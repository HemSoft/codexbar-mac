import Foundation

public enum CopilotCredentialsParser {
    public static func parse(_ storedSecret: String) -> CopilotCredentials? {
        let trimmed = storedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.first != "{" {
            return CopilotCredentials(accessToken: trimmed)
        }

        guard
            let data = trimmed.data(using: .utf8),
            let credentials = try? JSONDecoder().decode(CopilotCredentials.self, from: data),
            !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        return credentials
    }

    public static func storedCredential(from credentials: CopilotCredentials) -> String {
        guard let data = try? JSONEncoder().encode(credentials),
              let json = String(data: data, encoding: .utf8) else {
            return credentials.accessToken
        }
        return json
    }
}
