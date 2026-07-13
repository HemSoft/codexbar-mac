import Foundation
import Security

public enum ClaudeCredentialStore: Sendable {
    public enum Storage: Equatable, Sendable {
        case keychain(service: String, account: String)
        case file(String)
    }

    public static func readCredentials(
        keychainAccount: String = NSUserName(),
        credentialsFilePath: String = LocalCredentialDiscovery.defaultClaudeCredentialsPath()
    ) -> (credentials: ClaudeCredentials, storage: Storage)? {
        for service in ["Claude Code-credentials", "Claude Code"] {
            if let secret = try? readGenericPassword(service: service, account: keychainAccount),
               let credentials = ClaudeCredentialsParser.parse(secret),
               credentials.accessToken?.isEmpty == false {
                return (credentials, .keychain(service: service, account: keychainAccount))
            }
        }

        if let credentials = ClaudeCredentialsParser.parseCredentialsFile(at: credentialsFilePath),
           credentials.accessToken?.isEmpty == false {
            return (credentials, .file(credentialsFilePath))
        }

        return nil
    }

    public static func saveCredentials(
        _ credentials: ClaudeCredentials,
        to storage: Storage
    ) throws {
        let stored = ClaudeCredentialsParser.storedCredential(from: credentials)
        switch storage {
        case .keychain(let service, let account):
            try saveGenericPassword(stored, service: service, account: account)
        case .file(let path):
            let fileURL = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(stored.utf8).write(to: fileURL, options: .atomic)
        }
    }

    private static func readGenericPassword(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.unhandledStatus(status)
        }
        return secret
    }

    private static func saveGenericPassword(_ secret: String, service: String, account: String) throws {
        let encoded = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [kSecValueData as String: encoded]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = encoded
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledStatus(addStatus)
            }
            return
        }
        throw KeychainError.unhandledStatus(updateStatus)
    }
}
