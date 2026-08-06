import XCTest
@testable import CodexBarMac

struct StubUsageProvider: UsageProvider {
    let providerID: ProviderID
    let result: ProviderUsageResult

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        result
    }
}

actor SequencedUsageProvider: UsageProvider {
    enum Step: Sendable {
        case failure(String)
        case result(ProviderUsageResult)
    }

    nonisolated let providerID: ProviderID
    private var steps: [Step]

    init(providerID: ProviderID, steps: [Step]) {
        self.providerID = providerID
        self.steps = steps
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard !steps.isEmpty else {
            throw SequencedUsageProviderError(message: "No response configured")
        }

        switch steps.removeFirst() {
        case .failure(let message):
            throw SequencedUsageProviderError(message: message)
        case .result(let result):
            return result
        }
    }
}

actor BlockingUsageProvider: UsageProvider {
    nonisolated let providerID: ProviderID
    private var started = false
    private var cancellationObserved = false

    init(providerID: ProviderID) {
        self.providerID = providerID
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        started = true

        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            cancellationObserved = true
            throw CancellationError()
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Unexpected completion",
            bars: [],
            fetchedAt: Date()
        )
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if started {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return started
    }

    func waitUntilCancellationObserved() async -> Bool {
        for _ in 0..<200 {
            if cancellationObserved {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cancellationObserved
    }
}

actor GatedUsageProvider: UsageProvider {
    enum Outcome: Sendable {
        case failure(String)
        case result(ProviderUsageResult)
    }

    nonisolated let providerID: ProviderID
    private let outcome: Outcome
    private var started = false
    private var completed = false
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(providerID: ProviderID, outcome: Outcome) {
        self.providerID = providerID
        self.outcome = outcome
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        started = true
        defer {
            completed = true
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        switch outcome {
        case .failure(let message):
            throw SequencedUsageProviderError(message: message)
        case .result(let result):
            return result
        }
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if started {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return started
    }

    func waitUntilCompleted() async -> Bool {
        for _ in 0..<200 {
            if completed {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return completed
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

struct SequencedUsageProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
final class StubUsageAlertNotifier: UsageAlertNotifying {
    deinit {}

    func requestAuthorization() async -> Bool {
        true
    }

    func deliver(_ notification: UsageAlertNotification) async throws {}
}
