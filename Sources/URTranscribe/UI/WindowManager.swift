import AppKit
import SwiftUI

/// Owns the setup and settings windows. ur.transcribe has no Dock icon, so windows
/// are managed by hand and the app is brought forward when one opens.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var setupWindow: NSWindow?
    private(set) var settingsWindow: NSWindow?
    private(set) var transcriptWindow: NSWindow?

    func showSetup() {
        let model = AppModel.shared
        show(&setupWindow, title: "Set up ur.transcribe") {
            SetupView(permissions: model.permissions, settings: model.settings)
        }
    }

    func closeSetup() {
        setupWindow?.close()
    }

    func showSettings() {
        let model = AppModel.shared
        show(&settingsWindow, title: "ur.transcribe Settings", resizableHeight: SettingsView.heights) {
            SettingsView(settings: model.settings, permissions: model.permissions)
        }
    }

    /// The full transcript, live during a call. Resizable in both directions.
    func showTranscript() {
        let model = AppModel.shared
        let isNew = transcriptWindow == nil
        show(&transcriptWindow, title: "Transcript", resizableHeight: (320, 680)) {
            TranscriptWindowView(model: model)
        }
        if isNew, let window = transcriptWindow {
            window.contentMinSize = NSSize(width: 420, height: 320)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            // Reopen where it was last left; first time, a comfortable reading size.
            if !window.setFrameUsingName("TranscriptWindow") {
                window.setContentSize(NSSize(width: 620, height: 680))
                window.center()
            }
            window.setFrameAutosaveName("TranscriptWindow")
        }
    }

    /// - Parameter resizableHeight: when set, the window can be resized vertically
    ///   between these heights (starting at `ideal`); its width stays fixed.
    private func show<Content: View>(
        _ window: inout NSWindow?, title: String,
        resizableHeight: (min: CGFloat, ideal: CGFloat)? = nil,
        content: () -> Content
    ) {
        if window == nil {
            let hosting = NSHostingController(rootView: content())
            let created = NSWindow(contentViewController: hosting)
            created.title = title
            created.styleMask = [.titled, .closable, .miniaturizable]
            if let heights = resizableHeight {
                // Let the window, not the content's fitting size, own the height.
                hosting.sizingOptions = [.minSize]
                created.styleMask.insert(.resizable)
                let width = created.frame.width
                created.setContentSize(NSSize(width: width, height: heights.ideal))
                created.contentMinSize = NSSize(width: width, height: heights.min)
                created.contentMaxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            }
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
