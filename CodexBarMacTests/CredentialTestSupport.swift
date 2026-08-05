import XCTest
import Security
@testable import CodexBarMac

func browserCredentialFixture(
    for providerID: ProviderID
) -> (
    original: ProviderAccountConfiguration,
    replacement: ProviderAccountConfiguration,
    other: ProviderAccountConfiguration
) {
    var original = ProviderAccountConfiguration.defaultConfiguration(for: providerID)
    original.accountLabel = "Existing \(providerID.displayName)"
    original.githubCLIUsername = providerID == .copilot ? "existing-user" : ""

    var replacement = original
    replacement.authMethod = .browserSession
    replacement.accountLabel = "Replacement \(providerID.displayName)"
    replacement.githubCLIUsername = providerID == .copilot ? "replacement-user" : ""

    var other = ProviderAccountConfiguration.defaultConfiguration(for: providerID).withNewAccountID()
    other.accountLabel = "Other \(providerID.displayName)"
    other.githubCLIUsername = providerID == .copilot ? "other-user" : ""
    return (original, replacement, other)
}

enum TransactionalReplacementTestError: LocalizedError {
    case secretSave
    case configurationPersistence
    case credentialCompensation

    var errorDescription: String? {
        switch self {
        case .secretSave:
            "Injected secret save failure."
        case .configurationPersistence:
            "Injected configuration persistence failure."
        case .credentialCompensation:
            "Injected credential compensation failure."
        }
    }
}

enum CredentialMutationTestError: LocalizedError {
    case save
    case delete

    var errorDescription: String? {
        switch self {
        case .save:
            "Injected credential save failure."
        case .delete:
            "Injected credential deletion failure."
        }
    }
}

final class CredentialMutationSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private var shouldFailSaves = false
    private var shouldFailDeletes = false

    deinit {}

    var failSaves: Bool {
        get { lock.withLock { shouldFailSaves } }
        set { lock.withLock { shouldFailSaves = newValue } }
    }

    var failDeletes: Bool {
        get { lock.withLock { shouldFailDeletes } }
        set { lock.withLock { shouldFailDeletes = newValue } }
    }

    func readSecret(account: String) throws -> String? {
        lock.withLock { secrets[account] }
    }

    func saveSecret(_ secret: String, account: String) throws {
        try lock.withLock {
            if shouldFailSaves {
                throw CredentialMutationTestError.save
            }
            secrets[account] = secret
        }
    }

    func deleteSecret(account: String) throws {
        try lock.withLock {
            if shouldFailDeletes {
                throw CredentialMutationTestError.delete
            }
            _ = secrets.removeValue(forKey: account)
        }
    }
}

final class TransactionalReplacementSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private var unreadableAccounts: Set<String> = []
    private var storedSavedCredentials: [String] = []
    private var shouldFailNextSaveAfterWriting = false

    var savedCredentials: [String] {
        lock.withLock { storedSavedCredentials }
    }

    var failNextSaveAfterWriting: Bool {
        get { lock.withLock { shouldFailNextSaveAfterWriting } }
        set {
            lock.withLock {
                shouldFailNextSaveAfterWriting = newValue
            }
        }
    }

    func markUnreadable(account: String) {
        _ = lock.withLock {
            unreadableAccounts.insert(account)
        }
    }

    func resetSavedCredentials() {
        lock.withLock {
            storedSavedCredentials = []
        }
    }

    func readSecret(account: String) throws -> String? {
        try lock.withLock {
            if unreadableAccounts.contains(account) {
                throw KeychainError.invalidSecretData
            }
            return secrets[account]
        }
    }

    func saveSecret(_ secret: String, account: String) throws {
        try lock.withLock {
            secrets[account] = secret
            unreadableAccounts.remove(account)
            storedSavedCredentials.append(secret)
            if shouldFailNextSaveAfterWriting {
                shouldFailNextSaveAfterWriting = false
                throw TransactionalReplacementTestError.secretSave
            }
        }
    }

    func deleteSecret(account: String) throws {
        lock.withLock {
            secrets.removeValue(forKey: account)
            unreadableAccounts.remove(account)
        }
    }
}

final class FailingCredentialCompensationSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]
    private var saveCount = 0

    init(account: String, secret: String) {
        self.secrets = [account: secret]
    }

    deinit {}

    func readSecret(account: String) throws -> String? {
        lock.withLock { secrets[account] }
    }

    func saveSecret(_ secret: String, account: String) throws {
        try lock.withLock {
            saveCount += 1
            if saveCount == 1 {
                secrets[account] = secret
                throw TransactionalReplacementTestError.secretSave
            }
            throw TransactionalReplacementTestError.credentialCompensation
        }
    }

    func deleteSecret(account: String) throws {
        _ = lock.withLock {
            secrets.removeValue(forKey: account)
        }
    }
}

final class FailingSecretStore: SecretStore, @unchecked Sendable {
    func readSecret(account: String) throws -> String? {
        nil
    }

    func saveSecret(_ secret: String, account: String) throws {
        throw KeychainError.unhandledStatus(errSecDuplicateItem)
    }

    func deleteSecret(account: String) throws {}
}

final class MutableReadSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String?, KeychainError>

    init(result: Result<String?, KeychainError>) {
        self.result = result
    }

    func setResult(_ result: Result<String?, KeychainError>) {
        lock.withLock {
            self.result = result
        }
    }

    func readSecret(account: String) throws -> String? {
        try lock.withLock { result }.get()
    }

    func saveSecret(_ secret: String, account: String) throws {
        setResult(.success(secret))
    }

    func deleteSecret(account: String) throws {
        setResult(.success(nil))
    }
}

final class SelectiveDeletionSecretStore: SecretStore, @unchecked Sendable {
    struct DeletionError: LocalizedError {
        let account: String

        var errorDescription: String? {
            "Could not delete \(account)."
        }
    }

    var failingAccounts = Set<String>()

    func readSecret(account: String) throws -> String? {
        nil
    }

    func saveSecret(_ secret: String, account: String) throws {}

    func deleteSecret(account: String) throws {
        if failingAccounts.contains(account) {
            throw DeletionError(account: account)
        }
    }
}

final class FailingPermissionsFileManager: FileManager, @unchecked Sendable {
    private(set) var recordedAttributes: [FileAttributeKey: Any]?

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        recordedAttributes = attributes
        throw CocoaError(.fileWriteNoPermission)
    }
}

final class CopilotResolvedUsernameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private var wasSet = false

    var wasCalled: Bool {
        lock.withLock { wasSet }
    }

    var value: String? {
        get { lock.withLock { stored } }
        set {
            lock.withLock {
                stored = newValue
                wasSet = true
            }
        }
    }
}

final class CopilotTokenResolverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var callCount: Int {
        lock.withLock { count }
    }

    func nextToken() -> String {
        lock.withLock {
            count += 1
            return count == 1 ? "stale-token" : "fresh-token"
        }
    }
}


