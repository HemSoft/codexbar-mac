import Foundation

public struct ProviderUsageResult: Identifiable, Equatable, Sendable {
    public let accountID: String
    public let providerID: ProviderID
    public let title: String
    public let subtitle: String
    public let bars: [UsageBar]
    public let creditsRemaining: Double?
    public let fetchedAt: Date

    public init(
        accountID: String? = nil,
        providerID: ProviderID,
        title: String,
        subtitle: String,
        bars: [UsageBar],
        creditsRemaining: Double? = nil,
        fetchedAt: Date
    ) {
        self.accountID = accountID ?? providerID.rawValue
        self.providerID = providerID
        self.title = title
        self.subtitle = subtitle
        self.bars = bars
        self.creditsRemaining = creditsRemaining
        self.fetchedAt = fetchedAt
    }

    public var id: String {
        accountID
    }

    public var highestSeverity: UsageSeverity {
        highestSeverity()
    }

    public func highestSeverity(at now: Date = Date()) -> UsageSeverity {
        bars.map { $0.effectiveSeverity(at: now) }.max() ?? .normal
    }
}
