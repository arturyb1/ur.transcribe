import AppKit
import SwiftUI

@main
struct EarshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model, settings: model.settings, permissions: model.permissions)
        } label: {
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--selftest") {
            let files = Array(arguments[(flag + 1)...])
            Task { @MainActor in exit(await SelfTest.run(files: files)) }
            return
        }
        if let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 {
            let folder = arguments[flag + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                exit(await Snapshots.run(into: folder))
            }
            return
        }
        MainActor.assumeIsolated { AppModel.shared.launch() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Save the transcript of a call in progress before quitting.
        let model = MainActor.assumeIsolated { AppModel.shared }
        let recording = MainActor.assumeIsolated { model.state == .recording }
        guard recording else { return .terminateNow }
        Task { @MainActor in
            model.stop(manual: true)
            while model.state == .stopping || model.state == .recording {
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
