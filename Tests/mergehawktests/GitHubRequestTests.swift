@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubRequestTests: XCTestCase {
    override func tearDown() {
        RequestURLProtocol.handler = nil
        super.tearDown()
    }

    func testMissingRequiredConnectionAndPageInfoFailDecoding() throws {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(GitHubCompletePullRequestPayload.self, from: payload(removing: "comments")))
        XCTAssertThrowsError(try decoder.decode(GitHubCompletePullRequestPayload.self, from: payload(pageInfo: false)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload()) as? [String: Any])
        var comments = try XCTUnwrap(object["comments"] as? [String: Any])
        var nodes = try XCTUnwrap(comments["nodes"] as? [[String: Any]])
        nodes[0].removeValue(forKey: "url")
        comments["nodes"] = nodes
        object["comments"] = comments
        XCTAssertThrowsError(try decoder.decode(GitHubCompletePullRequestPayload.self, from: Self.json(object)))

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload()) as? [String: Any])
        let review = ["id": "R1", "state": "APPROVED", "submittedAt": "2026-01-01T00:00:00Z", "viewerDidAuthor": false, "author": NSNull()] as [String: Any]
        var reviews = try XCTUnwrap(object["reviews"] as? [String: Any])
        reviews["nodes"] = [review]
        object["reviews"] = reviews
        XCTAssertThrowsError(try decoder.decode(GitHubCompletePullRequestPayload.self, from: Self.json(object)))

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload()) as? [String: Any])
        object["repository"] = ["nameWithOwner": "acme/app"]
        XCTAssertThrowsError(try decoder.decode(GitHubCompletePullRequestPayload.self, from: Self.json(object)))
    }

    func testOptionalAuthorAndNoChecksDecodeSuccessfully() throws {
        let decoded = try JSONDecoder().decode(GitHubCompletePullRequestPayload.self, from: payload())
        XCTAssertNil(decoded.author)
        XCTAssertNil(decoded.statusCheckRollup)
        XCTAssertNil(decoded.reviewDecision)
        XCTAssertEqual(decoded.comments.nodes.first?.author, nil)
    }

    func testActorAuthorsDecodeWithoutUnsupportedNodeIDs() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload()) as? [String: Any]
        )
        object["author"] = [
            "login": "pr-author",
            "avatarUrl": "https://avatars.example/pr-author.png"
        ]
        var comments = try XCTUnwrap(object["comments"] as? [String: Any])
        var nodes = try XCTUnwrap(comments["nodes"] as? [[String: Any]])
        nodes[0]["author"] = ["login": "comment-author"]
        comments["nodes"] = nodes
        object["comments"] = comments

        let decoded = try JSONDecoder().decode(
            GitHubCompletePullRequestPayload.self,
            from: Self.json(object)
        )

        XCTAssertNil(decoded.author?.id)
        XCTAssertEqual(decoded.author?.login, "pr-author")
        XCTAssertEqual(decoded.author?.avatarUrl, URL(string: "https://avatars.example/pr-author.png"))
        XCTAssertNil(decoded.comments.nodes[0].author?.id)
        XCTAssertEqual(decoded.comments.nodes[0].author?.login, "comment-author")
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

    func testGraphQLErrorCopyJoinsGitHubMessagesAsSentences() {
        let error = GitHubReadError.graphQL([
            GitHubGraphQLErrorPayload(message: "Field 'x' doesn't exist", type: nil, path: nil),
            GitHubGraphQLErrorPayload(message: "Something went wrong. ", type: nil, path: nil)
        ])
        XCTAssertEqual(
            error.errorDescription,
            "GitHub returned an error: Field 'x' doesn't exist. Something went wrong."
        )
    }

    func testQueryUsesDirectCIAndNoCommitHistory() {
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("statusCheckRollup"))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("headRefOid"))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("reviewDecision"))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("repository { nameWithOwner isArchived }"))
        XCTAssertFalse(GitHubPullRequestQueries.hydration.contains("commits("))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("pageInfo"))
        XCTAssertFalse(GitHubPullRequestQueries.hydration.contains("author { id"))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("author { login avatarUrl(size: 64) }"))
        // Comments, reviews and latest opinionated reviews carry actors. Review threads select no comments here.
        XCTAssertEqual(GitHubPullRequestQueries.hydration.components(separatedBy: "author { login __typename }").count - 1, 3)
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("assignees(last: 20)"))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("nodes { id login avatarUrl(size: 64) }"))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("... on User { id login }"))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("... on Team { id slug"))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("nodes { id url createdAt"))
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("nodes { id url state submittedAt"))
    }

    func testHTTP200GraphQLRateLimitPreservesResetHeader() async throws {
        let reset = Date().addingTimeInterval(60)
        let requests = LockedBox(0)
        RequestURLProtocol.handler = { request in
            requests.withValue { $0 += 1 }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-RateLimit-Reset": String(reset.timeIntervalSince1970)]
            )!
            return (Self.json(["errors": [["message": "exhausted", "type": "RATE_LIMITED"]]]), response)
        }

        do {
            _ = try await GitHubClient(token: "token", session: Self.session())
                .fetchCompletePullRequests(login: "rw", previousState: nil, reusableViewerTeams: nil)
            XCTFail("Expected rate limit")
        } catch let GitHubReadError.rateLimited(retryAt) {
            XCTAssertEqual(try XCTUnwrap(retryAt).timeIntervalSince1970, reset.timeIntervalSince1970, accuracy: 0.001)
        }
        XCTAssertEqual(requests.value, 1)
    }

    func testSecondaryRateLimit403UsesRetryAfterWithoutRemainingZero() async throws {
        let before = Date()
        let requests = LockedBox(0)
        RequestURLProtocol.handler = { request in
            requests.withValue { $0 += 1 }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Retry-After": "60"]
            )!
            return (Self.json(["message": "secondary rate limit"]), response)
        }

        do {
            _ = try await GitHubClient(token: "token", session: Self.session())
                .fetchCompletePullRequests(login: "rw", previousState: nil, reusableViewerTeams: nil)
            XCTFail("Expected rate limit")
        } catch let GitHubReadError.rateLimited(retryAt) {
            let value = try XCTUnwrap(retryAt)
            XCTAssertGreaterThanOrEqual(value, before.addingTimeInterval(60))
            XCTAssertLessThan(value.timeIntervalSince(before), 61)
        }
        XCTAssertEqual(requests.value, 1)
    }

    private func payload(removing key: String? = nil, pageInfo: Bool = true) -> Data {
        var object: [String: Any] = [
            "id": "PR_1", "title": "Test", "number": 1,
            "url": "https://github.com/acme/app/pull/1", "state": "OPEN",
            "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
            "headRefName": "feature", "headRefOid": "abc", "isDraft": false,
            "mergeable": "MERGEABLE", "additions": 1, "deletions": 2,
            "statusCheckRollup": NSNull(), "author": NSNull(), "reviewDecision": NSNull(),
            "repository": ["nameWithOwner": "acme/app", "isArchived": false]
        ]
        let connection: [String: Any] = [
            "totalCount": 1,
            "nodes": [[
                "id": "C1", "createdAt": "2026-01-01T00:00:00Z",
                "publishedAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
                "bodyHTML": "<p>Comment</p>",
                "url": "https://github.com/acme/app/pull/1#issuecomment-C1",
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

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private final class RequestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&stored) } }
}
