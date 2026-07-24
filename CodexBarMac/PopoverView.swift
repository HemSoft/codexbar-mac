import Sparkle
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let usageAlertsByAccountID = model.currentUsageAlertsByAccountID

        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    if let historyError = model.historyStore.lastError {
                        Label(historyError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("usage-history-persistence-error")
                    }

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

            Divider()

            HStack {
                CheckForUpdatesButton(updater: updater)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 340, idealWidth: 360, maxWidth: 390, minHeight: 300, maxHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(model.configurationStore.appAppearance.colorScheme)
        .onChange(of: model.configurationStore.autoRefreshInterval) { _, _ in
            model.updateAutoRefresh()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
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
                Group {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Refresh usage")
            .accessibilityLabel("Refresh usage")
            .disabled(model.isRefreshing)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")

            Button {
                model.quit()
            } label: {
                Image(systemName: "power")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
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
