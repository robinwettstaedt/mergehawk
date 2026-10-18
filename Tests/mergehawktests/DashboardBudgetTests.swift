@testable import mergehawk
@testable import mergehawkcore
import Foundation
import XCTest

/// A GitHub source with a scripted budget. Also used by the automatic pacing tests.
final class BudgetGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    let login: String
    /// "budget" for each budget read and "fetch" for each complete PR refresh, in call order.
    private(set) var log: [String] = []
    /// Answers each budget read.
    var budgetRead: () throws -> GitHubBudgetReading?
    /// Each complete PR refresh's reading. It also becomes the latest reading, even when the refresh fails.
    var fetchReading: GitHubBudgetReading?
    var fetchFailure: Error?
    /// The budget headers a failing budget read's response carries. They become the latest reading before it throws.
    var failedBudgetReadReading: GitHubBudgetReading?
    var holdsFetches = false
    var holdsBudgetReads = false
    private var latest: GitHubBudgetReading?
    private var heldFetch: CheckedContinuation<Void, Never>?
    private var heldBudgetReads: [CheckedContinuation<Void, Never>] = []

    init(login: String = "rw", budgetRead: @escaping () throws -> GitHubBudgetReading? = { nil }) {
        self.login = login
        self.budgetRead = budgetRead
    }

    var fetchCount: Int { log.filter { $0 == "fetch" }.count }
    var budgetReadCount: Int { log.filter { $0 == "budget" }.count }
    var heldBudgetReadCount: Int { heldBudgetReads.count }
    var isFetchHeld: Bool { heldFetch != nil }

    /// Resumes every held budget read, in call order.
    func releaseBudgetReads() {
        let held = heldBudgetReads
        heldBudgetReads = []
        held.forEach { $0.resume() }
    }

    func releaseFetch() {
        heldFetch?.resume()
        heldFetch = nil
    }

    func fetchViewer() async throws -> GitHubAccount { GitHubAccount(login: login) }

    func fetchBudgetReading() async throws -> GitHubBudgetReading? {
        log.append("budget")
        if holdsBudgetReads {
            await withCheckedContinuation { heldBudgetReads.append($0) }
        }
        let reading: GitHubBudgetReading?
        do {
            reading = try budgetRead()
        } catch {
            if let failed = failedBudgetReadReading { latest = latest?.merged(with: failed) ?? failed }
            throw error
        }
        if let reading { latest = latest?.merged(with: reading) ?? reading }
        return reading
    }

    func latestBudgetReading() -> GitHubBudgetReading? { latest }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?,
        reusableViewerTeams: [ViewerTeam]?
    ) async throws -> CompletePullRequestFetchResult {
        log.append("fetch")
        if holdsFetches {
            await withCheckedContinuation { heldFetch = $0 }
        }
        if let fetchReading { latest = latest?.merged(with: fetchReading) ?? fetchReading }
        if let fetchFailure { throw fetchFailure }
        return CompletePullRequestFetchResult(activePullRequests: [], budgetReading: fetchReading)
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: accountLogin)
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }
}

/// Builds a PAT-signed-in controller on `provider`. Removes its defaults when the test ends.
@MainActor
func makeBudgetController(
    _ testCase: XCTestCase,
    provider: BudgetGitHubProvider,
    providers: [String: BudgetGitHubProvider] = [:],
    clock: ControllerTestClock,
    token: String? = "pat",
    automaticRefreshInterval: TimeInterval? = 0,
    sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
) -> DashboardController {
    let suiteName = "budget-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    testCase.addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    var preferences = PreferencesStore(defaults: defaults)
    preferences.authMethod = .pat
    return DashboardController(
        tokenStore: InMemoryTokenStore(token: token),
        preferencesStore: preferences,
        launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
        notificationClient: RecordingNotificationClient(),
        automaticRefreshInterval: automaticRefreshInterval,
        patGitHubClientFactory: { providers[$0] ?? provider },
        now: { clock.now },
        sleep: sleep
    )
}

@MainActor
func waitForBudgetCondition(
    timeout: TimeInterval = 1,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
}

func budgetReading(
    used: Int,
    at now: Date,
    resetIn: TimeInterval = 3_000,
    limit: Int = 5_000
) -> GitHubBudgetReading {
    GitHubBudgetReading(
        limit: limit,
        remaining: limit - used,
        used: used,
        resetAt: now.addingTimeInterval(resetIn),
        receivedAt: now
    )
}

final class DashboardBudgetTests: XCTestCase {
    fileprivate static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testManualRefreshSendsTheBudgetReadBeforeTheFirstRefreshQuery() async throws {
        let recorder = BudgetOrderRecorder()
        BudgetOrderURLProtocol.handler = { request in try recorder.response(for: request) }
        defer { BudgetOrderURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BudgetOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suiteName = "budget-order-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        let start = Self.start
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            notificationClient: RecordingNotificationClient(),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { GitHubClient(token: $0, session: session, now: { start }) },
            now: { start }
        )
        await waitForBudgetCondition { controller.state.syncedAt != nil && !controller.isRefreshing }
        let launchQueries = recorder.queries
        XCTAssertEqual(launchQueries.first, GitHubClient.budgetReadQuery)
        XCTAssertGreaterThan(launchQueries.count, 1)
        XCTAssertNotEqual(launchQueries[1], GitHubClient.budgetReadQuery)

        controller.refresh()
        await waitForBudgetCondition { recorder.queries.count > launchQueries.count && !controller.isRefreshing }

        let manualQueries = Array(recorder.queries.dropFirst(launchQueries.count))
        XCTAssertEqual(manualQueries.first, GitHubClient.budgetReadQuery)
        XCTAssertEqual(manualQueries.filter { $0 == GitHubClient.budgetReadQuery }.count, 1)
        XCTAssertEqual(controller.budgetState.reading?.used, 100)
    }

    @MainActor
    func testSuccessfulRefreshRecordsTheLatestReadingAndOneSample() async throws {
        let clock = ControllerTestClock(Self.start)
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: Self.start) }
        provider.fetchReading = budgetReading(used: 855, at: Self.start)
        let controller = makeBudgetController(self, provider: provider, clock: clock)

        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }

        XCTAssertEqual(provider.log, ["budget", "fetch"])
        XCTAssertEqual(controller.budgetState.reading, budgetReading(used: 855, at: Self.start))
        XCTAssertEqual(controller.budgetState.costSamples, [55])
        XCTAssertFalse(controller.budgetState.lastReadFailed)
    }

    @MainActor
    func testStrayAnswerIsReadAgainAndTheFreshMainReadingIsTheBaseline() async throws {
        let fixture = await makeStrayCounterFixture()
        let provider = fixture.provider, controller = fixture.controller, clock = fixture.clock
        // Two minutes later other tools have spent 30 points. GitHub answers the first read from the stray counter.
        clock.now = Self.start.addingTimeInterval(120)
        var answers = [fixture.stray(2), fixture.main(885)]
        provider.budgetRead = { answers.removeFirst() }
        provider.fetchReading = fixture.main(940)

        controller.refresh()
        await waitForBudgetCondition { provider.fetchCount == 2 && !controller.isRefreshing }

        XCTAssertEqual(provider.log, ["budget", "fetch", "budget", "budget", "fetch"])
        // The sample is MergeHawk's own 55 points, not the 85 since the previous refresh's reading.
        XCTAssertEqual(controller.budgetState.costSamples, [55, 55])
        XCTAssertEqual(controller.budgetState.reading, fixture.main(940))
    }

    @MainActor
    func testThreeStrayAnswersRecordNothingAndTakeNoSample() async throws {
        let fixture = await makeStrayCounterFixture()
        let provider = fixture.provider, controller = fixture.controller, clock = fixture.clock
        clock.now = Self.start.addingTimeInterval(120)
        provider.budgetRead = { fixture.stray(2) }
        provider.fetchReading = fixture.main(940)
        provider.holdsFetches = true

        controller.refresh()
        await waitForBudgetCondition { provider.isFetchHeld }
        XCTAssertEqual(provider.log, ["budget", "fetch", "budget", "budget", "budget", "fetch"])
        XCTAssertEqual(controller.budgetState.reading?.used, 855)
        XCTAssertEqual(controller.budgetState.reading?.receivedAt, Self.start)
        XCTAssertFalse(controller.budgetState.lastReadFailed)

        provider.releaseFetch()
        await waitForBudgetCondition { !controller.isRefreshing }
        XCTAssertEqual(controller.budgetState.costSamples, [55])
        XCTAssertEqual(controller.budgetState.reading, fixture.main(940))
    }

    @MainActor
    func testBudgetReadoutReadsAgainAfterAStrayAnswerAndSleepsToTheMainReset() async throws {
        let sleeper = SuspendingTestSleep()
        let fixture = await makeStrayCounterFixture(sleep: { try await sleeper.sleep($0) })
        let provider = fixture.provider, controller = fixture.controller, clock = fixture.clock
        clock.now = Self.start.addingTimeInterval(120)
        var answers = [fixture.stray(2), fixture.main(885)]
        provider.budgetRead = { answers.removeFirst() }

        let readout = Task { await controller.runBudgetReadout() }
        defer { readout.cancel() }
        await waitForBudgetCondition { sleeper.waitingCount == 1 }

        XCTAssertEqual(provider.log, ["budget", "fetch", "budget", "budget"])
        XCTAssertEqual(controller.budgetState.reading, fixture.main(885))
        XCTAssertEqual(sleeper.durations, [2_885])
    }

    @MainActor
    func testBudgetReadoutWithThreeStrayAnswersRecordsNothingAndSleepsToTheMainReset() async throws {
        let sleeper = SuspendingTestSleep()
        let fixture = await makeStrayCounterFixture(sleep: { try await sleeper.sleep($0) })
        let provider = fixture.provider, controller = fixture.controller, clock = fixture.clock
        clock.now = Self.start.addingTimeInterval(120)
        provider.budgetRead = { fixture.stray(2) }

        let readout = Task { await controller.runBudgetReadout() }
        defer { readout.cancel() }
        await waitForBudgetCondition { sleeper.waitingCount == 1 }

        XCTAssertEqual(provider.log, ["budget", "fetch", "budget", "budget", "budget"])
        XCTAssertEqual(controller.budgetState.reading?.used, 855)
        XCTAssertEqual(controller.budgetState.reading?.receivedAt, Self.start)
        XCTAssertFalse(controller.budgetState.lastReadFailed)
        XCTAssertEqual(sleeper.durations, [2_885])
    }

    struct StrayCounterFixture {
        let controller: DashboardController
        let provider: BudgetGitHubProvider
        let clock: ControllerTestClock

        /// The main counter, which resets 3,000 s after the start, read at the clock's time.
        func main(_ used: Int) -> GitHubBudgetReading {
            GitHubBudgetReading(
                limit: 5_000, remaining: 5_000 - used, used: used,
                resetAt: DashboardBudgetTests.start.addingTimeInterval(3_000), receivedAt: clock.now
            )
        }

        /// The stray counter, with a later reset and almost nothing used.
        func stray(_ used: Int) -> GitHubBudgetReading {
            GitHubBudgetReading(
                limit: 5_000, remaining: 5_000 - used, used: used,
                resetAt: DashboardBudgetTests.start.addingTimeInterval(3_600), receivedAt: clock.now
            )
        }
    }

    /// A controller whose launch refresh read 800 on the main counter and spent 55.
    @MainActor
    private func makeStrayCounterFixture(
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async -> StrayCounterFixture {
        let clock = ControllerTestClock(Self.start)
        let provider = BudgetGitHubProvider()
        let controller = makeBudgetController(self, provider: provider, clock: clock, sleep: sleep)
        let fixture = StrayCounterFixture(controller: controller, provider: provider, clock: clock)
        provider.budgetRead = { fixture.main(800) }
        provider.fetchReading = fixture.main(855)
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }
        XCTAssertEqual(controller.budgetState.costSamples, [55])
        return fixture
    }

    @MainActor
    func testFailedRefreshRecordsTheErrorResponsesReadingWithoutASample() async throws {
        let clock = ControllerTestClock(Self.start)
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: Self.start) }
        provider.fetchReading = budgetReading(used: 830, at: Self.start)
        provider.fetchFailure = GitHubReadError.http(status: 502)
        let controller = makeBudgetController(self, provider: provider, clock: clock)

        await waitForBudgetCondition { controller.refreshErrorMessage != nil }

        XCTAssertEqual(controller.budgetState.reading?.used, 830)
        XCTAssertEqual(controller.budgetState.costSamples, [])
    }

    @MainActor
    func testServerErrorFromTheBudgetReadStillRunsTheManualRefreshWithoutASample() async throws {
        let clock = ControllerTestClock(Self.start)
        let provider = BudgetGitHubProvider { throw GitHubReadError.http(status: 500) }
        provider.fetchReading = budgetReading(used: 855, at: Self.start)
        let controller = makeBudgetController(self, provider: provider, clock: clock)
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }

        controller.refresh()
        await waitForBudgetCondition { provider.fetchCount == 2 && !controller.isRefreshing }

        XCTAssertEqual(provider.log, ["budget", "fetch", "budget", "fetch"])
        XCTAssertTrue(controller.budgetState.lastReadFailed)
        XCTAssertEqual(controller.budgetState.costSamples, [])
        XCTAssertEqual(controller.budgetState.reading?.used, 855)
        XCTAssertNil(controller.refreshErrorMessage)
    }

    @MainActor
    func testServerErrorFromTheBudgetReadKeepsTheHeadersItCarried() async throws {
        let clock = ControllerTestClock(Self.start)
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: Self.start) }
        provider.holdsFetches = true
        let controller = makeBudgetController(self, provider: provider, clock: clock)
        await waitForBudgetCondition { provider.isFetchHeld }
        provider.releaseFetch()
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }
        provider.budgetRead = { throw GitHubReadError.http(status: 502) }
        provider.failedBudgetReadReading = budgetReading(used: 1_400, at: Self.start)

        controller.refresh()
        // The read failure is recorded before the refresh query, so check while that query is held.
        await waitForBudgetCondition { provider.isFetchHeld }

        XCTAssertTrue(controller.budgetState.lastReadFailed)
        XCTAssertEqual(controller.budgetState.reading?.used, 1_400)
        XCTAssertEqual(provider.log, ["budget", "fetch", "budget", "fetch"])
        provider.releaseFetch()
        await waitForBudgetCondition { !controller.isRefreshing }
        XCTAssertEqual(controller.budgetState.costSamples, [])
    }

    @MainActor
    func testBudgetReadoutFailureKeepsTheHeadersItCarried() async throws {
        let clock = ControllerTestClock(Self.start)
        let sleeper = SuspendingTestSleep()
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: clock.now) }
        let controller = makeBudgetController(self, provider: provider, clock: clock, sleep: { try await sleeper.sleep($0) })
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }
        provider.budgetRead = { throw GitHubReadError.http(status: 503) }
        provider.failedBudgetReadReading = budgetReading(used: 1_400, at: Self.start)

        await controller.runBudgetReadout()

        XCTAssertTrue(controller.budgetState.lastReadFailed)
        XCTAssertEqual(controller.budgetState.reading?.used, 1_400)
        XCTAssertEqual(sleeper.durations, [])
    }

    @MainActor
    func testAuthenticationFailureFromTheBudgetReadSignsOutWithoutARefreshQuery() async throws {
        let clock = ControllerTestClock(Self.start)
        let provider = BudgetGitHubProvider { throw GitHubReadError.authentication }
        let controller = makeBudgetController(self, provider: provider, clock: clock)

        await waitForBudgetCondition { controller.errorMessage != nil }

        XCTAssertEqual(provider.log, ["budget"])
        XCTAssertEqual(controller.errorMessage, GitHubReadError.authentication.localizedDescription)
        XCTAssertEqual(controller.state.authStatus, .signedOut)
        XCTAssertEqual(controller.budgetState, GitHubBudgetState())
    }

    @MainActor
    func testRateLimitedBudgetReadSetsTheErrorWithoutARefreshQuery() async throws {
        let clock = ControllerTestClock(Self.start)
        let retryAt = Self.start.addingTimeInterval(600)
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: Self.start) }
        let controller = makeBudgetController(self, provider: provider, clock: clock)
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }
        provider.budgetRead = { throw GitHubReadError.rateLimited(retryAt: retryAt) }

        controller.refresh()
        await waitForBudgetCondition { controller.refreshErrorMessage != nil && !controller.isRefreshing }

        XCTAssertEqual(provider.log, ["budget", "fetch", "budget"])
        XCTAssertEqual(controller.refreshErrorMessage, GitHubReadError.rateLimited(retryAt: retryAt).localizedDescription)
        XCTAssertEqual(controller.rateLimitRetryAt, retryAt)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testAccountSwitchMidRefreshDiscardsThatRefreshsReadingAndSample() async throws {
        let clock = ControllerTestClock(Self.start)
        let first = BudgetGitHubProvider { budgetReading(used: 800, at: Self.start) }
        first.fetchReading = budgetReading(used: 855, at: Self.start)
        first.holdsFetches = true
        let second = BudgetGitHubProvider(login: "bob") { budgetReading(used: 2_000, at: Self.start) }
        let controller = makeBudgetController(self, provider: first, providers: ["bob": second], clock: clock)
        await waitForBudgetCondition { first.isFetchHeld }
        XCTAssertEqual(controller.budgetState.reading?.used, 800)

        await controller.signInWithToken("bob")
        first.releaseFetch()
        await waitForBudgetCondition { !first.isFetchHeld && !controller.isRefreshing }
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(controller.state.account?.login, "bob")
        XCTAssertEqual(controller.budgetState.reading?.used, 2_000)
        XCTAssertEqual(controller.budgetState.costSamples, [])
    }

    @MainActor
    func testBudgetReadoutReadsAtOnceThenAfterEachResetUntilCancelled() async throws {
        let clock = ControllerTestClock(Self.start)
        let sleeper = SuspendingTestSleep()
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: clock.now) }
        let controller = makeBudgetController(self, provider: provider, clock: clock, sleep: { try await sleeper.sleep($0) })
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }

        let readout = Task { await controller.runBudgetReadout() }
        await waitForBudgetCondition { sleeper.waitingCount == 1 }
        XCTAssertEqual(provider.budgetReadCount, 2)
        XCTAssertEqual(sleeper.durations, [3_005])

        // The next reading belongs to the next window, which resets an hour later.
        clock.now = Self.start.addingTimeInterval(3_005)
        provider.budgetRead = { budgetReading(used: 10, at: clock.now, resetIn: 3_595) }
        sleeper.releaseNext()
        await waitForBudgetCondition { sleeper.durations.count == 2 }
        XCTAssertEqual(provider.budgetReadCount, 3)
        XCTAssertEqual(controller.budgetState.reading?.used, 10)
        XCTAssertEqual(sleeper.durations.last, 3_600)

        readout.cancel()
        await readout.value
        XCTAssertEqual(provider.budgetReadCount, 3)
        XCTAssertEqual(sleeper.cancelledCount, 1)
    }

    @MainActor
    func testBudgetReadoutEndsAfterAFailedReadAndALaterReadClearsTheFlag() async throws {
        let clock = ControllerTestClock(Self.start)
        let sleeper = SuspendingTestSleep()
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: clock.now) }
        let controller = makeBudgetController(self, provider: provider, clock: clock, sleep: { try await sleeper.sleep($0) })
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }
        provider.budgetRead = { throw GitHubReadError.http(status: 503) }

        await controller.runBudgetReadout()
        XCTAssertTrue(controller.budgetState.lastReadFailed)
        XCTAssertNil(controller.refreshErrorMessage)
        XCTAssertEqual(provider.budgetReadCount, 2)
        XCTAssertEqual(sleeper.durations, [])

        provider.budgetRead = { budgetReading(used: 820, at: clock.now) }
        let readout = Task { await controller.runBudgetReadout() }
        defer { readout.cancel() }
        await waitForBudgetCondition { sleeper.waitingCount == 1 }
        XCTAssertFalse(controller.budgetState.lastReadFailed)
        XCTAssertEqual(controller.budgetState.reading?.used, 820)
    }

    @MainActor
    func testBudgetReadSnapshotFinishingAfterARefreshKeepsTheRefreshsHigherUsed() async throws {
        let clock = ControllerTestClock(Self.start)
        let sleeper = SuspendingTestSleep()
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: Self.start) }
        provider.fetchReading = budgetReading(used: 855, at: Self.start)
        let controller = makeBudgetController(self, provider: provider, clock: clock, sleep: { try await sleeper.sleep($0) })
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }
        XCTAssertEqual(controller.budgetState.reading?.used, 855)
        // GitHub answered this read before the refresh's last query, but it finishes after the refresh.
        provider.budgetRead = { budgetReading(used: 830, at: Self.start) }

        let readout = Task { await controller.runBudgetReadout() }
        defer { readout.cancel() }
        await waitForBudgetCondition { sleeper.waitingCount == 1 }

        XCTAssertEqual(provider.budgetReadCount, 2)
        XCTAssertEqual(controller.budgetState.reading?.used, 855)
    }

    @MainActor
    func testFailedFirstReadoutReadWithoutAReadingSendsOneReadAndEnds() async throws {
        let clock = ControllerTestClock(Self.start)
        let sleeper = SuspendingTestSleep()
        let provider = BudgetGitHubProvider { throw GitHubReadError.http(status: 500) }
        let controller = makeBudgetController(self, provider: provider, clock: clock, sleep: { try await sleeper.sleep($0) })
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }
        XCTAssertNil(controller.budgetState.reading)

        await controller.runBudgetReadout()

        XCTAssertEqual(provider.log, ["budget", "fetch", "budget"])
        XCTAssertEqual(sleeper.durations, [])
    }

    @MainActor
    func testBudgetReadoutEndsWhenAReadAfterTheResetStillReturnsTheOldReset() async throws {
        let clock = ControllerTestClock(Self.start)
        let sleeper = SuspendingTestSleep()
        let reset = Self.start.addingTimeInterval(3_000)
        let provider = BudgetGitHubProvider {
            GitHubBudgetReading(limit: 5_000, remaining: 4_200, used: 800, resetAt: reset, receivedAt: clock.now)
        }
        let controller = makeBudgetController(self, provider: provider, clock: clock, sleep: { try await sleeper.sleep($0) })
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }

        let readout = Task { await controller.runBudgetReadout() }
        await waitForBudgetCondition { sleeper.waitingCount == 1 }
        // GitHub has not reset 5 s after the Mac's clock passed the reset.
        clock.now = reset.addingTimeInterval(5)
        sleeper.releaseNext()
        await readout.value

        XCTAssertEqual(provider.budgetReadCount, 3)
        XCTAssertEqual(sleeper.durations, [3_005])
        XCTAssertEqual(controller.budgetState.reading?.receivedAt, reset.addingTimeInterval(5))
    }

    @MainActor
    func testBudgetReadoutStartingJustAfterAResetReadsAgainAfterTheResetMargin() async throws {
        let clock = ControllerTestClock(Self.start)
        let sleeper = SuspendingTestSleep()
        let reset = Self.start.addingTimeInterval(3_000)
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: clock.now) }
        let controller = makeBudgetController(self, provider: provider, clock: clock, sleep: { try await sleeper.sleep($0) })
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }
        // Settings opens 2 s after the reset, and GitHub already answers from the next window.
        clock.now = reset.addingTimeInterval(2)
        provider.budgetRead = {
            GitHubBudgetReading(
                limit: 5_000, remaining: 4_990, used: 10,
                resetAt: reset.addingTimeInterval(3_600), receivedAt: clock.now
            )
        }

        let readout = Task { await controller.runBudgetReadout() }
        await waitForBudgetCondition { sleeper.waitingCount == 1 }
        // Within the reset margin the new window's answers are stray, so the old reading stays.
        XCTAssertEqual(provider.budgetReadCount, 4)
        XCTAssertEqual(controller.budgetState.reading?.used, 800)
        XCTAssertEqual(sleeper.durations, [3])

        clock.now = reset.addingTimeInterval(5)
        sleeper.releaseNext()
        await waitForBudgetCondition { sleeper.durations.count == 2 }
        XCTAssertEqual(provider.budgetReadCount, 5)
        XCTAssertEqual(controller.budgetState.reading?.used, 10)
        XCTAssertEqual(controller.budgetState.reading?.resetAt, reset.addingTimeInterval(3_600))
        XCTAssertEqual(sleeper.durations.last, 3_600)

        readout.cancel()
        await readout.value
    }

    @MainActor
    func testRateLimitedReadoutReadSetsTheDeferralButNotTheRefreshError() async throws {
        let clock = ControllerTestClock(Self.start)
        let sleeper = SuspendingTestSleep()
        let retryAt = Self.start.addingTimeInterval(600)
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: Self.start) }
        let controller = makeBudgetController(self, provider: provider, clock: clock, sleep: { try await sleeper.sleep($0) })
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }
        provider.budgetRead = { throw GitHubReadError.rateLimited(retryAt: retryAt) }
        provider.failedBudgetReadReading = budgetReading(used: 5_000, at: Self.start)

        await controller.runBudgetReadout()

        XCTAssertNil(controller.refreshErrorMessage)
        XCTAssertEqual(controller.rateLimitRetryAt, retryAt)
        XCTAssertEqual(controller.budgetState.reading?.remaining, 0)
        XCTAssertEqual(sleeper.durations, [])
    }

    @MainActor
    func testBudgetReadoutSendsNoReadDuringARateLimitDeferral() async throws {
        let clock = ControllerTestClock(Self.start)
        let sleeper = SuspendingTestSleep()
        let retryAt = Self.start.addingTimeInterval(600)
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: Self.start) }
        let controller = makeBudgetController(self, provider: provider, clock: clock, sleep: { try await sleeper.sleep($0) })
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }
        provider.budgetRead = { throw GitHubReadError.rateLimited(retryAt: retryAt) }
        controller.refresh()
        await waitForBudgetCondition { controller.rateLimitRetryAt != nil && !controller.isRefreshing }
        let reads = provider.budgetReadCount

        let readout = Task { await controller.runBudgetReadout() }
        await waitForBudgetCondition { sleeper.waitingCount == 1 }
        readout.cancel()
        await readout.value

        XCTAssertEqual(provider.budgetReadCount, reads)
        XCTAssertEqual(sleeper.durations, [3_005])
    }

    @MainActor
    func testBudgetReadoutSendsNoReadWhenSignedOut() async throws {
        let clock = ControllerTestClock(Self.start)
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: Self.start) }
        let controller = makeBudgetController(self, provider: provider, clock: clock, token: nil)

        await controller.runBudgetReadout()

        XCTAssertEqual(provider.log, [])
        XCTAssertEqual(controller.budgetState, GitHubBudgetState())
    }

    @MainActor
    func testSignedOutRefreshLeavesTheBudgetStateEmpty() async throws {
        let clock = ControllerTestClock(Self.start)
        let provider = BudgetGitHubProvider { budgetReading(used: 800, at: Self.start) }
        let controller = makeBudgetController(self, provider: provider, clock: clock, token: nil)

        controller.refresh()
        await waitForBudgetCondition { controller.state.syncedAt != nil && !controller.isRefreshing }

        XCTAssertEqual(controller.state.authStatus, .signedOut)
        XCTAssertEqual(provider.log, [])
        XCTAssertEqual(controller.budgetState, GitHubBudgetState())
    }
}

/// Serves a PAT refresh with an empty discovery and records every GraphQL query in order.
private final class BudgetOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let reset = Int(Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(3_600).timeIntervalSince1970)

    var queries: [String] { lock.withLock { recorded } }

    func response(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        switch request.url?.path {
        case "/user": return respond(["login": "rw"], request)
        case "/user/repos": return respond([Any](), request)
        case "/graphql": break
        default: return respond(["message": "unexpected"], request, status: 404)
        }
        let query = Self.graphQLQuery(request)
        lock.withLock { recorded.append(query) }
        let headers = [
            "X-RateLimit-Limit": "5000",
            "X-RateLimit-Remaining": "4900",
            "X-RateLimit-Used": "100",
            "X-RateLimit-Reset": "\(reset)"
        ]
        if query == GitHubClient.budgetReadQuery {
            return respond(["data": ["rateLimit": ["limit": 5_000]]], request, headers: headers)
        }
        if query.contains("query ViewerTeams") {
            return respond(["data": ["viewer": ["organizations": [
                "pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": []
            ]]]], request, headers: headers)
        }
        var data: [String: Any] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            if query.contains("DiscoveryBounds") {
                data["\(lane.rawValue)Oldest"] = ["nodes": []]
                data["\(lane.rawValue)Newest"] = ["nodes": []]
            } else {
                data[lane.rawValue] = [
                    "issueCount": 0, "nodes": [],
                    "pageInfo": [
                        "startCursor": NSNull(), "endCursor": NSNull(), "hasPreviousPage": false, "hasNextPage": false
                    ]
                ]
            }
        }
        return respond(["data": data], request, headers: headers)
    }

    private func respond(
        _ object: Any,
        _ request: URLRequest,
        status: Int = 200,
        headers: [String: String]? = nil
    ) -> (Data, HTTPURLResponse) {
        (
            try! JSONSerialization.data(withJSONObject: object),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        )
    }

    private static func graphQLQuery(_ request: URLRequest) -> String {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            body = data
        }
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        return object["query"] as? String ?? ""
    }
}

private final class BudgetOrderURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let result = try Self.handler?(request) else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: result.1, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.0)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
