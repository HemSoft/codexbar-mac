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

    public static func storedCredential(from credentials: ClaudeCredentials) -> String {
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
