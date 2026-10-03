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
    func testTeamsTabGroupsTheTeamTreeByOrganizationWithCountsAndCheckboxesOn() async throws {
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
            "@mergehawk-labs/engineering", "@mergehawk-labs/developers", "@mergehawk-labs/plm-team",
            "@mergehawk-labs/secret-squad"
        ])
        XCTAssertEqual(groups[0].rows.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(groups[0].rows.map(ReviewTeamsSettingsPresentation.countLabel(for:)), [
            "1 PR", "4 PRs", "2 PRs", "0 PRs",
        ])
        XCTAssertTrue(groups[0].rows.allSatisfy(\.isCounting))
        // Mock teams have no avatar URLs, so the Teams tab shows placeholders and never loads images.
        XCTAssertTrue(groups[0].rows.allSatisfy { $0.avatarURL == nil && $0.organizationAvatarURL == nil })

        let acme = TeamReference(id: "T_ACME", organization: "acme", slug: "reviewers")
        let zeta = TeamReference(id: "T_ZETA", organization: "zeta", slug: "ops")
        let platform = TeamReference(id: "T_PLATFORM", organization: "zeta", slug: "platform")
        let zetaAvatar = URL(string: "https://avatars.githubusercontent.com/u/9?v=4")
        let platformAvatar = URL(string: "https://avatars.githubusercontent.com/t/1?s=64&v=4")
        let rows = [
            DashboardController.ReviewTeamRow(team: acme, depth: 0, isCounting: true, pullRequestCount: 1),
            DashboardController.ReviewTeamRow(
                team: platform, depth: 0, isCounting: true, pullRequestCount: 3,
                avatarURL: platformAvatar, organizationAvatarURL: zetaAvatar
            ),
            DashboardController.ReviewTeamRow(
                team: zeta, depth: 1, isCounting: false, pullRequestCount: 0, organizationAvatarURL: zetaAvatar
            ),
        ]
        let content = ReviewTeamsSettingsPresentation.content(authStatus: .signedIn, rows: rows)
        XCTAssertEqual(content, .teams([
            .init(organization: "acme", rows: [rows[0]]),
            .init(organization: "zeta", rows: [rows[1], rows[2]]),
        ]))
        guard case .teams(let builtGroups) = content else { return XCTFail("Expected team rows") }
        XCTAssertEqual(builtGroups.map(\.avatarURL), [nil, zetaAvatar])
        XCTAssertEqual(builtGroups[1].rows.map(\.avatarURL), [platformAvatar, nil])
        XCTAssertEqual(ReviewTeamsSettingsPresentation.listLabel, "Show review requests from these teams:")
    }

    @MainActor
    func testTeamsTabSitsBetweenSourcesAndAboutWithItsShortcut() {
        XCTAssertEqual(SettingsTab.allCases, [.general, .github, .notifications, .sources, .teams, .about])
        XCTAssertEqual(SettingsTab.teams.title, "Teams")
        XCTAssertEqual(SettingsTab.teams.systemImage, "person.3")
        // Tab shortcuts are ⌘ plus the tab's 1-based position, so About moves to ⌘6.
        XCTAssertEqual(SettingsTab.allCases.firstIndex(of: .about).map { $0 + 1 }, 6)
        let tabCount = CGFloat(SettingsTab.allCases.count)
        XCTAssertLessThanOrEqual(
            SettingsTabLayout.tabWidth * tabCount + SettingsTabLayout.tabSpacing * (tabCount - 1),
            SettingsTab.defaultWindowSize.width - 24
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

    func testTeamsTabReportsSignedOutAndNoTeamsStates() {
        let row = DashboardController.ReviewTeamRow(
            team: TeamReference(id: "T", organization: "acme", slug: "reviewers"),
            depth: 0,
            isCounting: true,
            pullRequestCount: 0
        )

        XCTAssertEqual(ReviewTeamsSettingsPresentation.content(authStatus: .signedOut, rows: []), .signedOut)
        XCTAssertEqual(ReviewTeamsSettingsPresentation.content(authStatus: .signedOut, rows: [row]), .signedOut)
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
