import XCTest
import CryptoKit
import Darwin
import Security
@testable import CodexBarMac

final class ConfigurationPersistenceTests: XCTestCase {
    deinit {}

    @MainActor
    func testProviderConfigurationStoreTreatsAbsentStorageAsFirstLaunch() {
        let suiteName = "CodexBarMacTests.ConfigurationAbsent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())

        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertFalse(store.isConfigurationRecoveryRequired)
        XCTAssertNil(store.lastError)

        store.seedDefaultConfigurationsIfNeeded()

        XCTAssertEqual(store.configurations.count, ProviderID.allCases.count)
        XCTAssertNotNil(defaults.data(forKey: "providerConfigurations"))
    }

    @MainActor
    func testDashboardTextSizeAndMenuBarSizePersistAcrossStoreInstances() {
        let suiteName = "CodexBarMacTests.DashboardPresentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertEqual(store.dashboardTextSize, .standard)
        XCTAssertEqual(store.menuBarDashboardSize, .defaultSize)

        store.updateDashboardTextSize(.extraLarge)
        store.updateMenuBarDashboardSize(width: 780, height: 640)

        let reloadedStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        XCTAssertEqual(reloadedStore.dashboardTextSize, .extraLarge)
        XCTAssertEqual(reloadedStore.menuBarDashboardSize, DashboardPanelSize(width: 780, height: 640))
    }

    func testDashboardPresentationValuesStayWithinSupportedBounds() {
        XCTAssertEqual(DashboardTextSize.small.decreased, .small)
        XCTAssertEqual(DashboardTextSize.small.increased, .standard)
        XCTAssertEqual(DashboardTextSize.standard.decreased, .small)
        XCTAssertEqual(DashboardTextSize.large.increased, .extraLarge)
        XCTAssertEqual(DashboardTextSize.extraLarge.increased, .extraLarge)

        XCTAssertEqual(
            DashboardPanelSize.normalized(width: 100, height: 100),
            .minimumSize
        )
        XCTAssertEqual(
            DashboardPanelSize.normalized(width: 10_000, height: 10_000),
            .maximumPersistedSize
        )
        XCTAssertEqual(
            DashboardPanelSize.normalized(width: .nan, height: 500),
            .defaultSize
        )
    }

    @MainActor
    func testProviderConfigurationStoreTreatsMissingGroupDataAsEmpty() throws {
        let suiteName = "CodexBarMacTests.GroupAbsent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var savedAccount = ProviderAccountConfiguration(
            id: "openrouter.saved",
            providerID: .openRouter,
            authMethod: .apiKey
        )
        savedAccount.groupID = "missing-group"
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(try JSONEncoder().encode([savedAccount]), forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.configuration(accountID: savedAccount.id)?.groupID)
        XCTAssertFalse(store.isGroupRecoveryRequired)
        XCTAssertFalse(store.isPersistenceRecoveryRequired)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testProviderConfigurationStoreRejectsNonDataGroupStorageWithoutReplacingIt() throws {
        let suiteName = "CodexBarMacTests.GroupNonData.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let damagedValue = ["unexpected": "value"]
        var savedAccount = ProviderAccountConfiguration(
            id: "openrouter.saved",
            providerID: .openRouter,
            authMethod: .apiKey
        )
        savedAccount.groupID = "preserved-group"
        let configurationData = try JSONEncoder().encode([savedAccount])
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(damagedValue, forKey: "providerAccountGroups")
        defaults.set(configurationData, forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertEqual(store.configuration(accountID: savedAccount.id)?.groupID, "preserved-group")
        XCTAssertTrue(store.isGroupRecoveryRequired)
        XCTAssertTrue(store.isPersistenceRecoveryRequired)
        XCTAssertEqual(
            defaults.dictionary(forKey: "providerAccountGroups")?["unexpected"] as? String,
            damagedValue["unexpected"]
        )
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), configurationData)
    }

    @MainActor
    func testProviderConfigurationStorePreservesMalformedGroupsAndBlocksAutomaticOverwrites() throws {
        let suiteName = "CodexBarMacTests.GroupRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let malformedGroupData = Data(#"{"groups":"not-an-array"}"#.utf8)
        var savedAccount = ProviderAccountConfiguration(
            id: "openrouter.saved",
            providerID: .openRouter,
            authMethod: .apiKey
        )
        savedAccount.groupID = "preserved-group"
        let configurationData = try JSONEncoder().encode([savedAccount])
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(malformedGroupData, forKey: "providerAccountGroups")
        defaults.set(configurationData, forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertEqual(store.configuration(accountID: savedAccount.id)?.groupID, "preserved-group")
        XCTAssertTrue(store.isGroupRecoveryRequired)
        XCTAssertEqual(
            store.lastError,
            "Saved group data couldn't be read. Replace the damaged group list in Settings to resume saving accounts and groups."
        )

        XCTAssertNil(store.addGroup(named: "Blocked Group"))
        var attemptedUpdate = savedAccount
        attemptedUpdate.accountLabel = "Blocked Rename"
        XCTAssertFalse(store.update(attemptedUpdate))
        XCTAssertFalse(store.removeAccounts([savedAccount]))
        store.applyLocalCredentialDiscoveries(
            LocalCredentialDiscovery.Result(
                codexAuthAvailable: true,
                githubUsernames: ["blocked-user"],
                claudeOAuthAvailable: true
            )
        )

        XCTAssertEqual(store.configurations, [savedAccount])
        XCTAssertEqual(defaults.data(forKey: "providerAccountGroups"), malformedGroupData)
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), configurationData)
        XCTAssertTrue(store.localCredentialHints.isEmpty)
        XCTAssertTrue(store.isGroupRecoveryRequired)
    }

    @MainActor
    func testProviderConfigurationStoreReplacesMalformedGroupsThenSavesNormally() throws {
        let suiteName = "CodexBarMacTests.GroupReplacement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var savedAccount = ProviderAccountConfiguration(
            id: "openrouter.saved",
            providerID: .openRouter,
            authMethod: .apiKey
        )
        savedAccount.groupID = "damaged-group"
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(Data("not-json".utf8), forKey: "providerAccountGroups")
        defaults.set(try JSONEncoder().encode([savedAccount]), forKey: "providerConfigurations")
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())

        XCTAssertTrue(store.replaceCorruptedGroups())

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.configuration(accountID: savedAccount.id)?.groupID)
        XCTAssertFalse(store.isGroupRecoveryRequired)
        XCTAssertFalse(store.isPersistenceRecoveryRequired)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [ProviderAccountGroup].self,
                from: try XCTUnwrap(defaults.data(forKey: "providerAccountGroups"))
            ),
            []
        )

        let replacementGroup = try XCTUnwrap(store.addGroup(named: "Recovered Group"))
        var regroupedAccount = try XCTUnwrap(store.configuration(accountID: savedAccount.id))
        regroupedAccount.groupID = replacementGroup.id
        XCTAssertTrue(store.update(regroupedAccount))

        let reloadedStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(reloadedStore.groups, [replacementGroup])
        XCTAssertEqual(reloadedStore.configuration(accountID: savedAccount.id)?.groupID, replacementGroup.id)
        XCTAssertFalse(reloadedStore.isPersistenceRecoveryRequired)
        XCTAssertNil(reloadedStore.lastError)
    }

    @MainActor
    func testProviderConfigurationStoreRejectsNonDataStorageWithoutReplacingIt() {
        let suiteName = "CodexBarMacTests.ConfigurationNonData.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let damagedValue = ["unexpected": "value"]
        defaults.set(damagedValue, forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        store.seedDefaultConfigurationsIfNeeded()

        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertTrue(store.isConfigurationRecoveryRequired)
        XCTAssertEqual(
            defaults.dictionary(forKey: "providerConfigurations")?["unexpected"] as? String,
            damagedValue["unexpected"]
        )
        XCTAssertEqual(
            store.lastError,
            "Saved account data couldn't be read. Replace the damaged account list in Settings to resume saving configurations."
        )
    }

    @MainActor
    func testProviderConfigurationStorePreservesMalformedDataCredentialsAndBlocksMutations() throws {
        let suiteName = "CodexBarMacTests.ConfigurationRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let malformedData = Data(#"{"accounts":"not-an-array"}"#.utf8)
        let savedAccount = ProviderAccountConfiguration(
            id: "openrouter.saved",
            providerID: .openRouter,
            authMethod: .apiKey
        )
        let savedGroup = ProviderAccountGroup(id: "saved-group", name: "Saved Group")
        let secretStore = InMemorySecretStore()
        let savedKeychainAccount = ProviderConfigurationStore.keychainAccount(for: savedAccount)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(malformedData, forKey: "providerConfigurations")
        defaults.set(try JSONEncoder().encode([savedGroup]), forKey: "providerAccountGroups")
        try secretStore.saveSecret("preserved-secret", account: savedKeychainAccount)

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertEqual(store.groups, [savedGroup])
        XCTAssertTrue(store.isConfigurationRecoveryRequired)
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), malformedData)

        store.seedDefaultConfigurationsIfNeeded()
        XCTAssertNil(store.addGroup(named: "Blocked Group"))
        var renamedGroup = savedGroup
        renamedGroup.name = "Blocked Rename"
        XCTAssertFalse(store.updateGroup(renamedGroup))
        store.removeGroup(savedGroup)

        let attemptedAccount = store.addAccount(for: .codex)
        var attemptedUpdate = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        attemptedUpdate.accountLabel = "Blocked Import"
        XCTAssertFalse(store.update(attemptedUpdate))
        XCTAssertFalse(store.removeAccounts([savedAccount]))
        store.saveSecret("blocked-secret", for: attemptedAccount)
        XCTAssertNil(
            store.connectCursorAccount(
                ProviderAccountConfiguration.defaultConfiguration(for: .cursor),
                credential: "blocked-cursor-secret"
            )
        )
        XCTAssertNil(
            store.disconnectCursorAccount(
                ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
            )
        )
        store.applyLocalCredentialDiscoveries(
            LocalCredentialDiscovery.Result(
                codexAuthAvailable: true,
                githubUsernames: ["blocked-user"],
                claudeOAuthAvailable: true,
                geminiOAuthAvailable: true
            )
        )

        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertEqual(store.groups, [savedGroup])
        XCTAssertTrue(store.localCredentialHints.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), malformedData)
        XCTAssertEqual(try secretStore.readSecret(account: savedKeychainAccount), "preserved-secret")
        XCTAssertNil(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: attemptedAccount)
            )
        )
        XCTAssertTrue(store.isConfigurationRecoveryRequired)
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testProviderConfigurationStoreReplacesMalformedDataThenSavesNormally() throws {
        let suiteName = "CodexBarMacTests.ConfigurationReplacement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = InMemorySecretStore()
        let malformedData = Data("not-json".utf8)
        let savedAccount = ProviderAccountConfiguration(
            id: "openrouter.saved",
            providerID: .openRouter,
            authMethod: .apiKey
        )
        let savedKeychainAccount = ProviderConfigurationStore.keychainAccount(for: savedAccount)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(malformedData, forKey: "providerConfigurations")
        try secretStore.saveSecret("preserved-secret", account: savedKeychainAccount)
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

        XCTAssertTrue(store.replaceCorruptedConfigurations())

        XCTAssertFalse(store.isConfigurationRecoveryRequired)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [ProviderAccountConfiguration].self,
                from: try XCTUnwrap(defaults.data(forKey: "providerConfigurations"))
            ),
            []
        )
        XCTAssertEqual(try secretStore.readSecret(account: savedKeychainAccount), "preserved-secret")

        let replacement = store.addAccount(for: .claude)
        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

        XCTAssertEqual(reloadedStore.configurations, [replacement])
        XCTAssertFalse(reloadedStore.isConfigurationRecoveryRequired)
        XCTAssertNil(reloadedStore.lastError)
        XCTAssertEqual(try secretStore.readSecret(account: savedKeychainAccount), "preserved-secret")
    }

    @MainActor
    func testProviderConfigurationStoreReusesPreservedDefaultCredentialAfterReplacement() throws {
        let suiteName = "CodexBarMacTests.ConfigurationDefaultCredentialRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = InMemorySecretStore()
        let defaultAccount = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: defaultAccount)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(Data("not-json".utf8), forKey: "providerConfigurations")
        try secretStore.saveSecret("preserved-default-secret", account: keychainAccount)
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

        XCTAssertTrue(store.replaceCorruptedConfigurations())
        XCTAssertTrue(store.configurations.isEmpty)

        let recoveredAccount = store.addAccount(for: .openRouter)

        XCTAssertEqual(recoveredAccount.id, ProviderID.openRouter.rawValue)
        XCTAssertEqual(store.readSavedSecret(for: recoveredAccount), "preserved-default-secret")
        XCTAssertEqual(
            ProviderConfigurationStore(defaults: defaults, secretStore: secretStore).configurations,
            [recoveredAccount]
        )
    }

    @MainActor
    func testProviderConfigurationStoreReusesDefaultAccountWhenPreservedCredentialReadFails() async throws {
        let suiteName = "CodexBarMacTests.ConfigurationDefaultCredentialReadFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MutableReadSecretStore(result: .failure(.invalidSecretData))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(Data("not-json".utf8), forKey: "providerConfigurations")
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

        XCTAssertTrue(store.replaceCorruptedConfigurations())

        let recoveredAccount = store.addAccount(for: .openRouter)
        let expectedError = KeychainError.invalidSecretData.localizedDescription
        for _ in 0..<200
            where store.credentialReadiness(for: recoveredAccount) != .error(description: expectedError) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(recoveredAccount.id, ProviderID.openRouter.rawValue)
        XCTAssertEqual(store.configurations, [recoveredAccount])
        XCTAssertEqual(
            store.credentialReadiness(for: recoveredAccount),
            .error(description: expectedError)
        )
    }

    @MainActor
    func testProviderConfigurationStoreReusesPreservedDefaultCopilotCredentialDuringDiscovery() throws {
        let suiteName = "CodexBarMacTests.ConfigurationDefaultCopilotDiscovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = InMemorySecretStore()
        let defaultAccount = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: defaultAccount)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(Data("not-json".utf8), forKey: "providerConfigurations")
        try secretStore.saveSecret("preserved-copilot-secret", account: keychainAccount)
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

        XCTAssertTrue(store.replaceCorruptedConfigurations())
        store.applyLocalCredentialDiscoveries(
            LocalCredentialDiscovery.Result(
                codexAuthAvailable: false,
                githubUsernames: ["octocat"],
                claudeOAuthAvailable: false
            )
        )

        let recoveredAccount = try XCTUnwrap(store.configurations.first)
        XCTAssertEqual(store.configurations.count, 1)
        XCTAssertEqual(recoveredAccount.id, ProviderID.copilot.rawValue)
        XCTAssertEqual(recoveredAccount.providerID, .copilot)
        XCTAssertEqual(recoveredAccount.authMethod, .cliToken)
        XCTAssertEqual(recoveredAccount.githubCLIUsername, "octocat")
        XCTAssertEqual(store.readSavedSecret(for: recoveredAccount), "preserved-copilot-secret")
    }

    @MainActor
    func testProviderConfigurationStoreRollsBackConfigurationWhenEncodingFails() throws {
        let suiteName = "CodexBarMacTests.ConfigurationEncoding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let original = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let originalData = try JSONEncoder().encode([original])
        let secretStore = InMemorySecretStore()
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: original)
        var shouldFailEncoding = false
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(originalData, forKey: "providerConfigurations")
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { configurations in
                if shouldFailEncoding {
                    throw CocoaError(.fileWriteUnknown)
                }
                return try JSONEncoder().encode(configurations)
            }
        )
        var updated = original
        updated.accountLabel = "Changed"

        shouldFailEncoding = true

        XCTAssertFalse(store.update(updated))
        XCTAssertEqual(store.configurations, [original])
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), originalData)
        XCTAssertTrue(store.lastError?.hasPrefix("Could not save account data:") == true)

        try secretStore.saveSecret("preserved-secret", account: keychainAccount)

        XCTAssertFalse(store.removeAccounts([original]))
        XCTAssertEqual(store.configurations, [original])
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), originalData)
        XCTAssertEqual(try secretStore.readSecret(account: keychainAccount), "preserved-secret")

        shouldFailEncoding = false

        XCTAssertTrue(store.update(updated))
        XCTAssertEqual(store.configurations, [updated])
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testSingleCodexAccountAcceptsBrowserIdentityWithoutAccountID() {
        let suiteName = "CodexBarMacTests.CodexIdentity.Single.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: TransactionalReplacementSecretStore(),
            encodeConfigurations: { try JSONEncoder().encode($0) }
        )
        let configuration = store.addAccount(for: .codex)

        XCTAssertEqual(
            store.validateCodexAccountIdentity(nil, for: configuration),
            .available
        )
    }

    @MainActor
    func testCodexBrowserIdentityIsAvailableWhenOtherSavedIdentityDiffers() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.Available.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) }
        )
        let first = store.addAccount(for: .codex)
        let second = store.addAccount(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(
                from: CodexCredentials(accessToken: "first-token", accountID: " first-account ")
            ),
            account: ProviderConfigurationStore.keychainAccount(for: first)
        )

        XCTAssertEqual(
            store.validateCodexAccountIdentity(" second-account ", for: second),
            .available
        )
    }

    @MainActor
    func testCodexBrowserIdentityRejectsDuplicateActiveLocalCLIAccount() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.LocalDuplicate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) },
            readCodexAuthCredentials: {
                .credentials(
                    CodexCredentials(accessToken: "local-token", accountID: "local-account")
                )
            }
        )
        var localAccount = store.addAccount(for: .codex)
        localAccount.accountLabel = "Codex CLI"
        localAccount.authMethod = .codexAuthJSON
        XCTAssertTrue(store.update(localAccount))
        let browserAccount = store.addAccount(for: .codex)
        let browserCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: "browser-token", accountID: "browser-account")
        )
        try secretStore.saveSecret(
            browserCredential,
            account: ProviderConfigurationStore.keychainAccount(for: browserAccount)
        )
        let configurationsBeforeValidation = store.configurations

        XCTAssertEqual(
            store.validateCodexAccountIdentity(" local-account ", for: browserAccount),
            .duplicate(accountName: "Codex CLI")
        )
        XCTAssertEqual(store.configurations, configurationsBeforeValidation)
        XCTAssertNil(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: localAccount)
            )
        )
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: browserAccount)
            ),
            browserCredential
        )
    }

    @MainActor
    func testCodexBrowserIdentityAcceptsDistinctActiveLocalCLIAccount() {
        let suiteName = "CodexBarMacTests.CodexIdentity.LocalAvailable.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: TransactionalReplacementSecretStore(),
            encodeConfigurations: { try JSONEncoder().encode($0) },
            readCodexAuthCredentials: {
                .credentials(
                    CodexCredentials(accessToken: "local-token", accountID: "local-account")
                )
            }
        )
        var localAccount = store.addAccount(for: .codex)
        localAccount.authMethod = .codexAuthJSON
        XCTAssertTrue(store.update(localAccount))
        let browserAccount = store.addAccount(for: .codex)

        XCTAssertEqual(
            store.validateCodexAccountIdentity("browser-account", for: browserAccount),
            .available
        )
    }

    @MainActor
    func testCodexBrowserIdentityRejectsNonDefaultBrowserPeerUsingLocalFallback() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.BrowserLocalFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) },
            readCodexAuthCredentials: {
                .credentials(
                    CodexCredentials(accessToken: "local-token", accountID: "local-account")
                )
            }
        )
        let incomingAccount = store.addAccount(for: .codex)
        var browserPeer = store.addAccount(for: .codex)
        browserPeer.accountLabel = "Browser peer"
        browserPeer.authMethod = .browserSession
        XCTAssertTrue(store.update(browserPeer))

        XCTAssertNil(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: browserPeer)
            )
        )
        XCTAssertEqual(
            store.validateCodexAccountIdentity("local-account", for: incomingAccount),
            .duplicate(accountName: "Browser peer")
        )
    }

    @MainActor
    func testCodexMalformedLocalPeerCredentialDoesNotMutateAccounts() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.MalformedLocal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authPath = directory.appendingPathComponent("auth.json").path
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(
            CodexAuthFileStore.readResult(
                at: directory.appendingPathComponent("missing-auth.json").path
            ),
            .missing
        )
        try Data("{ malformed".utf8).write(to: URL(fileURLWithPath: authPath))
        XCTAssertEqual(CodexAuthFileStore.readResult(at: authPath), .failure)

        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) },
            readCodexAuthCredentials: {
                CodexAuthFileStore.readResult(at: authPath)
            }
        )
        var localAccount = store.addAccount(for: .codex)
        localAccount.authMethod = .codexAuthJSON
        XCTAssertTrue(store.update(localAccount))
        let browserAccount = store.addAccount(for: .codex)
        let browserCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: "browser-token", accountID: "browser-account")
        )
        try secretStore.saveSecret(
            browserCredential,
            account: ProviderConfigurationStore.keychainAccount(for: browserAccount)
        )
        let configurationsBeforeValidation = store.configurations

        XCTAssertEqual(
            store.validateCodexAccountIdentity("new-account", for: browserAccount),
            .unableToVerify
        )
        XCTAssertEqual(store.configurations, configurationsBeforeValidation)
        XCTAssertNil(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: localAccount)
            )
        )
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: browserAccount)
            ),
            browserCredential
        )
    }

    @MainActor
    func testCodexMalformedPreferredLocalCredentialUsesKeychainFallback() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.LocalKeychainFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) },
            readCodexAuthCredentials: { .failure }
        )
        var localPeer = store.addAccount(for: .codex)
        localPeer.accountLabel = "Local peer"
        localPeer.authMethod = .codexAuthJSON
        XCTAssertTrue(store.update(localPeer))
        let incomingAccount = store.addAccount(for: .codex)
        let fallbackCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: "fallback-token", accountID: "fallback-account")
        )
        try secretStore.saveSecret(
            fallbackCredential,
            account: ProviderConfigurationStore.keychainAccount(for: localPeer)
        )

        XCTAssertEqual(
            store.validateCodexAccountIdentity("fallback-account", for: incomingAccount),
            .duplicate(accountName: "Local peer")
        )
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: localPeer)
            ),
            fallbackCredential
        )
    }

    @MainActor
    func testCodexMalformedPreferredKeychainCredentialUsesLocalFallback() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.KeychainLocalFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) },
            readCodexAuthCredentials: {
                .credentials(
                    CodexCredentials(accessToken: "local-token", accountID: "local-account")
                )
            }
        )
        let incomingAccount = store.addAccount(for: .codex)
        var browserPeer = store.addAccount(for: .codex)
        browserPeer.accountLabel = "Browser peer"
        browserPeer.authMethod = .browserSession
        XCTAssertTrue(store.update(browserPeer))
        let malformedCredential = "{ malformed"
        try secretStore.saveSecret(
            malformedCredential,
            account: ProviderConfigurationStore.keychainAccount(for: browserPeer)
        )

        XCTAssertEqual(
            store.validateCodexAccountIdentity("local-account", for: incomingAccount),
            .duplicate(accountName: "Browser peer")
        )
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: browserPeer)
            ),
            malformedCredential
        )
    }

    @MainActor
    func testCodexIdentityRejectsKeychainRuntimeFallbackBehindVerifiedLocalCredential() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.VerifiedLocalFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) },
            readCodexAuthCredentials: {
                .credentials(
                    CodexCredentials(accessToken: "local-token", accountID: "local-account")
                )
            }
        )
        var localPeer = store.addAccount(for: .codex)
        localPeer.accountLabel = "Local peer"
        localPeer.authMethod = .codexAuthJSON
        XCTAssertTrue(store.update(localPeer))
        let incomingAccount = store.addAccount(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(
                from: CodexCredentials(
                    accessToken: "keychain-token",
                    accountID: "keychain-account"
                )
            ),
            account: ProviderConfigurationStore.keychainAccount(for: localPeer)
        )

        XCTAssertEqual(
            store.validateCodexAccountIdentity("local-account", for: incomingAccount),
            .duplicate(accountName: "Local peer")
        )
        XCTAssertEqual(
            store.validateCodexAccountIdentity("keychain-account", for: incomingAccount),
            .duplicate(accountName: "Local peer")
        )
    }

    @MainActor
    func testCodexIdentityRejectsLocalRuntimeFallbackBehindVerifiedBrowserCredential() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.VerifiedKeychainFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) },
            readCodexAuthCredentials: {
                .credentials(
                    CodexCredentials(accessToken: "local-token", accountID: "local-account")
                )
            }
        )
        let incomingAccount = store.addAccount(for: .codex)
        var browserPeer = store.addAccount(for: .codex)
        browserPeer.accountLabel = "Browser peer"
        browserPeer.authMethod = .browserSession
        XCTAssertTrue(store.update(browserPeer))
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(
                from: CodexCredentials(
                    accessToken: "keychain-token",
                    accountID: "keychain-account"
                )
            ),
            account: ProviderConfigurationStore.keychainAccount(for: browserPeer)
        )

        XCTAssertEqual(
            store.validateCodexAccountIdentity("keychain-account", for: incomingAccount),
            .duplicate(accountName: "Browser peer")
        )
        XCTAssertEqual(
            store.validateCodexAccountIdentity("local-account", for: incomingAccount),
            .duplicate(accountName: "Browser peer")
        )
    }

    @MainActor
    func testCodexIdentitylessPreferredCredentialFailsClosedWithVerifiedFallback() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.IdentitylessPreferred.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) },
            readCodexAuthCredentials: {
                .credentials(CodexCredentials(accessToken: "identityless-local-token"))
            }
        )
        var localPeer = store.addAccount(for: .codex)
        localPeer.authMethod = .codexAuthJSON
        XCTAssertTrue(store.update(localPeer))
        let incomingAccount = store.addAccount(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(
                from: CodexCredentials(
                    accessToken: "keychain-token",
                    accountID: "keychain-account"
                )
            ),
            account: ProviderConfigurationStore.keychainAccount(for: localPeer)
        )

        XCTAssertEqual(
            store.validateCodexAccountIdentity("new-account", for: incomingAccount),
            .unableToVerify
        )
    }

    @MainActor
    func testCodexDuplicateBrowserIdentityReportsOwnerAndDoesNotMutateAccounts() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.Duplicate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) }
        )
        var first = store.addAccount(for: .codex)
        first.accountLabel = "Personal Codex"
        XCTAssertTrue(store.update(first))
        let second = store.addAccount(for: .codex)
        let firstCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: "first-token", accountID: "duplicate-account")
        )
        let secondCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: "second-token", accountID: "second-account")
        )
        try secretStore.saveSecret(
            firstCredential,
            account: ProviderConfigurationStore.keychainAccount(for: first)
        )
        try secretStore.saveSecret(
            secondCredential,
            account: ProviderConfigurationStore.keychainAccount(for: second)
        )
        let configurationsBeforeValidation = store.configurations

        XCTAssertEqual(
            store.validateCodexAccountIdentity(" duplicate-account ", for: second),
            .duplicate(accountName: "Personal Codex")
        )
        XCTAssertEqual(store.configurations, configurationsBeforeValidation)
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: first)
            ),
            firstCredential
        )
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: second)
            ),
            secondCredential
        )
    }

    @MainActor
    func testCodexMissingBrowserIdentityDoesNotMutateMultipleAccounts() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.Missing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) }
        )
        let first = store.addAccount(for: .codex)
        let second = store.addAccount(for: .codex)
        let firstCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: "first-token", accountID: "first-account")
        )
        let secondCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: "second-token", accountID: "second-account")
        )
        try secretStore.saveSecret(
            firstCredential,
            account: ProviderConfigurationStore.keychainAccount(for: first)
        )
        try secretStore.saveSecret(
            secondCredential,
            account: ProviderConfigurationStore.keychainAccount(for: second)
        )
        let configurationsBeforeValidation = store.configurations

        XCTAssertEqual(
            store.validateCodexAccountIdentity(" \n ", for: second),
            .unableToVerify
        )
        XCTAssertEqual(store.configurations, configurationsBeforeValidation)
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: first)
            ),
            firstCredential
        )
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: second)
            ),
            secondCredential
        )
    }

    @MainActor
    func testCodexIdentitylessPeerCredentialDoesNotMutateAccounts() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.IdentitylessPeer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) }
        )
        let first = store.addAccount(for: .codex)
        let second = store.addAccount(for: .codex)
        let peerCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: "legacy-token")
        )
        try secretStore.saveSecret(
            peerCredential,
            account: ProviderConfigurationStore.keychainAccount(for: first)
        )
        let configurationsBeforeValidation = store.configurations

        XCTAssertEqual(
            store.validateCodexAccountIdentity("second-account", for: second),
            .unableToVerify
        )
        XCTAssertEqual(store.configurations, configurationsBeforeValidation)
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: first)
            ),
            peerCredential
        )
    }

    @MainActor
    func testCodexUnreadablePeerCredentialDoesNotMutateAccounts() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.UnreadablePeer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) }
        )
        let first = store.addAccount(for: .codex)
        let second = store.addAccount(for: .codex)
        let secondCredential = CodexCredentialsParser.storedCredential(
            from: CodexCredentials(accessToken: "second-token", accountID: "second-account")
        )
        try secretStore.saveSecret(
            secondCredential,
            account: ProviderConfigurationStore.keychainAccount(for: second)
        )
        secretStore.resetSavedCredentials()
        secretStore.markUnreadable(
            account: ProviderConfigurationStore.keychainAccount(for: first)
        )
        let configurationsBeforeValidation = store.configurations

        XCTAssertEqual(
            store.validateCodexAccountIdentity("new-account", for: second),
            .unableToVerify
        )
        XCTAssertEqual(store.configurations, configurationsBeforeValidation)
        XCTAssertTrue(secretStore.savedCredentials.isEmpty)
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: second)
            ),
            secondCredential
        )
        XCTAssertEqual(
            store.lastError,
            "Could not verify the saved ChatGPT accounts: "
                + "The saved credential contains invalid data. Replace it in Settings."
        )
    }

    @MainActor
    func testCodexSelfReauthenticationRemainsAvailable() throws {
        let suiteName = "CodexBarMacTests.CodexIdentity.SelfReauthentication.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) }
        )
        let first = store.addAccount(for: .codex)
        let second = store.addAccount(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(
                from: CodexCredentials(accessToken: "first-token", accountID: "first-account")
            ),
            account: ProviderConfigurationStore.keychainAccount(for: first)
        )
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(
                from: CodexCredentials(accessToken: "second-token", accountID: "second-account")
            ),
            account: ProviderConfigurationStore.keychainAccount(for: second)
        )

        XCTAssertEqual(
            store.validateCodexAccountIdentity("first-account", for: first),
            .available
        )
    }

    @MainActor
    func testBrowserCredentialReplacementRollsBackSecretFailuresForAllProviders() throws {
        for providerID in [ProviderID.codex, .claude, .copilot] {
            let suiteName = "CodexBarMacTests.BrowserCredential.SecretFailure.\(providerID.rawValue).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer {
                defaults.removePersistentDomain(forName: suiteName)
            }

            let fixture = browserCredentialFixture(for: providerID)
            let secretStore = TransactionalReplacementSecretStore()
            defaults.set(
                try JSONEncoder().encode([fixture.original, fixture.other]),
                forKey: "providerConfigurations"
            )
            try secretStore.saveSecret(
                "existing-\(providerID.rawValue)-credential",
                account: ProviderConfigurationStore.keychainAccount(for: fixture.original)
            )
            try secretStore.saveSecret(
                "other-\(providerID.rawValue)-credential",
                account: ProviderConfigurationStore.keychainAccount(for: fixture.other)
            )
            secretStore.resetSavedCredentials()
            secretStore.failNextSaveAfterWriting = true
            let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

            XCTAssertFalse(
                store.replaceCredential(
                    "replacement-\(providerID.rawValue)-credential",
                    for: fixture.replacement
                )
            )
            XCTAssertEqual(store.lastError, "Injected secret save failure.")
            XCTAssertEqual(
                secretStore.savedCredentials,
                [
                    "replacement-\(providerID.rawValue)-credential",
                    "existing-\(providerID.rawValue)-credential",
                ]
            )

            let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
            XCTAssertEqual(
                reloadedStore.configuration(accountID: fixture.original.id),
                fixture.original
            )
            XCTAssertEqual(
                try secretStore.readSecret(
                    account: ProviderConfigurationStore.keychainAccount(for: fixture.original)
                ),
                "existing-\(providerID.rawValue)-credential"
            )
            XCTAssertEqual(
                reloadedStore.configuration(accountID: fixture.other.id),
                fixture.other
            )
            XCTAssertEqual(
                try secretStore.readSecret(
                    account: ProviderConfigurationStore.keychainAccount(for: fixture.other)
                ),
                "other-\(providerID.rawValue)-credential"
            )
        }
    }

    @MainActor
    func testBrowserCredentialReplacementRecoversUnreadableSecretsForAllProviders() throws {
        for providerID in [ProviderID.codex, .claude, .copilot] {
            let suiteName = "CodexBarMacTests.BrowserCredential.Unreadable.\(providerID.rawValue).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer {
                defaults.removePersistentDomain(forName: suiteName)
            }

            let fixture = browserCredentialFixture(for: providerID)
            let secretStore = TransactionalReplacementSecretStore()
            let account = ProviderConfigurationStore.keychainAccount(for: fixture.original)
            defaults.set(
                try JSONEncoder().encode([fixture.original, fixture.other]),
                forKey: "providerConfigurations"
            )
            secretStore.markUnreadable(account: account)
            try secretStore.saveSecret(
                "other-\(providerID.rawValue)-credential",
                account: ProviderConfigurationStore.keychainAccount(for: fixture.other)
            )
            secretStore.markUnreadable(account: account)
            let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

            XCTAssertTrue(
                store.replaceCredential(
                    "replacement-\(providerID.rawValue)-credential",
                    for: fixture.replacement
                )
            )
            XCTAssertNil(store.lastError)

            let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
            XCTAssertEqual(
                reloadedStore.configuration(accountID: fixture.replacement.id),
                fixture.replacement
            )
            XCTAssertEqual(
                try secretStore.readSecret(account: account),
                "replacement-\(providerID.rawValue)-credential"
            )
            XCTAssertEqual(
                reloadedStore.configuration(accountID: fixture.other.id),
                fixture.other
            )
            XCTAssertEqual(
                try secretStore.readSecret(
                    account: ProviderConfigurationStore.keychainAccount(for: fixture.other)
                ),
                "other-\(providerID.rawValue)-credential"
            )
        }
    }

    @MainActor
    func testBrowserCredentialReplacementCompensatesConfigurationFailuresForAllProviders() throws {
        for providerID in [ProviderID.codex, .claude, .copilot] {
            let suiteName = "CodexBarMacTests.BrowserCredential.ConfigurationFailure.\(providerID.rawValue).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer {
                defaults.removePersistentDomain(forName: suiteName)
            }

            let fixture = browserCredentialFixture(for: providerID)
            let secretStore = TransactionalReplacementSecretStore()
            defaults.set(
                try JSONEncoder().encode([fixture.original, fixture.other]),
                forKey: "providerConfigurations"
            )
            try secretStore.saveSecret(
                "existing-\(providerID.rawValue)-credential",
                account: ProviderConfigurationStore.keychainAccount(for: fixture.original)
            )
            try secretStore.saveSecret(
                "other-\(providerID.rawValue)-credential",
                account: ProviderConfigurationStore.keychainAccount(for: fixture.other)
            )
            secretStore.resetSavedCredentials()
            var persistenceAttempts = 0
            let store = ProviderConfigurationStore(
                defaults: defaults,
                secretStore: secretStore,
                encodeConfigurations: { try JSONEncoder().encode($0) },
                persistConfigurations: { data in
                    persistenceAttempts += 1
                    if persistenceAttempts == 1 {
                        throw TransactionalReplacementTestError.configurationPersistence
                    }
                    defaults.set(data, forKey: "providerConfigurations")
                }
            )

            XCTAssertFalse(
                store.replaceCredential(
                    "replacement-\(providerID.rawValue)-credential",
                    for: fixture.replacement
                )
            )
            XCTAssertEqual(
                store.lastError,
                "Could not save account data: Injected configuration persistence failure."
            )
            XCTAssertEqual(persistenceAttempts, 2)
            XCTAssertEqual(
                secretStore.savedCredentials,
                [
                    "replacement-\(providerID.rawValue)-credential",
                    "existing-\(providerID.rawValue)-credential",
                ]
            )

            let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
            XCTAssertEqual(
                reloadedStore.configuration(accountID: fixture.original.id),
                fixture.original
            )
            XCTAssertEqual(
                try secretStore.readSecret(
                    account: ProviderConfigurationStore.keychainAccount(for: fixture.original)
                ),
                "existing-\(providerID.rawValue)-credential"
            )
            XCTAssertEqual(
                reloadedStore.configuration(accountID: fixture.other.id),
                fixture.other
            )
            XCTAssertEqual(
                try secretStore.readSecret(
                    account: ProviderConfigurationStore.keychainAccount(for: fixture.other)
                ),
                "other-\(providerID.rawValue)-credential"
            )
        }
    }

    @MainActor
    func testBrowserCredentialReplacementCommitsExactAccountForAllProviders() throws {
        for providerID in [ProviderID.codex, .claude, .copilot] {
            let suiteName = "CodexBarMacTests.BrowserCredential.Success.\(providerID.rawValue).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer {
                defaults.removePersistentDomain(forName: suiteName)
            }

            let fixture = browserCredentialFixture(for: providerID)
            let secretStore = TransactionalReplacementSecretStore()
            defaults.set(
                try JSONEncoder().encode([fixture.original, fixture.other]),
                forKey: "providerConfigurations"
            )
            try secretStore.saveSecret(
                "existing-\(providerID.rawValue)-credential",
                account: ProviderConfigurationStore.keychainAccount(for: fixture.original)
            )
            try secretStore.saveSecret(
                "other-\(providerID.rawValue)-credential",
                account: ProviderConfigurationStore.keychainAccount(for: fixture.other)
            )
            let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

            XCTAssertFalse(store.replaceCredential("", for: fixture.replacement))
            XCTAssertEqual(
                store.lastError,
                "A credential is required to replace this account's sign-in."
            )
            XCTAssertEqual(store.configuration(accountID: fixture.original.id), fixture.original)
            XCTAssertEqual(
                try secretStore.readSecret(
                    account: ProviderConfigurationStore.keychainAccount(for: fixture.original)
                ),
                "existing-\(providerID.rawValue)-credential"
            )
            XCTAssertEqual(
                try secretStore.readSecret(
                    account: ProviderConfigurationStore.keychainAccount(for: fixture.other)
                ),
                "other-\(providerID.rawValue)-credential"
            )

            XCTAssertTrue(
                store.replaceCredential(
                    "replacement-\(providerID.rawValue)-credential",
                    for: fixture.replacement
                )
            )
            XCTAssertNil(store.lastError)

            let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
            XCTAssertEqual(
                reloadedStore.configuration(accountID: fixture.replacement.id),
                fixture.replacement
            )
            XCTAssertEqual(
                try secretStore.readSecret(
                    account: ProviderConfigurationStore.keychainAccount(for: fixture.replacement)
                ),
                "replacement-\(providerID.rawValue)-credential"
            )
            XCTAssertEqual(
                reloadedStore.configuration(accountID: fixture.other.id),
                fixture.other
            )
            XCTAssertEqual(
                try secretStore.readSecret(
                    account: ProviderConfigurationStore.keychainAccount(for: fixture.other)
                ),
                "other-\(providerID.rawValue)-credential"
            )
        }
    }

    @MainActor
    func testOpenCodeCredentialReplacementRollsBackSecretFailureAndReloads() throws {
        let suiteName = "CodexBarMacTests.OpenCodeCredential.SecretFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        var original = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        original.accountLabel = "Existing OpenCode"
        original.isEnabled = false
        original.openCodeWorkspaceId = "wrk_existing"
        var replacement = original
        replacement.accountLabel = "Replacement OpenCode"
        replacement.isEnabled = true
        replacement.authMethod = .apiKey
        replacement.openCodeWorkspaceId = "wrk_replacement"
        let account = ProviderConfigurationStore.keychainAccount(for: original)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(try JSONEncoder().encode([original]), forKey: "providerConfigurations")
        try secretStore.saveSecret("existing-dashboard-token", account: account)
        secretStore.resetSavedCredentials()
        secretStore.failNextSaveAfterWriting = true
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

        XCTAssertFalse(store.replaceCredential("replacement-dashboard-token", for: replacement))
        XCTAssertEqual(store.lastError, "Injected secret save failure.")
        XCTAssertEqual(store.configuration(accountID: original.id), original)
        XCTAssertEqual(
            secretStore.savedCredentials,
            ["replacement-dashboard-token", "existing-dashboard-token"]
        )

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        XCTAssertEqual(reloadedStore.configuration(accountID: original.id), original)
        XCTAssertEqual(try secretStore.readSecret(account: account), "existing-dashboard-token")
    }

    @MainActor
    func testOpenCodeCredentialReplacementSurfacesCredentialCompensationFailure() throws {
        let suiteName = "CodexBarMacTests.OpenCodeCredential.CompensationFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var original = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        original.accountLabel = "Existing OpenCode"
        original.openCodeWorkspaceId = "wrk_existing"
        var replacement = original
        replacement.accountLabel = "Replacement OpenCode"
        replacement.openCodeWorkspaceId = "wrk_replacement"
        let account = ProviderConfigurationStore.keychainAccount(for: original)
        let secretStore = FailingCredentialCompensationSecretStore(
            account: account,
            secret: "existing-dashboard-token"
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(try JSONEncoder().encode([original]), forKey: "providerConfigurations")
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

        XCTAssertFalse(store.replaceCredential("replacement-dashboard-token", for: replacement))
        XCTAssertEqual(
            store.lastError,
            "Injected secret save failure. Restoring the previous account state also failed "
                + "(credential: Injected credential compensation failure.). "
                + "The account may be inconsistent; retry this credential update."
        )
        XCTAssertEqual(store.configuration(accountID: original.id), original)

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        XCTAssertEqual(reloadedStore.configuration(accountID: original.id), original)
        XCTAssertEqual(try secretStore.readSecret(account: account), "replacement-dashboard-token")
    }

    @MainActor
    func testOpenCodeCredentialReplacementCompensatesConfigurationFailureAndReloads() throws {
        let suiteName = "CodexBarMacTests.OpenCodeCredential.ConfigurationFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        var original = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        original.accountLabel = "Existing OpenCode"
        original.isEnabled = false
        original.openCodeWorkspaceId = "wrk_existing"
        var replacement = original
        replacement.accountLabel = "Replacement OpenCode"
        replacement.isEnabled = true
        replacement.authMethod = .apiKey
        replacement.openCodeWorkspaceId = "wrk_replacement"
        let account = ProviderConfigurationStore.keychainAccount(for: original)
        var persistenceAttempts = 0
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(try JSONEncoder().encode([original]), forKey: "providerConfigurations")
        try secretStore.saveSecret("existing-dashboard-token", account: account)
        secretStore.resetSavedCredentials()
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) },
            persistConfigurations: { data in
                persistenceAttempts += 1
                if persistenceAttempts == 1 {
                    throw TransactionalReplacementTestError.configurationPersistence
                }
                defaults.set(data, forKey: "providerConfigurations")
            }
        )

        XCTAssertFalse(store.replaceCredential("replacement-dashboard-token", for: replacement))
        XCTAssertEqual(
            store.lastError,
            "Could not save account data: Injected configuration persistence failure."
        )
        XCTAssertEqual(persistenceAttempts, 2)
        XCTAssertEqual(store.configuration(accountID: original.id), original)
        XCTAssertEqual(
            secretStore.savedCredentials,
            ["replacement-dashboard-token", "existing-dashboard-token"]
        )

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        XCTAssertEqual(reloadedStore.configuration(accountID: original.id), original)
        XCTAssertEqual(try secretStore.readSecret(account: account), "existing-dashboard-token")
    }

    @MainActor
    func testOpenCodeCredentialReplacementSurfacesConfigurationCompensationFailure() throws {
        let suiteName = "CodexBarMacTests.OpenCodeCredential.ConfigurationCompensationFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        var original = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        original.accountLabel = "Existing OpenCode"
        original.openCodeWorkspaceId = "wrk_existing"
        var replacement = original
        replacement.accountLabel = "Replacement OpenCode"
        replacement.openCodeWorkspaceId = "wrk_replacement"
        let account = ProviderConfigurationStore.keychainAccount(for: original)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(try JSONEncoder().encode([original]), forKey: "providerConfigurations")
        try secretStore.saveSecret("existing-dashboard-token", account: account)
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) },
            persistConfigurations: { _ in
                throw TransactionalReplacementTestError.configurationPersistence
            }
        )

        XCTAssertFalse(store.replaceCredential("replacement-dashboard-token", for: replacement))
        XCTAssertEqual(
            store.lastError,
            "Could not save account data: Injected configuration persistence failure. "
                + "Restoring the previous account state also failed "
                + "(account data: Injected configuration persistence failure.). "
                + "The account may be inconsistent; retry this credential update."
        )
        XCTAssertEqual(store.configuration(accountID: original.id), original)
        XCTAssertEqual(try secretStore.readSecret(account: account), "existing-dashboard-token")
    }

    @MainActor
    func testOpenCodeCredentialReplacementCommitsConfigurationAndCredential() throws {
        let suiteName = "CodexBarMacTests.OpenCodeCredential.Success.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        var original = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        original.accountLabel = "Existing OpenCode"
        original.isEnabled = false
        original.openCodeWorkspaceId = "wrk_existing"
        var replacement = original
        replacement.accountLabel = "Replacement OpenCode"
        replacement.isEnabled = true
        replacement.authMethod = .apiKey
        replacement.openCodeWorkspaceId = "wrk_replacement"
        let account = ProviderConfigurationStore.keychainAccount(for: original)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(try JSONEncoder().encode([original]), forKey: "providerConfigurations")
        try secretStore.saveSecret("existing-dashboard-token", account: account)
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

        XCTAssertTrue(store.replaceCredential("replacement-dashboard-token", for: replacement))
        XCTAssertNil(store.lastError)

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        XCTAssertEqual(reloadedStore.configuration(accountID: replacement.id), replacement)
        XCTAssertEqual(try secretStore.readSecret(account: account), "replacement-dashboard-token")
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterWaitsForAndResumesAfterConfigurationRecovery() throws {
        let suiteName = "OpenCodeZenBootstrapRecovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let malformedData = Data("not-json".utf8)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(malformedData, forKey: "providerConfigurations")

        let fileManager = FileManager.default
        let importDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenCodeZenBootstrapRecovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: importDirectory)
        }

        let importURL = importDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_after_recovery",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "recovered-dashboard-token"
            }
          }
        }
        """
        try Data(payload.utf8).write(to: importURL)

        let secretStore = InMemorySecretStore()
        let configurationStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        )

        XCTAssertTrue(fileManager.fileExists(atPath: importURL.path))
        XCTAssertTrue(configurationStore.configurations.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), malformedData)

        XCTAssertTrue(
            OpenCodeZenBootstrapImporter.replaceCorruptedConfigurationsAndImportIfNeeded(
                configurationStore: configurationStore,
                fileManager: fileManager,
                importDirectory: importDirectory
            )
        )

        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
        let configuration = try XCTUnwrap(configurationStore.configurations(for: .openCodeZen).first)
        XCTAssertEqual(configuration.openCodeWorkspaceId, "wrk_after_recovery")
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            ),
            "recovered-dashboard-token"
        )
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterWaitsForAndResumesAfterGroupRecovery() throws {
        let suiteName = "OpenCodeZenBootstrapGroupRecovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let malformedGroupData = Data("bad-groups".utf8)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(try JSONEncoder().encode([ProviderAccountConfiguration]()), forKey: "providerConfigurations")
        defaults.set(malformedGroupData, forKey: "providerAccountGroups")

        let fileManager = FileManager.default
        let importDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenCodeZenBootstrapGroupRecovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: importDirectory)
        }

        let importURL = importDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_after_group_recovery",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "group-recovered-dashboard-token"
            }
          }
        }
        """
        try Data(payload.utf8).write(to: importURL)

        let secretStore = InMemorySecretStore()
        let configurationStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        )

        XCTAssertTrue(fileManager.fileExists(atPath: importURL.path))
        XCTAssertTrue(configurationStore.isGroupRecoveryRequired)
        XCTAssertEqual(defaults.data(forKey: "providerAccountGroups"), malformedGroupData)

        XCTAssertTrue(
            OpenCodeZenBootstrapImporter.replaceCorruptedGroupsAndImportIfNeeded(
                configurationStore: configurationStore,
                fileManager: fileManager,
                importDirectory: importDirectory
            )
        )

        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
        XCTAssertFalse(configurationStore.isPersistenceRecoveryRequired)
        let configuration = try XCTUnwrap(configurationStore.configurations(for: .openCodeZen).first)
        XCTAssertEqual(configuration.openCodeWorkspaceId, "wrk_after_group_recovery")
        XCTAssertEqual(
            try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            ),
            "group-recovered-dashboard-token"
        )
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterStoresWindowsSettingsJSON() throws {
        let suiteName = "OpenCodeZenBootstrapImporter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let secretStore = InMemorySecretStore()
        let configurationStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            }
          }
        }
        """

        XCTAssertTrue(OpenCodeZenBootstrapImporter.importPayload(payload, configurationStore: configurationStore))

        let configuration = try XCTUnwrap(configurationStore.configurations(for: .openCodeZen).first)
        XCTAssertEqual(configuration.openCodeWorkspaceId, "wrk_from_windows")
        XCTAssertEqual(configuration.accountLabel, "OpenCode ZEN")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            "go-dashboard-token"
        )
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterDeletesFileForInvalidPayload() throws {
        let suiteName = "OpenCodeZenBootstrapImporter-invalid-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let importURL = tempDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        try Data().write(to: importURL)

        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )

        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            importDirectory: tempDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: importURL.path))
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterRestrictsFileBeforeReading() throws {
        let suiteName = "OpenCodeZenBootstrapImporter-permissions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let importURL = tempDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        try Data().write(to: importURL)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: importURL.path)

        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        var permissionsAtRead: Int?

        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: tempDirectory,
            readData: { url in
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                permissionsAtRead = (attributes[.posixPermissions] as? NSNumber)?.intValue
                return try Data(contentsOf: url)
            }
        )

        XCTAssertEqual(permissionsAtRead, 0o600)
        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterDeletesFileWithoutReadingWhenProtectionFails() throws {
        let suiteName = "OpenCodeZenBootstrapImporter-protection-failure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = FailingPermissionsFileManager()
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let importURL = tempDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        try Data("sensitive bootstrap payload".utf8).write(to: importURL)

        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        var readAttempted = false

        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: tempDirectory,
            readData: { url in
                readAttempted = true
                return try Data(contentsOf: url)
            }
        )

        XCTAssertEqual(
            (fileManager.recordedAttributes?[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertFalse(readAttempted)
        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterDeletesFileAfterSuccessfulImport() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let importURL = tempDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            }
          }
        }
        """
        try Data(payload.utf8).write(to: importURL)

        let configurationStore = ProviderConfigurationStore(
            defaults: UserDefaults(suiteName: "OpenCodeZenBootstrapImporter-success-\(UUID().uuidString)")!,
            secretStore: InMemorySecretStore()
        )

        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            importDirectory: tempDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: importURL.path))
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterDeletesFileWhenSecretSaveFails() throws {
        let suiteName = "OpenCodeZenBootstrapImporter-persistence-failure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = TransactionalReplacementSecretStore()
        var original = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        original.accountLabel = "Existing OpenCode"
        original.isEnabled = false
        original.openCodeWorkspaceId = "wrk_existing"
        let account = ProviderConfigurationStore.keychainAccount(for: original)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        defaults.set(try JSONEncoder().encode([original]), forKey: "providerConfigurations")
        try secretStore.saveSecret("existing-dashboard-token", account: account)
        secretStore.resetSavedCredentials()
        secretStore.failNextSaveAfterWriting = true
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore
        )
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            }
          }
        }
        """

        let importURL = tempDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        try Data(payload.utf8).write(to: importURL)

        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: tempDirectory
        )

        XCTAssertNotNil(configurationStore.lastError)
        XCTAssertEqual(configurationStore.configuration(accountID: original.id), original)
        XCTAssertEqual(try secretStore.readSecret(account: account), "existing-dashboard-token")
        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        XCTAssertEqual(reloadedStore.configuration(accountID: original.id), original)
        XCTAssertEqual(try secretStore.readSecret(account: account), "existing-dashboard-token")
        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterDeletesFileWhenConfigurationSaveFails() throws {
        let suiteName = "OpenCodeZenBootstrapImporter-configuration-failure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secretStore = TransactionalReplacementSecretStore()
        var original = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        original.accountLabel = "Existing OpenCode"
        original.isEnabled = false
        original.openCodeWorkspaceId = "wrk_existing"
        let account = ProviderConfigurationStore.keychainAccount(for: original)
        var persistenceAttempts = 0
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? fileManager.removeItem(at: tempDirectory)
        }
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaults.set(try JSONEncoder().encode([original]), forKey: "providerConfigurations")
        try secretStore.saveSecret("existing-dashboard-token", account: account)
        secretStore.resetSavedCredentials()
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore,
            encodeConfigurations: { try JSONEncoder().encode($0) },
            persistConfigurations: { data in
                persistenceAttempts += 1
                if persistenceAttempts == 1 {
                    throw TransactionalReplacementTestError.configurationPersistence
                }
                defaults.set(data, forKey: "providerConfigurations")
            }
        )
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            }
          }
        }
        """
        let importURL = tempDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        try Data(payload.utf8).write(to: importURL)

        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: tempDirectory
        )

        XCTAssertEqual(
            configurationStore.lastError,
            "Could not save account data: Injected configuration persistence failure."
        )
        XCTAssertEqual(persistenceAttempts, 2)
        XCTAssertEqual(configurationStore.configuration(accountID: original.id), original)
        XCTAssertEqual(try secretStore.readSecret(account: account), "existing-dashboard-token")
        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        XCTAssertEqual(reloadedStore.configuration(accountID: original.id), original)
        XCTAssertEqual(try secretStore.readSecret(account: account), "existing-dashboard-token")
        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterDeletesFileAndSurfacesCompensationFailure() throws {
        let suiteName = "OpenCodeZenBootstrapImporter-compensation-failure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var original = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        original.accountLabel = "Existing OpenCode"
        original.openCodeWorkspaceId = "wrk_existing"
        let account = ProviderConfigurationStore.keychainAccount(for: original)
        let secretStore = FailingCredentialCompensationSecretStore(
            account: account,
            secret: "existing-dashboard-token"
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? fileManager.removeItem(at: tempDirectory)
        }
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaults.set(try JSONEncoder().encode([original]), forKey: "providerConfigurations")
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: secretStore
        )
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            }
          }
        }
        """
        let importURL = tempDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        try Data(payload.utf8).write(to: importURL)

        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: tempDirectory
        )

        XCTAssertTrue(
            configurationStore.lastError?.contains(
                "Restoring the previous account state also failed "
                    + "(credential: Injected credential compensation failure.)"
            ) == true
        )
        XCTAssertEqual(configurationStore.configuration(accountID: original.id), original)
        XCTAssertEqual(try secretStore.readSecret(account: account), "go-dashboard-token")
        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
    }

    func testOpenCodeZenNormalizesPastedBalanceCredential() {
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "Authorization: Bearer oczen-test-key"),
            "oczen-test-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "\"quoted-key\""),
            "quoted-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "auth=oczen-legacy-shaped-key; other=value"),
            "oczen-legacy-shaped-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedWorkspaceId(from: "https://opencode.ai/workspace/wrk_test/billing"),
            "wrk_test"
        )
    }

    func testOpenCodeZenProviderWithoutWorkspaceIsNotConfigured() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        try secretStore.saveSecret("oczen-test-key", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let provider = OpenCodeZenUsageProvider(secretStore: secretStore)
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "Not configured - enter OpenCode workspace ID.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = OpenCodeZenUsageProvider(secretStore: InMemorySecretStore())
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "Not configured - enter OpenCode dashboard auth value.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    @MainActor
    func testApplyLocalCredentialDiscoveriesCreatesMissingGeminiAccount() throws {
        let suiteName = "CodexBarMacTests.GeminiDiscovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preexisting = ProviderID.allCases
            .filter { $0 != .gemini }
            .map(ProviderAccountConfiguration.defaultConfiguration)
        defaults.set(try JSONEncoder().encode(preexisting), forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertTrue(store.configurations(for: .gemini).isEmpty)

        store.applyLocalCredentialDiscoveries(
            LocalCredentialDiscovery.Result(
                codexAuthAvailable: false,
                githubUsernames: [],
                claudeOAuthAvailable: false,
                geminiOAuthAvailable: true
            )
        )

        let gemini = try XCTUnwrap(store.configurations(for: .gemini).first)
        XCTAssertEqual(gemini.authMethod, .oauth)
        XCTAssertEqual(store.localCredentialHints[gemini.id], "~/.gemini/oauth_creds.json")
    }

    @MainActor
    func testApplyLocalCredentialDiscoveriesRespectsDeletedGeminiAccount() throws {
        let suiteName = "CodexBarMacTests.GeminiDiscoverySuppressed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preexisting = ProviderID.allCases.map(ProviderAccountConfiguration.defaultConfiguration)
        defaults.set(try JSONEncoder().encode(preexisting), forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        let gemini = try XCTUnwrap(store.configurations(for: .gemini).first)
        store.removeAccount(gemini)
        XCTAssertTrue(store.configurations(for: .gemini).isEmpty)

        store.applyLocalCredentialDiscoveries(
            LocalCredentialDiscovery.Result(
                codexAuthAvailable: false,
                githubUsernames: [],
                claudeOAuthAvailable: false,
                geminiOAuthAvailable: true
            )
        )

        XCTAssertTrue(store.configurations(for: .gemini).isEmpty)
    }

    @MainActor
    func testRemoveAccountsPreservesFailureBeforeSuccess() {
        let suiteName = "CodexBarMacTests.ResetAccounts.FailureThenSuccess.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let secretStore = SelectiveDeletionSecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let codex = store.addAccount(for: .codex)
        let claude = store.addAccount(for: .claude)
        secretStore.failingAccounts = [ProviderConfigurationStore.keychainAccount(for: codex)]

        XCTAssertTrue(store.removeAccounts([codex, claude]))

        XCTAssertNotNil(store.configuration(accountID: codex.id))
        XCTAssertNil(store.configuration(accountID: claude.id))
        XCTAssertEqual(
            store.lastError,
            "Could not delete \(ProviderConfigurationStore.keychainAccount(for: codex))."
        )
    }

    @MainActor
    func testRemoveAccountsPreservesFailureAfterSuccess() {
        let suiteName = "CodexBarMacTests.ResetAccounts.SuccessThenFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let secretStore = SelectiveDeletionSecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let codex = store.addAccount(for: .codex)
        let claude = store.addAccount(for: .claude)
        secretStore.failingAccounts = [ProviderConfigurationStore.keychainAccount(for: claude)]

        XCTAssertTrue(store.removeAccounts([codex, claude]))

        XCTAssertNil(store.configuration(accountID: codex.id))
        XCTAssertNotNil(store.configuration(accountID: claude.id))
        XCTAssertEqual(
            store.lastError,
            "Could not delete \(ProviderConfigurationStore.keychainAccount(for: claude))."
        )
    }

    @MainActor
    func testRemoveAccountsRetriesAfterPartialReset() {
        let suiteName = "CodexBarMacTests.ResetAccounts.Retry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let secretStore = SelectiveDeletionSecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let codex = store.addAccount(for: .codex)
        let claude = store.addAccount(for: .claude)
        secretStore.failingAccounts = [ProviderConfigurationStore.keychainAccount(for: codex)]

        XCTAssertTrue(store.removeAccounts([codex, claude]))
        XCTAssertEqual(store.configurations.map(\.id), [codex.id])

        secretStore.failingAccounts = []

        XCTAssertTrue(store.removeAccounts(store.configurations))
        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertNil(store.lastError)
    }

    func testProviderAccountConfigurationDefaultsLegacyHistoryVisibilityOn() throws {
        let json = """
        {
          "id": "codex.personal",
          "providerID": "codex",
          "isEnabled": true,
          "accountLabel": "Personal",
          "authMethod": "codexAuthJSON"
        }
        """

        let configuration = try JSONDecoder().decode(
            ProviderAccountConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(configuration.showsHistory)
    }

    @MainActor
    func testProviderHistoryVisibilityPersistsIndependentlyAcrossAccounts() throws {
        let suiteName = "CodexBarMacTests.HistoryVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        var codex = store.addAccount(for: .codex)
        let claude = store.addAccount(for: .claude)

        XCTAssertTrue(codex.showsHistory)
        XCTAssertTrue(claude.showsHistory)

        codex.showsHistory = false
        XCTAssertTrue(store.update(codex))

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertFalse(try XCTUnwrap(reloadedStore.configuration(accountID: codex.id)?.showsHistory))
        XCTAssertTrue(try XCTUnwrap(reloadedStore.configuration(accountID: claude.id)?.showsHistory))
    }

    @MainActor
    func testProviderAccountGroupsPersistAndValidateNames() throws {
        let suiteName = "CodexBarMacTests.Groups.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        let work = try XCTUnwrap(store.addGroup(named: "  Work  "))
        let personal = try XCTUnwrap(store.addGroup(named: "Personal"))

        XCTAssertEqual(store.groups.map(\.name), ["Personal", "Work"])
        XCTAssertNil(store.addGroup(named: "work"))
        XCTAssertEqual(store.lastError, "Group names must be unique.")

        var renamed = personal
        renamed.name = "  Home  "
        XCTAssertTrue(store.updateGroup(renamed))

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertEqual(reloadedStore.groups.map(\.name), ["Home", "Work"])
        XCTAssertEqual(reloadedStore.group(for: work.id)?.name, "Work")
    }

    @MainActor
    func testRemovingProviderAccountGroupUngroupsAssignedAccounts() throws {
        let suiteName = "CodexBarMacTests.GroupRemoval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        let group = try XCTUnwrap(store.addGroup(named: "Work"))
        var account = store.addAccount(for: .codex)
        account.groupID = group.id
        XCTAssertTrue(store.update(account))
        XCTAssertEqual(store.configuration(accountID: account.id)?.groupID, group.id)

        store.removeGroup(group)

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.configuration(accountID: account.id)?.groupID)
        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertTrue(reloadedStore.groups.isEmpty)
        XCTAssertNil(reloadedStore.configuration(accountID: account.id)?.groupID)
    }

}
