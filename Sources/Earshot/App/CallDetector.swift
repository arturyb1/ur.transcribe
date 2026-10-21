import Foundation

/// Notices when a call app opens the microphone (a call started) and when it
/// has let go of it for a while (the call ended). Polls Core Audio's process
/// list, which is cheap and needs no permission.
@MainActor
final class CallDetector {
    var onCallStarted: ((CallApp) -> Void)?
    var onCallEnded: (() -> Void)?
    var appsToWatch: () -> [CallApp] = { [] }

    private var timer: Timer?
    private var activeApp: CallApp?
    private var positiveStreak = 0
    private var lastSeenActive = Date.distantPast

    /// Seconds the mic must stay closed before a call counts as over. Some apps
    /// briefly release the mic when you mute or switch devices.
    var endGrace: TimeInterval = 45

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activeApp = nil
        positiveStreak = 0
    }

    /// Forget the current call (for example after a manual stop) so it is not
    /// picked up again until the app closes and reopens the mic.
    func suppressCurrentCall() {
        if let app = appWithMicOpen() { activeApp = app }
    }

    private func poll() {
        let app = appWithMicOpen()
        if let activeApp {
            if app?.id == activeApp.id {
                lastSeenActive = Date()
            } else if Date().timeIntervalSince(lastSeenActive) > endGrace {
                self.activeApp = nil
                positiveStreak = 0
                onCallEnded?()
            }
            return
        }
        guard let app else {
            positiveStreak = 0
            return
        }
        // Two polls in a row (about four seconds) filters out quick mic checks.
        positiveStreak += 1
        if positiveStreak >= 2 {
            activeApp = app
            lastSeenActive = Date()
            onCallStarted?(app)
        }
    }

    private func appWithMicOpen() -> CallApp? {
        let processes = AudioProcess.all().filter(\.isRunningInput)
        return appsToWatch().first { app in
            processes.contains { process in app.bundlePrefixes.contains { process.bundleID.hasPrefix($0) } }
        }
    }
}
