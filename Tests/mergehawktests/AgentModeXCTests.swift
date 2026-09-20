@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

final class AgentModeXCTests: XCTestCase {
    func testMockPullRequestDatesUseOneStableReferenceAcrossRefreshes() async throws {
        let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)
        let source = MockPullRequestSource(referenceDate: referenceDate)
        let first = try await source.fetchCompletePullRequests(login: "agent-fixture", previousState: nil)
        let second = try await source.fetchCompletePullRequests(login: "agent-fixture", previousState: nil)
        let firstDates = Dictionary(uniqueKeysWithValues: first.activePullRequests.map {
            ($0.id, [$0.createdAt, $0.updatedAt])
        })
        let secondDates = Dictionary(uniqueKeysWithValues: second.activePullRequests.map {
            ($0.id, [$0.createdAt, $0.updatedAt])
        })

        XCTAssertEqual(firstDates.count, 7)
        XCTAssertEqual(secondDates, firstDates)
        for pullRequest in first.activePullRequests {
            XCTAssertLessThanOrEqual(pullRequest.createdAt, pullRequest.updatedAt)
            XCTAssertLessThanOrEqual(pullRequest.updatedAt, referenceDate)
        }

        func ageUnits(for dates: [Date]) -> Set<String> {
            Set(dates.map { date in
                switch referenceDate.timeIntervalSince(date) {
                case ..<3_600: "minutes"
                case ..<86_400: "hours"
                case ..<604_800: "days"
                case ..<2_592_000: "weeks"
                default: "months"
                }
            })
        }
        let expectedUnits: Set<String> = ["minutes", "hours", "days", "weeks", "months"]
        XCTAssertEqual(ageUnits(for: first.activePullRequests.map(\.createdAt)), expectedUnits)
        XCTAssertEqual(ageUnits(for: first.activePullRequests.map(\.updatedAt)), expectedUnits)
    }

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
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk"],
                environment: ["MERGEHAWK_MOCK_REFRESH_DELAY_SECONDS": "3"]
            ),
            LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: false,
                mockRefreshDelaySeconds: 3
            )
        )
    }

    func testMockModeStartsSignedInWithoutToken() async {
        let suiteName = "mergehawk-mock-mode-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferencesStore = PreferencesStore(defaults: defaults)
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
                controller.state.syncedAt != nil && !controller.isRefreshing
            }
        }

        await MainActor.run {
            XCTAssertEqual(controller.state.authStatus, .signedIn)
            XCTAssertEqual(controller.state.source, .mock)
            XCTAssertEqual(controller.state.account?.login, "agent-fixture")
            XCTAssertEqual(controller.state.pullRequests.map(\.id), ["PR_1", "PR_4", "PR_6", "PR_2", "PR_3", "PR_7", "PR_5"])
            let requests = controller.state.pullRequests
            let byId = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
            XCTAssertEqual(Set(requests.map(\.reviewDecision)), [.noReviewYet, .approved, .changesRequested, .unknown])
            XCTAssertEqual(Set(requests.map(\.ciState)), [.passing, .failing, .pending, .unknown])
            XCTAssertEqual(Set(requests.map(\.mergeable)), [.mergeable, .conflicting, .unknown])
            XCTAssertGreaterThanOrEqual(requests.filter { $0.mergeable == .unknown }.count, 2)
            XCTAssertEqual(byId["PR_1"]?.additions, 0)
            XCTAssertEqual(byId["PR_1"]?.deletions, 0)
            XCTAssertEqual(byId["PR_3"]?.additions, 1_200_000)
            XCTAssertEqual(byId["PR_3"]?.deletions, 0)
            XCTAssertNil(byId["PR_6"]?.additions)
            XCTAssertNil(byId["PR_7"]?.deletions)
            XCTAssertTrue((byId["PR_4"]?.title.count ?? 0) > 100)
            XCTAssertTrue((byId["PR_5"]?.title.count ?? 0) > 100)
            XCTAssertTrue((byId["PR_3"]?.headRefName.count ?? 0) > 70)
            XCTAssertEqual(byId["PR_2"]?.reviewRequestKind, .direct)
            XCTAssertEqual(byId["PR_3"]?.reviewRequestKind, .team)
            XCTAssertEqual(byId["PR_5"]?.reviewRequestKind, .directAndTeam)
            XCTAssertEqual(byId["PR_7"]?.isAssignedToViewer, true)
            XCTAssertEqual(byId["PR_1"]?.draft, true)
            XCTAssertFalse(controller.startsAtLogin)
        }

        await MainActor.run {
            controller.refresh()
        }
        await waitUntil(timeout: 1.0) {
            notificationClient.records.isEmpty == false
        }
        XCTAssertEqual(
            notificationClient.records.map(\.eventType),
            ["ci_failed", "new_comment", "relationship_added"]
        )
        await MainActor.run {
            XCTAssertGreaterThanOrEqual(controller.state.pullRequests.filter { $0.mergeable == .unknown }.count, 2)
        }
    }

    func testMockRefreshDelayKeepsRefreshIndicatorActive() async {
        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                launchConfiguration: LaunchConfiguration(
                    usesMockData: true,
                    suppressesMacOSNotifications: true,
                    mockRefreshDelaySeconds: 0.05
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
            controller.refresh()
        }
        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                controller.isRefreshing
            }
        }

        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                !controller.isRefreshing
            }
        }
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

    func testNotificationMatrixSuppressesHistoryAndMacOSNotificationsThroughStateEvents() async {
        let suiteName = "mergehawk-notification-matrix-suppression-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        var mutablePreferencesStore = PreferencesStore(defaults: defaults)
        mutablePreferencesStore.notificationPreferences = NotificationPreferences(
            authored: .disabled,
            assigned: .disabled,
            directReviewRequests: .disabled,
            teamReviewRequests: .disabled
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
                controller.visiblePullRequestNotifications.count == 3
            }
        }

        await MainActor.run {
            // PR_3 remains team-only across refresh, so no relationship-added row appears for it.
            XCTAssertEqual(controller.attentionCount, 3)
            XCTAssertTrue(controller.hasAttention)
            XCTAssertEqual(
                controller.visiblePullRequestNotifications.map(\.url).first,
                URL(string: "https://github.com/mergehawk-labs/desktop-app/pull/27")
            )

            controller.markPullRequestNotificationRead(controller.visiblePullRequestNotifications[0])
            XCTAssertEqual(controller.visiblePullRequestNotifications.count, 3)
            XCTAssertEqual(controller.attentionCount, 2)

            controller.markAllNotificationsRead()
            XCTAssertEqual(controller.visiblePullRequestNotifications.count, 3)
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
            XCTAssertEqual(restoredController.visiblePullRequestNotifications.count, 3)
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
                [
                    .relationshipAdded,
                    .newComment,
                    .reviewApproved,
                    .reviewCommented,
                    .ciFailed,
                    .changesRequested
                ]
            )
            XCTAssertEqual(controller.visiblePullRequestNotifications.count, 7)
            XCTAssertTrue(
                controller.visiblePullRequestNotifications
                    .map { PullRequestNotificationTitlePresentation.title(for: $0) }
                    .contains("New comment from @frontend-sam")
            )
            XCTAssertTrue(
                controller.visiblePullRequestNotifications
                    .map { PullRequestNotificationTitlePresentation.title(for: $0) }
                    .contains("Assigned/requested")
            )
            XCTAssertTrue(
                controller.visiblePullRequestNotifications
                    .map { PullRequestNotificationTitlePresentation.title(for: $0) }
                    .contains("Assigned to you")
            )
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
                ),
                "billing-platform-experiments": OwnerSourcePreferences(
                    notifications: false,
                    myPullRequests: true,
                    reviewRequests: true
                ),
                "customer-success-platform": OwnerSourcePreferences(
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

    func testNotificationContentIncludesRelationshipChangeTitlesAndMetadata() {
        let pullRequest = makePullRequest(id: "PR_1", url: "https://github.com/example/mergehawk/pull/42")
        let events = [
            PullRequestEvent(
                type: .relationshipAdded,
                prId: "PR_1",
                relationshipChanges: [.assigned]
            ),
            PullRequestEvent(
                type: .relationshipAdded,
                prId: "PR_1",
                relationshipChanges: [.directReviewRequest]
            ),
            PullRequestEvent(
                type: .relationshipAdded,
                prId: "PR_1",
                relationshipChanges: [.assigned, .teamReviewRequest]
            )
        ]

        let records = NotificationContentBuilder.records(events: events, pullRequests: [pullRequest])

        XCTAssertEqual(records.map(\.title), [
            "Assigned to you",
            "Review requested",
            "Assigned/requested"
        ])
        XCTAssertEqual(records[0].relationshipChanges, ["assigned"])
        XCTAssertEqual(records[1].relationshipChanges, ["direct_review_request"])
        XCTAssertEqual(records[2].relationshipChanges, ["assigned", "team_review_request"])
    }

    func testNotificationContentIncludesOtherCommitTitles() {
        let pullRequest = makePullRequest(id: "PR_1", url: "https://github.com/example/mergehawk/pull/42")
        let events = [
            PullRequestEvent(
                type: .otherCommitAdded,
                prId: "PR_1",
                count: 1,
                actorLogin: "frontend-sam"
            ),
            PullRequestEvent(
                type: .otherCommitAdded,
                prId: "PR_1",
                count: 2
            ),
            PullRequestEvent(
                type: .otherCommitAdded,
                prId: "PR_1",
                count: 1
            )
        ]

        let records = NotificationContentBuilder.records(events: events, pullRequests: [pullRequest])

        XCTAssertEqual(records.map(\.title), [
            "New commit by @frontend-sam",
            "2 commits by others",
            "New commit by someone else"
        ])
        XCTAssertEqual(records.map(\.count), [1, 2, 1])
        XCTAssertEqual(records.map(\.eventType), ["other_commit_added", "other_commit_added", "other_commit_added"])
        XCTAssertEqual(records[0].actorLogin, "frontend-sam")
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
            reviewDecision: .noReviewYet,
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
