import AVFoundation
import FluidAudio
import Foundation
import os

/// Splits the remote side of a call into up to four voices, live, on device.
/// Uses NVIDIA's Sortformer model through FluidAudio (Core ML / Neural Engine).
final class LiveDiarizer: @unchecked Sendable {
    struct Turn {
        let speaker: Int
        let start: Double
        let end: Double
    }

    /// New finalized turns, delivered on the main actor.
    var onTurns: (([Turn]) -> Void)?

    private let diarizer: SortformerDiarizer
    private let converter = BufferConverter(
        outputFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    )
    private let queue = DispatchQueue(label: "urtranscribe.diarizer", qos: .userInitiated)
    private let lock = NSLock()
    private var turns: [Turn] = []
    private var pending: [Float] = []
    private var lastRefresh = Date.distantPast
    private let log = Logger(subsystem: "ur.transcribe", category: "LiveDiarizer")

    static let config = SortformerConfig.default

    enum ModelError: LocalizedError {
        case unreachable(huggingFace: Error, mirror: Error)
        case badArchive

        var errorDescription: String? {
            switch self {
            case .unreachable(let huggingFace, let mirror):
                return "Couldn't download it (Hugging Face: \(Self.reason(huggingFace)); GitHub: \(Self.reason(mirror))). Your network may block model downloads. Get speaker-model-sortformer-v3-fp16.zip from the project's releases on another network, then use From file."
            case .badArchive:
                return "That file isn't a ur.transcribe speaker model. Use speaker-model-sortformer-v3-fp16.zip from the project's releases."
            }
        }

        /// A few words on why a download failed.
        private static func reason(_ error: Error) -> String {
            guard let url = error as? URLError else { return error.localizedDescription }
            switch url.code {
            case .notConnectedToInternet: return "no internet connection"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "can't reach the server"
            case .timedOut: return "timed out"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "secure connection blocked"
            case .badServerResponse: return "server refused the download"
            default: return "network error \(url.code.rawValue)"
            }
        }
    }

    /// FluidAudio's model cache. Files placed here load without any network.
    static let modelsFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models", isDirectory: true)

    /// The same model, mirrored on this project's GitHub releases, for networks that block Hugging Face.
    static let mirrorURL = URL(string:
        "https://github.com/arturyb1/ur.transcribe/releases/download/speaker-model-v1/speaker-model-sortformer-v3-fp16.zip")!

    /// Whether a complete model is on disk (a failed download can leave partial files behind).
    static var isModelCached: Bool {
        let weights = modelsFolder.appendingPathComponent("sortformer/v3/fp16/Sortformer_v2.1.mlmodelc/coremldata.bin")
        return FileManager.default.fileExists(atPath: weights.path)
    }

    /// Loads the model from disk, downloading it first if needed: from Hugging
    /// Face, and if that fails, from the GitHub mirror.
    static func loadModels() async throws -> SortformerModels {
        if isModelCached, let models = try? await loadCached() { return models }
        do {
            return try await SortformerModels.loadFromHuggingFace(config: config)
        } catch let huggingFace {
            Logger(subsystem: "ur.transcribe", category: "LiveDiarizer")
                .error("Hugging Face download failed, trying the mirror: \(huggingFace.localizedDescription)")
            do {
                let (download, response) = try await URLSession.shared.download(from: mirrorURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw URLError(.badServerResponse)
                }
                try installArchive(download)
                return try await loadCached()
            } catch let mirror {
                throw ModelError.unreachable(huggingFace: huggingFace, mirror: mirror)
            }
        }
    }

    /// Installs a model zip (as published in the releases) into the cache, then loads it.
    static func installAndLoad(archive: URL) async throws -> SortformerModels {
        try installArchive(archive)
        return try await loadCached()
    }

    private static func installArchive(_ archive: URL) throws {
        try FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, modelsFolder.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0, isModelCached else { throw ModelError.badArchive }
    }

    /// Loads strictly from disk; never touches the network.
    private static func loadCached() async throws -> SortformerModels {
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }
        return try await SortformerModels.loadFromHuggingFace(config: config)
    }

    init(models: SortformerModels) {
        diarizer = SortformerDiarizer(config: Self.config)
        diarizer.initialize(models: models)
    }

    /// Called from the capture thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        let samples = converter.convertToSamples(buffer)
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.append(contentsOf: samples)
            // Batch about a quarter second per inference call.
            guard self.pending.count >= 4_000 else { return }
            let chunk = self.pending
            self.pending.removeAll(keepingCapacity: true)
            do {
                if let update = try self.diarizer.process(samples: chunk) {
                    self.record(update.finalizedSegments)
                }
                if Date().timeIntervalSince(self.lastRefresh) > 1 { self.refreshTurns() }
            } catch {
                self.log.error("Diarization failed: \(error.localizedDescription)")
            }
        }
    }

    func finish() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { return done.resume() }
                do {
                    if !self.pending.isEmpty {
                        if let update = try self.diarizer.process(samples: self.pending) {
                            self.record(update.finalizedSegments)
                        }
                        self.pending.removeAll()
                    }
                    if let update = try self.diarizer.finalizeSession() {
                        self.record(update.finalizedSegments)
                    }
                    // Finalizing also closes segments that were still open; read them all back.
                    self.refreshTurns()
                } catch {
                    self.log.error("Finalizing diarization failed: \(error.localizedDescription)")
                }
                done.resume()
            }
        }
    }

    /// The voice that spoke most during [start, end] (stream seconds), if any.
    func dominantSpeaker(start: Double, end: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        var overlap: [Int: Double] = [:]
        for turn in turns where turn.end > start - 0.3 && turn.start < end + 0.3 {
            overlap[turn.speaker, default: 0] += min(turn.end, end + 0.3) - max(turn.start, start - 0.3)
        }
        if let best = overlap.max(by: { $0.value < $1.value }) { return best.key }
        // Nothing overlapped (the diarizer can miss quiet speech): use the nearest turn.
        return turns.min(by: { distance($0, start, end) < distance($1, start, end) })
            .flatMap { distance($0, start, end) < 2.0 ? $0.speaker : nil }
    }

    /// How many distinct voices have been heard so far.
    var speakerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return Set(turns.map(\.speaker)).count
    }

    private func distance(_ turn: Turn, _ start: Double, _ end: Double) -> Double {
        if turn.end < start { return start - turn.end }
        if turn.start > end { return turn.start - end }
        return 0
    }

    /// Reports newly finalized turns (used to vote names onto voices).
    private func record(_ segments: [DiarizerSegment]) {
        guard !segments.isEmpty else { return }
        let new = segments.map(Self.turn)
        DispatchQueue.main.async { [weak self] in self?.onTurns?(new) }
    }

    /// Mirrors the diarizer's whole timeline, including the turn still in
    /// progress, so lines get a voice while someone is mid-sentence.
    private func refreshTurns() {
        lastRefresh = Date()
        let all = diarizer.timeline.speakers.values.flatMap { $0.finalizedSegments + $0.tentativeSegments }
        lock.lock()
        turns = all.map(Self.turn)
        lock.unlock()
    }

    private static func turn(_ segment: DiarizerSegment) -> Turn {
        Turn(speaker: segment.speakerIndex, start: Double(segment.startTime), end: Double(segment.endTime))
    }
}
