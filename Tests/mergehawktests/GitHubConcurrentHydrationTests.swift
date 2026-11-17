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

    // MARK: Continuation rounds

    func testFirstReadBatchAndOlderPagesBatchAreInFlightTogether() async throws {
        var node = Fixtures.threadedPullRequest("PR_000", threads: 3)
        node["comments"] = Fixtures.connection(total: 11, nodes: (0..<11).map { Fixtures.comment("PR_000_C\($0)") })
        let serial = try await GitHubFixtureServer(pullRequests: [node]).fetcher.hydrate(Self.discoveries(1), login: "rw")
        let probe = ConcurrentReadProbe(server: GitHubFixtureServer(pullRequests: [node])) {
            $0.query.contains("ContinuePullRequestConnections")
        }

        let hydration = Task { try await probe.fetcher().hydrate(Self.discoveries(1), login: "rw") }
        await waitForCondition { probe.gatedRequests.count == 2 }
        XCTAssertEqual(Set(probe.gatedRequests.compactMap(\.batchShape)), ["other: 1", "first reads: 3"])
        probe.openGate()
        let hydrated = try await hydration.value

        XCTAssertEqual(
            try GitHubHydrationGoldenTests.normalizedJSON(hydrated.map(\.pullRequest)),
            try GitHubHydrationGoldenTests.normalizedJSON(serial.map(\.pullRequest))
        )
    }

    func testRestartInTheFirstBatchSupersedesThreadCommentPagesAndRetriesLaterInTheRound() async throws {
        let restarted = LockedBox(false)
        func server() -> GitHubFixtureServer {
            var pullRequests = [Fixtures.threadedPullRequest("R", threads: 250) { $0 == 249 ? 15 : 0 }]
            pullRequests += (1...25).map { index in
                let id = String(format: "X%02d", index)
                return Fixtures.pullRequest(
                    id: id,
                    comments: Fixtures.connection(total: 111, nodes: (0..<111).map { Fixtures.comment("\(id)_C\($0)") })
                )
            }
            let deleted = LockedBox(false)
            return GitHubFixtureServer(
                pullRequests: pullRequests,
                beforeQuery: { request, server in
                    // R loses its oldest thread just before its last thread page at attempt 0 is read.
                    guard request.aliases.contains(where: { $0.cursor == "reviewThreads:R:50" }),
                          deleted.withValue({ value in defer { value = true }; return !value }) else { return }
                    restarted.withValue { $0 = true }
                    server.deleteThread(prID: "R", threadID: "R_T0")
                },
                afterQuery: { request, response in
                    // The older page of R_T249 fails while X pages share its batch, which would retry it alone.
                    guard request.aliases.contains(where: { $0.id.hasPrefix("X") }),
                          let alias = request.aliases.first(where: { $0.cursor == "comments:R_T249:5" }) else { return }
                    var data = response["data"] as! [String: Any]
                    data[alias.name] = NSNull()
                    response["data"] = data
                    response["errors"] = [["type": "INTERNAL", "path": [alias.name], "message": "retry"]]
                }
            )
        }
        let discoveries = [Fixtures.discovery(id: "R")] + (1...25).map { Fixtures.discovery(id: String(format: "X%02d", $0)) }
        let serial = try await ConcurrentReadProbe(server: server()).fetcher(capacity: 1).hydrate(discoveries, login: "rw")
        XCTAssertTrue(restarted.value)
        let probe = ConcurrentReadProbe(server: server(), seed: 7, maxDelayMilliseconds: 3)

        let hydrated = try await probe.fetcher().hydrate(discoveries, login: "rw")

        XCTAssertEqual(
            try GitHubHydrationGoldenTests.normalizedJSON(hydrated.map(\.pullRequest)),
            try GitHubHydrationGoldenTests.normalizedJSON(serial.map(\.pullRequest))
        )
        let olderPageReads = probe.startedRequests.filter { request in
            request.aliases.contains { $0.cursor == "comments:R_T249:5" }
        }
        // The superseded read was in the round's third batch, with X pages, apart from R's thread page.
        let supersededBatch = try XCTUnwrap(olderPageReads.first)
        XCTAssertTrue(supersededBatch.aliases.contains { $0.id.hasPrefix("X") })
        XCTAssertFalse(supersededBatch.aliases.contains { $0.connection == "reviewThreads" })
        // Its re-read runs in a later round, and its retry is never sent.
        XCTAssertEqual(olderPageReads.count, 2)
        XCTAssertFalse(olderPageReads.contains { $0.aliases.count == 1 })
        let r = try XCTUnwrap(hydrated.first { $0.pullRequest.id == "R" }?.pullRequest)
        XCTAssertEqual(r.commentActivityCount, 15)
    }

    func testRestartWipesThreadCommentsMergedEarlierInTheRound() async throws {
        let threadPage = "reviewThreads:R:1"
        func server() -> GitHubFixtureServer {
            let deleted = LockedBox(false)
            return GitHubFixtureServer(
                pullRequests: [Fixtures.threadedPullRequest("Z", threads: 1), Fixtures.threadedPullRequest("R", threads: 101)],
                beforeQuery: { request, server in
                    // Just before R's last thread page, its oldest thread and one comment of R_T5 go away.
                    guard request.aliases.contains(where: { $0.cursor == threadPage }),
                          deleted.withValue({ value in defer { value = true }; return !value }) else { return }
                    server.deleteThread(prID: "R", threadID: "R_T0")
                    server.deleteThreadComment(threadID: "R_T5", commentID: "R_T5_C0")
                }
            )
        }
        let discoveries = [Fixtures.discovery(id: "Z"), Fixtures.discovery(id: "R")]
        // The thread page waits until the round's first reads, R_T5's among them, have answered.
        let probe = ConcurrentReadProbe(server: server()) { request in
            request.aliases.contains { $0.cursor == threadPage }
        }

        let hydration = Task { try await probe.fetcher().hydrate(discoveries, login: "rw") }
        await waitForCondition { probe.gatedRequests.count == 1 && probe.inFlight == 1 }
        probe.openGate()
        let hydrated = try await hydration.value

        let r = try XCTUnwrap(hydrated.first { $0.pullRequest.id == "R" }?.pullRequest)
        XCTAssertFalse(r.recentCommentActivities.contains { $0.id == "R_T5_C0" })
        XCTAssertEqual(r.commentActivityCount, 99)
        let firstReadsOfR5 = probe.startedRequests.filter { $0.aliases.contains { $0.id == "R_T5" } }
        XCTAssertEqual(firstReadsOfR5.count, 2)
        let serial = try await ConcurrentReadProbe(server: server()).fetcher(capacity: 1).hydrate(discoveries, login: "rw")
        XCTAssertEqual(
            try GitHubHydrationGoldenTests.normalizedJSON(hydrated.map(\.pullRequest)),
            try GitHubHydrationGoldenTests.normalizedJSON(serial.map(\.pullRequest))
        )
    }

    func testRepeatedCursorFailsTheRoundBeforeAnyOfItsReadsIsSent() async throws {
        let initial = Fixtures.pullRequest(
            comments: Fixtures.connection(total: 12, nodes: (2..<12).map { Fixtures.comment("C\($0)") }, previous: "before"),
            threads: Fixtures.connection(total: 3, nodes: [Fixtures.threadIdentity("T")], previous: "threads-p2")
        )
        let probe = ConcurrentReadProbe { query, variables in
            if query.contains("CompletePullRequests") { return Fixtures.json(["data": ["nodes": [initial]]]) }
            return Fixtures.answer(query, variables) { alias in
                switch (alias.connection, alias.cursor) {
                // The comments page doesn't advance its cursor.
                case ("comments", "before"):
                    Fixtures.connection(total: 12, nodes: [Fixtures.comment("C1")], previous: "before")
                case ("reviewThreads", _):
                    Fixtures.connection(total: 3, nodes: [Fixtures.threadIdentity("U")], previous: "threads-p3")
                default:
                    Fixtures.connection(total: 1, nodes: [Fixtures.comment("\(alias.id)_C0")])
                }
            }
        }

        do {
            _ = try await probe.fetcher().hydrate([Fixtures.discovery()], login: "rw")
            XCTFail("Expected a repeated cursor to fail")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .incompleteCoverage("Repeated continuation cursor"))
        }
        // The next round would send the repeated comments page with the next thread page, and U's first read.
        assertRequestRounds(probe.startedRequests.compactMap(\.batchShape), [["other: 2", "first reads: 1"]])
    }

    func testEntriesARoundQueuesRunInALaterRound() async throws {
        let server = GitHubFixtureServer(pullRequests: [Fixtures.threadedPullRequest("PR_000", threads: 101)])
        let probe = ConcurrentReadProbe(server: server, seed: 2, maxDelayMilliseconds: 5)

        _ = try await probe.fetcher().hydrate(Self.discoveries(1), login: "rw")

        let events = probe.events
        let laterStart = try XCTUnwrap(events.firstIndex { event in
            event.kind == .start && event.request.aliases.contains { $0.id == "PR_000_T0" }
        })
        let firstRound = events.filter { $0.kind == .end && $0.request.batchShape != nil }.prefix(2)
        XCTAssertEqual(Set(firstRound.compactMap(\.request.batchShape)), ["other: 1", "first reads: 100"])
        for end in firstRound {
            let index = try XCTUnwrap(events.firstIndex { $0.kind == .end && $0.key == end.key })
            XCTAssertLessThan(index, laterStart)
        }
    }

    func testFailedEntryRetriesAfterEveryPageOfItsRoundMerged() async throws {
        let initial = Fixtures.pullRequest(
            comments: Fixtures.connection(total: 11, nodes: (1..<11).map { Fixtures.comment("C\($0)") }, previous: "before"),
            threads: Fixtures.connection(total: 1, nodes: [Fixtures.threadIdentity("T")])
        )
        // The comments page and its retry are the same request, so the answer keys on a per-content count.
        let commentReads = LockedBox(0)
        let probe = ConcurrentReadProbe(gate: { $0.batchShape == "first reads: 1" }) { query, variables in
            if query.contains("CompletePullRequests") { return Fixtures.json(["data": ["nodes": [initial]]]) }
            let aliases = GitHubFixtureServer.aliases(query: query, variables: variables)
            if aliases.map(\.cursor) == ["before"], commentReads.increment() == 1 {
                return Fixtures.json([
                    "data": ["c0": NSNull()],
                    "errors": [["type": "INTERNAL", "path": ["c0"], "message": "retry"]]
                ])
            }
            return Fixtures.answer(query, variables) { alias in
                alias.isThreadComments
                    ? Fixtures.connection(total: 1, nodes: [Fixtures.comment("T_C0")])
                    : Fixtures.connection(total: 11, nodes: [Fixtures.comment("C0")])
            }
        }

        let hydration = Task { try await probe.fetcher().hydrate([Fixtures.discovery()], login: "rw") }
        await waitForCondition { probe.gatedRequests.count == 1 && probe.events.count == 5 }
        try await Task.sleep(for: .milliseconds(20))
        // The comments page failed, and its retry waits for the round's other batch.
        XCTAssertEqual(probe.startedRequests.count, 3)
        probe.openGate()
        let pullRequest = try await hydration.value[0].pullRequest

        XCTAssertEqual(pullRequest.recentCommentActivities.count, 12)
        XCTAssertEqual(commentReads.value, 2)
        let events = probe.events.map(\.description)
        let firstReadEnd = try XCTUnwrap(events.firstIndex { $0.hasPrefix("end") && $0.contains("T:comments:nil") })
        let retryStart = try XCTUnwrap(events.lastIndex { $0.hasPrefix("start") && $0.contains("PR_1:comments:before") })
        XCTAssertLessThan(firstReadEnd, retryStart)
    }

    func testRateLimitInOneBatchWinsOverInvalidPayloadInAnother() async throws {
        let initial = Fixtures.pullRequest(
            comments: Fixtures.connection(total: 11, nodes: (1..<11).map { Fixtures.comment("C\($0)") }, previous: "before"),
            threads: Fixtures.connection(total: 1, nodes: [Fixtures.threadIdentity("T")])
        )
        let probe = ConcurrentReadProbe(gate: { $0.batchShape != nil }) { query, variables in
            if query.contains("CompletePullRequests") { return Fixtures.json(["data": ["nodes": [initial]]]) }
            if GitHubFixtureServer.batchShape(query: query, variables: variables) == "first reads: 1" {
                return Fixtures.json(["data": ["c0": NSNull()], "errors": [["type": "RATE_LIMITED", "message": "Limited"]]])
            }
            return Fixtures.json(["unexpected": true])
        }

        let limiter = GitHubReadLimiter()
        let hydration = Task { try await probe.fetcher(limiter: limiter).hydrate([Fixtures.discovery()], login: "rw") }
        await waitForCondition { probe.gatedRequests.count == 2 }
        // The invalid payload answers and stops the read before the rate limit answers.
        probe.release { $0.batchShape == "other: 1" }
        await waitForCondition { limiter.isStopped }
        probe.openGate()
        do {
            _ = try await hydration.value
            XCTFail("Expected a rate limit")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .rateLimited(retryAt: nil))
        }
    }

    func testContinuationRoundsGiveTheSerialResultAndKeepOneLiveEntryPerConnection() async throws {
        func server() -> GitHubFixtureServer {
            GitHubFixtureServer(pullRequests: Self.richPullRequests(), afterQuery: { request, response in
                guard request.query.contains("query CompletePullRequests"),
                      var data = response["data"] as? [String: Any],
                      var nodes = data["nodes"] as? [[String: Any]] else { return }
                for index in nodes.indices {
                    guard var threads = nodes[index]["reviewThreads"] as? [String: Any] else { continue }
                    switch nodes[index]["id"] as? String {
                    case "PR_002":
                        // A thread deleted after the PR read counted it restarts the PR's thread list.
                        threads["totalCount"] = (threads["totalCount"] as! Int) + 1
                    case "PR_003":
                        // A listed thread is gone by the time its comments are read.
                        threads["nodes"] = (threads["nodes"] as! [[String: Any]]) + [Fixtures.threadIdentity("PR_003_GHOST")]
                    default:
                        continue
                    }
                    nodes[index]["reviewThreads"] = threads
                }
                data["nodes"] = nodes
                response["data"] = data
            })
        }
        let discoveries = Self.richPullRequests().map { Fixtures.discovery(id: $0["id"] as! String) }
        let serialProbe = ConcurrentReadProbe(server: server())
        let serial = try await serialProbe.fetcher(capacity: 1).hydrate(discoveries, login: "rw")
        XCTAssertTrue(serialProbe.startedRequests.contains { $0.query.contains("p: node(id: $pr)") })
        let expected = try GitHubHydrationGoldenTests.normalizedJSON(serial.map(\.pullRequest))

        for seed in UInt64(1)...5 {
            let probe = ConcurrentReadProbe(server: server(), seed: seed, maxDelayMilliseconds: 6)
            let hydrated = try await probe.fetcher().hydrate(discoveries, login: "rw")

            XCTAssertEqual(try GitHubHydrationGoldenTests.normalizedJSON(hydrated.map(\.pullRequest)), expected, "seed \(seed)")
            var inFlight: [String: Int] = [:]
            for event in probe.events {
                let keys = event.request.aliases.map { "\($0.connection):\($0.id)" }
                for key in keys {
                    switch event.kind {
                    case .start:
                        XCTAssertNil(inFlight[key], "\(key) in flight twice, seed \(seed)")
                        inFlight[key] = 1
                    case .end:
                        inFlight[key] = nil
                    }
                }
            }
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
