@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

final class PreferencesStoreTests: XCTestCase {
    func testScalarPreferencesPersistAndInvalidValuesFallBack() {
        withStore { store, defaults in
            XCTAssertEqual(store.refreshIntervalMinutes, 2)
            XCTAssertEqual(store.pullRequestSortOption, .createdDate)
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

    private func withStore(_ body: (inout PreferencesStore, UserDefaults) -> Void) {
        let suiteName = "mergehawk-preferences-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        var store = PreferencesStore(defaults: defaults)
        body(&store, defaults)
    }
}
