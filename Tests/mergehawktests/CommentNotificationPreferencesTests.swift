@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

@MainActor
final class CommentNotificationPreferencesTests: XCTestCase {
    private let matrixKey = "notifications.prMatrix"

    func testMissingModesArePersistedAsDefaultsWithoutAnyEdit() throws {
        try withDefaults { defaults in
            _ = makeController(defaults)

            let stored = try storedMatrixObject(defaults)
            XCTAssertEqual(stored["commentModes"] as? [String: String], [
                "authored": "all",
                "assigned": "all",
                "directReviewRequests": "mentions_and_threads",
                "teamReviewRequests": "mentions_and_threads",
            ])
            XCTAssertEqual(PreferencesStore(defaults: defaults).notificationPreferences.commentModes, .defaults)
        }
    }

    func testPullRequestOneFormatMatrixLoadsDefaultsAndStaysStored() throws {
        try withDefaults { defaults in
            let stored = Data(Self.pullRequestOneFormatMatrixJSON.utf8)
            defaults.set(stored, forKey: matrixKey)

            for _ in 0..<2 {
                let controller = makeController(defaults)
                XCTAssertEqual(controller.preferences, .defaults)
                XCTAssertEqual(defaults.data(forKey: matrixKey), stored)
            }
        }
    }

    func testSettingsChangeAfterResetPersistsNewFormatAndReloads() throws {
        try withDefaults { defaults in
            defaults.set(Data(Self.pullRequestOneFormatMatrixJSON.utf8), forKey: matrixKey)
            let controller = makeController(defaults)

            controller.preferences.commentModes.set(.off, for: .directReviewRequest)

            let stored = try storedMatrixObject(defaults)
            for relationship in ["authored", "assigned", "directReviewRequests", "teamReviewRequests"] {
                XCTAssertNotNil((stored[relationship] as? [String: Any])?["readyForReview"], relationship)
            }
            var expected = NotificationPreferences.defaults
            expected.commentModes.directReviewRequests = .off
            XCTAssertEqual(makeController(defaults).preferences, expected)
        }
    }

    func testUnreadableStoredMatrixIsNotOverwrittenByInitialization() throws {
        try withDefaults { defaults in
            let invalid = Data("not a notification matrix".utf8)
            defaults.set(invalid, forKey: matrixKey)

            let controller = makeController(defaults)
            _ = PreferencesStore(defaults: defaults).loadAndPersistNotificationPreferences()

            XCTAssertEqual(controller.preferences, .defaults)
            XCTAssertEqual(defaults.data(forKey: matrixKey), invalid)
        }
    }

    func testExplicitModesSurviveReconstructingStoreAndController() throws {
        try withDefaults { defaults in
            let chosen = CommentNotificationPreferences(
                authored: .off,
                assigned: .mentionsAndThreads,
                directReviewRequests: .all,
                teamReviewRequests: .off
            )
            let controller = makeController(defaults)
            controller.preferences.commentModes = chosen

            for _ in 0..<2 {
                let reopened = makeController(defaults)
                XCTAssertEqual(reopened.preferences.commentModes, chosen)
                XCTAssertEqual(PreferencesStore(defaults: defaults).notificationPreferences.commentModes, chosen)
            }
        }
    }

    func testChangingOneRowPersistsOnlyThatModeAndLeavesOtherSettings() throws {
        try withDefaults { defaults in
            var store = PreferencesStore(defaults: defaults)
            store.muteBotNotifications = true
            store.macOSLocalNotificationsEnabled = false
            let sources = SourcePreferences(
                owners: ["acme": OwnerSourcePreferences(notifications: false, myPullRequests: true, reviewRequests: true)],
                repositories: [:]
            )
            store.sourcePreferences = sources
            let controller = makeController(defaults)
            let before = controller.preferences

            controller.preferences.commentModes.set(.off, for: .teamReviewRequest)

            let reopened = PreferencesStore(defaults: defaults)
            var expected = before
            expected.commentModes.teamReviewRequests = .off
            XCTAssertEqual(reopened.notificationPreferences, expected)
            XCTAssertTrue(reopened.muteBotNotifications)
            XCTAssertFalse(reopened.macOSLocalNotificationsEnabled)
            XCTAssertEqual(reopened.sourcePreferences, sources)
        }
    }

    func testInitializationKeepsExistingNotificationHistory() throws {
        try withDefaults { defaults in
            let pullRequest = PullRequest(
                id: "PR_1", title: "History", number: 1,
                url: URL(string: "https://github.com/acme/app/pull/1")!, repo: "acme/app",
                ciState: .passing, reviewDecision: .reviewRequired, commentCount: 0, reviewCount: 0,
                isMine: true, author: "rw", mergeable: .mergeable, draft: false
            )
            var notification = PullRequestNotification(
                event: PullRequestEvent(type: .newComment, prId: pullRequest.id, activityId: "C1"),
                pullRequest: pullRequest,
                createdAt: Date(timeIntervalSince1970: 5)
            )
            notification.read = true
            let account = GitHubAccount(login: "rw")
            let state = PullRequestSyncState(
                account: account,
                dashboard: DashboardState(
                    pullRequests: [pullRequest], events: [], syncedAt: Date(timeIntervalSince1970: 10),
                    source: .github, account: account, authStatus: .signedIn
                ),
                notificationHistory: [notification]
            )
            try PreferencesStore(defaults: defaults).storePullRequestSyncState(state)
            defaults.set(Data(Self.pullRequestOneFormatMatrixJSON.utf8), forKey: matrixKey)

            let controller = makeController(defaults)

            XCTAssertEqual(controller.pullRequestNotificationHistory, [notification])
            XCTAssertEqual(PreferencesStore(defaults: defaults).pullRequestSyncState?.notificationHistory, [notification])
        }
    }

    private func makeController(_ defaults: UserDefaults) -> DashboardController {
        DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            notificationClient: RecordingNotificationClient(),
            automaticRefreshInterval: 0
        )
    }

    private func storedMatrixObject(_ defaults: UserDefaults) throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: matrixKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "comment-preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    /// A matrix saved before Ready for review existed: every current key except `readyForReview`.
    private static let pullRequestOneFormatMatrixJSON = """
    {
      "authored": {"reviewActivity": false, "ciFailures": true, "relationshipChanges": false},
      "assigned": {"reviewActivity": true, "ciFailures": true, "relationshipChanges": true},
      "directReviewRequests": {"reviewActivity": false, "ciFailures": false, "relationshipChanges": true},
      "teamReviewRequests": {"reviewActivity": true, "ciFailures": false, "relationshipChanges": false},
      "commentModes": {
        "authored": "off", "assigned": "mentions_and_threads",
        "directReviewRequests": "all", "teamReviewRequests": "off"
      }
    }
    """
}
