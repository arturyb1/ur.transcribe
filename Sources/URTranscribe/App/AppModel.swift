import AppKit
import FluidAudio
import Foundation
import os

@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable {
        case idle, paused, starting, recording, stopping
    }

    /// An automatic stop that is counting down and can still be cancelled.
    struct PendingStop: Equatable {
        let id = UUID()
        let reason: String
        let deadline: Date
    }

    /// Seconds between noticing a call ended and saving, to allow "Keep transcribing".
    static var stopCountdown = 20

    static let shared = AppModel()

    @Published private(set) var state: State = .idle
    @Published private(set) var currentTitle: String?
    @Published private(set) var recordingSince: Date?
    @Published private(set) var preview = LivePreview()
    /// The current call's transcript, kept after it ends until the next call starts.
    @Published private(set) var transcript: [TranscriptTurn] = []
    @Published private(set) var transcriptTitle: String?
    @Published private(set) var lastTranscript: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var pendingStop: PendingStop?

    let settings = Settings.shared
    let permissions: Permissions
    private(set) var diarizerModels: SortformerModels?

    private let detector = CallDetector()
    private var session: RecordingSession?
    /// After "Keep transcribing", ignore the call app's end signal until it shows activity again.
    private var ignoreDetectorEnd = false
    private var silenceTimer: Timer?
    private let log = Logger(subsystem: "ur.transcribe", category: "AppModel")

    private init() {
        permissions = Permissions(settings: settings)
        permissions.attach(self)
    }

    func launch() {
        detector.appsToWatch = { [weak self] in self?.settings.enabledCallApps ?? [] }
        detector.onCallStarted = { [weak self] app in self?.callStarted(in: app) }
        detector.onCallEnded = { [weak self] reason in self?.callEnded(reason: reason) }
        Notifier.shared.start()
        if settings.autoDetect { detector.start() } else { state = .paused }
        permissions.refresh()
        Updater.shared.start()

        // The speaker model is cached after its first download; load it quietly.
        if settings.useDiarization, LiveDiarizer.isModelCached {
            Task {
                do { try await loadDiarizerModels() } catch {
                    log.error("Speaker model unavailable: \(error.localizedDescription)")
                }
            }
        }
        if !settings.hasCompletedSetup || !permissions.essentialsGranted {
            WindowManager.shared.showSetup()
        }
    }

    /// Downloads (if needed) and loads the speaker model, or installs it from a zip.
    func loadDiarizerModels(from archive: URL? = nil) async throws {
        if let archive {
            diarizerModels = try await LiveDiarizer.installAndLoad(archive: archive)
        } else {
            diarizerModels = try await LiveDiarizer.loadModels()
        }
    }

    func setAutoDetect(_ on: Bool) {
        settings.autoDetect = on
        if on {
            detector.start()
            if state == .paused { state = .idle }
        } else {
            detector.stop()
            if state == .idle { state = .paused }
        }
    }

    // MARK: - Automatic start and stop

    private func callStarted(in app: CallApp) {
        if state == .recording {
            // The call app is active again (for example after "Keep transcribing").
            ignoreDetectorEnd = false
            return
        }
        start(app: app, automatic: true)
    }

    func callEnded(reason: String) {
        guard !ignoreDetectorEnd else { return }
        scheduleStop(reason: reason)
    }

    /// Counts down before saving, so a wrong guess can be cancelled.
    private func scheduleStop(reason: String) {
        guard state == .recording, pendingStop == nil else { return }
        let pending = PendingStop(reason: reason, deadline: Date().addingTimeInterval(TimeInterval(Self.stopCountdown)))
        pendingStop = pending
        log.info("Stopping in \(Self.stopCountdown)s: \(reason, privacy: .public)")
        Notifier.shared.callEnding(title: currentTitle ?? "this call", reason: reason, seconds: Self.stopCountdown)
        Task {
            try? await Task.sleep(for: .seconds(Self.stopCountdown))
            guard pendingStop?.id == pending.id else { return }
            pendingStop = nil
            stop()
        }
    }

    /// Cancels a countdown to an automatic stop.
    func keepTranscribing() {
        guard pendingStop != nil else { return }
        pendingStop = nil
        ignoreDetectorEnd = true
        session?.noteActivity()
        Notifier.shared.clearEnding()
    }

    /// Stops and deletes what was transcribed so far; this call won't be picked up again.
    func discardCurrentCall() {
        stop(manual: true, discard: true)
    }

    private func startSilenceWatch() {
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSilence() }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    func checkSilence() {
        let minutes = settings.silenceStopMinutes
        guard minutes > 0, state == .recording, pendingStop == nil, let session else { return }
        if Date().timeIntervalSince(session.lastSpeechAt) > TimeInterval(minutes * 60) {
            scheduleStop(reason: "No one has spoken for \(minutes) minutes")
        }
    }

    // MARK: - Recording

    /// Start transcribing now. With no app, captures everything the Mac plays.
    func start(app: CallApp? = nil, automatic: Bool = false) {
        guard state == .idle || state == .paused else { return }
        state = .starting
        lastError = nil
        pendingStop = nil
        ignoreDetectorEnd = false
        let session = RecordingSession(app: app, settings: settings, diarizerModels: diarizerModels)
        session.onPreview = { [weak self] preview in self?.preview = preview }
        session.onTranscript = { [weak self] turns in self?.transcript = turns }
        transcript = []
        preview = LivePreview()
        self.session = session
        Task {
            do {
                try await session.start()
                currentTitle = session.title
                transcriptTitle = session.title
                recordingSince = session.startedAt
                state = .recording
                startSilenceWatch()
                if automatic, let app {
                    Notifier.shared.callStarted(
                        title: session.title, reason: "\(app.name) is using your microphone",
                        folder: session.fileURL.deletingLastPathComponent())
                }
            } catch {
                log.error("Could not start: \(error.localizedDescription)")
                lastError = error.localizedDescription
                _ = await session.stop()
                self.session = nil
                state = settings.autoDetect ? .idle : .paused
                Updater.shared.callEnded()
            }
        }
    }

    /// - Parameters:
    ///   - manual: you stopped it, so don't pick this call up again.
    ///   - discard: delete the transcript instead of keeping it.
    func stop(manual: Bool = false, discard: Bool = false) {
        guard state == .recording, let session else { return }
        if manual { detector.suppressCurrentCall() }
        state = .stopping
        pendingStop = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        let title = session.title
        Task {
            let url = await session.stop()
            if discard {
                if let url { try? FileManager.default.removeItem(at: url) }
                transcript = []
                Notifier.shared.clearCallNotifications()
            } else if let url {
                lastTranscript = url
                if manual { Notifier.shared.clearCallNotifications() } else { Notifier.shared.callSaved(title: title, file: url) }
            } else {
                Notifier.shared.clearCallNotifications()
            }
            self.session = nil
            currentTitle = nil
            recordingSince = nil
            preview = LivePreview()
            state = settings.autoDetect ? .idle : .paused
            Updater.shared.callEnded()
        }
    }

    var currentTranscript: URL? { session?.writer?.fileURL }

    /// Puts a made-up call on screen, for `--snapshot` renders only.
    func showSampleCall() {
        let lines = [
            ("Jane Doe", "Thanks for joining. I wanted to walk through the roadmap for next quarter and get your take on priorities."),
            ("Sam Lee", "Sure. My main concern is the launch date. Anything new has to fit around the migration."),
            ("Jane Doe", "That makes sense. Should we start with the review screen, since every team reuses it?"),
            ("Speaker 3", "From the engineering side, the new API needs a spike before we commit to anything."),
            ("Sam Lee", "Agreed. Let's put the spike on next week and revisit the plan on Friday."),
        ]
        transcript = lines.enumerated().map { TranscriptTurn(id: $0.offset, name: $0.element.0, start: Double($0.offset * 14), text: $0.element.1) }
        preview = LivePreview(turns: transcript, inProgress: [.init(name: "Remote", text: "I can own the spike if")])
        transcriptTitle = "Roadmap review"
        currentTitle = "Roadmap review"
        recordingSince = Date().addingTimeInterval(-754)
        state = .recording
        pendingStop = nil
        ignoreDetectorEnd = false
    }

    func openDestination() {
        let url = URL(fileURLWithPath: settings.destinationPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
