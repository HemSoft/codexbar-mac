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
            } else if Self.shouldUnregister(for: SMAppService.mainApp.status) {
                try SMAppService.mainApp.unregister()
            }

            defaults.set(enabled, forKey: preferenceKey)
            isEnabled = enabled
            lastError = nil
        } catch {
            isEnabled = defaults.bool(forKey: preferenceKey)
            lastError = error.localizedDescription
        }
    }

    private func applySavedPreference() {
        setEnabled(defaults.bool(forKey: preferenceKey))
    }

    private static func shouldUnregister(for status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            true
        default:
            false
        }
    }
}
