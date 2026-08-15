import Sparkle
import SwiftUI

@main
struct CodexBarMacApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updateReminder: SparkleUpdateReminderCoordinator
    private let updaterController: SPUStandardUpdaterController

    init() {
        let updateReminder = SparkleUpdateReminderCoordinator()
        _updateReminder = StateObject(wrappedValue: updateReminder)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: updateReminder
        )
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                model: model,
                updater: updaterController.updater,
                updateReminder: updateReminder
            )
        } label: {
            MenuBarLabelContainer(
                model: model,
                updater: updaterController.updater,
                updateReminder: updateReminder
            )
        }
        .menuBarExtraStyle(.window)

        Window("CodexBar Dashboard", id: "dashboard") {
            DashboardView(
                model: model,
                updater: updaterController.updater,
                updateReminder: updateReminder,
                presentation: .detached
            )
            .preferredColorScheme(model.configurationStore.appAppearance.colorScheme)
        }
        .defaultSize(width: 360, height: 520)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(model.configurationStore.appAppearance.colorScheme)
        }
    }
}
