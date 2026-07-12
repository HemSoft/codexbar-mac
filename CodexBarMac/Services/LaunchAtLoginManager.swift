import Foundation
import ServiceManagement

@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var lastError: String?

    private let defaults: UserDefaults
    private let preferenceKey = "launchAtLoginEnabled"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: preferenceKey)
        applySavedPreference()
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }

            defaults.set(enabled, forKey: preferenceKey)
            isEnabled = SMAppService.mainApp.status == .enabled
            lastError = nil
        } catch {
            isEnabled = SMAppService.mainApp.status == .enabled
            lastError = error.localizedDescription
        }
    }

    private func applySavedPreference() {
        let preferred = defaults.bool(forKey: preferenceKey)
        let registered = SMAppService.mainApp.status == .enabled

        guard preferred != registered else {
            isEnabled = registered
            return
        }

        setEnabled(preferred)
    }
}
