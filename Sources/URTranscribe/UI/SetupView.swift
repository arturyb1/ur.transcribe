import SwiftUI

/// First-run flow: every permission and download in one place, in order.
struct SetupView: View {
    @ObservedObject var permissions: Permissions
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up ur.transcribe").font(.title2.bold())
                Text("ur.transcribe transcribes your calls live, on this Mac. Audio never leaves it and is never saved, only the text.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("Required") {
                VStack(spacing: 0) {
                    PermissionRow(
                        title: "Microphone", detail: "Your side of the call.",
                        status: permissions.microphone, action: permissions.requestMicrophone)
                    Divider()
                    PermissionRow(
                        title: "System audio", detail: "The other side of the call, from the call app only.",
                        status: permissions.systemAudio, actionTitle: "Request",
                        action: permissions.requestSystemAudio,
                        secondary: ("Check", { Permissions.openPrivacyPane("Privacy_AudioCapture") }))
                    Divider()
                    PermissionRow(
                        title: "Speech model", detail: "Apple's on-device transcription model. One-time download.",
                        status: permissions.speechModel, actionTitle: "Download", retryTitle: "Retry",
                        error: permissions.speechModelError,
                        action: permissions.downloadSpeechModel)
                }
            }

            GroupBox("Who said what") {
                VStack(spacing: 0) {
                    PermissionRow(
                        title: "Calendar", detail: "Names the file and the people on one-on-ones, and picks the folder.",
                        status: permissions.calendar, action: permissions.requestCalendar)
                    Divider()
                    PermissionRow(
                        title: "Speaker model", detail: "Tells remote voices apart on group calls. One-time download.",
                        status: permissions.speakerModel, actionTitle: "Download", retryTitle: "Retry",
                        error: permissions.speakerModelError,
                        action: permissions.downloadSpeakerModel,
                        fallback: ("From file…", permissions.installSpeakerModelFromFile))
                    Divider()
                    PermissionRow(
                        title: "Accessibility", detail: "Reads who Zoom says is talking, to put names on voices.",
                        status: permissions.accessibility, action: permissions.requestAccessibility)
                }
            }

            GroupBox("Where and when") {
                VStack(alignment: .leading, spacing: 10) {
                    PermissionRow(
                        title: "Notifications", detail: "Tells you when transcription starts and stops, so you can change course.",
                        status: permissions.notifications, action: permissions.requestNotifications)
                    Divider()
                    FolderPicker(title: "Save transcripts to", path: $settings.destinationPath)
                    Toggle("Open ur.transcribe when I log in", isOn: Binding(
                        get: { permissions.openAtLogin }, set: { permissions.setOpenAtLogin($0) }))
                }
                .padding(6)
            }

            HStack {
                Text("You can change all of this later in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    settings.hasCompletedSetup = true
                    WindowManager.shared.closeSetup()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!permissions.essentialsGranted)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let status: Permissions.Status
    var actionTitle = "Allow"
    /// Label for trying again after a failure. Without one, a failure points to System Settings.
    var retryTitle: String? = nil
    var error: String? = nil
    let action: () -> Void
    /// Shown once granted (for example, a link to check the setting).
    var secondary: (String, () -> Void)? = nil
    /// Shown while not granted (for example, another way to get it).
    var fallback: (String, () -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if status == .denied, let error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if let secondary, status.isGranted {
                Button(secondary.0, action: secondary.1).controlSize(.small)
            }
            if let fallback, !status.isGranted, status != .working {
                Button(fallback.0, action: fallback.1).controlSize(.small)
            }
            switch status {
            case .granted: Text("Done").font(.caption).foregroundStyle(.secondary)
            case .working: ProgressView().controlSize(.small)
            case .denied: Button(retryTitle ?? "Open Settings", action: action).controlSize(.small)
            case .notAsked, .unknown: Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        default: Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

struct FolderPicker: View {
    let title: String
    @Binding var path: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(displayPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                .frame(maxWidth: 220, alignment: .trailing)
            Button("Choose…") { choose() }
        }
    }

    private var displayPath: String {
        path.isEmpty ? "Not set" : (path as NSString).abbreviatingWithTildeInPath
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
