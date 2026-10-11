@testable import mergehawkcore
import CryptoKit
import Foundation
import XCTest

/// Golden `PullRequest` output for a named fixture set, recorded from the fetcher before review threads stopped
/// nesting their comments. A hash mismatch means the fetcher's output changed for the same GitHub data.
final class GitHubHydrationGoldenTests: XCTestCase {
    private typealias Fixtures = GitHubPaginationTests

    func testRichThreadsOutputIsUnchanged() async throws {
        try await assertGolden(
            "richThreads",
            pullRequests: [Self.richThreads()],
            discoveries: [Fixtures.discovery(id: "PR_RICH", isTeamRequested: true)],
            hash: "bcefb6d2e289fc8567c1ee36d8f6d231cbe21d80522de70e6bd3c87df0af4bab"
        )
    }

    func testLongThreadOutputIsUnchanged() async throws {
        try await assertGolden(
            "longThread",
            pullRequests: [Self.longThread()],
            discoveries: [Fixtures.discovery(id: "PR_LONG")],
            hash: "c4c119c4d00184450b23c616cba4c467c585f61c797d6036a5a4dd657197f444"
        )
    }

    func testManyThreadsOutputIsUnchanged() async throws {
        try await assertGolden(
            "manyThreads",
            pullRequests: [Self.manyThreads()],
            discoveries: [Fixtures.discovery(id: "PR_MANY")],
            hash: "f3193c1a7b225181903034479c09166b92e61751782c531b4aef9fb5fd9207e3"
        )
    }

    func testNoThreadsOutputIsUnchanged() async throws {
        try await assertGolden(
            "noThreads",
            pullRequests: [Self.noThreads()],
            discoveries: [Fixtures.discovery(id: "PR_NONE")],
            hash: "fec83f4db758a2cd66319330161eeb8ab2821de782d86396951d1ebcfca7b5be"
        )
    }

    func testBatchOf25OutputIsUnchanged() async throws {
        let pullRequests = Self.batch25()
        try await assertGolden(
            "batch25",
            pullRequests: pullRequests,
            discoveries: pullRequests.map { Fixtures.discovery(id: $0["id"] as! String) },
            hash: "b475761b66e1bceb355be9a6a3973da3661baf626fb9c538dde6764ca32be1ed"
        )
    }

    func testFixtureServerNestsThreadCommentsOnlyWhenTheHydrationSelectsThem() async throws {
        let nested = Self.hydrationShape(threadNodes: "id isResolved viewerCanResolve comments(last: 10) { totalCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage } nodes { id } }")
        let identityOnly = Self.hydrationShape(threadNodes: "id isResolved viewerCanResolve")
        for (query, expectsComments) in [(nested, true), (identityOnly, false)] {
            let server = GitHubFixtureServer(pullRequests: [Self.richThreads()])
            let data = try await server.read(query: query, variables: ["ids": .strings(["PR_RICH"])])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let nodes = try XCTUnwrap((object["data"] as? [String: Any])?["nodes"] as? [[String: Any]])
            let threads = try XCTUnwrap((nodes[0]["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]])
            XCTAssertEqual(threads.count, 8)
            XCTAssertTrue(threads.allSatisfy { ($0["comments"] != nil) == expectsComments })
            if expectsComments {
                let tenComments = try XCTUnwrap(threads.first { $0["id"] as? String == "T_TEN" })
                XCTAssertEqual((tenComments["comments"] as? [String: Any])?["totalCount"] as? Int, 10)
            }
        }
    }

    // MARK: Golden comparison

    private func assertGolden(
        _ name: String,
        pullRequests: [[String: Any]],
        discoveries: [DiscoveredPullRequest],
        hash expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let server = GitHubFixtureServer(pullRequests: pullRequests)
        let hydrated = try await server.fetcher.hydrate(discoveries, login: "rw")
        let json = try Self.normalizedJSON(hydrated.map(\.pullRequest))
        let hash = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
        if hash != expected {
            XCTFail(
                "\(name) output hash \(hash) differs from golden \(expected). Output:\n\(String(decoding: json, as: UTF8.self))",
                file: file,
                line: line
            )
        }
    }

    /// Tied timestamps keep dictionary order in the fetcher, so lists are compared in (time, id) order.
    private static func normalizedJSON(_ pullRequests: [PullRequest]) throws -> Data {
        let normalized = pullRequests.map { pullRequest in
            var value = pullRequest
            value.recentCommentActivities.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            value.recentReviews.sort { ($0.submittedAt, $0.id) < ($1.submittedAt, $1.id) }
            return value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(normalized)
    }

    private static func hydrationShape(threadNodes: String) -> String {
        let connection = "totalCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage } nodes { id }"
        return """
        query CompletePullRequests($ids: [ID!]!) {
          nodes(ids: $ids) {
            ... on PullRequest {
              id
              comments(last: 10) { \(connection) }
              reviews(last: 10) { \(connection) }
              latestOpinionatedReviews(last: 20) { \(connection) }
              reviewThreads(last: 20) { totalCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage } nodes { \(threadNodes) } }
              assignees(last: 20) { \(connection) }
              reviewRequests(last: 20) { \(connection) }
            }
          }
        }
        """
    }

    // MARK: Fixtures

    private static let mentionHTML =
        #"<p><a class="user-mention notranslate" data-hovercard-type="user" href="https://github.com/rw">@rw</a> please look</p>"#
    private static let tiedTime = "2026-04-01T10:00:00Z"

    private static func time(_ minute: Int) -> String {
        String(format: "2026-04-01T%02d:%02d:00Z", 8 + minute / 60, minute % 60)
    }

    private static func richThreads() -> [String: Any] {
        var botComment = Fixtures.comment("C_BOT", author: "ci-bot[bot]", createdAt: time(1), typename: "Bot")
        botComment.removeValue(forKey: "state")
        var mentionComment = Fixtures.comment("C_MENTION", author: "teammate", createdAt: tiedTime)
        mentionComment.removeValue(forKey: "state")
        mentionComment["bodyHTML"] = mentionHTML
        var sharedTopLevel = Fixtures.comment("SHARED_ID", author: "teammate", createdAt: tiedTime)
        sharedTopLevel.removeValue(forKey: "state")

        var commentSummary = Fixtures.review("R_COMMENT", state: "COMMENTED", author: "teammate", submittedAt: time(30))
        commentSummary["bodyHTML"] = mentionHTML
        commentSummary["bodyText"] = "@rw please look"
        var pendingReview = Fixtures.review("R_PENDING", state: "PENDING", author: "rw", viewerDidAuthor: true)
        pendingReview["submittedAt"] = NSNull()
        let reviews = [
            Fixtures.review("R_APPROVED", state: "APPROVED", author: "approver", submittedAt: time(20)),
            Fixtures.review("R_CHANGES", state: "CHANGES_REQUESTED", author: "blocker", submittedAt: tiedTime),
            commentSummary,
            pendingReview
        ]
        var opinionatedChanges = Fixtures.leanReview("R_CHANGES", state: "CHANGES_REQUESTED")
        opinionatedChanges["author"] = Fixtures.user("blocker")

        var pendingInline = Fixtures.comment("T_PENDING_DRAFT", viewerDidAuthor: true, createdAt: time(40))
        pendingInline["state"] = "PENDING"
        var submittedWithoutPublication = Fixtures.comment("T_PENDING_SUBMITTED", author: "teammate", createdAt: time(41))
        submittedWithoutPublication["publishedAt"] = NSNull()
        var nullAuthor = Fixtures.comment("T_MIXED_GHOST", createdAt: tiedTime)
        nullAuthor["author"] = NSNull()
        var threadMention = Fixtures.comment("T_MIXED_MENTION", author: "teammate", createdAt: time(52))
        threadMention["bodyHTML"] = mentionHTML

        let threads = [
            Fixtures.thread("T_ACTIONABLE", comments: [
                Fixtures.comment("T_ACTIONABLE_1", author: "reviewer", createdAt: tiedTime)
            ]),
            Fixtures.thread("T_RESOLVED", isResolved: true, comments: [
                Fixtures.comment("T_RESOLVED_1", author: "reviewer", createdAt: time(10))
            ]),
            Fixtures.thread("T_UNRESOLVABLE", viewerCanResolve: false, comments: [
                Fixtures.comment("T_UNRESOLVABLE_1", author: "reviewer", createdAt: time(11))
            ]),
            Fixtures.thread("T_SELF", comments: [
                Fixtures.comment("T_SELF_1", viewerDidAuthor: true, createdAt: time(12)),
                Fixtures.comment("T_SELF_2", viewerDidAuthor: true, createdAt: time(13))
            ]),
            Fixtures.thread("T_PENDING", comments: [submittedWithoutPublication, pendingInline]),
            Fixtures.thread("T_EMPTY"),
            Fixtures.thread("T_TEN", comments: (0..<10).map { index in
                Fixtures.comment(
                    "T_TEN_\(index)",
                    viewerDidAuthor: index % 3 == 0,
                    createdAt: index < 3 ? tiedTime : time(60 + index)
                )
            }),
            Fixtures.thread("T_MIXED", comments: [
                Fixtures.comment("T_MIXED_BOT", author: "lint-bot", createdAt: time(50), typename: "Bot"),
                nullAuthor,
                Fixtures.comment("T_MIXED_REVIEWED", author: "teammate", createdAt: time(51), reviewID: "R_COMMENT"),
                threadMention,
                Fixtures.comment("SHARED_ID", author: "teammate", createdAt: tiedTime, reviewID: "R_APPROVED")
            ])
        ]
        var node = Fixtures.pullRequest(
            id: "PR_RICH",
            comments: Fixtures.connection(total: 3, nodes: [botComment, mentionComment, sharedTopLevel]),
            reviews: Fixtures.connection(total: 4, nodes: reviews),
            opinionated: Fixtures.connection(total: 2, nodes: [Fixtures.leanReview("R_APPROVED"), opinionatedChanges]),
            threads: Fixtures.connection(total: threads.count, nodes: threads),
            assignees: Fixtures.connection(total: 2, nodes: [Fixtures.user("rw"), Fixtures.user("teammate")]),
            requests: Fixtures.connection(total: 2, nodes: [
                Fixtures.request("Q_USER", login: "rw"),
                Fixtures.request("Q_TEAM", typeName: "Team", teamSlug: "reviewers")
            ]),
            reviewDecision: "REVIEW_REQUIRED"
        )
        node["title"] = "Rich review threads"
        return node
    }

    private static func longThread() -> [String: Any] {
        let comments = (0..<25).map { index in
            Fixtures.comment(
                "LT_C\(index)",
                viewerDidAuthor: index % 4 == 0,
                createdAt: index % 5 == 0 ? tiedTime : time(index),
                reviewID: index % 2 == 0 ? "LT_R" : nil
            )
        }
        return Fixtures.pullRequest(
            id: "PR_LONG",
            threads: Fixtures.connection(total: 1, nodes: [Fixtures.thread("LT_T", comments: comments)])
        )
    }

    private static func manyThreads() -> [String: Any] {
        let threads = (0..<130).map { index in
            Fixtures.thread(
                "MT_T\(index)",
                isResolved: index % 7 == 0,
                viewerCanResolve: index % 11 != 0,
                comments: (0...(index % 3)).map { offset in
                    Fixtures.comment(
                        "MT_T\(index)_C\(offset)",
                        viewerDidAuthor: (index + offset) % 4 == 0,
                        createdAt: time((index * 3 + offset) % 600)
                    )
                }
            )
        }
        return Fixtures.pullRequest(
            id: "PR_MANY",
            threads: Fixtures.connection(total: threads.count, nodes: threads)
        )
    }

    private static func noThreads() -> [String: Any] {
        var comment = Fixtures.comment("NT_C0", author: "teammate", createdAt: time(5))
        comment.removeValue(forKey: "state")
        var node = Fixtures.pullRequest(
            id: "PR_NONE",
            comments: Fixtures.connection(total: 1, nodes: [comment]),
            reviews: Fixtures.connection(total: 1, nodes: [
                Fixtures.review("NT_R0", state: "APPROVED", author: "approver", submittedAt: time(6))
            ]),
            opinionated: Fixtures.connection(total: 1, nodes: [Fixtures.leanReview("NT_R0")]),
            reviewDecision: "APPROVED"
        )
        node["stack"] = ["id": "STACK_NONE"]
        return node
    }

    private static func batch25() -> [[String: Any]] {
        (0..<25).map { prIndex in
            let id = String(format: "PR_B%02d", prIndex)
            let threads = (0..<(prIndex % 5)).map { threadIndex in
                Fixtures.thread(
                    "\(id)_T\(threadIndex)",
                    isResolved: threadIndex == 3,
                    comments: (0...(threadIndex % 2)).map { offset in
                        Fixtures.comment(
                            "\(id)_T\(threadIndex)_C\(offset)",
                            viewerDidAuthor: (prIndex + threadIndex + offset) % 3 == 0,
                            createdAt: time((prIndex * 7 + threadIndex * 2 + offset) % 600)
                        )
                    }
                )
            }
            var comment = Fixtures.comment("\(id)_C", author: "teammate", createdAt: time(prIndex))
            comment.removeValue(forKey: "state")
            return Fixtures.pullRequest(
                id: id,
                comments: Fixtures.connection(total: 1, nodes: [comment]),
                threads: Fixtures.connection(total: threads.count, nodes: threads)
            )
        }
    }
}
