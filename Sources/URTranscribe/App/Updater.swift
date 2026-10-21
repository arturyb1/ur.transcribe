import AppKit
import Sparkle

/// In-app updates through Sparkle. The feed lives in the repo (appcast.xml),
/// and every update is signed with the project's EdDSA key, whose public half
/// is in Info.plist, so only genuine releases install.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// Set when a scheduled check found an update but did not interrupt you;
    /// the menu offers it instead.
    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController!
    private var canCheckObservation: NSKeyValueObservation?
    private var pendingRelaunch: (() -> Void)?

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func start() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// Called once a call's transcript is saved, to finish an update that waited for it.
    func callEnded() {
        guard let relaunch = pendingRelaunch else { return }
        pendingRelaunch = nil
        relaunch()
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Never restart in the middle of a call: wait until the transcript is saved.
    nonisolated func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            let busy = [.starting, .recording, .stopping].contains(AppModel.shared.state)
            if busy { pendingRelaunch = installHandler }
            return busy
        }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// ur.transcribe lives in the menu bar, so a scheduled check should not pop
    /// a window over whatever you're doing. The menu shows the update instead.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if !handleShowingUpdate { availableVersion = version }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { availableVersion = nil }
    }
}
