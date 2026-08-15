import XCTest
import CryptoKit
import Darwin
import Security
@testable import CodexBarMac

final class AppAndCredentialWorkflowTests: XCTestCase {
    deinit {}

    func testStatusBarRightClickRoutingConsumesOnlyClicksInsideMatchingButtonWindow() {
        XCTAssertEqual(
            StatusBarRightClickRoute.resolve(
                eventWindowMatchesButton: true,
                locationIsInsideButton: true
            ),
            .openMenu
        )
        XCTAssertEqual(
            StatusBarRightClickRoute.resolve(
                eventWindowMatchesButton: true,
                locationIsInsideButton: false
            ),
            .passThrough
        )
        XCTAssertEqual(
            StatusBarRightClickRoute.resolve(
                eventWindowMatchesButton: false,
                locationIsInsideButton: true
            ),
            .passThrough
        )
    }

    @MainActor
    func testOpenCodeAutomaticPersistenceStagesCredentialCoupledMetadata() {
        var persisted = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        persisted.isEnabled = true
        persisted.accountLabel = "Existing OpenCode"
        persisted.authMethod = .apiKey
        persisted.openCodeWorkspaceId = "wrk_existing"
        persisted.showsHistory = true

        var edited = persisted
        edited.isEnabled = false
        edited.accountLabel = "Replacement OpenCode"
        edited.authMethod = .browserSession
        edited.openCodeWorkspaceId = "wrk_replacement"
        edited.showsHistory = false

        let automaticallyPersisted = CredentialMutationFlow.configurationForAutomaticPersistence(
            edited,
            persistedConfiguration: persisted
        )

        XCTAssertTrue(automaticallyPersisted.isEnabled)
        XCTAssertEqual(automaticallyPersisted.accountLabel, "Existing OpenCode")
        XCTAssertEqual(automaticallyPersisted.authMethod, .apiKey)
        XCTAssertEqual(automaticallyPersisted.openCodeWorkspaceId, "wrk_existing")
        XCTAssertFalse(automaticallyPersisted.showsHistory)
    }

    @MainActor
    func testAutomaticPersistenceDoesNotStageOtherProviders() {
        var persisted = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        persisted.accountLabel = "Existing OpenRouter"

        var edited = persisted
        edited.accountLabel = "Replacement OpenRouter"

        XCTAssertEqual(
            CredentialMutationFlow.configurationForAutomaticPersistence(
                edited,
                persistedConfiguration: persisted
            ),
            edited
        )
    }

    @MainActor
    func testCredentialReplacementUsesEnteredCredentialOrFallsBackToSavedValue() {
        XCTAssertEqual(
            CredentialMutationFlow.replacementCredential(
                enteredCredential: "replacement-dashboard-token",
                savedCredential: "existing-dashboard-token"
            ),
            "replacement-dashboard-token"
        )
        XCTAssertEqual(
            CredentialMutationFlow.replacementCredential(
                enteredCredential: "  ",
                savedCredential: "existing-dashboard-token"
            ),
            "existing-dashboard-token"
        )
        XCTAssertNil(
            CredentialMutationFlow.replacementCredential(
                enteredCredential: "",
                savedCredential: nil
            )
        )
    }

    @MainActor
    func testOpenCodeSaveIsAvailableForCredentialOrMetadataChanges() {
        XCTAssertTrue(
            CredentialMutationFlow.canSaveOpenCodeSettings(
                enteredCredential: "replacement-dashboard-token",
                hasSavedCredential: false,
                hasStagedSettings: false
            )
        )
        XCTAssertTrue(
            CredentialMutationFlow.canSaveOpenCodeSettings(
                enteredCredential: "",
                hasSavedCredential: true,
                hasStagedSettings: false
            )
        )
        XCTAssertTrue(
            CredentialMutationFlow.canSaveOpenCodeSettings(
                enteredCredential: "",
                hasSavedCredential: false,
                hasStagedSettings: true
            )
        )
        XCTAssertFalse(
            CredentialMutationFlow.canSaveOpenCodeSettings(
                enteredCredential: "  ",
                hasSavedCredential: false,
                hasStagedSettings: false
            )
        )
    }

    @MainActor
    func testSavedCredentialReadResultDistinguishesMissingCredentialAndReadFailure() {
        let suiteName = "CodexBarMacTests.SavedCredentialReadResult.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let secretStore = MutableReadSecretStore(result: .failure(.invalidSecretData))
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

        XCTAssertEqual(
            store.savedCredentialReadResult(for: configuration),
            .failure("The saved credential contains invalid data. Replace it in Settings.")
        )

        secretStore.setResult(.success(nil))
        XCTAssertEqual(store.savedCredentialReadResult(for: configuration), .missing)

        secretStore.setResult(.success("redacted-dashboard-token"))
        XCTAssertEqual(
            store.savedCredentialReadResult(for: configuration),
            .credential("redacted-dashboard-token")
        )
    }

    func testKeychainServiceDistinguishesMissingValidAndInvalidSecrets() throws {
        let service = "com.hemsoft.CodexBarMacTests.\(UUID().uuidString)"
        let account = "credential.\(UUID().uuidString)"
        let keychain = KeychainService(service: service)
        defer {
            try? keychain.deleteSecret(account: account)
        }

        XCTAssertNil(try keychain.readSecret(account: account))

        try keychain.saveSecret("valid-test-secret", account: account)
        XCTAssertEqual(try keychain.readSecret(account: account), "valid-test-secret")

        try keychain.deleteSecret(account: account)
        XCTAssertNil(try keychain.readSecret(account: account))

        let invalidData = Data([0xFF])
        let addStatus = SecItemAdd(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: invalidData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary,
            nil
        )
        XCTAssertEqual(addStatus, errSecSuccess)

        XCTAssertThrowsError(try keychain.readSecret(account: account)) { error in
            XCTAssertEqual(error as? KeychainError, .invalidSecretData)
            XCTAssertEqual(
                error.localizedDescription,
                "The saved credential contains invalid data. Replace it in Settings."
            )
            XCTAssertFalse(error.localizedDescription.contains(invalidData.base64EncodedString()))
        }
    }

    @MainActor
    func testCredentialSaveFlowPreservesInputAndSkipsRefreshUntilStorageSucceeds() {
        let suiteName = "CodexBarMacTests.CredentialSaveFlow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        let secretStore = CredentialMutationSecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        var pastedSecret = "redacted-test-secret"
        var surfacedError: String?
        var refreshCount = 0

        secretStore.failSaves = true
        XCTAssertFalse(
            CredentialMutationFlow.perform(
                secret: pastedSecret,
                for: configuration,
                using: store,
                onFailure: { surfacedError = $0 },
                onSuccess: {
                    pastedSecret = ""
                    refreshCount += 1
                }
            )
        )
        XCTAssertEqual(pastedSecret, "redacted-test-secret")
        XCTAssertEqual(surfacedError, "Injected credential save failure.")
        XCTAssertEqual(store.lastError, surfacedError)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertNil(store.readSavedSecret(for: configuration))

        secretStore.failSaves = false
        XCTAssertTrue(
            CredentialMutationFlow.perform(
                secret: pastedSecret,
                for: configuration,
                using: store,
                onFailure: { surfacedError = $0 },
                onSuccess: {
                    pastedSecret = ""
                    refreshCount += 1
                }
            )
        )
        XCTAssertTrue(pastedSecret.isEmpty)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertNotNil(store.readSavedSecret(for: configuration))
    }

    @MainActor
    func testCredentialRemovalFlowPreservesPresentStateAndSkipsRefreshUntilDeletionSucceeds() throws {
        let suiteName = "CodexBarMacTests.CredentialRemovalFlow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let secretStore = CredentialMutationSecretStore()
        try secretStore.saveSecret(
            "redacted-existing-secret",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        var reportsCredentialPresent = true
        var pendingSecret = "redacted-pending-secret"
        var surfacedMessage: String?
        var refreshCount = 0

        secretStore.failDeletes = true
        XCTAssertFalse(
            CredentialMutationFlow.perform(
                secret: "",
                for: configuration,
                using: store,
                onFailure: { surfacedMessage = $0 },
                onSuccess: {
                    reportsCredentialPresent = false
                    pendingSecret = ""
                    surfacedMessage = "OpenCode credential removed."
                    refreshCount += 1
                }
            )
        )
        XCTAssertTrue(reportsCredentialPresent)
        XCTAssertEqual(pendingSecret, "redacted-pending-secret")
        XCTAssertEqual(surfacedMessage, "Injected credential deletion failure.")
        XCTAssertEqual(store.lastError, surfacedMessage)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertNotNil(store.readSavedSecret(for: configuration))

        secretStore.failDeletes = false
        XCTAssertTrue(
            CredentialMutationFlow.perform(
                secret: "",
                for: configuration,
                using: store,
                onFailure: { surfacedMessage = $0 },
                onSuccess: {
                    reportsCredentialPresent = false
                    pendingSecret = ""
                    surfacedMessage = "OpenCode credential removed."
                    refreshCount += 1
                }
            )
        )
        XCTAssertFalse(reportsCredentialPresent)
        XCTAssertTrue(pendingSecret.isEmpty)
        XCTAssertEqual(surfacedMessage, "OpenCode credential removed.")
        XCTAssertNil(store.lastError)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertNil(store.readSavedSecret(for: configuration))
    }

    @MainActor
    func testCredentialReadinessSurfacesAndClearsSecretReadErrors() async throws {
        let suiteName = "CodexBarMacTests.CredentialReadiness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        defaults.set(try JSONEncoder().encode([configuration]), forKey: "providerConfigurations")
        let secretStore = MutableReadSecretStore(result: .failure(.invalidSecretData))
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let errorDescription = "The saved credential contains invalid data. Replace it in Settings."

        for _ in 0..<200 where store.credentialReadiness(for: configuration) != .error(description: errorDescription) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.credentialReadiness(for: configuration), .error(description: errorDescription))

        secretStore.setResult(.success("valid-test-secret"))
        store.refreshSecretAvailability()
        for _ in 0..<200 where store.credentialReadiness(for: configuration) != .keychainSaved {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.credentialReadiness(for: configuration), .keychainSaved)

        secretStore.setResult(.success(nil))
        store.refreshSecretAvailability()
        for _ in 0..<200 where store.credentialReadiness(for: configuration) != .missing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.credentialReadiness(for: configuration), .missing)
    }

    @MainActor
    func testCredentialReadinessPrefersLocalCredentialsOverFallbackSecretReadError() async throws {
        let suiteName = "CodexBarMacTests.LocalCredentialReadiness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        defaults.set(try JSONEncoder().encode([configuration]), forKey: "providerConfigurations")
        let secretStore = MutableReadSecretStore(result: .failure(.invalidSecretData))
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)

        store.applyLocalCredentialDiscoveries(
            LocalCredentialDiscovery.Result(
                codexAuthAvailable: true,
                githubUsernames: [],
                claudeOAuthAvailable: false
            )
        )

        let expectedReadiness = CredentialReadiness.localCLIReady(description: "~/.codex/auth.json")
        for _ in 0..<200 where store.secretReadErrors[configuration.id] == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.secretReadErrors[configuration.id], KeychainError.invalidSecretData.localizedDescription)
        XCTAssertEqual(store.credentialReadiness(for: configuration), expectedReadiness)
    }

    func testSparkleConfigurationUsesSignedFeedAndDefaultConsentFlow() throws {
        let info = Bundle.main.infoDictionary ?? [:]

        XCTAssertEqual(
            info["SUFeedURL"] as? String,
            "https://hemsoft.github.io/codexbar-mac/appcast.xml"
        )
        XCTAssertEqual(
            info["SUPublicEDKey"] as? String,
            "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="
        )
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertNil(
            info["SUEnableAutomaticChecks"],
            "Sparkle must ask for automatic-check consent on its standard second-launch flow."
        )
    }

    @MainActor
    func testScheduledSparkleUpdateReminderPresentationAndActivation() {
        let reminder = SparkleUpdateReminderCoordinator()

        XCTAssertTrue(reminder.supportsGentleScheduledUpdateReminders)
        XCTAssertTrue(
            reminder.responds(to: NSSelectorFromString("supportsGentleScheduledUpdateReminders"))
        )
        XCTAssertTrue(
            reminder.responds(
                to: NSSelectorFromString("standardUserDriverDidReceiveUserAttentionForUpdate:")
            )
        )
        XCTAssertTrue(
            reminder.responds(to: NSSelectorFromString("standardUserDriverWillFinishUpdateSession"))
        )
        XCTAssertFalse(
            reminder.shouldStandardUserDriverHandleScheduledUpdate(inImmediateFocus: false)
        )

        reminder.recordUpdatePresentation(
            standardUserDriverWillHandle: false,
            userInitiated: false
        )
        XCTAssertTrue(reminder.hasPendingScheduledUpdate)

        var activationCount = 0
        XCTAssertTrue(
            reminder.activatePendingUpdate {
                activationCount += 1
            }
        )
        XCTAssertEqual(activationCount, 1)
        XCTAssertTrue(reminder.hasPendingScheduledUpdate)

        reminder.userDidAttendToUpdate()
        XCTAssertFalse(reminder.hasPendingScheduledUpdate)
        XCTAssertFalse(reminder.activatePendingUpdate { activationCount += 1 })
        XCTAssertEqual(activationCount, 1)
    }

    @MainActor
    func testSparkleReminderKeepsFocusedAndUserInitiatedChecksStandard() {
        let reminder = SparkleUpdateReminderCoordinator()

        XCTAssertTrue(
            reminder.shouldStandardUserDriverHandleScheduledUpdate(inImmediateFocus: true)
        )
        reminder.recordUpdatePresentation(
            standardUserDriverWillHandle: true,
            userInitiated: false
        )
        XCTAssertFalse(reminder.hasPendingScheduledUpdate)

        reminder.recordUpdatePresentation(
            standardUserDriverWillHandle: false,
            userInitiated: true
        )
        XCTAssertFalse(reminder.hasPendingScheduledUpdate)

        reminder.recordUpdatePresentation(
            standardUserDriverWillHandle: false,
            userInitiated: false
        )
        reminder.updateSessionDidFinish()
        XCTAssertFalse(reminder.hasPendingScheduledUpdate)
    }

}
