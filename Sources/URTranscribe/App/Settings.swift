import Foundation

/// An app ur.transcribe can detect a call in, matched by bundle ID prefix.
struct CallApp: Identifiable, Hashable {
    let id: String
    let name: String
    let bundlePrefixes: [String]
    let enabledByDefault: Bool
    /// Processes that exist only while a meeting is running, when the app has one.
    var meetingProcessNames: [String] = []

    static let all: [CallApp] = [
        CallApp(id: "zoom", name: "Zoom", bundlePrefixes: ["us.zoom."], enabledByDefault: true, meetingProcessNames: ["CptHost"]),
        CallApp(id: "teams", name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams"], enabledByDefault: true),
        CallApp(id: "webex", name: "Webex", bundlePrefixes: ["Cisco-Systems.Spark", "com.webex."], enabledByDefault: true),
        CallApp(id: "slack", name: "Slack huddles", bundlePrefixes: ["com.tinyspeck.slackmacgap"], enabledByDefault: true),
        CallApp(id: "facetime", name: "FaceTime", bundlePrefixes: ["com.apple.FaceTime", "com.apple.avconferenced"], enabledByDefault: true),
        CallApp(
            id: "browser", name: "Browser calls (Google Meet and others)",
            bundlePrefixes: [
                "com.google.Chrome", "com.apple.Safari", "com.apple.WebKit", "company.thebrowser.",
                "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
            ],
            enabledByDefault: false),
    ]
}

/// Sends a call's transcript to a folder based on its calendar event.
struct RoutingRule: Codable, Identifiable, Hashable {
    enum Match: String, Codable, CaseIterable, Identifiable {
        case calendar = "Calendar is"
        case titleContains = "Title contains"
        var id: String { rawValue }
    }

    var id = UUID()
    var match: Match = .calendar
    var value: String = ""
    var folderPath: String = ""

    func matches(_ meeting: MeetingInfo) -> Bool {
        let needle = value.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        switch match {
        case .calendar: return meeting.calendarTitle?.caseInsensitiveCompare(needle) == .orderedSame
        case .titleContains: return meeting.title.localizedCaseInsensitiveContains(needle)
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var destinationPath: String { didSet { defaults.set(destinationPath, forKey: "destinationPath") } }
    @Published var rules: [RoutingRule] { didSet { save(rules, "rules") } }
    @Published var myName: String { didSet { defaults.set(myName, forKey: "myName") } }
    @Published var autoDetect: Bool { didSet { defaults.set(autoDetect, forKey: "autoDetect") } }
    @Published var enabledApps: Set<String> { didSet { defaults.set(Array(enabledApps), forKey: "enabledApps") } }
    @Published var includeTimestamps: Bool { didSet { defaults.set(includeTimestamps, forKey: "includeTimestamps") } }
    @Published var removeEcho: Bool { didSet { defaults.set(removeEcho, forKey: "removeEcho") } }
    @Published var useCalendar: Bool { didSet { defaults.set(useCalendar, forKey: "useCalendar") } }
    @Published var useDiarization: Bool { didSet { defaults.set(useDiarization, forKey: "useDiarization") } }
    @Published var useZoomNames: Bool { didSet { defaults.set(useZoomNames, forKey: "useZoomNames") } }
    @Published var zoomPatterns: [String] { didSet { defaults.set(zoomPatterns, forKey: "zoomPatterns") } }
    @Published var localeIdentifier: String { didSet { defaults.set(localeIdentifier, forKey: "localeIdentifier") } }
    @Published var notifyOnStartStop: Bool { didSet { defaults.set(notifyOnStartStop, forKey: "notifyOnStartStop") } }
    /// Minutes without any speech before a call counts as over. 0 turns it off.
    @Published var silenceStopMinutes: Int { didSet { defaults.set(silenceStopMinutes, forKey: "silenceStopMinutes") } }
    @Published var hasCompletedSetup: Bool { didSet { defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup") } }
    @Published var systemAudioRequested: Bool { didSet { defaults.set(systemAudioRequested, forKey: "systemAudioRequested") } }

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        destinationPath = defaults.string(forKey: "destinationPath")
            ?? documents.appendingPathComponent("ur.transcribe").path
        rules = (defaults.data(forKey: "rules")).flatMap { try? JSONDecoder().decode([RoutingRule].self, from: $0) } ?? []
        myName = defaults.string(forKey: "myName") ?? NSFullUserName()
        autoDetect = defaults.object(forKey: "autoDetect") as? Bool ?? true
        enabledApps = Set(defaults.stringArray(forKey: "enabledApps")
            ?? CallApp.all.filter(\.enabledByDefault).map(\.id))
        includeTimestamps = defaults.object(forKey: "includeTimestamps") as? Bool ?? false
        removeEcho = defaults.object(forKey: "removeEcho") as? Bool ?? true
        useCalendar = defaults.object(forKey: "useCalendar") as? Bool ?? true
        useDiarization = defaults.object(forKey: "useDiarization") as? Bool ?? true
        useZoomNames = defaults.object(forKey: "useZoomNames") as? Bool ?? true
        zoomPatterns = defaults.stringArray(forKey: "zoomPatterns") ?? ZoomSpeakerWatcher.defaultPatterns
        localeIdentifier = defaults.string(forKey: "localeIdentifier") ?? ""
        notifyOnStartStop = defaults.object(forKey: "notifyOnStartStop") as? Bool ?? true
        silenceStopMinutes = defaults.object(forKey: "silenceStopMinutes") as? Int ?? 5
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
        systemAudioRequested = defaults.bool(forKey: "systemAudioRequested")
    }

    var enabledCallApps: [CallApp] { CallApp.all.filter { enabledApps.contains($0.id) } }

    /// The folder for a call: the first matching rule, else the default destination.
    func folder(for meeting: MeetingInfo?) -> URL {
        if let meeting, let rule = rules.first(where: { $0.matches(meeting) && !$0.folderPath.isEmpty }) {
            return URL(fileURLWithPath: rule.folderPath, isDirectory: true)
        }
        return URL(fileURLWithPath: destinationPath, isDirectory: true)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
