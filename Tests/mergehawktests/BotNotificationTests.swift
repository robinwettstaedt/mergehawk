@testable import mergehawk
@testable import mergehawkcore
import Foundation
import XCTest

@MainActor
final class BotNotificationTests: XCTestCase {
    func testMuteAppliesToEveryCommentAndReviewFormAndOnlyPositiveBots() async throws {
        for muted in [false, true] {
            let fixture = try BotFixture(muted: muted)
            defer { fixture.cleanup() }
            await fixture.started()
            let current = botPR(classifications: [true, false, nil])
            fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [current]))
            await fixture.finished()
            let rows = fixture.controller.pullRequestNotificationHistory
            XCTAssertEqual(rows.count, muted ? 10 : 15)
            XCTAssertEqual(Set(rows.compactMap(\.actorLogin)), muted ? ["human", "unknown"] : ["bot", "human", "unknown"])
            XCTAssertFalse(fixture.notifications.records.isEmpty)
            if muted {
                XCTAssertTrue(fixture.notifications.records.allSatisfy { !$0.body.contains("@bot") && !$0.title.contains("@bot") })
            }
            XCTAssertEqual(fixture.controller.state.pullRequests.first?.reviewDecision, .changesRequested)
            XCTAssertEqual(fixture.controller.state.pullRequests.first?.commentCount, 2)
        }
    }

    func testMutingBotsPreservesExactDestinationForTheRemainingHumanMacOSUpdate() async throws {
        let fixture = try BotFixture(muted: true)
        defer { fixture.cleanup() }
        await fixture.started()
        var current = botPR(classifications: [true, false])
        current.recentCommentActivities = current.recentCommentActivities.filter {
            $0.authorIsBot == true || $0.source == .pullRequest
        }
        current.recentReviews = current.recentReviews.filter { $0.authorIsBot == true }
        let humanComment = try XCTUnwrap(current.recentCommentActivities.first { $0.authorIsBot == false })
        fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [current]))
        await fixture.finished()

        let notification = try XCTUnwrap(fixture.controller.pullRequestNotificationHistory.first)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, 1)
        XCTAssertEqual(notification.url, current.url)
        XCTAssertEqual(notification.destinationURL, humanComment.url)
        let payload = try XCTUnwrap(fixture.notifications.records.first)
        XCTAssertEqual(fixture.notifications.records.count, 1)
        XCTAssertEqual(payload.clickPullRequestURL, current.url.absoluteString)
        XCTAssertEqual(payload.clickDestinationURL, humanComment.url.absoluteString)
        XCTAssertEqual(payload.actorLogin, "human")
    }

    func testBotOnlyUpdatesLeaveAttentionEmptyAndNormalMembershipIntact() async throws {
        let fixture = try BotFixture(muted: true)
        defer { fixture.cleanup() }
        await fixture.started()
        fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [botPR(classifications: [true])]))
        await fixture.finished()
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
        XCTAssertFalse(fixture.controller.hasAttention)
        XCTAssertEqual(fixture.controller.attentionCount, 0)
        XCTAssertFalse(fixture.controller.isUnreadPullRequest(fixture.controller.state.pullRequests[0]))
        XCTAssertEqual(fixture.controller.sortedMyPullRequests.count, 1)
        fixture.controller.selectedPullRequestFilters = [.needsAttention]
        XCTAssertTrue(fixture.controller.sortedMyPullRequests.isEmpty)
        XCTAssertEqual(fixture.controller.state.pullRequests.count, 1)
        XCTAssertEqual(fixture.controller.state.pullRequests[0].reviewDecision, .changesRequested)
        XCTAssertEqual(fixture.controller.state.pullRequests[0].commentCount, 2)
    }

    func testOldPersistedHistoryAndReadStateSurviveToggleRefreshAndRelaunch() async throws {
        let baseline = botPR()
        let old = [false, true].enumerated().map { index, read in
            var notification = PullRequestNotification(event: PullRequestEvent(type: .newComment, prId: baseline.id, activityId: "old-\(index)"), pullRequest: baseline, createdAt: Date(timeIntervalSince1970: Double(index)))
            notification.read = read
            return notification
        }.sorted { $0.createdAt > $1.createdAt }
        let fixture = try BotFixture(history: old, legacyMetadata: true)
        defer { fixture.cleanup() }
        await fixture.started()
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, old)
        fixture.controller.muteBotNotifications = true
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, old)
        fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [botPR(classifications: [true])]))
        await fixture.finished()
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, old)
        XCTAssertTrue(fixture.controller.hasAttention)
        XCTAssertEqual(fixture.controller.attentionCount, 1)
        let priorFetchCount = fixture.provider.fetchCount
        let reopened = fixture.reopen()
        await waitFor { fixture.provider.fetchCount > priorFetchCount && !reopened.isRefreshing }
        XCTAssertTrue(reopened.muteBotNotifications)
        XCTAssertEqual(reopened.pullRequestNotificationHistory, old)
        XCTAssertTrue(reopened.hasAttention)
    }

    func testSuppressedIDsRemainProcessedAcrossUnmuteAndRestartButNewUpdatesDeliver() async throws {
        let fixture = try BotFixture(muted: true)
        defer { fixture.cleanup() }
        await fixture.started()
        fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [botPR(classifications: [true])]))
        await fixture.finished()
        let processed = try XCTUnwrap(fixture.preferences.pullRequestSyncState?.processedActivityByPullRequestID["PR_BOT_TEST"])
        XCTAssertEqual(processed.commentIDs.count, 2)
        XCTAssertEqual(processed.submittedReviewIDs.count, 3)
        fixture.controller.muteBotNotifications = false
        await refresh(fixture.controller, provider: fixture.provider)
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        let priorFetchCount = fixture.provider.fetchCount
        let reopened = fixture.reopen()
        await waitFor { fixture.provider.fetchCount > priorFetchCount && !reopened.isRefreshing }
        XCTAssertFalse(reopened.muteBotNotifications)
        XCTAssertTrue(reopened.pullRequestNotificationHistory.isEmpty)
        await refresh(reopened, provider: fixture.provider)
        XCTAssertTrue(reopened.pullRequestNotificationHistory.isEmpty)
        fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [botPR(classifications: [true], suffix: "-new")]))
        await refresh(reopened, provider: fixture.provider)
        XCTAssertEqual(reopened.pullRequestNotificationHistory.count, 5)
    }

    func testFinalRetiringUpdatesUseSameFilterAndHumanRowsKeepOpenableIdentity() async throws {
        let opened = BotOpenedURLs()
        let fixture = try BotFixture(muted: true, opened: opened)
        defer { fixture.cleanup() }
        await fixture.started()
        fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [], retiringPullRequests: [botPR(classifications: [true, false])]))
        await fixture.finished()
        XCTAssertTrue(fixture.controller.state.pullRequests.isEmpty)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, 5)
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.allSatisfy { $0.actorLogin == "human" })
        fixture.controller.openPullRequestNotification(fixture.controller.pullRequestNotificationHistory[0])
        XCTAssertEqual(opened.values, [try XCTUnwrap(fixture.controller.pullRequestNotificationHistory[0].destinationURL)])
        XCTAssertTrue(fixture.notifications.records.allSatisfy { !$0.body.contains("@bot") })
    }

    func testCIAndRelationshipUpdatesRemainEligibleWhileBotsAreMuted() async throws {
        let fixture = try BotFixture(muted: true, baseline: botPR(mine: false))
        defer { fixture.cleanup() }
        await fixture.started()
        let current = botPR(classifications: [true], mine: false, assigned: true, ci: .failing)
        fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [current]))
        await fixture.finished()
        XCTAssertEqual(Set(fixture.controller.pullRequestNotificationHistory.map(\.eventType)), [.ciFailed, .relationshipAdded])
        XCTAssertFalse(fixture.notifications.records.isEmpty)
    }

    func testCurrentMuteValueAtCommitControlsSuspendedFetch() async throws {
        for startingMute in [false, true] {
            let fixture = try BotFixture(muted: startingMute)
            defer { fixture.cleanup() }
            await fixture.started()
            fixture.controller.muteBotNotifications = !startingMute
            fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [botPR(classifications: [true])]))
            await fixture.finished()
            XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, startingMute ? 5 : 0)
            XCTAssertEqual(fixture.notifications.records.isEmpty, !startingMute)
        }
    }
}

@MainActor
private final class BotOpenedURLs { var values: [URL] = [] }

@MainActor
private struct BotFixture {
    let suite: String
    let defaults: UserDefaults
    var preferences: PreferencesStore
    let provider: BotProvider
    let notifications: RecordingNotificationClient
    let controller: DashboardController

    init(muted: Bool = false, baseline: PullRequest = botPR(), history: [PullRequestNotification] = [], legacyMetadata: Bool = false, opened: BotOpenedURLs? = nil) throws {
        suite = "bot-notifications-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        preferences.muteBotNotifications = muted
        preferences.notificationPreferences = NotificationPreferences(authored: .enabled, assigned: .enabled, directReviewRequests: .enabled, teamReviewRequests: .enabled)
        let account = GitHubAccount(login: "rw")
        let state = PullRequestSyncState(account: account, dashboard: DashboardState(pullRequests: [baseline], events: [PullRequestEvent(type: .newComment, prId: baseline.id)], syncedAt: Date(timeIntervalSince1970: 10), source: .github, account: account, authStatus: .signedIn), processedActivityByPullRequestID: [baseline.id: PRActivityDetector.processedActivity(for: baseline)], notificationHistory: history)
        if legacyMetadata {
            // Encode a complete pre-feature state, including activity/event objects without metadata keys.
            let data = try JSONEncoder().encode(state)
            let object = try JSONSerialization.jsonObject(with: data)
            defaults.set(try JSONSerialization.data(withJSONObject: removingBotMetadata(object)), forKey: "pullRequests.syncState")
        } else {
            try preferences.storePullRequestSyncState(state)
        }
        provider = BotProvider()
        notifications = RecordingNotificationClient()
        controller = DashboardController(tokenStore: InMemoryTokenStore(token: "pat"), preferencesStore: preferences, launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true), notificationClient: notifications, automaticRefreshInterval: 0, patGitHubClientFactory: { [provider] _ in provider }, urlOpener: { opened?.values.append($0) })
    }

    func reopen() -> DashboardController {
        DashboardController(tokenStore: InMemoryTokenStore(token: "pat"), preferencesStore: PreferencesStore(defaults: defaults), launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true), notificationClient: notifications, automaticRefreshInterval: 0, patGitHubClientFactory: { _ in provider })
    }
    func started() async { await waitFor { provider.fetchCount > 0 } }
    func finished() async { await waitFor { !controller.isRefreshing }; XCTAssertNil(controller.refreshErrorMessage) }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
}

private final class BotProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    private var result: CompletePullRequestFetchResult?
    private var continuation: CheckedContinuation<CompletePullRequestFetchResult, Error>?
    private(set) var fetchCount = 0
    func fetchViewer() async throws -> GitHubAccount { GitHubAccount(login: "rw") }
    func fetchCompletePullRequests(login: String, previousState: PullRequestSyncState?) async throws -> CompletePullRequestFetchResult {
        fetchCount += 1
        if let result { return result }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: CompletePullRequestFetchResult) {
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog { SourceCatalog(repositories: [], accountLogin: accountLogin) }
    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations { GitHubAppInstallations(installations: []) }
}

private func botPR(classifications: [Bool?] = [], suffix: String = "", mine: Bool = true, assigned: Bool = false, ci: CIState = .passing) -> PullRequest {
    let date = Date(timeIntervalSince1970: 20)
    var comments: [PullRequestCommentActivity] = []
    var reviews: [PullRequestReview] = []
    for (index, isBot) in classifications.enumerated() {
        let author = isBot == true ? "bot" : isBot == false ? "human" : "unknown"
        for (sourceIndex, source) in [PullRequestCommentActivity.Source.pullRequest, .reviewThread].enumerated() {
            comments.append(PullRequestCommentActivity(id: "C-\(index)-\(sourceIndex)\(suffix)", url: URL(string: "https://github.com/acme/app/pull/72#issuecomment-C-\(index)-\(sourceIndex)\(suffix)")!, author: author, authorIsBot: isBot, createdAt: date, source: source))
        }
        for (stateIndex, state) in [PullRequestReviewState.commented, .approved, .changesRequested].enumerated() {
            reviews.append(PullRequestReview(id: "R-\(index)-\(stateIndex)\(suffix)", url: URL(string: "https://github.com/acme/app/pull/72#pullrequestreview-R-\(index)-\(stateIndex)\(suffix)")!, state: state, submittedAt: date, author: author, authorIsBot: isBot))
        }
    }
    return PullRequest(id: "PR_BOT_TEST", title: "Bot notification test", number: 72, url: URL(string: "https://github.com/acme/app/pull/72")!, repo: "acme/app", ciState: ci, reviewDecision: .changesRequested, commentCount: 2, recentCommentActivities: comments, reviewCount: reviews.count, recentReviews: reviews, isAssignedToViewer: assigned, isMine: mine, author: mine ? "rw" : "teammate", mergeable: .mergeable, draft: false)
}

private func removingBotMetadata(_ value: Any) -> Any {
    if let object = value as? [String: Any] {
        return object.filter { $0.key != "authorIsBot" && $0.key != "actorIsBot" }.mapValues(removingBotMetadata)
    }
    if let array = value as? [Any] { return array.map(removingBotMetadata) }
    return value
}

@MainActor
private func waitFor(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for bot notification refresh")
}

@MainActor
private func refresh(_ controller: DashboardController, provider: BotProvider) async {
    let count = provider.fetchCount
    controller.refresh()
    await waitFor { provider.fetchCount > count && !controller.isRefreshing }
}
