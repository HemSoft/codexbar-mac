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

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
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

