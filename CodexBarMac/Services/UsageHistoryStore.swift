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
    public let label: String
    public let fractionUsed: Double
    public let used: Double
    public let limit: Double

    public init(bar: UsageBar) {
        self.label = bar.label
        self.fractionUsed = bar.fractionUsed
        self.used = bar.used
        self.limit = bar.limit
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
        self.bars = result.bars.map(UsageHistoryBarSnapshot.init)
        self.creditsRemaining = result.creditsRemaining
        self.monetaryMetrics = result.monetaryMetrics.map(UsageHistoryMonetaryMetricSnapshot.init)
        self.highestSeverity = result.highestSeverity(at: capturedAt)
    }

    public var primaryValue: Double? {
        if let creditsRemaining {
            return creditsRemaining
        }

        if let usage = bars.map(\.fractionUsed).max() {
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
            return 0...1
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

    deinit {}

    private static let detailedRecentSnapshotCount = 120

    private let defaults: UserDefaults
    private let retention: TimeInterval
    private let maxSnapshotsPerAccount: Int
    private let storageKey = "usageHistorySnapshots"

    public init(
        defaults: UserDefaults = .standard,
        retentionDays: Int = 30,
        maxSnapshotsPerAccount: Int = 240
    ) {
        self.defaults = defaults
        self.retention = TimeInterval(max(retentionDays, 1) * 24 * 60 * 60)
        self.maxSnapshotsPerAccount = max(maxSnapshotsPerAccount, 1)
        self.snapshots = Self.loadSnapshots(defaults: defaults, storageKey: storageKey)
    }

    public func record(results: [ProviderUsageResult], now: Date = Date()) {
        let recordableResults = results.filter { result in
            result.creditsRemaining != nil || !result.bars.isEmpty || !result.monetaryMetrics.isEmpty
        }
        guard !recordableResults.isEmpty else {
            return
        }

        var snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        for snapshot in recordableResults.map({ UsageHistorySnapshot(result: $0) }) {
            snapshotsByID[snapshot.id] = snapshot
        }
        snapshots = Array(snapshotsByID.values)
        prune(now: now, validAccountIDs: Set(recordableResults.map(\.accountID)), removeMissingAccounts: false)
        save()
    }

    public func removeSnapshotsForMissingAccounts(validAccountIDs: Set<String>, now: Date = Date()) {
        prune(now: now, validAccountIDs: validAccountIDs, removeMissingAccounts: true)
        save()
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
        let isBalance: Bool
        if result.creditsRemaining != nil {
            isBalance = true
        } else if !result.bars.isEmpty {
            isBalance = false
        } else if primaryBalanceLikeMetric(in: result.monetaryMetrics) != nil {
            isBalance = true
        } else {
            isBalance = accountSnapshots.last.map {
                $0.creditsRemaining != nil || primaryBalanceLikeMetric(in: $0.monetaryMetrics ?? []) != nil
            } ?? false
        }

        let points = accountSnapshots.compactMap { snapshot -> UsageHistoryPoint? in
            if isBalance {
                guard snapshot.creditsRemaining != nil || primaryBalanceLikeMetric(in: snapshot.monetaryMetrics ?? []) != nil else {
                    return nil
                }
            } else {
                guard !snapshot.bars.isEmpty else {
                    return nil
                }
            }
            let value = isBalance
                ? snapshot.monetaryPrimaryValue
                : snapshot.bars.map(\.fractionUsed).max()
            return value.map { UsageHistoryPoint(snapshot: snapshot, value: $0) }
        }
        let monetaryFormat = primaryBalanceLikeMetric(in: result.monetaryMetrics).map {
            ($0.currencyCode, $0.decimalPlaces)
        } ?? accountSnapshots.last.flatMap { snapshot in
            primaryBalanceLikeMetric(in: snapshot.monetaryMetrics ?? []).map {
                ($0.currencyCode, $0.decimalPlaces)
            }
        }

        return UsageHistorySeries(
            accountID: result.accountID,
            points: points,
            isBalance: isBalance,
            currencyCode: monetaryFormat?.0,
            decimalPlaces: min(max(monetaryFormat?.1 ?? 2, 0), 6)
        )
    }

    public func historySeriesOptions(
        for result: ProviderUsageResult,
        since start: Date? = nil
    ) -> [UsageHistorySeriesOption] {
        let accountSnapshots = snapshots(for: result.accountID, since: start)
        var options: [UsageHistorySeriesOption] = []
        let monetaryPrimary = result.bars.isEmpty && result.creditsRemaining == nil
            ? primaryBalanceLikeMetric(in: result.monetaryMetrics)
            : nil

        if !result.bars.isEmpty || result.creditsRemaining != nil {
            options.append(UsageHistorySeriesOption(
                id: "primary",
                label: result.creditsRemaining == nil ? "Usage" : "Balance",
                series: historySeries(for: result, since: start)
            ))
        } else if let monetaryPrimary {
            options.append(UsageHistorySeriesOption(
                id: "primary",
                label: monetaryPrimary.label,
                series: historySeries(for: result, since: start)
            ))
        }

        for metric in result.monetaryMetrics where metric.id != monetaryPrimary?.id {
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

    private func save() {
        if let data = try? JSONEncoder().encode(snapshots) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func loadSnapshots(defaults: UserDefaults, storageKey: String) -> [UsageHistorySnapshot] {
        guard
            let data = defaults.data(forKey: storageKey),
            let snapshots = try? JSONDecoder().decode([UsageHistorySnapshot].self, from: data)
        else {
            return []
        }

        return snapshots.sorted { $0.capturedAt < $1.capturedAt }
    }
}
