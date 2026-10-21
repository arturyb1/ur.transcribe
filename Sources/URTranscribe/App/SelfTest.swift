import AVFoundation
import Foundation

/// Headless check of the transcription and voice-separation pipeline, no
/// permissions needed. Feeds audio files (played back to back) through the
/// same code the remote side of a call uses and prints the labeled result.
///
///     ur.transcribe.app/Contents/MacOS/URTranscribe --selftest a.wav b.wav ...
@MainActor
enum SelfTest {
    static func run(files: [String]) async -> Int32 {
        do {
            guard let locale = await StreamTranscriber.resolveLocale("") else {
                print("No supported speech locale")
                return 1
            }
            print("Locale: \(locale.identifier). Preparing speech model…")
            let transcriber = try await StreamTranscriber(locale: locale)
            // A second analyzer runs alongside, as the microphone stream does in a real call.
            let second = try await StreamTranscriber(locale: locale)
            var secondCount = 0
            second.onFinal = { _ in secondCount += 1 }
            try await second.start()
            print("Loading speaker model…")
            let diarizer = LiveDiarizer(models: try await LiveDiarizer.loadModels())

            var segments: [TranscribedSegment] = []
            transcriber.onFinal = { segments.append($0) }
            try await transcriber.start()

            let started = Date()
            var seconds = 0.0
            for path in files {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                let format = file.processingFormat
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { break }
                    try file.read(into: buffer, frameCount: 4096)
                    if buffer.frameLength == 0 { break }
                    transcriber.feed(buffer)
                    second.feed(buffer)
                    diarizer.feed(buffer)
                }
                seconds += Double(file.length) / format.sampleRate
            }
            await transcriber.finish()
            await second.finish()
            await diarizer.finish()

            print(String(format: "Processed %.1fs of audio in %.1fs. Voices heard: %d. Parallel stream lines: %d\n",
                         seconds, Date().timeIntervalSince(started), diarizer.speakerCount, secondCount))
            for segment in segments {
                let speaker = diarizer.dominantSpeaker(start: segment.start, end: segment.end).map { "Speaker \($0 + 1)" } ?? "Speaker ?"
                print(String(format: "[%5.1f-%5.1f] %@: %@", segment.start, segment.end, speaker, segment.text))
            }
            return segments.isEmpty ? 1 : 0
        } catch {
            print("Self-test failed: \(error.localizedDescription)")
            return 1
        }
    }
}
