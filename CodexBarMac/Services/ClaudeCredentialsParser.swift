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
}
