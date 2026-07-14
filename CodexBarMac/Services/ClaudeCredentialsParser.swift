import Foundation

public enum ClaudeCredentialsParser {
    private struct CredentialEnvelope: Decodable {
        let claudeAiOauth: ClaudeCredentials?
    }

    public static func parseCredentialsFile(at path: String) -> ClaudeCredentials? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }

        return parse(contents)
    }

    public static func parse(_ rawValue: String) -> ClaudeCredentials? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.first != "{" {
            return ClaudeCredentials(accessToken: trimmed)
        }

        guard let data = trimmed.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(CredentialEnvelope.self, from: data),
           let credentials = envelope.claudeAiOauth {
            return credentials
        }

        return try? decoder.decode(ClaudeCredentials.self, from: data)
    }

    public static func storedCredential(
        from credentials: ClaudeCredentials,
        mergingExisting rawValue: String? = nil
    ) -> String {
        var root: [String: Any] = [:]
        var existingOAuth: [String: Any]?

        if let rawValue,
           let data = rawValue.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
            existingOAuth = parsed["claudeAiOauth"] as? [String: Any]
        }

        root["claudeAiOauth"] = mergedOAuthObject(from: credentials, existingOAuth: existingOAuth)

        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let stored = String(data: data, encoding: .utf8) else {
            return legacyStoredCredential(from: credentials)
        }

        return stored
    }

    private static func mergedOAuthObject(
        from credentials: ClaudeCredentials,
        existingOAuth: [String: Any]?
    ) -> [String: Any] {
        var oauth = existingOAuth ?? [:]

        if let subscriptionType = credentials.subscriptionType {
            oauth["subscriptionType"] = subscriptionType
        }
        if let rateLimitTier = credentials.rateLimitTier {
            oauth["rateLimitTier"] = rateLimitTier
        }
        if credentials.expiresAt > 0 {
            oauth["expiresAt"] = credentials.expiresAt
        }
        if let accessToken = credentials.accessToken {
            oauth["accessToken"] = accessToken
        }
        if let refreshToken = credentials.refreshToken {
            oauth["refreshToken"] = refreshToken
        }

        return oauth
    }

    private static func legacyStoredCredential(from credentials: ClaudeCredentials) -> String {
        let tokenPairs = [
            jsonPair("subscriptionType", credentials.subscriptionType),
            jsonPair("rateLimitTier", credentials.rateLimitTier),
            jsonPair("expiresAt", credentials.expiresAt),
            jsonPair("accessToken", credentials.accessToken),
            jsonPair("refreshToken", credentials.refreshToken),
        ].compactMap { $0 }

        return """
        {
          "claudeAiOauth": {
            \(tokenPairs.joined(separator: ",\n    "))
          }
        }
        """
    }

    private static func jsonPair(_ key: String, _ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let encodedValue = (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"\""
        return "\"\(key)\": \(encodedValue)"
    }

    private static func jsonPair(_ key: String, _ value: Int64) -> String {
        "\"\(key)\": \(value)"
    }
}
