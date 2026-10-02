import AppKit
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

    @MainActor
    func testReviewTeamRowsGroupByOrganizationWithInheritedViaLabelsAndCounts() async throws {
        let suite = "settings-review-teams-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(
                usesMockData: true,
                suppressesMacOSNotifications: true,
                mockPullRequestScenario: .reviewTeams
            ),
            automaticRefreshInterval: 0
        )
        let deadline = Date().addingTimeInterval(1)
        while controller.state.syncedAt == nil || controller.isRefreshing, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .teams(let groups) = ReviewTeamsSettingsPresentation.content(
            authStatus: controller.state.authStatus,
            rows: controller.reviewTeamRows
        ) else {
            return XCTFail("Expected team rows")
        }
        XCTAssertEqual(groups.map(\.organization), ["mergehawk-labs"])
        XCTAssertEqual(groups[0].rows.map(\.team.displayName), [
            "@mergehawk-labs/developers", "@mergehawk-labs/engineering", "@mergehawk-labs/plm-team",
            "@mergehawk-labs/secret-squad"
        ])
        XCTAssertEqual(groups[0].rows.map(ReviewTeamsSettingsPresentation.detailLines(for:)), [
            ["via @mergehawk-labs/plm-team", "4 PRs requesting this team"],
            ["via @mergehawk-labs/plm-team", "1 PR requesting this team"],
            ["2 PRs requesting this team"],
            ["0 PRs requesting this team"],
        ])
        // Inherited rows get room for their extra line; four rows here overflow the cap and scroll.
        XCTAssertEqual(groups[0].rows.map(ReviewTeamsSettingsLayout.rowHeight(for:)), [52, 52, 38, 38])
        XCTAssertEqual(ReviewTeamsSettingsLayout.listHeight(for: groups), ReviewTeamsSettingsLayout.maximumListHeight)
        XCTAssertEqual(
            ReviewTeamsSettingsLayout.headerTrailingInset(for: groups, scrollerStyle: .legacy),
            NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        )
        XCTAssertEqual(ReviewTeamsSettingsLayout.headerTrailingInset(for: groups, scrollerStyle: .overlay), 0)
        let singleGroup = [ReviewTeamsSettingsPresentation.OrganizationGroup(organization: "mergehawk-labs", rows: [groups[0].rows[2]])]
        XCTAssertEqual(ReviewTeamsSettingsLayout.listHeight(for: singleGroup), 64)
        XCTAssertEqual(ReviewTeamsSettingsLayout.headerTrailingInset(for: singleGroup, scrollerStyle: .legacy), 0)

        let acme = TeamReference(id: "T_ACME", organization: "acme", slug: "reviewers")
        let zeta = TeamReference(id: "T_ZETA", organization: "zeta", slug: "ops")
        let platform = TeamReference(id: "T_PLATFORM", organization: "zeta", slug: "platform")
        let rows = [
            DashboardController.ReviewTeamRow(team: acme, inheritedVia: nil, isCounting: true, pullRequestCount: 1),
            DashboardController.ReviewTeamRow(team: zeta, inheritedVia: platform, isCounting: false, pullRequestCount: 0),
            DashboardController.ReviewTeamRow(team: platform, inheritedVia: nil, isCounting: true, pullRequestCount: 3),
        ]
        XCTAssertEqual(
            ReviewTeamsSettingsPresentation.content(authStatus: .signedIn, rows: rows),
            .teams([
                .init(organization: "acme", rows: [rows[0]]),
                .init(organization: "zeta", rows: [rows[1], rows[2]]),
            ])
        )
    }

    @MainActor
    func testSetReviewTeamFlipsTheTurnedOffSetBothWays() {
        let suite = "settings-review-team-toggle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0
        )

        controller.setReviewTeam("T_DEV", counting: false)
        XCTAssertEqual(controller.turnedOffReviewTeamIDs, ["T_DEV"])
        controller.setReviewTeam("T_DEV", counting: false)
        XCTAssertEqual(controller.turnedOffReviewTeamIDs, ["T_DEV"])
        controller.setReviewTeam("T_DEV", counting: true)
        XCTAssertEqual(controller.turnedOffReviewTeamIDs, [])
        XCTAssertEqual(PreferencesStore(defaults: defaults).turnedOffReviewTeamIDs, [])
    }

    func testReviewTeamsBlockIsHiddenSignedOutAndReportsNoTeamsSignedIn() {
        let row = DashboardController.ReviewTeamRow(
            team: TeamReference(id: "T", organization: "acme", slug: "reviewers"),
            inheritedVia: nil,
            isCounting: true,
            pullRequestCount: 0
        )

        XCTAssertEqual(ReviewTeamsSettingsPresentation.content(authStatus: .signedOut, rows: []), .hidden)
        XCTAssertEqual(ReviewTeamsSettingsPresentation.content(authStatus: .signedOut, rows: [row]), .hidden)
        XCTAssertEqual(ReviewTeamsSettingsPresentation.content(authStatus: .signedIn, rows: []), .noTeams)
        XCTAssertEqual(ReviewTeamsSettingsPresentation.noTeamsText, "You're not in any GitHub teams.")
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
