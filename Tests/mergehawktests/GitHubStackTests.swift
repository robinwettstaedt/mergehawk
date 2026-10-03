@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubStackTests: XCTestCase {
    func testStackWithThreeEntriesNormalizesInPositionOrderWithStateDraftAndAuthor() async throws {
        let transport = StackTransport { _, _ in
            Self.stacksPage([
                Self.stack("STACK_1", size: 3, entries: [
                    Self.entry(3, id: "PR_3", state: "CLOSED", author: nil),
                    Self.entry(1, id: "PR_1", state: "MERGED"),
                    Self.entry(2, id: "PR_2", state: "OPEN", isDraft: true, author: "octo")
                ])
            ])
        }

        let stacks = try await Self.fetcher(transport).fetchStacks(ids: ["STACK_1"])

        XCTAssertEqual(stacks, [
            PullRequestStack(id: "STACK_1", size: 3, entries: [
                Self.expectedEntry(1, id: "PR_1", state: .merged),
                Self.expectedEntry(2, id: "PR_2", state: .open, isDraft: true, author: "octo"),
                Self.expectedEntry(3, id: "PR_3", state: .closed, author: "unknown", avatar: nil)
            ])
        ])
        XCTAssertEqual(stacks[0].entries.map(\.position), [1, 2, 3])
        XCTAssertEqual(transport.queries.count, 1)
        XCTAssertEqual(transport.queries[0].variables["ids"], .strings(["STACK_1"]))
        XCTAssertTrue(transport.queries[0].query.contains("... on PullRequestStack"))
    }

    func testEntriesSpanningTwoPagesAreCombinedAndTheSecondReadCarriesCursorAndStackID() async throws {
        let transport = StackTransport { query, _ in
            if query.contains("PullRequestStackEntries") {
                return Self.entriesPage([Self.entry(2, id: "PR_2")], total: 2)
            }
            return Self.stacksPage([
                Self.stack("STACK_1", size: 2, entries: [Self.entry(1, id: "PR_1")], total: 2, nextCursor: "PAGE_1")
            ])
        }

        let stacks = try await Self.fetcher(transport).fetchStacks(ids: ["STACK_1"])

        XCTAssertEqual(stacks.first?.entries.map(\.pullRequestID), ["PR_1", "PR_2"])
        XCTAssertEqual(transport.queries.count, 2)
        XCTAssertEqual(transport.queries[1].variables["id"], .string("STACK_1"))
        XCTAssertEqual(transport.queries[1].variables["cursor"], .string("PAGE_1"))
        XCTAssertTrue(transport.queries[1].query.contains("after: $cursor"))
    }

    func testEntryWithoutAPullRequestIsSkippedAndPositionsAndSizeStayUnchanged() async throws {
        let transport = StackTransport { _, _ in
            Self.stacksPage([
                Self.stack("STACK_1", size: 4, entries: [
                    Self.entry(1, id: "PR_1"),
                    Self.entry(2, id: "PR_2"),
                    ["position": 3, "pullRequest": NSNull()],
                    Self.entry(4, id: "PR_4")
                ])
            ])
        }

        let stack = try await Self.fetcher(transport).fetchStacks(ids: ["STACK_1"]).first

        XCTAssertEqual(stack?.size, 4)
        XCTAssertEqual(stack?.entries.map(\.position), [1, 2, 4])
    }

    func testEntryCountThatDoesNotMatchTotalCountThrowsIncompleteCoverage() async throws {
        let transport = StackTransport { _, _ in
            Self.stacksPage([Self.stack("STACK_1", size: 3, entries: [Self.entry(1, id: "PR_1")], total: 3)])
        }

        await assertIncompleteCoverage { try await Self.fetcher(transport).fetchStacks(ids: ["STACK_1"]) }
    }

    func testRepeatedEntriesCursorThrowsIncompleteCoverage() async throws {
        let transport = StackTransport { query, _ in
            if query.contains("PullRequestStackEntries") {
                return Self.entriesPage([Self.entry(2, id: "PR_2")], total: 3, nextCursor: "PAGE_1")
            }
            return Self.stacksPage([
                Self.stack("STACK_1", size: 3, entries: [Self.entry(1, id: "PR_1")], total: 3, nextCursor: "PAGE_1")
            ])
        }

        await assertIncompleteCoverage { try await Self.fetcher(transport).fetchStacks(ids: ["STACK_1"]) }
    }

    func testNotFoundStackIsDroppedAndTheOthersInTheBatchAreKept() async throws {
        let transport = StackTransport { _, _ in
            Self.json([
                "data": ["nodes": [
                    NSNull(),
                    Self.stack("STACK_2", size: 2, entries: [Self.entry(1, id: "PR_1"), Self.entry(2, id: "PR_2")])
                ]],
                "errors": [["type": "NOT_FOUND", "message": "Could not resolve to a node", "path": ["nodes", 0]]]
            ])
        }

        let stacks = try await Self.fetcher(transport).fetchStacks(ids: ["STACK_1", "STACK_2"])

        XCTAssertEqual(stacks.map(\.id), ["STACK_2"])
    }

    func testNonNotFoundErrorFailsTheRead() async throws {
        let transport = StackTransport { _, _ in
            Self.json([
                "data": ["nodes": [NSNull()]],
                "errors": [["type": "FORBIDDEN", "message": "Resource not accessible", "path": ["nodes", 0]]]
            ])
        }

        do {
            _ = try await Self.fetcher(transport).fetchStacks(ids: ["STACK_1"])
            XCTFail("Expected the stack read to fail")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .accessDenied)
        }
    }

    func testTwentyOneStackIDsAreReadInTwoBatches() async throws {
        let ids = (1...21).map { "STACK_\($0)" }
        let transport = StackTransport { _, variables in
            guard case .strings(let batch) = variables["ids"] else { throw GitHubReadError.invalidPayload }
            return Self.stacksPage(batch.map { Self.stack($0, size: 2, entries: [
                Self.entry(1, id: "\($0)_PR_1"), Self.entry(2, id: "\($0)_PR_2")
            ]) })
        }

        let stacks = try await Self.fetcher(transport).fetchStacks(ids: ids)

        XCTAssertEqual(stacks.map(\.id), ids)
        XCTAssertEqual(transport.queries.map(\.variables["ids"]), [
            .strings(Array(ids[0..<20])),
            .strings(["STACK_21"])
        ])
    }

    func testEmptyIDListMakesNoRequest() async throws {
        let transport = StackTransport { _, _ in
            XCTFail("Unexpected request")
            return Data()
        }

        let stacks = try await Self.fetcher(transport).fetchStacks(ids: [])

        XCTAssertEqual(stacks, [])
        XCTAssertTrue(transport.queries.isEmpty)
    }

    private func assertIncompleteCoverage(
        _ operation: () async throws -> [PullRequestStack],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected incomplete coverage", file: file, line: line)
        } catch GitHubReadError.incompleteCoverage {
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private static func fetcher(_ transport: StackTransport) -> GitHubPullRequestFetcher {
        GitHubPullRequestFetcher { query, variables in
            try await transport.read(query: query, variables: variables)
        }
    }

    private static func stacksPage(_ stacks: [[String: Any]]) -> Data {
        json(["data": ["nodes": stacks]])
    }

    private static func entriesPage(_ entries: [[String: Any]], total: Int, nextCursor: String? = nil) -> Data {
        json(["data": ["node": ["entries": connection(entries, total: total, nextCursor: nextCursor)]]])
    }

    private static func stack(
        _ id: String,
        size: Int,
        entries: [[String: Any]],
        total: Int? = nil,
        nextCursor: String? = nil
    ) -> [String: Any] {
        ["id": id, "size": size, "entries": connection(entries, total: total ?? entries.count, nextCursor: nextCursor)]
    }

    private static func connection(_ entries: [[String: Any]], total: Int, nextCursor: String?) -> [String: Any] {
        [
            "totalCount": total,
            "pageInfo": ["hasNextPage": nextCursor != nil, "endCursor": nextCursor.map { $0 as Any } ?? NSNull()],
            "nodes": entries
        ]
    }

    private static func entry(
        _ position: Int,
        id: String,
        state: String = "OPEN",
        isDraft: Bool = false,
        author: String? = "author"
    ) -> [String: Any] {
        [
            "position": position,
            "pullRequest": [
                "id": id,
                "number": position,
                "title": "Stack member \(position)",
                "url": "https://github.com/acme/app/pull/\(position)",
                "state": state,
                "isDraft": isDraft,
                "author": author.map { ["login": $0, "avatarUrl": "https://avatars.githubusercontent.com/\($0)"] as Any }
                    ?? NSNull()
            ] as [String: Any]
        ]
    }

    private static func expectedEntry(
        _ position: Int,
        id: String,
        state: PullRequestStackEntry.State,
        isDraft: Bool = false,
        author: String = "author",
        avatar: String? = "default"
    ) -> PullRequestStackEntry {
        PullRequestStackEntry(
            position: position,
            pullRequestID: id,
            number: position,
            title: "Stack member \(position)",
            url: URL(string: "https://github.com/acme/app/pull/\(position)")!,
            state: state,
            isDraft: isDraft,
            author: author,
            authorAvatarURL: avatar.map { _ in URL(string: "https://avatars.githubusercontent.com/\(author)")! }
        )
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private final class StackTransport: @unchecked Sendable {
    typealias Handler = (String, [String: GitHubQueryValue]) throws -> Data
    private let handler: Handler
    private let lock = NSLock()
    private var storedQueries: [(query: String, variables: [String: GitHubQueryValue])] = []
    var queries: [(query: String, variables: [String: GitHubQueryValue])] { lock.withLock { storedQueries } }

    init(_ handler: @escaping Handler) { self.handler = handler }

    func read(query: String, variables: [String: GitHubQueryValue]) async throws -> Data {
        lock.withLock { storedQueries.append((query, variables)) }
        return try handler(query, variables)
    }
}
