@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubPullRequestFetchTests: XCTestCase {
    override func tearDown() {
        PullRequestFetchMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testPullRequestQueriesUseBoundedShallowAndDetailLimits() {
        let shallow = GitHubClient.pullRequestShallowSearchQuery
        XCTAssertTrue(shallow.contains("search(query: $query, type: ISSUE, first: 50)"))
        XCTAssertTrue(shallow.contains("reviewRequests(first: 20)"))
        XCTAssertTrue(shallow.contains("commits(last: 20)"))
        XCTAssertTrue(shallow.contains("oid"))
        XCTAssertTrue(shallow.contains("authoredDate"))
        XCTAssertTrue(shallow.contains("committedDate"))
        XCTAssertTrue(shallow.contains("assignees(first: 20)"))
        XCTAssertTrue(shallow.contains("latestOpinionatedReviews(first: 20)"))
        let shallowOpinionated = String(shallow.split(separator: "latestOpinionatedReviews(first: 20)")[1]
            .split(separator: "reviewThreads(first: 20)")[0])
        XCTAssertTrue(shallowOpinionated.contains("author {"))
        XCTAssertTrue(shallowOpinionated.contains("login"))
        XCTAssertTrue(shallow.contains("additions"))
        XCTAssertTrue(shallow.contains("deletions"))
        XCTAssertEqual(shallow.components(separatedBy: "avatarUrl(size: 64)").count - 1, 1)
        XCTAssertTrue(shallow.contains("reviewThreads(first: 20)"))
        XCTAssertFalse(shallow.contains("reviewThreads(first: 100)"))
        XCTAssertFalse(shallow.contains("comments(last: 100)"))

        let detail = GitHubClient.pullRequestDetailQuery
        XCTAssertTrue(detail.contains("comments(last: 10)"))
        XCTAssertTrue(detail.contains("reviews(last: 10)"))
        XCTAssertTrue(detail.contains("commits(last: 20)"))
        XCTAssertTrue(detail.contains("latestOpinionatedReviews(first: 20)"))
        let detailOpinionated = String(detail.split(separator: "latestOpinionatedReviews(first: 20)")[1]
            .split(separator: "reviewThreads(first: 20)")[0])
        XCTAssertTrue(detailOpinionated.contains("author {"))
        XCTAssertTrue(detailOpinionated.contains("login"))
        XCTAssertFalse(shallow.contains("reviewDecision\n"))
        XCTAssertFalse(detail.contains("reviewDecision\n"))
        XCTAssertTrue(detail.contains("additions"))
        XCTAssertTrue(detail.contains("deletions"))
        XCTAssertEqual(detail.components(separatedBy: "avatarUrl(size: 64)").count - 1, 1)
        XCTAssertTrue(detail.contains("reviewThreads(first: 20)"))
        XCTAssertTrue(detail.contains("comments(last: 10)"))
        XCTAssertFalse(detail.contains("first: 100"))
        XCTAssertFalse(detail.contains("last: 100"))
    }

    func testEffectiveNonAuthorReviewDecisions() throws {
        let approval = Self.opinionatedNode("APPROVED", reviewer: "Teammate")
        let request = Self.opinionatedNode("CHANGES_REQUESTED", reviewer: "other")
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 1, "nodes": [approval]]), .approved)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 2, "nodes": [approval, request]]), .changesRequested)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 1, "nodes": [Self.opinionatedNode("CHANGES_REQUESTED", reviewer: "RW")]]), .noReviewYet)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 2, "nodes": [Self.opinionatedNode("APPROVED", reviewer: "rw"), approval]]), .approved)

        // Activity history is separate: an older request or later comment does not
        // override the effective approval supplied by the opinionated connection.
        XCTAssertEqual(
            try Self.normalizeOpinionated(["totalCount": 1, "nodes": [approval]], activityReviewState: "CHANGES_REQUESTED"),
            .approved
        )
        XCTAssertEqual(
            try Self.normalizeOpinionated(["totalCount": 1, "nodes": [approval]], activityReviewState: "COMMENTED"),
            .approved
        )
    }

    func testNeutralAndEmptyEffectiveReviewsHaveNoFeedback() throws {
        for state in ["COMMENTED", "PENDING", "DISMISSED"] {
            XCTAssertEqual(
                try Self.normalizeOpinionated(["totalCount": 1, "nodes": [Self.opinionatedNode(state, reviewer: "teammate")]]),
                .noReviewYet
            )
        }
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 0, "nodes": []]), .noReviewYet)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 1, "nodes": [Self.opinionatedNode("APPROVED", reviewer: "rw")]]), .noReviewYet)
        // The latest opinion replaces an older request; the provider sends only the approval.
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 1, "nodes": [Self.opinionatedNode("APPROVED", reviewer: "teammate")]]), .approved)
    }

    func testIncompleteOrUnidentifiedReviewsRemainUnknownUnlessRequestIsConclusive() throws {
        let approval = Self.opinionatedNode("APPROVED", reviewer: "teammate")
        let request = Self.opinionatedNode("CHANGES_REQUESTED", reviewer: "other")
        XCTAssertEqual(try Self.normalizeOpinionated(nil), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(nil, nullConnection: true), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 0]), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 0, "nodes": NSNull()]), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(["nodes": [approval]]), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 1, "nodes": [NSNull()]]), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 1, "nodes": [["id": "REVIEW"]]]), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 2, "nodes": [approval]]), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 1, "nodes": [Self.opinionatedNode("FUTURE_STATE", reviewer: "teammate")]]), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 1, "nodes": [Self.opinionatedNode("APPROVED", reviewer: nil)]]), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 1, "nodes": [Self.opinionatedNode("CHANGES_REQUESTED", reviewer: nil)]]), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 1, "nodes": [request]], author: nil), .unknown)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 3, "nodes": [request, approval]]), .changesRequested)
        XCTAssertEqual(try Self.normalizeOpinionated(["totalCount": 2, "nodes": [request, Self.opinionatedNode("APPROVED", reviewer: nil)]]), .changesRequested)
    }

    func testFreshShallowReviewFeedbackWinsWhenDetailsAreReused() async throws {
        let session = Self.mockSession()
        var detailRequests = 0
        PullRequestFetchMockURLProtocol.handler = { request in
            if Self.requestBody(request).contains("PullRequestDetails") { detailRequests += 1 }
            let response = Self.withOpinionatedReviews(
                Self.searchResponse(commentCount: 0, reviewCount: 0),
                json: #"{ "totalCount": 1, "nodes": [{"id":"CHANGE","state":"CHANGES_REQUESTED","author":{"login":"teammate"}}] }"#
            )
            return (response, Self.okResponse(for: request))
        }
        let previous = PullRequest.fixture(commentActivityCount: 0, reviewCount: 0, reviewDecision: .approved)
        let result = try await GitHubClient(token: "token", session: session).fetchPullRequests(
            login: "rw", previousPullRequests: [previous]
        )
        XCTAssertEqual(detailRequests, 0)
        XCTAssertEqual(result.pullRequests.first?.reviewDecision, .changesRequested)
    }

    func testChangeCountsNormalizeAndSurviveCacheRoundTrip() throws {
        let response = Self.pullRequestJSON(commentCount: 0, reviewCount: 0, includeActivity: false)
        let node = try JSONDecoder().decode(GitHubPullRequestNode.self, from: Data(response.utf8))
        let request = GitHubPullRequestNormalizer.normalize(node, login: "rw")
        XCTAssertEqual(request.additions, 0)
        XCTAssertEqual(request.deletions, 12345)
        XCTAssertEqual(request.authorAvatarURL?.absoluteString, "https://avatars.githubusercontent.com/u/123?v=4")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encoded = try encoder.encode(request)
        let roundTrip = try decoder.decode(PullRequest.self, from: encoded)
        XCTAssertEqual(roundTrip.additions, 0)
        XCTAssertEqual(roundTrip.deletions, 12345)
        XCTAssertEqual(roundTrip.authorAvatarURL, request.authorAvatarURL)

        var oldCache = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldCache.removeValue(forKey: "additions")
        oldCache.removeValue(forKey: "deletions")
        oldCache.removeValue(forKey: "authorAvatarURL")
        let oldRequest = try decoder.decode(PullRequest.self, from: JSONSerialization.data(withJSONObject: oldCache))
        XCTAssertNil(oldRequest.additions)
        XCTAssertNil(oldRequest.deletions)
        XCTAssertNil(oldRequest.authorAvatarURL)
    }

    func testMissingPullRequestAuthorOrAvatarUsesNoAvatarURL() throws {
        let data = Data(Self.pullRequestJSON(commentCount: 0, reviewCount: 0, includeActivity: false).utf8)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["author"] = ["login": "rw"]
        var node = try JSONDecoder().decode(GitHubPullRequestNode.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(GitHubPullRequestNormalizer.normalize(node, login: "rw").authorAvatarURL)

        json["author"] = NSNull()
        node = try JSONDecoder().decode(GitHubPullRequestNode.self, from: JSONSerialization.data(withJSONObject: json))
        let request = GitHubPullRequestNormalizer.normalize(node, login: "rw")
        XCTAssertEqual(request.author, "unknown")
        XCTAssertNil(request.authorAvatarURL)
    }

    func testShallowChangeCountsSurviveUnchangedDetailReuseAndDetailFailure() async throws {
        let session = Self.mockSession()
        let previous = PullRequest.fixture(commentActivityCount: 0, reviewCount: 0, additions: 99, deletions: 99)
        PullRequestFetchMockURLProtocol.handler = { request in
            (Self.searchResponse(commentCount: 0, reviewCount: 0), Self.okResponse(for: request))
        }
        let client = GitHubClient(token: "token", session: session)
        let unchanged = try await client.fetchPullRequests(login: "rw", previousPullRequests: [previous])
        XCTAssertEqual(unchanged.pullRequests.first?.additions, 0)
        XCTAssertEqual(unchanged.pullRequests.first?.deletions, 12345)
        XCTAssertEqual(unchanged.pullRequests.first?.authorAvatarURL?.absoluteString, "https://avatars.githubusercontent.com/u/123?v=4")

        PullRequestFetchMockURLProtocol.handler = { request in
            if Self.requestBody(request).contains("PullRequestDetails") {
                return (Data(#"{"errors":[{"message":"temporary detail failure"}]}"#.utf8), Self.okResponse(for: request))
            }
            return (Self.searchResponse(commentCount: 1, reviewCount: 0), Self.okResponse(for: request))
        }
        let failed = try await client.fetchPullRequests(login: "rw", previousPullRequests: [previous])
        XCTAssertNotNil(failed.refreshWarning)
        XCTAssertEqual(failed.pullRequests.first?.additions, 0)
        XCTAssertEqual(failed.pullRequests.first?.deletions, 12345)
        XCTAssertEqual(failed.pullRequests.first?.authorAvatarURL?.absoluteString, "https://avatars.githubusercontent.com/u/123?v=4")
    }

    func testDetailHydrationAndCommitReplacementPreserveChangeCounts() async throws {
        let session = Self.mockSession()
        PullRequestFetchMockURLProtocol.handler = { request in
            if Self.requestBody(request).contains("PullRequestDetails") {
                return (Self.detailResponse(), Self.okResponse(for: request))
            }
            return (Self.searchResponse(commentCount: 1, reviewCount: 0), Self.okResponse(for: request))
        }
        let client = GitHubClient(token: "token", session: session)
        let hydrated = try await client.fetchPullRequests(
            login: "rw",
            previousPullRequests: [.fixture(commentActivityCount: 0, reviewCount: 0)]
        )
        XCTAssertEqual(hydrated.pullRequests.first?.additions, 0)
        XCTAssertEqual(hydrated.pullRequests.first?.deletions, 12345)
        XCTAssertEqual(hydrated.pullRequests.first?.authorAvatarURL?.absoluteString, "https://avatars.githubusercontent.com/u/123?v=4")

        PullRequestFetchMockURLProtocol.handler = { request in
            if request.url?.path == "/repos/acme/app/pulls/12/commits" {
                return (Self.pullRequestCommitsResponse(), Self.okResponse(for: request))
            }
            return (Self.searchResponseWithInaccessibleCommitMetadata(), Self.okResponse(for: request))
        }
        let replaced = try await client.fetchPullRequests(
            login: "rw",
            previousPullRequests: [.fixture(commentActivityCount: 0, reviewCount: 0)]
        )
        XCTAssertEqual(replaced.pullRequests.first?.additions, 0)
        XCTAssertEqual(replaced.pullRequests.first?.deletions, 12345)
        XCTAssertEqual(replaced.pullRequests.first?.authorAvatarURL?.absoluteString, "https://avatars.githubusercontent.com/u/123?v=4")
    }

    func testUnchangedPullRequestDoesNotFetchDetails() async throws {
        let session = Self.mockSession()
        var requestBodies: [String] = []
        PullRequestFetchMockURLProtocol.handler = { request in
            let body = Self.requestBody(request)
            requestBodies.append(body)
            return (Self.searchResponse(commentCount: 0, reviewCount: 0), Self.okResponse(for: request))
        }

        let client = GitHubClient(token: "token", session: session)
        let result = try await client.fetchPullRequests(
            login: "rw",
            previousPullRequests: [.fixture(commentActivityCount: 0, reviewCount: 0)]
        )

        XCTAssertEqual(result.pullRequests.count, 1)
        XCTAssertEqual(requestBodies.count, 3)
        XCTAssertFalse(requestBodies.contains { $0.contains("PullRequestDetails") })
    }

    func testChangedPullRequestFetchesDetailsByNodeId() async throws {
        let session = Self.mockSession()
        var requestBodies: [String] = []
        PullRequestFetchMockURLProtocol.handler = { request in
            let body = Self.requestBody(request)
            requestBodies.append(body)
            if body.contains("PullRequestDetails") {
                return (Self.detailResponse(), Self.okResponse(for: request))
            }
            return (Self.searchResponse(commentCount: 1, reviewCount: 0), Self.okResponse(for: request))
        }

        let client = GitHubClient(token: "token", session: session)
        let result = try await client.fetchPullRequests(
            login: "rw",
            previousPullRequests: [.fixture(commentActivityCount: 0, reviewCount: 0)]
        )

        XCTAssertEqual(requestBodies.count, 4)
        XCTAssertEqual(requestBodies.filter { $0.contains("PullRequestDetails") }.count, 1)
        XCTAssertTrue(requestBodies.last?.contains(#""ids":["PR_1"]"#) == true)
        XCTAssertEqual(result.pullRequests.first?.recentCommentActivities.map(\.id), ["COMMENT_1"])
    }

    func testDetailHydrationPreservesTeamReviewRequestContext() async throws {
        let session = Self.mockSession()
        PullRequestFetchMockURLProtocol.handler = { request in
            let body = Self.requestBody(request)
            if body.contains("PullRequestDetails") {
                return (Self.detailResponse(), Self.okResponse(for: request))
            }
            return (
                Self.searchResponse(commentCount: 1, reviewCount: 0, reviewRequests: Self.teamReviewRequestsJSON),
                Self.okResponse(for: request)
            )
        }

        let client = GitHubClient(token: "token", session: session)
        let result = try await client.fetchPullRequests(
            login: "rw",
            previousPullRequests: [.fixture(commentActivityCount: 0, reviewCount: 0)]
        )

        XCTAssertEqual(result.pullRequests.first?.reviewRequestKind, .team)
    }

    func testInaccessibleCommitMetadataUsesPullRequestCommitsFallback() async throws {
        let session = Self.mockSession()
        var requestedCommitFallback = false
        PullRequestFetchMockURLProtocol.handler = { request in
            if request.url?.path == "/repos/acme/app/pulls/12/commits" {
                requestedCommitFallback = true
                return (Self.pullRequestCommitsResponse(), Self.okResponse(for: request))
            }
            return (Self.searchResponseWithInaccessibleCommitMetadata(), Self.okResponse(for: request))
        }

        let client = GitHubClient(token: "token", session: session)
        let result = try await client.fetchPullRequests(
            login: "rw",
            previousPullRequests: [.fixture(commentActivityCount: 0, reviewCount: 0)]
        )

        XCTAssertEqual(result.pullRequests.count, 1)
        XCTAssertEqual(result.pullRequests.first?.title, "Ship dashboard")
        XCTAssertEqual(result.pullRequests.first?.recentCommits.map(\.oid), ["COMMIT_REST_1"])
        XCTAssertEqual(result.pullRequests.first?.recentCommits.first?.authorLogin, "teammate")
        XCTAssertEqual(result.pullRequests.first?.hasRecentCommitMetadata, true)
        XCTAssertTrue(requestedCommitFallback)
    }

    func testActionableCommentCountChangeTriggersDetailFetch() async throws {
        let session = Self.mockSession()
        var requestBodies: [String] = []
        PullRequestFetchMockURLProtocol.handler = { request in
            let body = Self.requestBody(request)
            requestBodies.append(body)
            return (Self.searchResponse(commentCount: 0, reviewCount: 0), Self.okResponse(for: request))
        }

        let client = GitHubClient(token: "token", session: session)
        let result = try await client.fetchPullRequests(
            login: "rw",
            previousPullRequests: [.fixture(commentCount: 1, commentActivityCount: 0, reviewCount: 0)]
        )

        XCTAssertEqual(requestBodies.count, 4)
        XCTAssertEqual(requestBodies.filter { $0.contains("PullRequestDetails") }.count, 1)
        XCTAssertEqual(result.pullRequests.first?.commentCount, 0)
    }

    func testDetailFailureReusesPreviousActivityAndReportsWarning() async throws {
        let session = Self.mockSession()
        PullRequestFetchMockURLProtocol.handler = { request in
            let body = Self.requestBody(request)
            if body.contains("PullRequestDetails") {
                return (
                    Data(#"{"errors":[{"message":"temporary detail failure"}]}"#.utf8),
                    Self.okResponse(for: request)
                )
            }
            return (Self.searchResponse(commentCount: 2, reviewCount: 0), Self.okResponse(for: request))
        }

        let previous = PullRequest.fixture(
            commentCount: 1,
            commentActivityCount: 1,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "OLD_COMMENT",
                    author: "teammate",
                    createdAt: Date(timeIntervalSince1970: 10),
                    source: .pullRequest
                )
            ],
            reviewCount: 0
        )
        let client = GitHubClient(token: "token", session: session)
        let result = try await client.fetchPullRequests(login: "rw", previousPullRequests: [previous])

        XCTAssertNotNil(result.refreshWarning)
        XCTAssertEqual(result.pullRequests.first?.commentActivityCount, 1)
        XCTAssertEqual(result.pullRequests.first?.recentCommentActivities.map(\.id), ["OLD_COMMENT"])
    }

    func testAuthFailureDuringDetailFetchIsPropagated() async throws {
        let session = Self.mockSession()
        PullRequestFetchMockURLProtocol.handler = { request in
            (Self.searchResponse(commentCount: 1, reviewCount: 0), Self.okResponse(for: request))
        }
        let tokenCalls = TokenCallCounter()
        let client = GitHubClient(session: session) {
            if tokenCalls.increment() == 4 {
                throw GitHubClientError.authRefreshFailed(status: 401, detail: nil)
            }
            return "token"
        }

        do {
            _ = try await client.fetchPullRequests(
                login: "rw",
                previousPullRequests: [.fixture(commentActivityCount: 0, reviewCount: 0)]
            )
            XCTFail("Expected detail auth failure to propagate.")
        } catch GitHubClientError.authRefreshFailed {
            XCTAssertEqual(tokenCalls.value, 4)
        } catch {
            XCTFail("Expected authRefreshFailed, got \(error).")
        }
    }

    func testHTTPUnauthorizedDuringDetailFetchIsPropagated() async throws {
        let session = Self.mockSession()
        PullRequestFetchMockURLProtocol.handler = { request in
            let body = Self.requestBody(request)
            if body.contains("PullRequestDetails") {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }
            return (Self.searchResponse(commentCount: 1, reviewCount: 0), Self.okResponse(for: request))
        }

        let client = GitHubClient(token: "token", session: session)

        do {
            _ = try await client.fetchPullRequests(
                login: "rw",
                previousPullRequests: [.fixture(commentActivityCount: 0, reviewCount: 0)]
            )
            XCTFail("Expected HTTP 401 detail failure to propagate.")
        } catch GitHubClientError.httpFailure(_, 401) {
        } catch {
            XCTFail("Expected HTTP 401, got \(error).")
        }
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullRequestFetchMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func opinionatedNode(_ state: String, reviewer: String?) -> [String: Any] {
        var node: [String: Any] = ["id": "REVIEW", "state": state]
        if let reviewer { node["author"] = ["login": reviewer] }
        return node
    }

    private static func normalizeOpinionated(
        _ connection: [String: Any]?,
        author: String? = "rw",
        nullConnection: Bool = false,
        activityReviewState: String? = nil
    ) throws -> ReviewDecision {
        let data = Data(pullRequestJSON(commentCount: 0, reviewCount: 0, includeActivity: false).utf8)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let connection { json["latestOpinionatedReviews"] = connection }
        else if nullConnection { json["latestOpinionatedReviews"] = NSNull() }
        else { json.removeValue(forKey: "latestOpinionatedReviews") }
        if let author { json["author"] = ["login": author] }
        else { json["author"] = NSNull() }
        if let activityReviewState {
            json["reviews"] = [
                "totalCount": 1,
                "nodes": [["id": "ACTIVITY", "state": activityReviewState, "author": ["login": "teammate"]]]
            ]
        }
        let node = try JSONDecoder().decode(GitHubPullRequestNode.self, from: JSONSerialization.data(withJSONObject: json))
        return GitHubPullRequestNormalizer.normalize(node, login: "rw").reviewDecision
    }

    private static func withOpinionatedReviews(_ response: Data, json: String) -> Data {
        let body = String(decoding: response, as: UTF8.self)
        return Data(body.replacingOccurrences(
            of: #""latestOpinionatedReviews": { "totalCount": 0, "nodes": [] }"#,
            with: #""latestOpinionatedReviews": "# + json
        ).utf8)
    }

    private static func requestBody(_ request: URLRequest) -> String {
        if let httpBody = request.httpBody {
            return String(data: httpBody, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else {
            return ""
        }
        stream.open()
        defer {
            stream.close()
        }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func okResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private static func searchResponse(
        commentCount: Int,
        reviewCount: Int,
        reviewRequests: String = #"{ "nodes": [] }"#
    ) -> Data {
        Data("""
        {
          "data": {
            "search": {
              "nodes": [
                \(pullRequestJSON(
                    commentCount: commentCount,
                    reviewCount: reviewCount,
                    reviewRequests: reviewRequests,
                    includeActivity: false
                ))
              ]
            }
          }
        }
        """.utf8)
    }

    private static func detailResponse() -> Data {
        Data("""
        {
          "data": {
            "nodes": [
              \(pullRequestJSON(commentCount: 1, reviewCount: 0, includeActivity: true))
            ]
          }
        }
        """.utf8)
    }

    private static func searchResponseWithInaccessibleCommitMetadata() -> Data {
        Data("""
        {
          "data": {
            "search": {
              "nodes": [
                \(pullRequestJSONWithCommits(#"{ "nodes": [null] }"#))
              ]
            }
          },
          "errors": [
            {
              "type": "FORBIDDEN",
              "path": ["search", "nodes", 0, "commits", "nodes", 0],
              "message": "Resource not accessible by integration"
            }
          ]
        }
        """.utf8)
    }

    private static func pullRequestCommitsResponse() -> Data {
        Data("""
        [
          {
            "sha": "COMMIT_REST_1",
            "commit": {
              "author": { "date": "2026-05-02T11:00:00Z" },
              "committer": { "date": "2026-05-02T11:05:00Z" }
            },
            "author": { "login": "teammate" },
            "committer": { "login": "teammate" }
          }
        ]
        """.utf8)
    }

    private static func pullRequestJSON(
        commentCount: Int,
        reviewCount: Int,
        reviewRequests: String = #"{ "nodes": [] }"#,
        includeActivity: Bool
    ) -> String {
        let commentNodes = includeActivity
            ? #","nodes":[{"id":"COMMENT_1","createdAt":"2026-05-02T12:00:00Z","viewerDidAuthor":false,"author":{"login":"teammate"}}]"#
            : ""
        return """
        {
          "id": "PR_1",
          "title": "Ship dashboard",
          "number": 12,
          "url": "https://github.com/acme/app/pull/12",
          "createdAt": "2026-05-01T12:00:00Z",
          "updatedAt": "2026-05-02T12:00:00Z",
          "headRefName": "ship-dashboard",
          "isDraft": false,
          "mergeable": "MERGEABLE",
          "additions": 0,
          "deletions": 12345,
          "comments": { "totalCount": \(commentCount)\(commentNodes) },
          "reviews": { "totalCount": \(reviewCount), "nodes": [] },
          "latestOpinionatedReviews": { "totalCount": 0, "nodes": [] },
          "reviewThreads": { "nodes": [] },
          "reviewRequests": \(reviewRequests),
          "assignees": { "nodes": [] },
          "repository": { "nameWithOwner": "acme/app" },
          "commits": {
            "nodes": [
              {
                "commit": {
                  "oid": "COMMIT_1",
                  "authoredDate": "2026-05-02T11:00:00Z",
                  "committedDate": "2026-05-02T11:05:00Z",
                  "author": { "user": { "login": "rw" } },
                  "committer": { "user": { "login": "rw" } },
                  "statusCheckRollup": { "state": "SUCCESS" }
                }
              }
            ]
          },
          "author": { "login": "rw", "avatarUrl": "https://avatars.githubusercontent.com/u/123?v=4" }
        }
        """
    }

    private static func pullRequestJSONWithCommits(_ commits: String) -> String {
        """
        {
          "id": "PR_1",
          "title": "Ship dashboard",
          "number": 12,
          "url": "https://github.com/acme/app/pull/12",
          "createdAt": "2026-05-01T12:00:00Z",
          "updatedAt": "2026-05-02T12:00:00Z",
          "headRefName": "ship-dashboard",
          "isDraft": false,
          "mergeable": "MERGEABLE",
          "additions": 0,
          "deletions": 12345,
          "comments": { "totalCount": 0 },
          "reviews": { "totalCount": 0, "nodes": [] },
          "latestOpinionatedReviews": { "totalCount": 0, "nodes": [] },
          "reviewThreads": { "nodes": [] },
          "reviewRequests": { "nodes": [] },
          "assignees": { "nodes": [] },
          "repository": { "nameWithOwner": "acme/app" },
          "commits": \(commits),
          "author": { "login": "rw", "avatarUrl": "https://avatars.githubusercontent.com/u/123?v=4" }
        }
        """
    }

    private static let teamReviewRequestsJSON = """
    {
      "nodes": [
        {
          "requestedReviewer": {
            "__typename": "Team",
            "slug": "ios",
            "organization": { "login": "acme" }
          }
        }
      ]
    }
    """
}

private final class PullRequestFetchMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

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

private final class TokenCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock {
            count
        }
    }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private extension PullRequest {
    static func fixture(
        commentCount: Int = 0,
        commentActivityCount: Int? = nil,
        recentCommentActivities: [PullRequestCommentActivity] = [],
        reviewCount: Int = 0,
        additions: Int? = nil,
        deletions: Int? = nil,
        reviewDecision: ReviewDecision = .noReviewYet
    ) -> PullRequest {
        PullRequest(
            id: "PR_1",
            title: "Ship dashboard",
            number: 12,
            url: URL(string: "https://github.com/acme/app/pull/12")!,
            repo: "acme/app",
            ciState: .passing,
            reviewDecision: reviewDecision,
            additions: additions,
            deletions: deletions,
            commentCount: commentCount,
            commentActivityCount: commentActivityCount,
            recentCommentActivities: recentCommentActivities,
            reviewCount: reviewCount,
            isMine: true,
            author: "rw",
            headRefName: "ship-dashboard",
            mergeable: .mergeable,
            draft: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }
}
