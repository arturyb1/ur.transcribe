import Speech
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: Permissions

    static let width: CGFloat = 560
    static let heights: (min: CGFloat, ideal: CGFloat) = (360, 560)

    var body: some View {
        TabView {
            GeneralTab(settings: settings, permissions: permissions)
                .tabItem { Label("General", systemImage: "gearshape") }
            DestinationsTab(settings: settings)
                .tabItem { Label("Folders", systemImage: "folder") }
            SpeakersTab(settings: settings, permissions: permissions)
                .tabItem { Label("Speakers", systemImage: "person.2") }
        }
        .frame(width: Self.width)
        .frame(minHeight: Self.heights.min, idealHeight: Self.heights.ideal, maxHeight: .infinity)
    }
}

private struct GeneralTab: View {
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: Permissions
    @State private var locales: [Locale] = []

    var body: some View {
        Form {
            Section {
                Toggle("Open ur.transcribe when I log in", isOn: Binding(
                    get: { permissions.openAtLogin }, set: { permissions.setOpenAtLogin($0) }))
                Toggle("Start transcribing when a call starts", isOn: Binding(
                    get: { settings.autoDetect }, set: { AppModel.shared.setAutoDetect($0) }))
                Button("Review permissions…") { WindowManager.shared.showSetup() }
            }
            Section("Detect calls in") {
                ForEach(CallApp.all) { app in
                    Toggle(app.name, isOn: Binding(
                        get: { settings.enabledApps.contains(app.id) },
                        set: { on in
                            if on { settings.enabledApps.insert(app.id) } else { settings.enabledApps.remove(app.id) }
                        }))
                }
            }
            Section("Transcript") {
                Picker("Language", selection: $settings.localeIdentifier) {
                    Text("System language").tag("")
                    ForEach(locales, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
                Toggle("Include timestamps", isOn: $settings.includeTimestamps)
                Toggle("Remove speaker echo from my microphone", isOn: $settings.removeEcho)
                    .help("Without headphones, your mic hears the other side. This drops those repeats.")
            }
        }
        .formStyle(.grouped)
        .task {
            locales = await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
        }
    }
}

private struct DestinationsTab: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section {
                FolderPicker(title: "Default folder", path: $settings.destinationPath)
            } footer: {
                Text("Every transcript lands here unless a rule below sends it elsewhere.")
            }
            Section {
                ForEach($settings.rules) { $rule in
                    RuleRow(rule: $rule) { settings.rules.removeAll { $0.id == rule.id } }
                }
                Button("Add rule") { settings.rules.append(RoutingRule()) }
            } header: {
                Text("Rules")
            } footer: {
                Text("Rules match the calendar event of the call, top to bottom. The first match wins. Needs calendar access.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct RuleRow: View {
    @Binding var rule: RoutingRule
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $rule.match) {
                    ForEach(RoutingRule.Match.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                if rule.match == .calendar, !CalendarLookup.calendarTitles.isEmpty {
                    Picker("", selection: $rule.value) {
                        Text("Choose a calendar").tag("")
                        ForEach(CalendarLookup.calendarTitles, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                } else {
                    TextField(rule.match == .calendar ? "Calendar name" : "Text in the title", text: $rule.value)
                }
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            FolderPicker(title: "Save to", path: $rule.folderPath)
        }
        .padding(.vertical, 4)
    }
}

private struct SpeakersTab: View {
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: Permissions
    @State private var patternsText = ""

    var body: some View {
        Form {
            Section {
                TextField("My name", text: $settings.myName)
            } footer: {
                Text("Everything from your microphone is labeled with this name.")
            }
            Section("Naming the other side") {
                Toggle("Use the calendar invite", isOn: $settings.useCalendar)
                    .help("On a one-on-one, the other attendee said everything from the call audio.")
                Toggle("Tell voices apart on group calls", isOn: $settings.useDiarization)
                Toggle("Read names from Zoom (Accessibility)", isOn: $settings.useZoomNames)
            }
            Section {
                TextEditor(text: $patternsText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 90)
                    .onChange(of: patternsText) { _, text in
                        settings.zoomPatterns = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    }
                HStack {
                    Button("Reset patterns") {
                        settings.zoomPatterns = ZoomSpeakerWatcher.defaultPatterns
                        patternsText = settings.zoomPatterns.joined(separator: "\n")
                    }
                    Spacer()
                    Button("Save Zoom accessibility snapshot…") { saveSnapshot() }
                        .disabled(!permissions.accessibility.isGranted)
                }
            } header: {
                Text("Zoom talking patterns")
            } footer: {
                Text("One regular expression per line. The first capture group is the speaker's name. If names never show up, take a snapshot during a call and look for the text Zoom shows next to whoever is talking.")
            }
        }
        .formStyle(.grouped)
        .onAppear { patternsText = settings.zoomPatterns.joined(separator: "\n") }
    }

    private func saveSnapshot() {
        let text = ZoomSpeakerWatcher.snapshot()
        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ur.transcribe", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("zoom-accessibility-\(Int(Date().timeIntervalSince1970)).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
