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
        _ = try coordinatedWrite(credentials, ifUnchangedFrom: nil, at: path)
    }

    static func writeCredentials(
        _ credentials: GeminiCredentials,
        ifUnchangedFrom expected: GeminiCredentials,
        at path: String = defaultPath()
    ) throws -> GeminiAuthFileStoreWriteResult {
        try coordinatedWrite(credentials, ifUnchangedFrom: expected, at: path)
    }

    private static func coordinatedWrite(
        _ credentials: GeminiCredentials,
        ifUnchangedFrom expected: GeminiCredentials?,
        at path: String
    ) throws -> GeminiAuthFileStoreWriteResult {
        let fileURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var writeResult: GeminiAuthFileStoreWriteResult?
        var writeError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let existingData = try? Data(contentsOf: coordinatedURL)
                if let expected {
                    guard let existingData,
                          let latest = GeminiCredentialsParser.parse(existingData) else {
                        throw GeminiAuthFileStoreError.invalidCredentialFile
                    }
                    guard latest == expected else {
                        writeResult = .changed(latest)
                        return
                    }
                }

                let encoded = GeminiCredentialsParser.storedCredential(
                    from: credentials,
                    mergingExisting: existingData
                )
                try encoded.write(to: coordinatedURL, options: .atomic)
                guard chmod(coordinatedURL.path, 0o600) == 0 else {
                    throw GeminiAuthFileStoreError.unableToSecureFile
                }
                writeResult = .written
            } catch {
                writeError = error
            }
        }

        if let writeError {
            throw writeError
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let writeResult else {
            throw GeminiAuthFileStoreError.unableToCoordinateWrite
        }
        return writeResult
    }
}

enum GeminiAuthFileStoreWriteResult: Equatable, Sendable {
    case written
    case changed(GeminiCredentials)
}

public enum GeminiAuthFileStoreError: Error {
    case invalidCredentialFile
    case unableToSecureFile
    case unableToCoordinateWrite
}
