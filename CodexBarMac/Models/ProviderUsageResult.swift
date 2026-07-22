import Foundation

public enum ProviderMonetaryMetricKind: String, Codable, Equatable, Sendable {
    case balance
    case spent
    case spendLimit
    case remainingHeadroom
}

public struct ProviderMonetaryMetric: Identifiable, Codable, Equatable, Sendable {
    public let kind: ProviderMonetaryMetricKind
    public let label: String
    public let minorUnits: Decimal
    public let currencyCode: String
    public let decimalPlaces: Int
    public let detail: String?

    public init(
        kind: ProviderMonetaryMetricKind,
        label: String,
        minorUnits: Decimal,
        currencyCode: String,
        decimalPlaces: Int,
        detail: String? = nil
    ) {
        self.kind = kind
        self.label = label
        self.minorUnits = max(minorUnits, 0)
        self.currencyCode = currencyCode.uppercased()
        self.decimalPlaces = min(max(decimalPlaces, 0), 6)
        self.detail = detail
    }

    public var id: String {
        "\(kind.rawValue).\(label).\(currencyCode)"
    }

    public var amount: Decimal {
        var divisor = Decimal(1)
        for _ in 0..<max(decimalPlaces, 0) {
            divisor *= 10
        }
        return minorUnits / divisor
    }

    public func formattedAmount(locale: Locale = .autoupdatingCurrent) -> String {
        amount.formatted(
            .currency(code: currencyCode)
                .precision(.fractionLength(decimalPlaces))
                .locale(locale)
        )
    }
}

public struct ProviderUsageResult: Identifiable, Equatable, Sendable {
    public let accountID: String
    public let providerID: ProviderID
    public let title: String
    public let subtitle: String
    public let bars: [UsageBar]
    public let creditsRemaining: Double?
    public let monetaryMetrics: [ProviderMonetaryMetric]
    public let usageMessages: [String]
    public let isIncompleteRefresh: Bool
    public let fetchedAt: Date

    /// When `true`, forces `hasReachedSpendLimit` to `true` regardless of `monetaryMetrics`.
    /// A `false` value does not suppress a metrics-derived `true`; it falls back to comparing
    /// `.spent` / `.spendLimit` metrics.
    private let forcedSpendLimitReached: Bool

    public init(
        accountID: String? = nil,
        providerID: ProviderID,
        title: String,
        subtitle: String,
        bars: [UsageBar],
        creditsRemaining: Double? = nil,
        monetaryMetrics: [ProviderMonetaryMetric] = [],
        usageMessages: [String] = [],
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
        self.monetaryMetrics = monetaryMetrics
        self.usageMessages = usageMessages
        self.forcedSpendLimitReached = hasReachedSpendLimit
        self.isIncompleteRefresh = isIncompleteRefresh
        self.fetchedAt = fetchedAt
    }

    public var id: String {
        accountID
    }

    public var hasReachedSpendLimit: Bool {
        if forcedSpendLimitReached {
            return true
        }

        guard
            let spent = monetaryMetrics.first(where: { $0.kind == .spent }),
            let limit = monetaryMetrics.first(where: { $0.kind == .spendLimit }),
            spent.currencyCode == limit.currencyCode,
            spent.decimalPlaces == limit.decimalPlaces
        else {
            return false
        }

        return limit.minorUnits > 0 && spent.minorUnits >= limit.minorUnits
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
