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
        XCTAssertTrue(shallow.contains("reviewThreads(first: 20)"))
        XCTAssertFalse(shallow.contains("reviewThreads(first: 100)"))
        XCTAssertFalse(shallow.contains("comments(last: 100)"))

        let detail = GitHubClient.pullRequestDetailQuery
        XCTAssertTrue(detail.contains("comments(last: 10)"))
        XCTAssertTrue(detail.contains("reviews(last: 10)"))
        XCTAssertTrue(detail.contains("commits(last: 20)"))
        XCTAssertTrue(detail.contains("latestOpinionatedReviews(first: 20)"))
        XCTAssertTrue(detail.contains("reviewThreads(first: 20)"))
        XCTAssertTrue(detail.contains("comments(last: 10)"))
        XCTAssertFalse(detail.contains("first: 100"))
        XCTAssertFalse(detail.contains("last: 100"))
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
          "reviewDecision": "REVIEW_REQUIRED",
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
          "author": { "login": "rw" }
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
        reviewCount: Int = 0
    ) -> PullRequest {
        PullRequest(
            id: "PR_1",
            title: "Ship dashboard",
            number: 12,
            url: URL(string: "https://github.com/acme/app/pull/12")!,
            repo: "acme/app",
            ciState: .passing,
            reviewDecision: .reviewRequired,
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
