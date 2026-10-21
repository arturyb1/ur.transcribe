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
    @Published private(set) var preview: [String] = []
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
            Task { await loadDiarizerModels() }
        }
        if !settings.hasCompletedSetup || !permissions.essentialsGranted {
            WindowManager.shared.showSetup()
        }
    }

    func loadDiarizerModels() async {
        do {
            diarizerModels = try await LiveDiarizer.loadModels()
        } catch {
            log.error("Speaker model unavailable: \(error.localizedDescription)")
        }
        permissions.refresh()
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
        session.onPreview = { [weak self] lines in self?.preview = lines }
        self.session = session
        Task {
            do {
                try await session.start()
                currentTitle = session.title
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
            preview = []
            state = settings.autoDetect ? .idle : .paused
        }
    }

    var currentTranscript: URL? { session?.writer?.fileURL }

    func openDestination() {
        let url = URL(fileURLWithPath: settings.destinationPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
