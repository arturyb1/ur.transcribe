import AVFoundation
import Foundation
import os

/// Captures the local microphone. Everything on this stream is attributed to you.
final class MicCapture: @unchecked Sendable {
    /// Called on the audio thread. `resyncAt` is set on the first buffer after the
    /// input device changed, as seconds since `start()`, so the transcriber can
    /// keep its timeline aligned with the call.
    var onBuffer: ((AVAudioPCMBuffer, TimeInterval?) -> Void)?

    private let engine = AVAudioEngine()
    private var startedAt = Date()
    private var observer: NSObjectProtocol?
    private let lock = NSLock()
    private var pendingResync: TimeInterval?
    private let log = Logger(subsystem: "ur.transcribe", category: "MicCapture")

    func start() throws {
        startedAt = Date()
        try startEngine()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "ur.transcribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let resync = self.pendingResync
            self.pendingResync = nil
            self.lock.unlock()
            self.onBuffer?(buffer, resync)
        }
        engine.prepare()
        try engine.start()
    }

    /// The default input changed (for example, headphones plugged in). Reopen it.
    private func restart() {
        log.info("Input device changed, restarting microphone capture")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        pendingResync = Date().timeIntervalSince(startedAt)
        lock.unlock()
        do { try startEngine() } catch { log.error("Microphone restart failed: \(error.localizedDescription)") }
    }
}
