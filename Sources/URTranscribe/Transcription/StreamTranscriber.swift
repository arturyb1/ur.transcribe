import AVFoundation
import CoreMedia
import Foundation
import Speech
import os

/// One finished stretch of speech from a single audio stream.
struct TranscribedSegment {
    /// Seconds from the start of the stream that produced it.
    let start: Double
    let end: Double
    let text: String
}

/// Live, on-device transcription of one audio stream with Apple's SpeechAnalyzer.
/// Audio is held in memory only.
final class StreamTranscriber: @unchecked Sendable {
    /// Final results, delivered on the main actor.
    var onFinal: ((TranscribedSegment) -> Void)?
    /// In-progress text for the live preview, delivered on the main actor.
    var onVolatile: ((String) -> Void)?

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let converter: BufferConverter
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>
    private var resultsTask: Task<Void, Never>?
    private var framesFed: Int64 = 0
    private let log = Logger(subsystem: "ur.transcribe", category: "StreamTranscriber")

    static func makeModule(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Picks the closest supported locale to the requested one.
    static func resolveLocale(_ identifier: String) async -> Locale? {
        let requested = identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
        return await SpeechTranscriber.supportedLocale(equivalentTo: requested)
    }

    /// Whether the on-device model for this locale is already installed.
    static func isModelInstalled(locale: Locale) async -> Bool {
        await AssetInventory.status(forModules: [makeModule(locale: locale)]) == .installed
    }

    /// Downloads the on-device model if needed. One-time, from Apple.
    static func installModel(locale: Locale) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule(locale: locale)]) {
            try await request.downloadAndInstall()
        }
    }

    init(locale: Locale) async throws {
        try await Self.installModel(locale: locale)
        transcriber = Self.makeModule(locale: locale)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "ur.transcribe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech model has no usable audio format."])
        }
        converter = BufferConverter(outputFormat: format)
        (inputStream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        try await analyzer.prepareToAnalyze(in: format)
    }

    func start() async throws {
        let transcriber = self.transcriber
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    await self?.deliver(result)
                }
            } catch {
                self?.log.error("Transcription stopped: \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: inputStream)
    }

    @MainActor private func deliver(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.isFinal else {
            onVolatile?(text)
            return
        }
        onVolatile?("")
        guard !text.isEmpty else { return }
        let start = result.range.start.seconds
        let end = (result.range.start + result.range.duration).seconds
        onFinal?(TranscribedSegment(start: start, end: end, text: text))
    }

    /// Thread-safe enough for one capture thread. `resyncAt` re-anchors the
    /// timeline (seconds since the stream started) after a capture restart.
    func feed(_ buffer: AVAudioPCMBuffer, resyncAt: TimeInterval? = nil) {
        guard let converted = converter.convert(buffer) else { return }
        let rate = converter.outputFormat.sampleRate
        var startTime: CMTime?
        if let resyncAt {
            let resyncFrames = Int64(resyncAt * rate)
            if resyncFrames > framesFed {
                framesFed = resyncFrames
                startTime = CMTime(value: framesFed, timescale: CMTimeScale(rate))
            }
        }
        framesFed += Int64(converted.frameLength)
        input.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime))
    }

    func finish() async {
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            log.error("Finalizing transcription failed: \(error.localizedDescription)")
        }
        await resultsTask?.value
    }
}
