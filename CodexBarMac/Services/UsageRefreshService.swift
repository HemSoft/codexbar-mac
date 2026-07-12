import Combine
import Foundation

@MainActor
public final class UsageRefreshService: ObservableObject {
    @Published public private(set) var results: [ProviderUsageResult] = []
    @Published public private(set) var isRefreshing = false

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
        let enabledAccountIDs = Set(enabledConfigurations.map(\.id))
        var nextResults: [ProviderUsageResult] = []

        await withTaskGroup(of: ProviderUsageResult?.self) { group in
            for configuration in enabledConfigurations {
                guard let provider = providers.first(where: { $0.providerID == configuration.providerID }) else {
                    nextResults.append(
                        Self.errorResult(for: configuration, error: MissingUsageProviderError())
                    )
                    continue
                }

                group.addTask {
                    guard let result = await Self.fetchUsageWithTimeout(provider: provider, configuration: configuration) else {
                        return nil
                    }
                    return result
                }
            }

            for await result in group {
                if let result {
                    nextResults.append(result)
                }
            }
        }

        applyBulkResults(nextResults, enabledAccountIDs: enabledAccountIDs)
    }

    @discardableResult
    public func refresh(configuration: ProviderAccountConfiguration) async -> ProviderUsageResult? {
        guard configuration.isEnabled else {
            return nil
        }

        guard let provider = providers.first(where: { $0.providerID == configuration.providerID }) else {
            let errorResult = Self.errorResult(for: configuration, error: MissingUsageProviderError())
            replaceResult(errorResult)
            return errorResult
        }

        let result = await Self.fetchUsageWithTimeout(provider: provider, configuration: configuration)
        guard let result else {
            return nil
        }

        replaceResult(result)
        return result
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

    private func applyBulkResults(
        _ incoming: [ProviderUsageResult],
        enabledAccountIDs: Set<String>
    ) {
        var merged = Dictionary(
            uniqueKeysWithValues: results
                .filter { enabledAccountIDs.contains($0.accountID) }
                .map { ($0.accountID, $0) }
        )

        for result in incoming {
            if let existing = merged[result.accountID] {
                if result.fetchedAt >= existing.fetchedAt {
                    merged[result.accountID] = result
                }
            } else {
                merged[result.accountID] = result
            }
        }

        results = merged.values.sorted { $0.title < $1.title }
    }

    private func replaceResult(_ result: ProviderUsageResult) {
        if let existing = results.first(where: { $0.accountID == result.accountID }),
           existing.fetchedAt > result.fetchedAt {
            return
        }

        var nextResults = results.filter { $0.accountID != result.accountID }
        nextResults.append(result)
        results = nextResults.sorted { $0.title < $1.title }
    }

    nonisolated private static func fetchUsageWithTimeout(
        provider: any UsageProvider,
        configuration: ProviderAccountConfiguration,
        timeout: Duration = .seconds(30)
    ) async -> ProviderUsageResult? {
        let race = FetchRaceState()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.begin(continuation: continuation, provider: provider, configuration: configuration, timeout: timeout)
            }
        } onCancel: {
            race.cancel()
        }
    }

    nonisolated fileprivate static func errorResult(
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

private struct RefreshTimeoutError: LocalizedError {
    var errorDescription: String? {
        "Request timed out"
    }
}

private struct MissingUsageProviderError: LocalizedError {
    var errorDescription: String? {
        "Provider is not available"
    }
}

private final class FetchRaceState: @unchecked Sendable {
    private let gate = RefreshResultGate()
    private var fetchTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func begin(
        continuation: CheckedContinuation<ProviderUsageResult?, Never>,
        provider: any UsageProvider,
        configuration: ProviderAccountConfiguration,
        timeout: Duration
    ) {
        gate.setContinuation(continuation)

        fetchTask = Task {
            let result: ProviderUsageResult
            do {
                result = try await provider.fetchUsage(for: configuration)
            } catch {
                result = UsageRefreshService.errorResult(for: configuration, error: error)
            }

            if gate.resumeOnce(with: result) {
                return
            }
        }

        timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            if gate.resumeOnce(with: UsageRefreshService.errorResult(for: configuration, error: RefreshTimeoutError())) {
                fetchTask?.cancel()
            }
        }
    }

    func cancel() {
        fetchTask?.cancel()
        timeoutTask?.cancel()
        _ = gate.resumeOnce(with: nil)
    }
}

private final class RefreshResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<ProviderUsageResult?, Never>?

    deinit {}

    func setContinuation(_ continuation: CheckedContinuation<ProviderUsageResult?, Never>) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    func resumeOnce(with result: ProviderUsageResult?) -> Bool {
        lock.withLock {
            guard !resumed, let continuation else {
                return false
            }

            resumed = true
            continuation.resume(returning: result)
            return true
        }
    }
}

public extension UsageRefreshService {
    static func demo() -> UsageRefreshService {
        UsageRefreshService(providers: DemoUsageProvider.samples)
    }
}
