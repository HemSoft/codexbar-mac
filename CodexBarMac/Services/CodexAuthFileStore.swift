import Foundation

public enum CodexAuthFileStore: Sendable {
    public static func defaultPath() -> String {
        LocalCredentialDiscovery.defaultCodexAuthPath()
    }

    public static func readCredentials(at path: String = defaultPath()) -> CodexCredentials? {
        CodexCredentialsParser.parseAuthFile(at: path)
    }

    public static func writeCredentials(_ credentials: CodexCredentials, at path: String = defaultPath()) throws {
        let fileURL = URL(fileURLWithPath: path)
        var root: [String: Any] = [:]

        if let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        let storedJSON = CodexCredentialsParser.storedCredential(from: credentials)
        guard let data = storedJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthFileStoreError.invalidCredentialPayload
        }

        for (key, value) in parsed {
            root[key] = value
        }

        let encoded = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded.write(to: fileURL, options: .atomic)
    }
}

public enum CodexAuthFileStoreError: Error {
    case invalidCredentialPayload
}
