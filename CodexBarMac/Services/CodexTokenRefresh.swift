import Foundation

public enum CodexTokenRefresh {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!

    public static func makeRefreshTokenRequestBody(refreshToken: String) -> Data {
        formEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])
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

struct CodexTokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int64?
    let expiresAt: Int64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case error
    }
}
