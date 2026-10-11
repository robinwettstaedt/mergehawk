@testable import mergehawk
@testable import mergehawkcore
import Foundation
import XCTest

final class MockBudgetTests: XCTestCase {
    private static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    private static let reset = referenceDate.addingTimeInterval(50 * 60)

    func testBudgetScenariosParseFromMockArguments() {
        XCTAssertEqual(MockPullRequestScenario(rawValue: "budget-stretched"), .budgetStretched)
        XCTAssertEqual(MockPullRequestScenario(rawValue: "budget-paused"), .budgetPaused)
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk", "--mock", "--mock-scenario", "budget-paused"],
                environment: [:]
            ).mockPullRequestScenario,
            .budgetPaused
        )
    }

    func testEachScenarioFirstReadHasItsStartingNumbers() async throws {
        let expectations: [(MockPullRequestScenario, Int)] = [
            (.standard, 800), (.longLists, 800), (.budgetStretched, 3_400), (.budgetPaused, 3_950)
        ]
        for (scenario, used) in expectations {
            let reading = try await Self.source(scenario).fetchBudgetReading()
            XCTAssertEqual(
                reading,
                GitHubBudgetReading(
                    limit: 5_000,
                    remaining: 5_000 - used,
                    used: used,
                    resetAt: Self.reset,
                    receivedAt: Self.referenceDate
                ),
                scenario.rawValue
            )
        }
    }

    func testCompleteFetchSpendsFiftyFivePointsAndGivesOneSample() async throws {
        let source = Self.source(.standard)
        let baseline = try await source.fetchBudgetReading()

        let result = try await Self.fetch(source)

        XCTAssertEqual(result.budgetReading?.used, 855)
        XCTAssertEqual(source.latestBudgetReading()?.used, 855)
        var state = GitHubBudgetState()
        state.recordRead(baseline)
        state.recordCompleteRefresh(baseline: baseline, fetched: result.budgetReading)
        XCTAssertEqual(state.costSamples, [55])
    }

    func testWindowRollsOverAfterTheReset() async throws {
        var date = Self.referenceDate
        let source = MockPullRequestSource(referenceDate: Self.referenceDate, scenario: .budgetPaused, now: { date })
        _ = try await Self.fetch(source)
        XCTAssertEqual(source.latestBudgetReading()?.used, 4_005)

        date = Self.reset
        let rolled = try await source.fetchBudgetReading()

        XCTAssertEqual(rolled?.used, 3_950)
        XCTAssertEqual(rolled?.resetAt, Self.reset.addingTimeInterval(60 * 60))
        XCTAssertEqual(rolled?.receivedAt, Self.reset)
    }

    func testOneSampleDecidesNormalStretchedAndPausedForTheThreeFixtures() async throws {
        let twoMinutes: TimeInterval = 120
        var decisions: [MockPullRequestScenario: RefreshPacing] = [:]
        for scenario in [MockPullRequestScenario.standard, .budgetStretched, .budgetPaused] {
            let source = Self.source(scenario)
            var state = GitHubBudgetState()
            let baseline = try await source.fetchBudgetReading()
            state.recordRead(baseline)
            let result = try await Self.fetch(source)
            state.recordCompleteRefresh(baseline: baseline, fetched: result.budgetReading)
            state.recordLatest(source.latestBudgetReading())
            decisions[scenario] = RefreshPacingPolicy.decide(
                reading: state.reading,
                estimatedCost: state.estimatedCost,
                userInterval: twoMinutes,
                now: Self.referenceDate
            )
            if scenario == .budgetPaused {
                XCTAssertTrue(RefreshPacingPolicy.canAffordOneRefresh(
                    reading: state.reading,
                    estimatedCost: state.estimatedCost
                ))
            }
        }

        XCTAssertEqual(decisions[.standard], .normal)
        guard case .stretched(let interval, let until)? = decisions[.budgetStretched] else {
            return XCTFail("\(String(describing: decisions[.budgetStretched]))")
        }
        XCTAssertGreaterThan(interval, twoMinutes)
        XCTAssertEqual(until, Self.reset)
        XCTAssertEqual(decisions[.budgetPaused], .paused(until: Self.reset))
    }

    private static func source(_ scenario: MockPullRequestScenario) -> MockPullRequestSource {
        MockPullRequestSource(referenceDate: referenceDate, scenario: scenario, now: { referenceDate })
    }

    private static func fetch(_ source: MockPullRequestSource) async throws -> CompletePullRequestFetchResult {
        try await source.fetchCompletePullRequests(login: "agent-fixture", previousState: nil, reusableViewerTeams: nil)
    }
}
