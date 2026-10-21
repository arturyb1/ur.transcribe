import Foundation
import os

/// Collects segments from both streams and keeps one markdown file up to date.
@MainActor
final class TranscriptWriter {
    enum Source { case me, remote }

    struct Line {
        let source: Source
        /// Seconds since the call started.
        let start: Double
        let end: Double
        let text: String
        /// Remote-stream seconds, for looking up the diarized voice.
        let streamStart: Double
        let streamEnd: Double
    }

    let fileURL: URL
    private let title: String
    private let date: Date
    private var lines: [Line] = []
    private var dirty = false
    private let log = Logger(subsystem: "Earshot", category: "TranscriptWriter")

    init(folder: URL, title: String, date: Date) {
        self.title = title
        self.date = date
        fileURL = Self.uniqueURL(in: folder, title: title, date: date)
    }

    var isEmpty: Bool { lines.isEmpty }

    func add(_ line: Line) {
        lines.append(line)
        dirty = true
    }

    func markDirty() { dirty = true }

    /// The latest few rendered turns, for the menu bar preview.
    func recentTurns(_ count: Int, label: (Line) -> String, removeEcho: Bool) -> [String] {
        let recent = Array(lines.sorted { $0.start < $1.start }.suffix(30))
        return turns(of: recent, label: label, removeEcho: removeEcho).suffix(count).map { "\($0.name): \($0.text)" }
    }

    /// Rewrites the file if anything changed. Cheap: a long call is a few hundred KB.
    func flush(participants: [String], label: (Line) -> String, removeEcho: Bool, timestamps: Bool, force: Bool = false) {
        guard dirty || force, !lines.isEmpty else { return }
        dirty = false
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        var out = "Meeting Title: \(title)\n"
        out += "Date: \(formatter.string(from: date))\n"
        out += "Meeting participants: \(participants.joined(separator: ", "))\n\n"
        out += "Transcript:\n"
        for turn in turns(of: lines, label: label, removeEcho: removeEcho) {
            let stamp = timestamps ? "[\(Self.clock(turn.start))] " : ""
            out += "\(stamp)\(turn.name): \(turn.text)\n"
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            log.error("Could not write transcript: \(error.localizedDescription)")
        }
    }

    // MARK: - Rendering

    private struct Turn {
        let name: String
        let start: Double
        var text: String
    }

    private func turns(of lines: [Line], label: (Line) -> String, removeEcho: Bool) -> [Turn] {
        let sorted = lines.sorted { $0.start < $1.start }
        let remote = sorted.filter { $0.source == .remote }
        var result: [Turn] = []
        for line in sorted {
            if removeEcho, line.source == .me, isEcho(line, remote: remote) { continue }
            let name = label(line)
            if let last = result.last, last.name == name {
                result[result.count - 1].text += " " + line.text
            } else {
                result.append(Turn(name: name, start: line.start, text: line.text))
            }
        }
        return result
    }

    /// Without headphones, the mic hears the other side through the speakers.
    /// Drop mic lines that mostly repeat what the remote stream said at the same time.
    private func isEcho(_ mine: Line, remote: [Line]) -> Bool {
        let myWords = Self.words(mine.text)
        guard !myWords.isEmpty else { return false }
        let overlapping = remote.filter { $0.end > mine.start - 1.5 && $0.start < mine.end + 1.5 }
        guard !overlapping.isEmpty else { return false }
        let theirWords = Set(overlapping.flatMap { Self.words($0.text) })
        let shared = myWords.filter { theirWords.contains($0) }.count
        return Double(shared) / Double(myWords.count) >= 0.6
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// "2026-10-20 Weekly sync.md", with " 2", " 3" appended if taken.
    private static func uniqueURL(in folder: URL, title: String, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let safe = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let base = "\(formatter.string(from: date)) \(safe.isEmpty ? "Call" : String(safe.prefix(80)))"
        var candidate = folder.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        return candidate
    }
}
