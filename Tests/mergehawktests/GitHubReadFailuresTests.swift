@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubReadFailuresTests: XCTestCase {
    private struct ProviderFailure: Error, Equatable {}

    func testRateLimitBeatsAnEarlierInvalidPayload() {
        var failures = GitHubReadFailures()
        failures.record(GitHubReadError.invalidPayload, at: GitHubReadOrder(.discovery))
        failures.record(GitHubReadError.rateLimited(retryAt: nil), at: GitHubReadOrder(.continuation, 2))

        XCTAssertEqual(failures.error() as? GitHubReadError, .rateLimited(retryAt: nil))
    }

    func testRateLimitCarriesTheLatestRetryDate() {
        var failures = GitHubReadFailures()
        failures.record(GitHubReadError.rateLimited(retryAt: Date(timeIntervalSince1970: 10)), at: GitHubReadOrder(.discovery))
        failures.record(GitHubReadError.rateLimited(retryAt: Date(timeIntervalSince1970: 20)), at: GitHubReadOrder(.knownHydration, 1))
        failures.record(GitHubReadError.rateLimited(retryAt: nil), at: GitHubReadOrder(.knownHydration, 0))
        XCTAssertEqual(failures.error() as? GitHubReadError, .rateLimited(retryAt: Date(timeIntervalSince1970: 20)))

        var undated = GitHubReadFailures()
        undated.record(GitHubReadError.rateLimited(retryAt: nil), at: GitHubReadOrder(.discovery))
        undated.record(GitHubReadError.rateLimited(retryAt: nil), at: GitHubReadOrder(.viewerTeams))
        XCTAssertEqual(undated.error() as? GitHubReadError, .rateLimited(retryAt: nil))
    }

    func testAuthenticationBeatsRateLimitsAndOtherErrorsInAnyOrder() {
        var failures = GitHubReadFailures()
        failures.record(GitHubReadError.invalidPayload, at: GitHubReadOrder(.viewerTeams))
        failures.record(GitHubReadError.rateLimited(retryAt: Date(timeIntervalSince1970: 10)), at: GitHubReadOrder(.discovery))
        failures.record(GitHubReadError.authentication, at: GitHubReadOrder(.continuation, 3))

        XCTAssertEqual(failures.error() as? GitHubReadError, .authentication)
    }

    func testTokenProviderErrorAndCancellationBeatGitHubErrors() {
        var failures = GitHubReadFailures()
        failures.record(GitHubReadError.authentication, at: GitHubReadOrder(.viewerTeams))
        failures.record(GitHubReadError.rateLimited(retryAt: nil), at: GitHubReadOrder(.discovery))
        failures.record(GitHubReadError.invalidPayload, at: GitHubReadOrder(.knownHydration))
        failures.record(GitHubTokenProviderError(underlying: ProviderFailure()), at: GitHubReadOrder(.continuation))
        let provider = failures.error() as? GitHubTokenProviderError
        XCTAssertEqual(provider?.underlying as? ProviderFailure, ProviderFailure())

        var cancelled = GitHubReadFailures()
        cancelled.record(GitHubReadError.authentication, at: GitHubReadOrder(.viewerTeams))
        cancelled.record(CancellationError(), at: GitHubReadOrder(.newHydration))
        XCTAssertTrue(cancelled.error() is CancellationError)
    }

    func testOtherErrorsPickTheEarliestOrder() {
        var failures = GitHubReadFailures()
        failures.record(GitHubReadError.incompleteCoverage("known"), at: GitHubReadOrder(.knownHydration, 0))
        failures.record(GitHubReadError.invalidPayload, at: GitHubReadOrder(.discovery))
        XCTAssertEqual(failures.error() as? GitHubReadError, .invalidPayload)

        var batches = GitHubReadFailures()
        batches.record(GitHubReadError.invalidPayload, at: GitHubReadOrder(.newHydration, 0))
        batches.record(GitHubReadError.accessDenied, at: GitHubReadOrder(.knownHydration, 1))
        XCTAssertEqual(batches.error() as? GitHubReadError, .accessDenied)
    }

    func testStoppedReadLosesToEveryErrorAndIsReturnedAlone() {
        var failures = GitHubReadFailures()
        XCTAssertTrue(failures.isEmpty)
        XCTAssertNil(failures.error())

        failures.record(GitHubReadStopped(), at: GitHubReadOrder(.viewerTeams))
        XCTAssertFalse(failures.isEmpty)
        XCTAssertTrue(failures.error() is GitHubReadStopped)

        failures.record(GitHubReadError.invalidPayload, at: GitHubReadOrder(.continuation, 3))
        XCTAssertEqual(failures.error() as? GitHubReadError, .invalidPayload)
    }
}
