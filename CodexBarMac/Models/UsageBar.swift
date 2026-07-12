import Foundation

public struct UsageProjectionDescriptionParts: Equatable, Sendable {
    public let leadingText: String
    public let timestamp: Date?
    public let trailingText: String

    public init(leadingText: String, timestamp: Date? = nil, trailingText: String = "") {
        self.leadingText = leadingText
        self.timestamp = timestamp
        self.trailingText = trailingText
    }

    public func formatted(using formatter: UserFacingDateTimeFormatter) -> String {
        guard let timestamp else {
            return leadingText
        }

        return "\(leadingText)\(formatter.timeWithZone(timestamp, includesWeekday: true))\(trailingText)"
    }
}

public struct UsageBar: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let used: Double
    public let limit: Double
    public let resetDescription: String?
    public let resetsAt: Date?
    public let resetDisplayStyle: UsageResetDisplayStyle
    public let projectionCurrent: Double?
    public let projectionLimit: Double?
    public let projectionPeriodStart: Date?
    public let projectionPeriodEnd: Date?
    public let showProjectionOnCurrentBar: Bool
    public let projectionDescriptionOverride: String?

    public init(
        id: UUID = UUID(),
        label: String,
        used: Double,
        limit: Double,
        resetDescription: String? = nil,
        resetsAt: Date? = nil,
        resetDisplayStyle: UsageResetDisplayStyle = .verbatim,
        projectionCurrent: Double? = nil,
        projectionLimit: Double? = nil,
        projectionPeriodStart: Date? = nil,
        projectionPeriodEnd: Date? = nil,
        showProjectionOnCurrentBar: Bool = false,
        projectionDescriptionOverride: String? = nil
    ) {
        self.id = id
        self.label = label
        self.used = used
        self.limit = limit
        self.resetDescription = resetDescription
        self.resetsAt = resetsAt
        self.resetDisplayStyle = resetDisplayStyle
        self.projectionCurrent = projectionCurrent
        self.projectionLimit = projectionLimit
        self.projectionPeriodStart = projectionPeriodStart
        self.projectionPeriodEnd = projectionPeriodEnd
        self.showProjectionOnCurrentBar = showProjectionOnCurrentBar
        self.projectionDescriptionOverride = projectionDescriptionOverride
    }

    public var fractionUsed: Double {
        guard limit > 0 else {
            return 0
        }

        return min(max(used / limit, 0), 1)
    }

    public var severity: UsageSeverity {
        UsageSeverity(fractionUsed: fractionUsed)
    }

    public func projectedSeverity(at now: Date = Date()) -> UsageSeverity? {
        guard let projectedFraction = projectedFraction(at: now) else {
            return nil
        }

        return UsageSeverity(fractionUsed: projectedFraction)
    }

    public func effectiveSeverity(at now: Date = Date()) -> UsageSeverity {
        max(severity, projectedSeverity(at: now) ?? .normal)
    }

    public var usageText: String {
        guard limit > 0 else {
            return "0%"
        }

        return "\(Int((used / limit * 100).rounded()))%"
    }

    public func localizedResetDescription(
        at now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> String? {
        dateTimeFormatter.resetDescription(
            resetAt: resetsAt,
            now: now,
            style: resetDisplayStyle,
            fallback: resetDescription
        )
    }

    public func projectedFraction(at now: Date = Date()) -> Double? {
        guard
            let projectionCurrent,
            let projectionLimit,
            let projectionPeriodStart,
            let projectionPeriodEnd,
            projectionCurrent > 0,
            projectionLimit > 0
        else {
            return nil
        }

        let projected = Self.projectedUsage(
            current: projectionCurrent,
            periodStart: projectionPeriodStart,
            periodEnd: projectionPeriodEnd,
            now: now
        )

        return min(max(projected / projectionLimit, 0), 1)
    }

    public func projectionDescription(
        at now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> String? {
        projectionDescriptionParts(at: now)?.formatted(using: dateTimeFormatter)
    }

    public func projectionDescriptionParts(at now: Date = Date()) -> UsageProjectionDescriptionParts? {
        if let projectionDescriptionOverride {
            return UsageProjectionDescriptionParts(leadingText: projectionDescriptionOverride)
        }

        guard
            showProjectionOnCurrentBar,
            let projectionCurrent,
            let projectionLimit,
            let projectionPeriodStart,
            let projectionPeriodEnd,
            let projectedFraction = projectedFraction(at: now),
            projectedFraction > fractionUsed
        else {
            return nil
        }

        let limitHit = Self.limitHitDescriptionParts(
            current: projectionCurrent,
            limit: projectionLimit,
            periodStart: projectionPeriodStart,
            periodEnd: projectionPeriodEnd,
            now: now
        )

        guard limitHit.leadingText != Self.limitNotReachedDescription else {
            return UsageProjectionDescriptionParts(leadingText: "Projected to stay under limit")
        }

        return UsageProjectionDescriptionParts(
            leadingText: "Projected \(Int((projectedFraction * 100).rounded()))% at current pace - \(limitHit.leadingText)",
            timestamp: limitHit.timestamp,
            trailingText: limitHit.trailingText
        )
    }

    private static let limitNotReachedDescription = "Limit not reached"

    private static func projectedUsage(current: Double, periodStart: Date, periodEnd: Date, now: Date) -> Double {
        let elapsed = now.timeIntervalSince(periodStart)
        if elapsed <= 0 || now >= periodEnd {
            return current
        }

        let total = periodEnd.timeIntervalSince(periodStart)
        return current * total / elapsed
    }

    public static func formatLimitHit(
        current: Double,
        limit: Double,
        periodStart: Date,
        periodEnd: Date,
        now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> String {
        limitHitDescriptionParts(
            current: current,
            limit: limit,
            periodStart: periodStart,
            periodEnd: periodEnd,
            now: now
        ).formatted(using: dateTimeFormatter)
    }

    private static func limitHitDescriptionParts(
        current: Double,
        limit: Double,
        periodStart: Date,
        periodEnd: Date,
        now: Date
    ) -> UsageProjectionDescriptionParts {
        if current >= limit {
            return UsageProjectionDescriptionParts(leadingText: "Limit reached")
        }

        let elapsed = now.timeIntervalSince(periodStart)
        guard elapsed > 0 else {
            return UsageProjectionDescriptionParts(leadingText: "Limit hit unknown")
        }

        let ratePerSecond = current / elapsed
        guard ratePerSecond > 0 else {
            return UsageProjectionDescriptionParts(leadingText: "Limit hit unknown")
        }

        let secondsToLimit = limit / ratePerSecond
        let hitAt = periodStart.addingTimeInterval(secondsToLimit)
        if hitAt > periodEnd {
            return UsageProjectionDescriptionParts(leadingText: limitNotReachedDescription)
        }

        let earlyDescription = hitAt < periodEnd
            ? " - \(formatEarlyDuration(periodEnd.timeIntervalSince(hitAt))) early"
            : ""

        return UsageProjectionDescriptionParts(
            leadingText: "Limit hit ",
            timestamp: hitAt,
            trailingText: earlyDescription
        )
    }

    private static func formatEarlyDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []

        if days > 0 {
            parts.append("\(days)d")
        }

        if hours > 0 {
            parts.append("\(hours)h")
        }

        if minutes > 0 || parts.isEmpty {
            parts.append("\(minutes)m")
        }

        return parts.joined(separator: " ")
    }
}
