@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubPaginationTests: XCTestCase {
    func testHydratesEveryRequiredConnectionWithoutRepeatingDashboardFields() async throws {
        let initial = Self.pullRequest(
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
                "c0": ["comments": Self.connection(total: 11, nodes: [Self.comment("C0")])]
            ]])
        }

        let hydrated = try await Self.fetcher(transport).hydrate([Self.discovery()], login: "rw")

        XCTAssertEqual(hydrated[0].pullRequest.recentCommentActivities.count, 11)
        XCTAssertEqual(hydrated[0].pullRequest.recentReviews.count, 11)
        XCTAssertEqual(continuations.value, 2)
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
            (["state": "PENDING"], .pending),
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

    private static func fetcher(_ transport: HydrationTransport) -> GitHubPullRequestFetcher {
        GitHubPullRequestFetcher { query, variables in
            try await transport.read(query: query, variables: variables)
        }
    }

    private static func discovery(id: String = "PR_1") -> DiscoveredPullRequest {
        DiscoveredPullRequest(
            id: id,
            repository: "acme/app",
            number: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            isAuthored: false,
            isAssigned: false,
            isDirectlyRequested: true,
            isTeamRequested: false
        )
    }

    private static func pullRequest(
        id: String = "PR_1",
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
            "author": user("author"), "repository": ["nameWithOwner": "acme/app"],
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
        reviewID: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "id": id, "createdAt": "2026-01-01T00:00:00Z",
            "viewerDidAuthor": viewerDidAuthor, "author": user(viewerDidAuthor ? "rw" : "reviewer")
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

    private static func review(_ id: String, state: String) -> [String: Any] {
        [
            "id": id, "state": state, "submittedAt": "2026-01-01T00:00:00Z",
            "viewerDidAuthor": false, "author": user("reviewer")
        ]
    }

    private static func thread(
        _ id: String,
        comments: [[String: Any]] = [],
        commentsConnection: [String: Any]? = nil
    ) -> [String: Any] {
        [
            "id": id, "isResolved": false, "viewerCanResolve": true,
            "comments": commentsConnection ?? connection(total: comments.count, nodes: comments)
        ]
    }

    private static func request(_ id: String) -> [String: Any] {
        ["id": id, "requestedReviewer": ["__typename": "User", "id": "USER_\(id)", "login": "rw"]]
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
