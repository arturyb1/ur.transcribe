import AVFoundation
import CoreAudio
import Foundation
import os

/// Captures what a set of apps plays (the other side of a call) with a Core Audio
/// process tap. Nothing is written to disk: buffers go straight to `onBuffer`.
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: LocalizedError {
        case noOutputDevice
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noOutputDevice: return "No audio output device is available."
            case .coreAudio(let step, let status): return "\(step) failed (Core Audio error \(status))."
            }
        }
    }

    /// Called on a private serial queue with each captured buffer.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var format: AVAudioFormat?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "urtranscribe.system-audio", qos: .userInitiated)
    private let log = Logger(subsystem: "ur.transcribe", category: "SystemAudioTap")

    /// - Parameter bundlePrefixes: apps to capture. Empty captures everything except ur.transcribe.
    func start(bundlePrefixes: [String]) throws {
        let description: CATapDescription
        let processes = AudioProcess.all()
        let matches = processes.filter { process in
            bundlePrefixes.contains { process.bundleID.hasPrefix($0) }
        }
        if matches.isEmpty {
            // No app given, or it has no audio process yet: take everything but ur.transcribe.
            let own = AudioProcess.current().map { [$0.objectID] } ?? []
            description = CATapDescription(monoGlobalTapButExcludeProcesses: own)
        } else {
            description = CATapDescription(monoMixdownOfProcesses: matches.map(\.objectID))
            // Follow the app by bundle ID so helper processes that start mid-call are captured too.
            description.bundleIDs = Array(Set(matches.map(\.bundleID)))
            description.isProcessRestoreEnabled = true
        }
        description.uuid = UUID()
        description.name = "ur.transcribe"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.coreAudio("Creating the audio tap", status) }

        guard let outputUID = CoreAudio.defaultOutputDeviceUID() else { throw TapError.noOutputDevice }
        let tapUID = CoreAudio.string(tapID, kAudioTapPropertyUID) ?? description.uuid.uuidString
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ur.transcribe tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw TapError.coreAudio("Creating the capture device", status) }

        var asbd: AudioStreamBasicDescription = CoreAudio.value(
            tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            stop(); throw TapError.coreAudio("Reading the tap format", -1)
        }
        self.format = format

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  buffer.frameLength > 0
            else { return }
            self.onBuffer?(buffer)
        }
        guard status == noErr else { stop(); throw TapError.coreAudio("Starting capture", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw TapError.coreAudio("Starting capture", status) }
        log.info("System audio tap running at \(format.sampleRate) Hz")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}
