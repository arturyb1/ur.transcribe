import SwiftUI

/// The menu bar icon. Quiet when idle, filled while transcribing.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.state {
        case .idle: Image(systemName: "waveform")
        case .paused: Image(systemName: "waveform.slash")
        case .starting, .stopping: Image(systemName: "ellipsis.circle")
        case .recording: Image(systemName: "waveform.circle.fill")
        }
    }
}

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.state == .recording {
                preview
            } else if !model.transcript.isEmpty {
                Button("Open last transcript") { WindowManager.shared.showTranscript() }
                    .buttonStyle(.link)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !permissions.essentialsGranted {
                Button("Finish setup…") { WindowManager.shared.showSetup() }
                    .buttonStyle(.link)
            }
            Divider()
            primaryAction
            Toggle("Detect calls automatically", isOn: Binding(
                get: { settings.autoDetect }, set: { model.setAutoDetect($0) }))
                .toggleStyle(.checkbox)
            Divider()
            HStack {
                Button("Transcripts") { model.openDestination() }
                if let url = model.currentTranscript ?? model.lastTranscript {
                    Button(model.state == .recording ? "Current file" : "Last file") { model.reveal(url) }
                }
                Spacer()
                Button {
                    WindowManager.shared.showSettings()
                } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: { Image(systemName: "power") }
                    .help("Quit ur.transcribe")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 400)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.state == .recording ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                if let since = model.recordingSince, model.state == .recording {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Live transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    WindowManager.shared.showTranscript()
                } label: {
                    Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Open the full transcript in a window")
            }
            TranscriptList(turns: model.preview.turns, inProgress: model.preview.inProgress, compact: true)
                .frame(height: 280)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var primaryAction: some View {
        switch model.state {
        case .recording:
            Button("Stop transcribing") { model.stop(manual: true) }
        case .starting:
            Button("Starting…") {}.disabled(true)
        case .stopping:
            Button("Saving…") {}.disabled(true)
        case .idle, .paused:
            Button("Transcribe now") { model.start() }
                .disabled(!permissions.essentialsGranted)
        }
    }

    private var statusTitle: String {
        switch model.state {
        case .idle: return "Listening for calls"
        case .paused: return "Auto-detect is off"
        case .starting: return "Starting…"
        case .recording: return model.currentTitle ?? "Transcribing"
        case .stopping: return "Saving transcript…"
        }
    }

    private var statusDetail: String {
        switch model.state {
        case .idle: return "Starts when a call app opens your microphone"
        case .paused: return "Use Transcribe now to start by hand"
        default: return ""
        }
    }
}
