@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubRequestTests: XCTestCase {
    func testMissingRequiredConnectionAndPageInfoFailDecoding() throws {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(GitHubCompletePullRequestPayload.self, from: payload(removing: "comments")))
        XCTAssertThrowsError(try decoder.decode(GitHubCompletePullRequestPayload.self, from: payload(pageInfo: false)))
    }

    func testOptionalAuthorAndNoChecksDecodeSuccessfully() throws {
        let decoded = try JSONDecoder().decode(GitHubCompletePullRequestPayload.self, from: payload())
        XCTAssertNil(decoded.author)
        XCTAssertNil(decoded.statusCheckRollup)
        XCTAssertEqual(decoded.comments.nodes.first?.author, nil)
    }

    func testRetryPolicyRetriesOnlyOrdinaryTransientReads() async throws {
        let attempts = LockedBox(0)
        let sleeps = LockedBox<[TimeInterval]>([])
        let policy = GitHubReadRetryPolicy(sleep: { seconds in sleeps.withValue { $0.append(seconds) } })
        let value: String = try await policy.run {
            let attempt = attempts.withValue { value -> Int in
                value += 1
                return value
            }
            if attempt < 3 { throw GitHubReadError.http(status: 503) }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(attempts.value, 3)
        XCTAssertEqual(sleeps.value, [1, 2])

        for terminal in [
            GitHubReadError.authentication,
            .accessDenied,
            .rateLimited(retryAt: Date(timeIntervalSince1970: 10)),
            .validation("bad query")
        ] {
            let calls = LockedBox(0)
            do {
                _ = try await policy.run {
                    calls.withValue { $0 += 1 }
                    throw terminal
                } as String
                XCTFail("Expected terminal error")
            } catch {
                XCTAssertEqual(error as? GitHubReadError, terminal)
                XCTAssertEqual(calls.value, 1)
            }
        }
    }

    func testQueryUsesDirectCIAndNoCommitHistory() {
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("statusCheckRollup"))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("headRefOid"))
        XCTAssertFalse(GitHubPullRequestQueries.hydration.contains("commits("))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("pageInfo"))
    }

    private func payload(removing key: String? = nil, pageInfo: Bool = true) -> Data {
        var object: [String: Any] = [
            "id": "PR_1", "title": "Test", "number": 1,
            "url": "https://github.com/acme/app/pull/1", "state": "OPEN",
            "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
            "headRefName": "feature", "headRefOid": "abc", "isDraft": false,
            "mergeable": "MERGEABLE", "additions": 1, "deletions": 2,
            "statusCheckRollup": NSNull(), "author": NSNull(),
            "repository": ["nameWithOwner": "acme/app"]
        ]
        let connection: [String: Any] = [
            "totalCount": 1,
            "nodes": [[
                "id": "C1", "createdAt": "2026-01-01T00:00:00Z",
                "viewerDidAuthor": false, "author": NSNull(), "pullRequestReview": NSNull()
            ]],
            "pageInfo": ["startCursor": "s", "endCursor": "e", "hasPreviousPage": false, "hasNextPage": false]
        ]
        object["comments"] = connection
        let empty: [String: Any] = [
            "totalCount": 0,
            "nodes": [],
            "pageInfo": ["startCursor": NSNull(), "endCursor": NSNull(), "hasPreviousPage": false, "hasNextPage": false]
        ]
        object["reviews"] = empty
        object["latestOpinionatedReviews"] = empty
        object["reviewThreads"] = empty
        object["assignees"] = empty
        object["reviewRequests"] = empty
        if let key { object.removeValue(forKey: key) }
        if !pageInfo { (object["comments"] as? [String: Any]).map { value in
            var value = value
            value.removeValue(forKey: "pageInfo")
            object["comments"] = value
        } }
        return try! JSONSerialization.data(withJSONObject: object)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&stored) } }
}
