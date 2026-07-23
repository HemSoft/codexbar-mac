import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let usageAlertsByAccountID = model.currentUsageAlertsByAccountID

        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.displayedResults.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.displayedResults) { result in
                            ProviderUsageCard(
                                result: result,
                                historyOptions: model.historyStore.historySeriesOptions(for: result),
                                alerts: usageAlertsByAccountID[result.accountID] ?? [],
                                isHistoryEnabled: model.configurationStore
                                    .configuration(accountID: result.accountID)?
                                    .showsHistory ?? true
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .frame(minWidth: 340, idealWidth: 360, maxWidth: 390, minHeight: 300, maxHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(model.configurationStore.appAppearance.colorScheme)
        .onChange(of: model.configurationStore.autoRefreshInterval) { _, _ in
            model.updateAutoRefresh()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CodexBar")
                    .font(.headline)

                Text(model.lastRefreshedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await model.refresh()
                }
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh usage")
            .disabled(model.isRefreshing)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button {
                model.quit()
            } label: {
                Image(systemName: "power")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Quit CodexBar")
            .accessibilityLabel("Quit CodexBar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("No providers to show")
                .font(.headline)

            Text("Enable providers in Settings to see usage cards here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
