import Darwin
import Foundation
import os

/// Notices when a call starts and ends. Two signals, both cheap and needing no
/// permission:
/// - the call app has the microphone open (Core Audio's process list), and
/// - for apps that run meetings in a separate process (Zoom's CptHost), that
///   process exists. When it's available this signal wins, because some apps
///   keep the microphone open after a meeting ends.
@MainActor
final class CallDetector {
    var onCallStarted: ((CallApp) -> Void)?
    /// The call is over; the string says how we know.
    var onCallEnded: ((String) -> Void)?
    var appsToWatch: () -> [CallApp] = { [] }

    private var timer: Timer?
    private var activeApp: CallApp?
    private var positiveStreak = 0
    private var lastSeenActive = Date.distantPast
    /// Whether the active app's meeting process has been seen during this call.
    private var sawMeetingProcess = false
    private let log = Logger(subsystem: "ur.transcribe", category: "CallDetector")

    /// Seconds the mic must stay closed before a call counts as over. Some apps
    /// briefly release the mic when you mute or switch devices.
    var micReleaseGrace: TimeInterval = 45
    /// A meeting process exiting is definitive, so this can be short.
    var meetingExitGrace: TimeInterval = 4

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Common modes keep polling while a menu or dialog is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activeApp = nil
        positiveStreak = 0
    }

    /// Forget the current call (for example after a manual stop) so it is not
    /// picked up again until it ends and a new one starts.
    func suppressCurrentCall() {
        if activeApp == nil, let app = activeCallApp(processNames: Self.runningProcessNames()) {
            activeApp = app
            lastSeenActive = Date()
        }
    }

    private func poll() {
        let names = Self.runningProcessNames()
        if let activeApp {
            let meetingRunning = Self.meetingRunning(activeApp, names)
            if meetingRunning { sawMeetingProcess = true }
            let micOpen = Self.micOpenApps(appsToWatch()).contains(activeApp.id)

            let stillInCall: Bool
            let grace: TimeInterval
            let reason: String
            if sawMeetingProcess {
                stillInCall = meetingRunning
                grace = meetingExitGrace
                reason = "\(activeApp.name) meeting ended"
            } else {
                stillInCall = micOpen
                grace = micReleaseGrace
                reason = "\(activeApp.name) released the microphone"
            }
            if stillInCall {
                lastSeenActive = Date()
            } else if Date().timeIntervalSince(lastSeenActive) > grace {
                log.info("Call ended: \(reason, privacy: .public)")
                self.activeApp = nil
                positiveStreak = 0
                sawMeetingProcess = false
                onCallEnded?(reason)
            }
            return
        }
        guard let app = activeCallApp(processNames: names) else {
            positiveStreak = 0
            return
        }
        // Two polls in a row (about four seconds) filters out quick mic checks.
        positiveStreak += 1
        if positiveStreak >= 2 {
            activeApp = app
            lastSeenActive = Date()
            sawMeetingProcess = Self.meetingRunning(app, names)
            log.info("Call started in \(app.name, privacy: .public), meeting process: \(self.sawMeetingProcess)")
            onCallStarted?(app)
        }
    }

    /// The first watched app that is in a call: mic open, or meeting process running.
    private func activeCallApp(processNames: Set<String>) -> CallApp? {
        let apps = appsToWatch()
        let micOpen = Self.micOpenApps(apps)
        return apps.first { micOpen.contains($0.id) || Self.meetingRunning($0, processNames) }
    }

    private static func micOpenApps(_ apps: [CallApp]) -> Set<String> {
        let processes = AudioProcess.all().filter(\.isRunningInput)
        return Set(apps.filter { app in
            processes.contains { process in app.bundlePrefixes.contains { process.bundleID.hasPrefix($0) } }
        }.map(\.id))
    }

    private static func meetingRunning(_ app: CallApp, _ names: Set<String>) -> Bool {
        app.meetingProcessNames.contains { names.contains($0) }
    }

    /// Names of every process running for this user.
    static func runningProcessNames() -> Set<String> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var names = Set<String>()
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { names.insert(String(cString: buffer)) }
        }
        return names
    }
}
