import Foundation

@MainActor
enum OpenCodeZenBootstrapImporter {
    static let importFileName = "opencode-zen-import.txt"

    static func importIfNeeded(
        configurationStore: ProviderConfigurationStore,
        fileManager: FileManager = .default,
        importDirectory: URL? = nil
    ) {
        let directory = importDirectory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let importURL = directory?.appendingPathComponent(importFileName) else {
            return
        }

        guard fileManager.fileExists(atPath: importURL.path) else {
            return
        }

        defer {
            try? fileManager.removeItem(at: importURL)
        }

        guard
            let data = try? Data(contentsOf: importURL),
            let payload = String(data: data, encoding: .utf8)
        else {
            return
        }

        importPayload(payload, configurationStore: configurationStore)
    }

    @discardableResult
    static func importPayload(
        _ payload: String,
        configurationStore: ProviderConfigurationStore
    ) -> Bool {
        guard let credential = OpenCodeZenUsageProvider.normalizedBalanceCredential(from: payload) else {
            return false
        }

        let existingConfiguration = configurationStore.configurations(for: .openCodeZen).first
        let existingWorkspaceId = OpenCodeZenUsageProvider.normalizedWorkspaceId(
            from: existingConfiguration?.openCodeWorkspaceId
        )
        guard let workspaceId = OpenCodeZenUsageProvider.normalizedWorkspaceId(from: payload) ?? existingWorkspaceId else {
            return false
        }

        var configuration = existingConfiguration ?? .defaultConfiguration(for: .openCodeZen)
        configuration.isEnabled = true
        configuration.authMethod = .apiKey
        configuration.openCodeWorkspaceId = workspaceId
        if configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configuration.accountLabel = "OpenCode ZEN"
        }

        guard configurationStore.update(configuration) else {
            return false
        }

        configurationStore.saveSecret(credential, for: configuration)
        return configurationStore.hasSecret(for: configuration)
    }
}
