import AppKit
import Combine
import Sparkle

@MainActor
final class SparkleUpdateReminderCoordinator: NSObject, ObservableObject,
    @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var hasPendingScheduledUpdate = false

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func shouldStandardUserDriverHandleScheduledUpdate(inImmediateFocus: Bool) -> Bool {
        inImmediateFocus
    }

    func recordUpdatePresentation(
        standardUserDriverWillHandle: Bool,
        userInitiated: Bool
    ) {
        guard !userInitiated else {
            return
        }

        hasPendingScheduledUpdate = !standardUserDriverWillHandle
    }

    @discardableResult
    func activatePendingUpdate(_ action: () -> Void) -> Bool {
        guard hasPendingScheduledUpdate else {
            return false
        }

        action()
        return true
    }

    func showPendingUpdate(using updater: SPUUpdater) {
        activatePendingUpdate {
            NSApp.activate(ignoringOtherApps: true)
            updater.checkForUpdates()
        }
    }

    func userDidAttendToUpdate() {
        hasPendingScheduledUpdate = false
    }

    func updateSessionDidFinish() {
        hasPendingScheduledUpdate = false
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        shouldStandardUserDriverHandleScheduledUpdate(inImmediateFocus: immediateFocus)
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        recordUpdatePresentation(
            standardUserDriverWillHandle: handleShowingUpdate,
            userInitiated: state.userInitiated
        )
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        userDidAttendToUpdate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateSessionDidFinish()
    }
}
