@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

final class PreferencesStoreTests: XCTestCase {
    func testBotNotificationPreferenceDefaultsOffAndPersistsSeparatelyFromMatrix() {
        withStore { store, defaults in
            XCTAssertFalse(store.muteBotNotifications)
            let matrix = NotificationPreferences(authored: .disabled, assigned: .enabled, directReviewRequests: .enabled, teamReviewRequests: .disabled)
            store.notificationPreferences = matrix
            for enabled in [true, false] {
                store.muteBotNotifications = enabled
                let reopened = PreferencesStore(defaults: defaults)
                XCTAssertEqual(reopened.muteBotNotifications, enabled)
                XCTAssertEqual(reopened.notificationPreferences, matrix)
            }
        }
    }

    func testScalarPreferencesPersistAndInvalidValuesFallBack() {
        withStore { store, defaults in
            XCTAssertEqual(store.refreshIntervalMinutes, 2)
            XCTAssertEqual(store.pullRequestSortOption, .createdDate)
            XCTAssertEqual(store.reviewRequestSortOption, .createdDate)
            XCTAssertEqual(store.reviewRequestSortDirection, .descending)
            XCTAssertEqual(store.authMethod, .oauth)

            store.refreshIntervalMinutes = 10
            store.pullRequestSortOption = .updatedDate
            store.authMethod = .pat
            XCTAssertEqual(store.refreshIntervalMinutes, 10)
            XCTAssertEqual(store.pullRequestSortOption, .updatedDate)
            XCTAssertEqual(store.authMethod, .pat)

            defaults.set(3, forKey: "refresh.intervalMinutes")
            defaults.set("unsupported", forKey: "pullRequests.sortOption")
            defaults.set("unsupported", forKey: "auth.method")
            XCTAssertEqual(store.refreshIntervalMinutes, 2)
            XCTAssertEqual(store.pullRequestSortOption, .createdDate)
            XCTAssertEqual(store.authMethod, .oauth)
        }
    }

    func testChangeSizeSortPreferenceRoundTrips() {
        withStore { store, defaults in
            store.pullRequestSortOption = .changeSize
            store.pullRequestSortDirection = .ascending
            store.reviewRequestSortOption = .updatedDate
            store.reviewRequestSortDirection = .descending

            let reopened = PreferencesStore(defaults: defaults)
            XCTAssertEqual(reopened.pullRequestSortOption, .changeSize)
            XCTAssertEqual(reopened.pullRequestSortDirection, .ascending)
            XCTAssertEqual(reopened.reviewRequestSortOption, .updatedDate)
            XCTAssertEqual(reopened.reviewRequestSortDirection, .descending)

            defaults.set("unsupported", forKey: "reviewRequests.sortOption")
            defaults.set("unsupported", forKey: "reviewRequests.sortDirection")
            XCTAssertEqual(reopened.reviewRequestSortOption, .createdDate)
            XCTAssertEqual(reopened.reviewRequestSortDirection, .descending)
        }
    }

    func testFilterSelectionsSerializeInStableOrderAndIgnoreUnsupportedValues() {
        withStore { store, defaults in
            store.selectedPullRequestFilters = [.ciFailing, .needsAttention]
            store.selectedReviewRequestFilters = [.draft, .ready]

            XCTAssertEqual(
                defaults.stringArray(forKey: "pullRequests.filterOptions"),
                ["needsAttention", "ciFailing"]
            )
            XCTAssertEqual(
                defaults.stringArray(forKey: "reviewRequests.filterOptions"),
                ["draft", "ready"]
            )

            defaults.set(["unsupported", "all", "draft"], forKey: "pullRequests.filterOptions")
            defaults.set(
                ["unsupported", "all", "direct", "team", "assigned", "ready"],
                forKey: "reviewRequests.filterOptions"
            )
            XCTAssertEqual(store.selectedPullRequestFilters, [.draft])
            XCTAssertEqual(store.selectedReviewRequestFilters, [.ready])

            defaults.removeObject(forKey: "reviewRequests.filterOptions")
            defaults.set("assigned", forKey: "reviewRequests.filterOption")
            XCTAssertTrue(store.selectedReviewRequestFilters.isEmpty)
        }
    }

    func testPinnedAndHiddenIdentifiersPersistNormalizedSets() {
        withStore { store, defaults in
            store.pinnedPullRequestIds = ["pr-3", "pr-1", "pr-2"]
            store.hiddenPullRequestIds = ["pr-2", "pr-1"]
            XCTAssertEqual(defaults.stringArray(forKey: "pullRequests.pinnedIds"), ["pr-1", "pr-2", "pr-3"])
            XCTAssertEqual(defaults.stringArray(forKey: "pullRequests.hiddenIds"), ["pr-1", "pr-2"])

            defaults.set(["pr-1", "", "  ", "pr-1", "pr-4"], forKey: "pullRequests.pinnedIds")
            XCTAssertEqual(store.pinnedPullRequestIds, ["pr-1", "pr-4"])
        }
    }

    @MainActor
    func testTurnedOffReviewTeamIDsPersistAcrossStoresAndControllers() {
        let suiteName = "mergehawk-review-teams-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.turnedOffReviewTeamIDs, [])
        store.turnedOffReviewTeamIDs = ["T_PLM", "T_DEV"]
        XCTAssertEqual(defaults.stringArray(forKey: "reviewTeams.turnedOffIds"), ["T_DEV", "T_PLM"])
        XCTAssertEqual(PreferencesStore(defaults: defaults).turnedOffReviewTeamIDs, ["T_DEV", "T_PLM"])

        func makeController() -> DashboardController {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: defaults),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0
            )
        }
        let controller = makeController()
        XCTAssertEqual(controller.turnedOffReviewTeamIDs, ["T_DEV", "T_PLM"])
        controller.setReviewTeam("T_PLM", counting: true)
        controller.setReviewTeam("T_ENG", counting: false)

        XCTAssertEqual(makeController().turnedOffReviewTeamIDs, ["T_DEV", "T_ENG"])
    }

    func testSourcePreferencesAndCatalogRoundTripThroughSerializedDefaults() {
        withStore { store, defaults in
            let preferences = SourcePreferences(
                owners: [
                    "example": OwnerSourcePreferences(
                        notifications: false,
                        myPullRequests: true,
                        reviewRequests: false
                    )
                ],
                repositories: [
                    "example/app": RepositorySourcePreferences(
                        notifications: .enabled,
                        myPullRequests: .disabled,
                        reviewRequests: .inherit
                    )
                ]
            )
            let catalog = SourceCatalog(
                repositories: [
                    RepositorySource(owner: "example", name: "app"),
                    RepositorySource(owner: "example", name: "mergehawk"),
                ],
                accountLogin: "rw"
            )
            store.sourcePreferences = preferences
            store.sourceCatalog = catalog

            let restored = PreferencesStore(defaults: defaults)
            XCTAssertEqual(restored.sourcePreferences, preferences)
            XCTAssertEqual(restored.sourceCatalog, catalog)
            XCTAssertNotNil(defaults.data(forKey: "sources.preferences"))
            XCTAssertNotNil(defaults.data(forKey: "sources.catalog"))
        }
    }

    func testHideArchivedRepositoriesDefaultsOnAndPersistsExplicitChoices() {
        withStore { store, defaults in
            XCTAssertTrue(store.hideArchivedRepositories)
            XCTAssertNil(defaults.object(forKey: "sources.hideArchivedRepositories"))
            store.hideArchivedRepositories = false
            XCTAssertFalse(PreferencesStore(defaults: defaults).hideArchivedRepositories)
            store.hideArchivedRepositories = true
            XCTAssertTrue(PreferencesStore(defaults: defaults).hideArchivedRepositories)
        }
    }

    func testNotificationPreferencesRoundTripThroughSerializedDefaults() {
        withStore { store, defaults in
            let preferences = NotificationPreferences(
                authored: PullRequestNotificationActivityPreferences(
                    reviewActivity: false,
                    ciFailures: true
                ),
                assigned: PullRequestNotificationActivityPreferences(
                    reviewActivity: true,
                    ciFailures: false,
                    relationshipChanges: false,
                    readyForReview: true
                ),
                directReviewRequests: PullRequestNotificationActivityPreferences(
                    reviewActivity: true,
                    ciFailures: false,
                    relationshipChanges: true,
                    readyForReview: false
                ),
                teamReviewRequests: .disabled,
                commentModes: CommentNotificationPreferences(
                    authored: .off, assigned: .mentionsAndThreads, directReviewRequests: .all, teamReviewRequests: .off
                )
            )
            store.notificationPreferences = preferences
            let stored = defaults.data(forKey: "notifications.prMatrix")

            XCTAssertEqual(PreferencesStore(defaults: defaults).notificationPreferences, preferences)
            XCTAssertEqual(PreferencesStore(defaults: defaults).loadAndPersistNotificationPreferences(), preferences)
            XCTAssertNotNil(stored)
            XCTAssertEqual(defaults.data(forKey: "notifications.prMatrix"), stored)
        }
    }

    func testNotificationDefaultsEnableReadyForReviewForRequestedRelationshipsOnly() {
        withStore { store, _ in
            let preferences = store.loadAndPersistNotificationPreferences()

            XCTAssertEqual(preferences, .defaults)
            XCTAssertEqual(preferences.authored, PullRequestNotificationActivityPreferences(
                reviewActivity: true, ciFailures: true, relationshipChanges: false, readyForReview: false
            ))
            for requested in [preferences.assigned, preferences.directReviewRequests, preferences.teamReviewRequests] {
                XCTAssertEqual(requested, PullRequestNotificationActivityPreferences(
                    reviewActivity: false, ciFailures: false, relationshipChanges: true, readyForReview: true
                ))
            }
            XCTAssertEqual(preferences.commentModes, .defaults)
        }
    }

    func testCoherentSyncStateRoundTripsDashboardHistoryAndProcessedActivity() throws {
        try withThrowingStore { store, defaults in
            let pullRequest = Self.pullRequest()
            let notification = PullRequestNotification(
                event: PullRequestEvent(type: .newComment, prId: pullRequest.id, activityId: "COMMENT_1"),
                pullRequest: pullRequest
            )
            let state = PullRequestSyncState(
                account: GitHubAccount(login: "rw"),
                dashboard: DashboardState(
                    pullRequests: [pullRequest],
                    events: [],
                    syncedAt: Date(timeIntervalSince1970: 10),
                    source: .github,
                    account: GitHubAccount(login: "rw"),
                    authStatus: .signedIn
                ),
                processedActivityByPullRequestID: [
                    pullRequest.id: ProcessedPullRequestActivity(
                        pullRequestID: pullRequest.id,
                        commentIDs: ["COMMENT_1"],
                        submittedReviewIDs: ["REVIEW_1"]
                    )
                ],
                notificationHistory: [notification]
            )

            try store.storePullRequestSyncState(state)

            XCTAssertEqual(PreferencesStore(defaults: defaults).pullRequestSyncState, state)
        }
    }

    func testArchiveMetadataRoundTripsSyncStateAndLegacyPRsRemainReadable() throws {
        try withThrowingStore { store, defaults in
            for archived in [true, false] {
                let pullRequest = Self.pullRequest(repositoryIsArchived: archived)
                let state = PullRequestSyncState(
                    account: GitHubAccount(login: "rw"),
                    dashboard: DashboardState(
                        pullRequests: [pullRequest], events: [], syncedAt: Date(timeIntervalSince1970: 10),
                        source: .github, account: GitHubAccount(login: "rw"), authStatus: .signedIn
                    ),
                    processedActivityByPullRequestID: [:]
                )
                try store.storePullRequestSyncState(state)
                XCTAssertEqual(PreferencesStore(defaults: defaults).pullRequestSyncState?.dashboard.pullRequests.first?.repositoryIsArchived, archived)
            }

            let unknown = Self.pullRequest()
            XCTAssertNil(unknown.repositoryIsArchived)
            let encoded = try JSONEncoder().encode(unknown)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: "repositoryIsArchived")
            let legacy = try JSONDecoder().decode(PullRequest.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(legacy.repositoryIsArchived)
            XCTAssertNil(try JSONDecoder().decode(PullRequest.self, from: JSONEncoder().encode(unknown)).repositoryIsArchived)
            XCTAssertEqual(Self.pullRequest(repositoryIsArchived: true).withoutActivityHistory.repositoryIsArchived, true)
        }
    }

    func testLegacySnapshotImportTreatsActivityThroughItsFetchTimeAsProcessed() {
        withStore { store, _ in
            let pullRequest = Self.pullRequest()
            let notification = PullRequestNotification(
                event: PullRequestEvent(type: .reviewApproved, prId: pullRequest.id, activityId: "REVIEW_1"),
                pullRequest: pullRequest
            )
            store.pullRequestSnapshotCache = PullRequestSnapshotCache(
                pullRequests: [pullRequest],
                account: GitHubAccount(login: "rw"),
                fetchedAt: Date(timeIntervalSince1970: 10),
                source: .github
            )
            store.pullRequestNotificationHistory = [notification]

            let imported = store.importedLegacySyncState()

            XCTAssertEqual(imported?.dashboard.pullRequests, [pullRequest])
            XCTAssertEqual(imported?.notificationHistory, [notification])
            XCTAssertEqual(imported?.processedActivityByPullRequestID, [
                pullRequest.id: ProcessedPullRequestActivity(
                    pullRequestID: pullRequest.id,
                    commentIDs: Set(pullRequest.recentCommentActivities.map(\.id)),
                    submittedReviewIDs: Set(pullRequest.recentReviews.map(\.id)),
                    processedThrough: Date(timeIntervalSince1970: 10)
                )
            ])
        }
    }

    func testPreFeatureRawSnapshotImportsAndQuietlyBaselinesMentionMembership() throws {
        try withThrowingStore { store, defaults in
            let date = Date(timeIntervalSince1970: 5)
            var pullRequest = Self.pullRequest()
            pullRequest.recentCommentActivities = [
                PullRequestCommentActivity(
                    id: "C1", url: URL(string: "https://github.com/example/app/pull/1#issuecomment-C1")!,
                    author: "teammate", createdAt: date, source: .reviewThread, reviewId: "R1"
                )
            ]
            pullRequest.recentReviews = [
                PullRequestReview(
                    id: "R1", url: URL(string: "https://github.com/example/app/pull/1#pullrequestreview-R1")!,
                    state: .commented, submittedAt: date, author: "teammate"
                )
            ]
            let notification = PullRequestNotification(
                event: PullRequestEvent(type: .reviewCommented, prId: pullRequest.id, activityId: "R1"),
                pullRequest: pullRequest,
                createdAt: date
            )
            let newKeys: Set<String> = [
                "publishedAt", "updatedAt", "threadId", "mentionsViewer", "hasSummaryText", "commentReason"
            ]
            // Only activity and history objects gained keys; a pull request's own updatedAt predates the feature.
            func stripped(_ value: Any) -> Any {
                if let object = value as? [String: Any] {
                    let isActivity = object["viewerDidAuthor"] != nil || object["eventType"] != nil
                    return object.filter { !isActivity || !newKeys.contains($0.key) }.mapValues(stripped)
                }
                if let array = value as? [Any] { return array.map(stripped) }
                return value
            }
            func rawData<T: Encodable>(_ value: T) throws -> Data {
                try JSONSerialization.data(withJSONObject: stripped(JSONSerialization.jsonObject(with: JSONEncoder().encode(value))))
            }
            defaults.set(try rawData(PullRequestSnapshotCache(
                pullRequests: [pullRequest], account: GitHubAccount(login: "rw"),
                fetchedAt: Date(timeIntervalSince1970: 10), source: .github
            )), forKey: "pullRequests.snapshotCache")
            defaults.set(try rawData([notification]), forKey: "notifications.prHistory")

            let imported = try XCTUnwrap(store.importedLegacySyncState())

            XCTAssertEqual(imported.notificationHistory, [notification])
            XCTAssertNil(imported.notificationHistory[0].commentReason)
            let comment = try XCTUnwrap(imported.dashboard.pullRequests.first?.recentCommentActivities.first)
            XCTAssertEqual(comment.publishedAt, date)
            XCTAssertNil(comment.threadId)
            XCTAssertFalse(comment.mentionsViewer)
            XCTAssertEqual(imported.dashboard.pullRequests.first?.recentReviews.first?.hasSummaryText, false)
            let processed = try XCTUnwrap(imported.processedActivityByPullRequestID[pullRequest.id])
            XCTAssertNil(processed.mentioningActivityIDs)

            var mentioned = pullRequest
            mentioned.recentCommentActivities = [
                PullRequestCommentActivity(
                    id: "C1", url: comment.url, author: "teammate", createdAt: date, source: .reviewThread,
                    reviewId: "R1", updatedAt: Date(timeIntervalSince1970: 20), threadId: "T1", mentionsViewer: true
                )
            ]
            XCTAssertTrue(PRActivityDetector.detectProcessedPeopleActivity(previous: processed, current: mentioned).isEmpty)
            XCTAssertEqual(PRActivityDetector.processedActivity(for: mentioned).mentioningActivityIDs, ["C1"])
        }
    }

    func testLegacySnapshotWithoutFetchTimeImportsNoProcessedBaseline() {
        withStore { store, _ in
            store.pullRequestSnapshotCache = PullRequestSnapshotCache(
                pullRequests: [Self.pullRequest()],
                account: GitHubAccount(login: "rw"),
                fetchedAt: nil,
                source: .github
            )

            XCTAssertEqual(store.importedLegacySyncState()?.processedActivityByPullRequestID, [:])
        }
    }

    func testStoringSyncStateRetiresLegacySnapshotAndHistory() throws {
        try withThrowingStore { store, _ in
            let pullRequest = Self.pullRequest()
            store.pullRequestSnapshotCache = PullRequestSnapshotCache(
                pullRequests: [pullRequest],
                account: GitHubAccount(login: "rw"),
                fetchedAt: Date(timeIntervalSince1970: 10),
                source: .github
            )
            store.pullRequestNotificationHistory = [PullRequestNotification(
                event: PullRequestEvent(type: .newComment, prId: pullRequest.id, activityId: "C1"),
                pullRequest: pullRequest
            )]
            let imported = try XCTUnwrap(store.importedLegacySyncState())

            try store.storePullRequestSyncState(imported)
            store.clearPullRequestSyncState()

            XCTAssertEqual(store.pullRequestSnapshotCache, .empty)
            XCTAssertTrue(store.pullRequestNotificationHistory.isEmpty)
            XCTAssertNil(store.importedLegacySyncState())
        }
    }

    private func withStore(_ body: (inout PreferencesStore, UserDefaults) -> Void) {
        let suiteName = "mergehawk-preferences-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        var store = PreferencesStore(defaults: defaults)
        body(&store, defaults)
    }

    private func withThrowingStore(
        _ body: (inout PreferencesStore, UserDefaults) throws -> Void
    ) throws {
        let suiteName = "mergehawk-preferences-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var store = PreferencesStore(defaults: defaults)
        try body(&store, defaults)
    }

    private static func pullRequest(repositoryIsArchived: Bool? = nil) -> PullRequest {
        PullRequest(
            id: "PR_1",
            title: "Persist refresh state",
            number: 1,
            url: URL(string: "https://github.com/example/app/pull/1")!,
            repo: "example/app",
            repositoryIsArchived: repositoryIsArchived,
            ciState: .passing,
            reviewDecision: .approved,
            commentCount: 0,
            reviewCount: 0,
            isMine: true,
            author: "rw",
            mergeable: .mergeable,
            draft: false
        )
    }
}
