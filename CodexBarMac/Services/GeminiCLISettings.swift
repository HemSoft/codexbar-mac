import Foundation

public enum GeminiCLISettings {
    public static func usesOAuthCredentials(at settingsPath: String = defaultSettingsPath()) -> Bool {
        guard let selectedType = readSelectedAuthType(at: settingsPath) else {
            return true
        }

        let normalized = selectedType.lowercased()

        // Whitelist Gemini CLI OAuth / Google-login modes only. Unknown values must not
        // fall through to true — ADC/cloud-shell/gateway leave stale oauth_creds.json behind.
        if normalized == "oauth-personal"
            || normalized.contains("oauth")
            || normalized.contains("login") {
            return true
        }

        return false
    }

    public static func defaultSettingsPath() -> String {
        URL(fileURLWithPath: LocalCredentialDiscovery.defaultGeminiOAuthPath())
            .deletingLastPathComponent()
            .appendingPathComponent("settings.json")
            .path
    }

    private static func readSelectedAuthType(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let security = root["security"] as? [String: Any],
           let auth = security["auth"] as? [String: Any] {
            if let enforced = nonEmptyString(auth["enforcedType"] as? String) {
                return enforced
            }
            if let selected = nonEmptyString(auth["selectedType"] as? String) {
                return selected
            }
        }

        return nonEmptyString(root["selectedAuthType"] as? String)
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
