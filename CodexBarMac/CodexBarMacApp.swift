import SwiftUI

@main
struct CodexBarMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarStatusLabel(
                severity: model.mostUrgentSeverity,
                onRefresh: {
                    Task {
                        await model.refresh()
                    }
                },
                onOpenSettings: {
                    model.openSettings()
                },
                onQuit: {
                    model.quit()
                }
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPlaceholderView()
        }
    }
}
