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

        try encoded.write(to: fileURL, options: .atomic)
        guard chmod(fileURL.path, 0o600) == 0 else {
            throw GeminiAuthFileStoreError.unableToSecureFile
        }
    }
}

public enum GeminiAuthFileStoreError: Error {
    case unableToSecureFile
}
