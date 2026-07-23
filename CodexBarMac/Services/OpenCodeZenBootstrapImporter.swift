import Foundation

@MainActor
enum OpenCodeZenBootstrapImporter {
    static let importFileName = "opencode-zen-import.txt"

    static func importIfNeeded(
        configurationStore: ProviderConfigurationStore,
        fileManager: FileManager = .default,
        importDirectory: URL? = nil,
        readData: (URL) throws -> Data = { try Data(contentsOf: $0) }
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

        guard protectImportFile(at: importURL, fileManager: fileManager) else {
            return
        }

        guard
            let data = try? readData(importURL),
            let payload = String(data: data, encoding: .utf8)
        else {
            return
        }

        importPayload(payload, configurationStore: configurationStore)
    }

    @discardableResult
    static func protectImportFile(
        at importURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: importURL.path
            )
            return true
        } catch {
            return false
        }
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
        guard configurationStore.lastError == nil else {
            return false
        }

        guard configurationStore.readSavedSecret(for: configuration) == credential else {
            return false
        }

        return true
    }
}
