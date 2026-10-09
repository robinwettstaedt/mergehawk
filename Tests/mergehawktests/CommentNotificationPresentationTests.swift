@testable import mergehawk
@testable import mergehawkcore
import Foundation
import XCTest

final class CommentNotificationPresentationTests: XCTestCase {
    func testReasonTitlesMatchAcrossInAppRowsAndSingleMacOSUpdates() {
        let pullRequest = presentationPR()
        let cases: [(PullRequestEventType, PullRequestCommentReason, String?, String)] = [
            (.newComment, .mention, "alice", "@alice mentioned you"),
            (.reviewCommented, .mention, "alice", "@alice mentioned you"),
            (.newComment, .mention, nil, "Someone mentioned you"),
            (.reviewCommented, .threadParticipation, "alice", "@alice commented in a thread you joined"),
            (.reviewCommented, .threadParticipation, nil, "New comment in a thread you joined"),
        ]
        for (type, reason, actor, expected) in cases {
            let event = PullRequestEvent(type: type, prId: pullRequest.id, count: 1, actorLogin: actor, commentReason: reason)
            let row = PullRequestNotification(event: event, pullRequest: pullRequest)
            XCTAssertEqual(PullRequestNotificationTitlePresentation.title(for: row), expected)
            XCTAssertEqual(NotificationContentBuilder.summaryTitle(for: [event]), expected)
            XCTAssertEqual(NotificationContentBuilder.records(events: [event], pullRequests: [pullRequest]).first?.title, expected)
        }

        let generic: [(PullRequestEventType, PullRequestCommentReason?, String?, String, String)] = [
            (.newComment, .general, "alice", "New comment from @alice", "New comment from @alice"),
            (.newComment, nil, "alice", "New comment from @alice", "New comment from @alice"),
            (.reviewCommented, .general, "alice", "Review comment from @alice", "Review comment from @alice"),
            (.reviewCommented, nil, nil, "Review comment", "PR review commented"),
            (.newComment, .general, nil, "1 new comment", "New PR comment"),
        ]
        for (type, reason, actor, inApp, macOS) in generic {
            let event = PullRequestEvent(type: type, prId: pullRequest.id, count: 1, actorLogin: actor, commentReason: reason)
            XCTAssertEqual(PullRequestNotificationTitlePresentation.title(for: PullRequestNotification(event: event, pullRequest: pullRequest)), inApp)
            XCTAssertEqual(NotificationContentBuilder.summaryTitle(for: [event]), macOS)
        }
    }

    func testMultipleUpdatesKeepTheAggregateMacOSTitleAndNotificationsRoute() {
        let pullRequest = presentationPR()
        let events = [
            PullRequestEvent(type: .newComment, prId: pullRequest.id, actorLogin: "alice", destinationURL: presentationURL("#c1"), commentReason: .mention),
            PullRequestEvent(type: .reviewCommented, prId: pullRequest.id, actorLogin: "bob", destinationURL: presentationURL("#c2"), commentReason: .threadParticipation),
        ]
        XCTAssertEqual(NotificationContentBuilder.summaryTitle(for: events), "2 MergeHawk updates")
        XCTAssertEqual(NotificationClickRoute.route(events: events, pullRequests: [pullRequest]), .openNotifications)
        XCTAssertEqual(
            NotificationClickRoute.route(events: [events[0]], pullRequests: [pullRequest]),
            .openPullRequest(PullRequestOpenRequest(pullRequestURL: pullRequest.url, destinationURL: presentationURL("#c1")))
        )
    }

    @MainActor
    func testOneRowPerActivityAndAnEditMentionGetsItsOwnRowAndDestination() async throws {
        let baseline = presentationPR(assigned: true, request: .directAndTeam, comments: [
            presentationComment("VIEWER", at: 10, viewer: true, thread: "T"),
        ])
        let fixture = try PresentationFixture(baseline: baseline)
        defer { fixture.cleanup() }
        await fixture.waitForFirstFetch()

        let created = presentationPR(assigned: true, request: .directAndTeam, comments: baseline.recentCommentActivities + [
            presentationComment("BOTH", at: 20, thread: "T", mention: true),
            presentationComment("EDITED", at: 21),
        ])
        fixture.provider.complete(with: created)
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.map(\.activityId), ["EDITED", "BOTH"])
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.map(\.commentReason), [.general, .mention])

        let edited = presentationPR(assigned: true, request: .directAndTeam, comments: baseline.recentCommentActivities + [
            presentationComment("BOTH", at: 20, thread: "T", mention: true),
            presentationComment("EDITED", at: 21, updatedAt: 40, mention: true),
        ])
        fixture.provider.succeed(with: edited)
        await fixture.refresh()
        await fixture.refresh()

        let rows = fixture.controller.pullRequestNotificationHistory
        XCTAssertEqual(rows.map(\.activityId), ["EDITED", "EDITED", "BOTH"])
        XCTAssertEqual(rows.map(\.commentReason), [.mention, .general, .mention])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        XCTAssertEqual(PullRequestNotificationTitlePresentation.title(for: rows[0]), "@alice mentioned you")
        fixture.controller.openPullRequestNotification(rows[0])
        XCTAssertEqual(fixture.opened.values.last?.destinationURL, presentationURL("#issuecomment-EDITED"))
        XCTAssertEqual(fixture.notifications.records.filter { $0.title == "@alice mentioned you" }.count, 2)
    }

    @MainActor
    func testApprovalWithSummaryAndFiveInlineCommentsYieldsSixRowsWithExactDestinations() async throws {
        for decisionsEnabled in [true, false] {
            let fixture = try PresentationFixture(baseline: presentationPR())
            defer { fixture.cleanup() }
            await fixture.waitForFirstFetch()
            fixture.controller.preferences.authored.reviewActivity = decisionsEnabled
            let inline = (1...5).map { presentationComment("INLINE_\($0)", at: 20 + Double($0), thread: "T\($0)", review: "APPROVAL") }
            let current = presentationPR(
                comments: inline + [presentationComment("CONVERSATION", at: 30)],
                reviews: [
                    presentationReview("APPROVAL", .approved, at: 20),
                    presentationReview("SUMMARY", .commented, at: 31),
                ]
            )
            fixture.provider.complete(with: current)
            await fixture.waitForIdle()

            let rows = fixture.controller.pullRequestNotificationHistory
            let expectedIDs = Set((1...5).map { "INLINE_\($0)" } + ["CONVERSATION", "SUMMARY"] + (decisionsEnabled ? ["APPROVAL"] : []))
            XCTAssertEqual(Set(rows.compactMap(\.activityId)), expectedIDs)
            XCTAssertEqual(rows.count, expectedIDs.count)
            let approvalRows = rows.filter { $0.activityId == "APPROVAL" || $0.activityId?.hasPrefix("INLINE_") == true }
            XCTAssertEqual(approvalRows.count, decisionsEnabled ? 6 : 5)
            for row in rows {
                let expected = current.recentCommentActivities.first { $0.id == row.activityId }?.url
                    ?? current.recentReviews.first { $0.id == row.activityId }?.url
                XCTAssertEqual(row.destinationURL, expected)
                fixture.controller.openPullRequestNotification(row)
                XCTAssertEqual(fixture.opened.values.last?.destinationURL, expected)
                XCTAssertEqual(fixture.opened.values.last?.pullRequestURL, current.url)
            }
            XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.allSatisfy(\.read))
        }
    }

    @MainActor
    func testHistoryKeepsNewestHundredMixedReadRowsWithDeterministicTies() async throws {
        let base = presentationPR()
        let retained = (0..<70).map { index in
            var row = PullRequestNotification(
                event: PullRequestEvent(type: .newComment, prId: base.id, activityId: String(format: "OLD_%02d", index)),
                pullRequest: base,
                createdAt: Date(timeIntervalSince1970: 5)
            )
            row.read = index.isMultiple(of: 2)
            return row
        }
        let fixture = try PresentationFixture(baseline: base, history: retained)
        defer { fixture.cleanup() }
        await fixture.waitForFirstFetch()
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, 70)

        let fresh = (0..<40).map { presentationComment(String(format: "NEW_%02d", $0), at: 50) }
        fixture.provider.complete(with: presentationPR(comments: fresh))
        await fixture.waitForIdle()

        let rows = fixture.controller.pullRequestNotificationHistory
        XCTAssertEqual(rows.count, 100)
        let expectedOld = retained.map { $0.activityId! }.sorted(by: >).prefix(60)
        XCTAssertEqual(rows.compactMap(\.activityId), fresh.map(\.id).sorted(by: >) + Array(expectedOld))
        for row in rows where row.activityId?.hasPrefix("OLD_") == true {
            XCTAssertEqual(row.read, retained.first { $0.activityId == row.activityId }?.read)
        }
        XCTAssertEqual(PreferencesStore(defaults: fixture.defaults).pullRequestSyncState?.notificationHistory, rows)
    }

    @MainActor
    func testDisabledMacOSDeliveryStillRecordsRowsWithoutReplayingWhenEnabled() async throws {
        let fixture = try PresentationFixture(baseline: presentationPR())
        defer { fixture.cleanup() }
        await fixture.waitForFirstFetch()
        fixture.controller.macOSLocalNotificationsEnabled = false
        fixture.provider.complete(with: presentationPR(comments: [presentationComment("C", at: 20, mention: true)]))
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.map(\.activityId), ["C"])
        XCTAssertTrue(fixture.notifications.records.isEmpty)

        fixture.controller.macOSLocalNotificationsEnabled = true
        await fixture.refresh()
        XCTAssertTrue(fixture.notifications.records.isEmpty)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, 1)
    }
}

private func presentationURL(_ suffix: String) -> URL {
    URL(string: "https://github.com/acme/app/pull/9\(suffix)")!
}

private func presentationComment(
    _ id: String,
    at seconds: Double,
    viewer: Bool = false,
    thread: String? = nil,
    review: String? = nil,
    updatedAt: Double? = nil,
    mention: Bool = false
) -> PullRequestCommentActivity {
    PullRequestCommentActivity(
        id: id, url: presentationURL("#issuecomment-\(id)"), author: viewer ? "rw" : "alice", authorIsBot: false,
        viewerDidAuthor: viewer, createdAt: Date(timeIntervalSince1970: seconds),
        source: thread == nil ? .pullRequest : .reviewThread, reviewId: review,
        updatedAt: updatedAt.map { Date(timeIntervalSince1970: $0) }, threadId: thread, mentionsViewer: mention
    )
}

private func presentationReview(_ id: String, _ state: PullRequestReviewState, at seconds: Double) -> PullRequestReview {
    PullRequestReview(
        id: id, url: presentationURL("#pullrequestreview-\(id)"), state: state,
        submittedAt: Date(timeIntervalSince1970: seconds), author: "alice", authorIsBot: false, hasSummaryText: true
    )
}

private func presentationPR(
    assigned: Bool = false,
    request: ReviewRequestKind = .none,
    comments: [PullRequestCommentActivity] = [],
    reviews: [PullRequestReview] = []
) -> PullRequest {
    PullRequest(
        id: "PR_PRESENTATION", title: "Comment presentation", number: 9, url: presentationURL(""), repo: "acme/app",
        ciState: .passing, reviewDecision: .reviewRequired, commentCount: 0, recentCommentActivities: comments,
        reviewCount: reviews.count, recentReviews: reviews, reviewRequestKind: request, isAssignedToViewer: assigned,
        isMine: true, author: "rw", mergeable: .mergeable, draft: false
    )
}

@MainActor
private final class OpenedRequests { var values: [PullRequestOpenRequest] = [] }

@MainActor
private struct PresentationFixture {
    let suite: String
    let defaults: UserDefaults
    let provider: PresentationProvider
    let notifications: RecordingNotificationClient
    let opened: OpenedRequests
    let controller: DashboardController

    init(baseline: PullRequest, history: [PullRequestNotification] = []) throws {
        suite = "comment-presentation-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        var seed = PreferencesStore(defaults: defaults)
        seed.authMethod = .pat
        let account = GitHubAccount(login: "rw")
        try seed.storePullRequestSyncState(PullRequestSyncState(
            account: account,
            dashboard: DashboardState(pullRequests: [baseline.withoutActivityHistory], events: [], syncedAt: Date(timeIntervalSince1970: 1), source: .github, account: account, authStatus: .signedIn),
            processedActivityByPullRequestID: [baseline.id: PRActivityDetector.processedActivity(for: baseline)],
            notificationHistory: history
        ))
        provider = PresentationProvider()
        notifications = RecordingNotificationClient()
        let opened = OpenedRequests()
        self.opened = opened
        controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            notificationClient: notifications,
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { [provider] _ in provider },
            pullRequestOpener: { opened.values.append($0) }
        )
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
        XCTFail("Timed out waiting for presentation refresh")
    }
}

private final class PresentationProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    private var next: CompletePullRequestFetchResult?
    private var continuation: CheckedContinuation<CompletePullRequestFetchResult, Error>?
    private(set) var fetchCount = 0

    func fetchViewer() async throws -> GitHubAccount { GitHubAccount(login: "rw") }

    func fetchCompletePullRequests(login: String, previousState: PullRequestSyncState?, reusableViewerTeams: [ViewerTeam]?) async throws -> CompletePullRequestFetchResult {
        fetchCount += 1
        if let next { return next }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete(with pullRequest: PullRequest) {
        let result = CompletePullRequestFetchResult(activePullRequests: [pullRequest])
        next = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func succeed(with pullRequest: PullRequest) {
        next = CompletePullRequestFetchResult(activePullRequests: [pullRequest])
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog { SourceCatalog(repositories: [], accountLogin: accountLogin) }
    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations { GitHubAppInstallations(installations: []) }
}
