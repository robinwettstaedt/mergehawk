import Foundation
import mergehawkcore

@main
struct Runner {
    static func main() async throws {
        try testFirstSyncBaselinesWithoutEvents()
        try testDetectsNewActivityAndAuthoredPRStateTransitions()
        try testDetectsNewCommentActivitiesWithActors()
        try testReviewThreadCommentsDoNotDuplicateCommentedReviewEvents()
        try testTopLevelCommentedReviewEmitsReviewCommentedEvent()
        try testOutcomeReviewSuppressesChildReviewThreadCommentEvents()
        try testOutcomeReviewKeepsUnrepresentedCommentFallback()
        try testCommentCountFallbackCoversMissingFetchedActivities()
        try testIgnoresSelfAuthoredPeopleActivity()
        try testDetectsCIFailuresForIncomingPRs()
        try testNotificationPreferencesDefaultToAuthoredOnly()
        try testPreferencesFilterEvents()
        try testNotificationPreferencesAllowEachRelationshipAndActivity()
        try testNotificationPreferencesTreatReviewEventsAsReviewActivity()
        try testNotificationPreferencesAllowOverlappingRelationshipOnce()
        try testSourcePreferencesResolveOwnerAndRepositoryOverrides()
        try await testSyncBaselinesFirstFetchAndReportsPRs()
        try await testSyncEmitsFilteredEventsAfterBaseline()
        try await testSyncFiltersIncomingEventsByMatrix()
        try await testSyncFiltersEventsBySourcePreferences()
        try await testEmptyPullRequestSourceReportsNoneAndNoPullRequests()
        try testNormalizesPullRequestSearchNodes()
        try testNormalizesActionableUnresolvedComments()
        try testNormalizesReviewOutcomeFromLatestOpinionatedReviews()
        try testNormalizesReviewRequestKinds()
        try testNormalizesViewerAssignment()
        try testBuildsThreePullRequestSearchQueries()
        try testInMemoryTokenStoreHandlesMissingStoreLoadAndClear()
        print("mergehawkcore tests passed")
    }

    private static func testFirstSyncBaselinesWithoutEvents() throws {
        let current = PullRequest.fixture(
            id: "PR_1",
            ciState: .failing,
            reviewDecision: .changesRequested,
            commentCount: 3,
            reviewCount: 1,
            isMine: true
        )

        try expect(PRActivityDetector.detect(previous: nil, current: current) == [])
    }

    private static func testDetectsNewActivityAndAuthoredPRStateTransitions() throws {
        let previous = PullRequest.fixture(
            id: "PR_1",
            ciState: .passing,
            reviewDecision: .reviewRequired,
            commentCount: 1,
            reviewCount: 0,
            isMine: true
        )
        let current = PullRequest.fixture(
            id: "PR_1",
            ciState: .failing,
            reviewDecision: .approved,
            commentCount: 2,
            commentActivityCount: 1,
            reviewCount: 1,
            recentReviews: [
                PullRequestReview(
                    id: "REVIEW_APPROVED",
                    state: .approved,
                    submittedAt: Date(timeIntervalSince1970: 200),
                    author: "teammate"
                )
            ],
            isMine: true
        )

        try expect(
            PRActivityDetector.detect(previous: previous, current: current).map(\.type)
                == [.reviewApproved, .ciFailed]
        )

        let previousReviews = PullRequest.fixture(
            id: "PR_2",
            commentCount: 1,
            reviewCount: 1,
            recentReviews: [
                PullRequestReview(
                    id: "REVIEW_OLD",
                    state: .approved,
                    submittedAt: Date(timeIntervalSince1970: 100),
                    author: "teammate"
                )
            ],
            isMine: true
        )
        let currentReviews = PullRequest.fixture(
            id: "PR_2",
            reviewDecision: .changesRequested,
            commentCount: 3,
            commentActivityCount: 1,
            reviewCount: 3,
            recentReviews: [
                PullRequestReview(
                    id: "REVIEW_OLD",
                    state: .approved,
                    submittedAt: Date(timeIntervalSince1970: 100),
                    author: "teammate"
                ),
                PullRequestReview(
                    id: "REVIEW_CHANGES",
                    state: .changesRequested,
                    submittedAt: Date(timeIntervalSince1970: 300),
                    author: "backend-mateo"
                )
            ],
            isMine: true
        )

        try expect(
            PRActivityDetector.detect(previous: previousReviews, current: currentReviews).map(\.type)
                == [.changesRequested]
        )
    }

    private static func testDetectsNewCommentActivitiesWithActors() throws {
        let previous = PullRequest.fixture(
            id: "PR_ACTIVITY",
            commentCount: 1,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "COMMENT_OLD",
                    author: "teammate",
                    createdAt: Date(timeIntervalSince1970: 100),
                    source: .pullRequest
                )
            ],
            isMine: true
        )
        let current = PullRequest.fixture(
            id: "PR_ACTIVITY",
            commentCount: 3,
            commentActivityCount: 3,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "COMMENT_OLD",
                    author: "teammate",
                    createdAt: Date(timeIntervalSince1970: 100),
                    source: .pullRequest
                ),
                PullRequestCommentActivity(
                    id: "COMMENT_NEW_1",
                    author: "frontend-sam",
                    createdAt: Date(timeIntervalSince1970: 200),
                    source: .pullRequest
                ),
                PullRequestCommentActivity(
                    id: "COMMENT_NEW_2",
                    author: "docs-lee",
                    createdAt: Date(timeIntervalSince1970: 300),
                    source: .reviewThread
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detect(previous: previous, current: current) == [
            PullRequestEvent(
                type: .newComment,
                prId: "PR_ACTIVITY",
                count: 1,
                actorLogin: "frontend-sam",
                activityId: "COMMENT_NEW_1",
                happenedAt: Date(timeIntervalSince1970: 200)
            ),
            PullRequestEvent(
                type: .reviewCommented,
                prId: "PR_ACTIVITY",
                count: 1,
                actorLogin: "docs-lee",
                activityId: "COMMENT_NEW_2",
                happenedAt: Date(timeIntervalSince1970: 300)
            )
        ])
    }

    private static func testReviewThreadCommentsDoNotDuplicateCommentedReviewEvents() throws {
        let previous = PullRequest.fixture(id: "PR_REVIEW_COMMENT", commentActivityCount: 0, isMine: true)
        let current = PullRequest.fixture(
            id: "PR_REVIEW_COMMENT",
            commentCount: 1,
            commentActivityCount: 1,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "INLINE_COMMENT",
                    author: "docs-lee",
                    createdAt: Date(timeIntervalSince1970: 200),
                    source: .reviewThread,
                    reviewId: "REVIEW_COMMENTED"
                )
            ],
            reviewCount: 1,
            recentReviews: [
                PullRequestReview(
                    id: "REVIEW_COMMENTED",
                    state: .commented,
                    submittedAt: Date(timeIntervalSince1970: 200),
                    author: "docs-lee"
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detect(previous: previous, current: current) == [
            PullRequestEvent(
                type: .reviewCommented,
                prId: "PR_REVIEW_COMMENT",
                count: 1,
                actorLogin: "docs-lee",
                activityId: "REVIEW_COMMENTED",
                happenedAt: Date(timeIntervalSince1970: 200)
            )
        ])
    }

    private static func testTopLevelCommentedReviewEmitsReviewCommentedEvent() throws {
        let previous = PullRequest.fixture(id: "PR_TOP_LEVEL_REVIEW_COMMENT", isMine: true)
        let current = PullRequest.fixture(
            id: "PR_TOP_LEVEL_REVIEW_COMMENT",
            reviewCount: 1,
            recentReviews: [
                PullRequestReview(
                    id: "REVIEW_COMMENTED",
                    state: .commented,
                    submittedAt: Date(timeIntervalSince1970: 200),
                    author: "docs-lee"
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detect(previous: previous, current: current) == [
            PullRequestEvent(
                type: .reviewCommented,
                prId: "PR_TOP_LEVEL_REVIEW_COMMENT",
                count: 1,
                actorLogin: "docs-lee",
                activityId: "REVIEW_COMMENTED",
                happenedAt: Date(timeIntervalSince1970: 200)
            )
        ])
    }

    private static func testOutcomeReviewSuppressesChildReviewThreadCommentEvents() throws {
        let previous = PullRequest.fixture(id: "PR_CHANGES_COMMENT", commentActivityCount: 0, isMine: true)
        let current = PullRequest.fixture(
            id: "PR_CHANGES_COMMENT",
            commentCount: 1,
            commentActivityCount: 1,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "INLINE_COMMENT",
                    author: "backend-mateo",
                    createdAt: Date(timeIntervalSince1970: 200),
                    source: .reviewThread,
                    reviewId: "REVIEW_CHANGES"
                )
            ],
            reviewCount: 1,
            recentReviews: [
                PullRequestReview(
                    id: "REVIEW_CHANGES",
                    state: .changesRequested,
                    submittedAt: Date(timeIntervalSince1970: 200),
                    author: "backend-mateo"
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detect(previous: previous, current: current) == [
            PullRequestEvent(
                type: .changesRequested,
                prId: "PR_CHANGES_COMMENT",
                count: 1,
                actorLogin: "backend-mateo",
                activityId: "REVIEW_CHANGES",
                happenedAt: Date(timeIntervalSince1970: 200)
            )
        ])
    }

    private static func testOutcomeReviewKeepsUnrepresentedCommentFallback() throws {
        let previous = PullRequest.fixture(id: "PR_CHANGES_WITH_MISSING_COMMENT", commentActivityCount: 0, isMine: true)
        let current = PullRequest.fixture(
            id: "PR_CHANGES_WITH_MISSING_COMMENT",
            commentCount: 2,
            commentActivityCount: 2,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "INLINE_COMMENT",
                    author: "backend-mateo",
                    createdAt: Date(timeIntervalSince1970: 200),
                    source: .reviewThread,
                    reviewId: "REVIEW_CHANGES"
                )
            ],
            reviewCount: 1,
            recentReviews: [
                PullRequestReview(
                    id: "REVIEW_CHANGES",
                    state: .changesRequested,
                    submittedAt: Date(timeIntervalSince1970: 200),
                    author: "backend-mateo"
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detect(previous: previous, current: current) == [
            PullRequestEvent(
                type: .changesRequested,
                prId: "PR_CHANGES_WITH_MISSING_COMMENT",
                count: 1,
                actorLogin: "backend-mateo",
                activityId: "REVIEW_CHANGES",
                happenedAt: Date(timeIntervalSince1970: 200)
            ),
            PullRequestEvent(type: .newComment, prId: "PR_CHANGES_WITH_MISSING_COMMENT", count: 1)
        ])
    }

    private static func testCommentCountFallbackCoversMissingFetchedActivities() throws {
        let previous = PullRequest.fixture(
            id: "PR_MISSING_COMMENTS",
            commentActivityCount: 10,
            isMine: true
        )
        let current = PullRequest.fixture(
            id: "PR_MISSING_COMMENTS",
            commentActivityCount: 13,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "FETCHED_COMMENT",
                    author: "teammate",
                    createdAt: Date(timeIntervalSince1970: 200),
                    source: .pullRequest
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detect(previous: previous, current: current) == [
            PullRequestEvent(
                type: .newComment,
                prId: "PR_MISSING_COMMENTS",
                count: 1,
                actorLogin: "teammate",
                activityId: "FETCHED_COMMENT",
                happenedAt: Date(timeIntervalSince1970: 200)
            ),
            PullRequestEvent(type: .newComment, prId: "PR_MISSING_COMMENTS", count: 2)
        ])
    }

    private static func testIgnoresSelfAuthoredPeopleActivity() throws {
        let previous = PullRequest.fixture(id: "PR_SELF", isMine: true)
        let current = PullRequest.fixture(
            id: "PR_SELF",
            commentCount: 1,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "COMMENT_SELF",
                    author: "rw",
                    viewerDidAuthor: true,
                    createdAt: Date(timeIntervalSince1970: 200),
                    source: .pullRequest
                )
            ],
            reviewCount: 1,
            recentReviews: [
                PullRequestReview(
                    id: "REVIEW_SELF",
                    state: .approved,
                    submittedAt: Date(timeIntervalSince1970: 300),
                    author: "rw",
                    viewerDidAuthor: true
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detect(previous: previous, current: current).isEmpty)
    }

    private static func testDetectsCIFailuresForIncomingPRs() throws {
        let previous = PullRequest.fixture(id: "PR_INCOMING_CI", ciState: .passing, isMine: false)
        let current = PullRequest.fixture(id: "PR_INCOMING_CI", ciState: .failing, isMine: false)

        try expect(PRActivityDetector.detect(previous: previous, current: current).map(\.type) == [.ciFailed])
    }

    private static func testNotificationPreferencesDefaultToAuthoredOnly() throws {
        let authored = PullRequest.fixture(id: "PR_AUTHORED", isMine: true)
        let assigned = PullRequest.fixture(id: "PR_ASSIGNED", isAssignedToViewer: true, isMine: false)
        let event = PullRequestEvent(type: .newComment, prId: "PR_AUTHORED")

        try expect(NotificationPreferences.defaults.allows(event: event, for: authored))
        try expect(!NotificationPreferences.defaults.allows(event: event, for: assigned))
    }

    private static func testPreferencesFilterEvents() throws {
        let preferences = NotificationPreferences(
            authored: PullRequestNotificationActivityPreferences(
                comments: true,
                reviewActivity: false,
                ciFailures: true
            ),
            assigned: .disabled,
            directReviewRequests: .disabled,
            teamReviewRequests: .disabled
        )
        let pullRequest = PullRequest.fixture(id: "1", isMine: true)
        let events = [
            PullRequestEvent(type: .newComment, prId: "1", count: 1),
            PullRequestEvent(type: .reviewApproved, prId: "1"),
            PullRequestEvent(type: .reviewCommented, prId: "1"),
            PullRequestEvent(type: .ciFailed, prId: "1"),
            PullRequestEvent(type: .changesRequested, prId: "1")
        ]

        try expect(
            PRActivityDetector
                .filter(events, preferences: preferences, pullRequest: pullRequest)
                .map(\.type) == [.newComment, .ciFailed]
        )
    }

    private static func testNotificationPreferencesAllowEachRelationshipAndActivity() throws {
        for relationship in PullRequestNotificationRelationship.allCases {
            for activity in PullRequestNotificationActivity.allCases {
                var preferences = NotificationPreferences(
                    authored: .disabled,
                    assigned: .disabled,
                    directReviewRequests: .disabled,
                    teamReviewRequests: .disabled
                )
                preferences.set(activityPreferences(enabling: activity), for: relationship)
                let pullRequest = pullRequest(matching: relationship)
                let allowedEvent = PullRequestEvent(type: eventType(for: activity), prId: pullRequest.id)

                try expect(preferences.allows(event: allowedEvent, for: pullRequest))

                for disabledActivity in PullRequestNotificationActivity.allCases where disabledActivity != activity {
                    let disabledEvent = PullRequestEvent(type: eventType(for: disabledActivity), prId: pullRequest.id)
                    try expect(!preferences.allows(event: disabledEvent, for: pullRequest))
                }
            }
        }
    }

    private static func testNotificationPreferencesTreatReviewEventsAsReviewActivity() throws {
        let pullRequest = PullRequest.fixture(id: "PR_REVIEWS", isMine: true)
        let preferences = NotificationPreferences(
            authored: PullRequestNotificationActivityPreferences(
                comments: false,
                reviewActivity: true,
                ciFailures: false
            ),
            assigned: .disabled,
            directReviewRequests: .disabled,
            teamReviewRequests: .disabled
        )

        for eventType in [
            PullRequestEventType.reviewApproved,
            .reviewCommented,
            .changesRequested,
            .newReview
        ] {
            try expect(
                preferences.allows(
                    event: PullRequestEvent(type: eventType, prId: pullRequest.id),
                    for: pullRequest
                )
            )
        }
        try expect(!preferences.allows(event: PullRequestEvent(type: .newComment, prId: pullRequest.id), for: pullRequest))
        try expect(!preferences.allows(event: PullRequestEvent(type: .ciFailed, prId: pullRequest.id), for: pullRequest))
    }

    private static func testNotificationPreferencesAllowOverlappingRelationshipOnce() throws {
        let preferences = NotificationPreferences(
            authored: .disabled,
            assigned: PullRequestNotificationActivityPreferences(
                comments: true,
                reviewActivity: false,
                ciFailures: false
            ),
            directReviewRequests: PullRequestNotificationActivityPreferences(
                comments: true,
                reviewActivity: false,
                ciFailures: false
            ),
            teamReviewRequests: .disabled
        )
        let pullRequest = PullRequest.fixture(
            id: "PR_OVERLAP",
            reviewRequestKind: .direct,
            isAssignedToViewer: true,
            isMine: false
        )
        let events = [PullRequestEvent(type: .newComment, prId: pullRequest.id)]

        try expect(
            PRActivityDetector.filter(events, preferences: preferences, pullRequest: pullRequest) == events
        )
    }

    private static func testSourcePreferencesResolveOwnerAndRepositoryOverrides() throws {
        let preferences = SourcePreferences(
            owners: [
                "work": OwnerSourcePreferences(
                    notifications: false,
                    myPullRequests: true,
                    reviewRequests: false
                )
            ],
            repositories: [
                "work/critical": RepositorySourcePreferences(
                    notifications: .enabled,
                    myPullRequests: .disabled,
                    reviewRequests: .inherit
                )
            ]
        )

        try expect(preferences.allowsNotifications(for: "work/app") == false)
        try expect(preferences.allowsMyPullRequests(for: "work/app") == true)
        try expect(preferences.allowsReviewRequests(for: "work/app") == false)
        try expect(preferences.allowsNotifications(for: "work/critical") == true)
        try expect(preferences.allowsMyPullRequests(for: "work/critical") == false)
        try expect(preferences.allowsReviewRequests(for: "work/critical") == false)
        try expect(preferences.allowsNotifications(for: "personal/tool") == true)
        try expect(preferences.allowsMyPullRequests(for: "malformed") == true)
    }

    private static func testSyncBaselinesFirstFetchAndReportsPRs() async throws {
        let source = SequencePullRequestSource(snapshots: [[.fixture(id: "1", isMine: true)]])
        let engine = SyncEngine(source: source, loginProvider: { "rw" })

        let result = try await engine.sync()

        try expect(result.pullRequests.count == 1)
        try expect(result.events == [])
        try expect(result.source == .mock)
        try expect(result.account?.login == "rw")
    }

    private static func testSyncEmitsFilteredEventsAfterBaseline() async throws {
        let source = SequencePullRequestSource(snapshots: [
            [.fixture(id: "1", ciState: .passing, commentCount: 0, isMine: true)],
            [.fixture(
                id: "1",
                ciState: .failing,
                commentCount: 1,
                recentCommentActivities: [
                    PullRequestCommentActivity(
                        id: "COMMENT_NEW",
                        author: "teammate",
                        createdAt: Date(timeIntervalSince1970: 200),
                        source: .pullRequest
                    )
                ],
                isMine: true
            )]
        ])
        let engine = SyncEngine(source: source, loginProvider: { "rw" })

        _ = try await engine.sync()
        let result = try await engine.sync()

        try expect(result.events.map(\.type) == [.newComment, .ciFailed])
    }

    private static func testSyncFiltersIncomingEventsByMatrix() async throws {
        let source = SequencePullRequestSource(snapshots: [
            [
                .fixture(
                    id: "assigned",
                    ciState: .passing,
                    commentCount: 0,
                    isAssignedToViewer: true,
                    isMine: false
                )
            ],
            [
                .fixture(
                    id: "assigned",
                    ciState: .failing,
                    commentCount: 1,
                    recentCommentActivities: [
                        PullRequestCommentActivity(
                            id: "COMMENT_ASSIGNED",
                            author: "teammate",
                            createdAt: Date(timeIntervalSince1970: 200),
                            source: .pullRequest
                        )
                    ],
                    isAssignedToViewer: true,
                    isMine: false
                )
            ]
        ])
        let preferences = NotificationPreferences(
            authored: .disabled,
            assigned: PullRequestNotificationActivityPreferences(
                comments: true,
                reviewActivity: false,
                ciFailures: false
            ),
            directReviewRequests: .disabled,
            teamReviewRequests: .disabled
        )
        let engine = SyncEngine(
            source: source,
            preferences: preferences,
            loginProvider: { "rw" }
        )

        _ = try await engine.sync()
        let result = try await engine.sync()

        try expect(result.events.map(\.type) == [.newComment])
    }

    private static func testSyncFiltersEventsBySourcePreferences() async throws {
        let source = SequencePullRequestSource(snapshots: [
            [.fixture(id: "1", repo: "work/app", commentCount: 0, isMine: true)],
            [.fixture(
                id: "1",
                repo: "work/app",
                commentCount: 1,
                recentCommentActivities: [
                    PullRequestCommentActivity(
                        id: "COMMENT_NEW",
                        author: "teammate",
                        createdAt: Date(timeIntervalSince1970: 200),
                        source: .pullRequest
                    )
                ],
                isMine: true
            )]
        ])
        let sourcePreferences = SourcePreferences(
            owners: [
                "work": OwnerSourcePreferences(
                    notifications: false,
                    myPullRequests: true,
                    reviewRequests: true
                )
            ],
            repositories: [:]
        )
        let engine = SyncEngine(
            source: source,
            loginProvider: { "rw" },
            sourcePreferencesProvider: { sourcePreferences }
        )

        _ = try await engine.sync()
        let result = try await engine.sync()

        try expect(result.events.isEmpty)
    }

    private static func testEmptyPullRequestSourceReportsNoneAndNoPullRequests() async throws {
        let source = EmptyPullRequestSource()
        let engine = SyncEngine(
            source: source,
            loginProvider: { "rw" },
            accountProvider: { nil },
            authStatusProvider: { .signedOut }
        )

        let result = try await engine.sync()

        try expect(result.source == .none)
        try expect(result.authStatus == .signedOut)
        try expect(result.account?.login == "rw")
        try expect(result.pullRequests.isEmpty)
        try expect(result.events.isEmpty)
    }

    private static func testNormalizesPullRequestSearchNodes() throws {
        let node = GitHubPullRequestNode(
            id: "PR_1",
            title: "Ship dashboard",
            number: 12,
            url: "https://github.com/acme/mergehawk/pull/12",
            createdAt: "2026-05-01T12:00:00Z",
            updatedAt: "2026-05-02T12:00:00Z",
            headRefName: "ship-dashboard",
            isDraft: true,
            mergeable: "MERGEABLE",
            reviewDecision: "REVIEW_REQUIRED",
            comments: .init(totalCount: 2, nodes: [
                .init(
                    id: "COMMENT_1",
                    createdAt: "2026-05-02T10:00:00Z",
                    viewerDidAuthor: false,
                    author: .init(login: "reviewer")
                )
            ]),
            reviews: .init(totalCount: 1, nodes: [
                .init(
                    id: "REVIEW_1",
                    state: "APPROVED",
                    submittedAt: "2026-05-02T11:00:00Z",
                    author: .init(login: "reviewer")
                )
            ]),
            reviewThreads: .init(nodes: [
                .fixture(idPrefix: "RESOLVED_COMMENT", isResolved: true, viewerCanResolve: true, viewerDidAuthorComments: [false]),
                .fixture(
                    idPrefix: "ACTIONABLE_COMMENT",
                    isResolved: false,
                    viewerCanResolve: true,
                    viewerDidAuthorComments: [true, false]
                )
            ]),
            repository: .init(nameWithOwner: "acme/mergehawk"),
            commits: .init(nodes: [.init(commit: .init(statusCheckRollup: .init(state: "FAILURE")))]),
            author: .init(login: "rw")
        )

        try expect(GitHubPullRequestNormalizer.normalize(node, login: "rw") == PullRequest(
            id: "PR_1",
            title: "Ship dashboard",
            number: 12,
            url: URL(string: "https://github.com/acme/mergehawk/pull/12")!,
            repo: "acme/mergehawk",
            ciState: .failing,
            reviewDecision: .reviewRequired,
            commentCount: 1,
            commentActivityCount: 5,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "COMMENT_1",
                    author: "reviewer",
                    createdAt: Date(timeIntervalSince1970: 1_777_716_000),
                    source: .pullRequest
                ),
                PullRequestCommentActivity(
                    id: "RESOLVED_COMMENT_1",
                    author: "teammate",
                    createdAt: Date(timeIntervalSince1970: 1_777_723_200),
                    source: .reviewThread,
                    reviewId: "REVIEW_1"
                ),
                PullRequestCommentActivity(
                    id: "ACTIONABLE_COMMENT_1",
                    author: "rw",
                    viewerDidAuthor: true,
                    createdAt: Date(timeIntervalSince1970: 1_777_723_200),
                    source: .reviewThread,
                    reviewId: "REVIEW_1"
                ),
                PullRequestCommentActivity(
                    id: "ACTIONABLE_COMMENT_2",
                    author: "teammate",
                    createdAt: Date(timeIntervalSince1970: 1_777_723_200),
                    source: .reviewThread,
                    reviewId: "REVIEW_1"
                )
            ],
            reviewCount: 1,
            recentReviews: [
                PullRequestReview(
                    id: "REVIEW_1",
                    state: .approved,
                    submittedAt: Date(timeIntervalSince1970: 1_777_719_600),
                    author: "reviewer"
                )
            ],
            isMine: true,
            author: "rw",
            headRefName: "ship-dashboard",
            mergeable: .mergeable,
            draft: true,
            createdAt: Date(timeIntervalSince1970: 1_777_636_800),
            updatedAt: Date(timeIntervalSince1970: 1_777_723_200)
        ))
    }

    private static func testNormalizesActionableUnresolvedComments() throws {
        let node = GitHubPullRequestNode.fixture(
            comments: .init(totalCount: 8),
            reviewThreads: .init(nodes: [
                .fixture(isResolved: false, viewerCanResolve: true, viewerDidAuthorComments: [true]),
                .fixture(isResolved: false, viewerCanResolve: false, viewerDidAuthorComments: [false]),
                .fixture(isResolved: false, viewerCanResolve: true, viewerDidAuthorComments: [true, false]),
                .fixture(isResolved: true, viewerCanResolve: true, viewerDidAuthorComments: [false])
            ])
        )

        try expect(GitHubPullRequestNormalizer.normalize(node, login: "rw").commentCount == 1)
        try expect(GitHubPullRequestNormalizer.normalize(node, login: "rw").commentActivityCount == 13)
    }

    private static func testNormalizesReviewOutcomeFromLatestOpinionatedReviews() throws {
        let approvedWithUnresolvedComments = GitHubPullRequestNode.fixture(
            reviewDecision: "REVIEW_REQUIRED",
            latestOpinionatedReviews: .init(totalCount: 1, nodes: [
                .init(id: "APPROVAL", state: "APPROVED", submittedAt: "2026-05-02T11:00:00Z")
            ]),
            reviewThreads: .init(nodes: [
                .fixture(isResolved: false, viewerCanResolve: true, viewerDidAuthorComments: [false])
            ])
        )

        let changesRequestedWins = GitHubPullRequestNode.fixture(
            reviewDecision: "APPROVED",
            latestOpinionatedReviews: .init(totalCount: 2, nodes: [
                .init(id: "APPROVAL", state: "APPROVED", submittedAt: "2026-05-02T11:00:00Z"),
                .init(id: "CHANGES", state: "CHANGES_REQUESTED", submittedAt: "2026-05-02T12:00:00Z")
            ])
        )

        let approved = GitHubPullRequestNormalizer.normalize(approvedWithUnresolvedComments, login: "rw")
        try expect(approved.reviewDecision == .approved)
        try expect(approved.commentCount == 1)
        try expect(GitHubPullRequestNormalizer.normalize(changesRequestedWins, login: "rw").reviewDecision == .changesRequested)
    }

    private static func testBuildsThreePullRequestSearchQueries() throws {
        try expect(GitHubClient.pullRequestSearchQueries(login: "rw") == [
            "is:open is:pr author:rw",
            "is:open is:pr assignee:rw",
            "is:open is:pr review-requested:rw"
        ])
    }

    private static func testNormalizesReviewRequestKinds() throws {
        let directNode = GitHubPullRequestNode.reviewRequestFixture(reviewers: [
            .init(typeName: "User", login: "rw")
        ])
        let teamNode = GitHubPullRequestNode.reviewRequestFixture(reviewers: [
            .init(typeName: "Team", slug: "developers", organization: .init(login: "acme"))
        ])
        let directAndTeamNode = GitHubPullRequestNode.reviewRequestFixture(reviewers: [
            .init(typeName: "User", login: "rw"),
            .init(typeName: "Team", slug: "developers", organization: .init(login: "acme"))
        ])
        let noneNode = GitHubPullRequestNode.reviewRequestFixture(reviewers: [])

        try expect(
            GitHubPullRequestNormalizer.normalize(
                directNode,
                login: "rw",
                isReviewRequestResult: true
            ).reviewRequestKind == .direct
        )
        try expect(
            GitHubPullRequestNormalizer.normalize(
                teamNode,
                login: "rw",
                isReviewRequestResult: true
            ).reviewRequestKind == .team
        )
        try expect(
            GitHubPullRequestNormalizer.normalize(
                directAndTeamNode,
                login: "rw",
                isReviewRequestResult: true
            ).reviewRequestKind == .directAndTeam
        )
        try expect(
            GitHubPullRequestNormalizer.normalize(
                noneNode,
                login: "rw"
            ).reviewRequestKind == .none
        )
    }

    private static func testNormalizesViewerAssignment() throws {
        let assignedNode = GitHubPullRequestNode.fixture(
            assignees: .init(nodes: [.init(login: "rw"), .init(login: "teammate")])
        )
        let unassignedNode = GitHubPullRequestNode.fixture(
            assignees: .init(nodes: [.init(login: "teammate")])
        )

        try expect(GitHubPullRequestNormalizer.normalize(assignedNode, login: "rw").isAssignedToViewer)
        try expect(!GitHubPullRequestNormalizer.normalize(unassignedNode, login: "rw").isAssignedToViewer)
    }

    private static func activityPreferences(
        enabling activity: PullRequestNotificationActivity
    ) -> PullRequestNotificationActivityPreferences {
        PullRequestNotificationActivityPreferences(
            comments: activity == .comments,
            reviewActivity: activity == .reviewActivity,
            ciFailures: activity == .ciFailures
        )
    }

    private static func eventType(for activity: PullRequestNotificationActivity) -> PullRequestEventType {
        switch activity {
        case .comments:
            .newComment
        case .reviewActivity:
            .reviewApproved
        case .ciFailures:
            .ciFailed
        }
    }

    private static func pullRequest(
        matching relationship: PullRequestNotificationRelationship
    ) -> PullRequest {
        switch relationship {
        case .authored:
            PullRequest.fixture(id: "PR_AUTHORED", isMine: true)
        case .assigned:
            PullRequest.fixture(id: "PR_ASSIGNED", isAssignedToViewer: true, isMine: false)
        case .directReviewRequest:
            PullRequest.fixture(id: "PR_DIRECT", reviewRequestKind: .direct, isMine: false)
        case .teamReviewRequest:
            PullRequest.fixture(id: "PR_TEAM", reviewRequestKind: .team, isMine: false)
        }
    }

    private static func testInMemoryTokenStoreHandlesMissingStoreLoadAndClear() throws {
        let store = InMemoryTokenStore()

        let missing = try store.load()
        try expect(missing == nil)
        try store.store("github_pat_test")
        let stored = try store.load()
        try expect(stored == "github_pat_test")
        try store.clear()
        let cleared = try store.load()
        try expect(cleared == nil)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) throws {
        if !condition() {
            throw TestFailure(file: "\(file)", line: line)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let file: String
    let line: UInt

    var description: String {
        "Test failed at \(file):\(line)"
    }
}

private extension GitHubPullRequestNode {
    static func fixture(
        reviewDecision: String? = "REVIEW_REQUIRED",
        comments: CommentConnection = .init(totalCount: 0),
        reviews: ReviewConnection = .init(totalCount: 0),
        latestOpinionatedReviews: ReviewConnection = .init(totalCount: 0),
        reviewThreads: ReviewThreadConnection = .init(nodes: []),
        assignees: AssigneeConnection = .init(nodes: [])
    ) -> GitHubPullRequestNode {
        GitHubPullRequestNode(
            id: "PR_FIXTURE",
            title: "Fixture PR",
            number: 12,
            url: "https://github.com/acme/mergehawk/pull/12",
            createdAt: "2026-05-01T12:00:00Z",
            updatedAt: "2026-05-02T12:00:00Z",
            isDraft: false,
            mergeable: "MERGEABLE",
            reviewDecision: reviewDecision,
            comments: comments,
            reviews: reviews,
            latestOpinionatedReviews: latestOpinionatedReviews,
            reviewThreads: reviewThreads,
            assignees: assignees,
            repository: .init(nameWithOwner: "acme/mergehawk"),
            commits: .init(nodes: []),
            author: .init(login: "teammate")
        )
    }

    static func reviewRequestFixture(reviewers: [RequestedReviewer]) -> GitHubPullRequestNode {
        GitHubPullRequestNode(
            id: "PR_REVIEW",
            title: "Review requested",
            number: 21,
            url: "https://github.com/acme/mergehawk/pull/21",
            createdAt: "2026-05-01T12:00:00Z",
            updatedAt: "2026-05-02T12:00:00Z",
            isDraft: false,
            mergeable: "MERGEABLE",
            reviewDecision: "REVIEW_REQUIRED",
            comments: .init(totalCount: 0),
            reviews: .init(totalCount: 0),
            reviewThreads: .init(nodes: []),
            reviewRequests: .init(nodes: reviewers.map { .init(requestedReviewer: $0) }),
            repository: .init(nameWithOwner: "acme/mergehawk"),
            commits: .init(nodes: []),
            author: .init(login: "teammate")
        )
    }
}

private extension GitHubPullRequestNode.ReviewThreadConnection.Node {
    static func fixture(
        idPrefix: String = "REVIEW_COMMENT",
        isResolved: Bool,
        viewerCanResolve: Bool,
        viewerDidAuthorComments: [Bool],
        reviewId: String? = "REVIEW_1"
    ) -> Self {
        .init(
            isResolved: isResolved,
            viewerCanResolve: viewerCanResolve,
            comments: .init(nodes: viewerDidAuthorComments.enumerated().map { index, viewerDidAuthor in
                .init(
                    id: "\(idPrefix)_\(index + 1)",
                    createdAt: "2026-05-02T12:00:00Z",
                    viewerDidAuthor: viewerDidAuthor,
                    author: .init(login: viewerDidAuthor ? "rw" : "teammate"),
                    pullRequestReview: reviewId.map { .init(id: $0) }
                )
            })
        )
    }
}

private final class SequencePullRequestSource: PullRequestSource {
    let sourceKind: DashboardSource = .mock
    private var snapshots: [[PullRequest]]

    init(snapshots: [[PullRequest]]) {
        self.snapshots = snapshots
    }

    func fetchPullRequests(login: String) async throws -> [PullRequest] {
        snapshots.isEmpty ? [] : snapshots.removeFirst()
    }
}

private extension PullRequest {
    static func fixture(
        id: String = "PR_1",
        title: String = "Build tray app",
        number: Int = 1,
        url: URL = URL(string: "https://github.com/acme/mergehawk/pull/1")!,
        repo: String = "acme/mergehawk",
        ciState: CIState = .passing,
        reviewDecision: ReviewDecision = .reviewRequired,
        commentCount: Int = 0,
        commentActivityCount: Int? = nil,
        recentCommentActivities: [PullRequestCommentActivity] = [],
        reviewCount: Int = 0,
        recentReviews: [PullRequestReview] = [],
        reviewRequestKind: ReviewRequestKind = .none,
        isAssignedToViewer: Bool = false,
        isMine: Bool = false,
        author: String = "rw",
        mergeable: MergeableState = .unknown,
        draft: Bool = false
    ) -> PullRequest {
        PullRequest(
            id: id,
            title: title,
            number: number,
            url: url,
            repo: repo,
            ciState: ciState,
            reviewDecision: reviewDecision,
            commentCount: commentCount,
            commentActivityCount: commentActivityCount,
            recentCommentActivities: recentCommentActivities,
            reviewCount: reviewCount,
            recentReviews: recentReviews,
            reviewRequestKind: reviewRequestKind,
            isAssignedToViewer: isAssignedToViewer,
            isMine: isMine,
            author: author,
            mergeable: mergeable,
            draft: draft
        )
    }
}
