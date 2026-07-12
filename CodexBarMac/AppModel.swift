import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let refreshService: UsageRefreshService
    let configurationStore: ProviderConfigurationStore

    @Published private(set) var lastRefreshedAt: Date?

    private var cancellables = Set<AnyCancellable>()

    init(
        refreshService: UsageRefreshService = .demo(),
        configurationStore: ProviderConfigurationStore = ProviderConfigurationStore()
    ) {
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        configurationStore.seedDefaultConfigurationsIfNeeded()

        refreshService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        configurationStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var isRefreshing: Bool {
        refreshService.isRefreshing
    }

    var mostUrgentSeverity: UsageSeverity {
        displayedResults.map(\.highestSeverity).max() ?? .normal
    }

    var displayedResults: [ProviderUsageResult] {
        let enabledAccountIDs = Set(configurationStore.enabledConfigurations.map(\.id))
        return refreshService.results
            .filter { enabledAccountIDs.contains($0.accountID) }
            .sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    var lastRefreshedText: String {
        guard let lastRefreshedAt else {
            return "Not refreshed yet"
        }

        return "Updated \(UserFacingDateTimeFormatter.current.time(lastRefreshedAt))"
    }

    func activate() async {
        updateAutoRefresh()
        await refresh()
    }

    func refresh() async {
        await refreshService.refresh(configurations: configurationStore.enabledConfigurations)
        lastRefreshedAt = Date()
    }

    func updateAutoRefresh() {
        refreshService.updateAutoRefresh(
            interval: configurationStore.autoRefreshInterval,
            configurations: { [configurationStore] in
                configurationStore.enabledConfigurations
            },
            onRefreshFinished: { [weak self] in
                self?.lastRefreshedAt = Date()
            }
        )
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
