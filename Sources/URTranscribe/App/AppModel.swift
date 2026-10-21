import AppKit
import FluidAudio
import Foundation
import os

@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable {
        case idle, paused, starting, recording, stopping
    }

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

    let settings = Settings.shared
    let permissions: Permissions
    private(set) var diarizerModels: SortformerModels?

    private let detector = CallDetector()
    private var session: RecordingSession?
    private let log = Logger(subsystem: "ur.transcribe", category: "AppModel")

    private init() {
        permissions = Permissions(settings: settings)
        permissions.attach(self)
    }

    func launch() {
        detector.appsToWatch = { [weak self] in self?.settings.enabledCallApps ?? [] }
        detector.onCallStarted = { [weak self] app in self?.start(app: app) }
        detector.onCallEnded = { [weak self] in self?.stop() }
        if settings.autoDetect { detector.start() } else { state = .paused }
        permissions.refresh()

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

    /// Start transcribing now. With no app, captures everything the Mac plays.
    func start(app: CallApp? = nil) {
        guard state == .idle || state == .paused else { return }
        state = .starting
        lastError = nil
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
            } catch {
                log.error("Could not start: \(error.localizedDescription)")
                lastError = error.localizedDescription
                _ = await session.stop()
                self.session = nil
                state = settings.autoDetect ? .idle : .paused
            }
        }
    }

    func stop(manual: Bool = false) {
        guard state == .recording, let session else { return }
        if manual { detector.suppressCurrentCall() }
        state = .stopping
        Task {
            if let url = await session.stop() { lastTranscript = url }
            self.session = nil
            currentTitle = nil
            recordingSince = nil
            preview = LivePreview()
            state = settings.autoDetect ? .idle : .paused
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
