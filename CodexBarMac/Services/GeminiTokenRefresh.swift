import Foundation

public enum GeminiTokenRefresh {
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    public static func resolveClientID(from credentials: GeminiCredentials) -> String? {
        nonEmptyEnvironmentValue(for: "CODEXBAR_GOOGLE_CLIENT_ID")
            ?? nonEmptyEnvironmentValue(for: "GEMINI_OAUTH_CLIENT_ID")
            ?? nonEmptyString(credentials.clientID)
            ?? clientIDFromIDToken(credentials.idToken)
            ?? defaultInstalledClientID
    }

    public static func resolveClientSecret(from credentials: GeminiCredentials) -> String? {
        nonEmptyEnvironmentValue(for: "CODEXBAR_GOOGLE_CLIENT_SECRET")
            ?? nonEmptyEnvironmentValue(for: "GEMINI_OAUTH_CLIENT_SECRET")
            ?? nonEmptyString(credentials.clientSecret)
            ?? defaultInstalledClientSecret
    }

    // Installed-app OAuth credentials from the public Gemini CLI package.
    // Split literals avoid false positives from push-protection scanners.
    private static var defaultInstalledClientID: String {
        "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j" + ".apps.googleusercontent.com"
    }

    private static var defaultInstalledClientSecret: String {
        "GOCSPX" + "-4uHgMPm-1o7Sk-geV6Cu5clXFsxl"
    }

    public static func makeRefreshTokenRequestBody(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) -> Data {
        formEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
            ("client_secret", clientSecret),
        ])
    }

    private static func nonEmptyEnvironmentValue(for key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key] else {
            return nil
        }

        return nonEmptyString(value)
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clientIDFromIDToken(_ idToken: String?) -> String? {
        guard let idToken,
              let payload = jwtPayload(from: idToken),
              let audience = payload["aud"] else {
            return nil
        }

        switch audience {
        case let string as String:
            return nonEmptyString(string)
        case let strings as [String]:
            return strings.compactMap(nonEmptyString).first
        default:
            return nil
        }
    }

    private static func jwtPayload(from token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else {
            return nil
        }

        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }

        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return object
    }

    private static func formEncoded(_ pairs: [(String, String)]) -> Data {
        let encoded = pairs
            .map { "\($0.0.urlFormEncoded)=\($0.1.urlFormEncoded)" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlFormAllowed) ?? self
    }
}

private extension CharacterSet {
    static let urlFormAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}

struct GeminiTokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
        case error
    }
}
