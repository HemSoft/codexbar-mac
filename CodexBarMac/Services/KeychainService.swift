import Foundation
import Security

public struct KeychainService: SecretStore {
    private let service: String

    public init(service: String = "com.hemsoft.CodexBarMac") {
        self.service = service
    }

    public func readSecret(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidSecretData
        }

        return try Self.decodeSecret(data)
    }

    public func saveSecret(_ secret: String, account: String) throws {
        let encodedSecret = Data(secret.utf8)
        var query = baseQuery(account: account)

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes = [kSecValueData as String: encodedSecret]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledStatus(updateStatus)
            }
            return
        }

        guard status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }

        query[kSecValueData as String] = encodedSecret
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledStatus(addStatus)
        }
    }

    public func deleteSecret(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func decodeSecret(_ data: Data) throws -> String {
        guard let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidSecretData
        }

        return secret
    }
}

public enum KeychainError: Error, Equatable, LocalizedError {
    case unhandledStatus(OSStatus)
    case invalidSecretData

    public var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            "Keychain operation failed with status \(status)."
        case .invalidSecretData:
            "The saved credential contains invalid data. Replace it in Settings."
        }
    }
}
