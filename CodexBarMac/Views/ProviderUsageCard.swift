import SwiftUI

struct ProviderUsageCard: View {
    let result: ProviderUsageResult

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
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
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
            let projectedFraction = bar.projectedFraction() ?? 0
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
        case .cursor:
            "cursorarrow.rays"
        }
    }
}
