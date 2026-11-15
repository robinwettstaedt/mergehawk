@testable import mergehawkcore
import Foundation
import XCTest

/// `readRefresh` at fetcher level: discovery, viewer teams and known-PR hydration together, new-PR hydration after
/// discovery, then discovery results applied in a fixed order.
final class GitHubRefreshReadTests: XCTestCase {
    private typealias Fixtures = GitHubPaginationTests

    func testDiscoveryViewerTeamsAndKnownBatchesAreInFlightTogetherAtFour() async throws {
        let known = Self.identities(45, lane: .authored)
        let transport = RefreshReadTransport(known: known, lanes: [.authored: known])
        let probe = ConcurrentReadProbe(gate: { _ in true }, handler: transport.read)
        let limiter = GitHubReadLimiter()

        let refresh = Task { try await probe.fetcher(limiter: limiter).readRefresh(login: "rw", known: known, reusableViewerTeams: nil) }
        await waitForCondition { probe.gatedRequests.count == 4 }
        func chainReadsGated() -> Bool {
            let gated = probe.gatedRequests
            return gated.contains { $0.query.contains("DiscoveryBounds") } && gated.contains { $0.query.contains("query ViewerTeams") }
        }
        if !chainReadsGated() {
            // The waiting chain read takes the next free permit.
            probe.release { $0.query.contains("CompletePullRequests") }
            await waitForCondition { chainReadsGated() }
        }
        let gated = probe.gatedRequests
        XCTAssertTrue(gated.contains { $0.query.contains("query ViewerTeams") })
        XCTAssertTrue(gated.contains { $0.query.contains("DiscoveryBounds") })
        XCTAssertTrue(gated.contains { $0.query.contains("CompletePullRequests") })
        XCTAssertEqual(probe.inFlight, 4)
        probe.openGate()
        let read = try await refresh.value

        XCTAssertEqual(read.pullRequests.count, 45)
        XCTAssertEqual(probe.peakInFlight, 4)
    }

    func testNewPullRequestsHydrateAfterDiscoveryWhileAKnownBatchIsStillInFlight() async throws {
        let known = Self.identities(30, lane: .authored)
        let new = Self.identities(3, lane: .direct, prefix: "NEW")
        let transport = RefreshReadTransport(known: known + new, lanes: [.authored: known, .direct: new])
        let knownBatch = GitHubQueryValue.strings(known.prefix(20).map(\.id))
        let probe = ConcurrentReadProbe(gate: { $0.variables["ids"] == knownBatch }, handler: transport.read)

        let refresh = Task {
            try await probe.fetcher().readRefresh(login: "rw", known: known, reusableViewerTeams: [])
        }
        let newBatch = GitHubQueryValue.strings(new.map(\.id))
        await waitForCondition { probe.events.contains { $0.kind == .end && $0.request.variables["ids"] == newBatch } }
        XCTAssertEqual(probe.gatedRequests.count, 1)
        probe.openGate()
        _ = try await refresh.value

        let events = probe.events
        let discoveryEnd = try XCTUnwrap(events.firstIndex { $0.kind == .end && $0.request.query.contains("DiscoverPullRequests") })
        let newStart = try XCTUnwrap(events.firstIndex { $0.kind == .start && $0.request.variables["ids"] == newBatch })
        let knownEnd = try XCTUnwrap(events.firstIndex { $0.kind == .end && $0.request.variables["ids"] == knownBatch })
        XCTAssertLessThan(discoveryEnd, newStart)
        XCTAssertLessThan(newStart, knownEnd)
    }

    func testDiscoveryReadsWaitForOnlyOnePermitBehindAQueueOfKnownBatches() async throws {
        // 150 known PRs make 8 hydration batches. Discovery reads three pages: bounds, discovery and one search page.
        let known = Self.identities(150, lane: .authored)
        let transport = RefreshReadTransport(known: known, lanes: [.authored: known])
        let probe = ConcurrentReadProbe(gate: { $0.query.contains("CompletePullRequests") }, handler: transport.read)
        let limiter = GitHubReadLimiter()
        func isDiscoveryRead(_ request: GitHubFixtureServer.Request) -> Bool {
            ["DiscoveryBounds", "DiscoverPullRequests", "SearchPullRequests"].contains { request.query.contains($0) }
        }
        func discoveryEvents(_ kind: ConcurrentReadProbe.Event.Kind) -> Int {
            probe.events.filter { $0.kind == kind && isDiscoveryRead($0.request) }.count
        }
        func hydrationStarts() -> Int {
            probe.startedRequests.filter { $0.query.contains("CompletePullRequests") }.count
        }

        let refresh = Task {
            try await probe.fetcher(limiter: limiter).readRefresh(login: "rw", known: known, reusableViewerTeams: [])
        }
        var releasesBeforeEachRead: [Int] = []
        var releases = 0
        while discoveryEvents(.end) < 3 {
            let started = discoveryEvents(.start)
            // Wait until the next discovery read starts, or waits behind gated batches holding every permit.
            await waitForCondition {
                discoveryEvents(.start) > started
                    || (discoveryEvents(.end) == started && probe.gatedRequests.count == 4
                        && limiter.waitingCount == 8 - hydrationStarts() + 1)
            }
            if discoveryEvents(.start) > started {
                releasesBeforeEachRead.append(releases)
                releases = 0
                await waitForCondition { discoveryEvents(.end) > started }
            } else {
                probe.release()
                releases += 1
            }
        }
        probe.openGate()
        _ = try await refresh.value

        XCTAssertEqual(releasesBeforeEachRead.count, 3)
        XCTAssertLessThanOrEqual(releasesBeforeEachRead[0], 1)
        XCTAssertEqual(Array(releasesBeforeEachRead.dropFirst()), [1, 1])
    }

    func testRefreshReadGivesTheSerialResultForAnyResponseOrder() async throws {
        let fixture = RefreshGoldenFixture(includesNewPullRequests: true)
        let serial = try await ConcurrentReadProbe(handler: fixture.graphQLTransport())
            .fetcher(capacity: 1)
            .readRefresh(login: "rw", known: fixture.knownIdentities, reusableViewerTeams: nil)
        XCTAssertEqual(serial.missingPullRequestIDs, ["D_GONE"])
        XCTAssertEqual(serial.viewerTeams, [RefreshGoldenFixture.viewerTeam])

        for seed in UInt64(1)...5 {
            let probe = ConcurrentReadProbe(seed: seed, maxDelayMilliseconds: 6, handler: fixture.graphQLTransport())
            let read = try await probe.fetcher()
                .readRefresh(login: "rw", known: fixture.knownIdentities, reusableViewerTeams: nil)

            XCTAssertEqual(
                try GitHubHydrationGoldenTests.normalizedJSON(read.pullRequests.map(\.pullRequest)),
                try GitHubHydrationGoldenTests.normalizedJSON(serial.pullRequests.map(\.pullRequest)),
                "seed \(seed)"
            )
            XCTAssertEqual(read.pullRequests.map(\.discovery), serial.pullRequests.map(\.discovery), "seed \(seed)")
            XCTAssertEqual(read.pullRequests.map(\.providerState), serial.pullRequests.map(\.providerState), "seed \(seed)")
            XCTAssertEqual(
                read.pullRequests.map(\.hasTeamReviewRequest), serial.pullRequests.map(\.hasTeamReviewRequest), "seed \(seed)"
            )
            XCTAssertEqual(read.discovery, serial.discovery, "seed \(seed)")
            XCTAssertEqual(read.missingPullRequestIDs, serial.missingPullRequestIDs, "seed \(seed)")
            XCTAssertEqual(read.viewerTeams, serial.viewerTeams, "seed \(seed)")
            XCTAssertLessThanOrEqual(probe.peakInFlight, 4)
        }
    }

    func testFoundPullRequestTakesDiscoveryLanesWhileADroppedOutOneKeepsItsKnownIdentity() async throws {
        let found = Self.identity("PR_FOUND", isAuthored: true)
        let dropped = Self.identity("PR_DROPPED", isDirectlyRequested: true)
        let discovered = Self.identity("PR_FOUND", isTeamRequested: true)
        let transport = RefreshReadTransport(known: [found, dropped], lanes: [.team: [discovered]])

        let read = try await transport.fetcher().readRefresh(login: "rw", known: [found, dropped], reusableViewerTeams: [])

        XCTAssertEqual(read.pullRequests.map(\.pullRequest.id), ["PR_FOUND", "PR_DROPPED"])
        XCTAssertEqual(read.pullRequests[0].discovery, discovered)
        XCTAssertEqual(read.pullRequests[1].discovery, dropped)
        XCTAssertFalse(read.pullRequests[0].pullRequest.isMine)
    }

    func testRefusalIsMissingOnlyForADroppedOutPullRequest() async throws {
        let refusal: (GitHubFixtureServer.Request, inout [String: Any]) -> Void = { request, response in
            guard case .strings(let ids) = request.variables["ids"],
                  let index = ids.firstIndex(where: { $0.hasPrefix("REFUSED") }) else { return }
            var data = response["data"] as! [String: Any]
            var nodes = data["nodes"] as! [Any]
            nodes[index] = NSNull()
            data["nodes"] = nodes
            response["data"] = data
            response["errors"] = [["type": "FORBIDDEN", "path": ["nodes", index], "message": "Forbidden"]]
        }
        let kept = Self.identity("PR_KEPT")
        let refused = Self.identity("REFUSED_1")

        let dropped = try await RefreshReadTransport(known: [kept, refused], lanes: [.authored: [kept]], afterQuery: refusal)
            .fetcher()
            .readRefresh(login: "rw", known: [kept, refused], reusableViewerTeams: [])
        XCTAssertEqual(dropped.missingPullRequestIDs, ["REFUSED_1"])
        XCTAssertEqual(dropped.pullRequests.map(\.pullRequest.id), ["PR_KEPT"])

        for known in [[kept, refused], [kept]] {
            do {
                _ = try await RefreshReadTransport(known: [kept, refused], lanes: [.authored: [kept, refused]], afterQuery: refusal)
                    .fetcher()
                    .readRefresh(login: "rw", known: known, reusableViewerTeams: [])
                XCTFail("Expected a refused PR that discovery found to fail the read")
            } catch {
                XCTAssertEqual(error as? GitHubReadError, .accessDenied, "known \(known.map(\.id))")
            }
        }
    }

    func testNotFoundNodeIsMissingForFoundAndDroppedOutPullRequests() async throws {
        let found = Self.identity("GONE_FOUND")
        let dropped = Self.identity("GONE_DROPPED")
        let kept = Self.identity("PR_KEPT")
        let transport = RefreshReadTransport(
            known: [kept],
            lanes: [.authored: [kept, found]]
        )

        let read = try await transport.fetcher().readRefresh(login: "rw", known: [kept, found, dropped], reusableViewerTeams: [])

        XCTAssertEqual(read.missingPullRequestIDs, ["GONE_FOUND", "GONE_DROPPED"])
        XCTAssertEqual(read.pullRequests.map(\.pullRequest.id), ["PR_KEPT"])
    }

    func testKnownBatchFailureStopsDiscoveryBeforeItsNextRead() async throws {
        let known = Self.identities(20, lane: .authored)
        let transport = RefreshReadTransport(known: known, lanes: [.authored: known])
        let probe = ConcurrentReadProbe(gate: { $0.query.contains("DiscoveryBounds") }) { query, variables in
            if query.contains("CompletePullRequests") {
                guard case .strings(let ids) = variables["ids"] else { throw GitHubReadError.invalidPayload }
                return Fixtures.json([
                    "data": ["nodes": ids.map { _ in NSNull() }],
                    "errors": [["type": "VALIDATION", "message": "Bad query"]]
                ])
            }
            return try await transport.read(query: query, variables: variables)
        }
        let limiter = GitHubReadLimiter()

        let refresh = Task {
            try await probe.fetcher(limiter: limiter).readRefresh(login: "rw", known: known, reusableViewerTeams: [])
        }
        await waitForCondition { limiter.isStopped && probe.gatedRequests.count == 1 }
        probe.openGate()

        do {
            _ = try await refresh.value
            XCTFail("Expected a validation error")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .validation("Bad query."))
        }
        XCTAssertFalse(probe.startedRequests.contains { $0.query.contains("DiscoverPullRequests") })
    }

    func testCancellingTheRefreshTurnsAwayReadsWaitingForAPermit() async throws {
        let known = Self.identities(100, lane: .authored)
        let transport = RefreshReadTransport(known: known, lanes: [.authored: known])
        let probe = ConcurrentReadProbe(gate: { _ in true }, handler: transport.read)
        let limiter = GitHubReadLimiter()

        let refresh = Task {
            try await probe.fetcher(limiter: limiter).readRefresh(login: "rw", known: known, reusableViewerTeams: nil)
        }
        await waitForCondition { probe.gatedRequests.count == 4 && limiter.waitingCount == 3 }
        refresh.cancel()
        await waitForCondition { limiter.waitingCount == 0 }
        probe.openGate()

        do {
            _ = try await refresh.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(probe.startedRequests.count, 4)
    }

    func testReusableViewerTeamsSkipTheTeamsRead() async throws {
        let known = Self.identities(2, lane: .authored)
        let transport = RefreshReadTransport(known: known, lanes: [.authored: known])
        let probe = ConcurrentReadProbe(handler: transport.read)
        let teams = [RefreshGoldenFixture.viewerTeam]

        let read = try await probe.fetcher().readRefresh(login: "rw", known: known, reusableViewerTeams: teams)

        XCTAssertEqual(read.viewerTeams, teams)
        XCTAssertFalse(probe.startedRequests.contains { $0.query.contains("query ViewerTeams") })
    }

    // MARK: Fixtures

    private static func identity(
        _ id: String,
        isAuthored: Bool = false,
        isDirectlyRequested: Bool = false,
        isTeamRequested: Bool = false,
        second: Int = 100
    ) -> DiscoveredPullRequest {
        DiscoveredPullRequest(
            id: id, repository: "acme/app", number: 1, createdAt: Date(timeIntervalSince1970: TimeInterval(second)),
            isAuthored: isAuthored, isAssigned: false,
            isDirectlyRequested: isDirectlyRequested, isTeamRequested: isTeamRequested
        )
    }

    private static func identities(_ count: Int, lane: GitHubDiscoveryLane, prefix: String = "PR") -> [DiscoveredPullRequest] {
        (0..<count).map { index in
            identity(
                String(format: "\(prefix)_%03d", index),
                isAuthored: lane == .authored,
                isDirectlyRequested: lane == .direct,
                isTeamRequested: lane == .team,
                second: 1_000 + index
            )
        }
    }
}

/// Answers a refresh read's GraphQL queries from their content: discovery from `lanes`, an empty viewer teams
/// read, and hydration and continuation from a fixture server holding the PRs in `known`.
private struct RefreshReadTransport: Sendable {
    let server: GitHubFixtureServer
    let lanes: [GitHubDiscoveryLane: [DiscoveredPullRequest]]

    init(
        known: [DiscoveredPullRequest],
        lanes: [GitHubDiscoveryLane: [DiscoveredPullRequest]],
        afterQuery: ((GitHubFixtureServer.Request, inout [String: Any]) -> Void)? = nil
    ) {
        let ids = Set(known.map(\.id) + lanes.values.flatMap { $0.map(\.id) })
            .filter { !$0.hasPrefix("GONE") }
        server = GitHubFixtureServer(
            pullRequests: ids.sorted().map { id in
                GitHubPaginationTests.pullRequest(
                    id: id,
                    comments: GitHubPaginationTests.connection(total: 1, nodes: [GitHubPaginationTests.comment("\(id)_C0")])
                )
            },
            afterQuery: afterQuery
        )
        self.lanes = lanes
    }

    func fetcher() -> GitHubPullRequestFetcher {
        GitHubPullRequestFetcher(read: { query, variables in try await read(query: query, variables: variables) })
    }

    @Sendable func read(query: String, variables: [String: GitHubQueryValue]) async throws -> Data {
        if query.contains("query CompletePullRequests") || query.contains("query ContinuePullRequestConnections") {
            return try server.respond(query: query, variables: variables)
        }
        if query.contains("query ViewerTeams") {
            return Self.json(["data": ["viewer": ["organizations": [
                "pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": []
            ]]]])
        }
        if query.contains("query DiscoveryBounds") {
            var data: [String: Any] = [:]
            for lane in GitHubDiscoveryLane.allCases {
                let sorted = (lanes[lane] ?? []).sorted { $0.createdAt < $1.createdAt }
                data["\(lane.rawValue)Oldest"] = ["nodes": sorted.prefix(1).map(Self.node)]
                data["\(lane.rawValue)Newest"] = ["nodes": sorted.suffix(1).map(Self.node)]
            }
            return Self.json(["data": data])
        }
        if query.contains("query DiscoverPullRequests") {
            var data: [String: Any] = [:]
            for lane in GitHubDiscoveryLane.allCases {
                data[lane.rawValue] = page(lane, offset: 0)
            }
            return Self.json(["data": data])
        }
        if query.contains("query SearchPullRequests"), case .string(let search) = variables["query"],
           case .string(let cursor) = variables["cursor"],
           let lane = GitHubDiscoveryLane.allCases.first(where: { cursor.hasPrefix("\($0.rawValue):") }),
           let offset = Int(cursor.dropFirst(lane.rawValue.count + 1)), search.contains("is:open is:pr") {
            return Self.json(["data": ["search": page(lane, offset: offset)]])
        }
        XCTFail("Unexpected query \(query.prefix(80))")
        throw GitHubReadError.invalidPayload
    }

    /// A lane's search page of up to 100 PRs from `offset`, with the next offset as its end cursor.
    private func page(_ lane: GitHubDiscoveryLane, offset: Int) -> [String: Any] {
        let all = lanes[lane] ?? []
        let end = min(offset + 100, all.count)
        return [
            "issueCount": all.count,
            "nodes": all[offset..<end].map(Self.node),
            "pageInfo": [
                "startCursor": NSNull(), "endCursor": "\(lane.rawValue):\(end)",
                "hasPreviousPage": false, "hasNextPage": end < all.count
            ]
        ]
    }

    private static func node(_ identity: DiscoveredPullRequest) -> [String: Any] {
        [
            "id": identity.id, "number": identity.number,
            "createdAt": ISO8601DateFormatter().string(from: identity.createdAt),
            "repository": ["nameWithOwner": identity.repository]
        ]
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}
