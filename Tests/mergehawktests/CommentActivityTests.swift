@testable import mergehawk
@testable import mergehawkcore
import Foundation
import XCTest

final class CommentActivityTests: XCTestCase {
    // MARK: Comment modes

    func testDefaultModesApplyPerRelationshipWithAnyAllowOverlapAndOff() {
        let preferences = NotificationPreferences.defaults
        let reasons: [PullRequestCommentReason?] = [.mention, .threadParticipation, .general, nil]
        for (pullRequest, allowed) in [
            (pr(mine: true), reasons),
            (pr(mine: false, assigned: true), reasons),
            (pr(mine: false, request: .direct), [.mention, .threadParticipation]),
            (pr(mine: false, request: .team), [.mention, .threadParticipation]),
        ] as [(PullRequest, [PullRequestCommentReason?])] {
            for type in [PullRequestEventType.newComment, .reviewCommented] {
                for reason in reasons {
                    let event = PullRequestEvent(type: type, prId: pullRequest.id, commentReason: reason)
                    XCTAssertEqual(
                        preferences.allows(event: event, for: pullRequest),
                        allowed.contains(reason),
                        "\(NotificationPreferences.relationships(matching: pullRequest)) \(String(describing: reason))"
                    )
                }
            }
        }

        let overlap = pr(mine: false, assigned: true, request: .direct)
        var modes = NotificationPreferences.defaults
        modes.commentModes.assigned = .off
        XCTAssertTrue(modes.allows(event: commentEvent(.mention), for: overlap))
        XCTAssertFalse(modes.allows(event: commentEvent(.general), for: overlap))
        modes.commentModes.directReviewRequests = .off
        XCTAssertFalse(modes.allows(event: commentEvent(.mention), for: overlap))
        modes.commentModes.assigned = .all
        XCTAssertTrue(modes.allows(event: commentEvent(.general), for: overlap))

        modes.commentModes = allOff
        modes.authored.reviewActivity = true
        XCTAssertFalse(modes.allows(event: commentEvent(.mention), for: pr(mine: true)))
        XCTAssertTrue(modes.allows(event: PullRequestEvent(type: .reviewApproved, prId: "PR"), for: pr(mine: true)))
    }

    // MARK: Participation

    func testSelfAuthoredNeverEmitsAndOnlyPublishedViewerCommentsJoinTheirOwnThread() {
        let previous = pr(comments: [
            comment("VIEWER_T1", at: 10, viewer: true, thread: "T1"),
            comment("DRAFT_T2", at: 10, viewer: true, thread: "T2", published: false),
        ])
        let current = pr(comments: previous.recentCommentActivities + [
            comment("REPLY_T1", at: 20, thread: "T1"),
            comment("REPLY_T2", at: 20, thread: "T2"),
            comment("REPLY_T3", at: 20, thread: "T3"),
            comment("CONVERSATION", at: 20),
            comment("VIEWER_T3", at: 21, viewer: true, thread: "T3"),
        ])

        let reasons = reasonsByID(detect(previous, current))

        XCTAssertEqual(reasons, [
            "REPLY_T1": .threadParticipation,
            "REPLY_T2": .general,
            "REPLY_T3": .general,
            "CONVERSATION": .general,
        ])
    }

    func testParticipationCoversLaterAndSimultaneousCommentsButNeverEarlierOnes() {
        let current = pr(comments: [
            comment("EARLIER", at: 5, thread: "T"),
            comment("VIEWER", at: 10, viewer: true, thread: "T"),
            comment("SIMULTANEOUS", at: 10, thread: "T"),
            comment("LATER", at: 15, thread: "T"),
        ])

        let events = detect(pr(), current)

        XCTAssertEqual(reasonsByID(events), [
            "EARLIER": .general,
            "SIMULTANEOUS": .threadParticipation,
            "LATER": .threadParticipation,
        ])
        XCTAssertEqual(events.map(\.activityId), ["EARLIER", "SIMULTANEOUS", "LATER"])
        let requested = pr(mine: false, request: .direct)
        XCTAssertEqual(
            events.filter { NotificationPreferences.defaults.allows(event: $0, for: requested) }.map(\.activityId),
            ["SIMULTANEOUS", "LATER"]
        )
    }

    func testDeletedParticipationStopsQualifyingWhileMentionsAndLateRepliesStillWork() {
        let joined = pr(comments: [
            comment("VIEWER", at: 10, viewer: true, thread: "T"),
            comment("REPLY", at: 11, thread: "T"),
        ])
        // Comments carry no resolution state, so a reply in a resolved thread is detected like any other.
        let lateReply = pr(comments: joined.recentCommentActivities + [comment("LATE", at: 50, thread: "T")])
        XCTAssertEqual(reasonsByID(detect(joined, lateReply)), ["LATE": .threadParticipation])

        let deleted = pr(comments: [
            comment("REPLY", at: 11, thread: "T"),
            comment("AFTER_DELETE", at: 20, thread: "T"),
            comment("MENTION_AFTER_DELETE", at: 21, thread: "T", mention: true),
        ])
        XCTAssertEqual(reasonsByID(detect(joined, deleted)), [
            "AFTER_DELETE": .general,
            "MENTION_AFTER_DELETE": .mention,
        ])
    }

    func testViewerDraftJoinsOnlyAfterPublicationAndLegacyCutoffUsesPublication() {
        let draft = pr(comments: [comment("DRAFT", at: 10, viewer: true, thread: "T", published: false)])
        let beforePublication = pr(comments: draft.recentCommentActivities + [comment("A", at: 20, thread: "T")])
        XCTAssertEqual(reasonsByID(detect(draft, beforePublication)), ["A": .general])

        let published = pr(comments: [
            comment("DRAFT", at: 10, viewer: true, thread: "T", publishedAt: 30),
            comment("A", at: 20, thread: "T"),
            comment("B", at: 31, thread: "T"),
        ])
        XCTAssertEqual(reasonsByID(detect(beforePublication, published)), ["B": .threadParticipation])

        let legacy = ProcessedPullRequestActivity(pullRequestID: "PR", processedThrough: Date(timeIntervalSince1970: 100))
        let afterCutoff = pr(comments: [
            comment("PUBLISHED_AFTER", at: 90, publishedAt: 110),
            comment("PUBLISHED_BEFORE", at: 80, publishedAt: 95),
        ])
        XCTAssertEqual(
            PRActivityDetector.detectProcessedPeopleActivity(previous: legacy, current: afterCutoff).map(\.activityId),
            ["PUBLISHED_AFTER"]
        )
        XCTAssertEqual(
            PRActivityDetector.detectProcessedPeopleActivity(previous: legacy, current: afterCutoff).first?.happenedAt,
            Date(timeIntervalSince1970: 110)
        )
    }

    // MARK: Mentions

    func testBaselineAndUpgradeDoNotReplayButUnseenActivityNotifies() async throws {
        let existing = pr(
            comments: [comment("OLD", at: 10, mention: true), comment("OLD_INLINE", at: 11, thread: "T", mention: true)],
            reviews: [review("OLD_SUMMARY", .commented, at: 12, mention: true)]
        )
        let engine = SyncEngine(source: EmptyPullRequestSource(), loginProvider: { "rw" })
        let baseline = try await engine.prepare(previousState: nil, fetchResult: CompletePullRequestFetchResult(activePullRequests: [existing]))
        XCTAssertTrue(baseline.events.isEmpty)
        XCTAssertEqual(baseline.processedActivityByPullRequestID["PR"]?.mentioningActivityIDs, ["OLD", "OLD_INLINE", "OLD_SUMMARY"])

        let upgraded = ProcessedPullRequestActivity(
            pullRequestID: "PR",
            commentIDs: ["OLD", "OLD_INLINE"],
            submittedReviewIDs: ["OLD_SUMMARY"]
        )
        XCTAssertNil(upgraded.mentioningActivityIDs)
        let withUnseen = pr(
            comments: existing.recentCommentActivities + [comment("UNSEEN", at: 20)],
            reviews: existing.recentReviews
        )
        XCTAssertEqual(
            PRActivityDetector.detectProcessedPeopleActivity(previous: upgraded, current: withUnseen).map(\.activityId),
            ["UNSEEN"]
        )
        let processed = PRActivityDetector.processedActivity(for: withUnseen)
        XCTAssertTrue(PRActivityDetector.detectProcessedPeopleActivity(previous: processed, current: withUnseen).isEmpty)
    }

    func testMentionMembershipEmitsOnlyForObservedAdditions() {
        var states = [pr(comments: [comment("C", at: 10)])]
        func step(_ next: PullRequest) -> [PullRequestEvent] {
            defer { states.append(next) }
            return detect(states.last!, next)
        }

        let newWithMention = step(pr(comments: [comment("C", at: 10), comment("M", at: 20, mention: true)]))
        XCTAssertEqual(newWithMention.map(\.activityId), ["M"])
        XCTAssertEqual(newWithMention.first?.commentReason, .mention)
        XCTAssertEqual(newWithMention.first?.happenedAt, Date(timeIntervalSince1970: 20))

        let added = step(pr(comments: [comment("C", at: 10, updatedAt: 50, mention: true), comment("M", at: 20, mention: true)]))
        XCTAssertEqual(added.map(\.activityId), ["C"])
        XCTAssertEqual(added.first?.type, .newComment)
        XCTAssertEqual(added.first?.commentReason, .mention)
        XCTAssertEqual(added.first?.happenedAt, Date(timeIntervalSince1970: 50))
        XCTAssertEqual(added.first?.destinationURL, commentURL("C"))

        // A retained mention, a casing-only change, or an ordinary edit only moves the update time.
        XCTAssertTrue(step(pr(comments: [comment("C", at: 10, updatedAt: 60, mention: true), comment("M", at: 20, updatedAt: 61, mention: true)])).isEmpty)
        XCTAssertTrue(step(states.last!).isEmpty)
        XCTAssertTrue(step(pr(comments: [comment("C", at: 10, updatedAt: 70), comment("M", at: 20, updatedAt: 61, mention: true)])).isEmpty)
        let readded = step(pr(comments: [comment("C", at: 10, updatedAt: 80, mention: true), comment("M", at: 20, updatedAt: 61, mention: true)]))
        XCTAssertEqual(readded.map(\.activityId), ["C"])
        XCTAssertEqual(readded.first?.happenedAt, Date(timeIntervalSince1970: 80))
    }

    func testSummaryMentionEditsNotifyOnlyForCommentOnlyReviews() {
        let before = pr(reviews: [
            review("SUMMARY", .commented, at: 10),
            review("APPROVAL", .approved, at: 11),
            review("CHANGES", .changesRequested, at: 12),
        ])
        let after = pr(reviews: [
            review("SUMMARY", .commented, at: 10, updatedAt: 40, mention: true),
            review("APPROVAL", .approved, at: 11, updatedAt: 41, mention: true),
            review("CHANGES", .changesRequested, at: 12, updatedAt: 42, mention: true),
        ])

        let events = detect(before, after)

        XCTAssertEqual(events.map(\.activityId), ["SUMMARY"])
        XCTAssertEqual(events.first?.type, .reviewCommented)
        XCTAssertEqual(events.first?.commentReason, .mention)
        XCTAssertEqual(events.first?.happenedAt, Date(timeIntervalSince1970: 40))
    }

    // MARK: Reviews

    func testOnlyNonemptyCommentOnlySummariesCreateCommentUpdates() {
        let current = pr(reviews: [
            review("SUMMARY", .commented, at: 10),
            review("EMPTY", .commented, at: 11, text: false),
            review("APPROVAL", .approved, at: 12, mention: true),
            review("CHANGES", .changesRequested, at: 13, mention: true),
        ])

        let events = detect(pr(), current)

        XCTAssertEqual(events.map(\.activityId), ["APPROVAL", "CHANGES", "SUMMARY"])
        XCTAssertEqual(events.map(\.type), [.reviewApproved, .changesRequested, .reviewCommented])
        XCTAssertEqual(events.map(\.commentReason), [nil, nil, .general])

        var decisionsOff = NotificationPreferences.defaults
        decisionsOff.authored.reviewActivity = false
        XCTAssertEqual(events.filter { decisionsOff.allows(event: $0, for: current) }.map(\.activityId), ["SUMMARY"])
    }

    func testDecisionsOnWithCommentsOffKeepsSummariesQuietAndNilReasonsCountAsGeneral() {
        var preferences = NotificationPreferences.defaults
        preferences.authored.reviewActivity = true
        preferences.commentModes.authored = .off
        let current = pr(reviews: [review("SUMMARY", .commented, at: 10, mention: true)])

        let events = detect(pr(), current)

        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events.filter { preferences.allows(event: $0, for: current) }.isEmpty)
        let legacy = PullRequestEvent(type: .reviewCommented, prId: "PR")
        let requested = pr(mine: false, request: .direct)
        XCTAssertFalse(NotificationPreferences.defaults.allows(event: legacy, for: requested))
        XCTAssertTrue(NotificationPreferences.defaults.allows(event: legacy, for: pr(mine: true)))
    }

    func testReviewsNeverHideTheirEligibleInlineComments() {
        let inline = (1...5).map { comment("INLINE_\($0)", at: 10 + Double($0), thread: "T\($0)", review: "APPROVAL") }
        let approval = detect(pr(), pr(comments: inline, reviews: [review("APPROVAL", .approved, at: 10, mention: true)]))
        XCTAssertEqual(approval.count, 6)
        XCTAssertEqual(Set(approval.compactMap(\.activityId)).count, 6)
        XCTAssertEqual(approval.filter { $0.type == .reviewCommented }.count, 5)

        let emptyComment = detect(pr(), pr(
            comments: [comment("ONLY", at: 11, thread: "T", review: "EMPTY")],
            reviews: [review("EMPTY", .commented, at: 11, text: false)]
        ))
        XCTAssertEqual(emptyComment.map(\.activityId), ["ONLY"])

        let commentOnly = detect(pr(), pr(
            comments: [comment("CHILD_1", at: 11, thread: "T1", review: "SUMMARY"), comment("CHILD_2", at: 11, thread: "T2", review: "SUMMARY")],
            reviews: [review("SUMMARY", .commented, at: 11)]
        ))
        XCTAssertEqual(Set(commentOnly.compactMap(\.activityId)), ["SUMMARY", "CHILD_1", "CHILD_2"])
        XCTAssertEqual(commentOnly.count, 3)

        // Mentions & threads you joined keeps only the one relevant inline comment of a review.
        let requested = pr(mine: false, request: .direct, comments: [
            comment("RELEVANT", at: 11, thread: "T1", review: "R", mention: true),
            comment("UNRELATED", at: 11, thread: "T2", review: "R"),
        ], reviews: [review("R", .approved, at: 11)])
        let allowed = detect(pr(mine: false, request: .direct), requested).filter {
            NotificationPreferences.defaults.allows(event: $0, for: requested)
        }
        XCTAssertEqual(allowed.map(\.activityId), ["RELEVANT"])
    }

    // MARK: State lifecycle

    func testSameAccountRestartKeepsMentionStateWhileAnotherAccountAndRetirementStayCoherent() async throws {
        let before = pr(mine: false, request: .direct, comments: [comment("C", at: 10)])
        let processed = PRActivityDetector.processedActivity(for: before)
        let state = PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: DashboardState(pullRequests: [before.withoutActivityHistory], events: [], syncedAt: nil, source: .github, account: GitHubAccount(login: "rw"), authStatus: .signedIn),
            processedActivityByPullRequestID: ["PR": processed]
        )
        let restored = try JSONDecoder().decode(PullRequestSyncState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.processedActivityByPullRequestID["PR"]?.mentioningActivityIDs, [])
        let edited = pr(mine: false, request: .direct, comments: [comment("C", at: 10, updatedAt: 30, mention: true)])

        let sameAccount = try await SyncEngine(source: EmptyPullRequestSource(), loginProvider: { "RW" })
            .prepare(previousState: restored, fetchResult: CompletePullRequestFetchResult(activePullRequests: [edited]))
        XCTAssertEqual(sameAccount.events.map(\.event.activityId), ["C"])
        XCTAssertEqual(sameAccount.processedActivityByPullRequestID["PR"]?.mentioningActivityIDs, ["C"])

        let otherAccount = try await SyncEngine(source: EmptyPullRequestSource(), loginProvider: { "someone" })
            .prepare(previousState: restored, fetchResult: CompletePullRequestFetchResult(activePullRequests: [edited]))
        XCTAssertTrue(otherAccount.events.isEmpty)

        let merged = pr(mine: false, request: .none, comments: [
            comment("C", at: 10, updatedAt: 30, mention: true),
            comment("FINAL", at: 40),
        ])
        let retiring = try await SyncEngine(source: EmptyPullRequestSource(), loginProvider: { "rw" })
            .prepare(previousState: restored, fetchResult: CompletePullRequestFetchResult(activePullRequests: [], retiringPullRequests: [merged]))
        XCTAssertEqual(retiring.events.map(\.event.activityId), ["C", "FINAL"])
        XCTAssertNil(retiring.processedActivityByPullRequestID["PR"])
        let allowed = retiring.events.filter { NotificationPreferences.defaults.allows(event: $0.event, for: $0.filteringContext) }
        XCTAssertEqual(allowed.map(\.event.activityId), ["C"])
    }

    @MainActor
    func testDeliveryFiltersStillAdvanceMentionStateWithoutLaterReplay() async throws {
        for filter in ["mode", "source", "archive", "bot"] {
            let archived = filter == "archive"
            let isBot = filter == "bot"
            let baseline = pr(archived: archived, comments: [comment("OLD", at: 10, isBot: isBot)])
            let fixture = try CommentFixture(baseline: baseline)
            defer { fixture.cleanup() }
            await fixture.waitForFirstFetch()
            switch filter {
            case "mode": fixture.controller.preferences.commentModes.authored = .off
            case "source": fixture.controller.setRepositoryPreferences(repo: baseline.repo, preferences: RepositorySourcePreferences(notifications: .disabled, myPullRequests: .inherit, reviewRequests: .inherit))
            case "archive": XCTAssertTrue(fixture.controller.hideArchivedRepositories)
            default: fixture.controller.muteBotNotifications = true
            }
            let updated = pr(archived: archived, comments: [
                comment("OLD", at: 10, updatedAt: 30, mention: true, isBot: isBot),
                comment("NEW", at: 31, mention: true, isBot: isBot),
            ])
            fixture.provider.complete(with: updated)
            await fixture.waitForIdle()
            XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty, filter)
            XCTAssertEqual(fixture.storedMentions, ["OLD", "NEW"], filter)

            switch filter {
            case "mode": fixture.controller.preferences.commentModes.authored = .all
            case "source": fixture.controller.setRepositoryPreferences(repo: baseline.repo, preferences: .defaults)
            case "archive": fixture.controller.hideArchivedRepositories = false
            default: fixture.controller.muteBotNotifications = false
            }
            await fixture.refresh()
            XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty, filter)
        }

        let fixture = try CommentFixture(baseline: pr(comments: []))
        defer { fixture.cleanup() }
        await fixture.waitForFirstFetch()
        fixture.controller.muteBotNotifications = true
        fixture.provider.complete(with: pr(comments: [comment("UNKNOWN_ACTOR", at: 20, isBot: nil)]))
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.map(\.activityId), ["UNKNOWN_ACTOR"])
    }

    @MainActor
    func testModeChangedDuringSuspendedFetchAppliesAtCommit() async throws {
        let fixture = try CommentFixture(baseline: pr(mine: false, request: .direct, comments: []))
        defer { fixture.cleanup() }
        await fixture.waitForFirstFetch()
        fixture.controller.preferences.commentModes.directReviewRequests = .all
        fixture.provider.complete(with: pr(mine: false, request: .direct, comments: [comment("GENERAL", at: 20)]))
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.map(\.activityId), ["GENERAL"])
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.first?.commentReason, .general)
    }

    @MainActor
    func testFetchAndPersistenceFailuresKeepRowsAndMentionStateAndRetryEmitsOnce() async throws {
        let baseline = pr(comments: [comment("OLD", at: 10)])
        let fixture = try CommentFixture(baseline: baseline)
        defer { fixture.cleanup() }
        await fixture.waitForFirstFetch()
        fixture.provider.complete(with: baseline)
        await fixture.waitForIdle()
        let updated = pr(comments: [comment("OLD", at: 10, updatedAt: 30, mention: true), comment("NEW", at: 31)])

        fixture.provider.fail()
        await fixture.refresh()
        XCTAssertNotNil(fixture.controller.refreshErrorMessage)
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertEqual(fixture.storedMentions, [])

        fixture.provider.succeed(with: updated)
        fixture.encoderFailure.fails = true
        await fixture.refresh()
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertEqual(fixture.storedMentions, [])
        XCTAssertTrue(fixture.notifications.records.isEmpty)

        fixture.encoderFailure.fails = false
        await fixture.refresh()
        XCTAssertEqual(Set(fixture.controller.pullRequestNotificationHistory.compactMap(\.activityId)), ["OLD", "NEW"])
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.first { $0.activityId == "OLD" }?.commentReason, .mention)
        XCTAssertEqual(fixture.storedMentions, ["OLD"])

        await fixture.refresh()
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, 2)
    }

    // MARK: Helpers

    private let allOff = CommentNotificationPreferences(
        authored: .off, assigned: .off, directReviewRequests: .off, teamReviewRequests: .off
    )

    private func commentEvent(_ reason: PullRequestCommentReason?) -> PullRequestEvent {
        PullRequestEvent(type: .newComment, prId: "PR", commentReason: reason)
    }

    private func detect(_ previous: PullRequest, _ current: PullRequest) -> [PullRequestEvent] {
        PRActivityDetector.detectProcessedPeopleActivity(
            previous: PRActivityDetector.processedActivity(for: previous),
            current: current
        )
    }

    private func reasonsByID(_ events: [PullRequestEvent]) -> [String: PullRequestCommentReason] {
        Dictionary(uniqueKeysWithValues: events.compactMap { event in
            event.activityId.flatMap { id in event.commentReason.map { (id, $0) } }
        })
    }
}

private func commentURL(_ id: String) -> URL {
    URL(string: "https://github.com/acme/app/pull/7#issuecomment-\(id)")!
}

private func comment(
    _ id: String,
    at seconds: Double,
    viewer: Bool = false,
    thread: String? = nil,
    review: String? = nil,
    published: Bool = true,
    publishedAt: Double? = nil,
    updatedAt: Double? = nil,
    mention: Bool = false,
    isBot: Bool? = false
) -> PullRequestCommentActivity {
    PullRequestCommentActivity(
        id: id,
        url: commentURL(id),
        author: viewer ? "rw" : "alice",
        authorIsBot: isBot,
        viewerDidAuthor: viewer,
        createdAt: Date(timeIntervalSince1970: seconds),
        source: thread == nil ? .pullRequest : .reviewThread,
        reviewId: review,
        publishedAt: publishedAt.map { Date(timeIntervalSince1970: $0) },
        isPublished: published,
        updatedAt: updatedAt.map { Date(timeIntervalSince1970: $0) },
        threadId: thread,
        mentionsViewer: mention
    )
}

private func review(
    _ id: String,
    _ state: PullRequestReviewState,
    at seconds: Double,
    updatedAt: Double? = nil,
    text: Bool = true,
    mention: Bool = false
) -> PullRequestReview {
    PullRequestReview(
        id: id,
        url: URL(string: "https://github.com/acme/app/pull/7#pullrequestreview-\(id)")!,
        state: state,
        submittedAt: Date(timeIntervalSince1970: seconds),
        author: "alice",
        authorIsBot: false,
        updatedAt: updatedAt.map { Date(timeIntervalSince1970: $0) },
        hasSummaryText: text,
        mentionsViewer: mention
    )
}

private func pr(
    mine: Bool = true,
    assigned: Bool = false,
    request: ReviewRequestKind = .none,
    archived: Bool = false,
    comments: [PullRequestCommentActivity] = [],
    reviews: [PullRequestReview] = []
) -> PullRequest {
    PullRequest(
        id: "PR", title: "Comment notifications", number: 7,
        url: URL(string: "https://github.com/acme/app/pull/7")!, repo: "acme/app",
        repositoryIsArchived: archived, ciState: .passing, reviewDecision: .noReviewYet,
        commentCount: 0, recentCommentActivities: comments, reviewCount: reviews.count, recentReviews: reviews,
        reviewRequestKind: request, isAssignedToViewer: assigned, isMine: mine,
        author: mine ? "rw" : "alice", mergeable: .mergeable, draft: false
    )
}

private final class EncoderFailure: @unchecked Sendable {
    var fails = false
}

@MainActor
private struct CommentFixture {
    let suite: String
    let defaults: UserDefaults
    let provider: CommentProvider
    let notifications: RecordingNotificationClient
    let encoderFailure: EncoderFailure
    let controller: DashboardController

    init(baseline: PullRequest) throws {
        suite = "comment-activity-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        var seed = PreferencesStore(defaults: defaults)
        seed.authMethod = .pat
        let account = GitHubAccount(login: "rw")
        try seed.storePullRequestSyncState(PullRequestSyncState(
            account: account,
            dashboard: DashboardState(pullRequests: [baseline.withoutActivityHistory], events: [], syncedAt: Date(timeIntervalSince1970: 1), source: .github, account: account, authStatus: .signedIn),
            processedActivityByPullRequestID: [baseline.id: PRActivityDetector.processedActivity(for: baseline)]
        ))
        let encoderFailure = EncoderFailure()
        self.encoderFailure = encoderFailure
        provider = CommentProvider()
        notifications = RecordingNotificationClient()
        controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: PreferencesStore(defaults: defaults, syncStateEncoder: { state in
                if encoderFailure.fails { throw CocoaError(.fileWriteUnknown) }
                return try JSONEncoder().encode(state)
            }),
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            notificationClient: notifications,
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { [provider] _ in provider }
        )
    }

    var storedMentions: Set<String>? {
        PreferencesStore(defaults: defaults).pullRequestSyncState?.processedActivityByPullRequestID["PR"]?.mentioningActivityIDs
    }

    func waitForFirstFetch() async { await wait { provider.fetchCount > 0 } }
    func waitForIdle() async { await wait { !controller.isRefreshing } }
    func refresh() async {
        let count = provider.fetchCount
        controller.refresh()
        await wait { provider.fetchCount > count && !controller.isRefreshing }
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }

    private func wait(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for comment refresh")
    }
}

private final class CommentProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    private var next: Result<CompletePullRequestFetchResult, Error>?
    private var continuation: CheckedContinuation<CompletePullRequestFetchResult, Error>?
    private(set) var fetchCount = 0

    func fetchViewer() async throws -> GitHubAccount { GitHubAccount(login: "rw") }

    func fetchCompletePullRequests(login: String, previousState: PullRequestSyncState?) async throws -> CompletePullRequestFetchResult {
        fetchCount += 1
        if let next { return try next.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    /// Resumes the suspended fetch and answers later fetches with the same pull request.
    func complete(with pullRequest: PullRequest) {
        let result = CompletePullRequestFetchResult(activePullRequests: [pullRequest])
        next = .success(result)
        continuation?.resume(returning: result)
        continuation = nil
    }

    func succeed(with pullRequest: PullRequest) {
        next = .success(CompletePullRequestFetchResult(activePullRequests: [pullRequest]))
    }

    func fail() { next = .failure(GitHubReadError.http(status: 502)) }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog { SourceCatalog(repositories: [], accountLogin: accountLogin) }
    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations { GitHubAppInstallations(installations: []) }
}
