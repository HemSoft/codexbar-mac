import Combine
import Foundation
import ServiceManagement

@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var requiresApproval: Bool
    @Published public private(set) var lastError: String?

    private let defaults: UserDefaults
    private let preferenceKey = "launchAtLoginEnabled"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = SMAppService.mainApp.status == .enabled
        self.requiresApproval = SMAppService.mainApp.status == .requiresApproval

        if defaults.object(forKey: preferenceKey) != nil {
            let preferred = defaults.bool(forKey: preferenceKey)
            if preferred {
                setEnabled(true)
            } else if Self.shouldUnregister(for: SMAppService.mainApp.status) {
                setEnabled(false)
            }
        }
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                }
                refreshState(requestedEnabled: true)
            } else {
                if Self.shouldUnregister(for: SMAppService.mainApp.status) {
                    try SMAppService.mainApp.unregister()
                }
                defaults.set(false, forKey: preferenceKey)
                isEnabled = false
                requiresApproval = false
                lastError = nil
            }
        } catch {
            refreshState(requestedEnabled: defaults.bool(forKey: preferenceKey))
            lastError = error.localizedDescription
        }
    }

    private func refreshState(requestedEnabled: Bool) {
        switch SMAppService.mainApp.status {
        case .enabled:
            defaults.set(true, forKey: preferenceKey)
            isEnabled = true
            requiresApproval = false
            lastError = nil
        case .requiresApproval:
            defaults.set(false, forKey: preferenceKey)
            isEnabled = false
            requiresApproval = requestedEnabled
            lastError = nil
        default:
            defaults.set(false, forKey: preferenceKey)
            isEnabled = false
            requiresApproval = false
            lastError = nil
        }
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
