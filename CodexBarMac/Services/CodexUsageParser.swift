import Foundation

public enum CodexUsageParser {
    private static let fiveHourDurationSeconds = 18_000
    private static let weeklyDurationSeconds = 604_800

    public static func parse(
        _ data: Data,
        fetchedAt: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> ProviderUsageResult? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rateLimit = root["rate_limit"] as? [String: Any]
        else {
            return nil
        }

        var windows: [CodexUsageWindow] = []
        addWindow(named: "primary_window", from: rateLimit, fetchedAt: fetchedAt, to: &windows)
        addWindow(named: "secondary_window", from: rateLimit, fetchedAt: fetchedAt, to: &windows)

        guard !windows.isEmpty else {
            return nil
        }

        windows.sort { $0.durationSeconds < $1.durationSeconds }
        let bars = windows.map { window in
            let usedFraction = window.usedPercent / 100
            return UsageBar(
                label: label(forDuration: window.durationSeconds),
                used: window.usedPercent,
                limit: 100,
                resetDescription: formatReset(
                    window.resetsAt,
                    now: fetchedAt,
                    dateTimeFormatter: dateTimeFormatter
                ),
                resetsAt: window.resetsAt,
                resetDisplayStyle: .relativeWithLocalTime,
                projectionCurrent: usedFraction,
                projectionLimit: 1,
                projectionPeriodStart: window.resetsAt.addingTimeInterval(TimeInterval(-window.durationSeconds)),
                projectionPeriodEnd: window.resetsAt,
                showProjectionOnCurrentBar: true
            )
        }
        return ProviderUsageResult(
            providerID: .codex,
            title: formatDisplayName(planType: root["plan_type"] as? String),
            subtitle: "Live ChatGPT usage",
            bars: bars,
            fetchedAt: fetchedAt
        )
    }

    private static func addWindow(
        named name: String,
        from rateLimit: [String: Any],
        fetchedAt: Date,
        to windows: inout [CodexUsageWindow]
    ) {
        guard
            let window = rateLimit[name] as? [String: Any],
            let usedPercent = doubleValue(window["used_percent"]),
            let durationSeconds = intValue(window["limit_window_seconds"])
        else {
            return
        }

        let resetsAt: Date
        if let resetEpoch = intValue(window["reset_at"]) {
            resetsAt = Date(timeIntervalSince1970: TimeInterval(resetEpoch))
        } else if let resetAfterSeconds = intValue(window["reset_after_seconds"]) {
            resetsAt = fetchedAt.addingTimeInterval(TimeInterval(resetAfterSeconds))
        } else {
            return
        }

        windows.append(
            CodexUsageWindow(
                usedPercent: min(max(usedPercent, 0), 100),
                resetsAt: resetsAt,
                durationSeconds: durationSeconds
            )
        )
    }

    private static func label(forDuration durationSeconds: Int) -> String {
        if isApproximateDuration(durationSeconds, expected: fiveHourDurationSeconds) {
            "5 hour usage limit"
        } else if isApproximateDuration(durationSeconds, expected: weeklyDurationSeconds) {
            "Weekly usage limit"
        } else if durationSeconds.isMultiple(of: 3_600) {
            "\(max(1, durationSeconds / 3_600)) hour usage limit"
        } else {
            "\(max(1, Int((Double(durationSeconds) / 60).rounded()))) minute usage limit"
        }
    }

    private static func isApproximateDuration(_ durationSeconds: Int, expected: Int) -> Bool {
        let tolerance = Double(expected) * 0.05
        return abs(Double(durationSeconds - expected)) <= tolerance
    }

    private static func formatReset(
        _ resetAt: Date,
        now: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> String {
        dateTimeFormatter.resetDescription(
            resetAt: resetAt,
            now: now,
            style: .relativeWithLocalTime,
            fallback: nil
        ) ?? "Resets now"
    }

    private static func formatDisplayName(planType: String?) -> String {
        guard let planType, !planType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ProviderID.codex.displayName
        }

        return "\(ProviderID.codex.displayName) (\(formatPlanName(planType)))"
    }

    private static func formatPlanName(_ planType: String) -> String {
        switch planType.lowercased() {
        case "free":
            "Free"
        case "plus":
            "Plus"
        case "pro", "prolite":
            "Pro"
        case "team":
            "Team"
        case "enterprise":
            "Enterprise"
        default:
            planType
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }

        if let value = value as? Double {
            return Int(value)
        }

        if let value = value as? String {
            return Int(value)
        }

        return nil
    }
}

private struct CodexUsageWindow {
    let usedPercent: Double
    let resetsAt: Date
    let durationSeconds: Int
}
