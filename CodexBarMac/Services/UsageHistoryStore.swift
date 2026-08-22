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
        self.id = "\(result.accountID).\(capturedAt.timeIntervalSince1970)"
        self.accountID = result.accountID
        self.providerID = result.providerID
        self.title = result.title
        self.subtitle = result.subtitle
        self.capturedAt = capturedAt
        self.bars = result.bars.map {
            UsageHistoryBarSnapshot(bar: $0, capturedAt: capturedAt)
        }
        self.creditsRemaining = result.creditsRemaining
        self.monetaryMetrics = result.monetaryMetrics.map(UsageHistoryMonetaryMetricSnapshot.init)
        self.highestSeverity = result.highestSeverity(at: capturedAt)
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
        self.points = points
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

            let padding = max(maximum * 0.08, 0.05)
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
    @Published public private(set) var lastError: String?
    @Published public private(set) var requiresRecovery: Bool

    private static let detailedRecentSnapshotCount = 120
    private static let loadErrorMessage =
        "Saved usage history could not be read. Reset history to resume recording."

    private let defaults: UserDefaults
    private let encodeSnapshots: ([UsageHistorySnapshot]) throws -> Data
    private let retention: TimeInterval
    private let maxSnapshotsPerAccount: Int
    private let storageKey = "usageHistorySnapshots"

    public init(
        defaults: UserDefaults = .standard,
        retentionDays: Int = 30,
        maxSnapshotsPerAccount: Int = 240
    ) {
        self.defaults = defaults
        self.encodeSnapshots = { try JSONEncoder().encode($0) }
        self.retention = TimeInterval(max(retentionDays, 1) * 24 * 60 * 60)
        self.maxSnapshotsPerAccount = max(maxSnapshotsPerAccount, 1)
        let state = Self.loadedState(defaults: defaults, storageKey: storageKey)
        self.snapshots = state.snapshots
        self.lastError = state.lastError
        self.requiresRecovery = state.requiresRecovery
    }

    init(
        defaults: UserDefaults,
        retentionDays: Int = 30,
        maxSnapshotsPerAccount: Int = 240,
        encodeSnapshots: @escaping ([UsageHistorySnapshot]) throws -> Data
    ) {
        self.defaults = defaults
        self.encodeSnapshots = encodeSnapshots
        self.retention = TimeInterval(max(retentionDays, 1) * 24 * 60 * 60)
        self.maxSnapshotsPerAccount = max(maxSnapshotsPerAccount, 1)
        let state = Self.loadedState(defaults: defaults, storageKey: storageKey)
        self.snapshots = state.snapshots
        self.lastError = state.lastError
        self.requiresRecovery = state.requiresRecovery
    }

    public func record(results: [ProviderUsageResult], now: Date = Date()) {
        guard !requiresRecovery else {
            return
        }

        let recordableResults = results.filter { result in
            result.creditsRemaining != nil || !result.bars.isEmpty || !result.monetaryMetrics.isEmpty
        }
        guard !recordableResults.isEmpty else {
            return
        }

        let previousSnapshots = snapshots
        var snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        for snapshot in recordableResults.map({ UsageHistorySnapshot(result: $0) }) {
            snapshotsByID[snapshot.id] = snapshot
        }
        snapshots = Array(snapshotsByID.values)
        prune(now: now, validAccountIDs: Set(recordableResults.map(\.accountID)), removeMissingAccounts: false)
        save(restoringOnFailure: previousSnapshots)
    }

    public func removeSnapshotsForMissingAccounts(validAccountIDs: Set<String>, now: Date = Date()) {
        guard !requiresRecovery else {
            return
        }

        let previousSnapshots = snapshots
        prune(now: now, validAccountIDs: validAccountIDs, removeMissingAccounts: true)
        save(restoringOnFailure: previousSnapshots)
    }

    public func discardCorruptedHistory() {
        guard requiresRecovery else {
            return
        }

        defaults.removeObject(forKey: storageKey)
        snapshots = []
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
        let accountSnapshots = snapshots(for: result.accountID, since: start)
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

        let points = accountSnapshots.compactMap { snapshot -> UsageHistoryPoint? in
            if !isBalance, primaryMonetaryIdentity == nil, result.providerID == .cursor {
                return Self.cursorPrimaryBar(in: snapshot).map {
                    UsageHistoryPoint(
                        id: snapshot.id,
                        capturedAt: snapshot.capturedAt,
                        value: $0.historyFractionUsed,
                        severity: $0.effectiveSeverity
                    )
                }
            }

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
        let accountSnapshots = snapshots(for: result.accountID, since: start)
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

    private static func cursorPrimaryBar(
        in snapshot: UsageHistorySnapshot
    ) -> UsageHistoryBarSnapshot? {
        snapshot.bars.first(where: {
            $0.stableKey == CursorUsageIdentity.totalStableKey
                || ($0.stableKey == nil
                    && CursorUsageIdentity.matchesLegacyLabel(
                        $0.label,
                        stableKey: CursorUsageIdentity.totalStableKey
                    ))
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
                    $0.stableKey == stableKey
                        || ($0.stableKey == nil
                            && CursorUsageIdentity.matchesLegacyLabel(
                                $0.label,
                                stableKey: stableKey
                            ))
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

    private func cursorPrimaryUsageSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot]
    ) -> UsageHistorySeries {
        UsageHistorySeries(
            accountID: accountID,
            points: snapshots.compactMap { snapshot in
                Self.cursorPrimaryBar(in: snapshot).map {
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

    private func cursorUsageSeriesOptions(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        currentBars: [UsageBar]
    ) -> [UsageHistorySeriesOption] {
        let metricOptions: [UsageHistorySeriesOption] =
            CursorUsageIdentity.metricDefinitions.compactMap { stableKey, label in
                let isAvailable = currentBars.contains(where: { $0.stableKey == stableKey })
                    || snapshots.contains(where: { snapshot in
                        snapshot.bars.contains(where: {
                            $0.stableKey == stableKey
                                || ($0.stableKey == nil
                                    && CursorUsageIdentity.matchesLegacyLabel(
                                        $0.label,
                                        stableKey: stableKey
                                    ))
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
            let hasFallbackSamples = snapshots.contains(where: { snapshot in
                !snapshot.bars.isEmpty
                    && !snapshot.bars.contains(where: {
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

    private func save(restoringOnFailure previousSnapshots: [UsageHistorySnapshot]) {
        do {
            let data = try encodeSnapshots(snapshots)
            defaults.set(data, forKey: storageKey)
            lastError = nil
        } catch {
            snapshots = previousSnapshots
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
            return .success(snapshots.sorted { $0.capturedAt < $1.capturedAt })
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
}
