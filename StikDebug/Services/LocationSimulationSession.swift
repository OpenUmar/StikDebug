import Foundation
import CoreLocation
import Combine

final class LocationSimulationSession: ObservableObject {
    static let shared = LocationSimulationSession()

    @Published private(set) var isActive = false
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D]?
    private var resendTimer: Timer?
    private var routeID: UUID?

    /// Remembers the coordinate being held across launches, so a simulation
    /// survives the app being killed or the device rebooting.
    private static let storageKey = "heldSimulatedLocation"

    private let healthLock = NSLock()
    private var consecutiveResendFailures = 0

    /// After a Stop, nothing is simulated but the connection is kept open so a
    /// new simulation can start without opening one (impossible on cellular).
    /// Standby keeps the background keep-alive held and the connection busy for
    /// as long as that idle connection exists.
    private(set) var isStandingBy = false
    private var standbyTimer: Timer?
    private var standbyPingFailing = false

    private init() {}

    func start(at coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        persist(coordinate)
        if !isActive {
            isActive = true
            resetResendHealth()
            if isStandingBy {
                // Standby already holds the keep-alive; hand it over.
                endStandbyTimer()
            } else {
                BackgroundAudioManager.shared.requestStart()
                BackgroundLocationManager.shared.requestStart()
            }
        }
    }

    func startResending(at coordinate: CLLocationCoordinate2D, _ operation: @escaping () -> Void) {
        start(at: coordinate)
        resendTimer?.invalidate()
        let timer = Timer(timeInterval: 4, repeats: true) { _ in operation() }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    func startRoute(at coordinate: CLLocationCoordinate2D, coordinates: [CLLocationCoordinate2D]) -> UUID {
        let routeID = UUID()
        self.routeID = routeID
        routeCoordinates = coordinates
        start(at: coordinate)
        return routeID
    }

    func isCurrentRoute(_ routeID: UUID) -> Bool {
        self.routeID == routeID
    }

    func clearRoute() {
        routeID = nil
        routeCoordinates = nil
    }

    func pauseResending() {
        resendTimer?.invalidate()
        resendTimer = nil
        // Nothing is being held any more, so there is nothing to re-arm on the
        // next launch. Whoever resumes (a new pin, a route) persists again.
        persist(nil)
    }

    func updateCoordinate(_ coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        persist(coordinate)
    }

    /// Ends the simulation. With `keepingConnection`, the session drops into
    /// standby instead of going idle, so the open connection stays usable.
    func stop(keepingConnection: Bool = false) {
        pauseResending()
        clearRoute()

        let holdsKeepAlive = isActive || isStandingBy
        if isActive {
            isActive = false
            coordinate = nil
            resetResendHealth()
        }
        guard holdsKeepAlive else { return }

        if keepingConnection {
            beginStandby()
        } else {
            endStandbyTimer()
            BackgroundAudioManager.shared.requestStop()
            BackgroundLocationManager.shared.requestStop()
        }
    }

    // MARK: - Standby

    private func beginStandby() {
        guard !isStandingBy else { return }
        isStandingBy = true
        standbyPingFailing = false
        LogManager.shared.addInfoLog(
            "Simulated location stopped; keeping the connection open so it can be re-armed without Wi-Fi"
        )

        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            LocationSimulationCommandQueue.shared.async {
                let result = ping_idle_location_simulation()
                DispatchQueue.main.async {
                    self?.handleStandbyPing(result)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        standbyTimer = timer
    }

    private func endStandbyTimer() {
        standbyTimer?.invalidate()
        standbyTimer = nil
        isStandingBy = false
    }

    private func handleStandbyPing(_ result: IdleLocationSimulationPing) {
        guard isStandingBy else { return }

        switch result {
        case .noConnection:
            // The connection is gone, so there is nothing left to keep awake for.
            endStandbyTimer()
            BackgroundAudioManager.shared.requestStop()
            BackgroundLocationManager.shared.requestStop()
            LogManager.shared.addWarningLog(
                "Idle simulation connection closed; a new simulation will need Wi-Fi or a hotspot"
            )
        case .failed:
            if !standbyPingFailing {
                standbyPingFailing = true
                LogManager.shared.addWarningLog(
                    "Idle simulation connection is not responding; re-arming may need Wi-Fi or a hotspot"
                )
            }
        case .ok:
            if standbyPingFailing {
                standbyPingFailing = false
                LogManager.shared.addInfoLog("Idle simulation connection is responding again")
            }
        case .simulating:
            break
        }
    }

    // MARK: - Restore on launch

    /// Re-arms a location that was still being held when the app last stopped
    /// running. Call on the main thread.
    ///
    /// iOS gives sideloaded apps no way to launch themselves, so a reboot or a
    /// kill always ends the simulation. Picking it straight back up on launch is
    /// the next best thing: the resend tolerates failure, so this can be armed
    /// before LocalDevVPN is connected and takes hold once it is.
    func restoreIfNeeded() {
        guard !isActive,
              let values = UserDefaults.standard.array(forKey: Self.storageKey) as? [Double],
              values.count == 2 else {
            return
        }

        let restored = CLLocationCoordinate2D(latitude: values[0], longitude: values[1])
        guard CLLocationCoordinate2DIsValid(restored) else {
            persist(nil)
            return
        }

        // Without a pairing file nothing can ever succeed, and retrying forever
        // would just burn battery.
        guard FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) else {
            return
        }

        LogManager.shared.addInfoLog(
            String(format: "Restoring held simulated location: %.6f, %.6f", restored.latitude, restored.longitude)
        )
        startResending(at: restored) {
            LocationSimulationCommandQueue.shared.async {
                let code = simulate_location(
                    DeviceConnectionContext.targetIPAddress,
                    restored.latitude,
                    restored.longitude,
                    PairingFileStore.prepareURL().path
                )
                LocationSimulationSession.shared.noteResendResult(code)
            }
        }
    }

    private func persist(_ value: CLLocationCoordinate2D?) {
        if let value {
            UserDefaults.standard.set([value.latitude, value.longitude], forKey: Self.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
    }

    // MARK: - Resend health

    /// Surfaces whether the held location is actually being applied, without
    /// spamming the log: the first failure, the recovery, and a heartbeat
    /// roughly every five minutes while failing. Safe to call from any thread.
    func noteResendResult(_ code: Int32) {
        healthLock.lock()
        let previousFailures = consecutiveResendFailures
        consecutiveResendFailures = code == 0 ? 0 : previousFailures + 1
        let failures = consecutiveResendFailures
        healthLock.unlock()

        if code == 0 {
            if previousFailures > 0 {
                LogManager.shared.addInfoLog(
                    "Simulated location resend recovered after \(previousFailures) failed attempt(s)"
                )
            }
        } else if failures == 1 {
            LogManager.shared.addWarningLog(
                "Simulated location resend failed (error \(code)); retrying every 4s"
            )
        } else if failures % 75 == 0 {
            LogManager.shared.addWarningLog(
                "Simulated location resend still failing after \(failures) attempts (error \(code)); the held location is NOT being applied"
            )
        }
    }

    private func resetResendHealth() {
        healthLock.lock()
        consecutiveResendFailures = 0
        healthLock.unlock()
    }
}
