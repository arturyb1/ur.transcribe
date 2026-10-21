import AppKit
import ApplicationServices
import Foundation
import os

/// Reads who Zoom says is talking, through the macOS Accessibility API.
///
/// Zoom shows the active speaker's name in its meeting window ("Talking: Jane
/// Doe" in many versions). The exact wording varies by Zoom version and
/// language, so the patterns are configurable, and `snapshot()` dumps the whole
/// tree to help tune them. Best effort by design: when it finds nothing,
/// speakers keep their numbered labels.
final class ZoomSpeakerWatcher: @unchecked Sendable {
    static let zoomBundleID = "us.zoom.xos"

    static let defaultPatterns = [
        #"^Talking:\s*(.+)$"#,
        #"^(.+?) is talking$"#,
        #"^(.+?),? (?:is )?speaking$"#,
        #"^Active speaker[:,]?\s*(.+)$"#,
        #"^(.+?), active speaker$"#,
    ]

    private let patterns: [NSRegularExpression]
    private let excludedNames: Set<String>
    private let clock: () -> Double
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "urtranscribe.zoom-ax", qos: .utility)
    private let lock = NSLock()
    private var observations: [(time: Double, name: String)] = []
    private let log = Logger(subsystem: "ur.transcribe", category: "ZoomSpeakerWatcher")

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// - Parameters:
    ///   - clock: seconds on the remote-audio timeline, so observations line up with voices.
    ///   - excludedNames: your own name(s); you are on the microphone stream, not this one.
    init(patterns: [String], excludedNames: [String], clock: @escaping () -> Double) {
        self.patterns = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        self.excludedNames = Set(excludedNames.map { $0.lowercased() })
        self.clock = clock
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Names Zoom reported as talking during [start, end] (remote-audio seconds).
    func names(from start: Double, to end: Double) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return observations.filter { $0.time >= start && $0.time <= end }.map(\.name)
    }

    private func poll() {
        let now = clock()
        guard let name = currentSpeaker() else { return }
        lock.lock()
        observations.append((now, name))
        lock.unlock()
    }

    private func currentSpeaker() -> String? {
        for text in Self.strings(maxElements: 4000) {
            let range = NSRange(text.startIndex..., in: text)
            for pattern in patterns {
                guard let match = pattern.firstMatch(in: text, range: range), match.numberOfRanges > 1,
                      let captured = Range(match.range(at: 1), in: text)
                else { continue }
                let name = Self.clean(String(text[captured]))
                if !name.isEmpty, !excludedNames.contains(name.lowercased()) { return name }
            }
        }
        return nil
    }

    /// Strips Zoom decorations like "(Host)", "(Me)", ", Video on".
    static func clean(_ raw: String) -> String {
        var name = raw.components(separatedBy: ",").first ?? raw
        name = name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Accessibility tree

    private static func zoomApps() -> [AXUIElement] {
        NSRunningApplication.runningApplications(withBundleIdentifier: zoomBundleID).map {
            let app = AXUIElementCreateApplication($0.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.3)
            return app
        }
    }

    /// Every piece of text visible to Accessibility in Zoom's windows.
    static func strings(maxElements: Int) -> [String] {
        var result: [String] = []
        walk(maxElements: maxElements) { _, element in
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
                if let text = stringAttribute(element, attribute), !text.isEmpty { result.append(text) }
            }
        }
        return result
    }

    /// A readable dump of Zoom's accessibility tree, for tuning the patterns.
    static func snapshot() -> String {
        var lines: [String] = []
        walk(maxElements: 20_000) { depth, element in
            let role = stringAttribute(element, kAXRoleAttribute) ?? "?"
            let parts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
                .compactMap { attr in stringAttribute(element, attr).flatMap { $0.isEmpty ? nil : "\(attr)=\"\($0)\"" } }
            lines.append(String(repeating: "  ", count: depth) + role + (parts.isEmpty ? "" : " " + parts.joined(separator: " ")))
        }
        return lines.isEmpty ? "No Zoom windows found (is Zoom running, and is Accessibility allowed?)." : lines.joined(separator: "\n")
    }

    private static func walk(maxElements: Int, visit: (Int, AXUIElement) -> Void) {
        var budget = maxElements
        for app in zoomApps() {
            guard let windows = arrayAttribute(app, kAXWindowsAttribute) else { continue }
            var stack: [(AXUIElement, Int)] = windows.map { ($0, 0) }
            while let (element, depth) = stack.popLast(), budget > 0 {
                budget -= 1
                visit(depth, element)
                if depth < 25, let children = arrayAttribute(element, kAXChildrenAttribute) {
                    stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
                }
            }
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func arrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }
}
