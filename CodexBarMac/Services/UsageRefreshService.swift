import Combine
import Foundation

@MainActor
public final class UsageRefreshService: ObservableObject {
    @Published public private(set) var results: [ProviderUsageResult] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastRefreshError: String?

    private let providers: [any UsageProvider]
    private var autoRefreshTask: Task<Void, Never>?

    public init(
        providers: [any UsageProvider],
        initialResults: [ProviderUsageResult] = []
    ) {
        self.providers = providers
        self.results = initialResults
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    public func refresh(configurations: [ProviderAccountConfiguration]) async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
        }

        let enabledConfigurations = configurations.filter(\.isEnabled)
        var nextResults: [ProviderUsageResult] = []

        await withTaskGroup(of: ProviderUsageResult?.self) { group in
            for configuration in enabledConfigurations {
                guard let provider = providers.first(where: { $0.providerID == configuration.providerID }) else {
                    continue
                }

                group.addTask {
                    do {
                        return try await provider.fetchUsage(for: configuration)
                    } catch {
                        return Self.errorResult(for: configuration, error: error)
                    }
                }
            }

            for await result in group {
                if let result {
                    nextResults.append(result)
                }
            }
        }

        results = nextResults.sorted { $0.title < $1.title }
        lastRefreshError = nil
    }

    @discardableResult
    public func refresh(configuration: ProviderAccountConfiguration) async -> ProviderUsageResult? {
        guard
            configuration.isEnabled,
            let provider = providers.first(where: { $0.providerID == configuration.providerID })
        else {
            return nil
        }

        do {
            let result = try await provider.fetchUsage(for: configuration)
            replaceResult(result)
            lastRefreshError = nil
            return result
        } catch {
            let errorResult = Self.errorResult(for: configuration, error: error)
            replaceResult(errorResult)
            lastRefreshError = nil
            return errorResult
        }
    }

    public func refresh() async {
        await refresh(configurations: ProviderID.allCases.map(ProviderAccountConfiguration.defaultConfiguration))
    }

    public func updateAutoRefresh(
        interval: AutoRefreshInterval,
        configurations: @escaping @MainActor () -> [ProviderAccountConfiguration]
    ) {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil

        guard let seconds = interval.seconds else {
            return
        }

        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }

                guard !Task.isCancelled, let self else {
                    return
                }

                await self.refresh(configurations: configurations())
            }
        }
    }

    public func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func replaceResult(_ result: ProviderUsageResult) {
        var nextResults = results.filter { $0.accountID != result.accountID }
        nextResults.append(result)
        results = nextResults.sorted { $0.title < $1.title }
    }

    nonisolated private static func errorResult(
        for configuration: ProviderAccountConfiguration,
        error: Error
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: configuration.providerID,
            title: configuration.displayName,
            subtitle: "Refresh failed: \(error.localizedDescription)",
            bars: [],
            fetchedAt: Date()
        )
    }
}

public extension UsageRefreshService {
    static func demo() -> UsageRefreshService {
        UsageRefreshService(providers: DemoUsageProvider.samples)
    }
}
