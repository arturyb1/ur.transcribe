import CoreAudio
import Foundation

/// Thin helpers over the Core Audio HAL property API.
enum CoreAudio {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default fallback: T) -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? value : fallback
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref)
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultOutputDeviceUID() -> String? {
        let device: AudioObjectID = value(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, default: 0)
        guard device != 0 else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }
}

/// A process that Core Audio knows about (anything that has opened an audio device).
struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
    let isRunningOutput: Bool

    static func all() -> [AudioProcess] {
        CoreAudio.objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
            .map { id in
                AudioProcess(
                    objectID: id,
                    pid: CoreAudio.value(id, kAudioProcessPropertyPID, default: pid_t(-1)),
                    bundleID: CoreAudio.string(id, kAudioProcessPropertyBundleID) ?? "",
                    isRunningInput: CoreAudio.value(id, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0,
                    isRunningOutput: CoreAudio.value(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
                )
            }
    }

    static func current() -> AudioProcess? {
        let me = ProcessInfo.processInfo.processIdentifier
        return all().first { $0.pid == me }
    }
}
