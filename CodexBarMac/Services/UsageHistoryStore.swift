import Combine
import Foundation

private enum UsageHistoryFormatting {
    static func formatCurrency(_ value: Double, currencyCode: String = "USD", decimalPlaces: Int = 2) -> String {
        value.formatted(
            .currency(code: currencyCode)
                .precision(.fractionLength(decimalPlaces))
        )
    }
}

public struct UsageHistoryBarSnapshot: Equatable, Codable, Sendable {
    public let stableKey: String?
    public let label: String
    public let fractionUsed: Double
    public let used: Double
    public let limit: Double
    public let effectiveSeverity: UsageSeverity

    private enum CodingKeys: String, CodingKey {
        case stableKey
        case label
        case fractionUsed
        case used
        case limit
        case effectiveSeverity
    }

    public init(bar: UsageBar, capturedAt: Date) {
        self.stableKey = bar.stableKey
        self.label = bar.label
        self.fractionUsed = bar.fractionUsed
        self.used = bar.used
        self.limit = bar.limit
        self.effectiveSeverity = bar.effectiveSeverity(at: capturedAt)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stableKey = try container.decodeIfPresent(String.self, forKey: .stableKey)
        self.label = try container.decode(String.self, forKey: .label)
        self.fractionUsed = try container.decode(Double.self, forKey: .fractionUsed)
        self.used = try container.decode(Double.self, forKey: .used)
        self.limit = try container.decode(Double.self, forKey: .limit)
        self.effectiveSeverity = try container.decodeIfPresent(
            UsageSeverity.self,
            forKey: .effectiveSeverity
        ) ?? UsageSeverity(fractionUsed: fractionUsed)
    }

    var historyFractionUsed: Double {
        guard limit > 0 else {
            return fractionUsed
        }

        let rawFraction = used / limit
        return rawFraction.isFinite ? max(rawFraction, 0) : fractionUsed
    }
}

public struct UsageHistoryMonetaryMetricSnapshot: Equatable, Codable, Sendable {
    public let kind: ProviderMonetaryMetricKind
    public let label: String
    public let minorUnits: Decimal
    public let currencyCode: String
    public let decimalPlaces: Int

    public init(metric: ProviderMonetaryMetric) {
        self.kind = metric.kind
        self.label = metric.label
        self.minorUnits = metric.minorUnits
        self.currencyCode = metric.currencyCode
        self.decimalPlaces = metric.decimalPlaces
    }
}

private protocol MonetaryMetricSnapshot {
    var metricKind: ProviderMonetaryMetricKind { get }
    var label: String { get }
    var minorUnits: Decimal { get }
    var currencyCode: String { get }
    var decimalPlaces: Int { get }
}

private extension MonetaryMetricSnapshot {
    var clampedDecimalPlaces: Int {
        min(max(decimalPlaces, 0), 6)
    }

    var doubleValue: Double {
        var divisor = Decimal(1)
        for _ in 0..<clampedDecimalPlaces {
            divisor *= 10
        }
        return NSDecimalNumber(decimal: minorUnits / divisor).doubleValue
    }
}

extension ProviderMonetaryMetric: MonetaryMetricSnapshot {
    fileprivate var metricKind: ProviderMonetaryMetricKind { kind }
}

extension UsageHistoryMonetaryMetricSnapshot: MonetaryMetricSnapshot {
    fileprivate var metricKind: ProviderMonetaryMetricKind { kind }
}

public struct UsageHistorySnapshot: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let accountID: String
    public let providerID: ProviderID
    public let title: String
    public let subtitle: String
    public let capturedAt: Date
    public let bars: [UsageHistoryBarSnapshot]
    public let creditsRemaining: Double?
    // Kept optional so pre-existing persisted snapshots (written before this field
    // existed) decode as `nil` instead of failing JSONDecoder entirely.
    public let monetaryMetrics: [UsageHistoryMonetaryMetricSnapshot]?
    public let highestSeverity: UsageSeverity

    public init(result: ProviderUsageResult, capturedAt: Date? = nil) {
        let capturedAt = capturedAt ?? result.fetchedAt
        let bars = result.historyFreshness.bars ? result.bars : []
        let creditsRemaining = result.historyFreshness.credits
            ? result.creditsRemaining
            : nil
        let monetaryMetrics = result.historyFreshness.monetaryMetrics
            ? result.monetaryMetrics
            : []
        self.id = "\(result.accountID).\(capturedAt.timeIntervalSince1970)"
        self.accountID = result.accountID
        self.providerID = result.providerID
        self.title = result.title
        self.subtitle = result.subtitle
        self.capturedAt = capturedAt
        self.bars = bars.map {
            UsageHistoryBarSnapshot(bar: $0, capturedAt: capturedAt)
        }
        self.creditsRemaining = creditsRemaining
        self.monetaryMetrics = monetaryMetrics.map(UsageHistoryMonetaryMetricSnapshot.init)
        self.highestSeverity = max(
            bars.map { $0.effectiveSeverity(at: capturedAt) }.max() ?? .normal,
            result.historyFreshness.monetaryMetrics && result.hasReachedSpendLimit
                ? .critical
                : .normal
        )
    }

    fileprivate init(
        presenting current: UsageHistorySnapshot,
        preservingMissingValuesFrom stored: UsageHistorySnapshot
    ) {
        let bars = current.bars.isEmpty ? stored.bars : current.bars
        let currentMonetaryMetrics = current.monetaryMetrics ?? []
        var monetaryMetrics = stored.monetaryMetrics ?? []
        for metric in currentMonetaryMetrics {
            if let matchingIndex = monetaryMetrics.firstIndex(where: {
                $0.kind == metric.kind && $0.currencyCode == metric.currencyCode
            }) {
                monetaryMetrics[matchingIndex] = metric
            } else {
                monetaryMetrics.append(metric)
            }
        }

        self.id = current.id
        self.accountID = current.accountID
        self.providerID = current.providerID
        self.title = current.title
        self.subtitle = current.subtitle
        self.capturedAt = current.capturedAt
        self.bars = bars
        self.creditsRemaining = current.creditsRemaining ?? stored.creditsRemaining
        self.monetaryMetrics = monetaryMetrics.isEmpty ? nil : monetaryMetrics
        let currentBarSeverity = current.bars.map(\.effectiveSeverity).max() ?? .normal
        let storedBarSeverity = stored.bars.map(\.effectiveSeverity).max() ?? .normal
        let currentMonetarySeverity = current.highestSeverity > currentBarSeverity
            ? current.highestSeverity
            : .normal
        let storedMonetarySeverity = stored.highestSeverity > storedBarSeverity
            ? stored.highestSeverity
            : .normal
        let preservedMonetarySeverity = determinesSpendLimit(in: currentMonetaryMetrics)
            ? currentMonetarySeverity
            : max(currentMonetarySeverity, storedMonetarySeverity)
        self.highestSeverity = max(
            bars.map(\.effectiveSeverity).max() ?? .normal,
            preservedMonetarySeverity,
            hasReachedSpendLimit(in: monetaryMetrics) ? .critical : .normal
        )
    }

    fileprivate init(
        dailyComponentOf snapshot: UsageHistorySnapshot,
        component: DailyUsageHistoryComponent
    ) {
        self.id = "\(snapshot.id).daily.\(component.id)"
        self.accountID = snapshot.accountID
        self.providerID = snapshot.providerID
        self.title = snapshot.title
        self.subtitle = snapshot.subtitle
        self.capturedAt = snapshot.capturedAt
        switch component {
        case let .bar(bar, _):
            self.bars = [bar]
            self.creditsRemaining = nil
            self.monetaryMetrics = nil
        case .credits:
            self.bars = []
            self.creditsRemaining = snapshot.creditsRemaining
            self.monetaryMetrics = nil
        case let .monetaryMetric(metric):
            self.bars = []
            self.creditsRemaining = nil
            self.monetaryMetrics = [metric]
        }
        self.highestSeverity = snapshot.highestSeverity
    }

    public var primaryValue: Double? {
        if let creditsRemaining {
            return creditsRemaining
        }

        if providerID == .cursor,
           let total = bars.first(where: {
               $0.stableKey == CursorUsageIdentity.totalStableKey
                   || ($0.stableKey == nil
                       && CursorUsageIdentity.matchesLegacyLabel(
                           $0.label,
                           stableKey: CursorUsageIdentity.totalStableKey
                       ))
           })
        {
            return total.historyFractionUsed
        }

        if let usage = bars.map(\.historyFractionUsed).max() {
            return usage
        }

        return monetaryPrimaryValue
    }

    fileprivate var monetaryPrimaryValue: Double? {
        if let creditsRemaining {
            return creditsRemaining
        }
        return primaryBalanceLikeMetric(in: monetaryMetrics ?? [])?.doubleValue
    }
}

private func primaryBalanceLikeMetric<T>(in metrics: [T]) -> T? where T: MonetaryMetricSnapshot {
    metrics.first(where: { $0.metricKind == .balance })
        ?? metrics.first(where: { $0.metricKind == .remainingHeadroom })
}

private func hasReachedSpendLimit<T>(in metrics: [T]) -> Bool where T: MonetaryMetricSnapshot {
    metrics.contains { spent in
        guard spent.metricKind == .spent else {
            return false
        }
        return metrics.contains { limit in
            limit.metricKind == .spendLimit
                && limit.currencyCode == spent.currencyCode
                && limit.decimalPlaces == spent.decimalPlaces
                && limit.minorUnits > 0
                && spent.minorUnits >= limit.minorUnits
        }
    }
}

private func determinesSpendLimit<T>(in metrics: [T]) -> Bool where T: MonetaryMetricSnapshot {
    metrics.contains { spent in
        guard spent.metricKind == .spent else {
            return false
        }
        return metrics.contains { limit in
            limit.metricKind == .spendLimit
                && limit.currencyCode == spent.currencyCode
                && limit.decimalPlaces == spent.decimalPlaces
        }
    }
}

private struct PrimaryMonetarySeriesIdentity {
    let kind: ProviderMonetaryMetricKind
    let label: String
    let currencyCode: String
    let decimalPlaces: Int

    init<T>(metric: T) where T: MonetaryMetricSnapshot {
        self.kind = metric.metricKind
        self.label = metric.label
        self.currencyCode = metric.currencyCode
        self.decimalPlaces = metric.decimalPlaces
    }
}

private func primaryMonetarySeriesIdentity(
    for result: ProviderUsageResult,
    snapshots: [UsageHistorySnapshot]
) -> PrimaryMonetarySeriesIdentity? {
    guard result.creditsRemaining == nil && result.bars.isEmpty else {
        return nil
    }
    if let metric = primaryBalanceLikeMetric(in: result.monetaryMetrics) {
        return PrimaryMonetarySeriesIdentity(metric: metric)
    }
    return snapshots.reversed().lazy.compactMap { snapshot in
        primaryBalanceLikeMetric(in: snapshot.monetaryMetrics ?? []).map {
            PrimaryMonetarySeriesIdentity(metric: $0)
        }
    }.first
}

public struct UsageTrendSummary: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case up
        case down
        case flat
    }

    public let accountID: String
    public let points: [Double]
    public let valueDescription: String
    public let windowDescription: String
    public let isBalance: Bool
    public let direction: Direction
}

public struct UsageHistoryPoint: Identifiable, Equatable, Sendable {
    public let id: String
    public let capturedAt: Date
    public let value: Double
    public let severity: UsageSeverity

    public init(id: String, capturedAt: Date, value: Double, severity: UsageSeverity) {
        self.id = id
        self.capturedAt = capturedAt
        self.value = value
        self.severity = severity
    }

    public init(snapshot: UsageHistorySnapshot, value: Double) {
        self.init(
            id: snapshot.id,
            capturedAt: snapshot.capturedAt,
            value: value,
            severity: snapshot.highestSeverity
        )
    }
}

enum DailyUsageHistoryComponent {
    case bar(UsageHistoryBarSnapshot, providerID: ProviderID)
    case credits
    case monetaryMetric(UsageHistoryMonetaryMetricSnapshot)

    var id: String {
        switch self {
        case let .bar(bar, providerID):
            "bar.\(Self.barIdentity(bar, providerID: providerID))"
        case .credits:
            "credits"
        case let .monetaryMetric(metric):
            "money.\(metric.kind.rawValue).\(metric.currencyCode)"
        }
    }

    static func barIdentity(
        _ bar: UsageHistoryBarSnapshot,
        providerID: ProviderID
    ) -> String {
        guard let stableKey = bar.stableKey else {
            return "legacy.\(bar.label.lowercased())"
        }
        return providerID == .cursor
            ? CursorUsageIdentity.canonicalStableKey(stableKey)
            : stableKey
    }
}

public struct UsageHistorySeries: Equatable, Sendable {
    public let accountID: String
    public let points: [UsageHistoryPoint]
    public let isBalance: Bool
    public let isIncreaseFavorable: Bool
    public let currencyCode: String?
    public let decimalPlaces: Int

    public init(
        accountID: String,
        points: [UsageHistoryPoint],
        isBalance: Bool,
        isIncreaseFavorable: Bool? = nil,
        currencyCode: String? = nil,
        decimalPlaces: Int = 2
    ) {
        self.accountID = accountID
        var pointsByTimestamp: [Date: UsageHistoryPoint] = [:]
        for point in points {
            if let existingPoint = pointsByTimestamp[point.capturedAt],
               !isBalance,
               existingPoint.value >= point.value {
                continue
            }
            pointsByTimestamp[point.capturedAt] = point
        }
        self.points = pointsByTimestamp.values.sorted { $0.capturedAt < $1.capturedAt }
        self.isBalance = isBalance
        self.isIncreaseFavorable = isIncreaseFavorable ?? isBalance
        self.currencyCode = currencyCode
        self.decimalPlaces = decimalPlaces
    }

    public var latestValueDescription: String {
        points.last.map { valueDescription(for: $0.value) } ?? "No data"
    }

    public var minimumValueDescription: String {
        points.map(\.value).min().map(valueDescription(for:)) ?? "--"
    }

    public var maximumValueDescription: String {
        points.map(\.value).max().map(valueDescription(for:)) ?? "--"
    }

    public var rangeDescription: String {
        guard
            let minimum = points.map(\.value).min(),
            let maximum = points.map(\.value).max()
        else {
            return "No range yet"
        }

        if abs(maximum - minimum) < Self.flatDeltaThreshold {
            return "Flat at \(valueDescription(for: maximum))"
        }

        return "Range \(valueDescription(for: minimum)) to \(valueDescription(for: maximum))"
    }

    public var changeDescription: String {
        guard let latestDelta else {
            return points.isEmpty ? "No history yet" : "Collecting history"
        }

        guard direction != .flat else {
            return "No change"
        }

        let directionDescription = direction == .up ? "Up" : "Down"
        if isBalance {
            let formattedDelta = UsageHistoryFormatting.formatCurrency(
                abs(latestDelta),
                currencyCode: currencyCode ?? "USD",
                decimalPlaces: decimalPlaces
            )
            return "\(directionDescription) \(formattedDelta)"
        }

        return "\(directionDescription) \(Int((abs(latestDelta) * 100).rounded())) pts"
    }

    public var sampleWindowDescription: String {
        guard let first = points.first, let last = points.last else {
            return "No samples"
        }

        let count = points.count
        let sampleText = "\(count) sample\(count == 1 ? "" : "s")"
        if Calendar.autoupdatingCurrent.isDate(first.capturedAt, inSameDayAs: last.capturedAt) {
            return "\(sampleText) - \(UserFacingDateTimeFormatter.current.shortDate(last.capturedAt))"
        }

        let formatter = UserFacingDateTimeFormatter.current
        return "\(sampleText) - \(formatter.shortDate(first.capturedAt)) - \(formatter.shortDate(last.capturedAt))"
    }

    public var direction: UsageTrendSummary.Direction {
        guard let latestDelta else {
            return .flat
        }

        if abs(latestDelta) < Self.flatDeltaThreshold {
            return .flat
        }

        return latestDelta > 0 ? .up : .down
    }

    public var chartDomain: ClosedRange<Double> {
        guard isBalance else {
            guard let maximum = points.map(\.value).max(), maximum > 1 else {
                return 0...1
            }

            let padding = max((maximum - 1) * 0.15, 0.01)
            return 0...(maximum + padding)
        }

        guard
            let minimum = points.map(\.value).min(),
            let maximum = points.map(\.value).max()
        else {
            return 0...1
        }

        let span = maximum - minimum
        let padding = span > 0
            ? max(span * 0.15, 0.25)
            : max(abs(maximum) * 0.08, 1)
        let lowerBound = minimum < 0 ? minimum - padding : max(0, minimum - padding)
        let upperBound = max(maximum + padding, lowerBound + 1)
        return lowerBound...upperBound
    }

    public func valueDescription(for value: Double) -> String {
        if isBalance {
            return UsageHistoryFormatting.formatCurrency(
                value,
                currencyCode: currencyCode ?? "USD",
                decimalPlaces: decimalPlaces
            )
        }

        return "\(Int((value * 100).rounded()))%"
    }

    fileprivate var latestDelta: Double? {
        guard points.count >= 2 else {
            return nil
        }

        return points[points.count - 1].value - points[points.count - 2].value
    }

    private static let flatDeltaThreshold = 0.0001

    public func filtered(
        to range: UsageHistoryRange,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> UsageHistorySeries {
        UsageHistorySeries(
            accountID: accountID,
            points: points.filter {
                $0.capturedAt >= range.startDate(now: now, calendar: calendar)
            },
            isBalance: isBalance,
            isIncreaseFavorable: isIncreaseFavorable,
            currencyCode: currencyCode,
            decimalPlaces: decimalPlaces
        )
    }
}

public enum UsageHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case threeDays
    case sevenDays
    case month
    case threeMonths

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today:
            "Today"
        case .threeDays:
            "3 days"
        case .sevenDays:
            "7 days"
        case .month:
            "A month"
        case .threeMonths:
            "3 months"
        }
    }

    public var compactTitle: String {
        switch self {
        case .today:
            "Today"
        case .threeDays:
            "3D"
        case .sevenDays:
            "7D"
        case .month:
            "1M"
        case .threeMonths:
            "3M"
        }
    }

    public func startDate(
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let daysBack: Int
        switch self {
        case .today:
            daysBack = 0
        case .threeDays:
            daysBack = 2
        case .sevenDays:
            daysBack = 6
        case .month:
            daysBack = 29
        case .threeMonths:
            daysBack = 89
        }
        return calendar.date(byAdding: .day, value: -daysBack, to: startOfToday)
            ?? startOfToday
    }
}

public struct UsageHistorySeriesOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let series: UsageHistorySeries

    public init(id: String, label: String, series: UsageHistorySeries) {
        self.id = id
        self.label = label
        self.series = series
    }
}

@MainActor
public final class UsageHistoryStore: ObservableObject {
    @Published public private(set) var snapshots: [UsageHistorySnapshot]
    @Published public private(set) var dailySnapshots: [UsageHistorySnapshot]
    @Published public private(set) var lastError: String?
    @Published public private(set) var requiresRecovery: Bool

    private static let detailedRecentSnapshotCount = 120
    private static let loadErrorMessage =
        "Saved usage history could not be read. Reset history to resume recording."

    private let defaults: UserDefaults
    private let encodeSnapshots: ([UsageHistorySnapshot]) throws -> Data
    private let encodeDailySnapshots: ([UsageHistorySnapshot]) throws -> Data
    private let retention: TimeInterval
    private let dailyRetentionDays: Int
    private let maxSnapshotsPerAccount: Int
    private let storageKey = "usageHistorySnapshots"
    private let dailyStorageKey = "usageHistoryDailySnapshots"

    public convenience init(
        defaults: UserDefaults = .standard,
        retentionDays: Int = 30,
        dailyRetentionDays: Int = 90,
        maxSnapshotsPerAccount: Int = 240
    ) {
        self.init(
            defaults: defaults,
            retentionDays: retentionDays,
            dailyRetentionDays: dailyRetentionDays,
            maxSnapshotsPerAccount: maxSnapshotsPerAccount,
            encodeSnapshots: { try JSONEncoder().encode($0) },
            encodeDailySnapshots: { try JSONEncoder().encode($0) }
        )
    }

    convenience init(
        defaults: UserDefaults,
        retentionDays: Int = 30,
        dailyRetentionDays: Int = 90,
        maxSnapshotsPerAccount: Int = 240,
        encodeSnapshots: @escaping ([UsageHistorySnapshot]) throws -> Data
    ) {
        self.init(
            defaults: defaults,
            retentionDays: retentionDays,
            dailyRetentionDays: dailyRetentionDays,
            maxSnapshotsPerAccount: maxSnapshotsPerAccount,
            encodeSnapshots: encodeSnapshots,
            encodeDailySnapshots: { try JSONEncoder().encode($0) }
        )
    }

    init(
        defaults: UserDefaults,
        retentionDays: Int = 30,
        dailyRetentionDays: Int = 90,
        maxSnapshotsPerAccount: Int = 240,
        encodeSnapshots: @escaping ([UsageHistorySnapshot]) throws -> Data,
        encodeDailySnapshots: @escaping ([UsageHistorySnapshot]) throws -> Data
    ) {
        self.defaults = defaults
        self.encodeSnapshots = encodeSnapshots
        self.encodeDailySnapshots = encodeDailySnapshots
        self.retention = TimeInterval(max(retentionDays, 1) * 24 * 60 * 60)
        self.dailyRetentionDays = max(dailyRetentionDays, 90)
        self.maxSnapshotsPerAccount = max(maxSnapshotsPerAccount, 1)
        let snapshotsState = Self.loadedState(defaults: defaults, storageKey: storageKey)
        let dailySnapshotsState = Self.loadedState(defaults: defaults, storageKey: dailyStorageKey)
        let requiresRecovery = snapshotsState.requiresRecovery
            || dailySnapshotsState.requiresRecovery
        self.snapshots = requiresRecovery ? [] : snapshotsState.snapshots
        self.dailySnapshots = requiresRecovery ? [] : dailySnapshotsState.snapshots
        self.lastError = requiresRecovery ? Self.loadErrorMessage : nil
        self.requiresRecovery = requiresRecovery
    }

    public func record(
        results: [ProviderUsageResult],
        now: Date = Date(),
        samplingInterval: TimeInterval = 0
    ) {
        guard !requiresRecovery else {
            return
        }

        let recordableResults = results.filter { result in
            result.historyFreshness.bars && !result.bars.isEmpty
                || result.historyFreshness.credits && result.creditsRemaining != nil
                || result.historyFreshness.monetaryMetrics && !result.monetaryMetrics.isEmpty
        }
        guard !recordableResults.isEmpty else {
            return
        }

        let previousSnapshots = snapshots
        let previousDailySnapshots = dailySnapshots
        var snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        var latestCaptureByAccountID = snapshots.reduce(into: [String: Date]()) {
            latestCaptureByAccountID,
            snapshot in
            latestCaptureByAccountID[snapshot.accountID] = max(
                latestCaptureByAccountID[snapshot.accountID] ?? snapshot.capturedAt,
                snapshot.capturedAt
            )
        }
        for snapshot in recordableResults.map({ UsageHistorySnapshot(result: $0) }) {
            updateDailySnapshots(from: snapshot)
            if samplingInterval > 0,
               let latestCapture = latestCaptureByAccountID[snapshot.accountID],
               snapshot.capturedAt.timeIntervalSince(latestCapture) < samplingInterval {
                continue
            }
            snapshotsByID[snapshot.id] = snapshot
            latestCaptureByAccountID[snapshot.accountID] = max(
                latestCaptureByAccountID[snapshot.accountID] ?? snapshot.capturedAt,
                snapshot.capturedAt
            )
        }
        snapshots = Array(snapshotsByID.values)
        prune(now: now, validAccountIDs: Set(recordableResults.map(\.accountID)), removeMissingAccounts: false)
        guard snapshots != previousSnapshots || dailySnapshots != previousDailySnapshots else {
            return
        }
        save(
            restoringOnFailure: previousSnapshots,
            previousDailySnapshots: previousDailySnapshots
        )
    }

    public func removeSnapshotsForMissingAccounts(validAccountIDs: Set<String>, now: Date = Date()) {
        guard !requiresRecovery else {
            return
        }

        let previousSnapshots = snapshots
        let previousDailySnapshots = dailySnapshots
        prune(now: now, validAccountIDs: validAccountIDs, removeMissingAccounts: true)
        save(
            restoringOnFailure: previousSnapshots,
            previousDailySnapshots: previousDailySnapshots
        )
    }

    public func discardCorruptedHistory() {
        guard requiresRecovery else {
            return
        }

        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: dailyStorageKey)
        snapshots = []
        dailySnapshots = []
        requiresRecovery = false
        lastError = nil
    }

    public func snapshots(for accountID: String, since start: Date? = nil) -> [UsageHistorySnapshot] {
        snapshots
            .filter { snapshot in
                snapshot.accountID == accountID && start.map { snapshot.capturedAt >= $0 } != false
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    public func historySeries(
        for result: ProviderUsageResult,
        since start: Date? = nil
    ) -> UsageHistorySeries {
        let accountSnapshots = presentationSnapshots(for: result, since: start)
        let primaryMonetaryIdentity = primaryMonetarySeriesIdentity(
            for: result,
            snapshots: accountSnapshots
        )
        let isBalance: Bool
        if result.creditsRemaining != nil {
            isBalance = true
        } else if !result.bars.isEmpty {
            isBalance = false
        } else if primaryMonetaryIdentity != nil {
            isBalance = true
        } else {
            isBalance = accountSnapshots.last.map {
                $0.creditsRemaining != nil || primaryBalanceLikeMetric(in: $0.monetaryMetrics ?? []) != nil
            } ?? false
        }

        if !isBalance, primaryMonetaryIdentity == nil, result.providerID == .cursor {
            return cursorPrimaryUsageSeries(
                accountID: result.accountID,
                snapshots: accountSnapshots
            )
        }

        let points = accountSnapshots.compactMap { snapshot -> UsageHistoryPoint? in
            let value: Double?
            if let primaryMonetaryIdentity {
                value = snapshot.monetaryMetrics?.first(where: {
                    $0.kind == primaryMonetaryIdentity.kind
                        && $0.currencyCode == primaryMonetaryIdentity.currencyCode
                })?.doubleValue
            } else if isBalance {
                value = snapshot.creditsRemaining
            } else {
                guard !snapshot.bars.isEmpty else {
                    return nil
                }
                value = snapshot.bars.map(\.historyFractionUsed).max()
            }
            return value.map { UsageHistoryPoint(snapshot: snapshot, value: $0) }
        }

        return UsageHistorySeries(
            accountID: result.accountID,
            points: points,
            isBalance: isBalance,
            currencyCode: primaryMonetaryIdentity?.currencyCode,
            decimalPlaces: min(max(primaryMonetaryIdentity?.decimalPlaces ?? 2, 0), 6)
        )
    }

    public func historySeriesOptions(
        for result: ProviderUsageResult,
        since start: Date? = nil
    ) -> [UsageHistorySeriesOption] {
        let accountSnapshots = presentationSnapshots(for: result, since: start)
        var options: [UsageHistorySeriesOption] = []
        let primaryMonetaryIdentity = primaryMonetarySeriesIdentity(
            for: result,
            snapshots: accountSnapshots
        )

        if result.providerID == .cursor && (!result.bars.isEmpty || accountSnapshots.contains(where: {
            !$0.bars.isEmpty
        })) {
            options.append(contentsOf: cursorUsageSeriesOptions(
                accountID: result.accountID,
                snapshots: accountSnapshots,
                currentBars: result.bars
            ))
        } else if !result.bars.isEmpty || result.creditsRemaining != nil {
            options.append(UsageHistorySeriesOption(
                id: "primary",
                label: result.creditsRemaining == nil ? "Usage" : "Balance",
                series: historySeries(for: result, since: start)
            ))
        } else if let primaryMonetaryIdentity {
            options.append(UsageHistorySeriesOption(
                id: "primary",
                label: primaryMonetaryIdentity.label,
                series: historySeries(for: result, since: start)
            ))
        }

        for metric in result.monetaryMetrics where
            metric.kind != primaryMonetaryIdentity?.kind
                || metric.currencyCode != primaryMonetaryIdentity?.currencyCode
        {
            let points = accountSnapshots.compactMap { snapshot -> UsageHistoryPoint? in
                guard let storedMetric = snapshot.monetaryMetrics?.first(where: {
                    $0.kind == metric.kind && $0.currencyCode == metric.currencyCode
                }) else {
                    return nil
                }
                return UsageHistoryPoint(snapshot: snapshot, value: storedMetric.doubleValue)
            }
            options.append(UsageHistorySeriesOption(
                id: "money.\(metric.id)",
                label: metric.label,
                series: UsageHistorySeries(
                    accountID: result.accountID,
                    points: points,
                    isBalance: true,
                    isIncreaseFavorable: metric.kind != .spent,
                    currencyCode: metric.currencyCode,
                    decimalPlaces: metric.clampedDecimalPlaces
                )
            ))
        }

        return options.isEmpty
            ? [UsageHistorySeriesOption(
                id: "primary",
                label: "Usage",
                series: historySeries(for: result, since: start)
            )]
            : options
    }

    private func presentationSnapshots(
        for result: ProviderUsageResult,
        since start: Date?
    ) -> [UsageHistorySnapshot] {
        var accountSnapshots = storedPresentationSnapshots(
            for: result.accountID,
            since: start
        )
        guard
            !result.isIncompleteRefresh,
            start.map({ result.fetchedAt >= $0 }) != false,
            accountSnapshots.last.map({ result.fetchedAt >= $0.capturedAt }) != false
        else {
            return accountSnapshots
        }

        let currentSnapshot = UsageHistorySnapshot(result: result)
        guard
            !currentSnapshot.bars.isEmpty
                || currentSnapshot.creditsRemaining != nil
                || currentSnapshot.monetaryMetrics?.isEmpty == false
        else {
            return accountSnapshots
        }

        if let matchingIndex = accountSnapshots.lastIndex(where: {
            $0.capturedAt == currentSnapshot.capturedAt
        }) {
            accountSnapshots[matchingIndex] = UsageHistorySnapshot(
                presenting: currentSnapshot,
                preservingMissingValuesFrom: accountSnapshots[matchingIndex]
            )
        } else {
            accountSnapshots.append(currentSnapshot)
        }
        return accountSnapshots
    }

    private static func cursorPrimaryBar(
        in snapshot: UsageHistorySnapshot
    ) -> UsageHistoryBarSnapshot? {
        snapshot.bars.first(where: {
            Self.matchesCursorBar($0, stableKey: CursorUsageIdentity.totalStableKey)
        }) ?? snapshot.bars.max(by: { $0.historyFractionUsed < $1.historyFractionUsed })
    }

    private func cursorUsageSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        stableKey: String
    ) -> UsageHistorySeries {
        UsageHistorySeries(
            accountID: accountID,
            points: snapshots.compactMap { snapshot in
                snapshot.bars.first(where: {
                    Self.matchesCursorBar($0, stableKey: stableKey)
                }).map {
                    UsageHistoryPoint(
                        id: snapshot.id,
                        capturedAt: snapshot.capturedAt,
                        value: $0.historyFractionUsed,
                        severity: $0.effectiveSeverity
                    )
                }
            },
            isBalance: false
        )
    }

    private static func matchesCursorBar(
        _ bar: UsageHistoryBarSnapshot,
        stableKey: String
    ) -> Bool {
        if let storedStableKey = bar.stableKey {
            return CursorUsageIdentity.acceptedStableKeys(for: stableKey).contains(storedStableKey)
        }
        return CursorUsageIdentity.matchesLegacyLabel(bar.label, stableKey: stableKey)
    }

    private func cursorPrimaryUsageSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot]
    ) -> UsageHistorySeries {
        let snapshotsByTimestamp = Dictionary(grouping: snapshots, by: \.capturedAt)
        return UsageHistorySeries(
            accountID: accountID,
            points: snapshotsByTimestamp.compactMap { capturedAt, matchingSnapshots in
                let selected = matchingSnapshots.compactMap { snapshot in
                    Self.cursorPrimaryBar(in: snapshot).map { (snapshot, $0) }
                }.max { lhs, rhs in
                    let lhsIsTotal = lhs.1.stableKey == CursorUsageIdentity.totalStableKey
                    let rhsIsTotal = rhs.1.stableKey == CursorUsageIdentity.totalStableKey
                    if lhsIsTotal != rhsIsTotal {
                        return !lhsIsTotal
                    }
                    return lhs.1.historyFractionUsed < rhs.1.historyFractionUsed
                }
                return selected.map { snapshot, bar in
                    UsageHistoryPoint(
                        id: snapshot.id,
                        capturedAt: capturedAt,
                        value: bar.historyFractionUsed,
                        severity: bar.effectiveSeverity
                    )
                }
            },
            isBalance: false
        )
    }

    private func cursorUsageSeriesOptions(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        currentBars: [UsageBar]
    ) -> [UsageHistorySeriesOption] {
        let metricOptions: [UsageHistorySeriesOption] =
            CursorUsageIdentity.metricDefinitions.compactMap { stableKey, label in
                let acceptedStableKeys = CursorUsageIdentity.acceptedStableKeys(for: stableKey)
                let isAvailable = currentBars.contains(where: {
                    $0.stableKey.map(acceptedStableKeys.contains) == true
                })
                    || snapshots.contains(where: { snapshot in
                        snapshot.bars.contains(where: {
                            Self.matchesCursorBar($0, stableKey: stableKey)
                        })
                    })
                guard isAvailable else {
                    return nil
                }

                return UsageHistorySeriesOption(
                    id: "usage.\(stableKey)",
                    label: label,
                    series: cursorUsageSeries(
                        accountID: accountID,
                        snapshots: snapshots,
                        stableKey: stableKey
                    )
                )
            }

        if metricOptions.contains(where: {
            $0.id == "usage.\(CursorUsageIdentity.totalStableKey)"
        }) {
            // Older snapshots may predate Cursor's Total bar, so keep their highest
            // available value in the default series while preserving named metrics.
            let snapshotsByTimestamp = Dictionary(grouping: snapshots, by: \.capturedAt)
            let hasFallbackSamples = snapshotsByTimestamp.values.contains(where: { matchingSnapshots in
                let bars = matchingSnapshots.flatMap(\.bars)
                return !bars.isEmpty
                    && !bars.contains(where: {
                        $0.stableKey == CursorUsageIdentity.totalStableKey
                            || ($0.stableKey == nil
                                && CursorUsageIdentity.matchesLegacyLabel(
                                    $0.label,
                                    stableKey: CursorUsageIdentity.totalStableKey
                                ))
                    })
            })
            if hasFallbackSamples {
                return [
                    UsageHistorySeriesOption(
                        id: "usage",
                        label: "Total / highest available",
                        series: cursorPrimaryUsageSeries(
                            accountID: accountID,
                            snapshots: snapshots
                        )
                    ),
                ] + metricOptions
            }

            return metricOptions
        } else {
            return [
                UsageHistorySeriesOption(
                    id: "usage",
                    label: "Highest usage",
                    series: cursorPrimaryUsageSeries(accountID: accountID, snapshots: snapshots)
                ),
            ] + metricOptions
        }
    }

    public func trendSummary(for result: ProviderUsageResult, now: Date = Date()) -> UsageTrendSummary? {
        let series = historySeries(
            for: result,
            since: now.addingTimeInterval(-7 * 24 * 60 * 60)
        )
        guard
            series.points.count >= 2,
            let previous = series.points.dropLast().last,
            let delta = series.latestDelta
        else {
            return nil
        }

        let direction = series.direction
        let description: String

        if direction == .flat {
            description = "No change"
        } else if series.isBalance {
            let formattedDelta = UsageHistoryFormatting.formatCurrency(
                abs(delta),
                currencyCode: series.currencyCode ?? "USD",
                decimalPlaces: series.decimalPlaces
            )
            description = "Changed \(delta > 0 ? "+" : "-")\(formattedDelta)"
        } else {
            description = "Changed \(delta > 0 ? "+" : "-")\(Int((abs(delta) * 100).rounded())) pts"
        }

        return UsageTrendSummary(
            accountID: result.accountID,
            points: series.points.map(\.value),
            valueDescription: description,
            windowDescription: "Since \(UserFacingDateTimeFormatter.current.dateAndTime(previous.capturedAt))",
            isBalance: series.isBalance,
            direction: direction
        )
    }

    private func prune(
        now: Date,
        validAccountIDs: Set<String>,
        removeMissingAccounts: Bool
    ) {
        let cutoff = now.addingTimeInterval(-retention)
        let groupedSnapshots = Dictionary(grouping: snapshots
            .filter { snapshot in
                snapshot.capturedAt >= cutoff
                    && (!removeMissingAccounts || validAccountIDs.contains(snapshot.accountID))
            }, by: \.accountID)

        snapshots = groupedSnapshots.values
            .flatMap { accountSnapshots in
                let ordered = accountSnapshots.sorted(by: Self.snapshotOrder)
                guard ordered.count > maxSnapshotsPerAccount else {
                    return ordered
                }

                let recentCount = min(Self.detailedRecentSnapshotCount, maxSnapshotsPerAccount)
                let recentSnapshots = Array(ordered.suffix(recentCount))
                let olderCapacity = maxSnapshotsPerAccount - recentCount
                guard olderCapacity > 0 else {
                    return recentSnapshots
                }

                let olderSnapshots = Array(ordered.dropLast(recentCount))
                return Self.timeDistributedSnapshots(
                    from: olderSnapshots,
                    capacity: olderCapacity
                ) + recentSnapshots
            }
            .sorted(by: Self.snapshotOrder)

        let calendar = Calendar.autoupdatingCurrent
        let startOfToday = calendar.startOfDay(for: now)
        let dailyCutoff = calendar.date(
            byAdding: .day,
            value: -(dailyRetentionDays - 1),
            to: startOfToday
        ) ?? now.addingTimeInterval(-TimeInterval(dailyRetentionDays * 24 * 60 * 60))
        let eligibleDailySnapshots = dailySnapshots
            .filter { snapshot in
                snapshot.capturedAt >= dailyCutoff
                    && (!removeMissingAccounts || validAccountIDs.contains(snapshot.accountID))
            }
            .sorted { $0.capturedAt > $1.capturedAt }
        var dailyKeys: Set<String> = []
        dailySnapshots = eligibleDailySnapshots
            .filter { snapshot in
                let day = calendar.startOfDay(for: snapshot.capturedAt)
                let componentID = Self.dailyComponentID(for: snapshot)
                let key = "\(snapshot.accountID)|\(day.timeIntervalSince1970)|\(componentID)"
                return dailyKeys.insert(key).inserted
            }
            .sorted(by: Self.snapshotOrder)
    }

    private func updateDailySnapshots(from snapshot: UsageHistorySnapshot) {
        var components = snapshot.bars.map {
            DailyUsageHistoryComponent.bar($0, providerID: snapshot.providerID)
        }
        if snapshot.creditsRemaining != nil {
            components.append(.credits)
        }
        components.append(contentsOf: (snapshot.monetaryMetrics ?? []).map {
            .monetaryMetric($0)
        })

        var updatedComponentIDs: Set<String> = []
        for component in components where updatedComponentIDs.insert(component.id).inserted {
            updateDailySnapshot(
                UsageHistorySnapshot(
                    dailyComponentOf: snapshot,
                    component: component
                ),
                componentID: component.id
            )
        }
    }

    private func updateDailySnapshot(
        _ snapshot: UsageHistorySnapshot,
        componentID: String
    ) {
        let calendar = Calendar.autoupdatingCurrent
        if let index = dailySnapshots.lastIndex(where: {
            $0.accountID == snapshot.accountID
                && calendar.isDate($0.capturedAt, inSameDayAs: snapshot.capturedAt)
                && Self.dailyComponentID(for: $0) == componentID
        }) {
            guard snapshot.capturedAt >= dailySnapshots[index].capturedAt else {
                return
            }
            dailySnapshots[index] = snapshot
        } else {
            dailySnapshots.append(snapshot)
        }
    }

    private static func dailyComponentID(for snapshot: UsageHistorySnapshot) -> String {
        if let bar = snapshot.bars.first {
            let identity = DailyUsageHistoryComponent.barIdentity(
                bar,
                providerID: snapshot.providerID
            )
            return "bar.\(identity)"
        }
        if snapshot.creditsRemaining != nil {
            return "credits"
        }
        guard let metric = snapshot.monetaryMetrics?.first else {
            return "empty"
        }
        return "money.\(metric.kind.rawValue).\(metric.currencyCode)"
    }

    private func storedPresentationSnapshots(
        for accountID: String,
        since start: Date?
    ) -> [UsageHistorySnapshot] {
        var snapshotsByID: [String: UsageHistorySnapshot] = [:]
        for snapshot in snapshots + dailySnapshots where
            snapshot.accountID == accountID
                && start.map({ snapshot.capturedAt >= $0 }) != false {
            snapshotsByID[snapshot.id] = snapshot
        }
        return snapshotsByID.values.sorted(by: Self.snapshotOrder)
    }

    private static func timeDistributedSnapshots(
        from snapshots: [UsageHistorySnapshot],
        capacity: Int
    ) -> [UsageHistorySnapshot] {
        guard capacity < snapshots.count else {
            return snapshots
        }
        guard capacity > 1 else {
            return Array(snapshots.prefix(capacity))
        }

        let firstTime = snapshots[0].capturedAt.timeIntervalSinceReferenceDate
        let timeSpan = snapshots[snapshots.count - 1].capturedAt.timeIntervalSinceReferenceDate - firstTime
        var selectedIndices: [Int] = []
        selectedIndices.reserveCapacity(capacity)

        for slot in 0..<capacity {
            let targetTime = firstTime + timeSpan * Double(slot) / Double(capacity - 1)
            let minimumIndex = (selectedIndices.last ?? -1) + 1
            let maximumIndex = snapshots.count - (capacity - slot)
            var lowerBound = minimumIndex
            var upperBound = maximumIndex + 1

            while lowerBound < upperBound {
                let middle = lowerBound + (upperBound - lowerBound) / 2
                if snapshots[middle].capturedAt.timeIntervalSinceReferenceDate < targetTime {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }

            var selectedIndex = min(lowerBound, maximumIndex)
            if selectedIndex > minimumIndex {
                let earlierIndex = selectedIndex - 1
                let earlierDistance = abs(
                    snapshots[earlierIndex].capturedAt.timeIntervalSinceReferenceDate - targetTime
                )
                let selectedDistance = abs(
                    snapshots[selectedIndex].capturedAt.timeIntervalSinceReferenceDate - targetTime
                )
                if earlierDistance <= selectedDistance {
                    selectedIndex = earlierIndex
                }
            }
            selectedIndices.append(selectedIndex)
        }

        return selectedIndices.map { snapshots[$0] }
    }

    private static func snapshotOrder(
        _ lhs: UsageHistorySnapshot,
        _ rhs: UsageHistorySnapshot
    ) -> Bool {
        if lhs.capturedAt != rhs.capturedAt {
            return lhs.capturedAt < rhs.capturedAt
        }
        if lhs.accountID != rhs.accountID {
            return lhs.accountID < rhs.accountID
        }
        return lhs.id < rhs.id
    }

    private func save(
        restoringOnFailure previousSnapshots: [UsageHistorySnapshot],
        previousDailySnapshots: [UsageHistorySnapshot]
    ) {
        do {
            let data = snapshots == previousSnapshots
                ? nil
                : try encodeSnapshots(snapshots)
            let dailyData = dailySnapshots == previousDailySnapshots
                ? nil
                : try encodeDailySnapshots(dailySnapshots)
            if let data {
                defaults.set(data, forKey: storageKey)
            }
            if let dailyData {
                defaults.set(dailyData, forKey: dailyStorageKey)
            }
            lastError = nil
        } catch {
            snapshots = previousSnapshots
            dailySnapshots = previousDailySnapshots
            lastError = "Could not save usage history: \(error.localizedDescription)"
        }
    }

    private static func loadSnapshots(
        defaults: UserDefaults,
        storageKey: String
    ) -> Result<[UsageHistorySnapshot], Error> {
        guard defaults.object(forKey: storageKey) != nil else {
            return .success([])
        }

        guard let data = defaults.data(forKey: storageKey) else {
            return .failure(UsageHistoryLoadError.invalidStoredValue)
        }

        do {
            let snapshots = try JSONDecoder().decode([UsageHistorySnapshot].self, from: data)
            guard Set(snapshots.map(\.id)).count == snapshots.count else {
                return .failure(UsageHistoryLoadError.duplicateSnapshotIDs)
            }
            return .success(snapshots.sorted(by: snapshotOrder))
        } catch {
            return .failure(error)
        }
    }

    private static func loadedState(
        defaults: UserDefaults,
        storageKey: String
    ) -> (snapshots: [UsageHistorySnapshot], lastError: String?, requiresRecovery: Bool) {
        switch loadSnapshots(defaults: defaults, storageKey: storageKey) {
        case let .success(snapshots):
            return (snapshots, nil, false)
        case .failure:
            return ([], loadErrorMessage, true)
        }
    }
}

private enum UsageHistoryLoadError: Error {
    case invalidStoredValue
    case duplicateSnapshotIDs
}
