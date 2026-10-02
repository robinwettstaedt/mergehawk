import Foundation
import mergehawkcore

@main
struct Runner {
    static func main() async throws {
        try testFirstSyncBaselinesWithoutEvents()
        try testDetectsNewActivityAndAuthoredPRStateTransitions()
        try testDetectsNewCommentActivitiesWithActors()
        try testCommentOnlyReviewEmitsSummaryAndInlineCommentsIndividually()
        try testTopLevelCommentedReviewEmitsReviewCommentedEvent()
        try testDecisionReviewKeepsItsInlineCommentEvents()
        try testOutcomeReviewKeepsUnrelatedCommentActivity()
        try testIgnoresSelfAuthoredPeopleActivity()
        try testDetectsCIFailuresForIncomingPRs()
        try testDetectsIncomingRelationshipAddedTransitions()
        try testDetectsRelationshipsOnPRsFirstSeenAfterBaseline()
        try testNewlySeenPRKeepsCIBaselined()
        try testRelationshipAddedFilteringUsesChangedRelationships()
        try testNotificationPreferencesDefaultCommentModes()
        try testPreferencesFilterEvents()
        try testNotificationPreferencesAllowEachRelationshipAndActivity()
        try testNotificationPreferencesSeparateDecisionsFromComments()
        try testNotificationPreferencesAllowOverlappingRelationshipOnce()
        try testSourcePreferencesResolveOwnerAndRepositoryOverrides()
        try await testPreparedRefreshUsesDurableProcessedActivity()
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

        try expect(PRActivityDetector.detectTransitions(previous: nil, current: current) == [])
        try expect(PRActivityDetector.detectProcessedPeopleActivity(previous: nil, current: current) == [])
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
                    url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                    state: .approved,
                    submittedAt: Date(timeIntervalSince1970: 200),
                    author: "teammate"
                )
            ],
            isMine: true
        )

        let events = PRActivityDetector.detectTransitions(previous: previous, current: current)
            + PRActivityDetector.detectProcessedPeopleActivity(
                previous: processedActivity(for: previous),
                current: current
            )
        try expect(events.map(\.type) == [.ciFailed, .reviewApproved])

        let previousReviews = PullRequest.fixture(
            id: "PR_2",
            commentCount: 1,
            reviewCount: 1,
            recentReviews: [
                PullRequestReview(
                    id: "REVIEW_OLD",
                    url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
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
                    url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                    state: .approved,
                    submittedAt: Date(timeIntervalSince1970: 100),
                    author: "teammate"
                ),
                PullRequestReview(
                    id: "REVIEW_CHANGES",
                    url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                    state: .changesRequested,
                    submittedAt: Date(timeIntervalSince1970: 300),
                    author: "backend-mateo"
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detectProcessedPeopleActivity(
            previous: processedActivity(for: previousReviews),
            current: currentReviews
        ).map(\.type) == [.changesRequested])
    }

    private static func testDetectsNewCommentActivitiesWithActors() throws {
        let previous = PullRequest.fixture(
            id: "PR_ACTIVITY",
            commentCount: 1,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "COMMENT_OLD",
                    url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
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
                    url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                    author: "teammate",
                    createdAt: Date(timeIntervalSince1970: 100),
                    source: .pullRequest
                ),
                PullRequestCommentActivity(
                    id: "COMMENT_NEW_1",
                    url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                    author: "frontend-sam",
                    createdAt: Date(timeIntervalSince1970: 200),
                    source: .pullRequest
                ),
                PullRequestCommentActivity(
                    id: "COMMENT_NEW_2",
                    url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                    author: "docs-lee",
                    createdAt: Date(timeIntervalSince1970: 300),
                    source: .reviewThread
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detectProcessedPeopleActivity(
            previous: processedActivity(for: previous),
            current: current
        ) == [
            PullRequestEvent(
                type: .newComment,
                prId: "PR_ACTIVITY",
                count: 1,
                actorLogin: "frontend-sam",
                activityId: "COMMENT_NEW_1",
                destinationURL: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                happenedAt: Date(timeIntervalSince1970: 200),
                commentReason: .general
            ),
            PullRequestEvent(
                type: .reviewCommented,
                prId: "PR_ACTIVITY",
                count: 1,
                actorLogin: "docs-lee",
                activityId: "COMMENT_NEW_2",
                destinationURL: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                happenedAt: Date(timeIntervalSince1970: 300),
                commentReason: .general
            )
        ])
    }

    private static func testCommentOnlyReviewEmitsSummaryAndInlineCommentsIndividually() throws {
        let previous = PullRequest.fixture(id: "PR_REVIEW_COMMENT", commentActivityCount: 0, isMine: true)
        let current = PullRequest.fixture(
            id: "PR_REVIEW_COMMENT",
            commentCount: 1,
            commentActivityCount: 1,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "INLINE_COMMENT",
                    url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
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
                    url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                    state: .commented,
                    submittedAt: Date(timeIntervalSince1970: 200),
                    author: "docs-lee",
                    hasSummaryText: true
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detectProcessedPeopleActivity(
            previous: processedActivity(for: previous),
            current: current
        ) == [
            PullRequestEvent(
                type: .reviewCommented,
                prId: "PR_REVIEW_COMMENT",
                count: 1,
                actorLogin: "docs-lee",
                activityId: "REVIEW_COMMENTED",
                destinationURL: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                happenedAt: Date(timeIntervalSince1970: 200),
                commentReason: .general
            ),
            PullRequestEvent(
                type: .reviewCommented,
                prId: "PR_REVIEW_COMMENT",
                count: 1,
                actorLogin: "docs-lee",
                activityId: "INLINE_COMMENT",
                destinationURL: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                happenedAt: Date(timeIntervalSince1970: 200),
                commentReason: .general
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
                    url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                    state: .commented,
                    submittedAt: Date(timeIntervalSince1970: 200),
                    author: "docs-lee",
                    hasSummaryText: true
                ),
                PullRequestReview(
                    id: "REVIEW_EMPTY",
                    url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-empty")!,
                    state: .commented,
                    submittedAt: Date(timeIntervalSince1970: 210),
                    author: "docs-lee"
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detectProcessedPeopleActivity(
            previous: processedActivity(for: previous),
            current: current
        ) == [
            PullRequestEvent(
                type: .reviewCommented,
                prId: "PR_TOP_LEVEL_REVIEW_COMMENT",
                count: 1,
                actorLogin: "docs-lee",
                activityId: "REVIEW_COMMENTED",
                destinationURL: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                happenedAt: Date(timeIntervalSince1970: 200),
                commentReason: .general
            )
        ])
    }

    private static func testDecisionReviewKeepsItsInlineCommentEvents() throws {
        let previous = PullRequest.fixture(id: "PR_CHANGES_COMMENT", commentActivityCount: 0, isMine: true)
        let current = PullRequest.fixture(
            id: "PR_CHANGES_COMMENT",
            commentCount: 1,
            commentActivityCount: 1,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "INLINE_COMMENT",
                    url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
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
                    url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                    state: .changesRequested,
                    submittedAt: Date(timeIntervalSince1970: 200),
                    author: "backend-mateo"
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detectProcessedPeopleActivity(
            previous: processedActivity(for: previous),
            current: current
        ) == [
            PullRequestEvent(
                type: .changesRequested,
                prId: "PR_CHANGES_COMMENT",
                count: 1,
                actorLogin: "backend-mateo",
                activityId: "REVIEW_CHANGES",
                destinationURL: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                happenedAt: Date(timeIntervalSince1970: 200)
            ),
            PullRequestEvent(
                type: .reviewCommented,
                prId: "PR_CHANGES_COMMENT",
                count: 1,
                actorLogin: "backend-mateo",
                activityId: "INLINE_COMMENT",
                destinationURL: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                happenedAt: Date(timeIntervalSince1970: 200),
                commentReason: .general
            )
        ])
    }

    private static func testOutcomeReviewKeepsUnrelatedCommentActivity() throws {
        let previous = PullRequest.fixture(id: "PR_CHANGES_WITH_COMMENT", isMine: true)
        let current = PullRequest.fixture(
            id: "PR_CHANGES_WITH_COMMENT",
            commentCount: 2,
            commentActivityCount: 2,
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "INLINE_COMMENT",
                    url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                    author: "backend-mateo",
                    createdAt: Date(timeIntervalSince1970: 200),
                    source: .reviewThread,
                    reviewId: "REVIEW_CHANGES"
                ),
                PullRequestCommentActivity(
                    id: "UNRELATED_COMMENT",
                    url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                    author: "frontend-sam",
                    createdAt: Date(timeIntervalSince1970: 300),
                    source: .pullRequest
                )
            ],
            reviewCount: 1,
            recentReviews: [
                PullRequestReview(
                    id: "REVIEW_CHANGES",
                    url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                    state: .changesRequested,
                    submittedAt: Date(timeIntervalSince1970: 200),
                    author: "backend-mateo"
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detectProcessedPeopleActivity(
            previous: processedActivity(for: previous),
            current: current
        ) == [
            PullRequestEvent(
                type: .changesRequested,
                prId: "PR_CHANGES_WITH_COMMENT",
                count: 1,
                actorLogin: "backend-mateo",
                activityId: "REVIEW_CHANGES",
                destinationURL: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                happenedAt: Date(timeIntervalSince1970: 200)
            ),
            PullRequestEvent(
                type: .reviewCommented,
                prId: "PR_CHANGES_WITH_COMMENT",
                count: 1,
                actorLogin: "backend-mateo",
                activityId: "INLINE_COMMENT",
                destinationURL: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                happenedAt: Date(timeIntervalSince1970: 200),
                commentReason: .general
            ),
            PullRequestEvent(
                type: .newComment,
                prId: "PR_CHANGES_WITH_COMMENT",
                count: 1,
                actorLogin: "frontend-sam",
                activityId: "UNRELATED_COMMENT",
                destinationURL: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                happenedAt: Date(timeIntervalSince1970: 300),
                commentReason: .general
            )
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
                    url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
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
                    url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
                    state: .approved,
                    submittedAt: Date(timeIntervalSince1970: 300),
                    author: "rw",
                    viewerDidAuthor: true
                )
            ],
            isMine: true
        )

        try expect(PRActivityDetector.detectProcessedPeopleActivity(
            previous: processedActivity(for: previous),
            current: current
        ).isEmpty)
    }

    private static func testDetectsCIFailuresForIncomingPRs() throws {
        let previous = PullRequest.fixture(id: "PR_INCOMING_CI", ciState: .passing, isMine: false)
        let current = PullRequest.fixture(id: "PR_INCOMING_CI", ciState: .failing, isMine: false)

        try expect(PRActivityDetector.detectTransitions(previous: previous, current: current).map(\.type) == [.ciFailed])
    }

    private static func testDetectsIncomingRelationshipAddedTransitions() throws {
        let assigned = PRActivityDetector.detectTransitions(
            previous: .fixture(id: "PR_ASSIGNED", isAssignedToViewer: false, isMine: false),
            current: .fixture(id: "PR_ASSIGNED", isAssignedToViewer: true, isMine: false)
        )
        try expect(assigned.map(\.type) == [.relationshipAdded])
        try expect(assigned[0].relationshipChanges == [.assigned])
        try expect(assigned[0].happenedAt == nil)

        let direct = PRActivityDetector.detectTransitions(
            previous: .fixture(id: "PR_DIRECT", reviewRequestKind: .none, isMine: false),
            current: .fixture(id: "PR_DIRECT", reviewRequestKind: .direct, isMine: false)
        )
        try expect(direct.map(\.type) == [.relationshipAdded])
        try expect(direct[0].relationshipChanges == [.directReviewRequest])

        let team = PRActivityDetector.detectTransitions(
            previous: .fixture(id: "PR_TEAM", reviewRequestKind: .none, isMine: false),
            current: .fixture(id: "PR_TEAM", reviewRequestKind: .team, isMine: false)
        )
        try expect(team.map(\.type) == [.relationshipAdded])
        try expect(team[0].relationshipChanges == [.teamReviewRequest])

        let combined = PRActivityDetector.detectTransitions(
            previous: .fixture(id: "PR_COMBINED", reviewRequestKind: .none, isAssignedToViewer: false, isMine: false),
            current: .fixture(id: "PR_COMBINED", reviewRequestKind: .directAndTeam, isAssignedToViewer: true, isMine: false)
        )
        try expect(combined.map(\.type) == [.relationshipAdded])
        try expect(combined[0].relationshipChanges == [.assigned, .directReviewRequest, .teamReviewRequest])

        let selfAuthored = PRActivityDetector.detectTransitions(
            previous: .fixture(id: "PR_SELF", reviewRequestKind: .none, isAssignedToViewer: false, isMine: true),
            current: .fixture(id: "PR_SELF", reviewRequestKind: .direct, isAssignedToViewer: true, isMine: true)
        )
        try expect(selfAuthored.isEmpty)

        let unchangedTeam = PRActivityDetector.detectTransitions(
            previous: .fixture(id: "PR_TEAM_UNCHANGED", reviewRequestKind: .team, isMine: false),
            current: .fixture(id: "PR_TEAM_UNCHANGED", reviewRequestKind: .team, isMine: false)
        )
        try expect(unchangedTeam.isEmpty)
    }

    private static func testDetectsRelationshipsOnPRsFirstSeenAfterBaseline() throws {
        let direct = PRActivityDetector.detectTransitions(
            previous: nil,
            current: .fixture(id: "PR_NEW_DIRECT", reviewRequestKind: .direct, isMine: false)
        )
        try expect(direct.map(\.type) == [.relationshipAdded])
        try expect(direct[0].relationshipChanges == [.directReviewRequest])

        let assigned = PRActivityDetector.detectTransitions(
            previous: nil,
            current: .fixture(id: "PR_NEW_ASSIGNED", isAssignedToViewer: true, isMine: false)
        )
        try expect(assigned.map(\.type) == [.relationshipAdded])
        try expect(assigned[0].relationshipChanges == [.assigned])

        let team = PRActivityDetector.detectTransitions(
            previous: nil,
            current: .fixture(id: "PR_NEW_TEAM", reviewRequestKind: .team, isMine: false)
        )
        try expect(team.map(\.type) == [.relationshipAdded])
        try expect(team[0].relationshipChanges == [.teamReviewRequest])

        let combined = PRActivityDetector.detectTransitions(
            previous: nil,
            current: .fixture(
                id: "PR_NEW_COMBINED", reviewRequestKind: .directAndTeam, isAssignedToViewer: true, isMine: false
            )
        )
        try expect(combined.map(\.type) == [.relationshipAdded])
        try expect(combined[0].relationshipChanges == [.assigned, .directReviewRequest, .teamReviewRequest])

        let authored = PRActivityDetector.detectTransitions(
            previous: nil,
            current: .fixture(
                id: "PR_NEW_AUTHORED", reviewRequestKind: .directAndTeam, isAssignedToViewer: true, isMine: true
            )
        )
        try expect(authored.isEmpty)
    }

    private static func testNewlySeenPRKeepsCIBaselined() throws {
        let failing = PRActivityDetector.detectTransitions(
            previous: nil,
            current: .fixture(id: "PR_NEW_FAILING", ciState: .failing, reviewRequestKind: .direct, isMine: false)
        )
        try expect(failing.map(\.type) == [.relationshipAdded])
    }

    private static func testRelationshipAddedFilteringUsesChangedRelationships() throws {
        let pullRequest = PullRequest.fixture(
            id: "PR_OVERLAP_RELATIONSHIP",
            reviewRequestKind: .direct,
            isAssignedToViewer: true,
            isMine: false
        )
        let preferences = NotificationPreferences(
            authored: .disabled,
            assigned: PullRequestNotificationActivityPreferences(
                reviewActivity: false,
                ciFailures: false,
                relationshipChanges: true
            ),
            directReviewRequests: .disabled,
            teamReviewRequests: .disabled
        )
        let assignedEvent = PullRequestEvent(
            type: .relationshipAdded,
            prId: pullRequest.id,
            relationshipChanges: [.assigned]
        )
        let directEvent = PullRequestEvent(
            type: .relationshipAdded,
            prId: pullRequest.id,
            relationshipChanges: [.directReviewRequest]
        )

        try expect(
            PRActivityDetector.filter([assignedEvent, directEvent], preferences: preferences, pullRequest: pullRequest)
                == [assignedEvent]
        )
    }

    private static func testNotificationPreferencesDefaultCommentModes() throws {
        let authored = PullRequest.fixture(id: "PR_AUTHORED", isMine: true)
        let assigned = PullRequest.fixture(id: "PR_ASSIGNED", isAssignedToViewer: true, isMine: false)
        let direct = PullRequest.fixture(id: "PR_DIRECT", reviewRequestKind: .direct, isMine: false)
        let team = PullRequest.fixture(id: "PR_TEAM", reviewRequestKind: .team, isMine: false)
        let general = PullRequestEvent(type: .newComment, prId: "PR_AUTHORED", commentReason: .general)
        let mention = PullRequestEvent(type: .reviewCommented, prId: "PR_AUTHORED", commentReason: .mention)

        try expect(NotificationPreferences.defaults.allows(event: general, for: authored))
        try expect(NotificationPreferences.defaults.allows(event: general, for: assigned))
        try expect(!NotificationPreferences.defaults.allows(event: general, for: direct))
        try expect(!NotificationPreferences.defaults.allows(event: general, for: team))
        try expect(NotificationPreferences.defaults.allows(event: mention, for: direct))
        try expect(NotificationPreferences.defaults.allows(event: mention, for: team))
        try expect(!NotificationPreferences.defaults.allows(
            event: PullRequestEvent(type: .reviewApproved, prId: assigned.id),
            for: assigned
        ))
        try expect(NotificationPreferences.defaults.allows(
            event: PullRequestEvent(
                type: .relationshipAdded,
                prId: assigned.id,
                relationshipChanges: [.assigned]
            ),
            for: assigned
        ))
    }

    private static func testPreferencesFilterEvents() throws {
        let preferences = NotificationPreferences(
            authored: PullRequestNotificationActivityPreferences(
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
                .map(\.type) == [.newComment, .reviewCommented, .ciFailed]
        )
    }

    private static func testNotificationPreferencesAllowEachRelationshipAndActivity() throws {
        for relationship in PullRequestNotificationRelationship.allCases {
            for activity in PullRequestNotificationActivity.allCases {
                var preferences = NotificationPreferences(
                    authored: .disabled,
                    assigned: .disabled,
                    directReviewRequests: .disabled,
                    teamReviewRequests: .disabled,
                    commentModes: CommentNotificationPreferences(
                        authored: .off, assigned: .off, directReviewRequests: .off, teamReviewRequests: .off
                    )
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

    private static func testNotificationPreferencesSeparateDecisionsFromComments() throws {
        let pullRequest = PullRequest.fixture(id: "PR_REVIEWS", isMine: true)
        let preferences = NotificationPreferences(
            authored: PullRequestNotificationActivityPreferences(
                reviewActivity: true,
                ciFailures: false
            ),
            assigned: .disabled,
            directReviewRequests: .disabled,
            teamReviewRequests: .disabled,
            commentModes: CommentNotificationPreferences(
                authored: .off, assigned: .all, directReviewRequests: .all, teamReviewRequests: .all
            )
        )

        for eventType in [
            PullRequestEventType.reviewApproved,
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
        for eventType in [PullRequestEventType.newComment, .reviewCommented] {
            try expect(!preferences.allows(
                event: PullRequestEvent(type: eventType, prId: pullRequest.id, commentReason: .mention),
                for: pullRequest
            ))
        }
        try expect(!preferences.allows(event: PullRequestEvent(type: .ciFailed, prId: pullRequest.id), for: pullRequest))
    }

    private static func testNotificationPreferencesAllowOverlappingRelationshipOnce() throws {
        let preferences = NotificationPreferences(
            authored: .disabled,
            assigned: PullRequestNotificationActivityPreferences(
                reviewActivity: false,
                ciFailures: false
            ),
            directReviewRequests: PullRequestNotificationActivityPreferences(
                reviewActivity: false,
                ciFailures: false
            ),
            teamReviewRequests: .disabled,
            commentModes: CommentNotificationPreferences(
                authored: .all, assigned: .off, directReviewRequests: .mentionsAndThreads, teamReviewRequests: .off
            )
        )
        let pullRequest = PullRequest.fixture(
            id: "PR_OVERLAP",
            reviewRequestKind: .direct,
            isAssignedToViewer: true,
            isMine: false
        )
        let events = [PullRequestEvent(type: .newComment, prId: pullRequest.id, commentReason: .threadParticipation)]

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


    private static func testPreparedRefreshUsesDurableProcessedActivity() async throws {
        let source = EmptyPullRequestSource()
        let engine = SyncEngine(
            source: source,
            loginProvider: { "rw" },
            accountProvider: { GitHubAccount(login: "rw") },
            now: { Date(timeIntervalSince1970: 10) }
        )
        let baselinePR = PullRequest.fixture(
            recentCommentActivities: [
                PullRequestCommentActivity(
                    id: "BASELINE",
                    url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                    author: "teammate",
                    createdAt: Date(timeIntervalSince1970: 1),
                    source: .pullRequest
                )
            ],
            isMine: true
        )
        let baseline = try await engine.prepare(
            previousState: nil,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [baselinePR])
        )
        try expect(baseline.events.isEmpty)

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
        let nextPR = PullRequest.fixture(
            recentCommentActivities: baselinePR.recentCommentActivities + [
                PullRequestCommentActivity(
                    id: "NEW",
                    url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                    author: "teammate",
                    createdAt: Date(timeIntervalSince1970: 2),
                    source: .pullRequest
                )
            ],
            isMine: true
        )
        let prepared = try await engine.prepare(
            previousState: previous,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [nextPR])
        )
        try expect(prepared.events.map(\.event.activityId) == ["NEW"])
        try expect(prepared.syncedAt == Date(timeIntervalSince1970: 10))
    }

    private static func activityPreferences(
        enabling activity: PullRequestNotificationActivity
    ) -> PullRequestNotificationActivityPreferences {
        PullRequestNotificationActivityPreferences(
            reviewActivity: activity == .reviewActivity,
            ciFailures: activity == .ciFailures,
            relationshipChanges: activity == .relationshipChanges
        )
    }

    private static func eventType(for activity: PullRequestNotificationActivity) -> PullRequestEventType {
        switch activity {
        case .reviewActivity:
            .reviewApproved
        case .ciFailures:
            .ciFailed
        case .relationshipChanges:
            .relationshipAdded
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

    private static func processedActivity(for pullRequest: PullRequest) -> ProcessedPullRequestActivity {
        ProcessedPullRequestActivity(
            pullRequestID: pullRequest.id,
            commentIDs: Set(pullRequest.recentCommentActivities.map(\.id)),
            submittedReviewIDs: Set(pullRequest.recentReviews.map(\.id))
        )
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
