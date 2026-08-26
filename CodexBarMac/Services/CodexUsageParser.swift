import CoreFoundation
import Foundation

public enum CodexUsageParser {
    private static let fiveHourDurationSeconds = 18_000
    private static let weeklyDurationSeconds = 604_800
    private static let maximumWindowDurationSeconds = 315_360_000

    public static func parse(
        _ data: Data,
        fetchedAt: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> ProviderUsageResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var windows: [CodexUsageWindow] = []
        if let rateLimit = root["rate_limit"] as? [String: Any] {
            addWindows(
                from: rateLimit,
                bucketStableKey: nil,
                bucketLabel: nil,
                bucketOrder: 0,
                bucketInstanceStableKey: "root",
                fetchedAt: fetchedAt,
                to: &windows
            )
        }
        for key in root.keys.sorted() where key.hasSuffix("_rate_limit") && key != "rate_limit" {
            guard let rateLimit = root[key] as? [String: Any] else {
                continue
            }
            let identity = String(key.dropLast("_rate_limit".count))
            let identityStableKey = topLevelBucketStableKey(for: identity)
            addWindows(
                from: rateLimit,
                bucketStableKey: "bucket-\(identityStableKey)",
                bucketLabel: bucketLabel(from: identity),
                bucketOrder: 1,
                bucketInstanceStableKey: "top-\(identityStableKey)",
                fetchedAt: fetchedAt,
                to: &windows
            )
        }
        for additionalRateLimit in additionalRateLimits(from: root["additional_rate_limits"]) {
            let rateLimit = additionalRateLimit.value
            let meteredFeature = nonemptyString(rateLimit["metered_feature"])
                .flatMap(stableKeyComponent)
            let limitID = nonemptyString(rateLimit["limit_id"])
                .flatMap(stableKeyComponent)
            let stableComponent = if let meteredFeature, let limitID {
                "\(meteredFeature).limit-\(limitID)"
            } else {
                meteredFeature
                    ?? limitID
                    ?? nonemptyString(rateLimit["limit_name"]).flatMap(stableKeyComponent)
                    ?? "additional"
            }
            let rateLimitWindows = rateLimit["rate_limit"] as? [String: Any] ?? rateLimit
            addWindows(
                from: rateLimitWindows,
                bucketStableKey: "bucket-\(stableComponent)",
                bucketLabel: nonemptyString(rateLimit["limit_name"]) ?? "Additional Codex usage",
                bucketOrder: 2,
                bucketInstanceStableKey: additionalRateLimit.instanceStableKey,
                fetchedAt: fetchedAt,
                to: &windows
            )
        }

        guard !windows.isEmpty else {
            return nil
        }

        windows.sort {
            if $0.bucketOrder != $1.bucketOrder {
                return $0.bucketOrder < $1.bucketOrder
            }
            if $0.bucketStableKey != $1.bucketStableKey {
                return ($0.bucketStableKey ?? "") < ($1.bucketStableKey ?? "")
            }
            if $0.durationSeconds != $1.durationSeconds {
                return $0.durationSeconds < $1.durationSeconds
            }
            if $0.bucketLabel != $1.bucketLabel {
                return ($0.bucketLabel ?? "") < ($1.bucketLabel ?? "")
            }
            if $0.bucketInstanceStableKey != $1.bucketInstanceStableKey {
                return $0.bucketInstanceStableKey < $1.bucketInstanceStableKey
            }
            return $0.windowOrder < $1.windowOrder
        }
        let instanceKeyCounts = Dictionary(grouping: windows.filter { $0.bucketOrder != 0 }) {
            instanceStableKey(for: $0)
        }.mapValues(\.count)
        let bars = windows.map { window in
            let baseStableKey = stableKey(for: window)
            let stableKey: String
            if window.bucketOrder == 0 {
                stableKey = baseStableKey
            } else {
                let instanceKey = instanceStableKey(for: window)
                stableKey = instanceKeyCounts[instanceKey] == 1
                    ? instanceKey
                    : "\(instanceKey).slot-\(window.windowOrder)"
            }
            let usedFraction = window.usedPercent / 100
            return UsageBar(
                stableKey: stableKey,
                label: label(for: window),
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

    private static func addWindows(
        from rateLimit: [String: Any],
        bucketStableKey: String?,
        bucketLabel: String?,
        bucketOrder: Int,
        bucketInstanceStableKey: String,
        fetchedAt: Date,
        to windows: inout [CodexUsageWindow]
    ) {
        addWindow(
            named: "primary_window",
            windowOrder: 0,
            from: rateLimit,
            bucketStableKey: bucketStableKey,
            bucketLabel: bucketLabel,
            bucketOrder: bucketOrder,
            bucketInstanceStableKey: bucketInstanceStableKey,
            fetchedAt: fetchedAt,
            to: &windows
        )
        addWindow(
            named: "secondary_window",
            windowOrder: 1,
            from: rateLimit,
            bucketStableKey: bucketStableKey,
            bucketLabel: bucketLabel,
            bucketOrder: bucketOrder,
            bucketInstanceStableKey: bucketInstanceStableKey,
            fetchedAt: fetchedAt,
            to: &windows
        )
    }

    private static func addWindow(
        named name: String,
        windowOrder: Int,
        from rateLimit: [String: Any],
        bucketStableKey: String?,
        bucketLabel: String?,
        bucketOrder: Int,
        bucketInstanceStableKey: String,
        fetchedAt: Date,
        to windows: inout [CodexUsageWindow]
    ) {
        guard
            let window = rateLimit[name] as? [String: Any],
            let usedPercent = doubleValue(window["used_percent"]),
            let durationSeconds = durationSeconds(for: window, windowName: name),
            durationSeconds > 0,
            durationSeconds <= maximumWindowDurationSeconds
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
                durationSeconds: durationSeconds,
                bucketStableKey: bucketStableKey,
                bucketLabel: bucketLabel,
                bucketOrder: bucketOrder,
                bucketInstanceStableKey: bucketInstanceStableKey,
                windowOrder: windowOrder
            )
        )
    }

    private static func durationSeconds(for window: [String: Any], windowName: String) -> Int? {
        if let rawLimitWindowSeconds = window["limit_window_seconds"],
           !(rawLimitWindowSeconds is NSNull) {
            return intValue(rawLimitWindowSeconds)
        }

        if let rawWindowMinutes = window["window_minutes"],
           !(rawWindowMinutes is NSNull) {
            guard let windowMinutes = intValue(rawWindowMinutes) else {
                return nil
            }
            let (seconds, overflow) = windowMinutes.multipliedReportingOverflow(by: 60)
            return overflow ? nil : seconds
        }

        switch windowName {
        case "primary_window":
            return fiveHourDurationSeconds
        case "secondary_window":
            return weeklyDurationSeconds
        default:
            return nil
        }
    }

    private static func additionalRateLimits(from value: Any?) -> [CodexAdditionalRateLimit] {
        if let rateLimits = value as? [Any] {
            var identityOccurrences: [String: Int] = [:]
            return rateLimits.compactMap { value in
                guard let rateLimit = value as? [String: Any] else {
                    return nil
                }
                let identity = arrayBucketIdentity(for: rateLimit)
                let occurrence = identityOccurrences[identity, default: 0]
                identityOccurrences[identity] = occurrence + 1
                return CodexAdditionalRateLimit(
                    value: rateLimit,
                    instanceStableKey: "array-\(identity).occurrence-\(occurrence)"
                )
            }
        }
        guard let rateLimits = value as? [String: Any] else {
            return []
        }
        return rateLimits.keys.sorted().compactMap { key in
            guard var rateLimit = rateLimits[key] as? [String: Any] else {
                return nil
            }
            if nonemptyString(rateLimit["metered_feature"]) == nil {
                rateLimit["metered_feature"] = key
            }
            return CodexAdditionalRateLimit(
                value: rateLimit,
                instanceStableKey: "object-\(stableKeyComponent(key) ?? "other")"
            )
        }
    }

    private static func arrayBucketIdentity(for rateLimit: [String: Any]) -> String {
        let providerIdentityComponents = [
            ("feature", nonemptyString(rateLimit["metered_feature"])),
            ("limit", nonemptyString(rateLimit["limit_id"])),
        ].compactMap { label, value -> String? in
            guard let value, let encodedValue = stableKeyComponent(value) else {
                return nil
            }
            return "\(label)-\(encodedValue)"
        }
        if !providerIdentityComponents.isEmpty {
            return providerIdentityComponents.joined(separator: ".")
        }
        guard
            let limitName = nonemptyString(rateLimit["limit_name"]),
            let encodedLimitName = stableKeyComponent(limitName)
        else {
            return "unnamed"
        }
        return "name-\(encodedLimitName)"
    }

    private static func stableKeyComponent(_ value: String) -> String? {
        guard !value.isEmpty else {
            return nil
        }
        return value.utf8.map { byte in
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122:
                String(UnicodeScalar(byte))
            default:
                String(format: "_%02X", byte)
            }
        }.joined()
    }

    private static func topLevelBucketStableKey(for identity: String) -> String {
        guard let encodedIdentity = stableKeyComponent(identity) else {
            return "empty"
        }
        return "named-\(encodedIdentity)"
    }

    private static func bucketLabel(from identity: String) -> String {
        let words = identity
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard let first = words.first else {
            return "Other Codex usage"
        }
        return ([first.capitalized] + words.dropFirst().map { $0.lowercased() })
            .joined(separator: " ")
    }

    private static func stableKey(for window: CodexUsageWindow) -> String {
        let durationKey = "window-\(canonicalDuration(window.durationSeconds))"
        guard let bucketStableKey = window.bucketStableKey else {
            return durationKey
        }
        return "\(bucketStableKey).\(durationKey)"
    }

    private static func instanceStableKey(for window: CodexUsageWindow) -> String {
        "\(stableKey(for: window)).instance-\(window.bucketInstanceStableKey)"
    }

    private static func label(for window: CodexUsageWindow) -> String {
        let durationLabel = label(forDuration: window.durationSeconds)
        guard let bucketLabel = window.bucketLabel else {
            return durationLabel
        }
        return "\(bucketLabel) · \(durationLabel)"
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

    private static func canonicalDuration(_ durationSeconds: Int) -> Int {
        if isApproximateDuration(durationSeconds, expected: fiveHourDurationSeconds) {
            fiveHourDurationSeconds
        } else if isApproximateDuration(durationSeconds, expected: weeklyDurationSeconds) {
            weeklyDurationSeconds
        } else {
            durationSeconds
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
        let parsed: Double?
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            parsed = number.doubleValue
        } else if let value = value as? String {
            parsed = Double(value)
        } else {
            parsed = nil
        }
        guard let parsed, parsed.isFinite else {
            return nil
        }
        return parsed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? String {
            return Int(value)
        }
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite,
            number.doubleValue.rounded(.towardZero) == number.doubleValue
        else {
            return nil
        }
        return Int(exactly: number.doubleValue)
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CodexUsageWindow {
    let usedPercent: Double
    let resetsAt: Date
    let durationSeconds: Int
    let bucketStableKey: String?
    let bucketLabel: String?
    let bucketOrder: Int
    let bucketInstanceStableKey: String
    let windowOrder: Int
}

private struct CodexAdditionalRateLimit {
    let value: [String: Any]
    let instanceStableKey: String
}
