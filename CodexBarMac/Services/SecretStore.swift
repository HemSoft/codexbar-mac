import Foundation

public protocol SecretStore: Sendable {
    func readSecret(account: String) throws -> String?
    func saveSecret(_ secret: String, account: String) throws
    func deleteSecret(account: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]

    public init(secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    public func readSecret(account: String) throws -> String? {
        lock.withLock { secrets[account] }
    }

    public func saveSecret(_ secret: String, account: String) throws {
        lock.withLock {
            secrets[account] = secret
        }
    }

    public func deleteSecret(account: String) throws {
        _ = lock.withLock {
            secrets.removeValue(forKey: account)
        }
    }
}
