import Combine
import Foundation
import ServiceManagement

@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var requiresApproval: Bool
    @Published public private(set) var lastError: String?

    deinit {}

    private let defaults: UserDefaults
    private let preferenceKey = "launchAtLoginEnabled"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let status = SMAppService.mainApp.status

        if defaults.object(forKey: preferenceKey) == nil {
            isEnabled = status == .enabled
            requiresApproval = status == .requiresApproval
        } else {
            let preferred = defaults.bool(forKey: preferenceKey)
            if preferred {
                switch status {
                case .enabled:
                    isEnabled = true
                    requiresApproval = false
                case .requiresApproval:
                    isEnabled = false
                    requiresApproval = true
                default:
                    isEnabled = false
                    requiresApproval = false
                    setEnabled(true)
                }
            } else {
                isEnabled = false
                requiresApproval = false
                if Self.shouldUnregister(for: status) {
                    setEnabled(false)
                }
            }
        }
    }

    public func refreshFromSystem() {
        let status = SMAppService.mainApp.status

        if defaults.object(forKey: preferenceKey) == nil {
            isEnabled = status == .enabled
            requiresApproval = status == .requiresApproval
            lastError = nil
            return
        }

        let preferred = defaults.bool(forKey: preferenceKey)
        if preferred {
            switch status {
            case .enabled:
                isEnabled = true
                requiresApproval = false
            case .requiresApproval:
                isEnabled = false
                requiresApproval = true
            default:
                isEnabled = false
                requiresApproval = false
            }
        } else {
            isEnabled = false
            requiresApproval = false
        }

        lastError = nil
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
            syncPublishedStateFromSystem()
            lastError = error.localizedDescription
        }
    }

    private func refreshState(requestedEnabled: Bool) {
        guard requestedEnabled else {
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            defaults.set(true, forKey: preferenceKey)
            isEnabled = true
            requiresApproval = false
            lastError = nil
        case .requiresApproval:
            defaults.set(true, forKey: preferenceKey)
            isEnabled = false
            requiresApproval = true
            lastError = nil
        default:
            defaults.set(false, forKey: preferenceKey)
            isEnabled = false
            requiresApproval = false
            lastError = nil
        }
    }

    private func syncPublishedStateFromSystem() {
        let preferred = defaults.object(forKey: preferenceKey) == nil
            ? nil
            : defaults.bool(forKey: preferenceKey)

        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            isEnabled = false
            requiresApproval = preferred ?? true
        default:
            isEnabled = false
            requiresApproval = false
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
