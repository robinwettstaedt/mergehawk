@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubReadLimiterTests: XCTestCase {
    func testAtMostFourOperationsRunAtOnce() async throws {
        let limiter = GitHubReadLimiter()
        let gate = AsyncGate()
        let running = LockedBox((now: 0, peak: 0))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await limiter.withPermit(.bulk) {
                        running.withValue { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                        await gate.wait()
                        running.withValue { $0.now -= 1 }
                    }
                }
            }
            await waitForCondition { gate.waitingCount == 4 && limiter.waitingCount == 6 }
            XCTAssertEqual(running.value.peak, 4)
            gate.open()
            try await group.waitForAll()
        }

        XCTAssertEqual(running.value.peak, 4)
        XCTAssertEqual(running.value.now, 0)
    }

    func testBulkWaitersGoInArrivalOrderAndAChainWaiterGoesFirst() async throws {
        let limiter = GitHubReadLimiter(capacity: 1)
        let gate = AsyncGate()
        let order = LockedBox<[String]>([])

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await limiter.withPermit(.bulk) { await gate.wait() } }
            await waitForCondition { gate.waitingCount == 1 }
            for (index, name) in ["B1", "B2", "B3", "C"].enumerated() {
                group.addTask {
                    try await limiter.withPermit(name == "C" ? .chain : .bulk) { order.withValue { $0.append(name) } }
                }
                await waitForCondition { limiter.waitingCount == index + 1 }
            }
            gate.open()
            try await group.waitForAll()
        }

        XCTAssertEqual(order.value, ["C", "B1", "B2", "B3"])
    }

    func testCancelledWaiterLeavesTheQueueAndThePermitGoesToTheNextWaiter() async throws {
        let limiter = GitHubReadLimiter(capacity: 1)
        let gate = AsyncGate()
        let ran = LockedBox<[String]>([])

        let holder = Task { try await limiter.withPermit(.bulk) { await gate.wait() } }
        await waitForCondition { gate.waitingCount == 1 }
        let cancelled = Task { try await limiter.withPermit(.bulk) { ran.withValue { $0.append("cancelled") } } }
        await waitForCondition { limiter.waitingCount == 1 }
        let next = Task { try await limiter.withPermit(.bulk) { ran.withValue { $0.append("next") } } }
        await waitForCondition { limiter.waitingCount == 2 }

        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Expected the cancelled waiter to throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(limiter.waitingCount, 1)
        gate.open()
        try await holder.value
        try await next.value

        XCTAssertEqual(ran.value, ["next"])
        XCTAssertFalse(limiter.isStopped)
    }

    func testCallerCancelledBeforeWaitingThrowsWithoutRunning() async {
        let limiter = GitHubReadLimiter()
        let ran = LockedBox(false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await limiter.withPermit(.chain) { ran.withValue { $0 = true } }
        }

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(ran.value)
    }

    func testFailingOperationTurnsAwayQueuedWaitersBeforeItsPermitFrees() async throws {
        let limiter = GitHubReadLimiter(capacity: 1)
        let gate = AsyncGate()
        let ran = LockedBox(0)

        let failing = Task {
            try await limiter.withPermit(.bulk) { () async throws -> Void in
                await gate.wait()
                throw GitHubReadError.invalidPayload
            }
        }
        await waitForCondition { gate.waitingCount == 1 }
        let waiters = (0..<3).map { _ in
            Task { try await limiter.withPermit(.bulk) { ran.increment() } }
        }
        await waitForCondition { limiter.waitingCount == 3 }
        gate.open()

        do {
            try await failing.value
            XCTFail("Expected invalid payload")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .invalidPayload)
        }
        for waiter in waiters {
            do {
                _ = try await waiter.value
                XCTFail("Expected a stopped read")
            } catch {
                XCTAssertTrue(error is GitHubReadStopped, "\(error)")
            }
        }
        XCTAssertEqual(ran.value, 0)
        XCTAssertTrue(limiter.isStopped)
    }

    func testStoppedOrCancelledOperationReleasesItsPermitWithoutStopping() async throws {
        let limiter = GitHubReadLimiter(capacity: 1)
        for error in [GitHubReadStopped() as Error, CancellationError()] {
            do {
                try await limiter.withPermit(.bulk) { () async throws -> Void in throw error }
                XCTFail("Expected \(error)")
            } catch {}
            XCTAssertFalse(limiter.isStopped)
        }

        let value = try await limiter.withPermit(.bulk) { "ran" }
        XCTAssertEqual(value, "ran")
    }

    func testStopTurnsAwayWaitersAndLaterCallsWhileRunningOperationsFinish() async throws {
        let limiter = GitHubReadLimiter(capacity: 1)
        let gate = AsyncGate()
        let running = Task { try await limiter.withPermit(.bulk) { () async -> String in await gate.wait(); return "done" } }
        await waitForCondition { gate.waitingCount == 1 }
        let waiting = Task { try await limiter.withPermit(.chain) { "waited" } }
        await waitForCondition { limiter.waitingCount == 1 }

        limiter.stop()
        gate.open()

        let runningValue = try await running.value
        XCTAssertEqual(runningValue, "done")
        do {
            _ = try await waiting.value
            XCTFail("Expected a stopped read")
        } catch {
            XCTAssertTrue(error is GitHubReadStopped, "\(error)")
        }
        do {
            _ = try await limiter.withPermit(.bulk) { "later" }
            XCTFail("Expected a stopped read")
        } catch {
            XCTAssertTrue(error is GitHubReadStopped, "\(error)")
        }
        XCTAssertTrue(limiter.isStopped)
    }

    func testFailRecordsAndStopsAndFailurePicksByPrecedence() async {
        let limiter = GitHubReadLimiter()
        XCTAssertNil(limiter.failure())

        limiter.fail(GitHubReadError.invalidPayload, at: GitHubReadOrder(.discovery))
        limiter.fail(GitHubReadError.rateLimited(retryAt: nil), at: GitHubReadOrder(.continuation))

        XCTAssertTrue(limiter.isStopped)
        XCTAssertEqual(limiter.failure() as? GitHubReadError, .rateLimited(retryAt: nil))
        do {
            _ = try await limiter.withPermit(.chain) { "after" }
            XCTFail("Expected a stopped read")
        } catch {
            XCTAssertTrue(error is GitHubReadStopped, "\(error)")
        }
    }

    func testCapacityOneRunsOperationsOneAtATimeInGrantOrder() async throws {
        let limiter = GitHubReadLimiter(capacity: 1)
        let gate = AsyncGate()
        let events = LockedBox<[String]>([])

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await limiter.withPermit(.bulk) { await gate.wait() } }
            await waitForCondition { gate.waitingCount == 1 }
            for index in 0..<5 {
                group.addTask {
                    try await limiter.withPermit(.bulk) {
                        events.withValue { $0.append("start \(index)") }
                        await Task.yield()
                        events.withValue { $0.append("end \(index)") }
                    }
                }
                await waitForCondition { limiter.waitingCount == index + 1 }
            }
            gate.open()
            try await group.waitForAll()
        }

        XCTAssertEqual(events.value, (0..<5).flatMap { ["start \($0)", "end \($0)"] })
    }

    // MARK: Fetcher reads

    func testFetcherWithAStoppedLimiterSendsNothing() async {
        let limiter = GitHubReadLimiter()
        limiter.stop()
        let reads = LockedBox(0)
        let fetcher = GitHubPullRequestFetcher(read: { _, _ in
            reads.increment()
            return Data()
        }, limiter: limiter)

        do {
            _ = try await fetcher.discover(login: "rw")
            XCTFail("Expected a stopped read")
        } catch {
            XCTAssertTrue(error is GitHubReadStopped, "\(error)")
        }
        XCTAssertEqual(reads.value, 0)
    }

    func testResponseThatFailsDecodingStopsTheLimiterBeforeTheNextWaiterRuns() async throws {
        let limiter = GitHubReadLimiter(capacity: 1)
        let gate = AsyncGate()
        let reads = LockedBox<[String]>([])
        let fetcher = GitHubPullRequestFetcher(read: { query, _ in
            reads.withValue { $0.append(query.contains("DiscoveryBounds") ? "bounds" : "other") }
            await gate.wait()
            return Data(#"{"data": {"unexpected": true}}"#.utf8)
        }, limiter: limiter)

        let discovery = Task { try await fetcher.discover(login: "rw") }
        await waitForCondition { gate.waitingCount == 1 }
        let waiting = Task { try await fetcher.withPriority(.chain).fetchViewerTeams(login: "rw") }
        await waitForCondition { limiter.waitingCount == 1 }
        gate.open()

        do {
            _ = try await discovery.value
            XCTFail("Expected a decoding failure")
        } catch {
            XCTAssertFalse(error is GitHubReadStopped, "\(error)")
        }
        do {
            _ = try await waiting.value
            XCTFail("Expected a stopped read")
        } catch {
            XCTAssertTrue(error is GitHubReadStopped, "\(error)")
        }
        XCTAssertEqual(reads.value, ["bounds"])
        XCTAssertTrue(limiter.isStopped)
    }
}
