@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubDiscoveryTests: XCTestCase {
    func testInitialDiscoveryPageUsesAllFourRelationshipSelectors() async throws {
        let transport = DiscoveryTransport { query, variables in
            if query.contains("DiscoveryBounds") {
                return Self.boundsResponse(nonEmptyLanes: Set(GitHubDiscoveryLane.allCases))
            }

            let expectedSelectors: [GitHubDiscoveryLane: String] = [
                .authored: "author:rw",
                .assigned: "assignee:rw",
                .direct: "user-review-requested:@me",
                .team: "team-review-requested-user:rw"
            ]
            for lane in GitHubDiscoveryLane.allCases {
                let laneQuery = Self.query(for: lane, variables: variables)
                XCTAssertTrue(laneQuery.contains("is:open is:pr"))
                XCTAssertTrue(laneQuery.contains(try XCTUnwrap(expectedSelectors[lane])))
                XCTAssertTrue(laneQuery.contains("created:"))
            }
            return Self.pageResponse(activeLanes: [], count: 0, nodes: [])
        }

        let result = try await Self.fetcher(transport).discover(login: "rw")

        XCTAssertTrue(result.pullRequests.isEmpty)
        XCTAssertEqual(transport.readCount, 2)
    }

    func testDeduplicatesAcrossRelationshipLanesAndUnionsFlags() async throws {
        let transport = DiscoveryTransport { query, variables in
            if query.contains("DiscoveryBounds") {
                return Self.boundsResponse(nonEmptyLanes: Set(GitHubDiscoveryLane.allCases))
            }
            let node = Self.node(id: "PR_SHARED", number: 7)
            return Self.pageResponse(activeLanes: Set(GitHubDiscoveryLane.allCases), count: 1, nodes: [node])
        }

        let result = try await Self.fetcher(transport).discover(login: "rw")

        XCTAssertEqual(result.pullRequests.count, 1)
        XCTAssertEqual(result.pullRequests[0].repository, "acme/app")
        XCTAssertTrue(result.pullRequests[0].isAuthored)
        XCTAssertTrue(result.pullRequests[0].isAssigned)
        XCTAssertTrue(result.pullRequests[0].isDirectlyRequested)
        XCTAssertTrue(result.pullRequests[0].isTeamRequested)
    }

    func testLaneEmptyAtBoundsQueryStillReturnsPRsCreatedSince() async throws {
        let transport = DiscoveryTransport { query, variables in
            if query.contains("DiscoveryBounds") {
                return Self.boundsResponse(nonEmptyLanes: [])
            }
            XCTAssertFalse(Self.query(for: .direct, variables: variables).contains("created:"))
            return Self.pageResponse(activeLanes: [.direct], count: 1, nodes: [Self.node(id: "PR_NEW", number: 9, second: 5)])
        }

        let result = try await Self.fetcher(transport).discover(login: "rw")

        XCTAssertEqual(result.pullRequests.map(\.id), ["PR_NEW"])
        XCTAssertTrue(result.pullRequests[0].isDirectlyRequested)
        XCTAssertEqual(result.coveredIntervals[.direct], [5...5])
        XCTAssertEqual(transport.readCount, 2)
    }

    func testPaginatesBeyondFirstHundredWithAdvancingCursor() async throws {
        let transport = DiscoveryTransport { query, variables in
            if query.contains("DiscoveryBounds") {
                return Self.boundsResponse(nonEmptyLanes: [.authored])
            }
            let cursor = Self.cursor(for: .authored, variables: variables)
            let nodes: [[String: Any]]
            let hasNext: Bool
            if cursor == nil {
                nodes = (0..<100).map { Self.node(id: "PR_\($0)", number: $0) }
                hasNext = true
            } else {
                nodes = (100..<125).map { Self.node(id: "PR_\($0)", number: $0) }
                hasNext = false
            }
            return Self.pageResponse(active: .authored, count: 125, nodes: nodes, hasNext: hasNext)
        }

        let result = try await Self.fetcher(transport).discover(login: "rw")

        XCTAssertEqual(result.pullRequests.count, 125)
        XCTAssertEqual(transport.readCount, 3)
    }

    func testOverCapRangeSplitsIntoDisjointWholeSecondLeaves() async throws {
        let transport = DiscoveryTransport { query, variables in
            if query.contains("DiscoveryBounds") {
                return Self.boundsResponse(nonEmptyLanes: [.authored], oldest: 0, newest: 3)
            }
            let queryValue = Self.query(for: .authored, variables: variables)
            if queryValue.contains("created:>=1970-01-01T00:00:00Z") {
                return Self.pageResponse(active: .authored, count: 1_001, nodes: [], hasNext: false)
            }
            if queryValue.contains("00:00:00Z..1970-01-01T00:00:01Z") {
                return Self.pageResponse(active: .authored, count: 1, nodes: [Self.node(id: "LOW", number: 1)], hasNext: false)
            }
            return Self.pageResponse(active: .authored, count: 1, nodes: [Self.node(id: "HIGH", number: 2, second: 3)], hasNext: false)
        }

        let result = try await Self.fetcher(transport).discover(login: "rw")

        XCTAssertEqual(Set(result.pullRequests.map(\.id)), ["LOW", "HIGH"])
        XCTAssertEqual(result.coveredIntervals[.authored], [0...1, 2...3])
    }

    func testSingleSecondOverCapAndNonAdvancingCursorFailExplicitly() async throws {
        let capped = DiscoveryTransport { query, _ in
            if query.contains("DiscoveryBounds") {
                return Self.boundsResponse(nonEmptyLanes: [.authored], oldest: 0, newest: 0)
            }
            return Self.pageResponse(active: .authored, count: 1_001, nodes: [], hasNext: false)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await Self.fetcher(capped).discover(login: "rw")
        }

        let stuck = DiscoveryTransport { query, variables in
            if query.contains("DiscoveryBounds") {
                return Self.boundsResponse(nonEmptyLanes: [.authored])
            }
            _ = variables
            return Self.pageResponse(
                active: .authored,
                count: 101,
                nodes: [Self.node(id: UUID().uuidString, number: 1)],
                hasNext: true,
                cursor: "same"
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await Self.fetcher(stuck).discover(login: "rw")
        }
    }

    func testRepositoryTeamConfirmationPartitionsOverCapWithFixedBounds() async throws {
        let transport = DiscoveryTransport { _, variables in
            guard case .string(let query) = variables["query"] else {
                throw GitHubReadError.invalidPayload
            }
            if query.contains("sort:created-asc") {
                return Self.repositoryPage(count: 1_001, nodes: [Self.node(id: "OLD", number: 1, second: 0)])
            }
            if query.contains("sort:created-desc") {
                return Self.repositoryPage(count: 1_001, nodes: [Self.node(id: "NEW", number: 2, second: 3)])
            }
            if query.contains("created:>=1970-01-01T00:00:00Z") {
                return Self.repositoryPage(count: 1_001, nodes: [])
            }
            if query.contains("00:00:00Z..1970-01-01T00:00:01Z") {
                return Self.repositoryPage(count: 1, nodes: [Self.node(id: "LOW", number: 3)])
            }
            return Self.repositoryPage(count: 1, nodes: [Self.node(id: "HIGH", number: 4, second: 3)])
        }

        let ids = try await Self.fetcher(transport).repositoryTeamRequestedPullRequestIDs(
            repository: "acme/app",
            login: "rw"
        )

        XCTAssertEqual(ids, ["LOW", "HIGH"])
    }

    func testDiscoveryKeepsStartBoundsAndAcceptsClosingResultsAboveFinalCount() async throws {
        let transport = DiscoveryTransport { query, variables in
            if query.contains("DiscoveryBounds") {
                return Self.boundsResponse(nonEmptyLanes: [.authored], oldest: 0, newest: 10)
            }
            let bounded = Self.query(for: .authored, variables: variables)
            XCTAssertTrue(bounded.contains("created:>=1970-01-01T00:00:00Z"))
            let cursor = Self.cursor(for: .authored, variables: variables)
            if cursor == nil {
                return Self.pageResponse(
                    active: .authored,
                    count: 2,
                    nodes: [Self.node(id: "CLOSED_DURING_READ", number: 1)],
                    hasNext: true
                )
            }
            return Self.pageResponse(
                active: .authored,
                count: 1,
                nodes: [Self.node(id: "STILL_OPEN", number: 2, second: 10)],
                hasNext: false
            )
        }

        let result = try await Self.fetcher(transport).discover(login: "rw")

        XCTAssertEqual(Set(result.pullRequests.map(\.id)), ["CLOSED_DURING_READ", "STILL_OPEN"])
    }

    func testDiscoveryRetriesAnUndercountLeafOnce() async throws {
        let attempts = LockedInt()
        let transport = DiscoveryTransport { query, _ in
            if query.contains("DiscoveryBounds") {
                return Self.boundsResponse(nonEmptyLanes: [.authored])
            }
            let attempt = attempts.increment()
            return Self.pageResponse(
                active: .authored,
                count: 2,
                nodes: attempt == 1
                    ? [Self.node(id: "ONE", number: 1)]
                    : [Self.node(id: "ONE", number: 1), Self.node(id: "TWO", number: 2)],
                hasNext: false
            )
        }

        let result = try await Self.fetcher(transport).discover(login: "rw")

        XCTAssertEqual(Set(result.pullRequests.map(\.id)), ["ONE", "TWO"])
        XCTAssertEqual(attempts.value, 2)
    }

    func testMidPaginationCapCrossingRepartitionsTheFixedInterval() async throws {
        let fullIntervalReads = LockedInt()
        let transport = DiscoveryTransport { query, variables in
            if query.contains("DiscoveryBounds") {
                return Self.boundsResponse(nonEmptyLanes: [.authored], oldest: 0, newest: 3)
            }
            let queryValue = Self.query(for: .authored, variables: variables)
            if queryValue.contains("created:>=1970-01-01T00:00:00Z") {
                let read = fullIntervalReads.increment()
                if read == 1 {
                    return Self.pageResponse(
                        active: .authored,
                        count: 101,
                        nodes: [Self.node(id: "INITIAL", number: 1)],
                        hasNext: true,
                        cursor: "next"
                    )
                }
                return Self.pageResponse(active: .authored, count: 1_001, nodes: [], hasNext: false)
            }
            if queryValue.contains("00:00:00Z..1970-01-01T00:00:01Z") {
                return Self.pageResponse(
                    active: .authored,
                    count: 1,
                    nodes: [Self.node(id: "LOW", number: 2)],
                    hasNext: false
                )
            }
            return Self.pageResponse(
                active: .authored,
                count: 1,
                nodes: [Self.node(id: "HIGH", number: 3, second: 3)],
                hasNext: false
            )
        }

        let result = try await Self.fetcher(transport).discover(login: "rw")

        XCTAssertEqual(Set(result.pullRequests.map(\.id)), ["LOW", "HIGH"])
        XCTAssertEqual(result.coveredIntervals[.authored], [0...1, 2...3])
        XCTAssertGreaterThanOrEqual(fullIntervalReads.value, 2)
    }

    private static func boundsResponse(
        nonEmptyLanes: Set<GitHubDiscoveryLane>,
        oldest: Int = 0,
        newest: Int = 10
    ) -> Data {
        var data: [String: Any] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            let nodes = nonEmptyLanes.contains(lane) ? [node(id: "BOUND", number: 1, second: oldest)] : []
            let newestNodes = nonEmptyLanes.contains(lane) ? [node(id: "BOUND", number: 1, second: newest)] : []
            data["\(lane.rawValue)Oldest"] = ["nodes": nodes]
            data["\(lane.rawValue)Newest"] = ["nodes": newestNodes]
        }
        return json(["data": data])
    }

    private static func pageResponse(
        active: GitHubDiscoveryLane,
        count: Int,
        nodes: [[String: Any]],
        hasNext: Bool,
        cursor: String = "next"
    ) -> Data {
        var data: [String: Any] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            let isActive = lane == active
            data[lane.rawValue] = [
                "issueCount": isActive ? count : 0,
                "nodes": isActive ? nodes : [],
                "pageInfo": [
                    "startCursor": isActive ? "start" : NSNull() as Any,
                    "endCursor": isActive ? cursor : NSNull() as Any,
                    "hasPreviousPage": false,
                    "hasNextPage": isActive ? hasNext : false
                ]
            ]
        }
        return json(["data": data])
    }

    private static func repositoryPage(
        count: Int,
        nodes: [[String: Any]],
        hasNext: Bool = false,
        cursor: String = "next"
    ) -> Data {
        json(["data": ["search": [
            "issueCount": count,
            "nodes": nodes,
            "pageInfo": [
                "startCursor": NSNull(),
                "endCursor": hasNext ? cursor as Any : NSNull(),
                "hasPreviousPage": false,
                "hasNextPage": hasNext
            ]
        ]]])
    }

    private static func pageResponse(
        activeLanes: Set<GitHubDiscoveryLane>,
        count: Int,
        nodes: [[String: Any]]
    ) -> Data {
        var data: [String: Any] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            let isActive = activeLanes.contains(lane)
            data[lane.rawValue] = [
                "issueCount": isActive ? count : 0,
                "nodes": isActive ? nodes : [],
                "pageInfo": [
                    "startCursor": NSNull(), "endCursor": NSNull(),
                    "hasPreviousPage": false, "hasNextPage": false
                ]
            ]
        }
        return json(["data": data])
    }

    private static func node(id: String, number: Int, second: Int = 0) -> [String: Any] {
        [
            "id": id,
            "number": number,
            "createdAt": isoSecond(second),
            "repository": ["nameWithOwner": "acme/app"]
        ]
    }

    private static func activeLane(_ variables: [String: GitHubQueryValue]) -> GitHubDiscoveryLane {
        GitHubDiscoveryLane.allCases.first { !query(for: $0, variables: variables).contains("__empty__") }!
    }

    private static func query(for lane: GitHubDiscoveryLane, variables: [String: GitHubQueryValue]) -> String {
        guard case .string(let value) = variables["\(lane.rawValue)Query"] else { return "" }
        return value
    }

    private static func cursor(for lane: GitHubDiscoveryLane, variables: [String: GitHubQueryValue]) -> String? {
        guard case .string(let value) = variables["\(lane.rawValue)Cursor"] else { return nil }
        return value
    }

    private static func isoSecond(_ second: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(second)))
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func fetcher(_ transport: DiscoveryTransport) -> GitHubPullRequestFetcher {
        GitHubPullRequestFetcher { query, variables in
            try await transport.read(query: query, variables: variables)
        }
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() -> Int { lock.withLock { stored += 1; return stored } }
}

private final class DiscoveryTransport: @unchecked Sendable {
    typealias Handler = (String, [String: GitHubQueryValue]) throws -> Data
    private let handler: Handler
    private let lock = NSLock()
    private var storedReadCount = 0
    var readCount: Int { lock.withLock { storedReadCount } }

    init(_ handler: @escaping Handler) { self.handler = handler }

    func read(query: String, variables: [String: GitHubQueryValue]) async throws -> Data {
        lock.withLock { storedReadCount += 1 }
        guard query.contains("SearchPullRequests"),
              case .string(let searchQuery) = variables["query"],
              !searchQuery.contains(" repo:") else {
            return try handler(query, variables)
        }
        return try laneSearch(variables: variables)
    }

    /// Serves single-lane search pages through the multi-lane handlers, marking inactive lanes as empty.
    private func laneSearch(variables: [String: GitHubQueryValue]) throws -> Data {
        guard case .string(let searchQuery) = variables["query"] else { throw GitHubReadError.invalidPayload }
        let selectors: [GitHubDiscoveryLane: String] = [
            .authored: "author:", .assigned: "assignee:",
            .direct: "user-review-requested:", .team: "team-review-requested-user:"
        ]
        let lane = GitHubDiscoveryLane.allCases.first { searchQuery.contains(selectors[$0]!) }!
        var laneVariables: [String: GitHubQueryValue] = [:]
        for candidate in GitHubDiscoveryLane.allCases {
            let isActive = candidate == lane
            laneVariables["\(candidate.rawValue)Query"] = .string(
                isActive ? searchQuery : "is:open is:pr repo:__mergehawk__/__empty__"
            )
            laneVariables["\(candidate.rawValue)Cursor"] = isActive ? variables["cursor"] ?? .null : .null
        }
        let data = try handler(GitHubPullRequestQueries.discoveryPage, laneVariables)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let lanes = object["data"] as? [String: Any] {
            object["data"] = ["search": lanes[lane.rawValue] as Any]
        }
        return try JSONSerialization.data(withJSONObject: object)
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
        XCTAssertTrue(error is GitHubReadError, file: file, line: line)
    }
}
