@testable import mergehawkcore
import Foundation
import XCTest

final class RefreshPacingTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let reset = now.addingTimeInterval(3_000)
    private static let twoMinutes: TimeInterval = 120

    func testReserveIsTwentyPercentRoundedUp() {
        XCTAssertEqual(RefreshPacingPolicy.reserve(forLimit: 5_000), 1_000)
        XCTAssertEqual(RefreshPacingPolicy.reserve(forLimit: 4_999), 1_000)
    }

    func testRuleOneNoOrStaleReadingIsNormal() {
        XCTAssertEqual(Self.decide(nil, estimate: 55), .normal)
        let stale = Self.reading(remaining: 10)
        XCTAssertEqual(
            RefreshPacingPolicy.decide(reading: stale, estimatedCost: 55, userInterval: Self.twoMinutes, now: Self.reset),
            .normal
        )
    }

    func testRuleTwoAtOrBelowTheReservePausesWithoutAnEstimate() {
        XCTAssertEqual(Self.decide(Self.reading(remaining: 1_000), estimate: nil), .paused(until: Self.reset))
        XCTAssertEqual(Self.decide(Self.reading(remaining: 400), estimate: 55), .paused(until: Self.reset))
    }

    func testRuleThreeNoEstimateIsNormal() {
        XCTAssertEqual(Self.decide(Self.reading(remaining: 1_001), estimate: nil), .normal)
    }

    func testRuleFourAvailableBelowTheEstimatePauses() {
        XCTAssertEqual(Self.decide(Self.reading(remaining: 1_054), estimate: 55), .paused(until: Self.reset))
        XCTAssertNotEqual(Self.decide(Self.reading(remaining: 1_055), estimate: 55), .paused(until: Self.reset))
    }

    func testRuleFiveEnoughBudgetForTheUserIntervalIsNormal() {
        XCTAssertEqual(Self.decide(Self.reading(remaining: 4_900), estimate: 55), .normal)
    }

    func testRuleFiveTimeUntilResetAtOrBelowZeroIsNormal() {
        let receivedAfterReset = Self.reading(remaining: 1_100, receivedAt: Self.reset.addingTimeInterval(1))
        XCTAssertEqual(
            RefreshPacingPolicy.decide(
                reading: receivedAfterReset,
                estimatedCost: 55,
                userInterval: Self.twoMinutes,
                now: Self.reset.addingTimeInterval(2)
            ),
            .normal
        )
    }

    func testAffordableExactlyCoveringTheTimeToResetStaysNormal() {
        // 550 available buys 10 refreshes, and 10 x 300 s is exactly the 3,000 s until the reset.
        XCTAssertEqual(Self.decide(Self.reading(remaining: 1_550), estimate: 55, userInterval: 300), .normal)
    }

    func testRuleSixStretchesAndRoundsUpToWholeMinutes() {
        // 600 available buys 10 refreshes over 3,000 s: one every 300 s.
        XCTAssertEqual(
            Self.decide(Self.reading(remaining: 1_600), estimate: 55),
            .stretched(interval: 300, until: Self.reset)
        )
        // 385 available buys 7 refreshes: 428.6 s rounds up to 8 min.
        XCTAssertEqual(
            Self.decide(Self.reading(remaining: 1_385), estimate: 55),
            .stretched(interval: 480, until: Self.reset)
        )
    }

    func testStretchedIntervalNeverGoesBelowTheUserInterval() {
        // 10 refreshes over 950 s at a 90 s interval: 95 s rounds up to 120 s.
        let reset = Self.now.addingTimeInterval(950)
        XCTAssertEqual(
            Self.decide(Self.reading(remaining: 1_550, resetAt: reset), estimate: 55, userInterval: 90),
            .stretched(interval: 120, until: reset)
        )
        // The 0.01 s test interval still stretches to whole minutes.
        XCTAssertEqual(
            Self.decide(Self.reading(remaining: 1_600), estimate: 55, userInterval: 0.01),
            .stretched(interval: 300, until: Self.reset)
        )
        let short = Self.decide(Self.reading(remaining: 4_900), estimate: 55, userInterval: 0.01)
        guard case .stretched(let interval, _) = short else { return XCTFail("\(short)") }
        XCTAssertEqual(interval, 60)
    }

    func testReadingReceivedAfterItsResetIsUsableAndRuleTwoStillPauses() {
        let receivedAfterReset = Self.reading(remaining: 200, receivedAt: Self.reset.addingTimeInterval(1))
        XCTAssertEqual(
            RefreshPacingPolicy.decide(
                reading: receivedAfterReset,
                estimatedCost: nil,
                userInterval: Self.twoMinutes,
                now: Self.reset.addingTimeInterval(10)
            ),
            .paused(until: Self.reset)
        )
    }

    func testCanAffordOneRefresh() {
        XCTAssertFalse(RefreshPacingPolicy.canAffordOneRefresh(reading: Self.reading(remaining: 900), estimatedCost: nil))
        XCTAssertFalse(RefreshPacingPolicy.canAffordOneRefresh(reading: nil, estimatedCost: 55))
        XCTAssertFalse(RefreshPacingPolicy.canAffordOneRefresh(reading: Self.reading(remaining: 54), estimatedCost: 55))
        XCTAssertTrue(RefreshPacingPolicy.canAffordOneRefresh(reading: Self.reading(remaining: 55), estimatedCost: 55))
    }

    func testNextDateNormalIsAnchorPlusInterval() {
        let anchor = Self.now.addingTimeInterval(-30)
        XCTAssertEqual(Self.next(.normal, anchor: anchor), anchor.addingTimeInterval(Self.twoMinutes))
    }

    func testNextDateStretchedIsCappedAtResetPlusMargin() {
        XCTAssertEqual(
            Self.next(.stretched(interval: 300, until: Self.reset), anchor: Self.now),
            Self.now.addingTimeInterval(300)
        )
        XCTAssertEqual(
            Self.next(.stretched(interval: 600, until: Self.now.addingTimeInterval(200)), anchor: Self.now),
            Self.now.addingTimeInterval(205)
        )
    }

    func testNextDatePausedWaitsUntilResetPlusMargin() {
        XCTAssertEqual(Self.next(.paused(until: Self.reset), anchor: Self.now), Self.reset.addingTimeInterval(5))
    }

    func testNextDatePausedWithThatTimeAlreadyPastWaitsAMinuteFromNow() {
        let now = Self.reset.addingTimeInterval(5)
        XCTAssertEqual(
            Self.next(.paused(until: Self.reset), anchor: Self.now, now: now),
            now.addingTimeInterval(60)
        )
    }

    func testNextDateTakesTheLaterDeferral() {
        let later = Self.now.addingTimeInterval(900)
        XCTAssertEqual(Self.next(.normal, anchor: Self.now, deferral: later), later)
        let earlier = Self.now.addingTimeInterval(10)
        XCTAssertEqual(Self.next(.normal, anchor: Self.now, deferral: earlier), Self.now.addingTimeInterval(120))
    }

    private static func decide(
        _ reading: GitHubBudgetReading?,
        estimate: Int?,
        userInterval: TimeInterval = twoMinutes
    ) -> RefreshPacing {
        RefreshPacingPolicy.decide(reading: reading, estimatedCost: estimate, userInterval: userInterval, now: now)
    }

    private static func next(
        _ pacing: RefreshPacing,
        anchor: Date,
        deferral: Date? = nil,
        now: Date = now
    ) -> Date {
        RefreshPacingPolicy.nextAutomaticRefreshDate(
            pacing: pacing,
            anchor: anchor,
            userInterval: twoMinutes,
            deferralRetryAt: deferral,
            now: now
        )
    }

    private static func reading(
        remaining: Int,
        resetAt: Date = reset,
        receivedAt: Date = now
    ) -> GitHubBudgetReading {
        GitHubBudgetReading(
            limit: 5_000,
            remaining: remaining,
            used: 5_000 - remaining,
            resetAt: resetAt,
            receivedAt: receivedAt
        )
    }
}
