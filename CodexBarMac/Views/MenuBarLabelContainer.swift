import SwiftUI

struct MenuBarLabelContainer: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarStatusLabel(
            severity: model.mostUrgentSeverity,
            isRefreshEnabled: !model.isRefreshing,
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
