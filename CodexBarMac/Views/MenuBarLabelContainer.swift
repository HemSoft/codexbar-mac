import Sparkle
import SwiftUI

struct MenuBarLabelContainer: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @ObservedObject var updateReminder: SparkleUpdateReminderCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarStatusLabel(
            severity: model.mostUrgentSeverity,
            hasPendingUpdate: updateReminder.hasPendingScheduledUpdate,
            isRefreshEnabled: !model.isRefreshing,
            onShowUpdate: {
                updateReminder.showPendingUpdate(using: updater)
            },
            onRefresh: {
                Task {
                    await model.refresh()
                }
            },
            onOpenSettings: {
                openSettings()
            },
            onQuit: {
                model.quit()
            }
        )
        .task {
            await model.activate()
        }
    }
}
