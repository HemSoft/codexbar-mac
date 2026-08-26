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
    private static let codexAdditionalResetJitterToleranceSeconds = 10.0
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

                guard !wasUsageAlertActive(
                    alertID,
                    result: result,
                    bar: bar,
                    activeAlertIDs: activeAlertIDs
                ) else {
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
                            body: severityNotificationBody(
                                result: result,
                                detail: detail
                            )
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
        let trigger = severityAlertTrigger(
            result: result,
            severity: severity,
            now: now
        )

        return UsageAlertDetail(
            id: id,
            accountID: result.accountID,
            kind: .severity,
            title: "\(severity.displayName) status",
            message: trigger?.message(accountName: result.title, severity: severity)
                ?? result.subtitle,
            severity: severity
        )
    }

    private static func severityNotificationBody(
        result: ProviderUsageResult,
        detail: UsageAlertDetail
    ) -> String {
        let providerName = result.providerID.displayName
        let accountIdentity = result.title == providerName
            ? providerName
            : "\(result.title) (\(providerName))"
        return "\(accountIdentity): \(detail.notificationBody)"
    }

    private static func severityAlertTrigger(
        result: ProviderUsageResult,
        severity: UsageSeverity,
        now: Date
    ) -> SeverityAlertTrigger? {
        if severity == .critical, result.hasReachedSpendLimit {
            return SeverityAlertTrigger(source: .spendLimit, bar: nil, fraction: nil)
        }

        let candidates = result.bars.compactMap { bar -> SeverityAlertTrigger? in
            if bar.severity == severity {
                return SeverityAlertTrigger(
                    source: .current,
                    bar: bar,
                    fraction: currentUsageFraction(for: bar)
                )
            }
            if bar.projectedSeverity(at: now) == severity,
               let projectedFraction = bar.projectedFraction(at: now)
            {
                return SeverityAlertTrigger(
                    source: .projected,
                    bar: bar,
                    fraction: projectedFraction
                )
            }
            return nil
        }

        // Prefer observed usage over a forecast, then the largest crossing.
        // Stable metric identity and label make equal crossings independent of array order.
        return candidates.sorted { lhs, rhs in
            if lhs.source.rank != rhs.source.rank {
                return lhs.source.rank < rhs.source.rank
            }
            if lhs.fraction != rhs.fraction {
                return (lhs.fraction ?? 0) > (rhs.fraction ?? 0)
            }
            let lhsKey = lhs.bar?.stableKey ?? ""
            let rhsKey = rhs.bar?.stableKey ?? ""
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            return (lhs.bar?.label ?? "") < (rhs.bar?.label ?? "")
        }.first
    }

    private static func currentUsageFraction(for bar: UsageBar) -> Double {
        guard bar.limit > 0 else {
            return bar.fractionUsed
        }
        return max(bar.used / bar.limit, 0)
    }

    private static func alertID(for result: ProviderUsageResult, bar: UsageBar) -> String {
        let stableKey = stableUsageKey(for: bar, providerID: result.providerID)
        if let resetsAt = bar.resetsAt {
            return "usage.\(result.accountID).\(stableKey).\(Int(resetsAt.timeIntervalSince1970))"
        }
        return "usage.\(result.accountID).\(stableKey)"
    }

    private static func stableUsageKey(for bar: UsageBar, providerID: ProviderID) -> String {
        if providerID == .codex {
            switch bar.stableKey {
            case "window-18000":
                return "hour-usage-limit"
            case "window-604800":
                return "weekly-usage-limit"
            case let stableKey?:
                return stableKey.contains(where: { $0.isUppercase })
                    ? "case-\(stableKey.utf8.map { String(format: "%02X", $0) }.joined())"
                    : normalizedKeyComponent(stableKey)
            default:
                break
            }
        }

        if bar.stableKey == ClaudeUsageIdentity.allModelsWeeklyStableKey {
            return ClaudeUsageIdentity.allModelsWeeklyLegacyKey
        }

        if let stableKey = bar.stableKey {
            let normalized = normalizedKeyComponent(stableKey)
            if !normalized.isEmpty {
                return normalized
            }
        }

        return legacyUsageKey(for: bar)
    }

    private static func wasUsageAlertActive(
        _ alertID: String,
        result: ProviderUsageResult,
        bar: UsageBar,
        activeAlertIDs: Set<String>
    ) -> Bool {
        if activeAlertIDs.contains(alertID) {
            return true
        }
        if result.providerID == .codex,
           bar.stableKey?.hasPrefix("bucket-") == true,
           let resetsAt = bar.resetsAt {
            let key = stableUsageKey(for: bar, providerID: result.providerID)
            let prefix = "usage.\(result.accountID).\(key)."
            let resetEpoch = Int(resetsAt.timeIntervalSince1970)
            let isWithinJitterTolerance = activeAlertIDs.contains { activeID in
                guard activeID.hasPrefix(prefix),
                      let activeResetEpoch = Int(activeID.dropFirst(prefix.count)) else {
                    return false
                }
                return abs(Double(activeResetEpoch) - Double(resetEpoch))
                    <= codexAdditionalResetJitterToleranceSeconds
            }
            if isWithinJitterTolerance {
                return true
            }
        }
        guard
            result.providerID == .codex,
            let stableKey = bar.stableKey,
            stableKey != "window-18000",
            stableKey != "window-604800",
            stableKey.range(of: #"^window-\d+$"#, options: .regularExpression) != nil
        else {
            return false
        }

        let legacyComponent = legacyUsageKey(for: bar)
        let legacyAlertID: String
        if let resetsAt = bar.resetsAt {
            legacyAlertID = "usage.\(result.accountID).\(legacyComponent).\(Int(resetsAt.timeIntervalSince1970))"
        } else {
            legacyAlertID = "usage.\(result.accountID).\(legacyComponent)"
        }
        return activeAlertIDs.contains(legacyAlertID)
    }

    private static func legacyUsageKey(for bar: UsageBar) -> String {
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

private func formatPercent(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

private struct SeverityAlertTrigger {
    enum Source: Equatable {
        case current
        case projected
        case spendLimit

        var rank: Int {
            switch self {
            case .spendLimit:
                0
            case .current:
                1
            case .projected:
                2
            }
        }
    }

    let source: Source
    let bar: UsageBar?
    let fraction: Double?

    func message(accountName: String, severity: UsageSeverity) -> String {
        guard source != .spendLimit else {
            return "\(accountName) reached its monthly usage-credit spend limit."
        }
        guard let bar, let fraction else {
            return accountName
        }

        let usageKind = source == .current ? "current usage" : "projected usage"
        return "\(bar.label) \(usageKind) is \(formatPercent(fraction)) "
            + "(\(severity.displayName) threshold: \(formatPercent(severity.alertThreshold)))."
    }
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

    var alertThreshold: Double {
        switch self {
        case .normal:
            0
        case .warning:
            UsageSeverity.warningThreshold
        case .critical:
            UsageSeverity.criticalThreshold
        }
    }
}
