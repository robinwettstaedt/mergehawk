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
                nodes: (1..<21).map { Self.thread("T\($0)") },
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
            )
        )
        let transport = HydrationTransport { query, _ in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            XCTAssertFalse(query.contains("title"))
            XCTAssertFalse(query.contains("headRefOid"))
            XCTAssertFalse(query.contains("statusCheckRollup"))
            XCTAssertFalse(query.contains("author { id"))
            XCTAssertTrue(query.contains("author { login }"))
            XCTAssertTrue(query.contains("assignees(last:"))
            XCTAssertTrue(query.contains("nodes { id login avatarUrl(size: 64) }"))
            XCTAssertTrue(query.contains("... on User { id login }"))
            XCTAssertTrue(query.contains("... on Team { id slug"))
            let topLevelComments = try XCTUnwrap(Self.selection(in: query, from: "c0:", to: "c1:"))
            XCTAssertFalse(topLevelComments.contains("pullRequestReview"))
            let reviewThreads = try XCTUnwrap(Self.selection(in: query, from: "c2:", to: "c3:"))
            XCTAssertTrue(reviewThreads.contains("pullRequestReview { id }"))
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 20, nodes: (0..<10).map { Self.comment("C\($0)") })],
                "c1": ["reviews": Self.connection(total: 11, nodes: [Self.review("R0", state: "APPROVED")])],
                "c2": ["reviewThreads": Self.connection(total: 21, nodes: [Self.thread("T0", comments: [Self.comment("THREAD_COMMENT", reviewID: "THREAD_REVIEW")])])],
                "c3": ["assignees": Self.connection(total: 21, nodes: [Self.user("rw")])],
                "c4": ["reviewRequests": Self.connection(total: 21, nodes: [Self.request("Q0")])]
            ]])
        }
        let discovery = Self.discovery()

        let hydrated = try await Self.fetcher(transport).hydrate([discovery], login: "rw")

        XCTAssertEqual(hydrated.count, 1)
        XCTAssertEqual(hydrated[0].pullRequest.recentCommentActivities.count, 21)
        XCTAssertEqual(hydrated[0].pullRequest.recentReviews.count, 11)
        XCTAssertEqual(hydrated[0].pullRequest.reviewDecision, .approved)
        XCTAssertEqual(hydrated[0].pullRequest.commentCount, 1)
        XCTAssertTrue(hydrated[0].pullRequest.isAssignedToViewer)
        XCTAssertEqual(hydrated[0].pullRequest.reviewRequestKind, .direct)
        XCTAssertEqual(hydrated[0].pullRequest.repositoryIsArchived, true)
        let topLevelComment = try XCTUnwrap(hydrated[0].pullRequest.recentCommentActivities.first { $0.id == "C0" })
        XCTAssertEqual(topLevelComment.source, .pullRequest)
        XCTAssertNil(topLevelComment.reviewId)
        let threadComment = try XCTUnwrap(hydrated[0].pullRequest.recentCommentActivities.first { $0.id == "THREAD_COMMENT" })
        XCTAssertEqual(threadComment.source, .reviewThread)
        XCTAssertEqual(threadComment.reviewId, "THREAD_REVIEW")
        XCTAssertEqual(transport.queries.filter { $0.contains("CompletePullRequests") }.count, 1)
        XCTAssertEqual(transport.queries.filter { $0.contains("ContinuePullRequestConnections") }.count, 1)
    }

    func testNestedThreadCursorRoutesToItsThreadAndDeduplicatesBoundaryRepeat() async throws {
        let oldThread = Self.thread(
            "T_OLD",
            commentsConnection: Self.connection(
                total: 11,
                nodes: (1..<11).map { Self.comment("TC\($0)", viewerDidAuthor: true) },
                previous: "thread-before"
            )
        )
        let initial = Self.pullRequest(
            threads: Self.connection(total: 2, nodes: [Self.thread("T_NEW"), oldThread])
        )
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            XCTAssertEqual(Self.string(variables["id0"]), "T_OLD")
            XCTAssertFalse(query.contains("author { id"))
            XCTAssertTrue(query.contains("author { login }"))
            XCTAssertTrue(query.contains("pullRequestReview { id }"))
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 11, nodes: [
                    Self.comment("TC1", viewerDidAuthor: true),
                    Self.comment("TC0", viewerDidAuthor: false, reviewID: "THREAD_REVIEW")
                ])]
            ]])
        }

        let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

        XCTAssertEqual(hydrated[0].pullRequest.recentCommentActivities.count, 11)
        XCTAssertEqual(hydrated[0].pullRequest.commentCount, 1)
        let continuedComment = try XCTUnwrap(hydrated[0].pullRequest.recentCommentActivities.first { $0.id == "TC0" })
        XCTAssertEqual(continuedComment.source, .reviewThread)
        XCTAssertEqual(continuedComment.reviewId, "THREAD_REVIEW")
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
        let survivingComments = (1..<11).map { Self.comment("T1C\($0)") }
        let otherThreads = (2..<21).map { Self.thread("T\($0)") }
        let initial = Self.pullRequest(
            threads: Self.connection(
                total: 21,
                nodes: [Self.thread("T1", commentsConnection: Self.connection(
                    total: 11,
                    nodes: survivingComments,
                    previous: "t1-before"
                ))] + otherThreads,
                previous: "threads-before"
            )
        )
        let transport = HydrationTransport { query, variables in
            if query.contains("CompletePullRequests") {
                return Self.json(["data": ["nodes": [initial]]])
            }
            if Self.string(variables["cursor0"]) == "threads-before" {
                return Self.json(["data": [
                    "c0": ["reviewThreads": Self.connection(total: 20, nodes: [])],
                    "c1": ["comments": Self.connection(total: 11, nodes: [Self.comment("T1C0")])]
                ]])
            }
            return Self.json(["data": [
                "c0": ["reviewThreads": Self.connection(
                    total: 20,
                    nodes: [Self.thread("T1", comments: survivingComments)] + otherThreads
                )]
            ]])
        }

        let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

        XCTAssertEqual(
            Set(hydrated[0].pullRequest.recentCommentActivities.map(\.id)),
            Set(survivingComments.compactMap { $0["id"] as? String })
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
            XCTAssertTrue(query.contains("author { login }"))
            return Self.json(["data": [
                "c0": ["comments": Self.connection(total: 11, nodes: [Self.comment("C1"), Self.comment("C0")])],
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
        var review = Self.review("REVIEW_WITH_ACTOR", state: "APPROVED")
        review["author"] = ["login": "review-author"]
        var node = Self.pullRequest(
            comments: Self.connection(total: 1, nodes: [comment]),
            reviews: Self.connection(total: 1, nodes: [review]),
            opinionated: Self.connection(total: 1, nodes: [review])
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
        XCTAssertEqual(pullRequest.recentReviews.first?.author, "review-author")
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
            threads: Self.connection(total: 2, nodes: [resolvedThread, actionableThread])
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
        let transport = HydrationTransport { _, _ in
            Self.json(["data": ["nodes": [node]]])
        }

        let pullRequest = try await Self.fetcher(transport)
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
        let transport = HydrationTransport { _, _ in
            Self.json(["data": ["nodes": [node]]])
        }

        let pullRequest = try await Self.fetcher(transport)
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
                opinionated: Self.connection(total: reviews.count, nodes: reviews)
            )
            let transport = HydrationTransport { _, _ in
                Self.json(["data": ["nodes": [initial]]])
            }

            let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

            XCTAssertEqual(hydrated[0].pullRequest.reviewDecision, expected)
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

    private static func fetcher(_ transport: HydrationTransport) -> GitHubPullRequestFetcher {
        GitHubPullRequestFetcher { query, variables in
            try await transport.read(query: query, variables: variables)
        }
    }

    private static func discovery(
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

    private static func pullRequest(
        id: String = "PR_1",
        isArchived: Bool = false,
        comments: [String: Any] = connection(total: 0, nodes: []),
        reviews: [String: Any] = connection(total: 0, nodes: []),
        opinionated: [String: Any] = connection(total: 0, nodes: []),
        threads: [String: Any] = connection(total: 0, nodes: []),
        assignees: [String: Any] = connection(total: 0, nodes: []),
        requests: [String: Any] = connection(total: 0, nodes: [])
    ) -> [String: Any] {
        [
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
                "startCursor": previous.map { $0 as Any } ?? NSNull(), "endCursor": "end",
                "hasPreviousPage": previous != nil, "hasNextPage": false
            ]
        ]
    }

    private static func user(_ login: String) -> [String: Any] {
        ["id": "USER_\(login)", "login": login]
    }

    private static func comment(
        _ id: String,
        viewerDidAuthor: Bool = false,
        author: String? = nil,
        createdAt: String = "2026-01-01T00:00:00Z",
        reviewID: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "id": id, "createdAt": createdAt,
            "viewerDidAuthor": viewerDidAuthor,
            "author": user(author ?? (viewerDidAuthor ? "rw" : "reviewer"))
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

    private static func review(
        _ id: String,
        state: String,
        author: String = "reviewer",
        submittedAt: String = "2026-01-01T00:00:00Z",
        viewerDidAuthor: Bool = false
    ) -> [String: Any] {
        [
            "id": id, "state": state, "submittedAt": submittedAt,
            "viewerDidAuthor": viewerDidAuthor, "author": user(author)
        ]
    }

    private static func thread(
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

    private static func request(
        _ id: String,
        typeName: String = "User",
        login: String = "rw"
    ) -> [String: Any] {
        if typeName == "Team" {
            return [
                "id": id,
                "requestedReviewer": [
                    "__typename": "Team", "id": "TEAM_\(id)", "slug": "developers",
                    "organization": ["login": "acme"]
                ]
            ]
        }
        return [
            "id": id,
            "requestedReviewer": ["__typename": "User", "id": "USER_\(id)", "login": login]
        ]
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func string(_ value: GitHubQueryValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private final class HydrationTransport: @unchecked Sendable {
    typealias Handler = (String, [String: GitHubQueryValue]) throws -> Data
    private let handler: Handler
    private let lock = NSLock()
    private var storedQueries: [String] = []
    var queries: [String] { lock.withLock { storedQueries } }

    init(_ handler: @escaping Handler) { self.handler = handler }

    func read(query: String, variables: [String: GitHubQueryValue]) async throws -> Data {
        lock.withLock { storedQueries.append(query) }
        return try handler(query, variables)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() -> Int { lock.withLock { stored += 1; return stored } }
}
