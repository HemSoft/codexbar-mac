import Charts
import SwiftUI

struct ProviderUsageCard: View {
    let result: ProviderUsageResult
    let historyOptions: [UsageHistorySeriesOption]
    let alerts: [UsageAlertDetail]
    let isHistoryEnabled: Bool

    @State private var isShowingHistory = false
    @Environment(\.dashboardTextScale) private var dashboardTextScale

    init(
        result: ProviderUsageResult,
        historyOptions: [UsageHistorySeriesOption],
        alerts: [UsageAlertDetail] = [],
        isHistoryEnabled: Bool
    ) {
        self.result = result
        self.historyOptions = historyOptions
        self.alerts = alerts
        self.isHistoryEnabled = isHistoryEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * dashboardTextScale) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4 * dashboardTextScale) {
                    HStack(alignment: .center, spacing: 8 * dashboardTextScale) {
                        ProviderLogoTile(providerID: result.providerID)

                        Text(result.title)
                            .dashboardFont(.headline)
                    }

                    Text(result.subtitle)
                        .dashboardFont(.subheadline)
                        .foregroundStyle(statusColor)
                }

                Spacer()

                Circle()
                    .fill(cardSeverity.tint)
                    .frame(width: 10 * dashboardTextScale, height: 10 * dashboardTextScale)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(hiddenAlertAccessibilityLabel)
                    .accessibilityHidden(hiddenAlerts.isEmpty)
            }

            if showsAlertSummary {
                UsageAlertSummaryView(alerts: displayedAlerts)
            }

            if let creditsRemaining = result.creditsRemaining, result.bars.isEmpty {
                Text(Self.currencyFormatter.string(from: NSNumber(value: creditsRemaining)) ?? "$0.00")
                    .dashboardFont(size: 34, weight: .semibold, design: .rounded)
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }

            ForEach(result.bars) { bar in
                VStack(alignment: .leading, spacing: 6 * dashboardTextScale) {
                    HStack {
                        Text(bar.label)
                        Spacer()
                        Text(bar.usageText)
                            .foregroundStyle(.secondary)
                    }
                    .dashboardFont(.footnote)

                    if let resetDescription = bar.localizedResetDescription() {
                        Text(resetDescription)
                            .dashboardFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    UsageProgressBar(bar: bar)

                    if let projectionDescription = bar.projectionDescription() {
                        Text(projectionDescription)
                            .dashboardFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !result.monetaryMetrics.isEmpty {
                Divider()

                ForEach(result.monetaryMetrics) { metric in
                    VStack(alignment: .leading, spacing: 6 * dashboardTextScale) {
                        HStack {
                            Text(metric.label)
                            Spacer()
                            Text(metric.formattedAmount())
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        .dashboardFont(.footnote)

                        if let detail = metric.detail {
                            Text(detail)
                                .dashboardFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(monetaryAccessibilityLabel(metric))
                }
            }

            ForEach(result.usageMessages, id: \.self) { message in
                Label(message, systemImage: "info.circle")
                    .dashboardFont(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }

            if showsHistory {
                Button {
                    isShowingHistory = true
                } label: {
                    UsageHistoryCompactView(
                        label: historyOptions.first?.label ?? "Usage",
                        series: history
                    )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open detailed history")
            }
        }
        .padding(12 * dashboardTextScale)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .sheet(isPresented: $isShowingHistory) {
            ProviderUsageHistoryDetailView(
                result: result,
                seriesOptions: historyOptions
            )
        }
    }

    private var history: UsageHistorySeries {
        historyOptions.first?.series
            ?? UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false)
    }

    var showsHistory: Bool {
        isHistoryEnabled && (!history.points.isEmpty
            || !result.bars.isEmpty
            || result.creditsRemaining != nil)
    }

    var cardSeverity: UsageSeverity {
        max(result.highestSeverity, alerts.map(\.severity).max() ?? .normal)
    }

    var displayedAlerts: [UsageAlertDetail] {
        guard result.providerID == .codex else {
            return alerts
        }
        return alerts.filter { $0.kind != .usage }
    }

    var hiddenAlerts: [UsageAlertDetail] {
        guard result.providerID == .codex else {
            return []
        }
        return alerts.filter { $0.kind == .usage }
    }

    var showsAlertSummary: Bool {
        !displayedAlerts.isEmpty
    }

    var hiddenAlertAccessibilityLabel: String {
        hiddenAlerts
            .map { "\($0.title). \($0.message)" }
            .joined(separator: " ")
    }

    private var statusColor: Color {
        result.isIncompleteRefresh ? .red : .secondary
    }

    private func monetaryAccessibilityLabel(_ metric: ProviderMonetaryMetric) -> String {
        [metric.label, metric.formattedAmount(), metric.detail]
            .compactMap { $0 }
            .joined(separator: ", ")
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

private struct UsageAlertSummaryView: View {
    let alerts: [UsageAlertDetail]
    @Environment(\.dashboardTextScale) private var dashboardTextScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * dashboardTextScale) {
            ForEach(alerts) { alert in
                HStack(alignment: .top, spacing: 8 * dashboardTextScale) {
                    Image(systemName: alert.kind.systemImageName)
                        .dashboardFont(.caption, weight: .semibold)
                        .foregroundStyle(alert.severity.tint)
                        .frame(width: 16 * dashboardTextScale)

                    VStack(alignment: .leading, spacing: 2 * dashboardTextScale) {
                        Text(alert.title)
                            .dashboardFont(.caption, weight: .semibold)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(alert.message)
                            .dashboardFont(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        alerts
            .map { "\($0.title). \($0.message)" }
            .joined(separator: " ")
    }
}

private struct UsageHistoryCompactView: View {
    let label: String
    let series: UsageHistorySeries
    @Environment(\.dashboardTextScale) private var dashboardTextScale

    var body: some View {
        HStack(spacing: 12 * dashboardTextScale) {
            UsageTrendSparkline(series: series, tint: series.tint)
                .frame(width: 88 * dashboardTextScale, height: 38 * dashboardTextScale)

            VStack(alignment: .leading, spacing: 2 * dashboardTextScale) {
                Text(label)
                    .dashboardFont(.caption2, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 6 * dashboardTextScale) {
                    Text(series.latestValueDescription)
                        .dashboardFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.primary)
                        .monospacedDigit()

                    Text(series.changeDescription)
                        .dashboardFont(.caption, weight: .medium)
                        .foregroundStyle(series.tint)
                        .lineLimit(1)
                }

                Text(series.rangeDescription)
                    .dashboardFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(series.sampleWindowDescription)
                    .dashboardFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(label) history. Latest \(series.latestValueDescription). \(series.changeDescription). \(series.rangeDescription)."
        )
    }
}

private extension UsageAlertKind {
    var systemImageName: String {
        switch self {
        case .usage:
            "gauge.with.dots.needle.67percent"
        case .balance:
            "creditcard"
        case .severity:
            "exclamationmark.triangle.fill"
        }
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

private struct ProviderUsageHistoryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dashboardTextScale) private var dashboardTextScale

    let result: ProviderUsageResult
    let seriesOptions: [UsageHistorySeriesOption]

    @State private var selectedDate: Date?
    @State private var selectedSeriesID: String
    @State private var selectedRange = UsageHistoryRange.sevenDays

    init(result: ProviderUsageResult, seriesOptions: [UsageHistorySeriesOption]) {
        self.result = result
        self.seriesOptions = seriesOptions
        _selectedSeriesID = State(initialValue: seriesOptions.first?.id ?? "primary")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .dashboardFont(.title2, weight: .semibold)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20 * dashboardTextScale)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24 * dashboardTextScale) {
                    accountHeader

                    if seriesOptions.count > 1 {
                        Picker("History metric", selection: $selectedSeriesID) {
                            ForEach(seriesOptions) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .onChange(of: selectedSeriesID) { _, _ in
                            selectedDate = nil
                        }
                    }

                    Picker("History range", selection: $selectedRange) {
                        ForEach(UsageHistoryRange.allCases) { range in
                            Text(range.compactTitle)
                                .accessibilityLabel(range.title)
                                .tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedRange) { _, _ in
                        selectedDate = nil
                    }

                    if series.points.isEmpty {
                        ContentUnavailableView(
                            "No History in This Range",
                            systemImage: "chart.xyaxis.line",
                            description: Text(
                                "Choose a longer range or refresh usage to collect another sample."
                            )
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        chartSection
                        statisticsSection
                        recentSamplesSection
                    }
                }
                .padding(20 * dashboardTextScale)
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var series: UsageHistorySeries {
        let unfilteredSeries = seriesOptions.first(where: { $0.id == selectedSeriesID })?.series
            ?? seriesOptions.first?.series
            ?? UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false)
        return unfilteredSeries.filtered(to: selectedRange)
    }

    private var accountHeader: some View {
        HStack(spacing: 10 * dashboardTextScale) {
            ProviderLogoTile(providerID: result.providerID)
                .frame(width: 30 * dashboardTextScale, height: 30 * dashboardTextScale)

            VStack(alignment: .leading, spacing: 2 * dashboardTextScale) {
                Text(result.title)
                    .dashboardFont(.headline)

                Text(series.sampleWindowDescription)
                    .dashboardFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12 * dashboardTextScale) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2 * dashboardTextScale) {
                    Text(displayedPoint.map { series.valueDescription(for: $0.value) } ?? series.latestValueDescription)
                        .dashboardFont(size: 30, weight: .semibold, design: .rounded)
                        .monospacedDigit()

                    if let displayedPoint {
                        Text(UserFacingDateTimeFormatter.current.dateAndTime(displayedPoint.capturedAt))
                            .dashboardFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(series.changeDescription)
                    .dashboardFont(.subheadline, weight: .semibold)
                    .foregroundStyle(series.tint)
            }

            Chart {
                ForEach(series.points) { point in
                    if series.points.count >= 2 {
                        AreaMark(
                            x: .value("Time", point.capturedAt),
                            yStart: .value("Baseline", series.chartDomain.lowerBound),
                            yEnd: .value("Value", point.value)
                        )
                        .foregroundStyle(series.tint.opacity(0.1))

                        LineMark(
                            x: .value("Time", point.capturedAt),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(series.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }

                    if series.points.count <= 12 {
                        PointMark(
                            x: .value("Time", point.capturedAt),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(series.tint.opacity(0.75))
                        .symbolSize(24)
                    }
                }

                if !series.isBalance {
                    RuleMark(y: .value("Limit", 1.0))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("100% limit")
                                .dashboardFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }

                if let displayedPoint {
                    RuleMark(x: .value("Selected time", displayedPoint.capturedAt))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    PointMark(
                        x: .value("Selected time", displayedPoint.capturedAt),
                        y: .value("Selected value", displayedPoint.value)
                    )
                    .foregroundStyle(series.tint)
                    .symbolSize(52)
                }
            }
            .chartYScale(domain: series.chartDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.15))
                    AxisTick()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(axisDateText(for: date))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.15))
                    AxisTick()
                    AxisValueLabel {
                        if let numericValue = value.as(Double.self) {
                            Text(series.valueDescription(for: numericValue))
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .frame(height: 260 * dashboardTextScale)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(result.title) history chart")
            .accessibilityValue(
                "\(series.sampleWindowDescription). Latest \(series.latestValueDescription). \(series.changeDescription). \(series.rangeDescription)."
            )
            .accessibilityHint("Move across the chart to inspect historical values.")

            if series.points.count == 1 {
                Text("More samples will appear after future refreshes.")
                    .dashboardFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 14 * dashboardTextScale) {
            Text("Summary")
                .dashboardFont(.headline)

            Grid(
                alignment: .leading,
                horizontalSpacing: 24 * dashboardTextScale,
                verticalSpacing: 14 * dashboardTextScale
            ) {
                GridRow {
                    HistoryMetricView(title: "Latest", value: series.latestValueDescription)
                    HistoryMetricView(title: "Change", value: series.changeDescription)
                }

                Divider()
                    .gridCellColumns(2)

                GridRow {
                    HistoryMetricView(title: "Low", value: series.minimumValueDescription)
                    HistoryMetricView(title: "High", value: series.maximumValueDescription)
                }
            }
        }
    }

    private var recentSamplesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Samples")
                .dashboardFont(.headline)
                .padding(.bottom, 8 * dashboardTextScale)

            ForEach(Array(series.points.suffix(20).reversed())) { point in
                HStack(alignment: .firstTextBaseline, spacing: 12 * dashboardTextScale) {
                    VStack(alignment: .leading, spacing: 3 * dashboardTextScale) {
                        Text(series.valueDescription(for: point.value))
                            .dashboardFont(.body, weight: .semibold)
                            .monospacedDigit()

                        Text(UserFacingDateTimeFormatter.current.dateAndTime(point.capturedAt))
                            .dashboardFont(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Circle()
                        .fill(point.severity.tint)
                        .frame(width: 9 * dashboardTextScale, height: 9 * dashboardTextScale)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 10 * dashboardTextScale)

                Divider()
            }
        }
    }

    private var displayedPoint: UsageHistoryPoint? {
        guard let selectedDate else {
            return series.points.last
        }

        return series.points.min { lhs, rhs in
            abs(lhs.capturedAt.timeIntervalSince(selectedDate))
                < abs(rhs.capturedAt.timeIntervalSince(selectedDate))
        }
    }

    private func axisDateText(for date: Date) -> String {
        guard
            let first = series.points.first?.capturedAt,
            let last = series.points.last?.capturedAt
        else {
            return ""
        }

        if last.timeIntervalSince(first) < 24 * 60 * 60 {
            return UserFacingDateTimeFormatter.current.time(date)
        }

        return UserFacingDateTimeFormatter.current.shortDate(date)
    }
}

private struct HistoryMetricView: View {
    let title: String
    let value: String
    @Environment(\.dashboardTextScale) private var dashboardTextScale

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * dashboardTextScale) {
            Text(title)
                .dashboardFont(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .dashboardFont(.subheadline, weight: .semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension UsageHistorySeries {
    var tint: Color {
        switch direction {
        case .flat:
            .secondary
        case .up:
            isIncreaseFavorable ? .green : .orange
        case .down:
            isIncreaseFavorable ? .orange : .green
        }
    }
}

private struct ProviderLogoTile: View {
    let providerID: ProviderID
    @Environment(\.dashboardTextScale) private var dashboardTextScale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))

            Image(systemName: providerID.symbolName)
                .dashboardFont(size: 12, weight: .semibold)
                .foregroundStyle(.primary)
        }
        .frame(width: 24 * dashboardTextScale, height: 24 * dashboardTextScale)
        .accessibilityHidden(true)
    }
}

private struct UsageProgressBar: View {
    let bar: UsageBar
    @Environment(\.dashboardTextScale) private var dashboardTextScale

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
        .frame(height: 7 * dashboardTextScale)
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
