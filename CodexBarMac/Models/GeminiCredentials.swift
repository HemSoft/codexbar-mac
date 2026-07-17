import Foundation

public struct GeminiCredentials: Equatable, Sendable {
    public let accessToken: String?
    public let refreshToken: String?
    public let expiryDateMs: Int64?
    public let idToken: String?
    public let clientID: String?
    public let clientSecret: String?

    public init(
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiryDateMs: Int64? = nil,
        idToken: String? = nil,
        clientID: String? = nil,
        clientSecret: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryDateMs = expiryDateMs
        self.idToken = idToken
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public var hasUsableToken: Bool {
        let access = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let refresh = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return access || refresh
    }

    public func isExpired(at date: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiryDateMs else {
            return true
        }

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(expiryDateMs) / 1_000)
        return expiresAt <= date.addingTimeInterval(leeway)
    }

    public func shouldRefresh(at date: Date, leeway: TimeInterval = 60) -> Bool {
        guard let accessToken,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }

        return isExpired(at: date, leeway: leeway)
    }
}
