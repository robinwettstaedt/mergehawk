@testable import mergehawkcore
import Foundation
import XCTest

/// Hydration and continuation reads at fetcher level under the read limiter.
final class GitHubConcurrentHydrationTests: XCTestCase {
    private typealias Fixtures = GitHubPaginationTests

    // MARK: Hydration first pages

    func testEightHydrationBatchesPeakAtFourReadsInFlight() async throws {
        let server = GitHubFixtureServer(pullRequests: Self.plainPullRequests(160))
        let probe = ConcurrentReadProbe(server: server, seed: 1, maxDelayMilliseconds: 5) { _ in true }
        let limiter = GitHubReadLimiter()
        let fetcher = probe.fetcher(limiter: limiter)

        let hydration = Task { try await fetcher.hydrate(Self.discoveries(160), login: "rw") }
        await waitForCondition { probe.gatedRequests.count == 4 && limiter.waitingCount == 4 }
        XCTAssertEqual(probe.peakInFlight, 4)
        probe.openGate()
        let hydrated = try await hydration.value

        XCTAssertEqual(hydrated.count, 160)
        XCTAssertEqual(probe.startedRequests.filter { $0.query.contains("CompletePullRequests") }.count, 8)
        XCTAssertEqual(probe.peakInFlight, 4)
    }

    func testHydrationGivesTheSameResultForAnyResponseOrder() async throws {
        let pullRequests = Self.richPullRequests()
        let discoveries = pullRequests.map { Fixtures.discovery(id: $0["id"] as! String) }
        let serial = try await ConcurrentReadProbe(server: GitHubFixtureServer(pullRequests: pullRequests))
            .fetcher(capacity: 1)
            .hydrate(discoveries, login: "rw")
        let expected = try GitHubHydrationGoldenTests.normalizedJSON(serial.map(\.pullRequest))

        for seed in UInt64(1)...5 {
            let probe = ConcurrentReadProbe(
                server: GitHubFixtureServer(pullRequests: pullRequests), seed: seed, maxDelayMilliseconds: 8
            )
            let hydrated = try await probe.fetcher().hydrate(discoveries, login: "rw")

            XCTAssertEqual(try GitHubHydrationGoldenTests.normalizedJSON(hydrated.map(\.pullRequest)), expected, "seed \(seed)")
            XCTAssertEqual(hydrated.map(\.pullRequest.id), serial.map(\.pullRequest.id), "seed \(seed)")
            XCTAssertLessThanOrEqual(probe.peakInFlight, 4)
        }
    }

    func testSingleNodeRetryRunsThroughTheLimiterAndKeepsTheResult() async throws {
        let pullRequests = Self.plainPullRequests(60)
        let discoveries = Self.discoveries(60)
        let plain = try await GitHubFixtureServer(pullRequests: pullRequests).fetcher.hydrate(discoveries, login: "rw")
        // The batch holding PR_007 fails that node's comments, and its retry alone reads it.
        let server = GitHubFixtureServer(pullRequests: pullRequests, afterQuery: { request, response in
            guard case .strings(let ids) = request.variables["ids"], ids.count > 1,
                  let index = ids.firstIndex(of: "PR_007") else { return }
            var data = response["data"] as! [String: Any]
            var nodes = data["nodes"] as! [[String: Any]]
            nodes[index]["comments"] = NSNull()
            data["nodes"] = nodes
            response["data"] = data
            response["errors"] = [["type": "INTERNAL", "path": ["nodes", index, "comments"], "message": "retry"]]
        })
        let probe = ConcurrentReadProbe(server: server, seed: 3, maxDelayMilliseconds: 5)

        let hydrated = try await probe.fetcher().hydrate(discoveries, login: "rw")

        XCTAssertEqual(
            try GitHubHydrationGoldenTests.normalizedJSON(hydrated.map(\.pullRequest)),
            try GitHubHydrationGoldenTests.normalizedJSON(plain.map(\.pullRequest))
        )
        XCTAssertEqual(probe.startedRequests.filter { $0.variables["ids"] == .strings(["PR_007"]) }.count, 1)
        XCTAssertLessThanOrEqual(probe.peakInFlight, 4)
    }

    func testFailingBatchTurnsAwayQueuedBatchesWhileBatchesInFlightFinish() async throws {
        let server = GitHubFixtureServer(pullRequests: Self.plainPullRequests(160))
        let failingID = LockedBox<String?>(nil)
        let probe = ConcurrentReadProbe(gate: { _ in true }) { query, variables in
            if case .strings(let ids) = variables["ids"], ids.first == failingID.value {
                return Fixtures.json(["data": ["nodes": []]])
            }
            return try await server.read(query: query, variables: variables)
        }
        let limiter = GitHubReadLimiter()
        let hydration = Task { try await probe.fetcher(limiter: limiter).hydrate(Self.discoveries(160), login: "rw") }
        await waitForCondition { probe.gatedRequests.count == 4 && limiter.waitingCount == 4 }

        let failing = try XCTUnwrap(probe.gatedRequests.first)
        guard case .strings(let ids) = failing.variables["ids"] else { return XCTFail("No hydration IDs") }
        failingID.withValue { $0 = ids.first }
        probe.release { $0.variables["ids"] == failing.variables["ids"] }
        await waitForCondition { limiter.isStopped }
        probe.openGate()

        do {
            _ = try await hydration.value
            XCTFail("Expected invalid payload")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .invalidPayload)
        }
        XCTAssertEqual(probe.startedRequests.count, 4)
        XCTAssertEqual(probe.events.filter { $0.kind == .end }.count, 4)
        XCTAssertEqual(limiter.waitingCount, 0)
    }

    func testEarlierBatchErrorWinsOverALaterBatchErrorThatArrivedFirst() async throws {
        let server = GitHubFixtureServer(pullRequests: Self.plainPullRequests(40))
        let probe = ConcurrentReadProbe(gate: { _ in true }) { query, variables in
            guard case .strings(let ids) = variables["ids"] else { return try await server.read(query: query, variables: variables) }
            if ids.first == "PR_000" { return Fixtures.json(["data": ["nodes": []]]) }
            // An error outside any node fails the whole batch with a GraphQL error.
            return Fixtures.json([
                "data": ["nodes": ids.map { _ in NSNull() }],
                "errors": [["type": "INTERNAL", "message": "Something went wrong"]]
            ])
        }
        let limiter = GitHubReadLimiter()
        let hydration = Task { try await probe.fetcher(limiter: limiter).hydrate(Self.discoveries(40), login: "rw") }
        await waitForCondition { probe.gatedRequests.count == 2 }

        probe.release { $0.variables["ids"] != .strings((0..<20).map(Self.id)) }
        await waitForCondition { limiter.isStopped }
        probe.openGate()

        do {
            _ = try await hydration.value
            XCTFail("Expected invalid payload")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .invalidPayload)
        }
    }

    func testRefusedNodeFailsAtOnceAndAnotherBatchRetryIsNotSent() async throws {
        let server = GitHubFixtureServer(pullRequests: Self.plainPullRequests(40), afterQuery: { request, response in
            guard case .strings(let ids) = request.variables["ids"] else { return }
            var data = response["data"] as! [String: Any]
            var nodes = data["nodes"] as! [Any]
            if let index = ids.firstIndex(of: "PR_005") {
                // GitHub refuses PR_005, in its batch and on its own.
                nodes[index] = NSNull()
                response["errors"] = [["type": "FORBIDDEN", "path": ["nodes", index], "message": "Forbidden"]]
            } else if ids.count > 1, let index = ids.firstIndex(of: "PR_025") {
                // PR_025's batch read fails that node, which then needs its own retry.
                nodes[index] = NSNull()
                response["errors"] = [["type": "INTERNAL", "path": ["nodes", index], "message": "retry"]]
            }
            data["nodes"] = nodes
            response["data"] = data
        })
        let laterBatch = GitHubQueryValue.strings((20..<40).map(Self.id))
        let probe = ConcurrentReadProbe(server: server) { $0.variables["ids"] == laterBatch }
        let limiter = GitHubReadLimiter()
        let hydration = Task { try await probe.fetcher(limiter: limiter).hydrate(Self.discoveries(40), login: "rw") }
        await waitForCondition { limiter.isStopped }
        probe.openGate()

        do {
            _ = try await hydration.value
            XCTFail("Expected access denied")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .accessDenied)
        }
        XCTAssertEqual(probe.startedRequests.filter { $0.variables["ids"] == .strings(["PR_005"]) }.count, 1)
        XCTAssertFalse(probe.startedRequests.contains { $0.variables["ids"] == .strings(["PR_025"]) })
    }

    func testMissingNodeStillFailsStrictHydration() async throws {
        let server = GitHubFixtureServer(pullRequests: Self.plainPullRequests(30).filter { $0["id"] as? String != "PR_012" })
        do {
            _ = try await ConcurrentReadProbe(server: server).fetcher().hydrate(Self.discoveries(30), login: "rw")
            XCTFail("Expected invalid payload")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .invalidPayload)
        }
    }

    // MARK: Fixtures

    static func id(_ index: Int) -> String { String(format: "PR_%03d", index) }

    static func discoveries(_ count: Int) -> [DiscoveredPullRequest] {
        (0..<count).map { Fixtures.discovery(id: id($0)) }
    }

    static func plainPullRequests(_ count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            Fixtures.pullRequest(
                id: id(index),
                comments: Fixtures.connection(total: 1, nodes: [Fixtures.comment("\(id(index))_C0")])
            )
        }
    }

    /// 45 PRs with older comment and review pages, threads with older comment pages, and one PR with more
    /// threads than one page holds.
    static func richPullRequests() -> [[String: Any]] {
        (0..<45).map { index in
            let prID = id(index)
            switch index % 5 {
            case 0:
                return Fixtures.pullRequest(
                    id: prID,
                    comments: Fixtures.connection(total: 25, nodes: (0..<25).map { Fixtures.comment("\(prID)_C\($0)") }),
                    reviews: Fixtures.connection(total: 12, nodes: (0..<12).map {
                        Fixtures.review("\(prID)_R\($0)", state: "COMMENTED")
                    })
                )
            case 1:
                return Fixtures.threadedPullRequest(prID, threads: 3) { $0 * 7 }
            case 2 where index == 2:
                return Fixtures.threadedPullRequest(prID, threads: 130)
            default:
                return Fixtures.threadedPullRequest(prID, threads: 2)
            }
        }
    }
}
