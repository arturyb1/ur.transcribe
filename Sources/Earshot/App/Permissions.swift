import AppKit
import AVFoundation
import ApplicationServices
import EventKit
import FluidAudio
import Foundation
import ServiceManagement

/// Tracks every permission and download Earshot needs, and asks for them.
@MainActor
final class Permissions: ObservableObject {
    enum Status: Equatable {
        case granted, denied, notAsked, working, unknown

        var isGranted: Bool { self == .granted }
    }

    @Published var microphone: Status = .unknown
    @Published var systemAudio: Status = .unknown
    @Published var speechModel: Status = .unknown
    @Published var speakerModel: Status = .unknown
    @Published var calendar: Status = .unknown
    @Published var accessibility: Status = .unknown
    @Published var openAtLogin = false

    private let settings: Settings
    private weak var model: AppModel?

    init(settings: Settings) {
        self.settings = settings
    }

    func attach(_ model: AppModel) { self.model = model }

    /// The minimum to transcribe at all.
    var essentialsGranted: Bool { microphone.isGranted && speechModel.isGranted && systemAudio.isGranted }

    func refresh() {
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
        calendar = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
        accessibility = AXIsProcessTrusted() ? .granted : .notAsked
        // macOS has no public way to read the system audio permission, so we
        // remember that it was requested and show where to check it.
        systemAudio = settings.systemAudioRequested ? .granted : .notAsked
        if speakerModel != .working {
            speakerModel = model?.diarizerModels != nil || LiveDiarizer.isModelCached ? .granted : .notAsked
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
        if speechModel != .working { Task { await refreshSpeechModel() } }
    }

    func refreshSpeechModel() async {
        guard let locale = await StreamTranscriber.resolveLocale(settings.localeIdentifier) else {
            speechModel = .denied
            return
        }
        speechModel = await StreamTranscriber.isModelInstalled(locale: locale) ? .granted : .notAsked
    }

    func requestMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
            if microphone == .denied { Self.openPrivacyPane("Privacy_Microphone") }
        }
    }

    func requestCalendar() {
        Task {
            _ = await CalendarLookup.requestAccess()
            refresh()
            if calendar == .denied { Self.openPrivacyPane("Privacy_Calendars") }
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // The user grants this in System Settings; check back periodically.
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                if AXIsProcessTrusted() { break }
            }
            refresh()
        }
    }

    /// Opening a process tap for the first time triggers the system prompt.
    func requestSystemAudio() {
        systemAudio = .working
        let tap = SystemAudioTap()
        do {
            try tap.start(bundlePrefixes: [])
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                tap.stop()
                settings.systemAudioRequested = true
                refresh()
            }
        } catch {
            systemAudio = .denied
        }
    }

    func downloadSpeechModel() {
        speechModel = .working
        Task {
            do {
                guard let locale = await StreamTranscriber.resolveLocale(settings.localeIdentifier) else {
                    speechModel = .denied
                    return
                }
                try await StreamTranscriber.installModel(locale: locale)
                speechModel = .granted
            } catch {
                speechModel = .denied
            }
        }
    }

    func downloadSpeakerModel() {
        speakerModel = .working
        Task {
            await model?.loadDiarizerModels()
            speakerModel = model?.diarizerModels != nil ? .granted : .denied
        }
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Earshot: could not change login item: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func openPrivacyPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }
}
