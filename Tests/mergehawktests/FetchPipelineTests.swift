@testable import mergehawkcore
import Foundation
import XCTest

final class FetchPipelineTests: XCTestCase {
    func testLargeCompleteHydrationFindsActivityOutsideFormerFixedWindow() async throws {
        let identity = Self.discovery(
            isAuthored: true,
            isAssigned: true,
            isDirect: true,
            isTeam: true
        )
        let newest = (101...120).map { Self.comment("C_\($0)") }
        let older = (1...100).map { Self.comment("C_\($0)") }
        let baselineTransport = PipelineTransport(
            responses: [
                Self.hydrationResponse(
                    comments: Self.connection(total: 120, nodes: newest, previous: "older")
                ),
                Self.continuationResponse(
                    comments: Self.connection(total: 120, nodes: older)
                )
            ],
            delayPerRequest: 0.025
        )
        let baselineHydrated = try await Self.fetcher(baselineTransport).hydrate([identity], login: "rw")
        let baselinePR = try XCTUnwrap(baselineHydrated.first?.pullRequest)
        XCTAssertEqual(baselinePR.recentCommentActivities.count, 120)

        let engine = SyncEngine(source: EmptyPullRequestSource(), loginProvider: { "rw" })
        let baseline = try await engine.prepare(
            previousState: nil,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [baselinePR])
        )
        let previous = PullRequestSyncState(
            account: baseline.account,
            dashboard: DashboardState(
                pullRequests: baseline.activePullRequests,
                events: [],
                syncedAt: baseline.syncedAt,
                source: baseline.source,
                account: baseline.account,
                authStatus: .signedIn
            ),
            processedActivityByPullRequestID: baseline.processedActivityByPullRequestID
        )

        let activityOutsideOldWindow = Self.comment("C_OUTSIDE_OLD_WINDOW")
        let changedTransport = PipelineTransport(
            responses: [
                Self.hydrationResponse(
                    comments: Self.connection(total: 121, nodes: newest, previous: "older")
                ),
                Self.continuationResponse(
                    comments: Self.connection(total: 121, nodes: older + [activityOutsideOldWindow])
                )
            ],
            delayPerRequest: 0.025
        )
        let changedHydrated = try await Self.fetcher(changedTransport).hydrate([identity], login: "rw")
        let changedPR = try XCTUnwrap(changedHydrated.first?.pullRequest)
        let prepared = try await engine.prepare(
            previousState: previous,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [changedPR])
        )

        XCTAssertEqual(prepared.events.map(\.event.activityId), ["C_OUTSIDE_OLD_WINDOW"])
        XCTAssertEqual(changedPR.recentCommentActivities.count, 121)
        XCTAssertEqual(baselineTransport.metrics.requestCount, 2)
        XCTAssertEqual(changedTransport.metrics.requestCount, 2)
        XCTAssertEqual(changedTransport.metrics.injectedNetworkDelay, 0.05, accuracy: 0.000_1)
        XCTAssertEqual(changedTransport.metrics.completeHydrationRequests, 1)
        XCTAssertEqual(changedTransport.metrics.continuationRequests, 1)
        XCTAssertFalse(changedTransport.queries.joined().contains("commits("))
        XCTAssertFalse(changedTransport.queries.joined().contains("notifications"))
        print(
            "Fetch cost large-complete: requests=\(changedTransport.metrics.requestCount), "
                + "response-bytes=\(changedTransport.metrics.responsePayloadBytes), "
                + "complete-activities=\(changedPR.recentCommentActivities.count), "
                + "injected-delay=\(changedTransport.metrics.injectedNetworkDelay)s"
        )
    }

    func testFetchCostEvidenceCoversUnchangedChangedMultiPageAndFailureFixtures() async throws {
        let fixtures: [(String, PipelineTransport)] = [
            ("unchanged-small", PipelineTransport(responses: [Self.hydrationResponse()])),
            ("changed-small", PipelineTransport(responses: [Self.hydrationResponse(title: "Changed")])),
            ("multi-page", PipelineTransport(responses: [
                Self.hydrationResponse(
                    comments: Self.connection(total: 21, nodes: (2...21).map { Self.comment("C_\($0)") }, previous: "older")
                ),
                Self.continuationResponse(comments: Self.connection(total: 21, nodes: [Self.comment("C_1")]))
            ])),
        ]

        for (name, transport) in fixtures {
            _ = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
            let metrics = transport.metrics
            XCTAssertGreaterThan(metrics.selectedFieldFootprint, 0)
            XCTAssertEqual(metrics.requestCount, name == "multi-page" ? 2 : 1)
            print(
                "Fetch cost \(name): requests=\(metrics.requestCount), "
                    + "selected-query-bytes=\(metrics.selectedFieldFootprint), "
                    + "response-bytes=\(metrics.responsePayloadBytes), "
                    + "injected-delay=\(metrics.injectedNetworkDelay)s"
            )
        }

        let failing = PipelineTransport(
            responses: [],
            terminalError: GitHubReadError.validation("fixture failure")
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await Self.fetcher(failing).hydrate([Self.discovery()], login: "rw")
        }
        XCTAssertEqual(failing.metrics.requestCount, 1)

        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("title"))
        let continuationQuery = try XCTUnwrap(fixtures[2].1.queries.last)
        XCTAssertFalse(continuationQuery.contains("title"))
        XCTAssertFalse(continuationQuery.contains("statusCheckRollup"))
        print(
            "Legacy small fixture comparison: the removed pipeline used three relationship searches plus "
                + "a detail request and repeated dashboard selections. Complete hydration uses one shared PR "
                + "node request after discovery; multi-page fixtures add bounded connection-only requests."
        )
    }

    private static func fetcher(_ transport: PipelineTransport) -> GitHubPullRequestFetcher {
        GitHubPullRequestFetcher { query, variables in
            try await transport.read(query: query, variables: variables)
        }
    }

    private static func discovery(
        isAuthored: Bool = true,
        isAssigned: Bool = false,
        isDirect: Bool = false,
        isTeam: Bool = false
    ) -> DiscoveredPullRequest {
        DiscoveredPullRequest(
            id: "PR_PIPELINE",
            repository: "acme/app",
            number: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            isAuthored: isAuthored,
            isAssigned: isAssigned,
            isDirectlyRequested: isDirect,
            isTeamRequested: isTeam
        )
    }

    private static func hydrationResponse(
        title: String = "Complete pipeline",
        comments: [String: Any] = connection(total: 0, nodes: [])
    ) -> Data {
        json(["data": ["nodes": [[
            "id": "PR_PIPELINE", "title": title, "number": 1,
            "url": "https://github.com/acme/app/pull/1", "state": "OPEN",
            "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z",
            "headRefName": "feature", "headRefOid": "abc", "isDraft": false,
            "mergeable": "MERGEABLE", "additions": 1, "deletions": 2,
            "statusCheckRollup": ["state": "SUCCESS"],
            "author": user("rw"), "repository": ["nameWithOwner": "acme/app"],
            "comments": comments,
            "reviews": connection(total: 0, nodes: []),
            "latestOpinionatedReviews": connection(total: 0, nodes: []),
            "reviewThreads": connection(total: 0, nodes: []),
            "assignees": connection(total: 0, nodes: []),
            "reviewRequests": connection(total: 0, nodes: [])
        ]]]])
    }

    private static func continuationResponse(comments: [String: Any]) -> Data {
        json(["data": ["c0": ["comments": comments]]])
    }

    private static func connection(
        total: Int,
        nodes: [[String: Any]],
        previous: String? = nil
    ) -> [String: Any] {
        [
            "totalCount": total,
            "nodes": nodes,
            "pageInfo": [
                "startCursor": previous.map { $0 as Any } ?? NSNull(),
                "endCursor": "end",
                "hasPreviousPage": previous != nil,
                "hasNextPage": false
            ]
        ]
    }

    private static func comment(_ id: String) -> [String: Any] {
        [
            "id": id,
            "createdAt": "2026-01-01T00:00:00Z",
            "viewerDidAuthor": false,
            "author": user("reviewer"),
            "pullRequestReview": NSNull()
        ]
    }

    private static func user(_ login: String) -> [String: Any] {
        ["id": "USER_\(login)", "login": login]
    }

    private static func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }
}

private struct FetchMetrics: Equatable {
    var requestCount = 0
    var selectedFieldFootprint = 0
    var responsePayloadBytes = 0
    var injectedNetworkDelay: TimeInterval = 0
    var completeHydrationRequests = 0
    var continuationRequests = 0
}

private final class PipelineTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data]
    private let terminalError: Error?
    private let delayPerRequest: TimeInterval
    private var storedMetrics = FetchMetrics()
    private var storedQueries: [String] = []

    init(
        responses: [Data],
        terminalError: Error? = nil,
        delayPerRequest: TimeInterval = 0.01
    ) {
        self.responses = responses
        self.terminalError = terminalError
        self.delayPerRequest = delayPerRequest
    }

    var metrics: FetchMetrics { lock.withLock { storedMetrics } }
    var queries: [String] { lock.withLock { storedQueries } }

    func read(
        query: String,
        variables: [String: GitHubQueryValue]
    ) async throws -> Data {
        try lock.withLock {
            storedMetrics.requestCount += 1
            storedMetrics.selectedFieldFootprint += query.utf8.count
            storedMetrics.injectedNetworkDelay += delayPerRequest
            storedMetrics.completeHydrationRequests += query.contains("CompletePullRequests") ? 1 : 0
            storedMetrics.continuationRequests += query.contains("ContinuePullRequestConnections") ? 1 : 0
            storedQueries.append(query)
            if let terminalError { throw terminalError }
            guard !responses.isEmpty else { throw GitHubReadError.invalidPayload }
            let response = responses.removeFirst()
            storedMetrics.responsePayloadBytes += response.count
            return response
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // The fixture intentionally proves the failed attempt stops without partial success.
    }
}
