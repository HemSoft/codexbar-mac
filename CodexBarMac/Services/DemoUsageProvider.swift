import Foundation

public struct DemoUsageProvider: UsageProvider {
    public let providerID: ProviderID
    public let bars: [UsageBar]
    public let creditsRemaining: Double?
    public let monetaryMetrics: [ProviderMonetaryMetric]
    public let usageMessages: [String]
    public let subtitle: String

    public init(
        providerID: ProviderID,
        bars: [UsageBar],
        creditsRemaining: Double? = nil,
        monetaryMetrics: [ProviderMonetaryMetric] = [],
        usageMessages: [String] = [],
        subtitle: String = "Ready to refresh"
    ) {
        self.providerID = providerID
        self.bars = bars
        self.creditsRemaining = creditsRemaining
        self.monetaryMetrics = monetaryMetrics
        self.usageMessages = usageMessages
        self.subtitle = subtitle
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: subtitle,
            bars: bars,
            creditsRemaining: creditsRemaining,
            monetaryMetrics: monetaryMetrics,
            usageMessages: usageMessages,
            fetchedAt: Date()
        )
    }
}

public extension DemoUsageProvider {
    static var samples: [DemoUsageProvider] {
        [
            DemoUsageProvider(
                providerID: .codex,
                bars: [
                    UsageBar(
                        label: "5-hour usage limit",
                        used: 42,
                        limit: 100,
                        resetDescription: "Resets in 2h 15m",
                        projectionDescriptionOverride: "Projected to stay under limit"
                    ),
                    UsageBar(
                        label: "Weekly usage limit",
                        used: 68,
                        limit: 100,
                        resetDescription: "Resets Monday at 12:00 AM"
                    )
                ],
                subtitle: "Personal account - live usage enabled"
            ),
            DemoUsageProvider(
                providerID: .copilot,
                bars: [
                    UsageBar(
                        label: "Premium requests",
                        used: 73,
                        limit: 100,
                        resetDescription: "Resets in 9 days"
                    )
                ],
                subtitle: "Engineering organization"
            ),
            DemoUsageProvider(
                providerID: .claude,
                bars: [
                    UsageBar(
                        label: "5-hour usage limit",
                        used: 36,
                        limit: 100,
                        resetDescription: "Resets in 1h 40m"
                    )
                ],
                monetaryMetrics: [
                    ProviderMonetaryMetric(
                        kind: .spent,
                        label: "Usage credits spent",
                        minorUnits: 1_250,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "Month to date"
                    ),
                    ProviderMonetaryMetric(
                        kind: .spendLimit,
                        label: "Monthly spend limit",
                        minorUnits: 5_000,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "Usage-credit policy cap"
                    ),
                    ProviderMonetaryMetric(
                        kind: .remainingHeadroom,
                        label: "Remaining spend headroom",
                        minorUnits: 3_750,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "Not a prepaid balance"
                    )
                ],
                subtitle: "Browser session connected"
            ),
            DemoUsageProvider(
                providerID: .openRouter,
                bars: [],
                creditsRemaining: 18.72,
                subtitle: "API balance"
            ),
            DemoUsageProvider(
                providerID: .openCodeZen,
                bars: [],
                creditsRemaining: 12.48,
                subtitle: "Workspace balance"
            ),
            DemoUsageProvider(
                providerID: .moonshot,
                bars: [],
                creditsRemaining: 37.5,
                subtitle: "API balance"
            ),
            DemoUsageProvider(
                providerID: .cursor,
                bars: [
                    UsageBar(
                        label: "Monthly included usage",
                        used: 51,
                        limit: 100,
                        resetDescription: "Resets Aug 1"
                    )
                ],
                subtitle: "Cursor account connected"
            )
        ]
    }
}
