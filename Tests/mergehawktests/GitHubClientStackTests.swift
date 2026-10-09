@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubClientStackTests: XCTestCase {
    override func tearDown() {
        StackURLProtocol.handler = nil
        super.tearDown()
    }

    func testTwoRequestedPRsInOneStackReadThatStackOnce() async throws {
        let first = Self.tracked(id: "PR_1", number: 1, reviewKind: .direct)
        let second = Self.tracked(id: "PR_2", number: 2, reviewKind: .direct)
        let recorder = StackRequestRecorder()
        Self.serve(previous: [first, second], recorder: recorder, nodes: [
            Self.completePR(id: first.id, number: 1, directRequest: true, stackID: "STACK_A"),
            Self.completePR(id: second.id, number: 2, directRequest: true, stackID: "STACK_A")
        ])

        let result = try await Self.client().fetchCompletePullRequests(login: "rw", previousState: Self.state([first, second]), reusableViewerTeams: nil)

        XCTAssertEqual(recorder.stackIDBatches, [["STACK_A"]])
        XCTAssertEqual(result.stacks.map(\.id), ["STACK_A"])
        XCTAssertEqual(result.stacks.first?.entries.map(\.pullRequestID), ["PR_1", "PR_2"])
        XCTAssertEqual(result.activePullRequests.map(\.stackID), ["STACK_A", "STACK_A"])
    }

    func testStacksReachedOnlyThroughAnAssignedOrATeamRequestedPRAreRead() async throws {
        let assigned = Self.tracked(id: "PR_ASSIGNED", number: 1, assigned: true)
        let team = Self.tracked(id: "PR_TEAM", number: 2, reviewKind: .team)
        let recorder = StackRequestRecorder()
        Self.serve(
            previous: [assigned, team],
            recorder: recorder,
            nodes: [
                Self.completePR(id: assigned.id, number: 1, assignees: ["rw"], stackID: "STACK_ASSIGNED"),
                Self.completePR(id: team.id, number: 2, teamRequest: true, stackID: "STACK_TEAM")
            ],
            teamRequestedIDs: [(team.id, team.number)]
        )

        let result = try await Self.client().fetchCompletePullRequests(login: "rw", previousState: Self.state([assigned, team]), reusableViewerTeams: nil)

        XCTAssertEqual(recorder.stackIDBatches, [["STACK_ASSIGNED", "STACK_TEAM"]])
        XCTAssertEqual(result.stacks.map(\.id), ["STACK_ASSIGNED", "STACK_TEAM"])
    }

    func testStackWhoseOnlyActiveMemberIsTheViewersOwnPRIsNotRead() async throws {
        let mine = Self.tracked(id: "PR_MINE", number: 1, isMine: true)
        let recorder = StackRequestRecorder()
        Self.serve(previous: [mine], recorder: recorder, nodes: [
            Self.completePR(id: mine.id, number: 1, author: "rw", stackID: "STACK_MINE")
        ])

        let result = try await Self.client().fetchCompletePullRequests(login: "rw", previousState: Self.state([mine]), reusableViewerTeams: nil)

        XCTAssertEqual(result.activePullRequests.map(\.id), [mine.id])
        XCTAssertTrue(recorder.stackIDBatches.isEmpty)
        XCTAssertEqual(result.stacks, [])
    }

    func testStackWhoseOnlyKnownMemberIsRetiringIsNotRead() async throws {
        let merged = Self.tracked(id: "PR_MERGED", number: 1, reviewKind: .direct)
        let recorder = StackRequestRecorder()
        Self.serve(previous: [merged], recorder: recorder, nodes: [
            Self.completePR(id: merged.id, number: 1, state: "MERGED", directRequest: true, stackID: "STACK_MERGED")
        ])

        let result = try await Self.client().fetchCompletePullRequests(login: "rw", previousState: Self.state([merged]), reusableViewerTeams: nil)

        XCTAssertEqual(result.retiringPullRequests.map(\.id), [merged.id])
        XCTAssertTrue(recorder.stackIDBatches.isEmpty)
        XCTAssertEqual(result.stacks, [])
    }

    func testRefreshWithoutStackedPRsMakesNoStackRequest() async throws {
        let direct = Self.tracked(id: "PR_DIRECT", number: 1, reviewKind: .direct)
        let recorder = StackRequestRecorder()
        Self.serve(previous: [direct], recorder: recorder, nodes: [
            Self.completePR(id: direct.id, number: 1, directRequest: true)
        ])

        let result = try await Self.client().fetchCompletePullRequests(login: "rw", previousState: Self.state([direct]), reusableViewerTeams: nil)

        XCTAssertEqual(result.activePullRequests.map(\.id), [direct.id])
        XCTAssertTrue(recorder.stackIDBatches.isEmpty)
        XCTAssertEqual(result.stacks, [])
    }

    func testStackReadFailureFailsTheCompletePRRefresh() async throws {
        let direct = Self.tracked(id: "PR_DIRECT", number: 1, reviewKind: .direct)
        let recorder = StackRequestRecorder()
        Self.serve(
            previous: [direct],
            recorder: recorder,
            nodes: [Self.completePR(id: direct.id, number: 1, directRequest: true, stackID: "STACK_A")],
            stackResponse: { _ in
                Self.json([
                    "data": ["nodes": [NSNull()]],
                    "errors": [["type": "FORBIDDEN", "message": "Resource not accessible", "path": ["nodes", 0]]]
                ])
            }
        )

        do {
            _ = try await Self.client().fetchCompletePullRequests(login: "rw", previousState: Self.state([direct]), reusableViewerTeams: nil)
            XCTFail("Expected the stack read failure to fail the complete PR refresh")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .accessDenied)
        }
        XCTAssertEqual(recorder.stackIDBatches, [["STACK_A"]])
    }

    func testReusableViewerTeamsSkipTheTeamReadAndAreReturnedAsGiven() async throws {
        let direct = Self.tracked(id: "PR_DIRECT", number: 1, reviewKind: .direct)
        let recorder = StackRequestRecorder()
        Self.serve(previous: [direct], recorder: recorder, nodes: [
            Self.completePR(id: direct.id, number: 1, directRequest: true)
        ])
        let stored = [
            ViewerTeam(team: TeamReference(id: "T_DEV", organization: "acme", slug: "developers")),
            ViewerTeam(team: TeamReference(id: "T_PLM", organization: "acme", slug: "plm"), parentTeamID: "T_DEV")
        ]

        let result = try await Self.client().fetchCompletePullRequests(
            login: "rw",
            previousState: Self.state([direct]),
            reusableViewerTeams: stored
        )

        XCTAssertEqual(recorder.teamQueries, [])
        XCTAssertEqual(result.viewerTeams, stored)
        XCTAssertEqual(result.activePullRequests.map(\.id), [direct.id])
    }

    func testMissingReusableViewerTeamsReadsTheViewersTeams() async throws {
        let direct = Self.tracked(id: "PR_DIRECT", number: 1, reviewKind: .direct)
        let recorder = StackRequestRecorder()
        Self.serve(previous: [direct], recorder: recorder, nodes: [
            Self.completePR(id: direct.id, number: 1, directRequest: true)
        ])

        let result = try await Self.client().fetchCompletePullRequests(
            login: "rw",
            previousState: Self.state([direct]),
            reusableViewerTeams: nil
        )

        XCTAssertEqual(recorder.teamQueries, ["ViewerTeams"])
        XCTAssertEqual(result.viewerTeams, [])
    }

    // MARK: - Fixtures

    /// Serves an empty discovery, so every tracked PR is rechecked through absent hydration.
    private static func serve(
        previous: [PullRequest],
        recorder: StackRequestRecorder,
        nodes: [[String: Any]],
        teamRequestedIDs: [(id: String, number: Int)] = [],
        stackResponse: (([String]) -> Data)? = nil
    ) {
        let entriesByStack = Dictionary(grouping: nodes.compactMap { node -> (String, [String: Any])? in
            guard let stack = node["stack"] as? [String: Any], let id = stack["id"] as? String else { return nil }
            return (id, node)
        }, by: \.0).mapValues { $0.map(\.1) }
        StackURLProtocol.handler = { request in
            let query = graphQLQuery(request)
            if query.contains("query OrganizationViewerTeams") {
                recorder.recordTeamQuery("OrganizationViewerTeams")
                XCTFail("Unexpected organization team page")
                return response(Data(), request, status: 500)
            }
            if query.contains("query ViewerTeams") {
                recorder.recordTeamQuery("ViewerTeams")
                return response(viewerTeams(), request)
            }
            if query.contains("DiscoveryBounds") { return response(emptyBounds(), request) }
            if query.contains("DiscoverPullRequests") { return response(emptyDiscovery(), request) }
            if query.contains("CompletePullRequests") {
                let ids = graphQLVariables(request)["ids"] as? [String] ?? []
                let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0["id"] as! String, $0) })
                return response(json(["data": ["nodes": ids.map { byID[$0] as Any? ?? NSNull() }]]), request)
            }
            if query.contains("SearchPullRequests") {
                let searchQuery = graphQLVariables(request)["query"] as? String ?? ""
                let matches = teamRequestedIDs.enumerated().map { index, value in
                    discoveryNode(id: value.id, number: value.number, second: index)
                }
                let page = searchQuery.contains("sort:created-asc")
                    ? Array(matches.prefix(1))
                    : searchQuery.contains("sort:created-desc") ? Array(matches.suffix(1)) : matches
                return response(repositoryTeamPage(page), request)
            }
            if query.contains("PullRequestStacks") {
                let ids = graphQLVariables(request)["ids"] as? [String] ?? []
                recorder.record(ids)
                if let stackResponse { return response(stackResponse(ids), request) }
                return response(json(["data": ["nodes": ids.map { id in
                    let members = entriesByStack[id] ?? []
                    return [
                        "id": id,
                        "size": members.count,
                        "entries": [
                            "totalCount": members.count,
                            "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
                            "nodes": members.enumerated().map { index, member in
                                [
                                    "position": index + 1,
                                    "pullRequest": [
                                        "id": member["id"]!, "number": member["number"]!, "title": member["title"]!,
                                        "url": member["url"]!, "state": member["state"]!, "isDraft": false,
                                        "author": member["author"]!
                                    ]
                                ] as [String: Any]
                            }
                        ] as [String: Any]
                    ] as [String: Any]
                }]]), request)
            }
            XCTFail("Unexpected query \(query.prefix(80))")
            return response(Data(), request, status: 500)
        }
    }

    private static func client() -> GitHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StackURLProtocol.self]
        return GitHubClient(token: "token", session: URLSession(configuration: configuration))
    }

    private static func tracked(
        id: String,
        number: Int,
        isMine: Bool = false,
        assigned: Bool = false,
        reviewKind: ReviewRequestKind = .none
    ) -> PullRequest {
        PullRequest(
            id: id, title: "Tracked PR", number: number,
            url: URL(string: "https://github.com/acme/app/pull/\(number)")!, repo: "acme/app",
            ciState: .passing, reviewDecision: .reviewRequired,
            commentCount: 0, reviewCount: 0,
            reviewRequestKind: reviewKind, isAssignedToViewer: assigned,
            isMine: isMine, author: isMine ? "rw" : "author", mergeable: .mergeable, draft: false
        )
    }

    private static func state(_ pullRequests: [PullRequest]) -> PullRequestSyncState {
        PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: DashboardState(
                pullRequests: pullRequests, events: [], syncedAt: Date(), source: .github,
                account: GitHubAccount(login: "rw"), authStatus: .signedIn
            ),
            processedActivityByPullRequestID: Dictionary(uniqueKeysWithValues: pullRequests.map {
                ($0.id, ProcessedPullRequestActivity(pullRequestID: $0.id))
            })
        )
    }

    private static func completePR(
        id: String,
        number: Int,
        state: String = "OPEN",
        author: String = "author",
        assignees: [String] = [],
        directRequest: Bool = false,
        teamRequest: Bool = false,
        stackID: String? = nil
    ) -> [String: Any] {
        var requests: [[String: Any]] = []
        if directRequest {
            requests.append(["id": "DIRECT_\(id)", "requestedReviewer": ["__typename": "User", "id": "U_RW", "login": "rw"]])
        }
        if teamRequest {
            requests.append([
                "id": "TEAM_\(id)",
                "requestedReviewer": [
                    "__typename": "Team", "id": "T_TEAM", "slug": "developers", "organization": ["login": "acme"]
                ]
            ])
        }
        return [
            "id": id, "title": "Tracked PR \(number)", "number": number,
            "url": "https://github.com/acme/app/pull/\(number)", "state": state,
            "createdAt": "1970-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
            "headRefName": "feature-\(number)", "headRefOid": "abc", "isDraft": false,
            "mergeable": "MERGEABLE", "additions": 1, "deletions": 1,
            "statusCheckRollup": ["state": "SUCCESS"],
            "author": ["id": "U_\(author)", "login": author],
            "repository": ["nameWithOwner": "acme/app", "isArchived": false],
            "stack": stackID.map { ["id": $0] as Any } ?? NSNull(),
            "comments": connection([]), "reviews": connection([]),
            "latestOpinionatedReviews": connection([]), "reviewThreads": connection([]),
            "assignees": connection(assignees.map { ["id": "U_\($0)", "login": $0] }),
            "reviewRequests": connection(requests)
        ]
    }

    private static func viewerTeams() -> Data {
        json(["data": ["viewer": ["organizations": [
            "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
            "nodes": [["login": "acme", "teams": ["pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": []]]]
        ]]]])
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
                "pageInfo": ["startCursor": NSNull(), "endCursor": NSNull(), "hasPreviousPage": false, "hasNextPage": false]
            ]
        }
        return json(["data": object])
    }

    private static func discoveryNode(id: String, number: Int, second: Int) -> [String: Any] {
        [
            "id": id, "number": number,
            "createdAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(second))),
            "repository": ["nameWithOwner": "acme/app"]
        ]
    }

    private static func repositoryTeamPage(_ nodes: [[String: Any]]) -> Data {
        json(["data": ["search": [
            "issueCount": nodes.count, "nodes": nodes,
            "pageInfo": ["startCursor": NSNull(), "endCursor": NSNull(), "hasPreviousPage": false, "hasNextPage": false]
        ]]])
    }

    private static func connection(_ nodes: [[String: Any]]) -> [String: Any] {
        [
            "totalCount": nodes.count, "nodes": nodes,
            "pageInfo": ["startCursor": NSNull(), "endCursor": NSNull(), "hasPreviousPage": false, "hasNextPage": false]
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
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
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

    private static func response(_ data: Data, _ request: URLRequest, status: Int = 200) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private static func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }
}

private final class StackURLProtocol: URLProtocol {
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

private final class StackRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[String]] = []
    private var teamQueryNames: [String] = []
    var stackIDBatches: [[String]] { lock.withLock { batches } }
    var teamQueries: [String] { lock.withLock { teamQueryNames } }
    func record(_ ids: [String]) { lock.withLock { batches.append(ids) } }
    func recordTeamQuery(_ name: String) { lock.withLock { teamQueryNames.append(name) } }
}
