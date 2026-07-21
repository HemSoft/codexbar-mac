import SwiftUI

struct ProviderUsageCard: View {
    let result: ProviderUsageResult
    let history: UsageHistorySeries

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        ProviderLogoTile(providerID: result.providerID)

                        Text(result.title)
                            .font(.headline)
                    }

                    Text(result.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                }

                Spacer()

                Circle()
                    .fill(result.highestSeverity.tint)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }

            if let creditsRemaining = result.creditsRemaining, result.bars.isEmpty {
                Text(Self.currencyFormatter.string(from: NSNumber(value: creditsRemaining)) ?? "$0.00")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }

            ForEach(result.bars) { bar in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(bar.label)
                        Spacer()
                        Text(bar.usageText)
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)

                    if let resetDescription = bar.localizedResetDescription() {
                        Text(resetDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    UsageProgressBar(bar: bar)

                    if let projectionDescription = bar.projectionDescription() {
                        Text(projectionDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if showsHistory {
                UsageHistoryCompactView(series: history)
            }
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var showsHistory: Bool {
        !history.points.isEmpty || !result.bars.isEmpty || result.creditsRemaining != nil
    }

    private var statusColor: Color {
        result.subtitle.hasPrefix("Refresh failed:") ? .red : .secondary
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

private struct UsageHistoryCompactView: View {
    let series: UsageHistorySeries

    var body: some View {
        HStack(spacing: 12) {
            UsageTrendSparkline(series: series, tint: series.tint)
                .frame(width: 88, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(series.latestValueDescription)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()

                    Text(series.changeDescription)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(series.tint)
                        .lineLimit(1)
                }

                Text(series.rangeDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(series.sampleWindowDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Usage history. Latest \(series.latestValueDescription). \(series.changeDescription). \(series.rangeDescription)."
        )
    }
}

private struct UsageTrendSparkline: View {
    let series: UsageHistorySeries
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard !series.points.isEmpty else {
                var placeholder = Path()
                placeholder.move(to: CGPoint(x: 0, y: size.height / 2))
                placeholder.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(
                    placeholder,
                    with: .color(tint.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
                return
            }

            let firstDate = series.points.first?.capturedAt ?? Date()
            let lastDate = series.points.last?.capturedAt ?? firstDate
            let timeSpan = max(lastDate.timeIntervalSince(firstDate), 1)
            let valueSpan = max(series.chartDomain.upperBound - series.chartDomain.lowerBound, 0.0001)
            var path = Path()
            var lastResolvedPoint = CGPoint(x: size.width / 2, y: size.height / 2)

            for (index, point) in series.points.enumerated() {
                let x = series.points.count == 1
                    ? size.width / 2
                    : CGFloat(point.capturedAt.timeIntervalSince(firstDate) / timeSpan) * size.width
                let normalizedValue = (point.value - series.chartDomain.lowerBound) / valueSpan
                let y = size.height - CGFloat(min(max(normalizedValue, 0), 1)) * size.height
                let resolvedPoint = CGPoint(x: x, y: y)
                lastResolvedPoint = resolvedPoint

                if index == 0 {
                    path.move(to: resolvedPoint)
                } else {
                    path.addLine(to: resolvedPoint)
                }
            }

            if series.points.count >= 2 {
                context.stroke(
                    path,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }

            context.fill(
                Path(ellipseIn: CGRect(
                    x: lastResolvedPoint.x - 3,
                    y: lastResolvedPoint.y - 3,
                    width: 6,
                    height: 6
                )),
                with: .color(tint)
            )
        }
        .accessibilityHidden(true)
    }
}

private extension UsageHistorySeries {
    var tint: Color {
        switch direction {
        case .flat:
            .secondary
        case .up:
            isBalance ? .green : .orange
        case .down:
            isBalance ? .orange : .green
        }
    }
}

private struct ProviderLogoTile: View {
    let providerID: ProviderID

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))

            Image(systemName: providerID.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

private struct UsageProgressBar: View {
    let bar: UsageBar

    var body: some View {
        GeometryReader { proxy in
            let actualWidth = proxy.size.width * bar.fractionUsed
            let projectedFraction = bar.showProjectionOnCurrentBar ? (bar.projectedFraction() ?? 0) : 0
            let projectedWidth = proxy.size.width * projectedFraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))

                if projectedWidth > actualWidth {
                    Capsule()
                        .fill(UsageSeverity(fractionUsed: projectedFraction).projectedTint.opacity(0.55))
                        .frame(width: projectedWidth)
                }

                Capsule()
                    .fill(bar.severity.tint)
                    .frame(width: actualWidth)
            }
        }
        .frame(height: 7)
        .accessibilityLabel("\(bar.label) \(bar.usageText)")
    }
}

private extension ProviderID {
    var symbolName: String {
        switch self {
        case .codex:
            "sparkles"
        case .copilot:
            "terminal"
        case .claude:
            "brain.head.profile"
        case .openRouter:
            "arrow.triangle.branch"
        case .openCodeZen:
            "cube"
        case .moonshot:
            "moon.stars"
        case .cursor:
            "cursorarrow.rays"
        case .gemini:
            "wand.and.stars"
        }
    }
}
