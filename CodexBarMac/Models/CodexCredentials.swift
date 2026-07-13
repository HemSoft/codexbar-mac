import Foundation

public struct CodexCredentials: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let accountID: String?
    public let expiresAt: Int64?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        accountID: String? = nil,
        expiresAt: Int64? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.expiresAt = expiresAt
    }

    static func normalizedEpochSeconds(_ value: Int64) -> Int64 {
        value >= 1_000_000_000_000 ? value / 1_000 : value
    }
}
