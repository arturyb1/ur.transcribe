import AVFoundation
import FluidAudio
import Foundation
import os

/// One call, from the first word to the final write. Two streams (your mic and
/// the call app's audio) are transcribed live; the remote stream is also split
/// by voice and named. Only text ever touches the disk.
@MainActor
final class RecordingSession {
    let app: CallApp?
    let startedAt = Date()
    /// When anyone last said anything, on either stream.
    private(set) var lastSpeechAt = Date()
    private(set) var meeting: MeetingInfo?
    private(set) var writer: TranscriptWriter!

    /// The last few turns plus words still being recognized, for the menu bar.
    var onPreview: ((LivePreview) -> Void)?
    /// The whole transcript so far, every time the file is rewritten.
    var onTranscript: (([TranscriptTurn]) -> Void)?

    private let settings: Settings
    private let diarizerModels: SortformerModels?
    private var mic: MicCapture?
    private var tap: SystemAudioTap?
    private var micTranscriber: StreamTranscriber?
    private var remoteTranscriber: StreamTranscriber?
    private var diarizer: LiveDiarizer?
    private var zoomWatcher: ZoomSpeakerWatcher?
    private var namer: SpeakerNamer!
    private var flushTimer: Timer?
    private var micStartOffset: Double = 0
    private var remoteStartOffset: Double = 0
    private var remoteStartedAt = Date()
    private var volatileMine = ""
    private var volatileTheirs = ""
    private let log = Logger(subsystem: "ur.transcribe", category: "RecordingSession")

    init(app: CallApp?, settings: Settings, diarizerModels: SortformerModels?) {
        self.app = app
        self.settings = settings
        self.diarizerModels = diarizerModels
    }

    var title: String { meeting?.title ?? app.map { "\($0.name) call" } ?? "Call" }
    var fileURL: URL { writer.fileURL }

    private var myName: String {
        let configured = settings.myName.trimmingCharacters(in: .whitespaces)
        return configured.isEmpty ? (meeting?.myName ?? "Me") : configured
    }

    func start() async throws {
        if settings.useCalendar { meeting = CalendarLookup.currentMeeting(at: startedAt) }
        namer = SpeakerNamer(meeting: meeting)
        writer = TranscriptWriter(folder: settings.folder(for: meeting), title: title, date: startedAt)

        guard let locale = await StreamTranscriber.resolveLocale(settings.localeIdentifier) else {
            throw NSError(domain: "ur.transcribe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Your language is not supported by on-device transcription."])
        }
        let micT = try await StreamTranscriber(locale: locale)
        let remoteT = try await StreamTranscriber(locale: locale)
        micTranscriber = micT
        remoteTranscriber = remoteT

        micT.onFinal = { [weak self] segment in self?.addMine(segment) }
        micT.onVolatile = { [weak self] text in self?.volatileMine = text; self?.heard(text); self?.publishPreview() }
        remoteT.onFinal = { [weak self] segment in self?.addTheirs(segment) }
        remoteT.onVolatile = { [weak self] text in self?.volatileTheirs = text; self?.heard(text); self?.publishPreview() }
        try await micT.start()
        try await remoteT.start()

        // Remote voices only matter when there may be more than one of them.
        if settings.useDiarization, !namer.isOneOnOne, let models = diarizerModels {
            let diarizer = LiveDiarizer(models: models)
            diarizer.onTurns = { [weak self] turns in self?.handleTurns(turns) }
            self.diarizer = diarizer
        }

        let tap = SystemAudioTap()
        let diarizer = self.diarizer
        tap.onBuffer = { buffer in
            remoteT.feed(buffer)
            diarizer?.feed(buffer)
        }
        try tap.start(bundlePrefixes: app?.bundlePrefixes ?? [])
        remoteStartedAt = Date()
        remoteStartOffset = remoteStartedAt.timeIntervalSince(startedAt)
        self.tap = tap

        let mic = MicCapture()
        mic.onBuffer = { buffer, resync in micT.feed(buffer, resyncAt: resync) }
        try mic.start()
        micStartOffset = Date().timeIntervalSince(startedAt)
        self.mic = mic

        if settings.useZoomNames, app?.id == "zoom", !namer.isOneOnOne, ZoomSpeakerWatcher.isTrusted {
            let started = remoteStartedAt
            let watcher = ZoomSpeakerWatcher(
                patterns: settings.zoomPatterns,
                excludedNames: [myName, meeting?.myName].compactMap { $0 },
                clock: { Date().timeIntervalSince(started) })
            watcher.start()
            zoomWatcher = watcher
        }

        flushTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        log.info("Transcribing \(self.title, privacy: .private)")
    }

    /// Stops capture, lets the models finish the last words, writes the final file.
    /// Returns the transcript, or nil if nobody said anything.
    func stop() async -> URL? {
        flushTimer?.invalidate()
        mic?.stop()
        tap?.stop()
        zoomWatcher?.stop()
        await micTranscriber?.finish()
        await remoteTranscriber?.finish()
        await diarizer?.finish()
        flush(force: true)
        return writer.isEmpty ? nil : writer.fileURL
    }

    /// Treat now as the last moment someone spoke (for example after "Keep transcribing").
    func noteActivity() { lastSpeechAt = Date() }

    private func heard(_ text: String) {
        if !text.isEmpty { lastSpeechAt = Date() }
    }

    // MARK: - Segments

    private func addMine(_ segment: TranscribedSegment) {
        lastSpeechAt = Date()
        writer.add(.init(
            source: .me, start: micStartOffset + segment.start, end: micStartOffset + segment.end,
            text: segment.text, streamStart: segment.start, streamEnd: segment.end))
        publishPreview()
    }

    private func addTheirs(_ segment: TranscribedSegment) {
        lastSpeechAt = Date()
        writer.add(.init(
            source: .remote, start: remoteStartOffset + segment.start, end: remoteStartOffset + segment.end,
            text: segment.text, streamStart: segment.start, streamEnd: segment.end))
        publishPreview()
    }

    private func handleTurns(_ turns: [LiveDiarizer.Turn]) {
        if let zoomWatcher {
            for turn in turns { namer.vote(speaker: turn.speaker, names: zoomWatcher.names(from: turn.start, to: turn.end)) }
        }
        // Earlier lines may now have a voice (or a name), so re-render.
        writer.markDirty()
    }

    private func label(_ line: TranscriptWriter.Line) -> String {
        switch line.source {
        case .me: return myName
        case .remote:
            if namer.isOneOnOne { return namer.name(forSpeaker: nil) }
            guard let diarizer else { return "Others" }
            return namer.name(forSpeaker: diarizer.dominantSpeaker(start: line.streamStart, end: line.streamEnd))
        }
    }

    private var participants: [String] {
        var names = [myName]
        names.append(contentsOf: meeting?.others ?? [])
        return names
    }

    private func flush(force: Bool = false) {
        if let turns = writer.flush(
            participants: participants, label: label, removeEcho: settings.removeEcho,
            timestamps: settings.includeTimestamps, force: force)
        {
            onTranscript?(turns)
        }
    }

    private func publishPreview() {
        var inProgress: [LivePreview.Partial] = []
        if !volatileTheirs.isEmpty {
            let name = namer.isOneOnOne ? namer.name(forSpeaker: nil) : "Remote"
            inProgress.append(.init(name: name, text: volatileTheirs))
        }
        if !volatileMine.isEmpty { inProgress.append(.init(name: myName, text: volatileMine)) }
        onPreview?(LivePreview(
            turns: writer.recentTurns(8, label: label, removeEcho: settings.removeEcho),
            inProgress: inProgress))
    }
}

struct LivePreview: Equatable {
    struct Partial: Equatable {
        let name: String
        let text: String
    }

    var turns: [TranscriptTurn] = []
    /// Words still being recognized, not yet in the file.
    var inProgress: [Partial] = []

    var isEmpty: Bool { turns.isEmpty && inProgress.isEmpty }
}
