@testable import mergehawk
@testable import mergehawkcore
import Combine
import Foundation
import XCTest

/// A sleep that records each duration and suspends until the test releases it. Cancelling the sleeping task
/// throws `CancellationError`, like `Task.sleep`.
final class SuspendingTestSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private var waiting: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var cancelledIDs: Set<Int> = []
    private var nextID = 0
    private var cancellations = 0

    var durations: [TimeInterval] { lock.withLock { recorded } }
    var waitingCount: Int { lock.withLock { waiting.count } }
    var cancelledCount: Int { lock.withLock { cancellations } }

    func sleep(_ seconds: TimeInterval) async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            recorded.append(seconds)
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if cancelledIDs.contains(id) { return true }
                    waiting.append((id, continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                cancelledIDs.insert(id)
                cancellations += 1
                guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest pending sleep.
    func releaseNext() {
        let continuation = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst().continuation }
        continuation?.resume()
    }
}

final class AutomaticPacingTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let reset = start.addingTimeInterval(3_000)

    @MainActor
    func testWithoutAReadingTheFirstSleepIsTheUserInterval() async throws {
        let fixture = makeFixture(budgetRead: { nil })

        await waitForBudgetCondition { fixture.sleeper.waitingCount == 1 }

        XCTAssertEqual(fixture.sleeper.durations, [120])
    }

    @MainActor
    func testStretchedReadingSleepsTheStretchedInterval() async throws {
        // 1,545 left with a 55 point sample buys 9 refreshes over 3,000 s, so one every 6 min.
        let fixture = makeFixture(baseline: 3_400, fetched: 3_455)
        await waitForLaunch(fixture)

        fixture.controller.refreshIntervalMinutes = 1

        await waitForBudgetCondition { fixture.sleeper.durations.count == 2 }
        XCTAssertEqual(fixture.sleeper.durations.last, 360)
    }

    @MainActor
    func testStretchedSleepIsCappedAtResetPlusMargin() async throws {
        // 55 above the reserve buys one refresh in the 130 s left, stretched to 3 min and capped at 135 s.
        let fixture = makeFixture(baseline: 3_890, fetched: 3_945, resetIn: 130)
        await waitForLaunch(fixture)

        fixture.controller.refreshIntervalMinutes = 1

        await waitForBudgetCondition { fixture.sleeper.durations.count == 2 }
        XCTAssertEqual(fixture.sleeper.durations.last, 135)
    }

    @MainActor
    func testPausedReadingSleepsUntilResetPlusMarginAndAMinuteOnceThatPassed() async throws {
        let fixture = makeFixture(baseline: 3_950, fetched: 4_005)
        await waitForLaunch(fixture)

        fixture.controller.refreshIntervalMinutes = 1
        await waitForBudgetCondition { fixture.sleeper.durations.count == 2 }
        XCTAssertEqual(fixture.sleeper.durations.last, 3_005)

        // GitHub has not reset although the Mac's clock passed the reset. The free budget read leaves `used`
        // unchanged, so the newer reading wins the tie and stays usable.
        fixture.clock.now = Self.reset.addingTimeInterval(10)
        fixture.provider.budgetRead = {
            GitHubBudgetReading(limit: 5_000, remaining: 995, used: 4_005, resetAt: Self.reset, receivedAt: fixture.clock.now)
        }
        fixture.provider.fetchReading = nil
        fixture.controller.refresh()
        await waitForBudgetCondition { fixture.provider.fetchCount == 2 && !fixture.controller.isRefreshing }
        fixture.controller.refreshIntervalMinutes = 2

        await waitForBudgetCondition { fixture.sleeper.durations.count == 3 }
        XCTAssertEqual(fixture.sleeper.durations.last, 60)
    }

    @MainActor
    func testFreshPausedReadAtWakeSendsNoRefreshQuery() async throws {
        let fixture = makeFixture(baseline: 800, fetched: 855)
        await waitForLaunch(fixture)
        let syncedAt = fixture.controller.state.syncedAt
        fixture.provider.fetchFailure = GitHubReadError.http(status: 502)
        fixture.controller.refresh()
        await waitForBudgetCondition { fixture.controller.refreshErrorMessage != nil && !fixture.controller.isRefreshing }
        let errorMessage = fixture.controller.refreshErrorMessage
        var refreshingValues: [Bool] = []
        let subscription = fixture.controller.$isRefreshing.dropFirst().sink { refreshingValues.append($0) }
        defer { subscription.cancel() }
        fixture.provider.budgetRead = { budgetReading(used: 4_100, at: fixture.clock.now, resetIn: 2_880) }

        fixture.clock.now = Self.start.addingTimeInterval(120)
        fixture.sleeper.releaseNext()
        await waitForBudgetCondition { fixture.sleeper.durations.count == 2 }

        XCTAssertEqual(fixture.provider.log, ["budget", "fetch", "budget", "fetch", "budget"])
        XCTAssertEqual(refreshingValues, [])
        XCTAssertEqual(fixture.controller.refreshErrorMessage, errorMessage)
        XCTAssertEqual(fixture.controller.state.syncedAt, syncedAt)
        XCTAssertEqual(fixture.sleeper.durations.last, 2_885)
    }

    @MainActor
    func testLongerStretchedIntervalAtWakeSleepsOnlyTheRemainder() async throws {
        let fixture = makeFixture(baseline: 3_400, fetched: 3_455)
        await waitForLaunch(fixture)
        fixture.provider.budgetRead = { budgetReading(used: 3_455, at: fixture.clock.now, resetIn: 2_880) }

        fixture.clock.now = Self.start.addingTimeInterval(120)
        fixture.sleeper.releaseNext()
        await waitForBudgetCondition { fixture.sleeper.durations.count == 2 }

        // 9 refreshes over the 2,880 s left is one every 6 min, measured from the loop's start.
        XCTAssertEqual(fixture.provider.fetchCount, 1)
        XCTAssertEqual(fixture.sleeper.durations.last, 240)
    }

    @MainActor
    func testActiveDeferralAtWakeSendsNoBudgetRead() async throws {
        let retryAt = Self.start.addingTimeInterval(600)
        let fixture = makeFixture(baseline: 800, fetched: 855)
        await waitForLaunch(fixture)
        fixture.provider.budgetRead = { throw GitHubReadError.rateLimited(retryAt: retryAt) }
        fixture.controller.refresh()
        await waitForBudgetCondition { fixture.controller.rateLimitRetryAt != nil && !fixture.controller.isRefreshing }
        let reads = fixture.provider.budgetReadCount

        fixture.clock.now = Self.start.addingTimeInterval(120)
        fixture.sleeper.releaseNext()
        await waitForBudgetCondition { fixture.sleeper.durations.count == 2 }

        XCTAssertEqual(fixture.provider.budgetReadCount, reads)
        XCTAssertEqual(fixture.sleeper.durations.last, 480)
    }

    @MainActor
    func testServerErrorFromTheAutomaticBudgetReadRefreshesOnTheLatestReadingWithoutASample() async throws {
        let fixture = makeFixture(baseline: 800, fetched: 855)
        await waitForLaunch(fixture)
        fixture.provider.budgetRead = { throw GitHubReadError.http(status: 500) }
        fixture.provider.fetchReading = budgetReading(used: 910, at: Self.start)

        fixture.clock.now = Self.start.addingTimeInterval(120)
        fixture.sleeper.releaseNext()
        await waitForBudgetCondition { fixture.provider.fetchCount == 2 && !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.provider.log, ["budget", "fetch", "budget", "fetch"])
        XCTAssertTrue(fixture.controller.budgetState.lastReadFailed)
        XCTAssertEqual(fixture.controller.budgetState.costSamples, [55])
        XCTAssertEqual(fixture.controller.budgetState.reading?.used, 910)
    }

    @MainActor
    func testAuthenticationFailureFromTheAutomaticBudgetReadSignsOut() async throws {
        let fixture = makeFixture(baseline: 800, fetched: 855)
        await waitForLaunch(fixture)
        fixture.provider.budgetRead = { throw GitHubReadError.authentication }

        fixture.clock.now = Self.start.addingTimeInterval(120)
        fixture.sleeper.releaseNext()
        await waitForBudgetCondition { fixture.controller.errorMessage != nil }

        XCTAssertEqual(fixture.controller.errorMessage, GitHubReadError.authentication.localizedDescription)
        XCTAssertEqual(fixture.provider.fetchCount, 1)
        XCTAssertEqual(fixture.controller.budgetState, GitHubBudgetState())
    }

    @MainActor
    func testRateLimitedAutomaticBudgetReadSetsTheDeferralAndTheErrorMessage() async throws {
        let retryAt = Self.start.addingTimeInterval(900)
        let fixture = makeFixture(baseline: 800, fetched: 855)
        await waitForLaunch(fixture)
        fixture.provider.budgetRead = { throw GitHubReadError.rateLimited(retryAt: retryAt) }

        fixture.clock.now = Self.start.addingTimeInterval(120)
        fixture.sleeper.releaseNext()
        await waitForBudgetCondition { fixture.controller.refreshErrorMessage != nil }

        XCTAssertEqual(
            fixture.controller.refreshErrorMessage,
            GitHubReadError.rateLimited(retryAt: retryAt).localizedDescription
        )
        XCTAssertEqual(fixture.controller.rateLimitRetryAt, retryAt)
        XCTAssertEqual(fixture.controller.automaticRefreshDeferral?.retryAt, retryAt)
        XCTAssertEqual(fixture.provider.fetchCount, 1)
        await waitForBudgetCondition { fixture.sleeper.durations.count == 2 }
        XCTAssertEqual(fixture.sleeper.durations.last, 780)
    }

    @MainActor
    func testAccountSwitchDuringTheAutomaticBudgetReadRecordsNoReading() async throws {
        let bob = BudgetGitHubProvider(login: "bob") { budgetReading(used: 2_000, at: Self.start) }
        let fixture = makeFixture(baseline: 800, fetched: 855, providers: ["bob": bob])
        await waitForLaunch(fixture)
        fixture.provider.holdsBudgetReads = true
        fixture.provider.budgetRead = { budgetReading(used: 2_500, at: Self.start) }

        fixture.clock.now = Self.start.addingTimeInterval(120)
        fixture.sleeper.releaseNext()
        await waitForBudgetCondition { fixture.provider.heldBudgetReadCount == 1 }
        await fixture.controller.signInWithToken("bob")
        fixture.provider.releaseBudgetReads()
        await waitForBudgetCondition { fixture.sleeper.durations.count == 2 }

        XCTAssertEqual(fixture.controller.state.account?.login, "bob")
        XCTAssertEqual(fixture.controller.budgetState.reading?.used, 2_000)
        XCTAssertEqual(fixture.provider.fetchCount, 1)
    }

    @MainActor
    func testAccountSwitchDuringAFailingAutomaticBudgetReadDoesNotSignOut() async throws {
        let bob = BudgetGitHubProvider(login: "bob") { budgetReading(used: 2_000, at: Self.start) }
        let fixture = makeFixture(baseline: 800, fetched: 855, providers: ["bob": bob])
        await waitForLaunch(fixture)
        fixture.provider.holdsBudgetReads = true
        fixture.provider.budgetRead = { throw GitHubReadError.authentication }

        fixture.clock.now = Self.start.addingTimeInterval(120)
        fixture.sleeper.releaseNext()
        await waitForBudgetCondition { fixture.provider.heldBudgetReadCount == 1 }
        await fixture.controller.signInWithToken("bob")
        fixture.provider.releaseBudgetReads()
        await waitForBudgetCondition { fixture.sleeper.durations.count == 2 }

        XCTAssertNil(fixture.controller.errorMessage)
        XCTAssertEqual(fixture.controller.state.account?.login, "bob")
        XCTAssertEqual(fixture.controller.state.authStatus, .signedIn)
    }

    @MainActor
    func testChangingTheRefreshIntervalCancelsTheOldSleepAndRecomputes() async throws {
        let fixture = makeFixture(budgetRead: { nil })
        await waitForBudgetCondition { fixture.sleeper.waitingCount == 1 }

        fixture.controller.refreshIntervalMinutes = 5

        await waitForBudgetCondition { fixture.sleeper.durations.count == 2 && fixture.sleeper.waitingCount == 1 }
        XCTAssertEqual(fixture.sleeper.durations, [120, 300])
        XCTAssertEqual(fixture.sleeper.cancelledCount, 1)
    }

    @MainActor
    func testManualRefreshDuringTheAutomaticBudgetReadSendsItsRefreshQueries() async throws {
        let fixture = makeFixture(baseline: 800, fetched: 855)
        await waitForLaunch(fixture)
        fixture.provider.holdsBudgetReads = true

        fixture.clock.now = Self.start.addingTimeInterval(120)
        fixture.sleeper.releaseNext()
        await waitForBudgetCondition { fixture.provider.heldBudgetReadCount == 1 }
        XCTAssertFalse(fixture.controller.isRefreshing)
        fixture.controller.refresh()
        await waitForBudgetCondition { fixture.provider.heldBudgetReadCount == 2 }
        XCTAssertTrue(fixture.controller.isRefreshing)
        fixture.provider.holdsBudgetReads = false
        fixture.provider.releaseBudgetReads()

        await waitForBudgetCondition {
            fixture.provider.fetchCount == 2 && !fixture.controller.isRefreshing && fixture.sleeper.waitingCount == 1
        }
        XCTAssertEqual(fixture.provider.log, ["budget", "fetch", "budget", "budget", "fetch"])
    }

    // MARK: - Fixtures

    private struct Fixture {
        let controller: DashboardController
        let provider: BudgetGitHubProvider
        let clock: ControllerTestClock
        let sleeper: SuspendingTestSleep
    }

    /// A signed-in controller with the default 2 min interval. Its launch refresh reads `baseline` and its
    /// complete fetch reports `fetched`, both with the reset `resetIn` seconds after the start.
    @MainActor
    private func makeFixture(
        baseline: Int,
        fetched: Int,
        resetIn: TimeInterval = 3_000,
        providers: [String: BudgetGitHubProvider] = [:]
    ) -> Fixture {
        let fixture = makeFixture(
            budgetRead: { budgetReading(used: baseline, at: Self.start, resetIn: resetIn) },
            providers: providers
        )
        fixture.provider.fetchReading = budgetReading(used: fetched, at: Self.start, resetIn: resetIn)
        return fixture
    }

    @MainActor
    private func makeFixture(
        budgetRead: @escaping () throws -> GitHubBudgetReading?,
        providers: [String: BudgetGitHubProvider] = [:]
    ) -> Fixture {
        let clock = ControllerTestClock(Self.start)
        let sleeper = SuspendingTestSleep()
        let provider = BudgetGitHubProvider(budgetRead: budgetRead)
        let controller = makeBudgetController(
            self,
            provider: provider,
            providers: providers,
            clock: clock,
            automaticRefreshInterval: nil,
            sleep: { try await sleeper.sleep($0) }
        )
        return Fixture(controller: controller, provider: provider, clock: clock, sleeper: sleeper)
    }

    @MainActor
    private func waitForLaunch(_ fixture: Fixture) async {
        await waitForBudgetCondition {
            fixture.provider.fetchCount == 1 && !fixture.controller.isRefreshing && fixture.sleeper.waitingCount == 1
        }
    }
}
