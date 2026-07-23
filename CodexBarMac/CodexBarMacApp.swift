import Sparkle
import SwiftUI

@main
struct CodexBarMacApp: App {
    @StateObject private var model = AppModel()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, updater: updaterController.updater)
        } label: {
            MenuBarLabelContainer(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(model.configurationStore.appAppearance.colorScheme)
        }
    }
}
