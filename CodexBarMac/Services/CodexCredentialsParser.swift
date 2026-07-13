import Foundation

public enum CodexCredentialsParser {
    public static func parseAuthFile(at path: String) -> CodexCredentials? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }

        return parse(contents)
    }

    public static func parse(_ input: String) -> CodexCredentials? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return nil
        }

        guard trimmedInput.first == "{" else {
            return CodexCredentials(
                accessToken: trimmedInput,
                accountID: accountID(from: trimmedInput)
            )
        }

        guard let data = trimmedInput.data(using: .utf8),
              let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let apiKey = rootObject["OPENAI_API_KEY"] as? String
            ?? rootObject["openai_api_key"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CodexCredentials(accessToken: apiKey)
        }

        let tokens = rootObject["tokens"] as? [String: Any] ?? rootObject

        guard let accessToken = stringValue(in: tokens, snakeCase: "access_token", camelCase: "accessToken"),
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let refreshToken = stringValue(in: tokens, snakeCase: "refresh_token", camelCase: "refreshToken")
        let idToken = stringValue(in: tokens, snakeCase: "id_token", camelCase: "idToken")
        let explicitExpiry = integerValue(in: tokens, snakeCase: "expires_at", camelCase: "expiresAt")
            .map(CodexCredentials.normalizedEpochSeconds)

        return CodexCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: stringValue(in: tokens, snakeCase: "account_id", camelCase: "accountId")
                ?? idToken.flatMap(accountID)
                ?? accountID(from: accessToken),
            expiresAt: explicitExpiry ?? tokenExpiry(from: accessToken) ?? idToken.flatMap(tokenExpiry)
        )
    }

    public static func storedCredential(from credentials: CodexCredentials) -> String {
        var tokens: [String: Any] = ["access_token": credentials.accessToken]
        if let refreshToken = credentials.refreshToken {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountID = credentials.accountID {
            tokens["account_id"] = accountID
        }
        if let expiresAt = credentials.expiresAt {
            tokens["expires_at"] = expiresAt
        }

        let root: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": tokens,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return credentials.accessToken
        }
        return value
    }

    private static func stringValue(in object: [String: Any], snakeCase: String, camelCase: String) -> String? {
        if let value = object[snakeCase] as? String {
            return value
        }

        return object[camelCase] as? String
    }

    private static func integerValue(in object: [String: Any], snakeCase: String, camelCase: String) -> Int64? {
        let value = object[snakeCase] ?? object[camelCase]
        if let value = value as? NSNumber {
            return value.int64Value
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }

    private static func tokenExpiry(from token: String) -> Int64? {
        jwtPayload(from: token)?["exp"].flatMap { value in
            if let value = value as? NSNumber {
                return value.int64Value
            }
            return (value as? String).flatMap(Int64.init)
        }
    }

    private static func accountID(from token: String) -> String? {
        jwtPayload(from: token)?["chatgpt_account_id"] as? String
    }

    private static func jwtPayload(from token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
        guard let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
