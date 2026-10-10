@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubPaginationTests: XCTestCase {
    func testHydratesEveryRequiredConnectionWithoutRepeatingDashboardFields() async throws {
        let initial = Self.pullRequest(
            isArchived: true,
            comments: Self.connection(
                total: 20,
                nodes: (10..<20).map { Self.comment("C\($0)") },
                previous: "comments-before"
            ),
            reviews: Self.connection(
                total: 11,
                nodes: (1..<11).map { Self.review("R\($0)", state: "COMMENTED") },
                previous: "reviews-before"
            ),
            opinionated: Self.connection(total: 1, nodes: [Self.review("OPINION", state: "APPROVED")]),
            threads: Self.connection(
                total: 21,
                nodes: (1..<21).map { Self.threadIdentity("T\($0)") },
                previous: "threads-before"
            ),
            assignees: Self.connection(
                total: 21,
                nodes: (1..<21).map { Self.user("user-\($0)") },
                previous: "assignees-before"
            ),
            requests: Self.connection(
                total: 21,
                nodes: (1..<21).map { Self.request("Q\($0)") },
                previous: "requests-before"
            ),
            reviewDecision: "APPROVED"
        )
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            XCTAssertFalse(query.contains("title"))
            XCTAssertFalse(query.contains("headRefOid"))
            XCTAssertFalse(query.contains("statusCheckRollup"))
            XCTAssertFalse(query.contains("author { id"))
            XCTAssertTrue(query.contains("author { login __typename }"))
            XCTAssertTrue(query.contains("nodes { id url createdAt"))
            if query.contains("... on PullRequestReviewThread") {
                XCTAssertTrue(query.contains("... on PullRequestReviewThread { comments(last: 10"))
                XCTAssertTrue(query.contains("pullRequestReview { id }"))
                XCTAssertEqual(
                    GitHubFixtureServer.aliases(query: query, variables: variables).map(\.id),
                    (1..<21).map { "T\($0)" } + ["T0"]
                )
                return Self.answer(query, variables) { alias in
                    alias.id == "T0"
                        ? Self.connection(total: 1, nodes: [Self.comment("THREAD_COMMENT", reviewID: "THREAD_REVIEW", typename: "Bot")])
                        : Self.connection(total: 0, nodes: [])
                }
            }
            XCTAssertTrue(query.contains("nodes { id url state submittedAt"))
            XCTAssertTrue(query.contains("assignees(last:"))
            XCTAssertTrue(query.contains("nodes { id login avatarUrl(size: 64) }"))
            XCTAssertTrue(query.contains("... on User { id login }"))
            XCTAssertTrue(query.contains("... on Team { id slug"))
            let topLevelComments = try XCTUnwrap(Self.selection(in: query, from: "c0:", to: "c1:"))
            XCTAssertFalse(topLevelComments.contains("pullRequestReview"))
            let reviewThreads = try XCTUnwrap(Self.selection(in: query, from: "c2:", to: "c3:"))
            XCTAssertFalse(reviewThreads.contains("pullRequestReview { id }"))
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 20, nodes: (0..<10).map { Self.comment("C\($0)", typename: $0 == 0 ? "Bot" : "User") })],
                "c1": ["reviews": Self.connection(total: 11, nodes: [Self.review("R0", state: "APPROVED", typename: "Bot")])],
                "c2": ["reviewThreads": Self.connection(total: 21, nodes: [Self.threadIdentity("T0")])],
                "c3": ["assignees": Self.connection(total: 21, nodes: [Self.user("rw")])],
                "c4": ["reviewRequests": Self.connection(total: 21, nodes: [Self.request("Q0")])]
            ]])
        }
        let discovery = Self.discovery()

        let hydrated = try await Self.fetcher(transport).hydrate([discovery], login: "rw")

        XCTAssertEqual(hydrated.count, 1)
        XCTAssertEqual(hydrated[0].pullRequest.recentCommentActivities.count, 21)
        XCTAssertEqual(hydrated[0].pullRequest.recentReviews.count, 11)
        XCTAssertEqual(hydrated[0].pullRequest.recentReviews.first { $0.id == "R0" }?.url.absoluteString, "https://github.com/acme/app/pull/1#pullrequestreview-R0")
        XCTAssertEqual(hydrated[0].pullRequest.reviewDecision, .approved)
        XCTAssertEqual(hydrated[0].pullRequest.commentCount, 1)
        XCTAssertTrue(hydrated[0].pullRequest.isAssignedToViewer)
        XCTAssertEqual(hydrated[0].pullRequest.reviewRequestKind, .direct)
        XCTAssertEqual(hydrated[0].pullRequest.repositoryIsArchived, true)
        let topLevelComment = try XCTUnwrap(hydrated[0].pullRequest.recentCommentActivities.first { $0.id == "C0" })
        XCTAssertEqual(topLevelComment.authorIsBot, true)
        XCTAssertEqual(hydrated[0].pullRequest.recentReviews.first { $0.id == "R0" }?.authorIsBot, true)
        XCTAssertEqual(hydrated[0].pullRequest.recentCommentActivities.first { $0.id == "C10" }?.authorIsBot, false)
        XCTAssertEqual(topLevelComment.source, .pullRequest)
        XCTAssertEqual(topLevelComment.url.absoluteString, "https://github.com/acme/app/pull/1#issuecomment-C0")
        XCTAssertNil(topLevelComment.reviewId)
        let threadComment = try XCTUnwrap(hydrated[0].pullRequest.recentCommentActivities.first { $0.id == "THREAD_COMMENT" })
        XCTAssertEqual(threadComment.authorIsBot, true)
        XCTAssertEqual(threadComment.source, .reviewThread)
        XCTAssertEqual(threadComment.url.absoluteString, "https://github.com/acme/app/pull/1#issuecomment-THREAD_COMMENT")
        XCTAssertEqual(threadComment.reviewId, "THREAD_REVIEW")
        XCTAssertEqual(transport.queries.filter { $0.contains("CompletePullRequests") }.count, 1)
        XCTAssertEqual(transport.shapes, ["other: 5", "first reads: 21"])
    }

    func testNestedThreadCursorRoutesToItsThreadAndDeduplicatesBoundaryRepeat() async throws {
        let initial = Self.pullRequest(
            threads: Self.connection(total: 2, nodes: [Self.threadIdentity("T_NEW"), Self.threadIdentity("T_OLD")])
        )
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            XCTAssertFalse(query.contains("author { id"))
            XCTAssertTrue(query.contains("author { login __typename }"))
            XCTAssertTrue(query.contains("pullRequestReview { id }"))
            XCTAssertTrue(query.contains("nodes { id url createdAt"))
            let aliases = GitHubFixtureServer.aliases(query: query, variables: variables)
            if aliases.allSatisfy({ $0.cursor == nil }) {
                XCTAssertEqual(aliases.map(\.id), ["T_NEW", "T_OLD"])
                XCTAssertTrue(query.contains("comments(last: 10, before: $cursor0)"))
                return Self.answer(query, variables) { alias in
                    alias.id == "T_NEW"
                        ? Self.connection(total: 0, nodes: [])
                        : Self.connection(
                            total: 11,
                            nodes: (1..<11).map { Self.comment("TC\($0)", viewerDidAuthor: true) },
                            previous: "thread-before"
                        )
                }
            }
            XCTAssertEqual(aliases.map(\.id), ["T_OLD"])
            XCTAssertEqual(aliases.first?.cursor, "thread-before")
            XCTAssertTrue(query.contains("comments(last: 100, before: $cursor0)"))
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 11, nodes: [
                    Self.comment("TC1", viewerDidAuthor: true),
                    Self.comment("TC0", viewerDidAuthor: false, reviewID: "THREAD_REVIEW", typename: "Bot")
                ])]
            ]])
        }

        let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

        XCTAssertEqual(hydrated[0].pullRequest.recentCommentActivities.count, 11)
        XCTAssertEqual(hydrated[0].pullRequest.commentCount, 1)
        let continuedComment = try XCTUnwrap(hydrated[0].pullRequest.recentCommentActivities.first { $0.id == "TC0" })
        XCTAssertEqual(continuedComment.authorIsBot, true)
        XCTAssertEqual(continuedComment.source, .reviewThread)
        XCTAssertEqual(continuedComment.url.absoluteString, "https://github.com/acme/app/pull/1#issuecomment-TC0")
        XCTAssertEqual(continuedComment.reviewId, "THREAD_REVIEW")
        XCTAssertEqual(
            Set(hydrated[0].pullRequest.recentCommentActivities.filter { $0.id.hasPrefix("TC") }.map(\.threadId)),
            ["T_OLD"]
        )
        XCTAssertEqual(transport.shapes, ["first reads: 2", "other: 1"])
    }

    func testIncompleteContinuationCoverageFailsInsteadOfPublishingPartialData() async throws {
        let initial = Self.pullRequest(
            comments: Self.connection(
                total: 11,
                nodes: (1..<11).map { Self.comment("C\($0)") },
                previous: "before"
            )
        )
        let transport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 11, nodes: [Self.comment("C1")])]
            ]])
        }

        do {
            _ = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
            XCTFail("Expected incomplete coverage")
        } catch let error as GitHubReadError {
            guard case .incompleteCoverage = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(transport.queries.filter { $0.contains("ContinuePullRequestConnections") }.count, 2)
    }

    func testOnlyIncompleteConnectionRetriesWhileSuccessfulSiblingStaysPrivate() async throws {
        let initial = Self.pullRequest(
            comments: Self.connection(
                total: 11,
                nodes: (1..<11).map { Self.comment("C\($0)") },
                previous: "comments-before"
            ),
            reviews: Self.connection(
                total: 11,
                nodes: (1..<11).map { Self.review("R\($0)", state: "COMMENTED") },
                previous: "reviews-before"
            )
        )
        let continuations = LockedCounter()
        let transport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            let attempt = continuations.increment()
            if attempt == 1 {
                XCTAssertTrue(query.contains("comments(last:"))
                XCTAssertTrue(query.contains("reviews(last:"))
                return Self.json(["data": [
                    "c0": ["comments": Self.connection(total: 11, nodes: [Self.comment("C1")])],
                    "c1": ["reviews": Self.connection(total: 11, nodes: [Self.review("R0", state: "APPROVED")])]
                ]])
            }
            XCTAssertTrue(query.contains("comments(last:"))
            XCTAssertFalse(query.contains("reviews(last:"))
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 11, nodes: (0..<11).map { Self.comment("C\($0)") })]
            ]])
        }

        let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

        XCTAssertEqual(hydrated[0].pullRequest.recentCommentActivities.count, 11)
        XCTAssertEqual(hydrated[0].pullRequest.recentReviews.count, 11)
        XCTAssertEqual(continuations.value, 2)
    }

    func testRetryAfterDeletedItemRereadsInsteadOfKeepingCachedItems() async throws {
        let initial = Self.pullRequest(
            comments: Self.connection(
                total: 11,
                nodes: (2..<12).map { Self.comment("C\($0)") },
                previous: "before"
            )
        )
        let surviving = [1, 2, 3, 4, 6, 7, 8, 9, 10, 11].map { "C\($0)" }
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            if Self.string(variables["cursor0"]) == "before" {
                return Self.json(["data": [
                    "c0": ["comments": Self.connection(total: 10, nodes: [Self.comment("C1")])]
                ]])
            }
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 10, nodes: surviving.map { Self.comment($0) })]
            ]])
        }

        let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

        XCTAssertEqual(Set(hydrated[0].pullRequest.recentCommentActivities.map(\.id)), Set(surviving))
        XCTAssertEqual(transport.queries.filter { $0.contains("ContinuePullRequestConnections") }.count, 2)
    }

    func testThreadRestartDropsChildCommentResultsFromTheSameBatch() async throws {
        let tComments = (0..<12).map { Self.comment("T_C\($0)") }
        let initial = Self.pullRequest(
            threads: Self.connection(total: 3, nodes: [Self.threadIdentity("T")], previous: "threads-p2")
        )
        let step = LockedCounter()
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            switch step.increment() {
            case 1:
                return Self.answer(query, variables) { _ in
                    Self.connection(total: 3, nodes: [Self.threadIdentity("U")], previous: "threads-p3")
                }
            case 2, 5:
                return Self.answer(query, variables) { alias in
                    alias.id == "T"
                        ? Self.connection(total: 12, nodes: Array(tComments[2...]), previous: "t-older")
                        : Self.connection(total: 1, nodes: [Self.comment("U_C0")])
                }
            case 3:
                // The thread list shrinks, so T's older page in the same batch belongs to the discarded read.
                return Self.answer(query, variables) { alias in
                    alias.connection == "reviewThreads"
                        ? Self.connection(total: 2, nodes: [])
                        : Self.connection(total: 12, nodes: [Self.comment("T_DISCARDED")])
                }
            case 4:
                return Self.answer(query, variables) { _ in
                    Self.connection(total: 2, nodes: [Self.threadIdentity("T"), Self.threadIdentity("U")])
                }
            default:
                return Self.answer(query, variables) { _ in
                    Self.connection(total: 12, nodes: Array(tComments[..<2]))
                }
            }
        }

        let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

        XCTAssertEqual(
            Set(hydrated[0].pullRequest.recentCommentActivities.map(\.id)),
            Set(tComments.compactMap { $0["id"] as? String } + ["U_C0"])
        )
        XCTAssertEqual(
            transport.shapes,
            ["other: 1", "first reads: 2", "other: 2", "other: 1", "first reads: 2", "other: 1"]
        )
    }

    func testBotRequestedReviewerHydratesWithoutActorFields() async throws {
        let initial = Self.pullRequest(
            requests: Self.connection(total: 2, nodes: [
                Self.request("Q_USER"),
                ["id": "Q_BOT", "requestedReviewer": ["__typename": "Bot"]]
            ])
        )
        let transport = HydrationTransport { _, _ in
            Self.json(["data": ["nodes": [initial]]])
        }

        let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

        XCTAssertEqual(hydrated[0].pullRequest.reviewRequestKind, .direct)
    }

    func testLatestOpinionatedPaginationAndTopLevelBoundaryDeduplication() async throws {
        let initial = Self.pullRequest(
            comments: Self.connection(
                total: 11,
                nodes: (1..<11).map { Self.comment("C\($0)") },
                previous: "comments-before"
            ),
            opinionated: Self.connection(
                total: 21,
                nodes: (1..<21).map { Self.review("O\($0)", state: "APPROVED") },
                previous: "opinions-before"
            )
        )
        let transport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            XCTAssertFalse(query.contains("author { id"))
            XCTAssertTrue(query.contains("latestOpinionatedReviews(last:"))
            XCTAssertTrue(query.contains("nodes { id url state submittedAt"))
            XCTAssertTrue(query.contains("author { login __typename }"))
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 11, nodes: [Self.comment("C1"), Self.comment("C0", typename: "Bot")])],
                "c1": ["latestOpinionatedReviews": Self.connection(
                    total: 21,
                    nodes: [Self.review("O0", state: "CHANGES_REQUESTED")]
                )]
            ]])
        }

        let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

        XCTAssertEqual(hydrated[0].pullRequest.recentCommentActivities.count, 11)
        XCTAssertEqual(hydrated[0].pullRequest.reviewDecision, .changesRequested)
    }

    func testHydrationPreservesActorLoginsAndActivityWithoutActorNodeIDs() async throws {
        let prAuthor: [String: Any] = [
            "login": "pr-author",
            "avatarUrl": "https://avatars.example/pr-author.png"
        ]
        var comment = Self.comment("COMMENT_WITH_ACTOR")
        comment["author"] = ["login": "comment-author"]
        comment["url"] = "https://github.com/acme/app/pull/1?view=discussion#issuecomment-C1"
        var review = Self.review("REVIEW_WITH_ACTOR", state: "APPROVED")
        review["author"] = ["login": "review-author"]
        review["url"] = "https://github.com/acme/app/pull/1?view=review#pullrequestreview-R1"
        var node = Self.pullRequest(
            comments: Self.connection(total: 1, nodes: [comment]),
            reviews: Self.connection(total: 1, nodes: [review]),
            opinionated: Self.connection(total: 1, nodes: [review]),
            reviewDecision: "APPROVED"
        )
        node["author"] = prAuthor
        let transport = HydrationTransport { query, _ in
            XCTAssertFalse(query.contains("author { id"))
            return Self.json(["data": ["nodes": [node]]])
        }

        let pullRequest = try await Self.fetcher(transport)
            .hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(pullRequest.author, "pr-author")
        XCTAssertEqual(pullRequest.authorAvatarURL, URL(string: "https://avatars.example/pr-author.png"))
        XCTAssertEqual(pullRequest.recentCommentActivities.first?.author, "comment-author")
        XCTAssertEqual(pullRequest.recentCommentActivities.first?.url.absoluteString, "https://github.com/acme/app/pull/1?view=discussion#issuecomment-C1")
        XCTAssertEqual(pullRequest.recentReviews.first?.author, "review-author")
        XCTAssertEqual(pullRequest.recentReviews.first?.url.absoluteString, "https://github.com/acme/app/pull/1?view=review#pullrequestreview-R1")
        XCTAssertEqual(pullRequest.reviewDecision, .approved)
    }

    func testCompleteHydrationPreservesDashboardAndActivityMetadata() async throws {
        let topLevelComment = Self.comment(
            "COMMENT_1",
            author: "comment-author",
            createdAt: "2026-05-02T09:00:00Z"
        )
        let authoredReview = Self.review(
            "REVIEW_FALSE",
            state: "APPROVED",
            author: "rw",
            submittedAt: "2026-05-02T11:00:00Z",
            viewerDidAuthor: false
        )
        let viewerReview = Self.review(
            "REVIEW_TRUE",
            state: "COMMENTED",
            author: "teammate",
            submittedAt: "2026-05-02T12:00:00Z",
            viewerDidAuthor: true
        )
        let opinionatedReview = Self.review(
            "OPINION",
            state: "APPROVED",
            author: "reviewer"
        )
        let resolvedThread = Self.thread(
            "RESOLVED",
            isResolved: true,
            comments: [
                Self.comment(
                    "RESOLVED_COMMENT",
                    author: "reviewer",
                    createdAt: "2026-05-02T10:00:00Z",
                    reviewID: "REVIEW_FALSE"
                )
            ]
        )
        let actionableThread = Self.thread(
            "ACTIONABLE",
            comments: [
                Self.comment(
                    "SELF_COMMENT",
                    viewerDidAuthor: true,
                    author: "rw",
                    createdAt: "2026-05-02T11:00:00Z",
                    reviewID: "REVIEW_TRUE"
                ),
                Self.comment(
                    "ACTIONABLE_COMMENT",
                    author: "teammate",
                    createdAt: "2026-05-02T12:00:00Z",
                    reviewID: "REVIEW_TRUE"
                )
            ]
        )
        var node = Self.pullRequest(
            comments: Self.connection(total: 1, nodes: [topLevelComment]),
            reviews: Self.connection(total: 2, nodes: [authoredReview, viewerReview]),
            opinionated: Self.connection(total: 1, nodes: [opinionatedReview]),
            threads: Self.connection(total: 2, nodes: [resolvedThread, actionableThread]),
            reviewDecision: "APPROVED"
        )
        node["title"] = "Ship dashboard"
        node["number"] = 12
        node["url"] = "https://github.com/acme/mergehawk/pull/12"
        node["repository"] = ["nameWithOwner": "acme/mergehawk", "isArchived": false]
        node["createdAt"] = "2026-05-01T12:00:00Z"
        node["updatedAt"] = "2026-05-02T12:00:00Z"
        node["headRefName"] = "ship-dashboard"
        node["headRefOid"] = "commit-1"
        node["isDraft"] = true
        node["mergeable"] = "MERGEABLE"
        node["additions"] = 42
        node["deletions"] = 7
        node["statusCheckRollup"] = ["state": "FAILURE"]
        node["author"] = [
            "id": "USER_RW", "login": "RW",
            "avatarUrl": "https://avatars.example/rw.png"
        ]
        let server = GitHubFixtureServer(pullRequests: [node])

        let pullRequest = try await server.fetcher
            .hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(pullRequest.id, "PR_1")
        XCTAssertEqual(pullRequest.title, "Ship dashboard")
        XCTAssertEqual(pullRequest.number, 12)
        XCTAssertEqual(pullRequest.url, URL(string: "https://github.com/acme/mergehawk/pull/12"))
        XCTAssertEqual(pullRequest.repo, "acme/mergehawk")
        XCTAssertEqual(pullRequest.repositoryIsArchived, false)
        XCTAssertEqual(pullRequest.ciState, .failing)
        XCTAssertEqual(pullRequest.reviewDecision, .approved)
        XCTAssertEqual(pullRequest.additions, 42)
        XCTAssertEqual(pullRequest.deletions, 7)
        XCTAssertEqual(pullRequest.commentCount, 1)
        XCTAssertEqual(pullRequest.commentActivityCount, 4)
        XCTAssertEqual(pullRequest.reviewCount, 2)
        XCTAssertEqual(pullRequest.headRefOid, "commit-1")
        XCTAssertTrue(pullRequest.isMine)
        XCTAssertEqual(pullRequest.author, "RW")
        XCTAssertEqual(pullRequest.authorAvatarURL, URL(string: "https://avatars.example/rw.png"))
        XCTAssertEqual(pullRequest.headRefName, "ship-dashboard")
        XCTAssertEqual(pullRequest.mergeable, .mergeable)
        XCTAssertTrue(pullRequest.draft)
        XCTAssertEqual(pullRequest.createdAt, Self.date("2026-05-01T12:00:00Z"))
        XCTAssertEqual(pullRequest.updatedAt, Self.date("2026-05-02T12:00:00Z"))

        let topLevel = try XCTUnwrap(pullRequest.recentCommentActivities.first { $0.id == "COMMENT_1" })
        XCTAssertEqual(topLevel.author, "comment-author")
        XCTAssertEqual(topLevel.createdAt, Self.date("2026-05-02T09:00:00Z"))
        XCTAssertEqual(topLevel.source, .pullRequest)
        XCTAssertNil(topLevel.reviewId)
        let resolved = try XCTUnwrap(pullRequest.recentCommentActivities.first { $0.id == "RESOLVED_COMMENT" })
        XCTAssertEqual(resolved.source, .reviewThread)
        XCTAssertEqual(resolved.reviewId, "REVIEW_FALSE")
        let selfComment = try XCTUnwrap(pullRequest.recentCommentActivities.first { $0.id == "SELF_COMMENT" })
        XCTAssertTrue(selfComment.viewerDidAuthor)
        let actionable = try XCTUnwrap(pullRequest.recentCommentActivities.first { $0.id == "ACTIONABLE_COMMENT" })
        XCTAssertEqual(actionable.author, "teammate")
        XCTAssertFalse(actionable.viewerDidAuthor)

        let payloadFalse = try XCTUnwrap(pullRequest.recentReviews.first { $0.id == "REVIEW_FALSE" })
        XCTAssertEqual(payloadFalse.state, .approved)
        XCTAssertEqual(payloadFalse.submittedAt, Self.date("2026-05-02T11:00:00Z"))
        XCTAssertEqual(payloadFalse.author, "rw")
        XCTAssertFalse(payloadFalse.viewerDidAuthor)
        let payloadTrue = try XCTUnwrap(pullRequest.recentReviews.first { $0.id == "REVIEW_TRUE" })
        XCTAssertEqual(payloadTrue.state, .commented)
        XCTAssertEqual(payloadTrue.author, "teammate")
        XCTAssertTrue(payloadTrue.viewerDidAuthor)
    }

    func testActionableCountExcludesResolvedUnresolvableAndSelfAuthoredThreadsWithoutDroppingActivity() async throws {
        let threads = [
            Self.thread("SELF", comments: [Self.comment("SELF_COMMENT", viewerDidAuthor: true)]),
            Self.thread(
                "UNRESOLVABLE",
                viewerCanResolve: false,
                comments: [Self.comment("UNRESOLVABLE_COMMENT")]
            ),
            Self.thread(
                "ACTIONABLE",
                comments: [Self.comment("ACTIONABLE_SELF", viewerDidAuthor: true), Self.comment("ACTIONABLE_OTHER")]
            ),
            Self.thread("RESOLVED", isResolved: true, comments: [Self.comment("RESOLVED_COMMENT")])
        ]
        let node = Self.pullRequest(threads: Self.connection(total: threads.count, nodes: threads))
        let server = GitHubFixtureServer(pullRequests: [node])

        let pullRequest = try await server.fetcher
            .hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(pullRequest.commentCount, 1)
        XCTAssertEqual(pullRequest.commentActivityCount, 5)
        XCTAssertEqual(Set(pullRequest.recentCommentActivities.map(\.id)), [
            "SELF_COMMENT", "UNRESOLVABLE_COMMENT", "ACTIONABLE_SELF", "ACTIONABLE_OTHER", "RESOLVED_COMMENT"
        ])
    }

    func testHydrationNormalizesRelationshipKindsAndViewerAssignment() async throws {
        let cases: [(String, [[String: Any]], Bool, [[String: Any]], ReviewRequestKind, Bool)] = [
            ("NONE", [], false, [Self.user("teammate")], .none, false),
            ("DIRECT", [Self.request("DIRECT", typeName: "User", login: "RW")], false, [Self.user("RW")], .direct, true),
            ("RAW_TEAM", [Self.request("TEAM", typeName: "Team")], false, [], .none, false),
            ("TEAM", [Self.request("TEAM", typeName: "Team")], true, [], .team, false),
            (
                "BOTH",
                [Self.request("DIRECT", typeName: "User", login: "rw"), Self.request("TEAM", typeName: "Team")],
                true,
                [],
                .directAndTeam,
                false
            )
        ]

        for (id, requests, hasTeamEvidence, assignees, expectedKind, expectedAssignment) in cases {
            var node = Self.pullRequest(
                id: id,
                assignees: Self.connection(total: assignees.count, nodes: assignees),
                requests: Self.connection(total: requests.count, nodes: requests)
            )
            node["author"] = Self.user("teammate")
            let discovery = Self.discovery(
                id: id,
                isDirectlyRequested: expectedKind.includesDirect,
                isTeamRequested: hasTeamEvidence
            )
            let transport = HydrationTransport { _, _ in
                Self.json(["data": ["nodes": [node]]])
            }

            let pullRequest = try await Self.fetcher(transport).hydrate([discovery], login: "rw")[0].pullRequest

            XCTAssertEqual(pullRequest.reviewRequestKind, expectedKind, id)
            XCTAssertEqual(pullRequest.isAssignedToViewer, expectedAssignment, id)
        }
    }

    func testHydrationKeepsEveryRequestedTeamWithItsIdentity() async throws {
        let node = Self.pullRequest(requests: Self.connection(total: 3, nodes: [
            Self.request("Q_PLM", typeName: "Team", teamSlug: "plm-team"),
            Self.request("Q_USER", typeName: "User", login: "teammate"),
            Self.request("Q_DEV", typeName: "Team", teamSlug: "developers")
        ]))
        let transport = HydrationTransport { _, _ in Self.json(["data": ["nodes": [node]]]) }

        let pullRequest = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(pullRequest.requestedTeams, [
            TeamReference(id: "TEAM_Q_DEV", organization: "acme", slug: "developers"),
            TeamReference(id: "TEAM_Q_PLM", organization: "acme", slug: "plm-team")
        ])
    }

    func testHydrationKeepsRequestedTeamsFromLaterReviewRequestPages() async throws {
        let initial = Self.pullRequest(requests: Self.connection(
            total: 2,
            nodes: [Self.request("Q_DEV", typeName: "Team", teamSlug: "developers")],
            previous: "requests-before"
        ))
        let transport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            XCTAssertTrue(query.contains("reviewRequests(last:"))
            return Self.json(["data": [
                "c0": ["reviewRequests": Self.connection(total: 2, nodes: [
                    Self.request("Q_ENG", typeName: "Team", teamSlug: "engineering")
                ])]
            ]])
        }

        let pullRequest = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(pullRequest.requestedTeams.map(\.slug), ["developers", "engineering"])
        XCTAssertEqual(transport.queries.filter { $0.contains("ContinuePullRequestConnections") }.count, 1)
    }

    func testRequestedTeamMissingSlugOrOrganizationFailsHydrationAsInvalidPayload() async throws {
        for missingKey in ["slug", "organization", "id"] {
            var team = Self.request("Q_TEAM", typeName: "Team")
            var reviewer = team["requestedReviewer"] as! [String: Any]
            reviewer.removeValue(forKey: missingKey)
            team["requestedReviewer"] = reviewer
            let node = Self.pullRequest(requests: Self.connection(total: 1, nodes: [team]))
            let transport = HydrationTransport { _, _ in Self.json(["data": ["nodes": [node]]]) }

            do {
                _ = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
                XCTFail("Expected a team request without \(missingKey) to fail hydration")
            } catch {
                XCTAssertEqual(error as? GitHubReadError, .invalidPayload, missingKey)
            }
        }
    }

    func testHydrationWithoutTeamRequestsKeepsNoRequestedTeams() async throws {
        let node = Self.pullRequest(requests: Self.connection(total: 1, nodes: [Self.request("Q_USER")]))
        let transport = HydrationTransport { _, _ in Self.json(["data": ["nodes": [node]]]) }

        let pullRequest = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(pullRequest.requestedTeams, [])
    }

    func testKnownChangesRequestedWinsOverUncertainOpinionatedReviewsInAnyOrder() async throws {
        var deletedAuthor = Self.review("DELETED", state: "APPROVED")
        deletedAuthor["author"] = NSNull()
        let unknown = Self.review("UNKNOWN", state: "FUTURE_STATE")
        let changesRequested = Self.review("CHANGES", state: "CHANGES_REQUESTED")
        let approved = Self.review("APPROVED", state: "APPROVED")
        var ignoredDeletedAuthor = Self.review("IGNORED", state: "COMMENTED")
        ignoredDeletedAuthor["author"] = NSNull()
        let cases: [([[String: Any]], ReviewDecision)] = [
            ([deletedAuthor, unknown, approved, changesRequested], .changesRequested),
            ([changesRequested, approved, unknown, deletedAuthor], .changesRequested),
            ([unknown, changesRequested, deletedAuthor, approved], .changesRequested),
            ([approved, ignoredDeletedAuthor], .approved),
            ([ignoredDeletedAuthor, approved], .approved),
            ([approved, deletedAuthor], .unknown),
            ([unknown, approved], .unknown)
        ]

        for (reviews, expected) in cases {
            let initial = Self.pullRequest(
                opinionated: Self.connection(total: reviews.count, nodes: reviews),
                reviewDecision: "APPROVED"
            )
            let transport = HydrationTransport { _, _ in
                Self.json(["data": ["nodes": [initial]]])
            }

            let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

            XCTAssertEqual(hydrated[0].pullRequest.reviewDecision, expected)
        }
    }

    func testOnlyGitHubApprovedDecisionShowsApproved() async throws {
        let approved = Self.review("APPROVED", state: "APPROVED")
        let changesRequested = Self.review("CHANGES", state: "CHANGES_REQUESTED")
        let dismissed = Self.review("DISMISSED", state: "DISMISSED")
        var deletedAuthor = Self.review("DELETED", state: "APPROVED")
        deletedAuthor["author"] = NSNull()
        let cases: [(String, [[String: Any]], String?, ReviewDecision)] = [
            ("approval, review required", [approved], "REVIEW_REQUIRED", .reviewRequired),
            ("approval, approved", [approved], "APPROVED", .approved),
            ("no opinions, approved", [], "APPROVED", .approved),
            ("approval, no decision", [approved], nil, .reviewRequired),
            ("no approval, no decision", [], nil, .reviewRequired),
            ("no approval, review required", [], "REVIEW_REQUIRED", .reviewRequired),
            ("changes requested, review required", [changesRequested], "REVIEW_REQUIRED", .changesRequested),
            ("changes requested, approved", [changesRequested], "APPROVED", .changesRequested),
            ("dismissed approval, review required", [dismissed], "REVIEW_REQUIRED", .reviewRequired),
            ("incomplete data, review required", [approved, deletedAuthor], "REVIEW_REQUIRED", .unknown),
            ("incomplete data, approved", [approved, deletedAuthor], "APPROVED", .unknown),
        ]

        for (name, reviews, gitHubDecision, expected) in cases {
            let initial = Self.pullRequest(
                opinionated: Self.connection(total: reviews.count, nodes: reviews),
                reviewDecision: gitHubDecision
            )
            let transport = HydrationTransport { _, _ in
                Self.json(["data": ["nodes": [initial]]])
            }

            let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

            XCTAssertEqual(hydrated[0].pullRequest.reviewDecision, expected, name)
        }
    }

    func testActivityAppendedBeyondAnchorDefersWithoutFailureAndAppearsNextRefresh() async throws {
        let firstInitial = Self.pullRequest(
            comments: Self.connection(
                total: 11,
                nodes: (2...11).map { Self.comment("C\($0)") },
                previous: "before"
            )
        )
        let firstTransport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [firstInitial]]])
            }
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 12, nodes: [Self.comment("C1")])]
            ]])
        }
        let first = try await Self.fetcher(firstTransport).hydrate([Self.discovery()], login: "rw")[0].pullRequest
        XCTAssertEqual(first.recentCommentActivities.count, 11)

        let secondInitial = Self.pullRequest(
            comments: Self.connection(
                total: 12,
                nodes: (3...12).map { Self.comment("C\($0)") },
                previous: "before"
            )
        )
        let secondTransport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [secondInitial]]])
            }
            return Self.json(["data": [
                "c0": ["comments": Self.connection(
                    total: 12,
                    nodes: [Self.comment("C1"), Self.comment("C2")]
                )]
            ]])
        }
        let second = try await Self.fetcher(secondTransport).hydrate([Self.discovery()], login: "rw")[0].pullRequest
        let engine = SyncEngine(source: EmptyPullRequestSource(), loginProvider: { "rw" })
        let baseline = try await engine.prepare(
            previousState: nil,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [first])
        )
        let state = PullRequestSyncState(
            account: baseline.account,
            dashboard: DashboardState(
                pullRequests: [first], events: [], syncedAt: baseline.syncedAt, source: .github,
                account: baseline.account, authStatus: .signedIn
            ),
            processedActivityByPullRequestID: baseline.processedActivityByPullRequestID
        )
        let prepared = try await engine.prepare(
            previousState: state,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [second])
        )

        XCTAssertEqual(prepared.events.map(\.event.activityId), ["C12"])
    }

    func testHydrationAndContinuationBatchesStayBoundedAtTwenty() async throws {
        let discoveries = (0..<21).map { Self.discovery(id: "PR_\($0)") }
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                guard case .strings(let ids) = variables["ids"] else {
                    throw GitHubReadError.invalidPayload
                }
                let nodes = ids.map { id in
                    Self.pullRequest(
                        id: id,
                        comments: Self.connection(
                            total: 11,
                            nodes: (1..<11).map { Self.comment("\(id)_C\($0)") },
                            previous: "before"
                        )
                    )
                }
                return Self.json(["data": ["nodes": nodes]])
            }
            var data: [String: Any] = [:]
            var index = 0
            while case .string(let id) = variables["id\(index)"] {
                data["c\(index)"] = [
                    "comments": Self.connection(total: 11, nodes: [Self.comment("\(id)_C0")])
                ]
                index += 1
            }
            return Self.json(["data": data])
        }

        let hydrated = try await Self.fetcher(transport).hydrate(discoveries, login: "rw")

        XCTAssertEqual(hydrated.count, 21)
        XCTAssertEqual(transport.queries.filter { $0.contains("CompletePullRequests") }.count, 2)
        XCTAssertEqual(transport.queries.filter { $0.contains("ContinuePullRequestConnections") }.count, 2)
    }

    func testPartialHydrationRetainsSuccessfulSiblingAndRetriesOnlyFailedID() async throws {
        let attempts = LockedCounter()
        let transport = HydrationTransport { query, variables in
            XCTAssertTrue(query.contains("CompletePullRequests"))
            guard case .strings(let ids) = variables["ids"] else {
                throw GitHubReadError.invalidPayload
            }
            let attempt = attempts.increment()
            if attempt == 1 {
                XCTAssertEqual(ids, ["PR_OK", "PR_FAILED"])
                var failedChild = Self.pullRequest(id: "PR_FAILED")
                failedChild["comments"] = NSNull()
                return Self.json([
                    "data": ["nodes": [Self.pullRequest(id: "PR_OK"), failedChild]],
                    "errors": [[
                        "message": "temporary child failure",
                        "type": "INTERNAL",
                        "path": ["nodes", 1, "comments"]
                    ]]
                ])
            }
            XCTAssertEqual(ids, ["PR_FAILED"])
            return Self.json(["data": ["nodes": [Self.pullRequest(id: "PR_FAILED")]]])
        }

        let hydrated = try await Self.fetcher(transport).hydrate(
            [Self.discovery(id: "PR_OK"), Self.discovery(id: "PR_FAILED")],
            login: "rw"
        )

        XCTAssertEqual(Set(hydrated.map(\.pullRequest.id)), ["PR_OK", "PR_FAILED"])
        XCTAssertEqual(attempts.value, 2)
    }

    func testPartialContinuationRetainsSuccessfulAliasAndRetriesOnlyFailedAlias() async throws {
        let initial = Self.pullRequest(
            comments: Self.connection(
                total: 11,
                nodes: (1..<11).map { Self.comment("C\($0)") },
                previous: "comments-before"
            ),
            reviews: Self.connection(
                total: 11,
                nodes: (1..<11).map { Self.review("R\($0)", state: "COMMENTED") },
                previous: "reviews-before"
            )
        )
        let continuationAttempts = LockedCounter()
        let transport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            let attempt = continuationAttempts.increment()
            if attempt == 1 {
                XCTAssertTrue(query.contains("comments(last:"))
                XCTAssertTrue(query.contains("reviews(last:"))
                return Self.json([
                    "data": [
                        "c0": ["comments": Self.connection(total: 11, nodes: [Self.comment("C0")])],
                        "c1": NSNull()
                    ],
                    "errors": [[
                        "message": "review alias failed",
                        "type": "INTERNAL",
                        "path": ["c1", "reviews"]
                    ]]
                ])
            }
            XCTAssertFalse(query.contains("comments(last:"))
            XCTAssertTrue(query.contains("reviews(last:"))
            return Self.json(["data": [
                "c0": ["reviews": Self.connection(
                    total: 11,
                    nodes: [Self.review("R0", state: "APPROVED")]
                )]
            ]])
        }

        let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

        XCTAssertEqual(hydrated[0].pullRequest.recentCommentActivities.count, 11)
        XCTAssertEqual(hydrated[0].pullRequest.recentReviews.count, 11)
        XCTAssertEqual(continuationAttempts.value, 2)
    }

    func testRetriedPartialHydrationClassifiesRequiredFailure() async throws {
        for (type, expected) in [
            ("UNAUTHENTICATED", GitHubReadError.authentication),
            ("FORBIDDEN", .accessDenied),
            ("RATE_LIMITED", .rateLimited(retryAt: nil))
        ] {
            let attempts = LockedCounter()
            let transport = HydrationTransport { _, _ in
                if attempts.increment() == 1 {
                    return Self.json([
                        "data": ["nodes": [NSNull()]],
                        "errors": [["message": "retry", "type": "INTERNAL", "path": ["nodes", 0]]]
                    ])
                }
                return Self.json([
                    "data": ["nodes": [NSNull()]],
                    "errors": [["message": "terminal", "type": type, "path": ["nodes", 0]]]
                ])
            }
            do {
                _ = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
                XCTFail("Expected classified retry failure")
            } catch {
                XCTAssertEqual(error as? GitHubReadError, expected)
            }
            XCTAssertEqual(attempts.value, 2)
        }
    }

    func testCompleteHydrationNormalizesEveryCIStateAndMissingAuthor() async throws {
        let cases: [(Any, CIState)] = [
            (["state": "SUCCESS"], .passing),
            (["state": "FAILURE"], .failing),
            (["state": "ERROR"], .failing),
            (["state": "PENDING"], .pending),
            (["state": "EXPECTED"], .pending),
            (["state": "FUTURE_STATE"], .unknown),
            (NSNull(), .unknown)
        ]

        for (status, expected) in cases {
            var node = Self.pullRequest()
            node["statusCheckRollup"] = status
            node["author"] = NSNull()
            let transport = HydrationTransport { _, _ in
                Self.json(["data": ["nodes": [node]]])
            }

            let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
            let pullRequest = try XCTUnwrap(hydrated.first?.pullRequest)
            XCTAssertEqual(pullRequest.ciState, expected)
            XCTAssertEqual(pullRequest.author, "unknown")
            XCTAssertNil(pullRequest.authorAvatarURL)
            XCTAssertFalse(pullRequest.isMine)
        }
    }

    func testHydratedPRWithAStackGetsThatStackID() async throws {
        var node = Self.pullRequest()
        node["stack"] = ["id": "STACK_1"]
        let transport = HydrationTransport { _, _ in Self.json(["data": ["nodes": [node]]]) }

        let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

        XCTAssertEqual(hydrated[0].pullRequest.stackID, "STACK_1")
    }

    func testHydratedPRWithNullOrMissingStackHasNoStackID() async throws {
        var nullStack = Self.pullRequest()
        nullStack["stack"] = NSNull()
        for node in [nullStack, Self.pullRequest()] {
            let transport = HydrationTransport { _, _ in Self.json(["data": ["nodes": [node]]]) }

            let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

            XCTAssertNil(hydrated[0].pullRequest.stackID)
        }
    }

    func testHydrationQuerySelectsOnlyTheStackID() {
        XCTAssertTrue(GitHubPullRequestQueries.hydration.contains("stack { id }"))
    }

    func testCompleteHydrationNormalizesEveryMergeableState() async throws {
        let cases: [(Any, MergeableState)] = [
            ("MERGEABLE", .mergeable),
            ("CONFLICTING", .conflicting),
            ("UNKNOWN", .unknown),
            (NSNull(), .unknown)
        ]

        for (mergeable, expected) in cases {
            var node = Self.pullRequest()
            node["mergeable"] = mergeable
            let transport = HydrationTransport { _, _ in
                Self.json(["data": ["nodes": [node]]])
            }

            let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

            XCTAssertEqual(hydrated[0].pullRequest.mergeable, expected)
        }
    }

    func testBotAndNonBotAuthorsNormalizeWithoutChangingReviewOrThreadState() async throws {
        let types: [String?] = ["Bot", "User", "Organization", nil]
        for typename in types {
            var comment = Self.comment("C", author: "unfamiliar[bot]")
            comment["author"] = typename.map { ["login": "unfamiliar[bot]", "__typename": $0] as Any } ?? NSNull()
            let reviews = ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"].enumerated().map { index, state in
                var review = Self.review("R\(index)", state: state)
                review["author"] = comment["author"]
                return review
            }
            let node = Self.pullRequest(
                comments: Self.connection(total: 1, nodes: [comment]),
                reviews: Self.connection(total: 3, nodes: reviews),
                opinionated: Self.connection(total: 1, nodes: [reviews[0]]),
                threads: Self.connection(total: 1, nodes: [Self.thread("T", comments: [comment])]),
                reviewDecision: "APPROVED"
            )
            let server = GitHubFixtureServer(pullRequests: [node])
            let pr = try await server.fetcher.hydrate([Self.discovery()], login: "rw")[0].pullRequest
            let expected = typename.map { $0 == "Bot" }
            XCTAssertTrue(pr.recentCommentActivities.allSatisfy { $0.authorIsBot == expected })
            XCTAssertEqual(pr.recentReviews.map(\.authorIsBot), [expected, expected, expected])
            XCTAssertEqual(pr.reviewDecision, typename == nil ? .unknown : .approved)
            XCTAssertEqual(pr.commentCount, 1)
        }
    }

    func testEveryActivityReadCarriesCommentContextWhileOpinionsStayLean() async throws {
        let hydration = GitHubPullRequestQueries.hydration
        XCTAssertTrue(hydration.contains("comments(last: 10) { \(GitHubPullRequestQueries.conversationCommentConnectionFields) }"))
        XCTAssertTrue(hydration.contains("reviews(last: 10) { \(GitHubPullRequestQueries.fullReviewConnectionFields) }"))
        XCTAssertTrue(hydration.contains("latestOpinionatedReviews(last: 20) { \(GitHubPullRequestQueries.opinionatedReviewConnectionFields) }"))
        let opinions = try XCTUnwrap(Self.selection(in: hydration, from: "latestOpinionatedReviews", to: "reviewThreads"))
        XCTAssertFalse(opinions.contains("bodyHTML"))
        XCTAssertFalse(opinions.contains("bodyText"))

        let initial = Self.pullRequest(
            comments: Self.connection(total: 2, nodes: [Self.comment("C_NEW")], previous: "comments-before"),
            reviews: Self.connection(total: 2, nodes: [Self.review("R_NEW", state: "COMMENTED")], previous: "reviews-before"),
            opinionated: Self.connection(total: 2, nodes: [Self.leanReview("O_NEW")], previous: "opinions-before"),
            threads: Self.connection(total: 2, nodes: [Self.threadIdentity("T_OLD")], previous: "threads-before"),
            reviewDecision: "APPROVED"
        )
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            if query.contains("... on PullRequestReviewThread") {
                XCTAssertTrue(query.contains(
                    "comments(last: 10, before: $cursor0) { \(GitHubPullRequestQueries.inlineCommentConnectionFields) }"
                ))
                return Self.answer(query, variables) { alias in
                    alias.id == "T_OLD"
                        ? Self.connection(total: 2, nodes: [
                            Self.comment("T_OLD_ROOT", createdAt: "2025-12-01T00:00:00Z", reviewID: "R_OLD"),
                            Self.comment("T_OLD_NEW", reviewID: "R_NEW")
                        ])
                        : Self.connection(total: 1, nodes: [Self.comment("T_CONTINUED_ROOT", reviewID: "R_OLD")])
                }
            }
            let fields = [
                ("c0:", "c1:", GitHubPullRequestQueries.conversationCommentConnectionFields),
                ("c1:", "c2:", GitHubPullRequestQueries.fullReviewConnectionFields),
                ("c2:", "c3:", GitHubPullRequestQueries.opinionatedReviewConnectionFields),
                ("c3:", "}\n}", GitHubPullRequestQueries.reviewThreadNodeFields),
            ]
            for (start, end, expected) in fields {
                let selection = try XCTUnwrap(Self.selection(in: query, from: start, to: end))
                XCTAssertTrue(selection.contains(expected), "\(start) \(selection)")
            }
            XCTAssertFalse(query.contains("c4:"))
            let continuedThreads = try XCTUnwrap(Self.selection(in: query, from: "c3:", to: "}\n}"))
            XCTAssertFalse(continuedThreads.contains("comments("))
            let continuedOpinions = try XCTUnwrap(Self.selection(in: query, from: "c2:", to: "c3:"))
            XCTAssertFalse(continuedOpinions.contains("bodyHTML"))
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 2, nodes: [Self.comment("C_OLD", createdAt: "2025-12-01T00:00:00Z")])],
                "c1": ["reviews": Self.connection(total: 2, nodes: [Self.review("R_OLD", state: "COMMENTED")])],
                "c2": ["latestOpinionatedReviews": Self.connection(total: 2, nodes: [Self.leanReview("O_OLD")])],
                "c3": ["reviewThreads": Self.connection(total: 2, nodes: [Self.threadIdentity("T_CONTINUED")])]
            ]])
        }

        let pullRequest = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")[0].pullRequest

        let comments = Dictionary(uniqueKeysWithValues: pullRequest.recentCommentActivities.map { ($0.id, $0) })
        XCTAssertEqual(Set(comments.keys), ["C_NEW", "C_OLD", "T_OLD_NEW", "T_OLD_ROOT", "T_CONTINUED_ROOT"])
        for id in ["C_OLD", "T_OLD_ROOT"] {
            let comment = try XCTUnwrap(comments[id])
            XCTAssertEqual(comment.publishedAt, Self.date("2025-12-01T00:00:00Z"))
            XCTAssertEqual(comment.updatedAt, Self.date("2025-12-01T00:00:00Z"))
            XCTAssertEqual(comment.url.absoluteString, "https://github.com/acme/app/pull/1#issuecomment-\(id)")
            XCTAssertEqual(comment.authorIsBot, false)
        }
        XCTAssertNil(comments["C_NEW"]?.threadId)
        XCTAssertNil(comments["C_OLD"]?.threadId)
        XCTAssertEqual(comments["T_OLD_NEW"]?.threadId, "T_OLD")
        XCTAssertEqual(comments["T_OLD_ROOT"]?.threadId, "T_OLD")
        XCTAssertEqual(comments["T_CONTINUED_ROOT"]?.threadId, "T_CONTINUED")
        XCTAssertEqual(comments["T_CONTINUED_ROOT"]?.reviewId, "R_OLD")
        XCTAssertEqual(Set(pullRequest.recentReviews.map(\.id)), ["R_NEW", "R_OLD"])
        XCTAssertEqual(pullRequest.reviewDecision, .approved)
        XCTAssertEqual(transport.queries.filter { $0.contains("ContinuePullRequestConnections") }.count, 2)
    }

    func testPendingInlineCommentIsUnpublishedAndItsPublishedFormKeepsPublicationTime() async throws {
        var pending = Self.comment("DRAFT", viewerDidAuthor: true, createdAt: "2026-09-26T10:00:10Z")
        pending["state"] = "PENDING"
        pending["publishedAt"] = "2026-09-26T10:00:10Z"
        var published = pending
        published["state"] = "SUBMITTED"
        published["publishedAt"] = "2026-09-26T10:00:17Z"
        published["updatedAt"] = "2026-09-26T10:00:17Z"

        for (payload, expected) in [(pending, nil), (published, Self.date("2026-09-26T10:00:17Z"))] as [([String: Any], Date?)] {
            let node = Self.pullRequest(threads: Self.connection(total: 1, nodes: [Self.thread("T", comments: [payload])]))
            let server = GitHubFixtureServer(pullRequests: [node])

            let hydrated = try await server.fetcher.hydrate([Self.discovery()], login: "rw")
            let comment = try XCTUnwrap(hydrated[0].pullRequest.recentCommentActivities.first)

            XCTAssertEqual(comment.publishedAt, expected)
            XCTAssertEqual(comment.createdAt, Self.date("2026-09-26T10:00:10Z"))
            XCTAssertEqual(comment.threadId, "T")
        }
    }

    func testCommentOnlySummaryKeepsTextAndMentionWhileDecisionSummariesDoNot() async throws {
        let mention = #"<p><a class="user-mention notranslate" data-hovercard-type="user" href="https://github.com/RW">@RW</a> please look</p>"#
        func review(_ id: String, state: String, html: String, text: String) -> [String: Any] {
            var value = Self.review(id, state: state)
            value["bodyHTML"] = html
            value["bodyText"] = text
            value["updatedAt"] = "2026-01-03T00:00:00Z"
            return value
        }
        var mentioningComment = Self.comment("MENTION")
        mentioningComment["bodyHTML"] = mention
        var quotedComment = Self.comment("QUOTED")
        quotedComment["bodyHTML"] = "<blockquote>\(mention)</blockquote>"
        let node = Self.pullRequest(
            comments: Self.connection(total: 2, nodes: [mentioningComment, quotedComment]),
            reviews: Self.connection(total: 4, nodes: [
                review("SUMMARY", state: "COMMENTED", html: mention, text: "@RW please look"),
                review("EMPTY", state: "COMMENTED", html: "", text: " \n "),
                review("APPROVAL", state: "APPROVED", html: mention, text: "@RW please look"),
                review("CHANGES", state: "CHANGES_REQUESTED", html: "<p>Fix it</p>", text: "Fix it"),
            ]),
            opinionated: Self.connection(total: 1, nodes: [Self.leanReview("APPROVAL")]),
            reviewDecision: "APPROVED"
        )
        let transport = HydrationTransport { _, _ in Self.json(["data": ["nodes": [node]]]) }

        let pullRequest = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")[0].pullRequest

        let reviews = Dictionary(uniqueKeysWithValues: pullRequest.recentReviews.map { ($0.id, $0) })
        XCTAssertEqual(reviews["SUMMARY"]?.hasSummaryText, true)
        XCTAssertEqual(reviews["SUMMARY"]?.mentionsViewer, true)
        XCTAssertEqual(reviews["SUMMARY"]?.updatedAt, Self.date("2026-01-03T00:00:00Z"))
        XCTAssertEqual(reviews["EMPTY"]?.hasSummaryText, false)
        XCTAssertEqual(reviews["EMPTY"]?.mentionsViewer, false)
        XCTAssertEqual(reviews["APPROVAL"]?.hasSummaryText, true)
        XCTAssertEqual(reviews["APPROVAL"]?.mentionsViewer, false)
        XCTAssertEqual(reviews["CHANGES"]?.hasSummaryText, true)
        XCTAssertEqual(pullRequest.reviewDecision, .approved)
        XCTAssertEqual(pullRequest.recentCommentActivities.first { $0.id == "MENTION" }?.mentionsViewer, true)
        XCTAssertEqual(pullRequest.recentCommentActivities.first { $0.id == "QUOTED" }?.mentionsViewer, false)
    }

    func testNullPublicationOnPublishedCommentsFallsBackToCreation() async throws {
        var conversation = Self.comment("CONVERSATION", createdAt: "2026-03-01T00:00:00Z")
        conversation.removeValue(forKey: "state")
        conversation["publishedAt"] = NSNull()
        var submitted = Self.comment("SUBMITTED", createdAt: "2026-03-02T00:00:00Z")
        submitted["publishedAt"] = NSNull()
        var pending = Self.comment("PENDING", viewerDidAuthor: true, createdAt: "2026-03-03T00:00:00Z")
        pending["state"] = "PENDING"
        pending["publishedAt"] = NSNull()
        let node = Self.pullRequest(
            comments: Self.connection(total: 1, nodes: [conversation]),
            threads: Self.connection(total: 1, nodes: [Self.thread("T", comments: [submitted, pending])])
        )
        let server = GitHubFixtureServer(pullRequests: [node])

        let comments = try await server.fetcher.hydrate([Self.discovery()], login: "rw")[0]
            .pullRequest.recentCommentActivities

        XCTAssertEqual(comments.first { $0.id == "CONVERSATION" }?.publishedAt, Self.date("2026-03-01T00:00:00Z"))
        XCTAssertEqual(comments.first { $0.id == "SUBMITTED" }?.publishedAt, Self.date("2026-03-02T00:00:00Z"))
        let pendingComment = try XCTUnwrap(comments.first { $0.id == "PENDING" })
        XCTAssertNil(pendingComment.publishedAt)
    }

    func testMissingContentOrInvalidActivityDatesFailTheCompleteFetch() async throws {
        func conversation(_ edit: (inout [String: Any]) -> Void) -> [String: Any] {
            var value = Self.comment("C")
            value.removeValue(forKey: "state")
            edit(&value)
            return Self.pullRequest(comments: Self.connection(total: 1, nodes: [value]))
        }
        func inline(_ edit: (inout [String: Any]) -> Void) -> [String: Any] {
            var value = Self.comment("T_C")
            edit(&value)
            return Self.pullRequest(threads: Self.connection(total: 1, nodes: [Self.thread("T", comments: [value])]))
        }
        func fullReview(_ edit: (inout [String: Any]) -> Void) -> [String: Any] {
            var value = Self.review("R", state: "COMMENTED")
            edit(&value)
            return Self.pullRequest(reviews: Self.connection(total: 1, nodes: [value]))
        }
        let invalidNodes: [(String, [String: Any])] = [
            ("conversation body", conversation { $0.removeValue(forKey: "bodyHTML") }),
            ("conversation null body", conversation { $0["bodyHTML"] = NSNull() }),
            ("conversation invalid publication", conversation { $0["publishedAt"] = "earlier" }),
            ("conversation update", conversation { $0.removeValue(forKey: "updatedAt") }),
            ("conversation invalid update", conversation { $0["updatedAt"] = "yesterday" }),
            ("inline missing state", inline { $0.removeValue(forKey: "state") }),
            ("inline unknown state", inline { $0["state"] = "DRAFTED" }),
            ("inline invalid publication", inline { $0["publishedAt"] = "later" }),
            ("inline body", inline { $0.removeValue(forKey: "bodyHTML") }),
            ("review text", fullReview { $0.removeValue(forKey: "bodyText") }),
            ("review body", fullReview { $0.removeValue(forKey: "bodyHTML") }),
            ("review update", fullReview { $0.removeValue(forKey: "updatedAt") }),
            ("review invalid update", fullReview { $0["updatedAt"] = "soon" }),
        ]
        for (label, node) in invalidNodes {
            let server = GitHubFixtureServer(pullRequests: [node])
            do {
                _ = try await server.fetcher.hydrate([Self.discovery()], login: "rw")
                XCTFail("Expected \(label) to fail the fetch")
            } catch {
                XCTAssertEqual(error as? GitHubReadError, .invalidPayload, label)
            }
        }

        var olderComment = Self.comment("C_OLD")
        olderComment.removeValue(forKey: "bodyHTML")
        let initial = Self.pullRequest(
            comments: Self.connection(total: 2, nodes: [Self.comment("C_NEW")], previous: "before")
        )
        let transport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            return Self.json(["data": ["c0": ["comments": Self.connection(total: 2, nodes: [olderComment])]]])
        }
        do {
            _ = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
            XCTFail("Expected a continuation page without content to fail the fetch")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .invalidPayload)
        }
    }

    func testThreadCommentRestartRereadsTheNewestTenThenPagesOlderCommentsByHundred() async throws {
        let comments = (0..<16).map { Self.comment("TC\($0)") }
        let node = Self.pullRequest(threads: Self.connection(total: 1, nodes: [Self.thread("T", comments: comments)]))
        var deleted = false
        let server = GitHubFixtureServer(pullRequests: [node]) { index, server in
            // The newest comment is deleted just before the first older page, so its total drops and the thread's
            // comments restart.
            guard !deleted, case .string(let cursor) = server.requests[index].variables["cursor0"],
                  cursor.hasPrefix("comments:T:") else { return }
            deleted = true
            server.deleteThreadComment(threadID: "T", commentID: "TC15")
        }

        let pullRequest = try await server.fetcher.hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(Set(pullRequest.recentCommentActivities.map(\.id)), Set((0..<15).map { "TC\($0)" }))
        let threadCommentReads = server.requests.filter { $0.query.contains("... on PullRequestReviewThread") }
        let firstReads = threadCommentReads.filter { $0.variables["cursor0"] == .null }
        let olderPages = threadCommentReads.filter { $0.variables["cursor0"] != .null }
        XCTAssertFalse(firstReads.isEmpty)
        XCTAssertEqual(olderPages.count, 2)
        for request in firstReads {
            XCTAssertTrue(request.query.contains("comments(last: 10, before: $cursor0)"), request.query)
        }
        for request in olderPages {
            XCTAssertTrue(request.query.contains("comments(last: 100, before: $cursor0)"), request.query)
        }
        // The restart re-read comes after the first older page, and one older page follows it.
        let restartIndex = try XCTUnwrap(threadCommentReads.lastIndex { $0.variables["cursor0"] == .null })
        XCTAssertEqual(threadCommentReads[(restartIndex + 1)...].count, 1)
    }

    // MARK: Separate thread-comment reads

    func testPullRequestReadAndThreadPagesSelectThreadsWithoutComments() async throws {
        let hydration = GitHubPullRequestQueries.hydration
        XCTAssertTrue(hydration.contains(
            "reviewThreads(last: 100) { totalCount \(GitHubPullRequestQueries.pageInfoFields) nodes { id isResolved viewerCanResolve } }"
        ))
        let hydrationThreads = try XCTUnwrap(Self.selection(in: hydration, from: "reviewThreads(", to: "assignees("))
        XCTAssertFalse(hydrationThreads.contains("comments("))

        let server = GitHubFixtureServer(pullRequests: [Self.threadedPullRequest("PR_1", threads: 101)])
        let pullRequest = try await server.fetcher.hydrate([Self.discovery()], login: "rw")[0].pullRequest

        let threadPage = try XCTUnwrap(server.requests.first { $0.aliases.contains { $0.connection == "reviewThreads" } })
        let continuedThreads = try XCTUnwrap(Self.selection(in: threadPage.query, from: "reviewThreads(", to: "}\n}"))
        XCTAssertFalse(continuedThreads.contains("comments("))
        XCTAssertEqual(pullRequest.commentActivityCount, 101)
    }

    func testThreadsWithZeroTenAndElevenCommentsReadTheirCommentsCompletely() async throws {
        let counts = ["T_ZERO": 0, "T_TEN": 10, "T_ELEVEN": 11]
        let node = Self.pullRequest(threads: Self.connection(total: 3, nodes: ["T_ZERO", "T_TEN", "T_ELEVEN"].map { id in
            Self.thread(id, comments: (0..<counts[id]!).map { Self.comment("\(id)_C\($0)") })
        }))
        let server = GitHubFixtureServer(pullRequests: [node])

        let pullRequest = try await server.fetcher.hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(server.requests.compactMap(\.batchShape), ["first reads: 3", "other: 1"])
        XCTAssertEqual(server.requests.last?.aliases.map(\.id), ["T_ELEVEN"])
        for (id, count) in counts {
            XCTAssertEqual(pullRequest.recentCommentActivities.filter { $0.threadId == id }.count, count, id)
        }
    }

    func testThreadOf250CommentsReadsItsNewestTenThenOlderPagesOfAHundred() async throws {
        let server = GitHubFixtureServer(pullRequests: [Self.threadedPullRequest("PR_1", threads: 1) { _ in 250 }])

        let pullRequest = try await server.fetcher.hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(
            server.requests.compactMap(\.batchShape),
            ["first reads: 1", "other: 1", "other: 1", "other: 1"]
        )
        // Cursors mean "comments before index": the first read takes 240..<250, then 140..<240, 40..<140 and 0..<40.
        XCTAssertEqual(
            server.requests.flatMap(\.aliases).map(\.cursor),
            [nil, "comments:PR_1_T0:240", "comments:PR_1_T0:140", "comments:PR_1_T0:40"]
        )
        XCTAssertEqual(Set(pullRequest.recentCommentActivities.map(\.id)), Set((0..<250).map { "PR_1_T0_C\($0)" }))
    }

    func testTwentyPullRequestsWithFiveThreadsEachReadAllFirstCommentsInOneQuery() async throws {
        let ids = (0..<20).map { String(format: "PR_%02d", $0) }
        let server = GitHubFixtureServer(pullRequests: ids.map { Self.threadedPullRequest($0, threads: 5) })

        let hydrated = try await server.fetcher.hydrate(ids.map { Self.discovery(id: $0) }, login: "rw")

        XCTAssertEqual(server.queries.filter { $0.contains("CompletePullRequests") }.count, 1)
        XCTAssertEqual(server.requests.compactMap(\.batchShape), ["first reads: 100"])
        XCTAssertEqual(hydrated.map(\.pullRequest.commentActivityCount), Array(repeating: 5, count: 20))
    }

    func testFiftyPullRequestsWithFiveThreadsEachSplitFirstReadsIntoQueriesOfAHundred() async throws {
        let ids = (0..<50).map { String(format: "PR_%02d", $0) }
        let server = GitHubFixtureServer(pullRequests: ids.map { Self.threadedPullRequest($0, threads: 5) })

        let hydrated = try await server.fetcher.hydrate(ids.map { Self.discovery(id: $0) }, login: "rw")

        XCTAssertEqual(server.queries.filter { $0.contains("CompletePullRequests") }.count, 3)
        XCTAssertEqual(
            server.requests.compactMap(\.batchShape),
            ["first reads: 100", "first reads: 100", "first reads: 50"]
        )
        XCTAssertEqual(hydrated.map(\.pullRequest.commentActivityCount), Array(repeating: 5, count: 50))
    }

    func testThreadsBeyondTheFirstHundredGetFirstReadsAfterTheirThreadPage() async throws {
        let server = GitHubFixtureServer(pullRequests: [Self.threadedPullRequest("PR_1", threads: 130)])

        let pullRequest = try await server.fetcher.hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertTrue(server.queries[0].contains("CompletePullRequests"))
        XCTAssertEqual(
            server.requests.compactMap(\.batchShape),
            ["other: 1", "first reads: 100", "first reads: 30"]
        )
        XCTAssertEqual(server.requests.last?.aliases.map(\.id), (0..<30).map { "PR_1_T\($0)" })
        XCTAssertEqual(pullRequest.commentActivityCount, 130)
    }

    func testOtherEntriesQueuedBeforeFirstReadsGoFirst() async throws {
        var node = Self.threadedPullRequest("PR_1", threads: 2)
        node["comments"] = Self.connection(total: 11, nodes: (0..<11).map { Self.comment("PR_1_C\($0)") })
        let server = GitHubFixtureServer(pullRequests: [node])

        let pullRequest = try await server.fetcher.hydrate([Self.discovery(id: "PR_1")], login: "rw")[0].pullRequest

        XCTAssertEqual(server.requests.compactMap(\.batchShape), ["other: 1", "first reads: 2"])
        XCTAssertEqual(pullRequest.commentActivityCount, 13)
    }

    func testFirstReadsOfSeveralPullRequestsShareAQueryWhenTheyAreOldest() async throws {
        var second = Self.threadedPullRequest("PR_2", threads: 2)
        second["comments"] = Self.connection(total: 11, nodes: (0..<11).map { Self.comment("PR_2_C\($0)") })
        var third = Self.threadedPullRequest("PR_3", threads: 0)
        third["reviews"] = Self.connection(
            total: 11,
            nodes: (0..<11).map { Self.review("PR_3_R\($0)", state: "COMMENTED") }
        )
        let server = GitHubFixtureServer(pullRequests: [Self.threadedPullRequest("PR_1", threads: 2), second, third])

        let hydrated = try await server.fetcher.hydrate(
            ["PR_1", "PR_2", "PR_3"].map { Self.discovery(id: $0) },
            login: "rw"
        )

        XCTAssertEqual(server.requests.compactMap(\.batchShape), ["first reads: 4", "other: 2"])
        XCTAssertEqual(
            server.requests.compactMap { $0.batchShape == nil ? nil : $0.aliases.map(\.id) },
            [["PR_1_T0", "PR_1_T1", "PR_2_T0", "PR_2_T1"], ["PR_2", "PR_3"]]
        )
        XCTAssertEqual(server.requests.last?.aliases.map(\.connection), ["comments", "reviews"])
        XCTAssertEqual(hydrated.map(\.pullRequest.commentActivityCount), [2, 13, 0])
        XCTAssertEqual(hydrated[2].pullRequest.reviewCount, 11)
    }

    func testThreadOnTwoThreadPagesGetsOneFirstRead() async throws {
        let initial = Self.pullRequest(threads: Self.connection(
            total: 3,
            nodes: [Self.threadIdentity("T1"), Self.threadIdentity("T2")],
            previous: "threads-p2"
        ))
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            return Self.answer(query, variables) { alias in
                alias.connection == "reviewThreads"
                    ? Self.connection(total: 3, nodes: [Self.threadIdentity("T2"), Self.threadIdentity("T0")])
                    : Self.connection(total: 1, nodes: [Self.comment("\(alias.id)_C")])
            }
        }

        let pullRequest = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(transport.shapes, ["other: 1", "first reads: 3"])
        XCTAssertEqual(transport.requests.last?.aliases.map(\.id), ["T1", "T2", "T0"])
        XCTAssertEqual(Set(pullRequest.recentCommentActivities.map(\.id)), ["T0_C", "T1_C", "T2_C"])
    }

    func testFirstReadsOfARestartedThreadListCarryTheRestartAttempt() async throws {
        let initial = Self.pullRequest(threads: Self.connection(
            total: 2,
            nodes: [Self.threadIdentity("T")],
            previous: "threads-p2"
        ))
        let step = LockedCounter()
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            switch step.increment() {
            case 1:
                return Self.answer(query, variables) { _ in Self.connection(total: 1, nodes: []) }
            case 2:
                return Self.answer(query, variables) { _ in Self.connection(total: 1, nodes: [Self.threadIdentity("T")]) }
            default:
                // A short first read at attempt 1 can't restart again.
                return Self.answer(query, variables) { _ in Self.connection(total: 3, nodes: [Self.comment("T_C0")]) }
            }
        }

        do {
            _ = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
            XCTFail("Expected incomplete coverage")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .incompleteCoverage("Connection returned 1 of 3 items"))
        }
        XCTAssertEqual(transport.shapes, ["other: 1", "other: 1", "first reads: 1"])
    }

    func testThreadCommentsRestartedBeforeTheirThreadListRestartsAreReadAgain() async throws {
        let node = Self.threadedPullRequest("PR_1", threads: 301) { $0 == 250 ? 15 : 0 }
        let restartedThread = "PR_1_T250"
        var shortenedFirstRead = false
        var deletedOldestThread = false
        let server = GitHubFixtureServer(
            pullRequests: [node],
            beforeQuery: { index, server in
                // The thread list loses its oldest thread just before its last page at attempt 0 is read.
                guard !deletedOldestThread,
                      server.requests[index].aliases.contains(where: { $0.cursor == "reviewThreads:PR_1:1" }) else { return }
                deletedOldestThread = true
                server.deleteThread(prID: "PR_1", threadID: "PR_1_T0")
            },
            afterQuery: { _, request, response in
                // The thread's first read comes back short with no older page, which restarts its comments.
                guard !shortenedFirstRead,
                      let alias = request.aliases.first(where: { $0.id == restartedThread && $0.cursor == nil }) else { return }
                shortenedFirstRead = true
                var data = response["data"] as! [String: Any]
                data[alias.name] = ["comments": Self.connection(
                    total: 15,
                    nodes: (0..<9).map { Self.comment("\(restartedThread)_C\($0)") }
                )]
                response["data"] = data
            }
        )

        let pullRequest = try await server.fetcher.hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(
            Array(server.requests.compactMap(\.batchShape).prefix(6)),
            ["other: 1", "first reads: 100", "other: 1", "first reads: 100", "first reads: 100", "other: 2"]
        )
        let restartBatch = try XCTUnwrap(server.requests.filter { $0.batchShape != nil }.dropFirst(5).first)
        XCTAssertEqual(
            restartBatch.aliases.map(\.cursor),
            ["reviewThreads:PR_1:1", "comments:\(restartedThread):5"]
        )
        XCTAssertEqual(
            Set(pullRequest.recentCommentActivities.map(\.id)),
            Set((0..<15).map { "\(restartedThread)_C\($0)" })
        )
    }

    func testThreadListRestartDiscardsAQueuedCommentPage() async throws {
        let first = Self.threadedPullRequest("PR_1", threads: 2) { $0 == 1 ? 12 : 0 }
        let second = Self.threadedPullRequest("PR_2", threads: 19) { _ in 11 }
        let server = GitHubFixtureServer(
            pullRequests: [first, second],
            beforeQuery: { index, server in
                if server.requests[index].aliases.contains(where: { $0.connection == "reviewThreads" && $0.cursor != nil }) {
                    server.deleteThread(prID: "PR_1", threadID: "PR_1_T0")
                }
            },
            afterQuery: { _, request, response in
                // PR_1's first thread page holds only its newest thread, so its thread list continues.
                guard request.query.contains("CompletePullRequests") else { return }
                var data = response["data"] as! [String: Any]
                var nodes = data["nodes"] as! [[String: Any]]
                let index = nodes.firstIndex { $0["id"] as? String == "PR_1" }!
                nodes[index]["reviewThreads"] = Self.connection(
                    total: 2,
                    nodes: [Self.threadIdentity("PR_1_T1")],
                    previous: "reviewThreads:PR_1:1"
                )
                data["nodes"] = nodes
                response["data"] = data
            }
        )

        let hydrated = try await server.fetcher.hydrate(
            [Self.discovery(id: "PR_2"), Self.discovery(id: "PR_1")],
            login: "rw"
        )

        XCTAssertEqual(
            server.requests.compactMap(\.batchShape),
            ["first reads: 20", "other: 20", "other: 1", "first reads: 1", "other: 1"]
        )
        let olderPagesOfRestartedThread = server.requests.filter { request in
            request.aliases.contains { $0.id == "PR_1_T1" && $0.cursor != nil }
        }
        XCTAssertEqual(olderPagesOfRestartedThread.count, 1)
        XCTAssertEqual(olderPagesOfRestartedThread.first?.batchShape, "other: 1")
        XCTAssertEqual(hydrated.map(\.pullRequest.commentActivityCount), [19 * 11, 12])
    }

    func testContinuationCursorThatFailsToAdvanceFails() async throws {
        let initial = Self.pullRequest(comments: Self.connection(
            total: 12,
            nodes: (2..<12).map { Self.comment("C\($0)") },
            previous: "before"
        ))
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            return Self.answer(query, variables) { _ in
                Self.connection(total: 12, nodes: [Self.comment("C1")], previous: "before")
            }
        }

        do {
            _ = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
            XCTFail("Expected a repeated cursor to fail the fetch")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .incompleteCoverage("Repeated continuation cursor"))
        }
        XCTAssertEqual(transport.shapes, ["other: 1"])
    }

    // MARK: Threads deleted mid-refresh

    func testDeletedThreadIsDroppedAfterAConfirmingRetryWhileSiblingsMerge() async throws {
        let server = GitHubFixtureServer(
            pullRequests: [
                Self.threadedPullRequest("PR_1", threads: 2),
                Self.threadedPullRequest("PR_2", threads: 2)
            ],
            beforeQuery: { index, server in
                if index == 1 { server.deleteThread(prID: "PR_1", threadID: "PR_1_T0") }
            }
        )

        let hydrated = try await server.fetcher.hydrate(
            [Self.discovery(id: "PR_1"), Self.discovery(id: "PR_2")],
            login: "rw"
        )

        XCTAssertEqual(server.requests.compactMap(\.batchShape), ["first reads: 4", "first reads: 1"])
        let retry = try XCTUnwrap(server.requests.last)
        XCTAssertTrue(retry.query.contains("p: node(id: $pr) { id }"))
        XCTAssertEqual(retry.variables["pr"], .string("PR_1"))
        XCTAssertEqual(retry.aliases.map(\.id), ["PR_1_T0"])
        XCTAssertEqual(hydrated[0].pullRequest.recentCommentActivities.map(\.id), ["PR_1_T1_C0"])
        XCTAssertEqual(hydrated[0].pullRequest.commentCount, 1)
        XCTAssertEqual(Set(hydrated[1].pullRequest.recentCommentActivities.map(\.id)), ["PR_2_T0_C0", "PR_2_T1_C0"])
        XCTAssertEqual(hydrated[1].pullRequest.commentCount, 2)
    }

    func testMissingThreadWhoseRetryReturnsDataMergesNormally() async throws {
        let initial = Self.pullRequest(threads: Self.connection(total: 1, nodes: [Self.threadIdentity("T")]))
        let step = LockedCounter()
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            if step.increment() == 1 {
                return Self.notFoundAtFirstAlias()
            }
            XCTAssertTrue(query.contains("p: node(id: $pr) { id }"))
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 1, nodes: [Self.comment("T_C0")])],
                "p": ["id": "PR_1"]
            ]])
        }

        let pullRequest = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(pullRequest.recentCommentActivities.map(\.id), ["T_C0"])
        XCTAssertEqual(transport.shapes, ["first reads: 1", "first reads: 1"])
    }

    func testThreadDeletedWhileItsOlderPageIsQueuedIsDropped() async throws {
        let initial = Self.pullRequest(threads: Self.connection(
            total: 2,
            nodes: [Self.threadIdentity("T"), Self.threadIdentity("U")]
        ))
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            let aliases = GitHubFixtureServer.aliases(query: query, variables: variables)
            if aliases.allSatisfy({ $0.cursor == nil }) {
                return Self.answer(query, variables) { alias in
                    alias.id == "T"
                        ? Self.connection(total: 11, nodes: (1..<11).map { Self.comment("T_C\($0)") }, previous: "t-older")
                        : Self.connection(total: 1, nodes: [Self.comment("U_C0")])
                }
            }
            XCTAssertEqual(aliases.map(\.cursor), ["t-older"])
            if query.contains("p: node(") {
                return Self.notFoundAtFirstAlias(pullRequest: ["id": "PR_1"])
            }
            return Self.notFoundAtFirstAlias()
        }

        let pullRequest = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(pullRequest.recentCommentActivities.map(\.id), ["U_C0"])
        XCTAssertEqual(pullRequest.commentCount, 1)
        XCTAssertEqual(transport.shapes, ["first reads: 2", "other: 1", "other: 1"])
        XCTAssertTrue(transport.queries.last?.contains("p: node(id: $pr) { id }") == true)
    }

    func testDeletedThreadOfAnUnreachablePullRequestFailsTheRefresh() async throws {
        let server = GitHubFixtureServer(
            pullRequests: [Self.threadedPullRequest("PR_1", threads: 2)],
            beforeQuery: { index, server in
                if index == 1 { server.deleteThread(prID: "PR_1", threadID: "PR_1_T0") }
                if index == 2 { server.removePullRequest(id: "PR_1") }
            }
        )

        do {
            _ = try await server.fetcher.hydrate([Self.discovery()], login: "rw")
            XCTFail("Expected an unreachable PR to fail the refresh")
        } catch let error as GitHubReadError {
            guard case .graphQL = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(server.requests.compactMap(\.batchShape), ["first reads: 2", "first reads: 1"])
        XCTAssertTrue(server.queries.last?.contains("p: node(id: $pr) { id }") == true)
    }

    func testMissingThreadRetryWithAnErrorOnItsPullRequestFails() async throws {
        let initial = Self.pullRequest(threads: Self.connection(total: 1, nodes: [Self.threadIdentity("T")]))
        let step = LockedCounter()
        let transport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            if step.increment() == 1 {
                return Self.notFoundAtFirstAlias()
            }
            return Self.json([
                "data": ["c0": ["comments": Self.connection(total: 1, nodes: [Self.comment("T_C0")])], "p": NSNull()],
                "errors": [["type": "INTERNAL", "path": ["p"], "message": "Something went wrong"]]
            ])
        }

        do {
            _ = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
            XCTFail("Expected the PR error to fail the refresh")
        } catch let error as GitHubReadError {
            guard case .graphQL = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(transport.shapes, ["first reads: 1", "first reads: 1"])
    }

    func testOtherScopedErrorOnAFirstReadIsRetriedAloneWithoutThePullRequest() async throws {
        for retrySucceeds in [true, false] {
            let initial = Self.pullRequest(threads: Self.connection(
                total: 2,
                nodes: [Self.threadIdentity("T"), Self.threadIdentity("U")]
            ))
            let step = LockedCounter()
            let transport = HydrationTransport { query, variables in
                if query.contains("CompletePullRequests") {
                    return Self.json(["data": ["nodes": [initial]]])
                }
                let internalError: [String: Any] = ["type": "INTERNAL", "path": ["c0"], "message": "Something went wrong"]
                if step.increment() == 1 {
                    return Self.json([
                        "data": ["c0": NSNull(), "c1": ["comments": Self.connection(total: 1, nodes: [Self.comment("U_C0")])]],
                        "errors": [internalError]
                    ])
                }
                XCTAssertFalse(query.contains("p: node("))
                XCTAssertEqual(GitHubFixtureServer.aliases(query: query, variables: variables).map(\.id), ["T"])
                return retrySucceeds
                    ? Self.answer(query, variables) { _ in Self.connection(total: 1, nodes: [Self.comment("T_C0")]) }
                    : Self.json(["data": ["c0": NSNull()], "errors": [internalError]])
            }

            do {
                let pullRequest = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")[0].pullRequest
                XCTAssertTrue(retrySucceeds)
                XCTAssertEqual(Set(pullRequest.recentCommentActivities.map(\.id)), ["T_C0", "U_C0"])
            } catch let error as GitHubReadError {
                XCTAssertFalse(retrySucceeds)
                guard case .graphQL = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(transport.shapes, ["first reads: 2", "first reads: 1"])
        }
    }

    func testNotFoundBelowTheThreadAliasIsNotAMissingThread() async throws {
        let initial = Self.pullRequest(threads: Self.connection(total: 1, nodes: [Self.threadIdentity("T")]))
        let transport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            XCTAssertFalse(query.contains("p: node("))
            return Self.json([
                "data": ["c0": NSNull()],
                "errors": [["type": "NOT_FOUND", "path": ["c0", "comments"], "message": "Not Found"]]
            ])
        }

        do {
            _ = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
            XCTFail("Expected the retry to fail the refresh")
        } catch let error as GitHubReadError {
            guard case .graphQL = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(transport.shapes, ["first reads: 1", "first reads: 1"])
    }

    func testRateLimitOnAMissingThreadRetryStaysARateLimit() async throws {
        let initial = Self.pullRequest(threads: Self.connection(total: 1, nodes: [Self.threadIdentity("T")]))
        let step = LockedCounter()
        let transport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            if step.increment() == 1 {
                return Self.notFoundAtFirstAlias()
            }
            XCTAssertTrue(query.contains("p: node(id: $pr) { id }"))
            return Self.json([
                "data": ["c0": NSNull(), "p": ["id": "PR_1"]],
                "errors": [["type": "RATE_LIMITED", "path": ["c0"], "message": "Rate limited"]]
            ])
        }

        do {
            _ = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
            XCTFail("Expected a rate limit")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .rateLimited(retryAt: nil))
        }
    }

    func testMissingThreadRetryWithoutErrorsIsNotDropped() async throws {
        let initial = Self.pullRequest(threads: Self.connection(total: 1, nodes: [Self.threadIdentity("T")]))
        let step = LockedCounter()
        let transport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            if step.increment() == 1 {
                return Self.notFoundAtFirstAlias()
            }
            return Self.json(["data": ["c0": NSNull(), "p": ["id": "PR_1"]]])
        }

        do {
            _ = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")
            XCTFail("Expected an invalid payload")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .invalidPayload)
        }
    }

    func testDroppedThreadListedAgainOnALaterThreadPageIsReadAfresh() async throws {
        let initial = Self.pullRequest(threads: Self.connection(
            total: 2,
            nodes: [Self.threadIdentity("T")],
            previous: "threads-p2"
        ))
        let step = LockedCounter()
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            switch step.increment() {
            case 1:
                return Self.answer(query, variables) { _ in
                    Self.connection(total: 2, nodes: [Self.threadIdentity("U")], previous: "threads-p3")
                }
            case 2:
                let aliases = GitHubFixtureServer.aliases(query: query, variables: variables)
                let missing = try XCTUnwrap(aliases.first { $0.id == "T" })
                var data: [String: Any] = [missing.name: NSNull()]
                for alias in aliases where alias.id != "T" {
                    data[alias.name] = ["comments": Self.connection(total: 1, nodes: [Self.comment("U_C0")])]
                }
                return Self.json([
                    "data": data,
                    "errors": [["type": "NOT_FOUND", "path": [missing.name], "message": "Not Found"]]
                ])
            case 3:
                XCTAssertTrue(query.contains("p: node(id: $pr) { id }"))
                return Self.notFoundAtFirstAlias(pullRequest: ["id": "PR_1"])
            case 4:
                return Self.answer(query, variables) { _ in Self.connection(total: 2, nodes: [Self.threadIdentity("T")]) }
            default:
                return Self.answer(query, variables) { _ in Self.connection(total: 1, nodes: [Self.comment("T_C0")]) }
            }
        }

        let pullRequest = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")[0].pullRequest

        XCTAssertEqual(
            transport.shapes,
            ["other: 1", "first reads: 2", "first reads: 1", "other: 1", "first reads: 1"]
        )
        XCTAssertEqual(Set(pullRequest.recentCommentActivities.map(\.id)), ["T_C0", "U_C0"])
        XCTAssertEqual(
            Set(pullRequest.recentCommentActivities.compactMap(\.threadId)),
            ["T", "U"]
        )
    }

    private static func fetcher(_ transport: HydrationTransport) -> GitHubPullRequestFetcher {
        GitHubPullRequestFetcher { query, variables in
            try await transport.read(query: query, variables: variables)
        }
    }

    static func discovery(
        id: String = "PR_1",
        isDirectlyRequested: Bool = true,
        isTeamRequested: Bool = false
    ) -> DiscoveredPullRequest {
        DiscoveredPullRequest(
            id: id,
            repository: "acme/app",
            number: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            isAuthored: false,
            isAssigned: false,
            isDirectlyRequested: isDirectlyRequested,
            isTeamRequested: isTeamRequested
        )
    }

    static func pullRequest(
        id: String = "PR_1",
        isArchived: Bool = false,
        comments: [String: Any] = connection(total: 0, nodes: []),
        reviews: [String: Any] = connection(total: 0, nodes: []),
        opinionated: [String: Any] = connection(total: 0, nodes: []),
        threads: [String: Any] = connection(total: 0, nodes: []),
        assignees: [String: Any] = connection(total: 0, nodes: []),
        requests: [String: Any] = connection(total: 0, nodes: []),
        reviewDecision: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "id": id, "title": "Complete hydration", "number": 1,
            "url": "https://github.com/acme/app/pull/1", "state": "OPEN",
            "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z",
            "headRefName": "feature", "headRefOid": "abc", "isDraft": false,
            "mergeable": "MERGEABLE", "additions": 1, "deletions": 2,
            "statusCheckRollup": ["state": "SUCCESS"],
            "author": user("author"), "repository": ["nameWithOwner": "acme/app", "isArchived": isArchived],
            "comments": comments, "reviews": reviews, "latestOpinionatedReviews": opinionated,
            "reviewThreads": threads, "assignees": assignees, "reviewRequests": requests
        ]
        if let reviewDecision {
            result["reviewDecision"] = reviewDecision
        }
        return result
    }

    static func connection(
        total: Int,
        nodes: [[String: Any]],
        previous: String? = nil
    ) -> [String: Any] {
        [
            "totalCount": total,
            "nodes": nodes,
            "pageInfo": [
                "startCursor": previous.map { $0 as Any } ?? NSNull(), "endCursor": "end",
                "hasPreviousPage": previous != nil, "hasNextPage": false
            ]
        ]
    }

    static func user(_ login: String, typename: String = "User") -> [String: Any] {
        ["id": "USER_\(login)", "login": login, "__typename": typename]
    }

    static func comment(
        _ id: String,
        viewerDidAuthor: Bool = false,
        author: String? = nil,
        createdAt: String = "2026-01-01T00:00:00Z",
        reviewID: String? = nil,
        typename: String = "User"
    ) -> [String: Any] {
        var result: [String: Any] = [
            "id": id, "createdAt": createdAt, "publishedAt": createdAt, "updatedAt": createdAt,
            "bodyHTML": "<p>Comment \(id)</p>", "state": "SUBMITTED",
            "url": "https://github.com/acme/app/pull/1#issuecomment-\(id)",
            "viewerDidAuthor": viewerDidAuthor,
            "author": user(author ?? (viewerDidAuthor ? "rw" : "reviewer"), typename: typename)
        ]
        if let reviewID {
            result["pullRequestReview"] = ["id": reviewID]
        }
        return result
    }

    private static func selection(in query: String, from start: String, to end: String) -> Substring? {
        guard let startRange = query.range(of: start),
              let endRange = query.range(of: end, range: startRange.upperBound..<query.endIndex)
        else { return nil }
        return query[startRange.lowerBound..<endRange.lowerBound]
    }

    static func review(
        _ id: String,
        state: String,
        author: String = "reviewer",
        submittedAt: String = "2026-01-01T00:00:00Z",
        viewerDidAuthor: Bool = false,
        typename: String = "User"
    ) -> [String: Any] {
        [
            "id": id, "state": state, "submittedAt": submittedAt,
            "updatedAt": submittedAt, "bodyHTML": "", "bodyText": "",
            "url": "https://github.com/acme/app/pull/1#pullrequestreview-\(id)",
            "viewerDidAuthor": viewerDidAuthor, "author": user(author, typename: typename)
        ]
    }

    /// A latest-opinionated review node, which never carries summary content.
    static func leanReview(_ id: String, state: String = "APPROVED") -> [String: Any] {
        var value = review(id, state: state)
        ["updatedAt", "bodyHTML", "bodyText"].forEach { value.removeValue(forKey: $0) }
        return value
    }

    static func thread(
        _ id: String,
        isResolved: Bool = false,
        viewerCanResolve: Bool = true,
        comments: [[String: Any]] = [],
        commentsConnection: [String: Any]? = nil
    ) -> [String: Any] {
        [
            "id": id, "isResolved": isResolved, "viewerCanResolve": viewerCanResolve,
            "comments": commentsConnection ?? connection(total: comments.count, nodes: comments)
        ]
    }

    /// A PR whose threads `<id>_T<n>` hold `comments(n)` comments `<thread id>_C<k>` each.
    static func threadedPullRequest(
        _ id: String,
        threads: Int,
        comments: (Int) -> Int = { _ in 1 }
    ) -> [String: Any] {
        let nodes = (0..<threads).map { index in
            let threadID = "\(id)_T\(index)"
            return thread(threadID, comments: (0..<comments(index)).map { comment("\(threadID)_C\($0)") })
        }
        return pullRequest(id: id, threads: connection(total: nodes.count, nodes: nodes))
    }

    /// A thread node as the PR read and thread pages now select it, without comments.
    static func threadIdentity(_ id: String, isResolved: Bool = false, viewerCanResolve: Bool = true) -> [String: Any] {
        ["id": id, "isResolved": isResolved, "viewerCanResolve": viewerCanResolve]
    }

    /// Answers a continuation query alias by alias with the connection page `page` returns for each.
    static func answer(
        _ query: String,
        _ variables: [String: GitHubQueryValue],
        page: (GitHubFixtureServer.Alias) -> [String: Any]
    ) -> Data {
        var data: [String: Any] = [:]
        for alias in GitHubFixtureServer.aliases(query: query, variables: variables) {
            data[alias.name] = [alias.connection: page(alias)]
        }
        return json(["data": data])
    }

    /// A single-alias continuation answer whose thread is gone. `pullRequest` answers the `p` alias.
    static func notFoundAtFirstAlias(pullRequest: [String: Any]? = nil) -> Data {
        var data: [String: Any] = ["c0": NSNull()]
        if let pullRequest { data["p"] = pullRequest }
        return json([
            "data": data,
            "errors": [["type": "NOT_FOUND", "path": ["c0"], "message": "Not Found"]]
        ])
    }

    static func request(
        _ id: String,
        typeName: String = "User",
        login: String = "rw",
        teamSlug: String = "developers",
        teamOrganization: String = "acme"
    ) -> [String: Any] {
        if typeName == "Team" {
            return [
                "id": id,
                "requestedReviewer": [
                    "__typename": "Team", "id": "TEAM_\(id)", "slug": teamSlug,
                    "organization": ["login": teamOrganization]
                ]
            ]
        }
        return [
            "id": id,
            "requestedReviewer": ["__typename": "User", "id": "USER_\(id)", "login": login]
        ]
    }

    static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    static func string(_ value: GitHubQueryValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private final class HydrationTransport: @unchecked Sendable {
    typealias Handler = (String, [String: GitHubQueryValue]) throws -> Data
    private let handler: Handler
    private let lock = NSLock()
    private var storedRequests: [GitHubFixtureServer.Request] = []
    var requests: [GitHubFixtureServer.Request] { lock.withLock { storedRequests } }
    var queries: [String] { requests.map(\.query) }
    var shapes: [String] { requests.compactMap(\.batchShape) }

    init(_ handler: @escaping Handler) { self.handler = handler }

    func read(query: String, variables: [String: GitHubQueryValue]) async throws -> Data {
        lock.withLock { storedRequests.append(GitHubFixtureServer.Request(query: query, variables: variables)) }
        return try handler(query, variables)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() -> Int { lock.withLock { stored += 1; return stored } }
}
