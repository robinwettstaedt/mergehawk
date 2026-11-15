@testable import mergehawkcore
import CryptoKit
import Foundation
import XCTest

/// A complete PR refresh through `GitHubClient` against a fixture that answers purely from request content. The
/// pinned hashes and GraphQL request counts were recorded from the serial read, so a hash mismatch means the
/// refresh result changed for the same GitHub data.
final class RefreshGoldenTests: XCTestCase {
    override func tearDown() {
        RefreshGoldenURLProtocol.handler = nil
        super.tearDown()
    }

    func testSteadyStateRefreshMatchesTheSerialRead() async throws {
        let outcome = try await RefreshGoldenFixture(includesNewPullRequests: false).refresh(reusesViewerTeams: false)

        Self.assertCoverage(outcome.result, newPullRequests: false)
        // The serial read's hash and count. Known PRs hydrate in one set of batches, one fewer than the serial
        // read's discovered and dropped-out sets, and continuation rounds add one.
        XCTAssertEqual(outcome.hash, "584baa0120cb6208b708e50c1f84920d5c3200cd1cad42e5d3ac4cc50155b3c9")
        XCTAssertEqual(outcome.graphQLRequests, 19)
    }

    func testRefreshWithNewPullRequestsMatchesTheSerialRead() async throws {
        let outcome = try await RefreshGoldenFixture(includesNewPullRequests: true).refresh(reusesViewerTeams: false)

        Self.assertCoverage(outcome.result, newPullRequests: true)
        // The serial read's hash. Continuation rounds add one request to the serial read's 19.
        XCTAssertEqual(outcome.hash, "5ed4265fca4d5c585fbdd6b0762806aa97a0c612da41217590d758aadf590396")
        XCTAssertEqual(outcome.graphQLRequests, 20)
    }

    func testSteadyStateRefreshWithReusedViewerTeamsSendsNoTeamsRead() async throws {
        let outcome = try await RefreshGoldenFixture(includesNewPullRequests: false).refresh(reusesViewerTeams: true)

        XCTAssertFalse(outcome.queryNames.contains("ViewerTeams"))
        XCTAssertEqual(outcome.result.viewerTeams, [RefreshGoldenFixture.viewerTeam])
        // The serial read's count, as in the steady state with teams read.
        XCTAssertEqual(outcome.graphQLRequests, 18)
    }

    /// The fixture's cases each reach the result: the rechecked team PR stays active, the merged PR retires, the
    /// 404 PR retires quietly, both stacks are read, and the deleted thread and restarted thread list leave
    /// complete activity.
    private static func assertCoverage(
        _ result: CompletePullRequestFetchResult,
        newPullRequests: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let active = Dictionary(uniqueKeysWithValues: result.activePullRequests.map { ($0.id, $0) })
        XCTAssertEqual(active.count, newPullRequests ? 51 : 46, file: file, line: line)
        XCTAssertEqual(active["D_TEAM"]?.reviewRequestKind, .team, file: file, line: line)
        XCTAssertEqual(result.retiringPullRequests.map(\.id), ["D_MERGED"], file: file, line: line)
        XCTAssertEqual(result.quietlyRetiredPullRequestIDs, ["D_GONE"], file: file, line: line)
        XCTAssertEqual(result.stacks.map(\.id), ["STACK_A", "STACK_B"], file: file, line: line)
        XCTAssertEqual(active["K05"]?.commentActivityCount, 105, file: file, line: line)
        XCTAssertEqual(active["K07"]?.commentActivityCount, 2, file: file, line: line)
        XCTAssertEqual(active["K01"]?.reviewCount, 12, file: file, line: line)
    }
}

/// Known PRs K00–K44 (authored, directly requested and team requested), new PRs N0–N4 (assigned) in one
/// variant, and three PRs that dropped out of discovery: D_TEAM (open, with a team request that needs a
/// repository recheck), D_GONE (404, retires quietly) and D_MERGED (merged, retiring). K01 pages its comments and
/// reviews, K03 pages its threads' comments, K05's thread list restarts and K07 lists a thread that was deleted.
/// K30 and K31 share a stack, K40 has its own.
struct RefreshGoldenFixture {
    struct Outcome {
        let result: CompletePullRequestFetchResult
        let hash: String
        let graphQLRequests: Int
        let queryNames: [String]
    }

    private typealias Fixtures = GitHubPaginationTests

    static let viewerTeam = ViewerTeam(team: TeamReference(id: "T_DEV", organization: "acme", slug: "developers"))

    let includesNewPullRequests: Bool

    private struct Spec {
        let id: String
        let number: Int
        let repo: String
        let author: String
        let lane: GitHubDiscoveryLane?
        let second: Int
    }

    private var known: [Spec] {
        (0..<45).map { index in
            let lane: GitHubDiscoveryLane = index < 30 ? .authored : index < 40 ? .direct : .team
            return Spec(
                id: String(format: "K%02d", index), number: 100 + index, repo: "acme/app",
                author: lane == .authored ? "rw" : "teammate", lane: lane, second: 1_000 + index
            )
        }
    }

    private var new: [Spec] {
        guard includesNewPullRequests else { return [] }
        return (0..<5).map { index in
            Spec(id: "N\(index)", number: 200 + index, repo: "acme/app", author: "teammate", lane: .assigned, second: 2_000 + index)
        }
    }

    private let droppedTeam = Spec(id: "D_TEAM", number: 7, repo: "acme/teamrepo", author: "teammate", lane: nil, second: 10)
    private let droppedGone = Spec(id: "D_GONE", number: 8, repo: "acme/app", author: "rw", lane: nil, second: 11)
    private let droppedMerged = Spec(id: "D_MERGED", number: 9, repo: "acme/app", author: "rw", lane: nil, second: 12)

    var previousState: PullRequestSyncState {
        let pullRequests = known.map(previousPullRequest) + [droppedTeam, droppedGone, droppedMerged].map(previousPullRequest)
        return PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: DashboardState(
                pullRequests: pullRequests, events: [], syncedAt: Date(timeIntervalSince1970: 0), source: .github,
                account: GitHubAccount(login: "rw"), authStatus: .signedIn
            ),
            processedActivityByPullRequestID: Dictionary(uniqueKeysWithValues: pullRequests.map {
                ($0.id, ProcessedPullRequestActivity(pullRequestID: $0.id))
            })
        )
    }

    /// Runs one complete PR refresh and records every GraphQL request's query name.
    func refresh(reusesViewerTeams: Bool) async throws -> Outcome {
        let server = makeServer()
        let queryNames = LockedBox<[String]>([])
        let discovered = known + new
        RefreshGoldenURLProtocol.handler = { request in
            try respond(to: request, server: server, discovered: discovered, queryNames: queryNames)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshGoldenURLProtocol.self]
        let client = GitHubClient(token: "token", session: URLSession(configuration: configuration))
        let result = try await client.fetchCompletePullRequests(
            login: "rw",
            previousState: previousState,
            reusableViewerTeams: reusesViewerTeams ? [Self.viewerTeam] : nil
        )
        return Outcome(
            result: result,
            hash: try Self.hash(result),
            graphQLRequests: queryNames.value.count,
            queryNames: queryNames.value
        )
    }

    /// The trusted previous state's PRs as the client passes them to `readRefresh`.
    var knownIdentities: [DiscoveredPullRequest] {
        previousState.dashboard.pullRequests.map { pullRequest in
            DiscoveredPullRequest(
                id: pullRequest.id,
                repository: pullRequest.repo,
                number: pullRequest.number,
                createdAt: pullRequest.createdAt,
                isAuthored: pullRequest.isMine,
                isAssigned: pullRequest.isAssignedToViewer,
                isDirectlyRequested: pullRequest.reviewRequestKind.includesDirect,
                isTeamRequested: pullRequest.reviewRequestKind.includesTeam
            )
        }
    }

    /// A fetcher-level transport answering the fixture's GraphQL queries from their content.
    func graphQLTransport() -> @Sendable (String, [String: GitHubQueryValue]) throws -> Data {
        let server = makeServer()
        let discovered = known + new
        return { query, variables in
            try answerGraphQL(query: query, variables: variables, server: server, discovered: discovered)
        }
    }

    /// Hashes the active and retiring PRs, quietly retired IDs, viewer teams and stacks.
    static func hash(_ result: CompletePullRequestFetchResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        data += try GitHubHydrationGoldenTests.normalizedJSON(result.activePullRequests)
        data += Data("|".utf8)
        data += try GitHubHydrationGoldenTests.normalizedJSON(result.retiringPullRequests)
        data += Data("|\(result.quietlyRetiredPullRequestIDs.sorted())|".utf8)
        data += try encoder.encode(result.viewerTeams)
        data += Data("|".utf8)
        data += try encoder.encode(result.stacks)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Data

    private func previousPullRequest(_ spec: Spec) -> PullRequest {
        let kind: ReviewRequestKind = switch spec.lane {
        case .direct: .direct
        case .team: .team
        case nil where spec.id == droppedTeam.id: .team
        default: .none
        }
        return PullRequest(
            id: spec.id, title: "Previous \(spec.id)", number: spec.number,
            url: URL(string: "https://github.com/\(spec.repo)/pull/\(spec.number)")!, repo: spec.repo,
            ciState: .passing, reviewDecision: .reviewRequired,
            commentCount: 0, reviewCount: 0,
            reviewRequestKind: kind, isAssignedToViewer: false,
            isMine: spec.author == "rw", author: spec.author, mergeable: .mergeable, draft: false,
            createdAt: Date(timeIntervalSince1970: TimeInterval(spec.second))
        )
    }

    private func makeServer() -> GitHubFixtureServer {
        var nodes = (known + new).map(pullRequestNode)
        var team = pullRequestNode(droppedTeam)
        team["reviewRequests"] = Fixtures.connection(total: 1, nodes: [Fixtures.request("Q_D_TEAM", typeName: "Team")])
        var merged = pullRequestNode(droppedMerged)
        merged["state"] = "MERGED"
        merged["comments"] = Fixtures.connection(total: 1, nodes: [Fixtures.comment("D_MERGED_FINAL")])
        nodes += [team, merged]
        return GitHubFixtureServer(pullRequests: nodes, afterQuery: { request, response in
            guard request.query.contains("query CompletePullRequests"),
                  var data = response["data"] as? [String: Any],
                  var hydrated = data["nodes"] as? [Any] else { return }
            for index in hydrated.indices {
                guard var node = hydrated[index] as? [String: Any],
                      var threads = node["reviewThreads"] as? [String: Any] else { continue }
                switch node["id"] as? String {
                case "K05":
                    // One thread was deleted after the PR read counted it, so its later thread page restarts.
                    threads["totalCount"] = (threads["totalCount"] as! Int) + 1
                case "K07":
                    // A thread the PR read lists is gone by the time its comments are read.
                    threads["totalCount"] = (threads["totalCount"] as! Int) + 1
                    threads["nodes"] = (threads["nodes"] as! [[String: Any]]) + [Fixtures.threadIdentity("K07_GHOST")]
                default:
                    continue
                }
                node["reviewThreads"] = threads
                hydrated[index] = node
            }
            data["nodes"] = hydrated
            response["data"] = data
        })
    }

    private func pullRequestNode(_ spec: Spec) -> [String: Any] {
        func comments(_ owner: String, _ count: Int) -> [[String: Any]] {
            (0..<count).map { Fixtures.comment("\(owner)_C\($0)", createdAt: Self.timestamp(5_000 + $0)) }
        }
        var node: [String: Any]
        switch spec.id {
        case "K01":
            node = Fixtures.pullRequest(
                id: spec.id,
                comments: Fixtures.connection(total: 25, nodes: comments(spec.id, 25)),
                reviews: Fixtures.connection(total: 12, nodes: (0..<12).map {
                    Fixtures.review("K01_R\($0)", state: $0 == 11 ? "APPROVED" : "COMMENTED", submittedAt: Self.timestamp(6_000 + $0))
                }),
                opinionated: Fixtures.connection(total: 1, nodes: [Fixtures.leanReview("K01_R11")])
            )
        case "K03":
            node = Fixtures.pullRequest(id: spec.id, threads: Fixtures.connection(total: 3, nodes: (0..<3).map { index in
                Fixtures.thread("K03_T\(index)", comments: comments("K03_T\(index)", 15))
            }))
        case "K05":
            node = Fixtures.threadedPullRequest(spec.id, threads: 105)
        case "K07":
            node = Fixtures.threadedPullRequest(spec.id, threads: 2)
        default:
            node = Fixtures.pullRequest(id: spec.id, comments: Fixtures.connection(total: 1, nodes: comments(spec.id, 1)))
        }
        node["number"] = spec.number
        node["title"] = "PR \(spec.id)"
        node["url"] = "https://github.com/\(spec.repo)/pull/\(spec.number)"
        node["repository"] = ["nameWithOwner": spec.repo, "isArchived": false]
        node["author"] = ["login": spec.author]
        node["createdAt"] = Self.timestamp(spec.second)
        switch spec.lane {
        case .direct:
            node["reviewRequests"] = Fixtures.connection(total: 1, nodes: [Fixtures.request("Q_\(spec.id)", login: "rw")])
        case .team:
            node["reviewRequests"] = Fixtures.connection(total: 1, nodes: [Fixtures.request("Q_\(spec.id)", typeName: "Team")])
        case .assigned:
            node["assignees"] = Fixtures.connection(total: 1, nodes: [Fixtures.user("rw")])
        default:
            break
        }
        switch spec.id {
        case "K30", "K31": node["stack"] = ["id": "STACK_A"]
        case "K40": node["stack"] = ["id": "STACK_B"]
        default: break
        }
        return node
    }

    private func discoveryNode(_ spec: Spec) -> [String: Any] {
        ["id": spec.id, "number": spec.number, "createdAt": Self.timestamp(spec.second), "repository": ["nameWithOwner": spec.repo]]
    }

    private static func timestamp(_ second: Int) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(second)))
    }

    // MARK: Answers

    private func respond(
        to request: URLRequest,
        server: GitHubFixtureServer,
        discovered: [Spec],
        queryNames: LockedBox<[String]>
    ) throws -> (Data, HTTPURLResponse) {
        switch request.url?.path {
        case "/user":
            return Self.response(["login": "rw"], request)
        case "/repos/\(droppedGone.repo)/pulls/\(droppedGone.number)":
            return Self.response(["message": "Not Found"], request, status: 404)
        case "/graphql":
            break
        default:
            XCTFail("Unexpected REST request \(request.url?.path ?? "")")
            return Self.response(["message": "unexpected"], request, status: 500)
        }
        let body = try XCTUnwrap(Self.body(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = object["query"] as? String ?? ""
        let variables = Self.queryValues(object["variables"] as? [String: Any] ?? [:])
        let name = query.range(of: "query ").map { String(query[$0.upperBound...].prefix { $0.isLetter }) } ?? query
        queryNames.withValue { $0.append(name) }

        return (try answerGraphQL(query: query, variables: variables, server: server, discovered: discovered), Self.http(request))
    }

    /// Answers one GraphQL query from its content.
    private func answerGraphQL(
        query: String,
        variables: [String: GitHubQueryValue],
        server: GitHubFixtureServer,
        discovered: [Spec]
    ) throws -> Data {
        if query.contains("query CompletePullRequests") || query.contains("query ContinuePullRequestConnections") {
            return try server.respond(query: query, variables: variables)
        }
        if query.contains("query ViewerTeams") {
            return Self.json(["data": ["viewer": ["organizations": [
                "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
                "nodes": [[
                    "login": "acme",
                    "teams": [
                        "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
                        "nodes": [[
                            "id": "T_DEV", "slug": "developers", "parentTeam": NSNull(),
                            "ancestors": ["pageInfo": ["hasNextPage": false], "nodes": []]
                        ]]
                    ]
                ]]
            ]]]])
        }
        if query.contains("query DiscoveryBounds") {
            var data: [String: Any] = [:]
            for lane in GitHubDiscoveryLane.allCases {
                let specs = discovered.filter { $0.lane == lane }.sorted { $0.second < $1.second }
                data["\(lane.rawValue)Oldest"] = ["nodes": specs.prefix(1).map(discoveryNode)]
                data["\(lane.rawValue)Newest"] = ["nodes": specs.suffix(1).map(discoveryNode)]
            }
            return Self.json(["data": data])
        }
        if query.contains("query DiscoverPullRequests") {
            var data: [String: Any] = [:]
            for lane in GitHubDiscoveryLane.allCases {
                data[lane.rawValue] = Self.searchPage(discovered.filter { $0.lane == lane }.map(discoveryNode))
            }
            return Self.json(["data": data])
        }
        if query.contains("query SearchPullRequests"), case .string(let search) = variables["query"],
           search.contains("repo:\(droppedTeam.repo) team-review-requested-user:rw") {
            return Self.json(["data": ["search": Self.searchPage([discoveryNode(droppedTeam)])]])
        }
        if query.contains("query PullRequestStacks"), case .strings(let ids) = variables["ids"] {
            return Self.json(["data": ["nodes": ids.map { id -> Any in
                let members = id == "STACK_A" ? ["K30", "K31"] : id == "STACK_B" ? ["K40", "EXTERNAL"] : []
                return [
                    "id": id,
                    "size": members.count,
                    "entries": [
                        "totalCount": members.count,
                        "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
                        "nodes": members.enumerated().map { index, member -> [String: Any] in
                            [
                                "position": index + 1,
                                "pullRequest": [
                                    "id": member, "number": 300 + index, "title": "Stacked \(member)",
                                    "url": "https://github.com/acme/app/pull/\(300 + index)", "state": "OPEN",
                                    "isDraft": false, "author": ["login": "teammate"]
                                ]
                            ]
                        }
                    ]
                ]
            }]])
        }
        XCTFail("Unexpected query \(query.prefix(80))")
        throw GitHubReadError.invalidPayload
    }

    private static func searchPage(_ nodes: [[String: Any]]) -> [String: Any] {
        [
            "issueCount": nodes.count, "nodes": nodes,
            "pageInfo": ["startCursor": NSNull(), "endCursor": NSNull(), "hasPreviousPage": false, "hasNextPage": false]
        ]
    }

    static func queryValues(_ variables: [String: Any]) -> [String: GitHubQueryValue] {
        variables.mapValues { value in
            switch value {
            case let value as String: .string(value)
            case let value as [String]: .strings(value)
            case let value as Int: .integer(value)
            default: .null
            }
        }
    }

    static func body(_ request: URLRequest) -> Data? {
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

    private static func http(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func response(_ object: Any, _ request: URLRequest, status: Int = 200) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: object), http(request, status: status))
    }
}

final class RefreshGoldenURLProtocol: URLProtocol {
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
