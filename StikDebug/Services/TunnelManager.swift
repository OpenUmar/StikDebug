//
//  TunnelManager.swift
//  StikDebug
//

import Foundation

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var isConnected = false

    private var isStarting = false
    private var restartPending = false
    private var pathChangeWorkItem: DispatchWorkItem?
    private var lastInterfaceName: String?

    private init() {
        // Reconnect when the network path changes (e.g. a Wi-Fi↔cellular handoff)
        // so the tunnel comes back instead of staying dropped. Block-based
        // observer avoids needing an @objc selector on this non-NSObject singleton.
        NotificationCenter.default.addObserver(
            forName: .networkPathDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.networkPathChanged()
        }
    }

    func markDisconnected() {
        runOnMain {
            self.isConnected = false
        }
    }

    func restart() {
        runOnMain {
            self.isConnected = false
            if self.isStarting {
                self.restartPending = true
            } else {
                self.start()
            }
        }
    }

    func start(showErrorUI: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.start(showErrorUI: showErrorUI)
            }
            return
        }

        let pairingFileURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            isConnected = false
            return
        }

        guard !isStarting else {
            return
        }

        isStarting = true

        DispatchQueue.global(qos: .userInteractive).async { [showErrorUI] in
            let result = self.connectWithRetry()

            DispatchQueue.main.async {
                self.finishStart(result, showErrorUI: showErrorUI)
            }
        }
    }

    /// Attempts the tunnel connection a few times with a short backoff before
    /// giving up. Cellular paths (and Wi-Fi↔cellular handoffs) are more prone to
    /// transient connect failures than Wi-Fi, so a couple of retries turn a
    /// spurious drop into a successful connection instead of an error alert.
    private func connectWithRetry() -> Result<Void, NSError> {
        let maxAttempts = 3
        var lastError: NSError?

        for attempt in 1...maxAttempts {
            do {
                try JITEnableContext.shared.startTunnel()
                if attempt > 1 {
                    LogManager.shared.addInfoLog("Tunnel connected on attempt \(attempt)")
                }
                return .success(())
            } catch let error as NSError {
                lastError = error

                if Self.isPermanentTunnelError(error) || attempt == maxAttempts {
                    break
                }

                let backoff = TimeInterval(attempt) // 1s, then 2s
                LogManager.shared.addWarningLog(
                    "Tunnel connect attempt \(attempt) failed: \(error.localizedDescription). Retrying in \(Int(backoff))s…"
                )
                Thread.sleep(forTimeInterval: backoff)
            }
        }

        return .failure(lastError ?? NSError(
            domain: "StikDebug",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Tunnel connection failed"]
        ))
    }

    /// True for failures that another attempt won't fix — they need user action
    /// (fresh pairing file, valid target IP), not a retry.
    private static func isPermanentTunnelError(_ error: NSError) -> Bool {
        // -9 invalid/expired pairing, -17 missing pairing, -18 bad target IP.
        if [-9, -17, -18].contains(error.code) {
            return true
        }
        let message = error.localizedDescription.lowercased()
        // A refusal means nothing is listening on the port that was dialled; a
        // few seconds later nothing will be either. Each attempt also re-runs
        // Remote Pairing port discovery, which can take ~6s, so retrying a
        // refusal mostly delays the error.
        return message.contains("parse target ip")
            || message.contains("pairing file not found")
            || message.contains("connection refused")
    }

    private func networkPathChanged() {
        // Debounce: a handoff can emit several path updates in quick succession.
        pathChangeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.handleNetworkPathChange()
        }
        pathChangeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func handleNetworkPathChange() {
        let status = NetworkPathMonitor.shared.status
        guard status.isReachable else { return }

        let previous = lastInterfaceName
        lastInterfaceName = status.interfaceName
        let interfaceChanged = previous != nil && previous != status.interfaceName

        // A tunnel established earlier survives a Wi-Fi↔cellular handoff: the
        // connection rides LocalDevVPN's loopback, so the physical interface
        // underneath it doesn't matter (verified on device — an active session
        // kept working across the switch). Rebuilding here would tear down a
        // live tunnel and, on cellular, fail to replace it.
        guard !isConnected else {
            if interfaceChanged {
                LogManager.shared.addInfoLog(
                    "Interface changed (\(previous ?? "?") → \(status.interfaceName)); keeping existing tunnel"
                )
            }
            return
        }

        // Cellular included: Remote Pairing port discovery may find the service
        // where the fixed port was refused. A refusal is no longer retried, so
        // a failing attempt here costs one discovery and one connect.
        LogManager.shared.addInfoLog("Network path changed (\(status.description)); reconnecting tunnel")
        start(showErrorUI: false)
    }

    private func finishStart(_ result: Result<Void, NSError>, showErrorUI: Bool) {
        isStarting = false
        if restartPending {
            restartPending = false
            start()
            return
        }

        switch result {
        case .success:
            isConnected = true
            LogManager.shared.addInfoLog("Tunnel connected successfully")
            mountDeveloperDiskImageIfNeeded()
        case .failure(let error):
            isConnected = false
            handleStartFailure(error, showErrorUI: showErrorUI)
        }
    }

    private func mountDeveloperDiskImageIfNeeded() {
        guard DeveloperDiskImageService.filesAreReady else { return }
        MountingProgress.shared.pubMount()
    }

    private func handleStartFailure(_ error: NSError, showErrorUI: Bool) {
        LogManager.shared.addErrorLog(tunnelConnectionLogMessage(for: error))
        guard showErrorUI else {
            return
        }

        if error.code == -9 {
            handleInvalidPairingFile()
            return
        }

        showAlert(
            title: "Connection Error",
            message: tunnelConnectionAlertMessage(for: error),
            showOk: false,
            showTryAgain: true
        ) { shouldTryAgain in
            if shouldTryAgain {
                startTunnelInBackground()
            }
        }
    }

    private func handleInvalidPairingFile() {
        LogManager.shared.addInfoLog("Pairing file reported invalid; keeping existing file")

        showAlert(
            title: "Invalid Pairing File",
            message: "The pairing file may be invalid or expired. You can import a new pairing file to replace it.",
            showOk: true,
            showTryAgain: false,
            primaryButtonText: "Select New File"
        ) { _ in
            NotificationCenter.default.post(name: NSNotification.Name("ShowPairingFilePicker"), object: nil)
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

func startTunnelInBackground(showErrorUI: Bool = true) {
    TunnelManager.shared.start(showErrorUI: showErrorUI)
}

func markTunnelDisconnected() {
    TunnelManager.shared.markDisconnected()
}

private func tunnelConnectionLogMessage(for error: NSError) -> String {
    let target = RemotePairingPortResolver.lastAttemptDescription
    return "Tunnel connection failed for \(target): \(error.localizedDescription) (Domain: \(error.domain), Code: \(error.code), Raw: \(String(describing: error)))"
}

private func tunnelConnectionAlertMessage(for error: NSError) -> String {
    """
    Target attempted: \(RemotePairingPortResolver.lastAttemptDescription)

    Code \(error.code): \(error.localizedDescription)
    """
}
