import XCTest
@testable import CodexBarMac

final class TestSignal: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = stream
        self.continuation = continuation
    }

    deinit {}

    func signal() {
        continuation.yield()
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }
}

actor TestAsyncGate {
    private let blocked = TestSignal()
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            blocked.signal()
        }
    }

    func waitUntilBlocked() async {
        await blocked.wait()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

struct TestWatchdogError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private final class TestWatchdogStartLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    deinit {}

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !isOpen else { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func open() {
        let pendingWaiters = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private final class TestWatchdogTaskCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var isTerminated = false
    private var tasks: [Task<Void, Never>] = []

    deinit {}

    func install(_ tasks: [Task<Void, Never>]) {
        let shouldCancel = lock.withLock {
            guard !isTerminated else { return true }
            self.tasks = tasks
            return false
        }
        guard shouldCancel else { return }

        for task in tasks {
            task.cancel()
        }
    }

    func terminate() {
        let tasksToCancel = lock.withLock {
            isTerminated = true
            defer { tasks.removeAll() }
            return tasks
        }
        for task in tasksToCancel {
            task.cancel()
        }
    }
}

private final class TestWatchdogOutcomeCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var didChooseOutcome = false

    deinit {}

    func claimOperation() -> Bool {
        claimOutcome()
    }

    func claimTimeout() -> Bool {
        claimOutcome()
    }

    private func claimOutcome() -> Bool {
        lock.withLock {
            guard !didChooseOutcome else { return false }
            didChooseOutcome = true
            return true
        }
    }
}

func withTestWatchdog<Result: Sendable>(
    timeout: Duration,
    failureMessage: String,
    onTimeout: @escaping @Sendable () -> Void,
    waitForTimeout: @escaping @Sendable (Duration) async throws -> Void = { duration in
        try await Task.sleep(for: duration)
    },
    operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    let outcomes = AsyncThrowingStream(Result.self) { continuation in
        let startLatch = TestWatchdogStartLatch()
        let taskCoordinator = TestWatchdogTaskCoordinator()
        let outcomeCoordinator = TestWatchdogOutcomeCoordinator()
        continuation.onTermination = { _ in
            taskCoordinator.terminate()
        }

        let operationTask = Task {
            await startLatch.wait()
            do {
                let result = try await operation()
                guard outcomeCoordinator.claimOperation() else { return }
                continuation.yield(result)
                continuation.finish()
            } catch {
                guard outcomeCoordinator.claimOperation() else { return }
                continuation.finish(throwing: error)
            }
        }
        let timeoutTask = Task {
            await startLatch.wait()
            do {
                try await waitForTimeout(timeout)
                try Task.checkCancellation()
            } catch {
                return
            }

            guard outcomeCoordinator.claimTimeout() else { return }
            onTimeout()
            continuation.finish(throwing: TestWatchdogError(message: failureMessage))
        }
        taskCoordinator.install([operationTask, timeoutTask])
        startLatch.open()
    }

    for try await result in outcomes {
        return result
    }
    throw CancellationError()
}

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
    private var startedCount = 0
    private var completedCount = 0
    private var isReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(providerID: ProviderID, outcome: Outcome) {
        self.providerID = providerID
        self.outcome = outcome
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        startedCount += 1
        defer {
            completedCount += 1
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }

        switch outcome {
        case .failure(let message):
            throw SequencedUsageProviderError(message: message)
        case .result(let result):
            return result
        }
    }

    func waitUntilStarted(count: Int = 1) async -> Bool {
        for _ in 0..<200 {
            if startedCount >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return startedCount >= count
    }

    func waitUntilCompleted(count: Int = 1) async -> Bool {
        for _ in 0..<200 {
            if completedCount >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return completedCount >= count
    }

    func release() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
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
