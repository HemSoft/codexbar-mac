import Foundation
import Security
import Darwin

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
        switch storage {
        case .keychain(let service, let account):
            let existing = try? readGenericPassword(service: service, account: account)
            try saveGenericPassword(
                ClaudeCredentialsParser.storedCredential(from: credentials, mergingExisting: existing),
                service: service,
                account: account
            )
        case .file(let path):
            let existing = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            try writeCredentialsFile(credentials, at: path, mergingExisting: existing)
        }
    }

    private static func writeCredentialsFile(
        _ credentials: ClaudeCredentials,
        at path: String,
        mergingExisting existing: String? = nil
    ) throws {
        let fileURL = URL(fileURLWithPath: path)
        let stored = ClaudeCredentialsParser.storedCredential(
            from: credentials,
            mergingExisting: existing ?? (try? String(contentsOf: fileURL, encoding: .utf8))
        )
        guard let data = stored.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCredentialStoreError.invalidCredentialPayload
        }

        let encoded = try JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fileMode = existingFileMode(at: fileURL.path) ?? 0o600
        try encoded.write(to: fileURL, options: .atomic)
        _ = chmod(fileURL.path, fileMode)
    }

    private static func existingFileMode(at path: String) -> mode_t? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        var attributes = stat()
        guard stat(path, &attributes) == 0 else {
            return nil
        }

        return attributes.st_mode & 0o777
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

public enum ClaudeCredentialStoreError: Error {
    case invalidCredentialPayload
}
