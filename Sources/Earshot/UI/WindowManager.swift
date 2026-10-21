import AppKit
import SwiftUI

/// Owns the setup and settings windows. Earshot has no Dock icon, so windows
/// are managed by hand and the app is brought forward when one opens.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func showSetup() {
        let model = AppModel.shared
        show(&setupWindow, title: "Set up Earshot") {
            SetupView(permissions: model.permissions, settings: model.settings)
        }
    }

    func closeSetup() {
        setupWindow?.close()
    }

    func showSettings() {
        let model = AppModel.shared
        show(&settingsWindow, title: "Earshot Settings") {
            SettingsView(settings: model.settings, permissions: model.permissions)
        }
    }

    private func show<Content: View>(_ window: inout NSWindow?, title: String, content: () -> Content) {
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: content()))
            created.title = title
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
