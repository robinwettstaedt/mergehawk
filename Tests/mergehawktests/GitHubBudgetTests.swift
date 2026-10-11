@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubBudgetTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let reset = now.addingTimeInterval(3_000)

    func testReadingParsesAllFourHeaders() throws {
        let reading = try XCTUnwrap(GitHubBudgetReading(
            response: Self.response(headers: [
                "X-RateLimit-Limit": "5000",
                "X-RateLimit-Remaining": "3132",
                "X-RateLimit-Used": "1868",
                "X-RateLimit-Reset": "\(Int(Self.reset.timeIntervalSince1970))"
            ]),
            receivedAt: Self.now
        ))

        XCTAssertEqual(reading, GitHubBudgetReading(
            limit: 5_000,
            remaining: 3_132,
            used: 1_868,
            resetAt: Self.reset,
            receivedAt: Self.now
        ))
    }

    func testReadingIsNilWhenAnyHeaderIsMissingOrMalformed() {
        let complete = [
            "x-ratelimit-limit": "5000",
            "x-ratelimit-remaining": "3132",
            "x-ratelimit-used": "1868",
            "x-ratelimit-reset": "1800003000"
        ]
        for name in complete.keys {
            var missing = complete
            missing[name] = nil
            XCTAssertNil(GitHubBudgetReading(response: Self.response(headers: missing), receivedAt: Self.now), name)

            var malformed = complete
            malformed[name] = "soon"
            XCTAssertNil(GitHubBudgetReading(response: Self.response(headers: malformed), receivedAt: Self.now), name)
        }
    }

    func testMergeKeepsTheLaterResetAndIgnoresAnEarlierOne() {
        let current = Self.reading(used: 900)
        let nextWindow = Self.reading(used: 10, resetAt: Self.reset.addingTimeInterval(3_600))
        let previousWindow = Self.reading(used: 4_000, resetAt: Self.reset.addingTimeInterval(-3_600))

        XCTAssertEqual(current.merged(with: nextWindow), nextWindow)
        XCTAssertEqual(nextWindow.merged(with: current), nextWindow)
        XCTAssertEqual(current.merged(with: previousWindow), current)
        XCTAssertEqual(previousWindow.merged(with: current), current)
        XCTAssertEqual(current.merged(with: nil), current)
    }

    func testMergeInOneWindowKeepsTheHigherUsedInBothOrders() {
        let lower = Self.reading(used: 900, receivedAt: Self.now.addingTimeInterval(5))
        let higher = Self.reading(used: 955, receivedAt: Self.now)

        XCTAssertEqual(lower.merged(with: higher), higher)
        XCTAssertEqual(higher.merged(with: lower), higher)

        let tie = Self.reading(used: 900, receivedAt: Self.now.addingTimeInterval(9))
        XCTAssertEqual(lower.merged(with: tie), lower)
    }

    func testStaleness() {
        XCTAssertFalse(Self.reading(used: 1).isStale(at: Self.now))
        XCTAssertTrue(Self.reading(used: 1).isStale(at: Self.reset))
        XCTAssertTrue(Self.reading(used: 1).isStale(at: Self.reset.addingTimeInterval(60)))

        let receivedAfterReset = Self.reading(used: 1, receivedAt: Self.reset.addingTimeInterval(2))
        XCTAssertFalse(receivedAfterReset.isStale(at: Self.reset.addingTimeInterval(30)))

        var state = GitHubBudgetState()
        state.recordRead(Self.reading(used: 1))
        XCTAssertNotNil(state.usableReading(at: Self.now))
        XCTAssertNil(state.usableReading(at: Self.reset))
    }

    func testCostSampleAppendsTheRiseInOneWindow() {
        var state = GitHubBudgetState()
        state.recordCompleteRefresh(baseline: Self.reading(used: 800), fetched: Self.reading(used: 855))

        XCTAssertEqual(state.costSamples, [55])
        XCTAssertEqual(state.estimatedCost, 55)
    }

    func testCostSampleSkipsAnotherWindowAMissingSideAndNoRise() {
        var state = GitHubBudgetState()
        state.recordCompleteRefresh(
            baseline: Self.reading(used: 4_900),
            fetched: Self.reading(used: 40, resetAt: Self.reset.addingTimeInterval(3_600))
        )
        state.recordCompleteRefresh(baseline: nil, fetched: Self.reading(used: 855))
        state.recordCompleteRefresh(baseline: Self.reading(used: 800), fetched: nil)
        state.recordCompleteRefresh(baseline: Self.reading(used: 800), fetched: Self.reading(used: 800))
        state.recordCompleteRefresh(baseline: Self.reading(used: 800), fetched: Self.reading(used: 790))

        XCTAssertEqual(state.costSamples, [])
        XCTAssertNil(state.estimatedCost)
    }

    func testEstimateIsTheHighestOfTheLastThreeSamples() {
        var state = GitHubBudgetState()
        for rise in [90, 40, 50] {
            state.recordCompleteRefresh(baseline: Self.reading(used: 100), fetched: Self.reading(used: 100 + rise))
        }
        XCTAssertEqual(state.costSamples, [90, 40, 50])
        XCTAssertEqual(state.estimatedCost, 90)

        state.recordCompleteRefresh(baseline: Self.reading(used: 100), fetched: Self.reading(used: 160))
        XCTAssertEqual(state.costSamples, [40, 50, 60])
        XCTAssertEqual(state.estimatedCost, 60)
    }

    func testReadFailuresSetTheFlagAndASuccessfulReadClearsIt() {
        var state = GitHubBudgetState()
        state.recordRead(nil)
        XCTAssertTrue(state.lastReadFailed)
        XCTAssertNil(state.reading)

        state.recordRead(Self.reading(used: 800))
        XCTAssertFalse(state.lastReadFailed)
        XCTAssertEqual(state.reading?.used, 800)

        state.recordReadFailure()
        XCTAssertTrue(state.lastReadFailed)
        XCTAssertEqual(state.reading?.used, 800)

        state.recordLatest(Self.reading(used: 855))
        XCTAssertTrue(state.lastReadFailed)
        XCTAssertEqual(state.reading?.used, 855)

        state.recordLatest(nil)
        XCTAssertEqual(state.reading?.used, 855)
    }

    private static func reading(
        used: Int,
        resetAt: Date = reset,
        receivedAt: Date = now
    ) -> GitHubBudgetReading {
        GitHubBudgetReading(limit: 5_000, remaining: 5_000 - used, used: used, resetAt: resetAt, receivedAt: receivedAt)
    }

    private static func response(headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.github.com/graphql")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}
