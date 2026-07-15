import Foundation

public struct CursorCredentials: Decodable, Equatable, Sendable {
    public let accessToken: String?
    public let refreshToken: String?

    public init(accessToken: String? = nil, refreshToken: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

public enum CursorCredentialsParser {
    public static func defaultAuthPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/auth.json")
            .path
    }

    public static func parseAuthFile(at path: String) -> CursorCredentials? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }

        return try? JSONDecoder().decode(CursorCredentials.self, from: data)
    }

    public static func hasSession(at path: String = defaultAuthPath()) -> Bool {
        guard
            let credentials = parseAuthFile(at: path),
            let accessToken = credentials.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            !accessToken.isEmpty
        else {
            return false
        }

        return true
    }
}
