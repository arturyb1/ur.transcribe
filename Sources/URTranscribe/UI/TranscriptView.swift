import AppKit
import SwiftUI

/// The transcript as a scrolling list of turns that follows new lines as they
/// arrive, unless you scroll up to read.
struct TranscriptList: View {
    let turns: [TranscriptTurn]
    var inProgress: [LivePreview.Partial] = []
    /// Smaller type and no timestamps, for the menu bar.
    var compact = false
    var showTimes = false

    @State private var follow = true
    private let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                    if turns.isEmpty, inProgress.isEmpty {
                        Text("Listening…")
                            .font(compact ? .callout : .body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(turns) { turn in
                        TurnRow(name: turn.name, text: turn.text, time: showTimes ? turn.start : nil, compact: compact)
                    }
                    ForEach(Array(inProgress.enumerated()), id: \.offset) { _, partial in
                        TurnRow(name: partial.name, text: partial.text, time: nil, compact: compact, inProgress: true)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                        .onAppear { follow = true }
                        .onDisappear { follow = false }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, compact ? 2 : 4)
            }
            .onChange(of: turns) { _, _ in if follow { proxy.scrollTo(bottomID, anchor: .bottom) } }
            .onChange(of: inProgress) { _, _ in if follow { proxy.scrollTo(bottomID, anchor: .bottom) } }
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }
}

private struct TurnRow: View {
    let name: String
    let text: String
    let time: Double?
    let compact: Bool
    var inProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name).font((compact ? Font.callout : .body).weight(.semibold))
                if let time {
                    Text(TranscriptWriter.clock(time)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            Text(text)
                .font(compact ? .callout : .body)
                .foregroundStyle(inProgress ? .secondary : .primary)
                .italic(inProgress)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The full transcript in its own window, live during a call.
struct TranscriptWindowView: View {
    @ObservedObject var model: AppModel
    @State private var showTimes = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.state == .recording ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.transcriptTitle ?? "Transcript").font(.headline)
                    if let since = model.recordingSince, model.state == .recording {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text(model.transcript.isEmpty ? "No call yet" : "Call ended")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Times", isOn: $showTimes).toggleStyle(.checkbox)
                Button {
                    copyAll()
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(model.transcript.isEmpty)
                if let url = model.currentTranscript ?? model.lastTranscript {
                    Button {
                        model.reveal(url)
                    } label: { Label("Show file", systemImage: "folder") }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            TranscriptList(
                turns: model.transcript,
                inProgress: model.state == .recording ? model.preview.inProgress : [],
                showTimes: showTimes)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 420, idealWidth: 620, minHeight: 320, idealHeight: 680)
    }

    private func copyAll() {
        let text = model.transcript.map { "\($0.name): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
