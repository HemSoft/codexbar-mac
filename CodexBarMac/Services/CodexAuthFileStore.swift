import Foundation
import Darwin

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
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let encoded = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
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
}

public enum CodexAuthFileStoreError: Error {
    case invalidCredentialPayload
}
