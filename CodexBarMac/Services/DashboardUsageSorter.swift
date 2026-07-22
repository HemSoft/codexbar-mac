import Foundation

public enum DashboardUsageSorter {
    public static func orderedResults(
        _ results: [ProviderUsageResult],
        mode: DashboardOrderingMode,
        now: Date = Date()
    ) -> [ProviderUsageResult] {
        results.enumerated()
            .sorted { lhs, rhs in
                switch mode {
                case .manual:
                    return lhs.offset < rhs.offset
                case .smart:
                    return SmartOrderingScore(
                        result: lhs.element,
                        originalOffset: lhs.offset,
                        now: now
                    ) < SmartOrderingScore(
                        result: rhs.element,
                        originalOffset: rhs.offset,
                        now: now
                    )
                }
            }
            .map(\.element)
    }
}

private struct SmartOrderingScore: Comparable {
    let severityRank: Int
    let balanceRank: BalanceRank
    let projectedLimitHitAt: Date?
    let projectedFractionRank: Double
    let originalOffset: Int

    init(result: ProviderUsageResult, originalOffset: Int, now: Date) {
        severityRank = -result.highestSeverity(at: now).rawValue
        balanceRank = BalanceRank(creditsRemaining: result.creditsRemaining)
        projectedLimitHitAt = result.bars.compactMap { $0.projectedLimitHitAt(now: now) }.min()
        projectedFractionRank = -(result.bars.map {
            max($0.fractionUsed, $0.projectedFraction(at: now) ?? 0)
        }.max() ?? 0)
        self.originalOffset = originalOffset
    }

    static func < (lhs: SmartOrderingScore, rhs: SmartOrderingScore) -> Bool {
        if lhs.severityRank != rhs.severityRank {
            return lhs.severityRank < rhs.severityRank
        }

        if lhs.balanceRank != rhs.balanceRank {
            return lhs.balanceRank < rhs.balanceRank
        }

        if lhs.projectedLimitHitAt != rhs.projectedLimitHitAt {
            switch (lhs.projectedLimitHitAt, rhs.projectedLimitHitAt) {
            case let (lhsHit?, rhsHit?):
                return lhsHit < rhsHit
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
        }

        if lhs.projectedFractionRank != rhs.projectedFractionRank {
            return lhs.projectedFractionRank < rhs.projectedFractionRank
        }

        return lhs.originalOffset < rhs.originalOffset
    }
}

private enum BalanceRank: Comparable {
    case balance(Double)
    case none

    init(creditsRemaining: Double?) {
        if let creditsRemaining {
            self = .balance(max(creditsRemaining, 0))
        } else {
            self = .none
        }
    }

    static func < (lhs: BalanceRank, rhs: BalanceRank) -> Bool {
        switch (lhs, rhs) {
        case let (.balance(lhsCredits), .balance(rhsCredits)):
            return lhsCredits < rhsCredits
        case (.balance, .none):
            return true
        case (.none, .balance):
            return false
        case (.none, .none):
            return false
        }
    }
}

private extension UsageBar {
    func projectedLimitHitAt(now: Date) -> Date? {
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

        let elapsed = now.timeIntervalSince(projectionPeriodStart)
        guard elapsed > 0 else {
            return nil
        }

        let ratePerSecond = projectionCurrent / elapsed
        guard ratePerSecond > 0 else {
            return nil
        }

        let hitAt = projectionPeriodStart.addingTimeInterval(projectionLimit / ratePerSecond)
        return hitAt <= projectionPeriodEnd ? hitAt : nil
    }
}
