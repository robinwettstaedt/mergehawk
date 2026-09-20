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

    func testResource404And410RequireFreshMatchingViewerBeforeQuietRetirement() async throws {
        for status in [404, 410] {
            let previous = Self.previousState(Self.previousPR())
            var requestedPaths: [String] = []
            RetirementURLProtocol.handler = { request in
                requestedPaths.append(request.url!.path)
                if request.url?.host == "api.github.com", request.url?.path == "/repos/acme/app/pulls/1" {
                    return Self.response(Self.json(["message": "Gone"]), request, status: status)
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

    func testAbsentAssignedDirectAndSharedTeamPRsRemainActive() async throws {
        let assigned = Self.previousPR(id: "PR_ASSIGNED", number: 1, isMine: false, assigned: true)
        let direct = Self.previousPR(id: "PR_DIRECT", number: 2, isMine: false, reviewKind: .direct)
        let teamOne = Self.previousPR(id: "PR_TEAM_1", number: 3, isMine: false, reviewKind: .team)
        let teamTwo = Self.previousPR(id: "PR_TEAM_2", number: 4, isMine: false, reviewKind: .team)
        let previous = Self.previousState([assigned, direct, teamOne, teamTwo])
        let teamQueries = LockedRetirementCounter()
        RetirementURLProtocol.handler = { request in
            let query = Self.graphQLQuery(request)
            if query.contains("DiscoveryBounds") { return Self.response(Self.emptyBounds(), request) }
            if query.contains("DiscoverPullRequests") { return Self.response(Self.emptyDiscovery(), request) }
            if query.contains("CompletePullRequests") {
                return Self.response(Self.hydration(nodes: [
                    Self.completePR(id: assigned.id, number: assigned.number, state: "OPEN", author: "author", assignees: ["rw"]),
                    Self.completePR(id: direct.id, number: direct.number, state: "OPEN", author: "author", directRequest: true),
                    Self.completePR(id: teamOne.id, number: teamOne.number, state: "OPEN", author: "author", teamRequest: true),
                    Self.completePR(id: teamTwo.id, number: teamTwo.number, state: "OPEN", author: "author", teamRequest: true)
                ]), request)
            }
            if query.contains("RepositoryTeamMembership") {
                teamQueries.increment()
                let queryValue = Self.graphQLVariables(request)["query"] as? String ?? ""
                let nodes = queryValue.contains("sort:created-asc")
                    ? [Self.discoveryNode(id: teamOne.id, number: teamOne.number, second: 0)]
                    : queryValue.contains("sort:created-desc")
                        ? [Self.discoveryNode(id: teamTwo.id, number: teamTwo.number, second: 1)]
                        : [
                            Self.discoveryNode(id: teamOne.id, number: teamOne.number, second: 0),
                            Self.discoveryNode(id: teamTwo.id, number: teamTwo.number, second: 1)
                        ]
                return Self.response(Self.repositoryTeamPage(nodes), request)
            }
            return Self.response(Data(), request, status: 500)
        }

        let result = try await GitHubClient(token: "token", session: Self.session())
            .fetchCompletePullRequests(login: "rw", previousState: previous)

        XCTAssertEqual(Set(result.activePullRequests.map(\.id)), Set(previous.dashboard.pullRequests.map(\.id)))
        XCTAssertEqual(teamQueries.value, 3)
    }

    func testHydratedTeamRequestsRequireSharedRepositoryConfirmationWhenDiscoveryDidNotProveMembership() async throws {
        let keep = Self.discoveryNode(id: "PR_TEAM_KEEP", number: 1, second: 0)
        let unrelated = Self.discoveryNode(id: "PR_TEAM_OTHER", number: 2, second: 1)
        let directAndTeam = Self.discoveryNode(id: "PR_DIRECT_TEAM", number: 3, second: 2)
        let teamQueries = LockedRetirementCounter()
        RetirementURLProtocol.handler = { request in
            let query = Self.graphQLQuery(request)
            if query.contains("DiscoveryBounds") {
                var data: [String: Any] = [:]
                for lane in GitHubDiscoveryLane.allCases {
                    let nodes: [[String: Any]] = switch lane {
                    case .assigned: [keep, unrelated]
                    case .direct: [directAndTeam]
                    case .authored, .team: []
                    }
                    data["\(lane.rawValue)Oldest"] = ["nodes": Array(nodes.prefix(1))]
                    data["\(lane.rawValue)Newest"] = ["nodes": Array(nodes.suffix(1))]
                }
                return Self.response(Self.json(["data": data]), request)
            }
            if query.contains("DiscoverPullRequests") {
                var data: [String: Any] = [:]
                for lane in GitHubDiscoveryLane.allCases {
                    let nodes: [[String: Any]] = switch lane {
                    case .assigned: [keep, unrelated]
                    case .direct: [directAndTeam]
                    case .authored, .team: []
                    }
                    data[lane.rawValue] = [
                        "issueCount": nodes.count,
                        "nodes": nodes,
                        "pageInfo": [
                            "startCursor": NSNull(), "endCursor": NSNull(),
                            "hasPreviousPage": false, "hasNextPage": false
                        ]
                    ]
                }
                return Self.response(Self.json(["data": data]), request)
            }
            if query.contains("CompletePullRequests") {
                return Self.response(Self.hydration(nodes: [
                    Self.completePR(
                        id: "PR_DIRECT_TEAM", number: 3, state: "OPEN",
                        author: "author", directRequest: true, teamRequest: true
                    ),
                    Self.completePR(
                        id: "PR_TEAM_KEEP", number: 1, state: "OPEN",
                        author: "author", teamRequest: true
                    ),
                    Self.completePR(
                        id: "PR_TEAM_OTHER", number: 2, state: "OPEN",
                        author: "author", teamRequest: true
                    )
                ]), request)
            }
            if query.contains("RepositoryTeamMembership") {
                teamQueries.increment()
                let queryValue = Self.graphQLVariables(request)["query"] as? String ?? ""
                let nodes = queryValue.contains("sort:created-asc")
                    ? [keep]
                    : queryValue.contains("sort:created-desc")
                        ? [directAndTeam]
                        : [keep, directAndTeam]
                return Self.response(Self.repositoryTeamPage(nodes), request)
            }
            return Self.response(Data(), request, status: 500)
        }

        let result = try await GitHubClient(token: "token", session: Self.session())
            .fetchCompletePullRequests(login: "rw", previousState: nil)

        XCTAssertEqual(result.activePullRequests.map(\.id), ["PR_DIRECT_TEAM", "PR_TEAM_KEEP"])
        XCTAssertEqual(
            result.activePullRequests.first { $0.id == "PR_TEAM_KEEP" }?.reviewRequestKind,
            .team
        )
        XCTAssertEqual(
            result.activePullRequests.first { $0.id == "PR_DIRECT_TEAM" }?.reviewRequestKind,
            .directAndTeam
        )
        XCTAssertFalse(result.activePullRequests.contains { $0.id == "PR_TEAM_OTHER" })
        XCTAssertEqual(teamQueries.value, 3)
    }

    func testAmbiguousForbiddenRateLimitAndServerFailureNeverRetireQuietly() async throws {
        for scenario in ["ambiguous", "rate", "server"] {
            let previous = Self.previousState(Self.previousPR())
            RetirementURLProtocol.handler = { request in
                if request.url?.path == "/repos/acme/app/pulls/1" {
                    switch scenario {
                    case "rate":
                        return Self.response(
                            Self.json(["message": "rate limited"]),
                            request,
                            status: 403,
                            headers: ["X-RateLimit-Remaining": "0", "Retry-After": "60"]
                        )
                    case "server":
                        return Self.response(Self.json(["message": "failed"]), request, status: 500)
                    default:
                        return Self.response(Self.json(["message": "Forbidden"]), request, status: 403)
                    }
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
                XCTFail("Expected \(scenario) failure")
            } catch let error as GitHubReadError {
                switch scenario {
                case "rate":
                    guard case .rateLimited(let retryAt) = error else { return XCTFail("Unexpected \(error)") }
                    XCTAssertNotNil(retryAt)
                case "server": XCTAssertEqual(error, .http(status: 500))
                default: XCTAssertEqual(error, .http(status: 403))
                }
            }
        }
    }

    private static func previousPR(
        id: String = "PR_1",
        number: Int = 1,
        isMine: Bool = true,
        assigned: Bool = false,
        reviewKind: ReviewRequestKind = .none
    ) -> PullRequest {
        PullRequest(
            id: id, title: "Tracked PR", number: number,
            url: URL(string: "https://github.com/acme/app/pull/\(number)")!, repo: "acme/app",
            ciState: .passing, reviewDecision: .noReviewYet,
            commentCount: 0, reviewCount: 0,
            reviewRequestKind: reviewKind, isAssignedToViewer: assigned,
            isMine: isMine, author: isMine ? "rw" : "author", mergeable: .mergeable, draft: false,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func previousState(_ pullRequest: PullRequest) -> PullRequestSyncState {
        previousState([pullRequest])
    }

    private static func previousState(_ pullRequests: [PullRequest]) -> PullRequestSyncState {
        PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: DashboardState(
                pullRequests: pullRequests, events: [], syncedAt: Date(), source: .github,
                account: GitHubAccount(login: "rw"), authStatus: .signedIn
            ),
            processedActivityByPullRequestID: Dictionary(uniqueKeysWithValues: pullRequests.map {
                ($0.id, ProcessedPullRequestActivity(pullRequestID: $0.id))
            }),
            notificationHistory: []
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
        id: String = "PR_1",
        number: Int = 1,
        state: String,
        author: String = "rw",
        assignees: [String] = [],
        directRequest: Bool = false,
        teamRequest: Bool = false,
        comments: [[String: Any]] = [],
        reviews: [[String: Any]] = []
    ) -> [String: Any] {
        var requests: [[String: Any]] = []
        if directRequest {
            requests.append([
                "id": "DIRECT_\(id)",
                "requestedReviewer": ["__typename": "User", "id": "U_RW", "login": "rw"]
            ])
        }
        if teamRequest {
            requests.append([
                "id": "TEAM_\(id)",
                "requestedReviewer": [
                    "__typename": "Team", "id": "T_TEAM", "slug": "developers",
                    "organization": ["login": "acme"]
                ]
            ])
        }
        return [
            "id": id, "title": "Tracked PR", "number": number,
            "url": "https://github.com/acme/app/pull/\(number)", "state": state,
            "createdAt": "1970-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
            "headRefName": "feature", "headRefOid": "abc", "isDraft": false,
            "mergeable": "MERGEABLE", "additions": 1, "deletions": 1,
            "statusCheckRollup": ["state": "SUCCESS"],
            "author": ["id": "U_\(author)", "login": author],
            "repository": ["nameWithOwner": "acme/app"],
            "comments": connection(comments), "reviews": connection(reviews),
            "latestOpinionatedReviews": connection([]), "reviewThreads": connection([]),
            "assignees": connection(assignees.map { ["id": "U_\($0)", "login": $0] }),
            "reviewRequests": connection(requests)
        ]
    }

    private static func discoveryNode(id: String, number: Int, second: Int) -> [String: Any] {
        [
            "id": id,
            "number": number,
            "createdAt": ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: TimeInterval(second))
            ),
            "repository": ["nameWithOwner": "acme/app"]
        ]
    }

    private static func repositoryTeamPage(_ nodes: [[String: Any]]) -> Data {
        json(["data": ["search": [
            "issueCount": nodes.count,
            "nodes": nodes,
            "pageInfo": [
                "startCursor": NSNull(), "endCursor": NSNull(),
                "hasPreviousPage": false, "hasNextPage": false
            ]
        ]]])
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

    private static func graphQLVariables(_ request: URLRequest) -> [String: Any] {
        guard let body = requestBody(request),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [:]
        }
        return json["variables"] as? [String: Any] ?? [:]
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
        status: Int = 200,
        headers: [String: String]? = nil
    ) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
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

private final class LockedRetirementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}
