@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubRetirementTests: XCTestCase {
    override func tearDown() {
        RetirementURLProtocol.handler = nil
        super.tearDown()
    }

    func testMergedPRGetsFinalCommentAndReviewBeforeRetirement() async throws {
        let previousPR = Self.previousPR()
        let previous = Self.previousState(previousPR)
        RetirementURLProtocol.handler = { request in
            let query = Self.graphQLQuery(request)
            if query.contains("DiscoveryBounds") { return Self.response(Self.emptyBounds(), request) }
            if query.contains("DiscoverPullRequests") { return Self.response(Self.emptyDiscovery(), request) }
            if query.contains("CompletePullRequests") {
                return Self.response(Self.hydration(nodes: [
                    Self.completePR(
                        state: "MERGED",
                        comments: [Self.comment("FINAL_COMMENT")],
                        reviews: [Self.review("FINAL_REVIEW")]
                    )
                ]), request)
            }
            XCTFail("Unexpected request: \(request) query=\(query.prefix(80))")
            return Self.response(Data(), request, status: 500)
        }
        let client = GitHubClient(token: "token", session: Self.session())

        let result = try await client.fetchCompletePullRequests(login: "rw", previousState: previous)

        XCTAssertTrue(result.activePullRequests.isEmpty)
        XCTAssertEqual(result.retiringPullRequests.map(\.id), [previousPR.id])
        let prepared = try await SyncEngine(
            source: client,
            loginProvider: { "rw" },
            accountProvider: { GitHubAccount(login: "rw") }
        ).prepare(previousState: previous, fetchResult: result)
        XCTAssertEqual(Set(prepared.events.map(\.event.type)), [.newComment, .reviewApproved])
    }

    func testAbsentButStillAuthoredOpenPRRemainsActive() async throws {
        let previous = Self.previousState(Self.previousPR())
        RetirementURLProtocol.handler = { request in
            let query = Self.graphQLQuery(request)
            if query.contains("DiscoveryBounds") { return Self.response(Self.emptyBounds(), request) }
            if query.contains("DiscoverPullRequests") { return Self.response(Self.emptyDiscovery(), request) }
            if query.contains("CompletePullRequests") {
                return Self.response(Self.hydration(nodes: [Self.completePR(state: "OPEN")]), request)
            }
            return Self.response(Data(), request, status: 500)
        }

        let result = try await GitHubClient(token: "token", session: Self.session())
            .fetchCompletePullRequests(login: "rw", previousState: previous)

        XCTAssertEqual(result.activePullRequests.map(\.id), ["PR_1"])
        XCTAssertTrue(result.retiringPullRequests.isEmpty)
    }

    func testResource404RequiresFreshMatchingViewerBeforeQuietRetirement() async throws {
        let previous = Self.previousState(Self.previousPR())
        var requestedPaths: [String] = []
        RetirementURLProtocol.handler = { request in
            requestedPaths.append(request.url!.path)
            if request.url?.host == "api.github.com", request.url?.path == "/repos/acme/app/pulls/1" {
                return Self.response(Self.json(["message": "Not Found"]), request, status: 404)
            }
            if request.url?.path == "/user" {
                return Self.response(Self.json(["login": "rw"]), request)
            }
            let query = Self.graphQLQuery(request)
            if query.contains("DiscoveryBounds") { return Self.response(Self.emptyBounds(), request) }
            if query.contains("DiscoverPullRequests") { return Self.response(Self.emptyDiscovery(), request) }
            if query.contains("CompletePullRequests") {
                return Self.response(Self.hydration(nodes: [NSNull()]), request)
            }
            return Self.response(Data(), request, status: 500)
        }

        let result = try await GitHubClient(token: "token", session: Self.session())
            .fetchCompletePullRequests(login: "rw", previousState: previous)

        XCTAssertEqual(result.quietlyRetiredPullRequestIDs, ["PR_1"])
        XCTAssertEqual(requestedPaths.filter { $0 == "/user" }.count, 1)
    }

    func testViewerMismatchDoesNotMasqueradeAsRetirement() async throws {
        let previous = Self.previousState(Self.previousPR())
        RetirementURLProtocol.handler = { request in
            if request.url?.path == "/repos/acme/app/pulls/1" {
                return Self.response(Self.json(["message": "Not Found"]), request, status: 404)
            }
            if request.url?.path == "/user" {
                return Self.response(Self.json(["login": "someone-else"]), request)
            }
            let query = Self.graphQLQuery(request)
            if query.contains("DiscoveryBounds") { return Self.response(Self.emptyBounds(), request) }
            if query.contains("DiscoverPullRequests") { return Self.response(Self.emptyDiscovery(), request) }
            if query.contains("CompletePullRequests") {
                return Self.response(Self.hydration(nodes: [NSNull()]), request)
            }
            return Self.response(Data(), request, status: 500)
        }

        do {
            _ = try await GitHubClient(token: "token", session: Self.session())
                .fetchCompletePullRequests(login: "rw", previousState: previous)
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .authentication)
        }
    }

    private static func previousPR() -> PullRequest {
        PullRequest(
            id: "PR_1", title: "Tracked PR", number: 1,
            url: URL(string: "https://github.com/acme/app/pull/1")!, repo: "acme/app",
            ciState: .passing, reviewDecision: .noReviewYet,
            commentCount: 0, reviewCount: 0,
            isMine: true, author: "rw", mergeable: .mergeable, draft: false,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func previousState(_ pullRequest: PullRequest) -> PullRequestSyncState {
        PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: DashboardState(
                pullRequests: [pullRequest], events: [], syncedAt: Date(), source: .github,
                account: GitHubAccount(login: "rw"), authStatus: .signedIn
            ),
            processedActivityByPullRequestID: [
                pullRequest.id: ProcessedPullRequestActivity(pullRequestID: pullRequest.id)
            ],
            notificationHistory: [
                PullRequestNotification(
                    event: PullRequestEvent(type: .ciFailed, prId: pullRequest.id),
                    pullRequest: pullRequest,
                    read: true
                )
            ]
        )
    }

    private static func emptyBounds() -> Data {
        var object: [String: Any] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            object["\(lane.rawValue)Oldest"] = ["nodes": []]
            object["\(lane.rawValue)Newest"] = ["nodes": []]
        }
        return json(["data": object])
    }

    private static func emptyDiscovery() -> Data {
        var object: [String: Any] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            object[lane.rawValue] = [
                "issueCount": 0, "nodes": [],
                "pageInfo": [
                    "startCursor": NSNull(), "endCursor": NSNull(),
                    "hasPreviousPage": false, "hasNextPage": false
                ]
            ]
        }
        return json(["data": object])
    }

    private static func hydration(nodes: [Any]) -> Data {
        json(["data": ["nodes": nodes]])
    }

    private static func completePR(
        state: String,
        comments: [[String: Any]] = [],
        reviews: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "id": "PR_1", "title": "Tracked PR", "number": 1,
            "url": "https://github.com/acme/app/pull/1", "state": state,
            "createdAt": "1970-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
            "headRefName": "feature", "headRefOid": "abc", "isDraft": false,
            "mergeable": "MERGEABLE", "additions": 1, "deletions": 1,
            "statusCheckRollup": ["state": "SUCCESS"],
            "author": ["id": "U_RW", "login": "rw"],
            "repository": ["nameWithOwner": "acme/app"],
            "comments": connection(comments), "reviews": connection(reviews),
            "latestOpinionatedReviews": connection([]), "reviewThreads": connection([]),
            "assignees": connection([]), "reviewRequests": connection([])
        ]
    }

    private static func connection(_ nodes: [[String: Any]]) -> [String: Any] {
        [
            "totalCount": nodes.count, "nodes": nodes,
            "pageInfo": [
                "startCursor": NSNull(), "endCursor": NSNull(),
                "hasPreviousPage": false, "hasNextPage": false
            ]
        ]
    }

    private static func comment(_ id: String) -> [String: Any] {
        [
            "id": id, "createdAt": "2026-01-01T00:00:00Z", "viewerDidAuthor": false,
            "author": ["id": "U_REVIEWER", "login": "reviewer"], "pullRequestReview": NSNull()
        ]
    }

    private static func review(_ id: String) -> [String: Any] {
        [
            "id": id, "state": "APPROVED", "submittedAt": "2026-01-01T00:00:00Z",
            "viewerDidAuthor": false, "author": ["id": "U_REVIEWER", "login": "reviewer"]
        ]
    }

    private static func graphQLQuery(_ request: URLRequest) -> String {
        guard request.url?.path == "/graphql", let body = requestBody(request),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return "" }
        return json["query"] as? String ?? ""
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
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
        return data
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetirementURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        _ data: Data,
        _ request: URLRequest,
        status: Int = 200
    ) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private static func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }
}

private final class RetirementURLProtocol: URLProtocol {
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
