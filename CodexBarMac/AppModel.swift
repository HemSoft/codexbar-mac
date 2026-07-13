import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let refreshService: UsageRefreshService
    let configurationStore: ProviderConfigurationStore
    let launchAtLoginManager: LaunchAtLoginManager

    @Published private(set) var lastRefreshedAt: Date?

    private var cancellables = Set<AnyCancellable>()
    private var pendingRefresh = false

    init(
        refreshService: UsageRefreshService = .live(),
        configurationStore: ProviderConfigurationStore = ProviderConfigurationStore(secretStore: KeychainService()),
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager()
    ) {
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        self.launchAtLoginManager = launchAtLoginManager
        configurationStore.seedDefaultConfigurationsIfNeeded()

        refreshService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        refreshService.$isRefreshing
            .removeDuplicates()
            .sink { [weak self] isRefreshing in
                guard let self, !isRefreshing else {
                    return
                }

                Task {
                    await self.drainPendingRefreshIfNeeded()
                }
            }
            .store(in: &cancellables)

        configurationStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        launchAtLoginManager.objectWillChange
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
        let enabledConfigurations = configurationStore.enabledConfigurations
        let configurationByID = Dictionary(
            uniqueKeysWithValues: enabledConfigurations.map { ($0.id, $0) }
        )
        let enabledAccountIDs = Set(enabledConfigurations.map(\.id))

        return refreshService.results
            .filter { enabledAccountIDs.contains($0.accountID) }
            .map { result in
                guard let configuration = configurationByID[result.accountID],
                      configuration.displayName != result.title else {
                    return result
                }

                return ProviderUsageResult(
                    accountID: result.accountID,
                    providerID: result.providerID,
                    title: configuration.displayName,
                    subtitle: result.subtitle,
                    bars: result.bars,
                    creditsRemaining: result.creditsRemaining,
                    fetchedAt: result.fetchedAt
                )
            }
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
        await discoverLocalCredentials()
        updateAutoRefresh()
        await refresh()
    }

    func discoverLocalCredentials() async {
        let discovery = await Task.detached(priority: .utility) {
            LocalCredentialDiscovery.discover()
        }.value

        configurationStore.applyLocalCredentialDiscoveries(discovery)
    }

    func refresh() async {
        if refreshService.isRefreshing {
            pendingRefresh = true
            return
        }

        guard await refreshService.refresh(configurations: configurationStore.enabledConfigurations) else {
            pendingRefresh = true
            return
        }

        lastRefreshedAt = Date()
    }

    private func drainPendingRefreshIfNeeded() async {
        guard pendingRefresh else {
            return
        }

        pendingRefresh = false
        await refresh()
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

    func handleAccountsChanged() async {
        updateAutoRefresh()
        await refresh()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
