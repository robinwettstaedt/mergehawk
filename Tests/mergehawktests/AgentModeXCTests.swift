@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

final class AgentModeXCTests: XCTestCase {
    func testBotScenarioUsesCommittedBaselineAndDoesNotReplayAfterSourceRestart() async throws {
        let source = MockPullRequestSource(scenario: .botNotifications)
        let engine = SyncEngine(source: source, loginProvider: { "agent-fixture" })
        let baseline = try await engine.prepare(previousState: nil)
        XCTAssertTrue(baseline.events.isEmpty)
        XCTAssertEqual(baseline.activePullRequests.count, 2)
        XCTAssertTrue(baseline.activePullRequests.allSatisfy { $0.recentCommentActivities.isEmpty && $0.recentReviews.isEmpty })
        func committed(_ prepared: PreparedPullRequestRefresh) -> PullRequestSyncState {
            PullRequestSyncState(account: prepared.account, dashboard: DashboardState(pullRequests: prepared.activePullRequests.map(\.withoutActivityHistory), events: [], syncedAt: prepared.syncedAt, source: .mock, account: prepared.account, authStatus: .signedIn), processedActivityByPullRequestID: prepared.processedActivityByPullRequestID)
        }
        let batch = try await engine.prepare(previousState: committed(baseline))
        XCTAssertEqual(batch.events.count, 12)
        XCTAssertEqual(batch.events.filter { $0.event.actorIsBot == true }.count, 10)
        XCTAssertEqual(batch.events.filter { $0.event.actorIsBot == false }.count, 2)
        XCTAssertEqual(batch.activePullRequests.map(\.reviewDecision), baseline.activePullRequests.map(\.reviewDecision))
        XCTAssertEqual(batch.activePullRequests.map(\.commentCount), baseline.activePullRequests.map(\.commentCount))
        let state = committed(batch)
        let repeatedBatch = try await engine.prepare(previousState: state)
        XCTAssertTrue(repeatedBatch.events.isEmpty)
        let restarted = SyncEngine(source: MockPullRequestSource(scenario: .botNotifications), loginProvider: { "agent-fixture" })
        let repeated = try await restarted.prepare(previousState: state)
        XCTAssertTrue(repeated.events.isEmpty)
        XCTAssertEqual(repeated.processedActivityByPullRequestID, state.processedActivityByPullRequestID)
    }

    func testCommentScenarioProducesExactUpdatesAcrossBaselineUpdatesEditAndRepeat() async throws {
        let engine = SyncEngine(source: MockPullRequestSource(scenario: .commentNotifications), loginProvider: { "agent-fixture" })
        var state: PullRequestSyncState?
        var allowedByStage: [[String]] = []
        var emittedByStage: [Set<String>] = []
        for _ in 0..<4 {
            let prepared = try await engine.prepare(previousState: state)
            emittedByStage.append(Set(prepared.events.compactMap(\.event.activityId)))
            allowedByStage.append(prepared.events
                .filter { NotificationPreferences.defaults.allows(event: $0.event, for: $0.filteringContext) }
                .compactMap(\.event.activityId))
            state = PullRequestSyncState(
                account: prepared.account,
                dashboard: DashboardState(pullRequests: prepared.activePullRequests.map(\.withoutActivityHistory), events: [], syncedAt: prepared.syncedAt, source: .mock, account: prepared.account, authStatus: .signedIn),
                processedActivityByPullRequestID: prepared.processedActivityByPullRequestID
            )
        }

        XCTAssertEqual(emittedByStage[0], [])
        XCTAssertEqual(emittedByStage[1], [
            "COMMENT_AUTHORED_NEW", "REVIEW_AUTHORED_APPROVAL", "INLINE_AUTHORED_1", "INLINE_AUTHORED_2",
            "COMMENT_ASSIGNED_NEW", "REPLY_DIRECT_JOINED", "COMMENT_DIRECT_UNRELATED", "INLINE_DIRECT_MENTION",
            "COMMENT_TEAM_UNRELATED", "REVIEW_TEAM_SUMMARY_MENTION",
        ])
        XCTAssertEqual(Set(allowedByStage[1]), [
            "COMMENT_AUTHORED_NEW", "REVIEW_AUTHORED_APPROVAL", "INLINE_AUTHORED_1", "INLINE_AUTHORED_2",
            "COMMENT_ASSIGNED_NEW", "REPLY_DIRECT_JOINED", "INLINE_DIRECT_MENTION", "REVIEW_TEAM_SUMMARY_MENTION",
        ])
        XCTAssertEqual(allowedByStage[1].count, 8)
        XCTAssertEqual(allowedByStage[2], ["COMMENT_TEAM_EDITED"])
        XCTAssertEqual(emittedByStage[2], ["COMMENT_TEAM_EDITED"])
        XCTAssertEqual(emittedByStage[3], [])
    }

    @MainActor
    func testCommentScenarioRecordsReasonRowsAndPayloadsInTheMockApp() async {
        let suite = "comment-scenario-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifications = RecordingNotificationClient()
        let controller = DashboardController(tokenStore: InMemoryTokenStore(), preferencesStore: PreferencesStore(defaults: defaults), launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true, mockPullRequestScenario: .commentNotifications), notificationClient: notifications, automaticRefreshInterval: 0)
        await waitUntil(timeout: 1) { await MainActor.run { controller.state.syncedAt != nil && !controller.isRefreshing } }
        XCTAssertTrue(controller.pullRequestNotificationHistory.isEmpty)
        for expected in [8, 9, 9] {
            controller.refresh()
            await waitUntil(timeout: 1) { await MainActor.run { controller.pullRequestNotificationHistory.count == expected && !controller.isRefreshing } }
        }
        XCTAssertEqual(controller.pullRequestNotificationHistory.count, 9)
        let reasons = Dictionary(uniqueKeysWithValues: controller.pullRequestNotificationHistory.compactMap { row in
            row.activityId.map { ($0, row.commentReason) }
        })
        XCTAssertEqual(reasons["REPLY_DIRECT_JOINED"], .threadParticipation)
        XCTAssertEqual(reasons["INLINE_DIRECT_MENTION"], .mention)
        XCTAssertEqual(reasons["REVIEW_TEAM_SUMMARY_MENTION"], .mention)
        XCTAssertEqual(reasons["COMMENT_TEAM_EDITED"], .mention)
        XCTAssertEqual(reasons["COMMENT_ASSIGNED_NEW"], .general)
        XCTAssertEqual(reasons["REVIEW_AUTHORED_APPROVAL"], .some(nil))
        XCTAssertEqual(notifications.records.count, 9)
        XCTAssertEqual(notifications.records.last?.title, "@docs-lee mentioned you")
        XCTAssertEqual(notifications.records.last?.clickDestinationURL, "https://github.com/mergehawk-labs/mergehawk/pull/83#issuecomment-COMMENT_TEAM_EDITED")
        XCTAssertTrue(notifications.records.contains { $0.title == "@backend-mateo commented in a thread you joined" })
    }

    func testLongListsScenarioReturnsOverflowingListsThenNewCommentActivity() async throws {
        let source = MockPullRequestSource(scenario: .longLists)
        let first = try await source.fetchCompletePullRequests(login: "agent-fixture", previousState: nil).activePullRequests
        XCTAssertEqual(first.filter(\.isMine).count, 20)
        let requested = first.filter { !$0.isMine }
        XCTAssertEqual(requested.count, 20)
        XCTAssertGreaterThan(Set(requested.compactMap(DashboardController.RequestedSection.section(for:))).count, 1)
        XCTAssertTrue(first.allSatisfy { $0.recentCommentActivities.isEmpty })

        let second = try await source.fetchCompletePullRequests(login: "agent-fixture", previousState: nil).activePullRequests
        XCTAssertEqual(second.map(\.id), first.map(\.id))
        XCTAssertTrue(second.allSatisfy { $0.recentCommentActivities.count == 1 })
    }

    @MainActor
    func testLongListsScenarioFillsNotificationHistoryAfterOneRefresh() async {
        let suite = "long-lists-scenario-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DashboardController(tokenStore: InMemoryTokenStore(), preferencesStore: PreferencesStore(defaults: defaults), launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true, mockPullRequestScenario: .longLists), notificationClient: RecordingNotificationClient(), automaticRefreshInterval: 0)
        await waitUntil(timeout: 1) { await MainActor.run { controller.state.syncedAt != nil && !controller.isRefreshing } }
        XCTAssertTrue(controller.visiblePullRequestNotifications.isEmpty)
        controller.refresh()
        await waitUntil(timeout: 1) { await MainActor.run { controller.visiblePullRequestNotifications.count > 8 && !controller.isRefreshing } }
        XCTAssertGreaterThan(controller.visiblePullRequestNotifications.count, 8)
    }

    @MainActor
    func testFreshBotScenarioRunsRespectMuteAndRecordedPayloads() async {
        for muted in [false, true] {
            let suite = "bot-scenario-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var preferences = PreferencesStore(defaults: defaults)
            preferences.muteBotNotifications = muted
            let notifications = RecordingNotificationClient()
            let controller = DashboardController(tokenStore: InMemoryTokenStore(), preferencesStore: preferences, launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true, mockPullRequestScenario: .botNotifications), notificationClient: notifications, automaticRefreshInterval: 0)
            await waitUntil(timeout: 1) { await MainActor.run { controller.state.syncedAt != nil && !controller.isRefreshing } }
            XCTAssertTrue(controller.pullRequestNotificationHistory.isEmpty)
            controller.refresh()
            await waitUntil(timeout: 1) { await MainActor.run { controller.pullRequestNotificationHistory.count == (muted ? 2 : 12) && !controller.isRefreshing } }
            XCTAssertEqual(controller.attentionCount, muted ? 2 : 12)
            XCTAssertEqual(controller.isUnreadPullRequest(controller.state.pullRequests.first { $0.id == "PR_BOT_NOTIFICATIONS_ONLY" }!), !muted)
            XCTAssertEqual(Set(notifications.records.map(\.pullRequestId)), muted ? ["PR_BOT_NOTIFICATIONS_MIXED"] : ["PR_BOT_NOTIFICATIONS_MIXED", "PR_BOT_NOTIFICATIONS_ONLY"])
            if muted { XCTAssertTrue(notifications.records.allSatisfy { !$0.body.contains("mergehawk-helper") && !$0.title.contains("mergehawk-helper") }) }
        }
    }

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
            teamReviewRequests: .disabled,
            commentModes: CommentNotificationPreferences(
                authored: .off, assigned: .off, directReviewRequests: .off, teamReviewRequests: .off
            )
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
                // The newest actual activity is the mergehawk PR comment; relationship changes fall back to sync time.
                URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/14")
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
                    .changesRequested,
                    .newReview,
                    .otherCommitAdded
                ]
            )
            XCTAssertEqual(controller.visiblePullRequestNotifications.count, 9)
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
            XCTAssertTrue(
                controller.visiblePullRequestNotifications
                    .map { PullRequestNotificationTitlePresentation.title(for: $0) }
                    .contains("New review from @qa-rin")
            )
            XCTAssertTrue(
                controller.visiblePullRequestNotifications
                    .map { PullRequestNotificationTitlePresentation.title(for: $0) }
                    .contains("New commit by @teammate-kai")
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

    func testMockRefreshFailurePreservesExistingDashboardAndEmitsNothing() async {
        let suiteName = "mergehawk-mock-failure-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferencesStore = PreferencesStore(defaults: defaults)
        let notifications = RecordingNotificationClient()
        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: preferencesStore,
                launchConfiguration: LaunchConfiguration(
                    usesMockData: true,
                    suppressesMacOSNotifications: true,
                    mockPullRequestScenario: .refreshFailure
                ),
                notificationClient: notifications,
                automaticRefreshInterval: 0
            )
        }
        await waitUntil(timeout: 1) {
            await MainActor.run { controller.state.syncedAt != nil && !controller.isRefreshing }
        }
        let baseline = await MainActor.run { controller.state }

        await MainActor.run { controller.refresh() }
        await waitUntil(timeout: 1) {
            await MainActor.run { controller.refreshErrorMessage != nil && !controller.isRefreshing }
        }

        await MainActor.run {
            XCTAssertEqual(controller.state, baseline)
            XCTAssertEqual(controller.refreshErrorMessage, MockPullRequestError.refreshFailed.localizedDescription)
        }
        XCTAssertTrue(notifications.records.isEmpty)
    }

    func testMockMergedFinalActivityAndQuietAccessLossAreDeterministic() async {
        for scenario in [MockPullRequestScenario.mergedFinalActivity, .quietAccessLoss] {
            let suiteName = "mergehawk-mock-retirement-test-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let preferencesStore = PreferencesStore(defaults: defaults)
            let notifications = RecordingNotificationClient()
            let controller = await MainActor.run {
                DashboardController(
                    tokenStore: InMemoryTokenStore(),
                    preferencesStore: preferencesStore,
                    launchConfiguration: LaunchConfiguration(
                        usesMockData: true,
                        suppressesMacOSNotifications: true,
                        mockPullRequestScenario: scenario
                    ),
                    notificationClient: notifications,
                    automaticRefreshInterval: 0
                )
            }
            await waitUntil(timeout: 1) {
                await MainActor.run { controller.state.pullRequests.count == 1 && !controller.isRefreshing }
            }
            await MainActor.run { controller.refresh() }
            await waitUntil(timeout: 1) {
                await MainActor.run { controller.state.pullRequests.isEmpty && !controller.isRefreshing }
            }

            if scenario == .mergedFinalActivity {
                await MainActor.run {
                    XCTAssertEqual(
                        Set(controller.pullRequestNotificationHistory.map(\.activityId)),
                        ["PR_SCENARIO_FINAL_COMMENT", "PR_SCENARIO_FINAL_REVIEW"]
                    )
                }
                XCTAssertEqual(Set(notifications.records.map(\.eventType)), ["new_comment", "review_approved"])
            } else {
                await MainActor.run {
                    XCTAssertTrue(controller.pullRequestNotificationHistory.isEmpty)
                }
                XCTAssertTrue(notifications.records.isEmpty)
            }
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testNotificationClickRouteOpensSingleMatchingPullRequest() {
        let pullRequest = makePullRequest(id: "PR_1", url: "https://github.com/example/mergehawk/pull/42")
        let route = NotificationClickRoute.route(
            events: [PullRequestEvent(type: .ciFailed, prId: "PR_1")],
            pullRequests: [pullRequest]
        )

        XCTAssertEqual(route, .openPullRequest(PullRequestOpenRequest(pullRequestURL: pullRequest.url)))
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
