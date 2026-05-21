@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

final class AgentModeXCTests: XCTestCase {
    func testLaunchConfigurationAcceptsMockFlagAndEnvironment() {
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk", "--mock"],
                environment: [:]
            ),
            LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true)
        )
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk"],
                environment: ["MERGEHAWK_MOCK_MODE": "true"]
            ),
            LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true)
        )
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk", "--suppress-macos-notifications"],
                environment: [:]
            ),
            LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true)
        )
    }

    func testMockModeStartsSignedInWithoutToken() async {
        let notificationClient = RecordingNotificationClient()
        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
                notificationClient: notificationClient,
                automaticRefreshInterval: 0
            )
        }

        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                controller.state.syncedAt != nil
            }
        }

        await MainActor.run {
            XCTAssertEqual(controller.state.authStatus, .signedIn)
            XCTAssertEqual(controller.state.source, .mock)
            XCTAssertEqual(controller.state.account?.login, "agent-fixture")
            XCTAssertEqual(controller.state.pullRequests.map(\.id), ["PR_1", "PR_4", "PR_6", "PR_2", "PR_3", "PR_5"])
            XCTAssertFalse(controller.startsAtLogin)
        }

        await MainActor.run {
            controller.refresh()
        }
        await waitUntil(timeout: 1.0) {
            notificationClient.records.isEmpty == false
        }
        XCTAssertEqual(notificationClient.records.map(\.eventType), ["new_comment", "ci_failed"])
    }

    func testMacOSLocalNotificationsCanBeDisabled() async {
        let suiteName = "mergehawk-macos-local-disabled-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        var mutablePreferencesStore = PreferencesStore(defaults: defaults)
        mutablePreferencesStore.macOSLocalNotificationsEnabled = false
        let preferencesStore = mutablePreferencesStore

        let notificationClient = RecordingNotificationClient()
        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: preferencesStore,
                launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
                notificationClient: notificationClient,
                automaticRefreshInterval: 0
            )
        }

        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                controller.state.syncedAt != nil
            }
        }

        await MainActor.run {
            controller.refresh()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            XCTAssertFalse(controller.state.events.isEmpty)
            XCTAssertFalse(controller.visiblePullRequestNotifications.isEmpty)
        }
        XCTAssertTrue(notificationClient.records.isEmpty)
    }

    func testPRNotificationHistoryPersistsAndMarksReadWithoutRemovingRows() async {
        let suiteName = "mergehawk-pr-notification-history-test-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0
            )
        }

        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                controller.state.syncedAt != nil
            }
        }

        await MainActor.run {
            XCTAssertFalse(controller.hasAttention)
            controller.refresh()
        }
        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                controller.visiblePullRequestNotifications.count == 2
            }
        }

        await MainActor.run {
            XCTAssertEqual(controller.attentionCount, 2)
            XCTAssertTrue(controller.hasAttention)
            XCTAssertEqual(
                controller.visiblePullRequestNotifications.map(\.url).first,
                URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/14")
            )

            controller.markPullRequestNotificationRead(controller.visiblePullRequestNotifications[0])
            XCTAssertEqual(controller.visiblePullRequestNotifications.count, 2)
            XCTAssertEqual(controller.attentionCount, 1)

            controller.markAllNotificationsRead()
            XCTAssertEqual(controller.visiblePullRequestNotifications.count, 2)
            XCTAssertEqual(controller.attentionCount, 0)
            XCTAssertFalse(controller.hasAttention)
        }

        let restoredController = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0
            )
        }

        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                restoredController.state.syncedAt != nil
            }
        }

        await MainActor.run {
            XCTAssertEqual(restoredController.visiblePullRequestNotifications.count, 2)
            XCTAssertEqual(restoredController.attentionCount, 0)
        }
    }

    func testOpeningPullRequestMarksItsNotificationsRead() async {
        let suiteName = "mergehawk-open-pr-notification-history-test-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let pullRequest = makePullRequest(id: "PR_1", url: "https://github.com/example/mergehawk/pull/42")
        var preferencesStore = PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!)
        preferencesStore.pullRequestNotificationHistory = [
            PullRequestNotification(
                event: PullRequestEvent(type: .newComment, prId: pullRequest.id),
                pullRequest: pullRequest
            ),
            PullRequestNotification(
                event: PullRequestEvent(type: .ciFailed, prId: pullRequest.id),
                pullRequest: pullRequest
            )
        ]
        let seededPreferencesStore = preferencesStore
        let openedURLs = RecordingURLOpener()
        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: seededPreferencesStore,
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                urlOpener: openedURLs.open
            )
        }

        await MainActor.run {
            XCTAssertEqual(controller.visiblePullRequestNotifications.count, 2)
            XCTAssertTrue(controller.isUnreadPullRequest(pullRequest))
            controller.openPullRequest(pullRequest)

            XCTAssertEqual(openedURLs.urls, [pullRequest.url])
            XCTAssertFalse(controller.isUnreadPullRequest(pullRequest))
            XCTAssertEqual(controller.attentionCount, 0)
            XCTAssertTrue(
                controller.visiblePullRequestNotifications
                    .filter { $0.prId == pullRequest.id }
                    .allSatisfy(\.read)
            )
        }
    }

    func testOtherNotificationsDoNotDriveGlobalAttention() async {
        let suiteName = "mergehawk-other-notifications-test-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0
            )
        }

        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                controller.state.syncedAt != nil && controller.visibleGitHubInboxNotifications.count == 2
            }
        }

        await MainActor.run {
            XCTAssertEqual(controller.visibleGitHubInboxNotifications.filter(\.unread).count, 1)
            XCTAssertFalse(controller.hasAttention)
            XCTAssertEqual(controller.attentionCount, 0)

            controller.selectedNotificationSubtab = .other
            controller.markAllNotificationsRead()

            XCTAssertEqual(controller.visibleGitHubInboxNotifications.filter(\.unread).count, 0)
            XCTAssertFalse(controller.hasAttention)
        }
    }

    func testNotificationTypeFixtureModeSeedsAllMockNotificationKinds() async {
        let suiteName = "mergehawk-notification-type-fixtures-test-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(
                    usesMockData: true,
                    suppressesMacOSNotifications: true,
                    showsNotificationTypeFixtures: true
                ),
                automaticRefreshInterval: 0
            )
        }

        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                controller.state.syncedAt != nil
            }
        }

        await MainActor.run {
            XCTAssertEqual(
                Set(controller.visiblePullRequestNotifications.map(\.eventType)),
                [.newComment, .reviewApproved, .reviewCommented, .ciFailed, .changesRequested]
            )
            XCTAssertEqual(controller.visiblePullRequestNotifications.count, 5)
            XCTAssertTrue(
                controller.visiblePullRequestNotifications
                    .map { PullRequestNotificationTitlePresentation.title(for: $0) }
                    .contains("New comment from @frontend-sam")
            )
            XCTAssertEqual(
                Set(controller.visibleGitHubInboxNotifications.map(\.subjectType)),
                ["Issue", "Discussion", "Release", "Commit", "CheckSuite", "RepositoryVulnerabilityAlert"]
            )
            XCTAssertEqual(controller.visibleGitHubInboxNotifications.count, 6)
        }
    }

    func testSourcePreferencesSuppressInAppNotifications() async {
        let suiteName = "mergehawk-source-notifications-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        var mutablePreferencesStore = PreferencesStore(defaults: defaults)
        mutablePreferencesStore.sourcePreferences = SourcePreferences(
            owners: [
                "mergehawk-labs": OwnerSourcePreferences(
                    notifications: false,
                    myPullRequests: true,
                    reviewRequests: true
                ),
                "example": OwnerSourcePreferences(
                    notifications: false,
                    myPullRequests: true,
                    reviewRequests: true
                )
            ],
            repositories: [:]
        )
        let preferencesStore = mutablePreferencesStore

        let notificationClient = RecordingNotificationClient()
        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: preferencesStore,
                launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
                notificationClient: notificationClient,
                automaticRefreshInterval: 0
            )
        }

        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                controller.state.syncedAt != nil
            }
        }

        await MainActor.run {
            controller.refresh()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            XCTAssertTrue(controller.state.events.isEmpty)
            XCTAssertTrue(controller.visiblePullRequestNotifications.isEmpty)
            XCTAssertTrue(controller.visibleGitHubInboxNotifications.isEmpty)
        }
        XCTAssertTrue(notificationClient.records.isEmpty)
    }

    func testNotificationClickRouteOpensSingleMatchingPullRequest() {
        let pullRequest = makePullRequest(id: "PR_1", url: "https://github.com/example/mergehawk/pull/42")
        let route = NotificationClickRoute.route(
            events: [PullRequestEvent(type: .ciFailed, prId: "PR_1")],
            pullRequests: [pullRequest]
        )

        XCTAssertEqual(route, .openPullRequest(pullRequest.url))
        XCTAssertEqual(route.userInfo[NotificationClickRoute.actionKey], NotificationClickRoute.openPullRequestAction)
        XCTAssertEqual(route.userInfo[NotificationClickRoute.pullRequestURLKey], pullRequest.url.absoluteString)
    }

    func testNotificationClickRouteOpensNotificationsForMultipleEvents() {
        let route = NotificationClickRoute.route(
            events: [
                PullRequestEvent(type: .newComment, prId: "PR_1"),
                PullRequestEvent(type: .ciFailed, prId: "PR_2")
            ],
            pullRequests: [
                makePullRequest(id: "PR_1", url: "https://github.com/example/mergehawk/pull/1"),
                makePullRequest(id: "PR_2", url: "https://github.com/example/mergehawk/pull/2")
            ]
        )

        XCTAssertEqual(route, .openNotifications)
        XCTAssertEqual(route.userInfo[NotificationClickRoute.actionKey], NotificationClickRoute.openNotificationsAction)
        XCTAssertNil(route.userInfo[NotificationClickRoute.pullRequestURLKey])
    }

    func testNotificationClickRouteOpensNotificationsWhenPullRequestIsMissing() {
        let route = NotificationClickRoute.route(
            events: [PullRequestEvent(type: .ciFailed, prId: "missing")],
            pullRequests: [makePullRequest(id: "PR_1", url: "https://github.com/example/mergehawk/pull/42")]
        )

        XCTAssertEqual(route, .openNotifications)
    }

    func testNotificationClickRouteParsesMalformedUserInfoSafely() {
        XCTAssertEqual(NotificationClickRoute(userInfo: [:]), .openNotifications)
        XCTAssertEqual(
            NotificationClickRoute(userInfo: [NotificationClickRoute.actionKey: "unknown"]),
            .openNotifications
        )
        XCTAssertEqual(
            NotificationClickRoute(userInfo: [
                NotificationClickRoute.actionKey: NotificationClickRoute.openPullRequestAction,
                NotificationClickRoute.pullRequestURLKey: "not a url"
            ]),
            .openNotifications
        )
    }

    func testNotificationContentIncludesActorsAndCapsGroupedActorSummary() {
        let pullRequest = makePullRequest(id: "PR_1", url: "https://github.com/example/mergehawk/pull/42")
        let events = [
            PullRequestEvent(
                type: .newComment,
                prId: "PR_1",
                count: 1,
                actorLogin: "alice",
                activityId: "COMMENT_1"
            ),
            PullRequestEvent(
                type: .reviewApproved,
                prId: "PR_1",
                count: 1,
                actorLogin: "bob",
                activityId: "REVIEW_1"
            ),
            PullRequestEvent(
                type: .reviewCommented,
                prId: "PR_1",
                count: 1,
                actorLogin: "carol",
                activityId: "REVIEW_2"
            ),
            PullRequestEvent(
                type: .changesRequested,
                prId: "PR_1",
                count: 1,
                actorLogin: "dina",
                activityId: "REVIEW_3"
            )
        ]

        let records = NotificationContentBuilder.records(events: events, pullRequests: [pullRequest])

        XCTAssertEqual(records.map(\.title), [
            "New comment from @alice",
            "Approved by @bob",
            "Review comment from @carol",
            "Changes requested by @dina"
        ])
        XCTAssertEqual(records.map(\.actorLogin), ["alice", "bob", "carol", "dina"])
        XCTAssertTrue(
            NotificationContentBuilder.summaryBody(
                for: events,
                pullRequests: [pullRequest]
            ).contains("From @alice, @bob, @carol, ...")
        )
    }

    func testRecordingNotificationClientWritesJsonLines() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mergehawk-notifications-\(UUID().uuidString)")
        let logURL = directory.appendingPathComponent("notifications.jsonl")
        let client = RecordingNotificationClient(logPath: logURL.path)
        let pullRequest = makePullRequest(id: "PR_1", url: "https://github.com/example/mergehawk/pull/42")

        client.post(
            events: [
                PullRequestEvent(
                    type: .newComment,
                    prId: "PR_1",
                    count: 1,
                    actorLogin: "alice",
                    activityId: "COMMENT_1"
                )
            ],
            pullRequests: [pullRequest]
        )

        let payload = try String(contentsOf: logURL)
        XCTAssertTrue(payload.contains(#""title":"New comment from @alice""#))
        XCTAssertTrue(payload.contains(#""actorLogin":"alice""#))
        XCTAssertTrue(payload.contains(#""eventType":"new_comment""#))
        XCTAssertTrue(payload.contains(#""repository":"example\/mergehawk""#))
        XCTAssertTrue(payload.contains(#""clickAction":"open_pull_request""#))
        XCTAssertTrue(payload.contains(#""clickPullRequestURL":"https:\/\/github.com\/example\/mergehawk\/pull\/42""#))
    }

    private func makePullRequest(id: String, url: String) -> PullRequest {
        PullRequest(
            id: id,
            title: "Make mock notifications testable",
            number: 42,
            url: URL(string: url)!,
            repo: "example/mergehawk",
            ciState: .failing,
            reviewDecision: .reviewRequired,
            commentCount: 3,
            reviewCount: 0,
            isMine: true,
            author: "agent",
            mergeable: .mergeable,
            draft: false
        )
    }

    private func waitUntil(timeout: TimeInterval, condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

private final class RecordingURLOpener {
    private(set) var urls: [URL] = []

    func open(_ url: URL) {
        urls.append(url)
    }
}
