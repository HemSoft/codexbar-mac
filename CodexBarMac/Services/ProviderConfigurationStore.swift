import Combine
import Foundation

@MainActor
public final class ProviderConfigurationStore: ObservableObject {
    @Published public private(set) var configurations: [ProviderAccountConfiguration]
    @Published public private(set) var groups: [ProviderAccountGroup]
    @Published public private(set) var secretAvailability: [String: Bool]
    @Published public private(set) var localCredentialHints: [String: String]
    @Published public private(set) var appAppearance: AppAppearance
    @Published public private(set) var autoRefreshInterval: AutoRefreshInterval
    @Published public private(set) var lastError: String?

    private let defaults: UserDefaults
    private let secretStore: any SecretStore
    private let configurationsKey = DefaultsKey.configurations
    private let groupsKey = DefaultsKey.groups
    private let appAppearanceKey = DefaultsKey.appAppearance
    private let autoRefreshIntervalKey = DefaultsKey.autoRefreshInterval
    private var secretAvailabilityGeneration = 0

    deinit {}

    public init(
        defaults: UserDefaults = .standard,
        secretStore: any SecretStore = KeychainService()
    ) {
        let loadedGroups = Self.loadGroups(from: defaults)
        self.defaults = defaults
        self.secretStore = secretStore
        self.groups = loadedGroups
        self.configurations = Self.loadConfigurations(
            from: defaults,
            validGroupIDs: Set(loadedGroups.map(\.id))
        )
        self.secretAvailability = [:]
        self.localCredentialHints = [:]
        self.appAppearance = Self.loadAppAppearance(from: defaults)
        self.autoRefreshInterval = Self.loadAutoRefreshInterval(from: defaults)
        sortConfigurations()
        refreshSecretAvailability()
    }

    public var enabledConfigurations: [ProviderAccountConfiguration] {
        configurations.filter(\.isEnabled)
    }

    public func seedDefaultConfigurationsIfNeeded() {
        guard defaults.data(forKey: configurationsKey) == nil else {
            return
        }

        configurations = ProviderID.allCases.map(ProviderAccountConfiguration.defaultConfiguration)
        sortConfigurations()
        saveConfigurations()
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
    public func addAccount(for providerID: ProviderID) -> ProviderAccountConfiguration {
        addAccount(for: providerID, copilotScope: .personal)
    }

    @discardableResult
    public func addAccount(
        for providerID: ProviderID,
        copilotScope: CopilotAccountScope
    ) -> ProviderAccountConfiguration {
        var configuration = ProviderAccountConfiguration
            .defaultConfiguration(for: providerID)
            .withNewAccountID()
        if providerID == .copilot {
            configuration.copilotAccountScope = copilotScope
        }
        configuration.accountLabel = suggestedAccountLabel(for: providerID)
        configurations.append(configuration)
        sortConfigurations()
        saveConfigurations()
        refreshSecretAvailability()
        return configuration
    }

    @discardableResult
    public func update(_ configuration: ProviderAccountConfiguration) -> Bool {
        let normalized = Self.normalizedConfiguration(
            configuration,
            validGroupIDs: Set(groups.map(\.id))
        )
        guard isAccountNameUnique(normalized) else {
            lastError = "Account names must be unique."
            return false
        }

        if let index = configurations.firstIndex(where: { $0.id == normalized.id }) {
            configurations[index] = normalized
        } else {
            configurations.append(normalized)
        }

        sortConfigurations()
        saveConfigurations()
        return true
    }

    public func removeAccount(_ configuration: ProviderAccountConfiguration) {
        do {
            try secretStore.deleteSecret(account: Self.keychainAccount(for: configuration))
        } catch {
            lastError = error.localizedDescription
            return
        }

        configurations.removeAll { $0.id == configuration.id }
        secretAvailability.removeValue(forKey: configuration.id)
        localCredentialHints.removeValue(forKey: configuration.id)
        lastError = nil
        sortConfigurations()
        saveConfigurations()
        refreshSecretAvailability()
    }

    public func updateAppAppearance(_ appearance: AppAppearance) {
        appAppearance = appearance
        defaults.set(appearance.rawValue, forKey: appAppearanceKey)
    }

    public func updateAutoRefreshInterval(_ interval: AutoRefreshInterval) {
        autoRefreshInterval = interval
        defaults.set(interval.rawValue, forKey: autoRefreshIntervalKey)
    }

    public func saveSecret(_ secret: String, for configuration: ProviderAccountConfiguration) {
        do {
            if secret.isEmpty {
                try secretStore.deleteSecret(account: Self.keychainAccount(for: configuration))
                secretAvailability[configuration.id] = false
            } else {
                try secretStore.saveSecret(secret, account: Self.keychainAccount(for: configuration))
                secretAvailability[configuration.id] = true
            }

            lastError = nil
            refreshSecretAvailability(including: [configuration])
        } catch {
            lastError = error.localizedDescription
        }
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

        return .missing
    }

    public func applyLocalCredentialDiscoveries(
        _ discovery: LocalCredentialDiscovery.Result = LocalCredentialDiscovery.discover()
    ) {
        var nextHints: [String: String] = [:]

        if discovery.codexAuthAvailable {
            for index in configurations.indices where configurations[index].providerID == .codex {
                configurations[index].authMethod = .codexAuthJSON
                nextHints[configurations[index].id] = "~/.codex/auth.json"
            }
        }

        for username in discovery.githubUsernames {
            if let index = configurations.firstIndex(where: {
                $0.providerID == .copilot
                    && $0.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                        .localizedCaseInsensitiveCompare(username) == .orderedSame
            }) {
                configurations[index].authMethod = .cliToken
                nextHints[configurations[index].id] = "GitHub CLI (\(username))"
                continue
            }

            var configuration = ProviderAccountConfiguration
                .defaultConfiguration(for: .copilot)
                .withNewAccountID()
            configuration.accountLabel = username
            configuration.authMethod = .cliToken
            configurations.append(configuration)
            nextHints[configuration.id] = "GitHub CLI (\(username))"
        }

        if discovery.claudeOAuthAvailable {
            for index in configurations.indices where configurations[index].providerID == .claude {
                configurations[index].authMethod = .oauth
                nextHints[configurations[index].id] = "~/.claude/.credentials.json"
            }
        }

        localCredentialHints = nextHints
        sortConfigurations()
        saveConfigurations()
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
            for configuration in snapshot {
                let account = ProviderConfigurationStore.keychainAccount(for: configuration)
                availability[configuration.id] = ((try? store.readSecret(account: account)) ?? nil) != nil
            }

            await MainActor.run { [weak self] in
                guard let self, self.secretAvailabilityGeneration == generation else {
                    return
                }

                var nextAvailability = self.secretAvailability
                let currentPersistedIDs = Set(self.configurations.map(\.id))
                for accountID in nextAvailability.keys
                    where persistedSnapshotIDs.contains(accountID) && !currentPersistedIDs.contains(accountID) {
                    nextAvailability.removeValue(forKey: accountID)
                }

                for (accountID, isAvailable) in availability {
                    nextAvailability[accountID] = isAvailable
                }

                self.secretAvailability = nextAvailability
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

    private func saveConfigurations() {
        do {
            let data = try JSONEncoder().encode(configurations)
            defaults.set(data, forKey: configurationsKey)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private enum DefaultsKey {
        static let configurations = "providerConfigurations"
        static let groups = "providerAccountGroups"
        static let appAppearance = "appAppearance"
        static let autoRefreshInterval = "autoRefreshInterval"
    }

    private static func loadConfigurations(
        from defaults: UserDefaults,
        validGroupIDs: Set<String>? = nil
    ) -> [ProviderAccountConfiguration] {
        guard
            let data = defaults.data(forKey: DefaultsKey.configurations),
            let decoded = try? JSONDecoder().decode([ProviderAccountConfiguration].self, from: data)
        else {
            return []
        }

        return decoded
            .map { normalizedConfiguration($0, validGroupIDs: validGroupIDs) }
            .sorted { configurationSort($0, $1) }
    }

    private static func loadGroups(from defaults: UserDefaults) -> [ProviderAccountGroup] {
        guard
            let data = defaults.data(forKey: DefaultsKey.groups),
            let decoded = try? JSONDecoder().decode([ProviderAccountGroup].self, from: data)
        else {
            return []
        }

        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        return decoded.compactMap { group in
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
        let groupNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        configurations.sort {
            Self.configurationSort($0, $1, groupNames: groupNames)
        }
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

    private static func normalizedGroupName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
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
