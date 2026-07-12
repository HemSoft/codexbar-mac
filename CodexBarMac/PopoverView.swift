import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.displayedResults.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.displayedResults) { result in
                            ProviderUsageCard(result: result)
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            footer
        }
        .frame(minWidth: 360, idealWidth: 380, maxWidth: 420, minHeight: 420, maxHeight: 640)
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
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh usage")
            .disabled(model.isRefreshing)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button("Refresh") {
                Task {
                    await model.refresh()
                }
            }
            .disabled(model.isRefreshing)

            Button("Settings") {
                openSettings()
            }

            Spacer()

            Button("Quit") {
                model.quit()
            }
        }
        .buttonStyle(.link)
        .font(.footnote)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        .padding(.vertical, 32)
    }
}
