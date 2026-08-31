import Combine
import Foundation

@MainActor
public final class UsageRefreshService: ObservableObject {
    @Published public private(set) var results: [ProviderUsageResult] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var incompleteRefreshAccountIDs: Set<String> = []

    private let providers: [any UsageProvider]
    private let sleepBeforeAutoRefresh: @Sendable (TimeInterval) async throws -> Void
    private var autoRefreshTask: Task<Void, Never>?
    private var hasCurrentConfigurationSnapshot = false
    private var currentConfigurationsByAccountID: [String: ProviderAccountConfiguration] = [:]
    private var refreshGenerationsByAccountID: [String: UUID] = [:]
    private var refreshInputRevision = 0

    public var successfulRefreshResults: [ProviderUsageResult] {
        results.filter { !incompleteRefreshAccountIDs.contains($0.accountID) }
    }

    public convenience init(
        providers: [any UsageProvider],
        initialResults: [ProviderUsageResult] = []
    ) {
        self.init(
            providers: providers,
            initialResults: initialResults,
            sleepBeforeAutoRefresh: { seconds in
                try await Task.sleep(for: .seconds(seconds))
            }
        )
    }

    init(
        providers: [any UsageProvider],
        initialResults: [ProviderUsageResult] = [],
        sleepBeforeAutoRefresh: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.providers = providers
        self.results = initialResults
        self.sleepBeforeAutoRefresh = sleepBeforeAutoRefresh
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    @discardableResult
    public func refresh(configurations: [ProviderAccountConfiguration]) async -> Bool {
        updateCurrentConfigurations(configurations)
        guard !isRefreshing else {
            return false
        }

        let revision = refreshInputRevision
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        let enabledConfigurations = configurations.filter(\.isEnabled)
        var outcomes: [(ProviderAccountConfiguration, UUID, ProviderUsageResult?)] = []

        await withTaskGroup(
            of: (ProviderAccountConfiguration, UUID, ProviderUsageResult?).self
        ) { group in
            for configuration in enabledConfigurations {
                guard
                    isCurrent(configuration),
                    let generation = refreshGenerationsByAccountID[configuration.id]
                else {
                    continue
                }
                guard let provider = providers.first(where: { $0.providerID == configuration.providerID }) else {
                    let errorResult = Self.errorResult(for: configuration, error: MissingUsageProviderError())
                    group.addTask {
                        (configuration, generation, errorResult)
                    }
                    continue
                }

                group.addTask {
                    let result = await Self.fetchUsageWithTimeout(provider: provider, configuration: configuration)
                    return (configuration, generation, result)
                }
            }

            for await (configuration, generation, result) in group {
                outcomes.append((configuration, generation, result))
            }
        }

        let currentOutcomes = outcomes.filter { configuration, generation, _ in
            isCurrent(configuration, generation: generation)
        }
        let nextResults = currentOutcomes.compactMap(\.2)
        let unavailableAccountIDs = Set(
            currentOutcomes.lazy
                .filter { $0.2 == nil }
                .map { $0.0.id }
        )
        applyBulkResults(nextResults)
        incompleteRefreshAccountIDs = unavailableAccountIDs.union(
            results.lazy
                .filter(\.isIncompleteRefresh)
                .map(\.accountID)
        )
        return refreshInputRevision == revision
    }

    @discardableResult
    public func refresh(configuration: ProviderAccountConfiguration) async -> ProviderUsageResult? {
        guard configuration.isEnabled else {
            return nil
        }

        let generation: UUID
        if hasCurrentConfigurationSnapshot {
            guard
                isCurrent(configuration),
                let currentGeneration = refreshGenerationsByAccountID[configuration.id]
            else {
                return nil
            }
            generation = currentGeneration
        } else {
            generation = registerCurrentConfiguration(configuration)
        }

        guard let provider = providers.first(where: { $0.providerID == configuration.providerID }) else {
            let errorResult = Self.errorResult(for: configuration, error: MissingUsageProviderError())
            guard isCurrent(configuration, generation: generation) else {
                return nil
            }
            if replaceResult(errorResult) {
                incompleteRefreshAccountIDs.insert(configuration.id)
            }
            return errorResult
        }

        let result = await Self.fetchUsageWithTimeout(provider: provider, configuration: configuration)
        guard
            let result,
            isCurrent(configuration, generation: generation)
        else {
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

        let sleepBeforeAutoRefresh = self.sleepBeforeAutoRefresh
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleepBeforeAutoRefresh(seconds)
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

    func updateCurrentConfigurations(
        _ configurations: [ProviderAccountConfiguration]
    ) {
        let hadCurrentConfigurationSnapshot = hasCurrentConfigurationSnapshot
        hasCurrentConfigurationSnapshot = true
        let enabledConfigurations = configurations.filter(\.isEnabled)
        let nextConfigurations = enabledConfigurations.reduce(
            into: [String: ProviderAccountConfiguration]()
        ) { configurationsByID, configuration in
            configurationsByID[configuration.id] = configuration
        }
        let accountIDs = Set(currentConfigurationsByAccountID.keys)
            .union(nextConfigurations.keys)
        var invalidatedAccountIDs = Set<String>()

        for accountID in accountIDs {
            let currentConfiguration = currentConfigurationsByAccountID[accountID]
            let nextConfiguration = nextConfigurations[accountID]
            guard currentConfiguration != nextConfiguration,
                  refreshInputsChanged(from: currentConfiguration, to: nextConfiguration)
            else {
                continue
            }

            invalidatedAccountIDs.insert(accountID)
            if nextConfiguration == nil {
                refreshGenerationsByAccountID.removeValue(forKey: accountID)
            } else {
                refreshGenerationsByAccountID[accountID] = UUID()
            }
        }

        currentConfigurationsByAccountID = nextConfigurations
        if !invalidatedAccountIDs.isEmpty {
            refreshInputRevision += 1
        }

        let enabledAccountIDs = Set(nextConfigurations.keys)
        let evictedAccountIDs = hadCurrentConfigurationSnapshot ? invalidatedAccountIDs : []
        pruneCachedState(to: enabledAccountIDs.subtracting(evictedAccountIDs))
    }

    func invalidateCredential(forAccountID accountID: String) {
        guard currentConfigurationsByAccountID[accountID] != nil else {
            pruneCachedState(to: Set(currentConfigurationsByAccountID.keys))
            return
        }

        refreshGenerationsByAccountID[accountID] = UUID()
        refreshInputRevision += 1
        pruneCachedState(to: Set(currentConfigurationsByAccountID.keys).subtracting([accountID]))
    }

    func hasSameRefreshInputs(
        _ first: ProviderAccountConfiguration,
        _ second: ProviderAccountConfiguration
    ) -> Bool {
        RefreshInputs(configuration: first) == RefreshInputs(configuration: second)
    }

    private func applyBulkResults(_ incoming: [ProviderUsageResult]) {
        let enabledAccountIDs = Set(currentConfigurationsByAccountID.keys)
        var merged = Dictionary(
            uniqueKeysWithValues: results
                .filter { enabledAccountIDs.contains($0.accountID) }
                .map { ($0.accountID, $0) }
        )

        for result in incoming {
            guard enabledAccountIDs.contains(result.accountID) else {
                continue
            }
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

    private func pruneCachedState(to allowedAccountIDs: Set<String>) {
        let nextResults = results.filter { allowedAccountIDs.contains($0.accountID) }
        if nextResults != results {
            results = nextResults
        }
        let nextIncompleteAccountIDs = incompleteRefreshAccountIDs.intersection(allowedAccountIDs)
        if nextIncompleteAccountIDs != incompleteRefreshAccountIDs {
            incompleteRefreshAccountIDs = nextIncompleteAccountIDs
        }
    }

    private func refreshInputsChanged(
        from currentConfiguration: ProviderAccountConfiguration?,
        to nextConfiguration: ProviderAccountConfiguration?
    ) -> Bool {
        guard let currentConfiguration, let nextConfiguration else {
            return true
        }
        return !hasSameRefreshInputs(currentConfiguration, nextConfiguration)
    }

    private func registerCurrentConfiguration(
        _ configuration: ProviderAccountConfiguration
    ) -> UUID {
        if currentConfigurationsByAccountID[configuration.id] != configuration {
            currentConfigurationsByAccountID[configuration.id] = configuration
            refreshGenerationsByAccountID[configuration.id] = UUID()
        }
        let generation = refreshGenerationsByAccountID[configuration.id] ?? UUID()
        refreshGenerationsByAccountID[configuration.id] = generation
        return generation
    }

    private func isCurrent(_ configuration: ProviderAccountConfiguration) -> Bool {
        currentConfigurationsByAccountID[configuration.id] == configuration
    }

    private func isCurrent(
        _ configuration: ProviderAccountConfiguration,
        generation: UUID
    ) -> Bool {
        guard let currentConfiguration = currentConfigurationsByAccountID[configuration.id] else {
            return false
        }
        return !refreshInputsChanged(from: configuration, to: currentConfiguration)
            && refreshGenerationsByAccountID[configuration.id] == generation
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
        let hasComponentPreservation = result.preservesCachedBarsOnIncompleteRefresh
            || result.preservesCachedCreditsOnIncompleteRefresh
        guard
            result.isIncompleteRefresh,
            let cachedResult,
            canReuseCachedResult(cachedResult, for: result)
        else {
            return result
        }

        let preservesAllUsageData = !resultHasUsageData && (
            !hasComponentPreservation
                || result.preservesCachedBarsOnIncompleteRefresh
                    && result.preservesCachedCreditsOnIncompleteRefresh
        )
        let restoresBars = (preservesAllUsageData || result.preservesCachedBarsOnIncompleteRefresh)
            && result.bars.isEmpty
            && !cachedResult.bars.isEmpty
        let restoresCredits = (preservesAllUsageData || result.preservesCachedCreditsOnIncompleteRefresh)
            && result.creditsRemaining == nil
            && cachedResult.creditsRemaining != nil
        let restoresMonetaryMetrics = preservesAllUsageData
            && result.monetaryMetrics.isEmpty
            && !cachedResult.monetaryMetrics.isEmpty
        guard restoresBars || restoresCredits || restoresMonetaryMetrics else {
            return result
        }

        let bars = restoresBars
            ? cachedResult.bars
            : result.bars
        let creditsRemaining = restoresCredits
            ? cachedResult.creditsRemaining
            : result.creditsRemaining
        let monetaryMetrics = restoresMonetaryMetrics ? cachedResult.monetaryMetrics : result.monetaryMetrics

        let subtitle: String
        if result.subtitle.localizedCaseInsensitiveContains("last known data") {
            subtitle = result.subtitle
        } else {
            let separator = result.subtitle.last.map { ".!?".contains($0) } == true ? " " : ". "
            subtitle = "\(result.subtitle)\(separator)Showing last known data."
        }

        let title: String
        if result.providerID == .openCodeZen {
            let titleConfiguration = ProviderAccountConfiguration(
                id: result.accountID,
                providerID: .openCodeZen,
                accountLabel: result.title,
                authMethod: .browserSession
            )
            title = titleConfiguration.openCodeDisplayName(
                hasGoUsage: !bars.isEmpty,
                hasZenBalance: creditsRemaining != nil
            )
        } else {
            title = result.title
        }

        return ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: title,
            subtitle: subtitle,
            bars: bars,
            creditsRemaining: creditsRemaining,
            monetaryMetrics: monetaryMetrics,
            usageMessages: preservesAllUsageData ? cachedResult.usageMessages : result.usageMessages,
            hasReachedSpendLimit: preservesAllUsageData
                ? cachedResult.hasReachedSpendLimit
                : result.hasReachedSpendLimit,
            historyFreshness: result.historyFreshness,
            cacheIdentity: preservesAllUsageData ? cachedResult.cacheIdentity : result.cacheIdentity,
            cacheScope: preservesAllUsageData ? cachedResult.cacheScope : result.cacheScope,
            allowsUnscopedCacheReuse: result.allowsUnscopedCacheReuse,
            isIncompleteRefresh: true,
            fetchedAt: preservesAllUsageData ? cachedResult.fetchedAt : result.fetchedAt
        )
    }

    private nonisolated static func canReuseCachedResult(
        _ cachedResult: ProviderUsageResult,
        for result: ProviderUsageResult
    ) -> Bool {
        guard result.providerID == .openCodeZen else {
            return true
        }
        guard let cacheIdentity = result.cacheIdentity else {
            guard
                result.allowsUnscopedCacheReuse,
                let cacheScope = result.cacheScope
            else {
                return false
            }
            return cachedResult.cacheScope == cacheScope
        }
        return cachedResult.cacheIdentity == cacheIdentity
    }

    nonisolated static func fetchUsageWithTimeout(
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
            cacheScope: configuration.providerID == .openCodeZen
                ? OpenCodeZenUsageProvider.normalizedWorkspaceId(from: configuration.openCodeWorkspaceId)
                : nil,
            isIncompleteRefresh: true,
            fetchedAt: Date()
        )
    }
}

/// Refresh-relevant subset of `ProviderAccountConfiguration`.
///
/// Evaluate every new provider-routing field for inclusion here. Presentation-only
/// fields such as `accountLabel`, `groupID`, and `showsHistory` stay omitted. Update
/// `testRefreshInputsDistinguishRoutingChangesFromPresentationChanges` with this list.
private struct RefreshInputs: Equatable {
    let providerID: ProviderID
    let authMethod: ProviderAuthMethod
    let oauthClientID: String?
    let copilotAccountScope: CopilotAccountScope
    let githubOrganization: String
    let githubEnterprise: String
    let githubCLIUsername: String
    let copilotTotalAllotment: Double?
    let openCodeWorkspaceId: String
    let showsCursorGrokBotWeekly: Bool

    init(configuration: ProviderAccountConfiguration) {
        self.providerID = configuration.providerID
        self.authMethod = configuration.authMethod
        self.oauthClientID = configuration.oauthClientID
        self.copilotAccountScope = configuration.copilotAccountScope
        self.githubOrganization = configuration.githubOrganization
        self.githubEnterprise = configuration.githubEnterprise
        self.githubCLIUsername = configuration.githubCLIUsername
        self.copilotTotalAllotment = configuration.copilotTotalAllotment
        self.openCodeWorkspaceId = configuration.openCodeWorkspaceId
        self.showsCursorGrokBotWeekly = configuration.showsCursorGrokBotWeekly
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
    private let taskLock = NSLock()
    private var isTerminal = false
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

        let fetchTask = Task {
            let result: ProviderUsageResult
            do {
                result = try await provider.fetchUsage(for: configuration)
            } catch is CancellationError {
                return
            } catch {
                result = UsageRefreshService.errorResult(for: configuration, error: error)
            }

            if gate.resumeOnce(with: result) {
                cancelTasks()
            }
        }
        install(fetchTask, as: .fetch)

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }

            if gate.resumeOnce(with: UsageRefreshService.errorResult(for: configuration, error: RefreshTimeoutError())) {
                cancelTasks()
            }
        }
        install(timeoutTask, as: .timeout)
    }

    func cancel() {
        gate.markCancelled()
        cancelTasks()
    }

    private enum TaskKind {
        case fetch
        case timeout
    }

    private func install(_ task: Task<Void, Never>, as kind: TaskKind) {
        let shouldCancel = taskLock.withLock {
            guard !isTerminal else {
                return true
            }

            switch kind {
            case .fetch:
                fetchTask = task
            case .timeout:
                timeoutTask = task
            }
            return false
        }

        if shouldCancel {
            task.cancel()
        }
    }

    private func cancelTasks() {
        let tasks = taskLock.withLock {
            isTerminal = true
            let tasks = (fetchTask, timeoutTask)
            fetchTask = nil
            timeoutTask = nil
            return tasks
        }

        tasks.0?.cancel()
        tasks.1?.cancel()
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
