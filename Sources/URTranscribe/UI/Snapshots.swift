import AppKit
import SwiftUI

/// Renders each screen to a PNG, for docs and for checking layout without
/// clicking through the app.
///
///     ur.transcribe.app/Contents/MacOS/URTranscribe --snapshot docs/
@MainActor
enum Snapshots {
    static func run(into folder: String) async -> Int32 {
        let model = AppModel.shared
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        model.permissions.refresh()
        await model.permissions.refreshSpeechModel()

        let idle: [(String, AnyView)] = [
            ("menu", AnyView(MenuPanel(model: model, settings: model.settings, permissions: model.permissions))),
            ("setup", AnyView(SetupView(permissions: model.permissions, settings: model.settings))),
            ("settings", AnyView(SettingsView(settings: model.settings, permissions: model.permissions).frame(height: 560))),
        ]
        render(idle, into: out)

        // A failed speaker model download, as a blocked network shows it.
        model.permissions.speakerModel = .denied
        model.permissions.speakerModelError = LiveDiarizer.ModelError.unreachable(
            huggingFace: URLError(.cannotConnectToHost), mirror: URLError(.timedOut)).localizedDescription
        render([("setup-model-error", AnyView(SetupView(permissions: model.permissions, settings: model.settings)))], into: out)

        model.showSampleCall()
        let recording: [(String, AnyView)] = [
            ("menu-recording", AnyView(MenuPanel(model: model, settings: model.settings, permissions: model.permissions))),
            ("transcript", AnyView(TranscriptWindowView(model: model).frame(width: 620, height: 560))),
        ]
        render(recording, into: out)
        return 0
    }

    private static func render(_ views: [(String, AnyView)], into out: URL) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, view) in views {
                let suffix = appearance == .darkAqua ? "-dark" : ""
                save(view, appearance: appearance, to: out.appendingPathComponent("\(name)\(suffix).png"))
            }
        }
    }

    private static func save(_ view: AnyView, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: appearance)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("Wrote \(url.path)")
    }
}
