import Foundation

public struct CopilotCredentials: Equatable, Codable, Sendable {
    public let accessToken: String
    public let username: String?
    public let refreshToken: String?
    public let expiresAt: Int64?
    public let refreshTokenExpiresAt: Int64?

    public init(
        accessToken: String,
        username: String? = nil,
        refreshToken: String? = nil,
        expiresAt: Int64? = nil,
        refreshTokenExpiresAt: Int64? = nil
    ) {
        self.accessToken = accessToken
        self.username = username
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) <= date } ?? false
    }

    public func shouldRefresh(at date: Date, leeway: TimeInterval = 5 * 60) -> Bool {
        expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) <= date.addingTimeInterval(leeway) } ?? false
    }
}
