import Combine
import Foundation

@MainActor
public final class ProviderConfigurationStore: ObservableObject {
    @Published public private(set) var configurations: [ProviderAccountConfiguration]
    @Published public private(set) var groups: [ProviderAccountGroup]
    @Published public private(set) var secretAvailability: [String: Bool]
    @Published public private(set) var secretReadErrors: [String: String]
    @Published public private(set) var localCredentialHints: [String: String]
    @Published public private(set) var appAppearance: AppAppearance
    @Published public private(set) var autoRefreshInterval: AutoRefreshInterval
    @Published public private(set) var dashboardOrderingMode: DashboardOrderingMode
    @Published public private(set) var usageAlertSettings: UsageAlertSettings
    @Published public private(set) var usageAlertActiveIDs: Set<String>
    @Published public private(set) var isConfigurationRecoveryRequired: Bool
    @Published public private(set) var isGroupRecoveryRequired: Bool
    @Published public private(set) var lastError: String?

    private let defaults: UserDefaults
    private let secretStore: any SecretStore
    private let encodeConfigurations: ([ProviderAccountConfiguration]) throws -> Data
    private let persistConfigurations: (Data) throws -> Void
    private let configurationsKey = DefaultsKey.configurations
    private let groupsKey = DefaultsKey.groups
    private let appAppearanceKey = DefaultsKey.appAppearance
    private let autoRefreshIntervalKey = DefaultsKey.autoRefreshInterval
    private let dashboardOrderingModeKey = DefaultsKey.dashboardOrderingMode
    private let usageAlertSettingsKey = DefaultsKey.usageAlertSettings
    private let usageAlertActiveIDsKey = DefaultsKey.usageAlertActiveIDs
    private let suppressedCopilotDiscoveryUsernamesKey = DefaultsKey.suppressedCopilotDiscoveryUsernames
    private let suppressedGeminiDiscoveryKey = DefaultsKey.suppressedGeminiDiscovery
    private var secretAvailabilityGeneration = 0

    deinit {}

    public convenience init(
        defaults: UserDefaults = .standard,
        secretStore: any SecretStore = KeychainService()
    ) {
        self.init(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) }
        )
    }

    init(
        defaults: UserDefaults,
        secretStore: any SecretStore,
        encodeConfigurations: @escaping ([ProviderAccountConfiguration]) throws -> Data,
        persistConfigurations: ((Data) throws -> Void)? = nil
    ) {
        let groupLoadResult = Self.loadGroups(from: defaults)
        let configurationLoadResult = Self.loadConfigurations(
            from: defaults,
            validGroupIDs: groupLoadResult.error == nil
                ? Set(groupLoadResult.groups.map(\.id))
                : nil
        )
        self.defaults = defaults
        self.secretStore = secretStore
        self.encodeConfigurations = encodeConfigurations
        self.persistConfigurations = persistConfigurations ?? { data in
            defaults.set(data, forKey: DefaultsKey.configurations)
        }
        self.groups = groupLoadResult.groups
        self.configurations = configurationLoadResult.configurations
        self.secretAvailability = [:]
        self.secretReadErrors = [:]
        self.localCredentialHints = [:]
        self.appAppearance = Self.loadAppAppearance(from: defaults)
        self.autoRefreshInterval = Self.loadAutoRefreshInterval(from: defaults)
        self.dashboardOrderingMode = Self.loadDashboardOrderingMode(from: defaults)
        self.usageAlertSettings = Self.loadUsageAlertSettings(from: defaults)
        self.usageAlertActiveIDs = Self.loadUsageAlertActiveIDs(from: defaults)
        self.isConfigurationRecoveryRequired = configurationLoadResult.error != nil
        self.isGroupRecoveryRequired = groupLoadResult.error != nil
        self.lastError = configurationLoadResult.error ?? groupLoadResult.error
        sortConfigurations()
        refreshSecretAvailability()
    }

    public var isPersistenceRecoveryRequired: Bool {
        isConfigurationRecoveryRequired || isGroupRecoveryRequired
    }

    public var enabledConfigurations: [ProviderAccountConfiguration] {
        configurations.filter(\.isEnabled)
    }

    public func seedDefaultConfigurationsIfNeeded() {
        guard defaults.object(forKey: configurationsKey) == nil,
              allowConfigurationMutation()
        else {
            return
        }

        let previousConfigurations = configurations
        configurations = ProviderID.allCases.map(ProviderAccountConfiguration.defaultConfiguration)
        sortConfigurations()
        if !saveConfigurations() {
            configurations = previousConfigurations
        }
        refreshSecretAvailability()
    }

    public func configuration(for providerID: ProviderID) -> ProviderAccountConfiguration {
        configurations.first { $0.providerID == providerID }
            ?? .defaultConfiguration(for: providerID)
    }

    public func configuration(accountID: String) -> ProviderAccountConfiguration? {
        configurations.first { $0.id == accountID }
    }

    public func configurations(for providerID: ProviderID) -> [ProviderAccountConfiguration] {
        configurations.filter { $0.providerID == providerID }
    }

    public func group(for groupID: String?) -> ProviderAccountGroup? {
        guard let groupID else {
            return nil
        }

        return groups.first { $0.id == groupID }
    }

    public func groupName(for groupID: String?) -> String {
        group(for: groupID)?.name ?? ProviderAccountGroup.ungroupedDisplayName
    }

    @discardableResult
    public func addGroup(named name: String) -> ProviderAccountGroup? {
        guard allowConfigurationMutation() else {
            return nil
        }

        let normalizedName = Self.normalizedGroupName(name)
        guard !normalizedName.isEmpty else {
            lastError = "Group names cannot be empty."
            return nil
        }

        guard isGroupNameUnique(normalizedName) else {
            lastError = "Group names must be unique."
            return nil
        }

        let group = ProviderAccountGroup(name: normalizedName)
        groups.append(group)
        sortGroups()
        saveGroups()
        return group
    }

    @discardableResult
    public func updateGroup(_ group: ProviderAccountGroup) -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        let previousGroups = groups
        let previousConfigurations = configurations
        let normalizedName = Self.normalizedGroupName(group.name)
        guard !normalizedName.isEmpty else {
            lastError = "Group names cannot be empty."
            return false
        }

        guard isGroupNameUnique(normalizedName, excluding: group.id) else {
            lastError = "Group names must be unique."
            return false
        }

        guard let index = groups.firstIndex(where: { $0.id == group.id }) else {
            lastError = "Group no longer exists."
            return false
        }

        groups[index].name = normalizedName
        sortGroups()
        sortConfigurations()
        guard saveConfigurations() else {
            groups = previousGroups
            configurations = previousConfigurations
            return false
        }
        saveGroups()
        return true
    }

    public func removeGroup(_ group: ProviderAccountGroup) {
        guard allowConfigurationMutation() else {
            return
        }

        let previousGroups = groups
        let previousConfigurations = configurations
        groups.removeAll { $0.id == group.id }
        configurations = configurations.map { configuration in
            var updated = configuration
            if updated.groupID == group.id {
                updated.groupID = nil
            }
            return updated
        }
        sortGroups()
        sortConfigurations()
        guard saveConfigurations() else {
            groups = previousGroups
            configurations = previousConfigurations
            return
        }
        saveGroups()
    }

    @discardableResult
    public func addAccount(for providerID: ProviderID) -> ProviderAccountConfiguration {
        addAccount(for: providerID, copilotScope: .personal)
    }

    @discardableResult
    public func addAccount(
        for providerID: ProviderID,
        copilotScope: CopilotAccountScope
    ) -> ProviderAccountConfiguration {
        let defaultConfiguration = ProviderAccountConfiguration.defaultConfiguration(for: providerID)
        var configuration = defaultConfiguration.withNewAccountID()
        if providerID == .copilot {
            configuration.copilotAccountScope = copilotScope
        }
        configuration.accountLabel = suggestedAccountLabel(for: providerID)
        guard allowConfigurationMutation() else {
            return configuration
        }

        if shouldReuseDefaultAccountID(for: providerID) {
            configuration = defaultConfiguration
            if providerID == .copilot {
                configuration.copilotAccountScope = copilotScope
            }
            configuration.accountLabel = suggestedAccountLabel(for: providerID)
        }

        if providerID == .gemini {
            clearSuppressedGeminiDiscovery()
        }

        let previousConfigurations = configurations
        configurations.append(configuration)
        sortConfigurations()
        if !saveConfigurations() {
            configurations = previousConfigurations
        }
        refreshSecretAvailability()
        return configuration
    }

    @discardableResult
    public func update(_ configuration: ProviderAccountConfiguration) -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        let normalized = Self.normalizedConfiguration(
            configuration,
            validGroupIDs: Set(groups.map(\.id))
        )
        guard isAccountNameUnique(normalized) else {
            lastError = "Account names must be unique."
            return false
        }

        let previousConfigurations = configurations
        if let index = configurations.firstIndex(where: { $0.id == normalized.id }) {
            configurations[index] = normalized
        } else {
            configurations.append(normalized)
        }

        sortConfigurations()
        guard saveConfigurations() else {
            configurations = previousConfigurations
            return false
        }
        return true
    }

    @discardableResult
    public func replaceCredential(
        _ credential: String,
        for configuration: ProviderAccountConfiguration
    ) -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        let normalized = Self.normalizedConfiguration(
            configuration,
            validGroupIDs: Set(groups.map(\.id))
        )
        guard isAccountNameUnique(normalized) else {
            lastError = "Account names must be unique."
            return false
        }

        var updatedConfigurations = configurations
        if let index = updatedConfigurations.firstIndex(where: { $0.id == normalized.id }) {
            updatedConfigurations[index] = normalized
        } else {
            updatedConfigurations.append(normalized)
        }
        updatedConfigurations = sortedConfigurations(updatedConfigurations)

        let previousData: Data
        let updatedData: Data
        do {
            previousData = try encodeConfigurations(configurations)
            updatedData = try encodeConfigurations(updatedConfigurations)
        } catch {
            lastError = "Could not save account data: \(error.localizedDescription)"
            return false
        }

        let account = Self.keychainAccount(for: normalized)
        let previousCredential: String?
        do {
            previousCredential = try secretStore.readSecret(account: account)
        } catch {
            lastError = error.localizedDescription
            return false
        }

        do {
            try writeCredential(credential, account: account)
        } catch {
            let firstError = error.localizedDescription
            try? writeCredential(previousCredential, account: account)
            lastError = firstError
            refreshSecretAvailability(including: [normalized])
            return false
        }

        do {
            try persistConfigurations(updatedData)
        } catch {
            let firstError = "Could not save account data: \(error.localizedDescription)"
            try? writeCredential(previousCredential, account: account)
            try? persistConfigurations(previousData)
            lastError = firstError
            refreshSecretAvailability(including: [normalized])
            return false
        }

        configurations = updatedConfigurations
        lastError = nil
        refreshSecretAvailability(including: [normalized])
        return true
    }

    public func removeAccount(_ configuration: ProviderAccountConfiguration) {
        removeAccounts([configuration])
    }

    @discardableResult
    public func removeAccounts(_ configurations: [ProviderAccountConfiguration]) -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        var removedAnyAccount = false
        var firstDeletionError: String?

        for configuration in configurations {
            let remainingConfigurations = self.configurations.filter { $0.id != configuration.id }
            let encodedConfigurations: Data
            do {
                encodedConfigurations = try encodeConfigurations(remainingConfigurations)
            } catch {
                if firstDeletionError == nil {
                    firstDeletionError = "Could not save account data: \(error.localizedDescription)"
                }
                continue
            }

            do {
                try secretStore.deleteSecret(account: Self.keychainAccount(for: configuration))
            } catch {
                if firstDeletionError == nil {
                    firstDeletionError = error.localizedDescription
                }
                continue
            }

            rememberSuppressedCopilotDiscovery(for: configuration)
            rememberSuppressedGeminiDiscovery(for: configuration)
            defaults.set(encodedConfigurations, forKey: configurationsKey)
            self.configurations = remainingConfigurations
            secretAvailability.removeValue(forKey: configuration.id)
            secretReadErrors.removeValue(forKey: configuration.id)
            localCredentialHints.removeValue(forKey: configuration.id)
            removedAnyAccount = true
        }

        lastError = firstDeletionError
        refreshSecretAvailability()
        return removedAnyAccount
    }

    public func updateAppAppearance(_ appearance: AppAppearance) {
        appAppearance = appearance
        defaults.set(appearance.rawValue, forKey: appAppearanceKey)
    }

    public func updateAutoRefreshInterval(_ interval: AutoRefreshInterval) {
        autoRefreshInterval = interval
        defaults.set(interval.rawValue, forKey: autoRefreshIntervalKey)
    }

    public func updateDashboardOrderingMode(_ mode: DashboardOrderingMode) {
        dashboardOrderingMode = mode
        defaults.set(mode.rawValue, forKey: dashboardOrderingModeKey)
    }

    public func updateUsageAlertSettings(_ settings: UsageAlertSettings) {
        let previousSettings = usageAlertSettings
        usageAlertSettings = settings
        saveUsageAlertSettings()

        if settings != previousSettings {
            updateUsageAlertActiveIDs([])
        }
    }

    public func updateUsageAlertsEnabled(_ isEnabled: Bool) {
        var settings = usageAlertSettings
        settings.isEnabled = isEnabled
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertUsageThreshold(_ threshold: Double) {
        var settings = usageAlertSettings
        settings.usageThreshold = UsageAlertSettings.normalizedUsageThreshold(threshold)
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertBalanceThreshold(_ threshold: Double) {
        var settings = usageAlertSettings
        settings.balanceThreshold = UsageAlertSettings.normalizedBalanceThreshold(threshold)
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertIncludesSeverityAlerts(_ includesSeverityAlerts: Bool) {
        var settings = usageAlertSettings
        settings.includesSeverityAlerts = includesSeverityAlerts
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertActiveIDs(_ activeIDs: Set<String>) {
        usageAlertActiveIDs = activeIDs
        defaults.set(Array(activeIDs).sorted(), forKey: usageAlertActiveIDsKey)
    }

    public func cursorAccountLabelAfterIdentityChange(for configuration: ProviderAccountConfiguration) -> String {
        guard configuration.providerID == .cursor else {
            return configuration.accountLabel
        }

        let currentLabel = configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentLabel.isEmpty || Self.looksLikeEmailAddress(currentLabel) else {
            return configuration.accountLabel
        }

        let base = ProviderID.cursor.displayName
        let otherNames = configurations
            .filter { $0.id != configuration.id }
            .map(\.displayName)
        if !otherNames.contains(where: { $0.localizedCaseInsensitiveCompare(base) == .orderedSame }) {
            return ""
        }

        var index = 2
        while otherNames.contains(where: {
            $0.localizedCaseInsensitiveCompare("\(base) \(index)") == .orderedSame
        }) {
            index += 1
        }
        return "\(base) \(index)"
    }

    @discardableResult
    public func connectCursorAccount(
        _ configuration: ProviderAccountConfiguration,
        credential: String
    ) -> ProviderAccountConfiguration? {
        guard allowConfigurationMutation() else {
            return nil
        }

        guard configuration.providerID == .cursor else {
            lastError = "Only Cursor accounts can be connected here."
            return nil
        }

        var connectedConfiguration = configuration
        connectedConfiguration.accountLabel = cursorAccountLabelAfterIdentityChange(for: configuration)
        connectedConfiguration.authMethod = .browserSession
        guard isAccountNameUnique(connectedConfiguration) else {
            lastError = "Account names must be unique."
            return nil
        }

        do {
            try secretStore.saveSecret(credential, account: Self.keychainAccount(for: configuration))
        } catch {
            lastError = error.localizedDescription
            return nil
        }

        guard update(connectedConfiguration) else {
            refreshSecretAvailability()
            return nil
        }
        lastError = nil
        refreshSecretAvailability()
        return connectedConfiguration
    }

    @discardableResult
    public func disconnectCursorAccount(
        _ configuration: ProviderAccountConfiguration
    ) -> ProviderAccountConfiguration? {
        guard allowConfigurationMutation() else {
            return nil
        }

        guard configuration.providerID == .cursor else {
            lastError = "Only Cursor accounts can be disconnected here."
            return nil
        }

        do {
            try secretStore.deleteSecret(account: Self.keychainAccount(for: configuration))
        } catch {
            lastError = error.localizedDescription
            return nil
        }

        var disconnectedConfiguration = configuration
        disconnectedConfiguration.accountLabel = cursorAccountLabelAfterIdentityChange(for: configuration)
        guard update(disconnectedConfiguration) else {
            refreshSecretAvailability()
            return nil
        }

        lastError = nil
        refreshSecretAvailability()
        return disconnectedConfiguration
    }

    public func saveSecret(_ secret: String, for configuration: ProviderAccountConfiguration) {
        guard allowConfigurationMutation() else {
            return
        }

        do {
            if secret.isEmpty {
                try secretStore.deleteSecret(account: Self.keychainAccount(for: configuration))
                secretAvailability[configuration.id] = false
            } else {
                try secretStore.saveSecret(secret, account: Self.keychainAccount(for: configuration))
                secretAvailability[configuration.id] = true
            }

            secretReadErrors.removeValue(forKey: configuration.id)
            lastError = nil
            refreshSecretAvailability(including: [configuration])
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func readSavedSecret(for configuration: ProviderAccountConfiguration) -> String? {
        try? secretStore.readSecret(account: Self.keychainAccount(for: configuration))
    }

    public func hasSecret(for configuration: ProviderAccountConfiguration) -> Bool {
        secretAvailability[configuration.id] ?? false
    }

    public func credentialReadiness(for configuration: ProviderAccountConfiguration) -> CredentialReadiness {
        if hasSecret(for: configuration) {
            return .keychainSaved
        }

        if let hint = localCredentialHints[configuration.id] {
            return .localCLIReady(description: hint)
        }

        if let error = secretReadErrors[configuration.id] {
            return .error(description: error)
        }

        return .missing
    }

    public func applyLocalCredentialDiscoveries(
        _ discovery: LocalCredentialDiscovery.Result = LocalCredentialDiscovery.discover()
    ) {
        guard allowConfigurationMutation() else {
            return
        }

        let previousConfigurations = configurations
        let previousHints = localCredentialHints
        var nextHints: [String: String] = [:]

        if discovery.codexAuthAvailable {
            for index in configurations.indices where configurations[index].providerID == .codex {
                if shouldApplyLocalAuthMethod(
                    current: configurations[index].authMethod,
                    localMethod: .codexAuthJSON,
                    providerID: .codex
                ) {
                    configurations[index].authMethod = .codexAuthJSON
                    nextHints[configurations[index].id] = "~/.codex/auth.json"
                } else if configurations[index].authMethod == .codexAuthJSON {
                    nextHints[configurations[index].id] = "~/.codex/auth.json"
                }
            }
        }

        for username in discovery.githubUsernames {
            guard !isSuppressedCopilotDiscoveryUsername(username) else {
                continue
            }

            if let index = configurations.firstIndex(where: {
                $0.providerID == .copilot
                    && (
                        $0.githubCLIUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                            .localizedCaseInsensitiveCompare(username) == .orderedSame
                        || $0.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                            .localizedCaseInsensitiveCompare(username) == .orderedSame
                    )
            }) {
                if shouldApplyLocalAuthMethod(
                    current: configurations[index].authMethod,
                    localMethod: .cliToken,
                    providerID: .copilot
                ) {
                    configurations[index].authMethod = .cliToken
                }
                configurations[index].githubCLIUsername = username

                if configurations[index].authMethod == .cliToken {
                    nextHints[configurations[index].id] = "GitHub CLI (\(username))"
                }
                continue
            }

            if let index = unusedDefaultCopilotAccountIndex() {
                configurations[index].accountLabel = uniqueAccountLabel(
                    preferred: username,
                    for: configurations[index]
                )
                configurations[index].authMethod = .cliToken
                configurations[index].githubCLIUsername = username
                nextHints[configurations[index].id] = "GitHub CLI (\(username))"
                continue
            }

            let defaultConfiguration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
            var configuration = shouldReuseDefaultAccountID(for: .copilot)
                ? defaultConfiguration
                : defaultConfiguration.withNewAccountID()
            configuration.accountLabel = uniqueAccountLabel(preferred: username, for: configuration)
            configuration.authMethod = .cliToken
            configuration.githubCLIUsername = username
            configurations.append(configuration)
            nextHints[configuration.id] = "GitHub CLI (\(username))"
        }

        if discovery.claudeOAuthAvailable {
            let claudeCredentialHint = discovery.claudeCredentialSource ?? "~/.claude/.credentials.json"
            for index in configurations.indices where configurations[index].providerID == .claude {
                if shouldApplyLocalAuthMethod(
                    current: configurations[index].authMethod,
                    localMethod: .oauth,
                    providerID: .claude
                ) {
                    configurations[index].authMethod = .oauth
                    nextHints[configurations[index].id] = claudeCredentialHint
                } else if configurations[index].authMethod == .oauth {
                    nextHints[configurations[index].id] = claudeCredentialHint
                }
            }
        }

        if discovery.cursorSessionAvailable {
            let cursorCredentialHint = "~/Library/Application Support/Cursor/auth.json"
            for index in configurations.indices where configurations[index].providerID == .cursor {
                if shouldApplyLocalAuthMethod(
                    current: configurations[index].authMethod,
                    localMethod: .browserSession,
                    providerID: .cursor
                ) {
                    configurations[index].authMethod = .browserSession
                    nextHints[configurations[index].id] = cursorCredentialHint
                } else if configurations[index].authMethod == .browserSession {
                    nextHints[configurations[index].id] = cursorCredentialHint
                }
            }
        }

        if discovery.geminiOAuthAvailable {
            let geminiCredentialHint = "~/.gemini/oauth_creds.json"
            if !configurations.contains(where: { $0.providerID == .gemini }),
               !isGeminiDiscoverySuppressed() {
                configurations.append(.defaultConfiguration(for: .gemini))
            }

            for index in configurations.indices where configurations[index].providerID == .gemini {
                if shouldApplyLocalAuthMethod(
                    current: configurations[index].authMethod,
                    localMethod: .oauth,
                    providerID: .gemini
                ) {
                    configurations[index].authMethod = .oauth
                    nextHints[configurations[index].id] = geminiCredentialHint
                } else if configurations[index].authMethod == .oauth {
                    nextHints[configurations[index].id] = geminiCredentialHint
                }
            }
        }

        localCredentialHints = nextHints
        sortConfigurations()
        if !saveConfigurations() {
            configurations = previousConfigurations
            localCredentialHints = previousHints
        }
        refreshSecretAvailability()
    }

    public func refreshSecretAvailability(
        including additional: [ProviderAccountConfiguration] = []
    ) {
        var snapshot = configurations
        for configuration in additional where !snapshot.contains(where: { $0.id == configuration.id }) {
            snapshot.append(configuration)
        }

        let store = secretStore
        let persistedSnapshotIDs = Set(configurations.map(\.id))
        secretAvailabilityGeneration += 1
        let generation = secretAvailabilityGeneration

        Task.detached(priority: .utility) {
            var availability: [String: Bool] = [:]
            var readErrors: [String: String] = [:]
            for configuration in snapshot {
                let account = ProviderConfigurationStore.keychainAccount(for: configuration)
                do {
                    availability[configuration.id] = try store.readSecret(account: account) != nil
                } catch {
                    availability[configuration.id] = false
                    readErrors[configuration.id] = error.localizedDescription
                }
            }

            await MainActor.run { [weak self] in
                guard let self, self.secretAvailabilityGeneration == generation else {
                    return
                }

                var nextAvailability = self.secretAvailability
                var nextReadErrors = self.secretReadErrors
                let currentPersistedIDs = Set(self.configurations.map(\.id))
                for accountID in nextAvailability.keys
                    where persistedSnapshotIDs.contains(accountID) && !currentPersistedIDs.contains(accountID) {
                    nextAvailability.removeValue(forKey: accountID)
                }
                for accountID in nextReadErrors.keys
                    where persistedSnapshotIDs.contains(accountID) && !currentPersistedIDs.contains(accountID) {
                    nextReadErrors.removeValue(forKey: accountID)
                }

                for (accountID, isAvailable) in availability {
                    nextAvailability[accountID] = isAvailable
                    nextReadErrors.removeValue(forKey: accountID)
                }
                for (accountID, readError) in readErrors {
                    nextReadErrors[accountID] = readError
                }

                self.secretAvailability = nextAvailability
                self.secretReadErrors = nextReadErrors
            }
        }
    }

    public nonisolated static func keychainAccount(for providerID: ProviderID) -> String {
        "provider.\(providerID.rawValue).credential"
    }

    public nonisolated static func keychainAccount(for configuration: ProviderAccountConfiguration) -> String {
        if configuration.id == configuration.providerID.rawValue {
            return keychainAccount(for: configuration.providerID)
        }

        return "providerAccount.\(configuration.id).credential"
    }

    @discardableResult
    public func replaceCorruptedConfigurations() -> Bool {
        guard isConfigurationRecoveryRequired else {
            return false
        }

        let replacement: [ProviderAccountConfiguration] = []
        do {
            let data = try encodeConfigurations(replacement)
            defaults.set(data, forKey: configurationsKey)
            configurations = replacement
            secretAvailability = [:]
            secretReadErrors = [:]
            localCredentialHints = [:]
            isConfigurationRecoveryRequired = false
            lastError = isGroupRecoveryRequired ? Self.groupLoadErrorMessage : nil
            return true
        } catch {
            lastError = "Could not replace damaged account data: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    public func replaceCorruptedGroups() -> Bool {
        guard isGroupRecoveryRequired else {
            return false
        }

        let replacementGroups: [ProviderAccountGroup] = []
        let replacementConfigurations = configurations.map { configuration in
            var ungrouped = configuration
            ungrouped.groupID = nil
            return ungrouped
        }

        do {
            let groupData = try JSONEncoder().encode(replacementGroups)
            let configurationData = try encodeConfigurations(replacementConfigurations)
            defaults.set(groupData, forKey: groupsKey)
            if !isConfigurationRecoveryRequired {
                defaults.set(configurationData, forKey: configurationsKey)
                configurations = replacementConfigurations
                sortConfigurations()
            }
            groups = replacementGroups
            isGroupRecoveryRequired = false
            lastError = isConfigurationRecoveryRequired
                ? Self.configurationLoadErrorMessage
                : nil
            return true
        } catch {
            lastError = "Could not replace damaged group data: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func saveConfigurations() -> Bool {
        guard allowConfigurationMutation() else {
            return false
        }

        do {
            let data = try encodeConfigurations(configurations)
            try persistConfigurations(data)
            lastError = nil
            return true
        } catch {
            lastError = "Could not save account data: \(error.localizedDescription)"
            return false
        }
    }

    private func allowConfigurationMutation() -> Bool {
        if isConfigurationRecoveryRequired {
            lastError = Self.configurationLoadErrorMessage
            return false
        }

        if isGroupRecoveryRequired {
            lastError = Self.groupLoadErrorMessage
            return false
        }

        return true
    }

    private func saveGroups() {
        guard allowConfigurationMutation() else {
            return
        }

        do {
            let data = try JSONEncoder().encode(groups)
            defaults.set(data, forKey: groupsKey)
            if !isPersistenceRecoveryRequired {
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private enum DefaultsKey {
        static let configurations = "providerConfigurations"
        static let groups = "providerAccountGroups"
        static let appAppearance = "appAppearance"
        static let autoRefreshInterval = "autoRefreshInterval"
        static let dashboardOrderingMode = "dashboardOrderingMode"
        static let usageAlertSettings = "usageAlertSettings"
        static let usageAlertActiveIDs = "usageAlertActiveIDs"
        static let suppressedCopilotDiscoveryUsernames = "suppressedCopilotDiscoveryUsernames"
        static let suppressedGeminiDiscovery = "suppressedGeminiDiscovery"
    }

    private struct ConfigurationLoadResult {
        let configurations: [ProviderAccountConfiguration]
        let error: String?
    }

    private struct GroupLoadResult {
        let groups: [ProviderAccountGroup]
        let error: String?
    }

    private static let configurationLoadErrorMessage =
        "Saved account data couldn't be read. Replace the damaged account list in Settings to resume saving configurations."
    private static let groupLoadErrorMessage =
        "Saved group data couldn't be read. Replace the damaged group list in Settings to resume saving accounts and groups."

    private static func loadConfigurations(
        from defaults: UserDefaults,
        validGroupIDs: Set<String>? = nil
    ) -> ConfigurationLoadResult {
        guard defaults.object(forKey: DefaultsKey.configurations) != nil else {
            return ConfigurationLoadResult(configurations: [], error: nil)
        }

        guard let data = defaults.data(forKey: DefaultsKey.configurations) else {
            return ConfigurationLoadResult(
                configurations: [],
                error: configurationLoadErrorMessage
            )
        }

        let decoded: [ProviderAccountConfiguration]
        do {
            decoded = try JSONDecoder().decode([ProviderAccountConfiguration].self, from: data)
        } catch {
            return ConfigurationLoadResult(
                configurations: [],
                error: configurationLoadErrorMessage
            )
        }

        return ConfigurationLoadResult(
            configurations: decoded
                .map { normalizedConfiguration($0, validGroupIDs: validGroupIDs) }
                .sorted { configurationSort($0, $1) },
            error: nil
        )
    }

    private static func loadGroups(from defaults: UserDefaults) -> GroupLoadResult {
        guard defaults.object(forKey: DefaultsKey.groups) != nil else {
            return GroupLoadResult(groups: [], error: nil)
        }

        guard let data = defaults.data(forKey: DefaultsKey.groups) else {
            return GroupLoadResult(groups: [], error: groupLoadErrorMessage)
        }

        let decoded: [ProviderAccountGroup]
        do {
            decoded = try JSONDecoder().decode([ProviderAccountGroup].self, from: data)
        } catch {
            return GroupLoadResult(groups: [], error: groupLoadErrorMessage)
        }

        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        let groups = decoded.compactMap { group in
            let name = normalizedGroupName(group.name)
            let nameKey = name.lowercased()
            guard !name.isEmpty,
                  seenIDs.insert(group.id).inserted,
                  seenNames.insert(nameKey).inserted
            else {
                return nil
            }

            return ProviderAccountGroup(id: group.id, name: name)
        }
        .sorted(by: groupSort)

        return GroupLoadResult(groups: groups, error: nil)
    }

    private static func loadAppAppearance(from defaults: UserDefaults) -> AppAppearance {
        guard
            let rawValue = defaults.string(forKey: DefaultsKey.appAppearance),
            let appearance = AppAppearance(rawValue: rawValue)
        else {
            return .system
        }

        return appearance
    }

    private static func loadAutoRefreshInterval(from defaults: UserDefaults) -> AutoRefreshInterval {
        guard
            defaults.object(forKey: DefaultsKey.autoRefreshInterval) != nil,
            let interval = AutoRefreshInterval(rawValue: defaults.integer(forKey: DefaultsKey.autoRefreshInterval))
        else {
            return .off
        }

        return interval
    }

    private static func loadDashboardOrderingMode(from defaults: UserDefaults) -> DashboardOrderingMode {
        guard
            let rawValue = defaults.string(forKey: DefaultsKey.dashboardOrderingMode),
            let mode = DashboardOrderingMode(rawValue: rawValue)
        else {
            return .manual
        }

        return mode
    }

    private func saveUsageAlertSettings() {
        do {
            let data = try JSONEncoder().encode(usageAlertSettings)
            defaults.set(data, forKey: usageAlertSettingsKey)
            if !isPersistenceRecoveryRequired {
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func loadUsageAlertSettings(from defaults: UserDefaults) -> UsageAlertSettings {
        guard
            let data = defaults.data(forKey: DefaultsKey.usageAlertSettings),
            let settings = try? JSONDecoder().decode(UsageAlertSettings.self, from: data)
        else {
            return UsageAlertSettings()
        }

        return settings
    }

    private static func loadUsageAlertActiveIDs(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: DefaultsKey.usageAlertActiveIDs) ?? [])
    }

    private static func normalizedConfiguration(
        _ configuration: ProviderAccountConfiguration,
        validGroupIDs: Set<String>? = nil
    ) -> ProviderAccountConfiguration {
        var normalized = configuration
        if let validGroupIDs, let groupID = normalized.groupID, !validGroupIDs.contains(groupID) {
            normalized.groupID = nil
        }

        return normalized
    }

    private func sortConfigurations() {
        configurations = sortedConfigurations(configurations)
    }

    private func sortedConfigurations(
        _ configurations: [ProviderAccountConfiguration]
    ) -> [ProviderAccountConfiguration] {
        let groupNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        return configurations.sorted {
            Self.configurationSort($0, $1, groupNames: groupNames)
        }
    }

    private func writeCredential(_ credential: String?, account: String) throws {
        if let credential, !credential.isEmpty {
            try secretStore.saveSecret(credential, account: account)
        } else {
            try secretStore.deleteSecret(account: account)
        }
    }

    private func sortGroups() {
        groups.sort(by: Self.groupSort)
    }

    private static func configurationSort(
        _ lhs: ProviderAccountConfiguration,
        _ rhs: ProviderAccountConfiguration,
        groupNames: [String: String] = [:]
    ) -> Bool {
        let lhsGroup = lhs.groupID.flatMap { groupNames[$0] } ?? ""
        let rhsGroup = rhs.groupID.flatMap { groupNames[$0] } ?? ""
        if lhsGroup != rhsGroup {
            return lhsGroup.localizedCaseInsensitiveCompare(rhsGroup) == .orderedAscending
        }

        if lhs.providerID.displayName != rhs.providerID.displayName {
            return lhs.providerID.displayName < rhs.providerID.displayName
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private static func groupSort(_ lhs: ProviderAccountGroup, _ rhs: ProviderAccountGroup) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func isAccountNameUnique(_ configuration: ProviderAccountConfiguration) -> Bool {
        let name = configuration.displayName

        return !configurations.contains {
            $0.id != configuration.id
                && $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func isGroupNameUnique(_ name: String, excluding groupID: String? = nil) -> Bool {
        !groups.contains {
            $0.id != groupID
                && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func shouldApplyLocalAuthMethod(
        current: ProviderAuthMethod,
        localMethod: ProviderAuthMethod,
        providerID: ProviderID
    ) -> Bool {
        current == localMethod
            || current == ProviderAccountConfiguration.defaultConfiguration(for: providerID).authMethod
    }

    private func rememberSuppressedGeminiDiscovery(for configuration: ProviderAccountConfiguration) {
        guard configuration.providerID == .gemini else {
            return
        }

        defaults.set(true, forKey: suppressedGeminiDiscoveryKey)
    }

    private func clearSuppressedGeminiDiscovery() {
        defaults.set(false, forKey: suppressedGeminiDiscoveryKey)
    }

    private func isGeminiDiscoverySuppressed() -> Bool {
        defaults.bool(forKey: suppressedGeminiDiscoveryKey)
    }

    private func rememberSuppressedCopilotDiscovery(for configuration: ProviderAccountConfiguration) {
        guard configuration.providerID == .copilot else {
            return
        }

        if let hint = localCredentialHints[configuration.id],
           let username = Self.githubUsername(fromLocalCredentialHint: hint) {
            addSuppressedCopilotDiscoveryUsername(username)
            return
        }

        let cliUsername = configuration.githubCLIUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cliUsername.isEmpty {
            addSuppressedCopilotDiscoveryUsername(cliUsername)
            return
        }

        let label = configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            return
        }

        addSuppressedCopilotDiscoveryUsername(label)
    }

    private func isSuppressedCopilotDiscoveryUsername(_ username: String) -> Bool {
        suppressedCopilotDiscoveryUsernames().contains(username.lowercased())
    }

    private func addSuppressedCopilotDiscoveryUsername(_ username: String) {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return
        }

        var suppressed = suppressedCopilotDiscoveryUsernames()
        guard suppressed.insert(normalized).inserted else {
            return
        }

        defaults.set(Array(suppressed).sorted(), forKey: suppressedCopilotDiscoveryUsernamesKey)
    }

    private func suppressedCopilotDiscoveryUsernames() -> Set<String> {
        Set(defaults.stringArray(forKey: suppressedCopilotDiscoveryUsernamesKey) ?? [])
    }

    private static func githubUsername(fromLocalCredentialHint hint: String) -> String? {
        guard hint.hasPrefix("GitHub CLI ("), hint.hasSuffix(")") else {
            return nil
        }

        let username = hint.dropFirst("GitHub CLI (".count).dropLast()
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func unusedDefaultCopilotAccountIndex() -> Int? {
        configurations.firstIndex(where: { configuration in
            guard configuration.providerID == .copilot else {
                return false
            }

            let label = configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDefaultLabel = label.isEmpty
                || label.localizedCaseInsensitiveCompare(ProviderID.copilot.displayName) == .orderedSame
                || label.range(
                    of: #"^GitHub Copilot( \d+)?$"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
            let hasNoCredential = !hasSecret(for: configuration)
                && localCredentialHints[configuration.id] == nil

            return isDefaultLabel
                && hasNoCredential
                && configuration.authMethod == ProviderAccountConfiguration.defaultConfiguration(for: .copilot).authMethod
        })
    }

    private func shouldReuseDefaultAccountID(for providerID: ProviderID) -> Bool {
        guard configurations(for: providerID).isEmpty else {
            return false
        }

        do {
            return try secretStore.readSecret(account: Self.keychainAccount(for: providerID)) != nil
        } catch {
            return true
        }
    }

    private static func normalizedGroupName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeEmailAddress(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            return false
        }
        let domainParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domainParts.count >= 2 && domainParts.allSatisfy { !$0.isEmpty }
    }

    private func uniqueAccountLabel(
        preferred: String,
        for configuration: ProviderAccountConfiguration
    ) -> String {
        let trimmedPreferred = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPreferred.isEmpty else {
            return suggestedAccountLabel(for: configuration.providerID)
        }

        var candidate = trimmedPreferred
        var suffix = 2
        while !isAccountNameUnique(
            ProviderAccountConfiguration(
                id: configuration.id,
                providerID: configuration.providerID,
                isEnabled: configuration.isEnabled,
                accountLabel: candidate,
                authMethod: configuration.authMethod
            )
        ) {
            candidate = "\(trimmedPreferred) \(suffix)"
            suffix += 1
        }

        return candidate
    }

    private func suggestedAccountLabel(for providerID: ProviderID) -> String {
        let base = providerID.displayName
        var index = configurations(for: providerID).count + 1
        while true {
            let candidate = "\(base) \(index)"
            let matchesExisting = configurations.contains {
                $0.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(candidate) == .orderedSame
            }
            if !matchesExisting {
                return candidate
            }
            index += 1
        }
    }
}
