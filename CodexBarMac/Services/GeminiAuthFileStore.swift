import Foundation
import Darwin

public enum GeminiAuthFileStore: Sendable {
    public static func defaultPath() -> String {
        LocalCredentialDiscovery.defaultGeminiOAuthPath()
    }

    public static func readCredentials(at path: String = defaultPath()) -> GeminiCredentials? {
        GeminiCredentialsParser.parseCredentialsFile(at: path)
    }

    public static func writeCredentials(_ credentials: GeminiCredentials, at path: String = defaultPath()) throws {
        let fileURL = URL(fileURLWithPath: path)
        let existingData = try? Data(contentsOf: fileURL)
        let encoded = GeminiCredentialsParser.storedCredential(
            from: credentials,
            mergingExisting: existingData
        )

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
