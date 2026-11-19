@testable import mergehawk
@testable import mergehawkcore
import Foundation
import XCTest

@MainActor
final class IgnoredAuthorNotificationTests: XCTestCase {
    func testBotsToggleDropsNewReviewRequestsOnBotPullRequestsOnly() async throws {
        let fixture = try IgnoreFixture(
            baseline: [ignorePR("PR_BOT", author: "dependabot", isBot: true), ignorePR("PR_HUMAN", author: "teammate")]
        ) { $0.ignoresBotPullRequests = true }
        defer { fixture.cleanup() }
        await fixture.started()
        fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [
            ignorePR("PR_BOT", author: "dependabot", isBot: true, request: .direct),
            ignorePR("PR_HUMAN", author: "teammate", request: .direct)
        ]))
        await fixture.finished()

        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.map(\.prId), ["PR_HUMAN"])
        XCTAssertEqual(fixture.notifications.records.map(\.pullRequestId), ["PR_HUMAN"])
        XCTAssertEqual(fixture.controller.state.events.map(\.prId), ["PR_HUMAN"])
    }

    func testIgnoredAccountDropsNewReviewRequestsEvenWithRepositoryNotificationsOn() async throws {
        let fixture = try IgnoreFixture(
            baseline: [ignorePR("PR_NORA", author: "platform-nora"), ignorePR("PR_HUMAN", author: "teammate")]
        ) { store in
            store.ignoredAccounts = ["Platform-Nora"]
            store.sourcePreferences = SourcePreferences(
                owners: ["acme": OwnerSourcePreferences(notifications: false, myPullRequests: false, reviewRequests: false)],
                repositories: ["acme/app": RepositorySourcePreferences(
                    notifications: .enabled, myPullRequests: .enabled, reviewRequests: .enabled
                )]
            )
        }
        defer { fixture.cleanup() }
        await fixture.started()
        fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [
            ignorePR("PR_NORA", author: "platform-nora", request: .direct),
            ignorePR("PR_HUMAN", author: "teammate", request: .direct)
        ]))
        await fixture.finished()

        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.map(\.prId), ["PR_HUMAN"])
        XCTAssertEqual(fixture.notifications.records.map(\.pullRequestId), ["PR_HUMAN"])
    }

    func testFinalActivityOfARetiringBotPullRequestFollowsTheToggle() async throws {
        for ignoresBots in [false, true] {
            // A cached PR without a bot type, so only the retiring PR's own type can ignore it.
            let baseline = ignorePR("PR_BOT", author: "dependabot", isBot: nil, request: .direct)
            let fixture = try IgnoreFixture(baseline: [baseline]) { $0.ignoresBotPullRequests = ignoresBots }
            defer { fixture.cleanup() }
            await fixture.started()
            let merged = ignorePR(
                "PR_BOT", author: "dependabot", isBot: true, comments: [ignoreComment("FINAL")]
            )
            fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [], retiringPullRequests: [merged]))
            await fixture.finished()

            XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, ignoresBots ? 0 : 1, "\(ignoresBots)")
            XCTAssertEqual(fixture.notifications.records.isEmpty, ignoresBots, "\(ignoresBots)")
        }
    }

    func testSettingValueAtCommitControlsASuspendedRefresh() async throws {
        for startsIgnoring in [false, true] {
            let fixture = try IgnoreFixture(baseline: [ignorePR("PR_BOT", author: "dependabot", isBot: true)]) {
                $0.ignoresBotPullRequests = startsIgnoring
            }
            defer { fixture.cleanup() }
            await fixture.started()
            fixture.controller.ignoresBotPullRequests = !startsIgnoring
            fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [
                ignorePR("PR_BOT", author: "dependabot", isBot: true, request: .direct)
            ]))
            await fixture.finished()

            XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, startsIgnoring ? 1 : 0)
            XCTAssertEqual(fixture.notifications.records.isEmpty, !startsIgnoring)
        }
    }

    func testDroppedActivityIsProcessedSoLiftingTheIgnoreReplaysNothing() async throws {
        let fixture = try IgnoreFixture(baseline: [ignorePR("PR_BOT", author: "dependabot", isBot: true)]) {
            $0.ignoresBotPullRequests = true
        }
        defer { fixture.cleanup() }
        await fixture.started()
        fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [
            ignorePR("PR_BOT", author: "dependabot", isBot: true, request: .direct, comments: [ignoreComment("C1")])
        ]))
        await fixture.finished()
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)

        fixture.controller.ignoresBotPullRequests = false
        await fixture.refresh()

        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
    }

    func testExistingRowsHideAndReturnAsTheIgnoreChanges() async throws {
        let dependabotPR = ignorePR("PR_DEPENDABOT", author: "dependabot", isBot: true)
        let nora = row("NORA", for: ignorePR("PR_NORA", author: "platform-nora"))
        let flaggedBot = row("FLAGGED", for: ignorePR("PR_RENOVATE", author: "renovate", isBot: true))
        let knownBot = row("KNOWN", for: ignorePR("PR_DEPENDABOT", author: "Dependabot", isBot: nil))
        let noAuthor = try withoutKey(row("NO_AUTHOR", for: ignorePR("PR_OLD", author: "dependabot", isBot: nil)), "prAuthor")
        let unknownBot = row("UNKNOWN", for: ignorePR("PR_GONE", author: "old-bot", isBot: nil))
        let sameLoginPerson = row("PERSON", for: ignorePR("PR_PERSON", author: "dependabot", isBot: false))
        let fixture = try IgnoreFixture(
            baseline: [dependabotPR],
            history: [nora, flaggedBot, knownBot, noAuthor, unknownBot, sameLoginPerson]
        )
        defer { fixture.cleanup() }
        await fixture.started()
        let controller = fixture.controller
        func visible() -> Set<String> { Set(controller.visiblePullRequestNotifications.compactMap(\.activityId)) }
        let all: Set<String> = ["NORA", "FLAGGED", "KNOWN", "NO_AUTHOR", "UNKNOWN", "PERSON"]
        XCTAssertEqual(visible(), all)
        XCTAssertEqual(controller.attentionCount, 6)

        controller.ignoresBotPullRequests = true
        XCTAssertEqual(visible(), ["NORA", "NO_AUTHOR", "UNKNOWN", "PERSON"])
        XCTAssertEqual(controller.attentionCount, 4)

        controller.addIgnoredAccount("platform-nora")
        XCTAssertEqual(visible(), ["NO_AUTHOR", "UNKNOWN", "PERSON"])
        XCTAssertEqual(controller.attentionCount, 3)

        controller.ignoresBotPullRequests = false
        controller.removeIgnoredAccount("platform-nora")
        XCTAssertEqual(visible(), all)
        XCTAssertEqual(controller.attentionCount, 6)
        XCTAssertEqual(controller.pullRequestNotificationHistory.count, 6)
    }

    func testAHiddenUnreadRowReturnsUnreadAfterMarkAllRead() async throws {
        let bot = row("BOT", for: ignorePR("PR_BOT", author: "dependabot", isBot: true))
        let human = row("HUMAN", for: ignorePR("PR_HUMAN", author: "teammate"))
        let fixture = try IgnoreFixture(baseline: [], history: [bot, human]) { $0.ignoresBotPullRequests = true }
        defer { fixture.cleanup() }
        await fixture.started()
        XCTAssertEqual(fixture.controller.attentionCount, 1)

        fixture.controller.markAllNotificationsRead()
        XCTAssertFalse(fixture.controller.hasAttention)
        fixture.controller.ignoresBotPullRequests = false

        XCTAssertEqual(fixture.controller.attentionCount, 1)
        XCTAssertEqual(fixture.controller.visiblePullRequestNotifications.filter { !$0.read }.map(\.activityId), ["BOT"])
    }

    func testBotCommentsOnAVisiblePullRequestFollowOnlyTheBotMute() async throws {
        for muted in [false, true] {
            let fixture = try IgnoreFixture(baseline: [ignorePR("PR_HUMAN", author: "teammate", request: .direct)]) {
                $0.ignoresBotPullRequests = true
                $0.muteBotNotifications = muted
            }
            defer { fixture.cleanup() }
            await fixture.started()
            fixture.provider.finish(CompletePullRequestFetchResult(activePullRequests: [
                ignorePR("PR_HUMAN", author: "teammate", request: .direct, comments: [ignoreComment("BOT_COMMENT", byBot: true)])
            ]))
            await fixture.finished()

            XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, muted ? 0 : 1, "\(muted)")
        }
    }

    private func row(_ activityID: String, for pullRequest: PullRequest) -> PullRequestNotification {
        PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: pullRequest.id, activityId: activityID),
            pullRequest: pullRequest,
            createdAt: Date(timeIntervalSince1970: 5)
        )
    }

    private func withoutKey(_ notification: PullRequestNotification, _ key: String) throws -> PullRequestNotification {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(notification)) as? [String: Any])
        object.removeValue(forKey: key)
        return try JSONDecoder().decode(PullRequestNotification.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@MainActor
private struct IgnoreFixture {
    let suite: String
    let defaults: UserDefaults
    let provider: IgnoreProvider
    let notifications: RecordingNotificationClient
    let controller: DashboardController

    init(
        baseline: [PullRequest],
        history: [PullRequestNotification] = [],
        configure: (inout PreferencesStore) -> Void = { _ in }
    ) throws {
        suite = "ignored-author-notifications-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        preferences.notificationPreferences = NotificationPreferences(
            authored: .enabled, assigned: .enabled, directReviewRequests: .enabled, teamReviewRequests: .enabled,
            commentModes: CommentNotificationPreferences(
                authored: .all, assigned: .all, directReviewRequests: .all, teamReviewRequests: .all
            )
        )
        configure(&preferences)
        let account = GitHubAccount(login: "rw")
        let state = PullRequestSyncState(
            account: account,
            dashboard: DashboardState(
                pullRequests: baseline, events: [], syncedAt: Date(timeIntervalSince1970: 10),
                source: .github, account: account, authStatus: .signedIn
            ),
            processedActivityByPullRequestID: Dictionary(
                uniqueKeysWithValues: baseline.map { ($0.id, PRActivityDetector.processedActivity(for: $0)) }
            ),
            notificationHistory: history
        )
        try preferences.storePullRequestSyncState(state)
        provider = IgnoreProvider()
        notifications = RecordingNotificationClient()
        controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            notificationClient: notifications,
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { [provider] _ in provider }
        )
    }

    func started() async { await ignoreWaitFor { provider.fetchCount > 0 } }
    func finished() async {
        await ignoreWaitFor { !controller.isRefreshing }
        XCTAssertNil(controller.refreshErrorMessage)
    }
    func refresh() async {
        let count = provider.fetchCount
        controller.refresh()
        await ignoreWaitFor { provider.fetchCount > count && !controller.isRefreshing }
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
}

private final class IgnoreProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    private var result: CompletePullRequestFetchResult?
    private var continuation: CheckedContinuation<CompletePullRequestFetchResult, Error>?
    private(set) var fetchCount = 0
    func fetchViewer() async throws -> GitHubAccount { GitHubAccount(login: "rw") }
    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?,
        reusableViewerTeams: [ViewerTeam]?
    ) async throws -> CompletePullRequestFetchResult {
        fetchCount += 1
        if let result { return result }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: CompletePullRequestFetchResult) {
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: accountLogin)
    }
    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }
}

private func ignorePR(
    _ id: String,
    author: String,
    isBot: Bool? = false,
    request: ReviewRequestKind = .none,
    comments: [PullRequestCommentActivity] = []
) -> PullRequest {
    PullRequest(
        id: id, title: id, number: 1, url: URL(string: "https://github.com/acme/app/pull/1")!, repo: "acme/app",
        ciState: .passing, reviewDecision: .reviewRequired, commentCount: comments.count,
        recentCommentActivities: comments, reviewCount: 0, reviewRequestKind: request, isMine: false,
        author: author, authorIsBot: isBot, mergeable: .mergeable, draft: false
    )
}

private func ignoreComment(_ id: String, byBot: Bool = false) -> PullRequestCommentActivity {
    PullRequestCommentActivity(
        id: id,
        url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-\(id)")!,
        author: byBot ? "ci-bot" : "reviewer",
        authorIsBot: byBot,
        createdAt: Date(timeIntervalSince1970: 20),
        source: .pullRequest
    )
}

@MainActor
private func ignoreWaitFor(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the ignored author refresh")
}
