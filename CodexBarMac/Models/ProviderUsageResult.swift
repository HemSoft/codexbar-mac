import Foundation

public struct ProviderUsageResult: Identifiable, Equatable, Sendable {
    public let accountID: String
    public let providerID: ProviderID
    public let title: String
    public let subtitle: String
    public let bars: [UsageBar]
    public let creditsRemaining: Double?
    public let hasReachedSpendLimit: Bool
    public let isIncompleteRefresh: Bool
    public let fetchedAt: Date

    public init(
        accountID: String? = nil,
        providerID: ProviderID,
        title: String,
        subtitle: String,
        bars: [UsageBar],
        creditsRemaining: Double? = nil,
        hasReachedSpendLimit: Bool = false,
        isIncompleteRefresh: Bool = false,
        fetchedAt: Date
    ) {
        self.accountID = accountID ?? providerID.rawValue
        self.providerID = providerID
        self.title = title
        self.subtitle = subtitle
        self.bars = bars
        self.creditsRemaining = creditsRemaining
        self.hasReachedSpendLimit = hasReachedSpendLimit
        self.isIncompleteRefresh = isIncompleteRefresh
        self.fetchedAt = fetchedAt
    }

    public var id: String {
        accountID
    }

    public var highestSeverity: UsageSeverity {
        highestSeverity()
    }

    public func highestSeverity(at now: Date = Date()) -> UsageSeverity {
        max(
            bars.map { $0.effectiveSeverity(at: now) }.max() ?? .normal,
            hasReachedSpendLimit ? .critical : .normal
        )
    }
}
