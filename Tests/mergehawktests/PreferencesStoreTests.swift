@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

final class PreferencesStoreTests: XCTestCase {
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

    func testNotificationPreferencesRoundTripThroughSerializedDefaults() {
        withStore { store, defaults in
            let preferences = NotificationPreferences(
                authored: PullRequestNotificationActivityPreferences(
                    comments: true,
                    reviewActivity: false,
                    ciFailures: true
                ),
                assigned: PullRequestNotificationActivityPreferences(
                    comments: false,
                    reviewActivity: true,
                    ciFailures: false
                ),
                directReviewRequests: PullRequestNotificationActivityPreferences(
                    comments: true,
                    reviewActivity: true,
                    ciFailures: false
                ),
                teamReviewRequests: .disabled
            )
            store.notificationPreferences = preferences

            XCTAssertEqual(PreferencesStore(defaults: defaults).notificationPreferences, preferences)
            XCTAssertNotNil(defaults.data(forKey: "notifications.prMatrix"))
        }
    }

    func testRetiredCommitNotificationHistoryStillRoundTripsAndRenders() {
        withStore { store, defaults in
            let pullRequest = PullRequest(
                id: "legacy-commit-pr",
                title: "Legacy commit notification",
                number: 42,
                url: URL(string: "https://github.com/example/app/pull/42")!,
                repo: "example/app",
                ciState: .passing,
                reviewDecision: .noReviewYet,
                commentCount: 0,
                reviewCount: 0,
                isMine: true,
                author: "rw",
                mergeable: .mergeable,
                draft: false
            )
            var notification = PullRequestNotification(
                event: PullRequestEvent(
                    type: .otherCommitAdded,
                    prId: pullRequest.id,
                    count: 1,
                    actorLogin: "teammate"
                ),
                pullRequest: pullRequest
            )
            notification.read = true
            store.pullRequestNotificationHistory = [notification]

            let restored = PreferencesStore(defaults: defaults).pullRequestNotificationHistory
            XCTAssertEqual(restored, [notification])
            XCTAssertTrue(restored[0].read)
            XCTAssertEqual(PullRequestNotificationTitlePresentation.title(for: restored[0]), "New commit by @teammate")
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
