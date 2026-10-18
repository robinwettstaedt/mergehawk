@testable import mergehawk
@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubBudgetPresentationTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let reset = now.addingTimeInterval(3_000)
    private static let twoMinutes: TimeInterval = 120

    func testNumbersLineUsesPlainDigitsWithoutGrouping() {
        let presentation = Self.presentation(remaining: 3_132)

        XCTAssertEqual(presentation.numbersLine, "3132 of 5000 left this hour")
        XCTAssertEqual(presentation.title, "GitHub API budget")
        XCTAssertEqual(presentation.fillFraction, 3_132.0 / 5_000.0, accuracy: 0.0001)
        XCTAssertEqual(presentation.reserveFraction, 0.2)
    }

    func testNumbersLineBeforeTheFirstReadingAndAfterAFailedRead() {
        let checking = Self.presentation(state: GitHubBudgetState())
        XCTAssertEqual(checking.numbersLine, "Checking budget")
        XCTAssertEqual(checking.fillFraction, 0)
        XCTAssertNil(checking.resetLine)

        var failed = GitHubBudgetState()
        failed.recordReadFailure()
        XCTAssertEqual(Self.presentation(state: failed).numbersLine, "Couldn't read the budget")

        // A failed read keeps showing the last usable reading.
        var failedWithReading = Self.state(remaining: 3_132)
        failedWithReading.recordReadFailure()
        XCTAssertEqual(
            Self.presentation(state: failedWithReading).numbersLine,
            "3132 of 5000 left this hour"
        )
    }

    func testNumbersLineAfterTheReadingGoesStaleShowsCheckingBudget() {
        let presentation = Self.presentation(state: Self.state(remaining: 3_132), now: Self.reset)

        XCTAssertEqual(presentation.numbersLine, "Checking budget")
        XCTAssertNil(presentation.resetLine)
        XCTAssertEqual(presentation.fillFraction, 0)
    }

    func testResetLineShowsTheShortResetTime() {
        XCTAssertEqual(
            Self.presentation(remaining: 3_132).resetLine,
            "Resets at \(Self.reset.formatted(date: .omitted, time: .shortened))"
        )
    }

    func testWarningAtAndBelowTheReserveAndWhilePaused() {
        XCTAssertTrue(Self.presentation(remaining: 1_000).isWarning)
        XCTAssertTrue(Self.presentation(remaining: 400).isWarning)
        // 1,050 is above the reserve, but 50 above it cannot cover a 55 point refresh.
        let pausedAbove = Self.presentation(state: Self.state(remaining: 1_050, samples: [55]))
        XCTAssertTrue(pausedAbove.isWarning)
        XCTAssertNotNil(pausedAbove.statusLine)
        XCTAssertFalse(Self.presentation(remaining: 1_600, samples: [55]).isWarning)
        XCTAssertFalse(Self.presentation(remaining: 4_900, samples: [55]).isWarning)
    }

    func testStretchedStatusLine() {
        // 600 above the reserve buys 10 refreshes over 3,000 s, one every 5 min.
        XCTAssertEqual(
            Self.presentation(remaining: 1_600, samples: [55]).statusLine,
            "Refreshing every 5 min until \(Self.time(Self.reset)) to stay within the budget"
        )
    }

    func testPausedStatusLineSaysWhetherManualRefreshStillWorks() {
        XCTAssertEqual(
            Self.presentation(remaining: 995, samples: [55]).statusLine,
            "Automatic refresh paused until \(Self.time(Self.reset)). Manual refresh still works."
        )
        XCTAssertEqual(
            Self.presentation(remaining: 40, samples: [55]).statusLine,
            "Automatic refresh paused until \(Self.time(Self.reset))."
        )
    }

    func testPausedStatusLineWithoutAnEstimateIsShort() {
        XCTAssertEqual(
            Self.presentation(remaining: 995).statusLine,
            "Automatic refresh paused until \(Self.time(Self.reset))."
        )
    }

    func testNoStatusLineWhenNormal() {
        XCTAssertNil(Self.presentation(remaining: 4_900, samples: [55]).statusLine)
        XCTAssertNil(Self.presentation(state: GitHubBudgetState()).statusLine)
    }

    func testDeferralLineTakesPrecedenceAndShowsTheLaterOfTheTwoTimes() {
        let earlyRetry = Self.now.addingTimeInterval(600)
        XCTAssertEqual(
            Self.presentation(state: Self.state(remaining: 995, samples: [55]), retryAt: earlyRetry).statusLine,
            "GitHub rate limit reached. Automatic refresh paused until \(Self.time(Self.reset))."
        )
        let lateRetry = Self.reset.addingTimeInterval(600)
        XCTAssertEqual(
            Self.presentation(state: Self.state(remaining: 995, samples: [55]), retryAt: lateRetry).statusLine,
            "GitHub rate limit reached. Automatic refresh paused until \(Self.time(lateRetry))."
        )
        XCTAssertEqual(
            Self.presentation(state: Self.state(remaining: 4_900, samples: [55]), retryAt: earlyRetry).statusLine,
            "GitHub rate limit reached. Automatic refresh paused until \(Self.time(earlyRetry))."
        )
    }

    func testExpiredDeferralShowsNoDeferralLine() {
        let expired = Self.now.addingTimeInterval(-1)
        XCTAssertNil(Self.presentation(state: Self.state(remaining: 4_900), retryAt: expired).statusLine)
    }

    @MainActor
    func testControllerDropsAnExpiredDeferralFromThePacingDisplay() async throws {
        let clock = ControllerTestClock(Self.now)
        let retryAt = Self.now.addingTimeInterval(600)
        let provider = BudgetGitHubProvider { budgetReading(used: 100, at: Self.now) }
        let controller = makeBudgetController(self, provider: provider, clock: clock)
        await waitForBudgetCondition { provider.fetchCount == 1 && !controller.isRefreshing }
        provider.budgetRead = { throw GitHubReadError.rateLimited(retryAt: retryAt) }
        controller.refresh()
        await waitForBudgetCondition { controller.rateLimitRetryAt != nil && !controller.isRefreshing }

        XCTAssertEqual(controller.pacingDisplay(at: Self.now).rateLimitRetryAt, retryAt)
        XCTAssertNotNil(controller.budgetPresentation(at: Self.now).statusLine)
        XCTAssertNil(controller.pacingDisplay(at: retryAt).rateLimitRetryAt)
        XCTAssertNil(controller.budgetPresentation(at: retryAt).statusLine)
    }

    func testChangeDatesEndPacingAtTheResetAndTheDeferral() {
        let retryAt = Self.now.addingTimeInterval(600)
        let display = PacingDisplay(pacing: .paused(until: Self.reset), canRefreshManually: true, rateLimitRetryAt: retryAt)

        XCTAssertEqual(display.changeDates(after: Self.now), [retryAt, Self.reset, Self.reset.addingTimeInterval(5)])
        XCTAssertEqual(
            PacingDisplay(pacing: .normal, canRefreshManually: false, rateLimitRetryAt: nil).changeDates(after: Self.now),
            []
        )
    }

    func testNewCopyHasNoSemicolonsOrDashes() {
        let retryAt = Self.now.addingTimeInterval(600)
        var lines = [GitHubBudgetCopy.title, GitHubBudgetCopy.hint, GitHubBudgetCopy.checking, GitHubBudgetCopy.readFailed]
        for presentation in [
            Self.presentation(remaining: 1_600, samples: [55]),
            Self.presentation(remaining: 995, samples: [55]),
            Self.presentation(remaining: 40, samples: [55]),
            Self.presentation(state: Self.state(remaining: 995), retryAt: retryAt),
        ] {
            lines += [presentation.numbersLine, presentation.resetLine, presentation.statusLine, presentation.hint]
                .compactMap { $0 }
        }
        XCTAssertEqual(
            GitHubBudgetCopy.hint,
            "MergeHawk spaces out automatic refreshes to stay within this budget and stops them when 20% is left, "
                + "so gh and other tools keep working. The budget is shared by every tool that uses your GitHub account."
        )
        for line in lines {
            XCTAssertFalse(line.contains(";") || line.contains("\u{2014}") || line.contains("\u{2013}"), line)
        }
    }

    // MARK: - Fixtures

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static func state(remaining: Int, samples: [Int] = []) -> GitHubBudgetState {
        var state = GitHubBudgetState()
        let used = 5_000 - remaining
        state.recordRead(GitHubBudgetReading(limit: 5_000, remaining: remaining, used: used, resetAt: reset, receivedAt: now))
        for sample in samples {
            state.recordCompleteRefresh(
                baseline: GitHubBudgetReading(limit: 5_000, remaining: remaining, used: used, resetAt: reset, receivedAt: now),
                fetched: GitHubBudgetReading(
                    limit: 5_000, remaining: remaining - sample, used: used + sample, resetAt: reset, receivedAt: now
                )
            )
        }
        return state
    }

    private static func presentation(remaining: Int, samples: [Int] = []) -> GitHubBudgetPresentation {
        presentation(state: state(remaining: remaining, samples: samples))
    }

    /// Builds the presentation the way the controller does, from the decision on `state` at `now`.
    private static func presentation(
        state: GitHubBudgetState,
        retryAt: Date? = nil,
        now: Date = now
    ) -> GitHubBudgetPresentation {
        let display = PacingDisplay(
            pacing: RefreshPacingPolicy.decide(
                reading: state.reading,
                estimatedCost: state.estimatedCost,
                userInterval: twoMinutes,
                now: now
            ),
            canRefreshManually: RefreshPacingPolicy.canAffordOneRefresh(
                reading: state.usableReading(at: now),
                estimatedCost: state.estimatedCost
            ),
            rateLimitRetryAt: retryAt
        )
        return GitHubBudgetPresentation(budgetState: state, pacing: display, now: now)
    }
}
