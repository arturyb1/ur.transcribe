import AppKit
import UserNotifications

/// Tells you when transcription starts and when it's about to stop, with a
/// button on each to change course.
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()

    enum Action: String {
        case discard = "discard"
        case keep = "keep"
        case showTranscript = "show-transcript"
        case reveal = "reveal"
    }

    private enum Category: String {
        case started, ending, saved
    }

    private enum ID {
        static let started = "call-started"
        static let ending = "call-ending"
        static let saved = "call-saved"
    }

    /// Notifications need a real app bundle; the test and snapshot runs have none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        let discard = UNNotificationAction(identifier: Action.discard.rawValue, title: "Don't transcribe this call", options: [.destructive])
        let show = UNNotificationAction(identifier: Action.showTranscript.rawValue, title: "Show transcript", options: [.foreground])
        let keep = UNNotificationAction(identifier: Action.keep.rawValue, title: "Keep transcribing", options: [])
        let reveal = UNNotificationAction(identifier: Action.reveal.rawValue, title: "Show in Finder", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.started.rawValue, actions: [discard, show], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.ending.rawValue, actions: [keep], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.saved.rawValue, actions: [reveal, show], intentIdentifiers: []),
        ])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .notDetermined }
        return await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func callStarted(title: String, reason: String, folder: URL) {
        post(ID.started, category: .started,
             title: "Transcribing \(title)",
             body: "\(reason). Saving to \(folder.lastPathComponent).")
    }

    func callEnding(title: String, reason: String, seconds: Int) {
        remove(ID.started)
        post(ID.ending, category: .ending,
             title: "Stopping in \(seconds) seconds",
             body: "\(reason). The transcript of \(title) will be saved.")
    }

    func callSaved(title: String, file: URL) {
        remove(ID.started, ID.ending)
        post(ID.saved, category: .saved, title: "Transcript saved", body: "\(title), in \(file.deletingLastPathComponent().lastPathComponent).",
             userInfo: ["file": file.path])
    }

    func clearCallNotifications() {
        remove(ID.started, ID.ending)
    }

    func clearEnding() {
        remove(ID.ending)
    }

    private func post(_ id: String, category: Category, title: String, body: String, userInfo: [String: String] = [:]) {
        guard let center, Settings.shared.notifyOnStartStop else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue
        content.userInfo = userInfo
        content.interruptionLevel = .active
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func remove(_ ids: String...) {
        center?.removeDeliveredNotifications(withIdentifiers: ids)
        center?.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show banners even while one of our windows is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let file = response.notification.request.content.userInfo["file"] as? String
        await MainActor.run {
            let model = AppModel.shared
            switch Action(rawValue: action) {
            case .discard: model.discardCurrentCall()
            case .keep: model.keepTranscribing()
            case .showTranscript: WindowManager.shared.showTranscript()
            case .reveal: if let file { model.reveal(URL(fileURLWithPath: file)) }
            case nil:
                // Clicking the notification itself opens the transcript.
                if action == UNNotificationDefaultActionIdentifier, category != Category.ending.rawValue {
                    WindowManager.shared.showTranscript()
                }
            }
        }
    }
}
