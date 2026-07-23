import Combine
import Foundation

@MainActor
public final class UsageRefreshService: ObservableObject {
    @Published public private(set) var results: [ProviderUsageResult] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var incompleteRefreshAccountIDs: Set<String> = []

    private let providers: [any UsageProvider]
    private var autoRefreshTask: Task<Void, Never>?

    public var successfulRefreshResults: [ProviderUsageResult] {
        results.filter { !incompleteRefreshAccountIDs.contains($0.accountID) }
    }

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

    @discardableResult
    public func refresh(configurations: [ProviderAccountConfiguration]) async -> Bool {
        guard !isRefreshing else {
            return false
        }

        isRefreshing = true
        defer {
            isRefreshing = false
        }

        let enabledConfigurations = configurations.filter(\.isEnabled)
        let enabledAccountIDs = Set(enabledConfigurations.map(\.id))
        var nextResults: [ProviderUsageResult] = []
        var unavailableAccountIDs = Set<String>()

        await withTaskGroup(of: (String, ProviderUsageResult?).self) { group in
            for configuration in enabledConfigurations {
                guard let provider = providers.first(where: { $0.providerID == configuration.providerID }) else {
                    let errorResult = Self.errorResult(for: configuration, error: MissingUsageProviderError())
                    nextResults.append(errorResult)
                    continue
                }

                group.addTask {
                    let result = await Self.fetchUsageWithTimeout(provider: provider, configuration: configuration)
                    return (configuration.id, result)
                }
            }

            for await (accountID, result) in group {
                guard let result else {
                    unavailableAccountIDs.insert(accountID)
                    continue
                }

                nextResults.append(result)
            }
        }

        applyBulkResults(nextResults, enabledAccountIDs: enabledAccountIDs)
        incompleteRefreshAccountIDs = unavailableAccountIDs.union(
            results.lazy
                .filter(\.isIncompleteRefresh)
                .map(\.accountID)
        )
        return true
    }

    @discardableResult
    public func refresh(configuration: ProviderAccountConfiguration) async -> ProviderUsageResult? {
        guard configuration.isEnabled else {
            return nil
        }

        guard let provider = providers.first(where: { $0.providerID == configuration.providerID }) else {
            let errorResult = Self.errorResult(for: configuration, error: MissingUsageProviderError())
            if replaceResult(errorResult) {
                incompleteRefreshAccountIDs.insert(configuration.id)
            }
            return errorResult
        }

        let result = await Self.fetchUsageWithTimeout(provider: provider, configuration: configuration)
        guard let result else {
            return nil
        }

        if replaceResult(result) {
            if result.isIncompleteRefresh {
                incompleteRefreshAccountIDs.insert(configuration.id)
            } else {
                incompleteRefreshAccountIDs.remove(configuration.id)
            }
        }
        return result
    }

    public func refresh() async {
        await refresh(configurations: ProviderID.allCases.map(ProviderAccountConfiguration.defaultConfiguration))
    }

    public func updateAutoRefresh(
        interval: AutoRefreshInterval,
        configurations: @escaping @MainActor () -> [ProviderAccountConfiguration],
        onRefreshFinished: (@MainActor () -> Void)? = nil
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

                if await self.refresh(configurations: configurations()) {
                    onRefreshFinished?()
                }
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
                    merged[result.accountID] = Self.preservingUsageData(
                        from: result,
                        cachedResult: existing
                    )
                }
            } else {
                merged[result.accountID] = result
            }
        }

        results = merged.values.sorted { $0.title < $1.title }
    }

    @discardableResult
    private func replaceResult(_ result: ProviderUsageResult) -> Bool {
        let existing = results.first(where: { $0.accountID == result.accountID })
        if let existing {
            guard existing.fetchedAt <= result.fetchedAt else {
                return false
            }
        }

        var nextResults = results.filter { $0.accountID != result.accountID }
        nextResults.append(Self.preservingUsageData(from: result, cachedResult: existing))
        results = nextResults.sorted { $0.title < $1.title }
        return true
    }

    private static func preservingUsageData(
        from result: ProviderUsageResult,
        cachedResult: ProviderUsageResult?
    ) -> ProviderUsageResult {
        let resultHasUsageData = result.creditsRemaining != nil
            || !result.bars.isEmpty
            || !result.monetaryMetrics.isEmpty
        guard
            result.isIncompleteRefresh,
            !resultHasUsageData,
            let cachedResult,
            cachedResult.creditsRemaining != nil
                || !cachedResult.bars.isEmpty
                || !cachedResult.monetaryMetrics.isEmpty
        else {
            return result
        }

        let subtitle: String
        if result.subtitle.localizedCaseInsensitiveContains("last known data") {
            subtitle = result.subtitle
        } else {
            let separator = result.subtitle.last.map { ".!?".contains($0) } == true ? " " : ". "
            subtitle = "\(result.subtitle)\(separator)Showing last known data."
        }

        return ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: subtitle,
            bars: cachedResult.bars,
            creditsRemaining: cachedResult.creditsRemaining,
            monetaryMetrics: cachedResult.monetaryMetrics,
            usageMessages: cachedResult.usageMessages,
            hasReachedSpendLimit: cachedResult.hasReachedSpendLimit,
            isIncompleteRefresh: true,
            fetchedAt: cachedResult.fetchedAt
        )
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
            isIncompleteRefresh: true,
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
        guard gate.install(continuation) else {
            return
        }

        fetchTask = Task {
            let result: ProviderUsageResult
            do {
                result = try await provider.fetchUsage(for: configuration)
            } catch is CancellationError {
                return
            } catch {
                result = UsageRefreshService.errorResult(for: configuration, error: error)
            }

            if gate.resumeOnce(with: result) {
                timeoutTask?.cancel()
                return
            }
        }

        timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }

            if gate.resumeOnce(with: UsageRefreshService.errorResult(for: configuration, error: RefreshTimeoutError())) {
                fetchTask?.cancel()
                timeoutTask?.cancel()
            }
        }
    }

    func cancel() {
        gate.markCancelled()
        fetchTask?.cancel()
        timeoutTask?.cancel()
    }
}

private final class RefreshResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var cancelled = false
    private var continuation: CheckedContinuation<ProviderUsageResult?, Never>?

    deinit {}

    func install(_ continuation: CheckedContinuation<ProviderUsageResult?, Never>) -> Bool {
        lock.withLock {
            guard !resumed else {
                return false
            }

            if cancelled {
                resumed = true
                continuation.resume(returning: nil)
                return false
            }

            self.continuation = continuation
            return true
        }
    }

    func markCancelled() {
        lock.withLock {
            guard !resumed else {
                return
            }

            cancelled = true
            if let continuation {
                resumed = true
                continuation.resume(returning: nil)
            }
        }
    }

    func resumeOnce(with result: ProviderUsageResult?) -> Bool {
        lock.withLock {
            guard !resumed, !cancelled, let continuation else {
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

    static func live(secretStore: any SecretStore = KeychainService()) -> UsageRefreshService {
        let providers: [any UsageProvider] = [
            CodexUsageProvider(secretStore: secretStore),
            ClaudeUsageProvider(secretStore: secretStore),
            CopilotUsageProvider(secretStore: secretStore),
            OpenRouterUsageProvider(secretStore: secretStore),
            CursorUsageProvider(secretStore: secretStore),
            OpenCodeZenUsageProvider(secretStore: secretStore),
            MoonshotUsageProvider(secretStore: secretStore),
            GeminiUsageProvider(),
        ] + DemoUsageProvider.samples.filter {
            $0.providerID != .codex
                && $0.providerID != .claude
                && $0.providerID != .copilot
                && $0.providerID != .openRouter
                && $0.providerID != .cursor
                && $0.providerID != .openCodeZen
                && $0.providerID != .moonshot
                && $0.providerID != .gemini
        }

        return UsageRefreshService(providers: providers)
    }
}
