@testable import mergehawk
import mergehawkcore
import XCTest

final class SettingsViewTests: XCTestCase {
    func testSourceCatalogSearchTrimsAndMatchesOwnerRepositoryOrCombinedName() {
        let catalog = makeCatalog()

        XCTAssertEqual(sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "")), [
            "acme/mergehawk",
            "acme/website",
            "openai/codex",
            "openai/swift-tools",
        ])
        XCTAssertEqual(sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "  OPENAI\n")), [
            "openai/codex",
            "openai/swift-tools",
        ])
        XCTAssertEqual(
            sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "merge")),
            ["acme/mergehawk"]
        )
        XCTAssertEqual(
            sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "acme/web")),
            ["acme/website"]
        )
    }

    func testSourceCatalogSearchReportsEmptyResultsAndCountsFilteredSources() {
        let catalog = makeCatalog()
        let missing = SourceCatalogSearch.filteredCatalog(catalog, query: "missing")
        let filtered = SourceCatalogSearch.filteredCatalog(catalog, query: "merge")

        XCTAssertTrue(missing.owners.isEmpty)
        XCTAssertEqual(SourceCatalogSearch.sourceCount(catalog), 4)
        XCTAssertEqual(SourceCatalogSearch.sourceCount(filtered), 1)
        XCTAssertEqual(SourceCatalogSearch.sourceCount(SourceCatalog(repositories: [], accountLogin: "rw")), 0)
        XCTAssertEqual(CountSearchPresentation.countLabel(for: 1, singular: "source", plural: "sources"), "1 source")
        XCTAssertEqual(CountSearchPresentation.countLabel(for: 4, singular: "source", plural: "sources"), "4 sources")
    }

    func testNotificationMatricesUseTheAgreedColumnsAndFitTheSettingsWindow() {
        XCTAssertEqual(PullRequestNotificationActivity.allCases, [.reviewActivity, .ciFailures, .relationshipChanges])
        XCTAssertEqual(PullRequestNotificationActivity.allCases.map(\.columnTitle), ["Review decisions", "CI failed", "Assigned/\nRequested"])
        XCTAssertEqual(CommentNotificationMode.allCases.map(\.title), ["All comments", "Mentions & threads you joined", "Off"])
        for relationship in PullRequestNotificationRelationship.allCases {
            XCTAssertEqual(
                NotificationMatrixLayout.showsToggle(relationship: relationship, activity: .relationshipChanges),
                relationship != .authored
            )
            XCTAssertTrue(NotificationMatrixLayout.showsToggle(relationship: relationship, activity: .reviewActivity))
            XCTAssertTrue(NotificationMatrixLayout.showsToggle(relationship: relationship, activity: .ciFailures))
        }
        XCTAssertEqual(
            PullRequestNotificationRelationship.allCases.map(NotificationMatrixLayout.commentModeAccessibilityLabel(for:)),
            [
                "Authored PRs comment notifications",
                "Assigned PRs comment notifications",
                "Direct review requests comment notifications",
                "Team review requests comment notifications",
            ]
        )
        XCTAssertEqual(PullRequestNotificationActivity.allCases.map(NotificationMatrixLayout.activityColumnWidth(for:)), [86, 60, 88])
        XCTAssertEqual(CommentNotificationMode.allCases.map(NotificationMatrixLayout.commentModeColumnWidth(for:)), [78, 110, 40])
        func rowWidth(_ columns: [CGFloat]) -> CGFloat {
            NotificationMatrixLayout.relationshipColumnWidth + columns.reduce(0, +)
                + NotificationMatrixLayout.columnSpacing * CGFloat(columns.count)
        }
        // The grouped form insets leave well under the 500pt window for either matrix.
        XCTAssertLessThanOrEqual(rowWidth([86, 60, 88]), SettingsTab.defaultWindowSize.width - 80)
        XCTAssertLessThanOrEqual(rowWidth([78, 110, 40]), SettingsTab.defaultWindowSize.width - 80)
    }

    @MainActor
    func testChangingOneCommentRowKeepsEveryOtherRowAndSetting() {
        let suite = "settings-comment-modes-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            notificationClient: RecordingNotificationClient(),
            automaticRefreshInterval: 0
        )
        controller.muteBotNotifications = true
        controller.macOSLocalNotificationsEnabled = false
        controller.preferences.teamReviewRequests.ciFailures = true
        for relationship in PullRequestNotificationRelationship.allCases {
            for mode in CommentNotificationMode.allCases {
                let before = controller.preferences
                controller.preferences.commentModes.set(mode, for: relationship)
                var expected = before
                expected.commentModes.set(mode, for: relationship)
                XCTAssertEqual(controller.preferences, expected)
                XCTAssertEqual(controller.preferences.commentModes.mode(for: relationship), mode)
                XCTAssertEqual(PreferencesStore(defaults: defaults).notificationPreferences, expected)
            }
        }
        XCTAssertTrue(PreferencesStore(defaults: defaults).muteBotNotifications)
        XCTAssertFalse(PreferencesStore(defaults: defaults).macOSLocalNotificationsEnabled)
        XCTAssertTrue(PreferencesStore(defaults: defaults).notificationPreferences.teamReviewRequests.ciFailures)
    }

    private func makeCatalog() -> SourceCatalog {
        SourceCatalog(owners: [
            OwnerSource(owner: "acme", repositories: [
                RepositorySource(owner: "acme", name: "mergehawk"),
                RepositorySource(owner: "acme", name: "website"),
            ]),
            OwnerSource(owner: "openai", repositories: [
                RepositorySource(owner: "openai", name: "codex"),
                RepositorySource(owner: "openai", name: "swift-tools"),
            ]),
        ])
    }

    private func sourceCatalogEntries(_ catalog: SourceCatalog) -> [String] {
        catalog.owners.flatMap { owner in
            owner.repositories.map(\.identity.nameWithOwner)
        }
    }
}
