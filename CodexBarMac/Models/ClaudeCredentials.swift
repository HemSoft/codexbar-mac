import Foundation

public struct ClaudeCredentials: Codable, Equatable, Sendable {
    public let subscriptionType: String?
    public let rateLimitTier: String?
    public let expiresAt: Int64
    public let accessToken: String?
    public let refreshToken: String?

    public init(
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil,
        expiresAt: Int64 = 0,
        accessToken: String?,
        refreshToken: String? = nil
    ) {
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.expiresAt = expiresAt
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    enum CodingKeys: String, CodingKey {
        case subscriptionType
        case rateLimitTier
        case expiresAt
        case accessToken
        case refreshToken
    }
}
