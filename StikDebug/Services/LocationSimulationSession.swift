import Foundation
import CoreLocation
import Combine

final class LocationSimulationSession: ObservableObject {
    static let shared = LocationSimulationSession()

    @Published private(set) var isActive = false
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D]?
    private var resendTimer: Timer?

    /// Remembers the coordinate being held across launches, so a simulation
    /// survives the app being killed or the device rebooting.
    private static let storageKey = "heldSimulatedLocation"

    /// Guards the state below, which is touched both on the main thread and on
    /// `LocationSimulationCommandQueue`.
    private let lock = NSLock()
    private var routeID: UUID?
    private var consecutiveResendFailures = 0
    private var resendInFlight = false
    private var standbyPingInFlight = false

    /// The hold being re-applied, kept so resends can be suspended while another
    /// command runs and resumed if that command fails. Main thread only.
    private var resendBase: CLLocationCoordinate2D?
    private var resendOperation: ((CLLocationCoordinate2D) -> Int32)?

    /// After a Stop, nothing is simulated but the connection is kept open, so a
    /// new simulation can start without opening one; opening one has been refused
    /// on cellular-only. Standby keeps the background keep-alive held and the
    /// connection busy for as long as that idle connection exists.
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

    // MARK: - Resending

    /// Re-applies the held location every 4s. `operation` receives the
    /// coordinate to set, runs on `LocationSimulationCommandQueue`, and returns
    /// the simulation status code.
    func startResending(
        at coordinate: CLLocationCoordinate2D,
        _ operation: @escaping (CLLocationCoordinate2D) -> Int32
    ) {
        start(at: coordinate)
        resendBase = coordinate
        resendOperation = operation
        driftOffset = (north: 0, east: 0)
        scheduleResendTimer()
    }

    /// Stops resends while another command (a new location, a route) is being
    /// applied, so a resend of the old location cannot be queued behind it and
    /// land afterwards. Pair with `resumeResending()` if that command fails.
    func suspendResending() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    /// Restarts the resends of the current hold after a failed command.
    func resumeResending() {
        guard isActive, resendTimer == nil, resendBase != nil else { return }
        scheduleResendTimer()
    }

    func pauseResending() {
        suspendResending()
        resendBase = nil
        resendOperation = nil
        // Nothing is being held any more, so there is nothing to re-arm on the
        // next launch. Whoever resumes (a new pin, a route) persists again.
        persist(nil)
    }

    private func scheduleResendTimer() {
        guard let base = resendBase, let operation = resendOperation else { return }
        resendTimer?.invalidate()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let target = self.nextResendCoordinate(around: base)
            self.enqueueOnce(\.resendInFlight) {
                self.noteResendResult(operation(target))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    /// Runs `work` on the command queue unless the previous run guarded by the
    /// same flag is still in progress.
    ///
    /// Opening a fresh connection can block for several seconds while the Remote
    /// Pairing port is discovered, and a request on a dead connection can hang.
    /// Work arriving every 4s would then stack up faster than it drains, and
    /// Simulate and Stop, which share the queue, would wait behind the backlog.
    private func enqueueOnce(
        _ flag: ReferenceWritableKeyPath<LocationSimulationSession, Bool>,
        _ work: @escaping () -> Void
    ) {
        lock.lock()
        guard !self[keyPath: flag] else {
            lock.unlock()
            return
        }
        self[keyPath: flag] = true
        lock.unlock()

        LocationSimulationCommandQueue.shared.async {
            work()
            self.lock.lock()
            self[keyPath: flag] = false
            self.lock.unlock()
        }
    }

    // MARK: - Drift

    static let driftDefaultsKey = "simulatedLocationDrift"

    /// A phone at rest still wanders a few meters because GPS is noisy, and Find
    /// My reports more readily when the location changes. A held point that is
    /// bit-for-bit identical on every resend can sit unreported until the shared
    /// location ages into a stale (grey) pin. Wandering within a few meters of
    /// the chosen spot looks like an ordinary stationary phone.
    private static let driftRadiusMeters = 6.0
    private static let driftStepMeters = 1.5

    /// Meters north/east of the held coordinate. Main thread only.
    private var driftOffset = (north: 0.0, east: 0.0)

    private func nextResendCoordinate(around base: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard UserDefaults.standard.bool(forKey: Self.driftDefaultsKey) else { return base }

        let step = Self.driftStepMeters
        var north = driftOffset.north + Double.random(in: -step...step)
        var east = driftOffset.east + Double.random(in: -step...step)
        let distance = (north * north + east * east).squareRoot()
        if distance > Self.driftRadiusMeters {
            let scale = Self.driftRadiusMeters / distance
            north *= scale
            east *= scale
        }
        driftOffset = (north: north, east: east)

        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = max(metersPerDegreeLatitude * cos(base.latitude * .pi / 180), 1)
        return CLLocationCoordinate2D(
            latitude: base.latitude + north / metersPerDegreeLatitude,
            longitude: base.longitude + east / metersPerDegreeLongitude
        )
    }

    // MARK: - Routes

    func startRoute(at coordinate: CLLocationCoordinate2D, coordinates: [CLLocationCoordinate2D]) -> UUID {
        let routeID = UUID()
        lock.lock()
        self.routeID = routeID
        lock.unlock()
        routeCoordinates = coordinates
        start(at: coordinate)
        return routeID
    }

    /// Safe to call from any thread. Route samples check this on the command
    /// queue right before they are applied, so a sample queued after a Stop or a
    /// new route is dropped instead of re-simulating a stale point.
    func isCurrentRoute(_ routeID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.routeID == routeID
    }

    func clearRoute() {
        lock.lock()
        routeID = nil
        lock.unlock()
        routeCoordinates = nil
    }

    func updateCoordinate(_ coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        persist(coordinate)
    }

    // MARK: - Stop

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
            guard let self else { return }
            self.enqueueOnce(\.standbyPingInFlight) {
                let result = ping_idle_location_simulation()
                DispatchQueue.main.async {
                    self.handleStandbyPing(result)
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
            // A new simulation has been applied and its success has not reached
            // the main thread yet; start(at:) will end standby.
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
        // would just burn battery. Resolved once here; resends only read it when
        // they have to open a fresh connection.
        let pairingPath = PairingFileStore.prepareURL().path
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            return
        }

        LogManager.shared.addInfoLog(
            String(format: "Restoring held simulated location: %.6f, %.6f", restored.latitude, restored.longitude)
        )
        startResending(at: restored) { target in
            simulate_location(
                DeviceConnectionContext.targetIPAddress,
                target.latitude,
                target.longitude,
                pairingPath
            )
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
    private func noteResendResult(_ code: Int32) {
        lock.lock()
        let previousFailures = consecutiveResendFailures
        consecutiveResendFailures = code == 0 ? 0 : previousFailures + 1
        let failures = consecutiveResendFailures
        lock.unlock()

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
        lock.lock()
        consecutiveResendFailures = 0
        lock.unlock()
    }
}
