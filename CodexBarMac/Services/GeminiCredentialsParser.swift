import Foundation

public enum GeminiCredentialsParser {
    private struct OAuthEnvelope: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiryDate: Int64?
        let idToken: String?
        let clientID: String?
        let clientSecret: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiryDate = "expiry_date"
            case idToken = "id_token"
            case clientID = "client_id"
            case clientSecret = "client_secret"
        }

        private enum AlternateCodingKeys: String, CodingKey {
            case clientId
            case clientSecret
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let alternateContainer = try decoder.container(keyedBy: AlternateCodingKeys.self)
            accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
            refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
            expiryDate = try container.decodeIfPresent(Int64.self, forKey: .expiryDate)
            idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
            clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
                ?? alternateContainer.decodeIfPresent(String.self, forKey: .clientId)
            clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret)
                ?? alternateContainer.decodeIfPresent(String.self, forKey: .clientSecret)
        }
    }

    public static func parseCredentialsFile(at path: String) -> GeminiCredentials? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }

        return parse(data)
    }

    public static func parse(_ data: Data) -> GeminiCredentials? {
        guard let envelope = try? JSONDecoder().decode(OAuthEnvelope.self, from: data) else {
            return nil
        }

        let credentials = GeminiCredentials(
            accessToken: envelope.accessToken,
            refreshToken: envelope.refreshToken,
            expiryDateMs: envelope.expiryDate,
            idToken: envelope.idToken,
            clientID: envelope.clientID,
            clientSecret: envelope.clientSecret
        )

        return credentials.hasUsableToken ? credentials : nil
    }

    public static func storedCredential(from credentials: GeminiCredentials, mergingExisting data: Data?) -> Data {
        var root: [String: Any] = [:]

        if let data,
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        if let accessToken = credentials.accessToken {
            root["access_token"] = accessToken
        }
        if let refreshToken = credentials.refreshToken {
            root["refresh_token"] = refreshToken
        }
        if let expiryDateMs = credentials.expiryDateMs {
            root["expiry_date"] = expiryDateMs
        }
        if let idToken = credentials.idToken {
            root["id_token"] = idToken
        }

        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
