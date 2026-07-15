import Foundation

public enum UsageAlertKind: String, Equatable, Sendable {
    case usage
    case balance
    case severity
}

public struct UsageAlertDetail: Identifiable, Equatable, Sendable {
    public let id: String
    public let accountID: String
    public let kind: UsageAlertKind
    public let title: String
    public let message: String
    public let severity: UsageSeverity

    public init(
        id: String,
        accountID: String,
        kind: UsageAlertKind,
        title: String,
        message: String,
        severity: UsageSeverity
    ) {
        self.id = id
        self.accountID = accountID
        self.kind = kind
        self.title = title
        self.message = message
        self.severity = severity
    }
}

public struct UsageAlertNotification: Equatable, Sendable {
    public let id: String
    public let accountID: String
    public let kind: UsageAlertKind
    public let title: String
    public let body: String
}

public struct UsageAlertEvaluation: Equatable, Sendable {
    public let notifications: [UsageAlertNotification]
    public let activeAlertIDs: Set<String>
    public let activeAlerts: [UsageAlertDetail]
}

public enum UsageAlertEvaluator {
    public static func activeAlertIDs(
        _ activeAlertIDs: Set<String>,
        belongingTo preservedAccountIDs: Set<String>,
        knownAccountIDs: Set<String>
    ) -> Set<String> {
        let accountIDsBySpecificity = knownAccountIDs.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
        }

        return activeAlertIDs.filter { alertID in
            guard let accountID = accountID(
                for: alertID,
                knownAccountIDs: accountIDsBySpecificity
            ) else {
                return false
            }
            return preservedAccountIDs.contains(accountID)
        }
    }

    private static func accountID(
        for alertID: String,
        knownAccountIDs: [String]
    ) -> String? {
        knownAccountIDs.first { accountID in
            alertID == "balance.\(accountID)"
                || alertID == "severity.\(accountID)"
                || alertID.hasPrefix("severity.\(accountID).")
                || alertID.hasPrefix("usage.\(accountID).")
        }
    }

    public static func evaluate(
        results: [ProviderUsageResult],
        settings: UsageAlertSettings,
        activeAlertIDs: Set<String>,
        now: Date = Date()
    ) -> UsageAlertEvaluation {
        guard settings.isEnabled else {
            return UsageAlertEvaluation(notifications: [], activeAlertIDs: [], activeAlerts: [])
        }

        var nextActiveAlertIDs = Set<String>()
        var activeAlerts: [UsageAlertDetail] = []
        var notifications: [UsageAlertNotification] = []

        for result in results {
            for bar in result.bars where bar.fractionUsed >= settings.usageThreshold {
                let alertID = alertID(for: result, bar: bar)
                let hasAlreadyQueuedAlert = nextActiveAlertIDs.contains(alertID)
                nextActiveAlertIDs.insert(alertID)

                guard !hasAlreadyQueuedAlert else {
                    continue
                }

                let detail = usageAlertDetail(
                    id: alertID,
                    result: result,
                    bar: bar,
                    threshold: settings.usageThreshold,
                    now: now
                )
                activeAlerts.append(detail)

                guard !activeAlertIDs.contains(alertID) else {
                    continue
                }

                notifications.append(
                    UsageAlertNotification(
                        id: alertID,
                        accountID: result.accountID,
                        kind: .usage,
                        title: "\(result.title) \(bar.label) alert",
                        body: detail.notificationBody
                    )
                )
            }

            if let creditsRemaining = result.creditsRemaining,
               creditsRemaining <= settings.balanceThreshold
            {
                let alertID = "balance.\(result.accountID)"
                nextActiveAlertIDs.insert(alertID)

                let detail = balanceAlertDetail(
                    id: alertID,
                    result: result,
                    creditsRemaining: creditsRemaining,
                    threshold: settings.balanceThreshold
                )
                activeAlerts.append(detail)

                if !activeAlertIDs.contains(alertID) {
                    notifications.append(
                        UsageAlertNotification(
                            id: alertID,
                            accountID: result.accountID,
                            kind: .balance,
                            title: "\(result.title) balance alert",
                            body: detail.notificationBody
                        )
                    )
                }
            }

            let highestSeverity = result.highestSeverity(at: now)
            if settings.includesSeverityAlerts,
               highestSeverity >= .warning
            {
                let alertID = "severity.\(result.accountID).\(highestSeverity.rawValue)"
                nextActiveAlertIDs.insert(alertID)

                let detail = severityAlertDetail(
                    id: alertID,
                    result: result,
                    severity: highestSeverity,
                    now: now
                )
                activeAlerts.append(detail)

                if !activeAlertIDs.contains(alertID) {
                    notifications.append(
                        UsageAlertNotification(
                            id: alertID,
                            accountID: result.accountID,
                            kind: .severity,
                            title: "\(result.title) \(highestSeverity.displayName) alert",
                            body: detail.notificationBody
                        )
                    )
                }
            }
        }

        return UsageAlertEvaluation(
            notifications: notifications,
            activeAlertIDs: nextActiveAlertIDs,
            activeAlerts: activeAlerts
        )
    }

    private static func usageAlertDetail(
        id: String,
        result: ProviderUsageResult,
        bar: UsageBar,
        threshold: Double,
        now: Date
    ) -> UsageAlertDetail {
        let thresholdText = formatPercent(threshold)
        let usageAmountText = formatUsageAmount(used: bar.used, limit: bar.limit)
        let resetText = bar.localizedResetDescription(at: now).map { " \($0)." } ?? ""

        return UsageAlertDetail(
            id: id,
            accountID: result.accountID,
            kind: .usage,
            title: "\(bar.label) at \(bar.usageText)",
            message: "\(usageAmountText) used. Alert threshold: \(thresholdText).\(resetText)",
            severity: max(bar.severity, .warning)
        )
    }

    private static func balanceAlertDetail(
        id: String,
        result: ProviderUsageResult,
        creditsRemaining: Double,
        threshold: Double
    ) -> UsageAlertDetail {
        UsageAlertDetail(
            id: id,
            accountID: result.accountID,
            kind: .balance,
            title: "Balance below \(formatCurrency(threshold))",
            message: "\(formatCurrency(creditsRemaining)) remaining for \(result.title).",
            severity: .warning
        )
    }

    private static func severityAlertDetail(
        id: String,
        result: ProviderUsageResult,
        severity: UsageSeverity,
        now: Date
    ) -> UsageAlertDetail {
        let affectedBar = result.bars
            .first { $0.effectiveSeverity(at: now) == severity }
        let message: String

        if let affectedBar {
            if affectedBar.severity < severity,
               let projectedFraction = affectedBar.projectedFraction(at: now)
            {
                message = "\(affectedBar.label) is projected to reach \(formatPercent(projectedFraction))."
            } else {
                message = "\(affectedBar.label) is currently at \(affectedBar.usageText)."
            }
        } else if result.hasReachedSpendLimit {
            message = "The monthly usage-credit spend limit has been reached."
        } else {
            message = result.subtitle
        }

        return UsageAlertDetail(
            id: id,
            accountID: result.accountID,
            kind: .severity,
            title: "\(severity.displayName) status",
            message: message,
            severity: severity
        )
    }

    private static func alertID(for result: ProviderUsageResult, bar: UsageBar) -> String {
        let stableKey = stableUsageKey(for: bar)
        if let resetsAt = bar.resetsAt {
            return "usage.\(result.accountID).\(stableKey).\(Int(resetsAt.timeIntervalSince1970))"
        }
        return "usage.\(result.accountID).\(stableKey)"
    }

    private static func stableUsageKey(for bar: UsageBar) -> String {
        if bar.stableKey == ClaudeUsageIdentity.allModelsWeeklyStableKey {
            return ClaudeUsageIdentity.allModelsWeeklyLegacyKey
        }

        if let stableKey = bar.stableKey {
            let normalized = normalizedKeyComponent(stableKey)
            if !normalized.isEmpty {
                return normalized
            }
        }

        let withoutParentheticalValues = bar.label
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        let withoutRatios = withoutParentheticalValues
            .replacingOccurrences(
                of: #"\$?\d[\d,]*(?:\.\d+)?\s*/\s*\$?\d[\d,]*(?:\.\d+)?"#,
                with: "",
                options: .regularExpression
            )
        let withoutStandaloneNumbers = withoutRatios
            .replacingOccurrences(
                of: #"\$?\d[\d,]*(?:\.\d+)?"#,
                with: "",
                options: .regularExpression
            )

        let normalized = normalizedKeyComponent(withoutStandaloneNumbers)
        if !normalized.isEmpty {
            return normalized
        }

        return normalizedKeyComponent(bar.label)
    }

    private static func normalizedKeyComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func formatPercent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private static func formatCurrency(_ value: Double) -> String {
        currencyFormatter.string(from: NSNumber(value: value)) ?? "$\(String(format: "%.2f", value))"
    }

    private static func formatUsageAmount(used: Double, limit: Double) -> String {
        "\(formatNumber(used)) of \(formatNumber(limit))"
    }

    private static func formatNumber(_ value: Double) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

private extension UsageAlertDetail {
    var notificationBody: String {
        "\(title). \(message)"
    }
}

private extension UsageSeverity {
    var displayName: String {
        switch self {
        case .normal:
            "Normal"
        case .warning:
            "Warning"
        case .critical:
            "Critical"
        }
    }
}
