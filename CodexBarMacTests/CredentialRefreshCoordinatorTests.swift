import XCTest
@testable import CodexBarMac

final class CredentialRefreshCoordinatorTests: XCTestCase {
    deinit {}

    func testSameAccountJoinsOneInFlightOperation() async throws {
        let coordinator = CredentialRefreshCoordinator<Int>()
        let operationCount = RefreshOperationCounter()
        let operationStarted = TestSignal()
        let releaseOperation = TestSignal()
        let refreshJoined = TestSignal()

        let results = try await withTestWatchdog(
            timeout: .seconds(10),
            failureMessage: "Same-account credential refresh did not coalesce within the test bound.",
            onTimeout: { releaseOperation.signal() }
        ) {
            let first = Task {
                await coordinator.run(for: "account-a") {
                    await operationCount.increment()
                    operationStarted.signal()
                    await releaseOperation.wait()
                    return 42
                }
            }
            defer {
                first.cancel()
                releaseOperation.signal()
            }
            await operationStarted.wait()

            let second = Task {
                await coordinator.run(
                    for: "account-a",
                    onJoinExistingTask: { refreshJoined.signal() }
                ) {
                    await operationCount.increment()
                    return 99
                }
            }
            defer { second.cancel() }
            await refreshJoined.wait()

            releaseOperation.signal()
            return await [first.value, second.value]
        }

        let finalOperationCount = await operationCount.currentValue()
        XCTAssertEqual(results, [42, 42])
        XCTAssertEqual(finalOperationCount, 1)
    }

    func testDifferentAccountsRunIndependentOperations() async throws {
        let coordinator = CredentialRefreshCoordinator<Int>()
        let operationCount = RefreshOperationCounter()
        let firstStarted = TestSignal()
        let releaseFirst = TestSignal()
        let secondStarted = TestSignal()
        let unexpectedlyJoined = LockedTestFlag()

        let results = try await withTestWatchdog(
            timeout: .seconds(10),
            failureMessage: "Different-account credential refreshes did not remain independent.",
            onTimeout: { releaseFirst.signal() }
        ) {
            let first = Task {
                await coordinator.run(for: "account-a") {
                    await operationCount.increment()
                    firstStarted.signal()
                    await releaseFirst.wait()
                    return 1
                }
            }
            defer {
                first.cancel()
                releaseFirst.signal()
            }
            await firstStarted.wait()

            let second = Task {
                await coordinator.run(
                    for: "account-b",
                    onJoinExistingTask: { unexpectedlyJoined.set() }
                ) {
                    await operationCount.increment()
                    secondStarted.signal()
                    return 2
                }
            }
            defer { second.cancel() }
            await secondStarted.wait()

            let secondResult = await second.value
            releaseFirst.signal()
            return await [first.value, secondResult]
        }

        let finalOperationCount = await operationCount.currentValue()
        XCTAssertEqual(results, [1, 2])
        XCTAssertEqual(finalOperationCount, 2)
        XCTAssertFalse(unexpectedlyJoined.currentValue())
    }

    func testWatchdogDoesNotAwaitOperationThatIgnoresCancellation() async throws {
        let operationGate = TestAsyncGate()
        defer { Task { await operationGate.release() } }

        do {
            let _: Void = try await withTestWatchdog(
                timeout: .seconds(10),
                failureMessage: "Expected watchdog timeout.",
                onTimeout: {},
                waitForTimeout: { _ in
                    await operationGate.waitUntilBlocked()
                },
                operation: {
                    await operationGate.wait()
                }
            )
            XCTFail("Expected the watchdog to time out.")
        } catch let error as TestWatchdogError {
            XCTAssertEqual(error.message, "Expected watchdog timeout.")
        }
    }
}

private actor RefreshOperationCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}

private final class LockedTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    deinit {}

    func set() {
        lock.withLock { value = true }
    }

    func currentValue() -> Bool {
        lock.withLock { value }
    }
}
