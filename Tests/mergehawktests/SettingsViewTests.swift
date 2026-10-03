import AppKit
@testable import mergehawk
import mergehawkcore
import SwiftUI
import XCTest

final class SettingsViewTests: XCTestCase {
    func testMenuSizeNoteExplainsTheMenuMayBeReduced() {
        XCTAssertEqual(GeneralMenuSizeCopy.reductionNote, "The menu may be reduced to fit smaller displays.")
    }

    func testGeneralFooterShortcutHintEndsAtTheLastSettingsTab() {
        XCTAssertEqual(GeneralShortcutHintCopy.lastTabShortcut, "⌘6")
        XCTAssertEqual(GeneralShortcutHintCopy.lastTabShortcut, "⌘\(SettingsTab.allCases.count)")
    }

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

    func testNotificationTablesUseTheAgreedRowsColumnsAndFitTheSettingsWindow() {
        XCTAssertEqual(
            PullRequestNotificationActivity.allCases,
            [.reviewActivity, .ciFailures, .relationshipChanges, .readyForReview]
        )
        XCTAssertEqual(
            PullRequestNotificationActivity.allCases.map(\.rowTitle),
            ["Review decisions", "CI failed", "New assignment or review request", "Ready for review"]
        )
        XCTAssertEqual(CommentNotificationMode.allCases.map(\.title), ["All comments", "Mentions & threads you joined", "Off"])
        XCTAssertEqual(
            PullRequestNotificationRelationship.allCases.map(\.columnTitle),
            ["Authored", "Assigned", "Direct\nrequest", "Team\nrequest"]
        )
        XCTAssertEqual(
            PullRequestNotificationRelationship.allCases.map(\.columnHelp),
            [
                "PRs you opened",
                "PRs assigned to you",
                "Your review was requested by name",
                "A team you belong to was requested",
            ]
        )
        for relationship in PullRequestNotificationRelationship.allCases {
            for activity in PullRequestNotificationActivity.allCases {
                XCTAssertEqual(
                    NotificationMatrixLayout.showsToggle(relationship: relationship, activity: activity),
                    !(relationship == .authored && [.relationshipChanges, .readyForReview].contains(activity)),
                    "\(relationship) \(activity)"
                )
            }
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
        XCTAssertEqual(
            PullRequestNotificationActivity.allCases.map {
                NotificationMatrixLayout.checkboxAccessibilityLabel(relationship: .directReviewRequest, activity: $0)
            },
            [
                "Direct review requests review decisions",
                "Direct review requests CI failures",
                "Direct review requests new assignment or review request",
                "Direct review requests ready for review",
            ]
        )
        XCTAssertEqual(
            PullRequestNotificationRelationship.allCases.map {
                NotificationMatrixLayout.checkboxAccessibilityLabel(relationship: $0, activity: .reviewActivity)
            },
            [
                "Authored PRs review decisions",
                "Assigned PRs review decisions",
                "Direct review requests review decisions",
                "Team review requests review decisions",
            ]
        )
        XCTAssertEqual(NotificationMatrixLayout.tableWidth, 414)
        // The grouped form insets leave well under the 500pt window for both tables.
        XCTAssertLessThanOrEqual(NotificationMatrixLayout.tableWidth, SettingsTab.defaultWindowSize.width - 80)
    }

    func testBothNotificationTablesShareARowHeightThatFitsATwoLineLabel() {
        // Both tables lay out every row at this height, so rows sit evenly spaced whether or not a label wraps.
        XCTAssertEqual(NotificationMatrixLayout.rowHeight, 32)
        XCTAssertEqual(NotificationMatrixLayout.rowSpacing, 8)
        // The radio groups span the comment label column: three rows and the two gaps between them.
        XCTAssertEqual(
            NotificationMatrixLayout.commentModeColumnHeight,
            3 * NotificationMatrixLayout.rowHeight + 2 * NotificationMatrixLayout.rowSpacing
        )
        XCTAssertEqual(NotificationMatrixLayout.commentModeColumnHeight, 112)
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        XCTAssertLessThanOrEqual(2 * NSLayoutManager().defaultLineHeight(for: bodyFont), NotificationMatrixLayout.rowHeight)
    }

    @MainActor
    func testCommentRadioGroupStacksModesTopToBottomInTheRelationshipColumn() {
        let rowHeight = NotificationMatrixLayout.rowHeight
        let rowPitch = rowHeight + NotificationMatrixLayout.rowSpacing
        let group = CommentModeRadioGroup.RadioGroupView(frame: CGRect(
            x: 0,
            y: 0,
            width: NotificationMatrixLayout.relationshipColumnWidth,
            height: NotificationMatrixLayout.commentModeColumnHeight
        ))
        // Added out of order so placement follows the tag, not the subview order.
        for tag in [2, 0, 1] {
            let button = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
            button.tag = tag
            group.addSubview(button)
        }
        group.layout()

        let buttons = group.subviews.compactMap { $0 as? NSButton }.sorted { $0.tag < $1.tag }
        XCTAssertEqual(buttons.map(\.tag), [0, 1, 2])
        for button in buttons {
            XCTAssertEqual(button.frame.midX, group.bounds.midX, accuracy: 1, "tag \(button.tag)")
            XCTAssertEqual(button.frame.midY, CGFloat(button.tag) * rowPitch + rowHeight / 2, accuracy: 1, "tag \(button.tag)")
        }
        // Flipped, so tag 0 sits in the top slot.
        XCTAssertTrue(group.isFlipped)
    }

    @MainActor
    func testMentionsRadioButtonsCarryTheCommentModeExplanation() {
        XCTAssertEqual(
            CommentNotificationMode.mentionsAndThreadsHelp,
            "Mentions & threads you joined covers direct mentions of you and new comments in review threads where your published comments are still present."
        )
        XCTAssertEqual(CommentNotificationMode.allCases.map(\.help), [nil, CommentNotificationMode.mentionsAndThreadsHelp, nil])

        for relationship in PullRequestNotificationRelationship.allCases {
            let host = NSHostingView(rootView: CommentModeRadioGroup(relationship: relationship, selection: .constant(.all)))
            host.frame = CGRect(
                x: 0,
                y: 0,
                width: NotificationMatrixLayout.relationshipColumnWidth,
                height: NotificationMatrixLayout.commentModeColumnHeight
            )
            host.layoutSubtreeIfNeeded()

            let buttons = radioButtons(in: host).sorted { $0.tag < $1.tag }
            XCTAssertEqual(buttons.count, CommentNotificationMode.allCases.count, "\(relationship)")
            let tooltips = CommentNotificationMode.allCases.map { "\(relationship.title): \($0.title)" }
            XCTAssertEqual(buttons.map(\.toolTip), tooltips, "\(relationship)")
            // AppKit reads a button's tooltip as its accessibility help unless the help is set explicitly.
            XCTAssertEqual(
                buttons.map { $0.accessibilityHelp() },
                zip(CommentNotificationMode.allCases, tooltips).map { mode, tooltip in mode.help ?? tooltip },
                "\(relationship)"
            )
        }
    }

    private func radioButtons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            (subview as? NSButton).map { [$0] } ?? radioButtons(in: subview)
        }
    }

    @MainActor
    func testCommentRadioGroupSelectsTheModeMatchingTheButtonTag() {
        var selection = CommentNotificationMode.off
        let coordinator = CommentModeRadioGroup.Coordinator(selection: Binding(get: { selection }, set: { selection = $0 }))
        for (index, mode) in CommentNotificationMode.allCases.enumerated() {
            let button = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
            button.tag = index
            coordinator.select(button)
            XCTAssertEqual(selection, mode)
        }
    }

    @MainActor
    func testChangingOneCheckboxKeepsEveryOtherCellAndSetting() {
        let (controller, defaults, suite) = makeNotificationSettingsController()
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = NotificationSettingsView(controller: controller)
        for relationship in PullRequestNotificationRelationship.allCases {
            for activity in PullRequestNotificationActivity.allCases
            where NotificationMatrixLayout.showsToggle(relationship: relationship, activity: activity) {
                let before = controller.preferences
                let binding = view.matrixBinding(relationship: relationship, activity: activity)
                let isEnabled = !binding.wrappedValue
                binding.wrappedValue = isEnabled

                for otherRelationship in PullRequestNotificationRelationship.allCases {
                    for otherActivity in PullRequestNotificationActivity.allCases {
                        let expected = otherRelationship == relationship && otherActivity == activity
                            ? isEnabled
                            : before.preferences(for: otherRelationship).allows(otherActivity)
                        XCTAssertEqual(
                            controller.preferences.preferences(for: otherRelationship).allows(otherActivity),
                            expected,
                            "toggling \(relationship) \(activity) changed \(otherRelationship) \(otherActivity)"
                        )
                    }
                }
                XCTAssertEqual(controller.preferences.commentModes, before.commentModes)
                XCTAssertEqual(PreferencesStore(defaults: defaults).notificationPreferences, controller.preferences)
            }
        }
        XCTAssertTrue(PreferencesStore(defaults: defaults).muteBotNotifications)
        XCTAssertFalse(PreferencesStore(defaults: defaults).macOSLocalNotificationsEnabled)
    }

    @MainActor
    func testChangingOneCommentModeKeepsEveryOtherModeAndSetting() {
        let (controller, defaults, suite) = makeNotificationSettingsController()
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = NotificationSettingsView(controller: controller)
        controller.preferences.teamReviewRequests.ciFailures = true
        for relationship in PullRequestNotificationRelationship.allCases {
            let coordinator = CommentModeRadioGroup.Coordinator(selection: view.commentModeBinding(for: relationship))
            for (index, mode) in CommentNotificationMode.allCases.enumerated() {
                let before = controller.preferences
                let button = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
                button.tag = index
                coordinator.select(button)
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
    }

    func testTeamsCaptionExplainsTheSwitchesWithoutSayingCount() {
        XCTAssertEqual(
            ReviewTeamsSettingsPresentation.caption,
            "Show review requests sent to these teams. A PR still appears if it reaches you another way."
        )
        XCTAssertFalse(ReviewTeamsSettingsPresentation.caption.localizedCaseInsensitiveContains("count"))
    }

    func testTeamsNotificationsLinkOpensTheNotificationsPane() {
        XCTAssertEqual(
            ReviewTeamsSettingsPresentation.notificationsLinkTitle,
            "Team review request notifications are set in Notifications ›"
        )
        XCTAssertEqual(ReviewTeamsSettingsPresentation.notificationsLinkDestination, .notifications)
    }

    func testTeamPullRequestNumberTooltipNamesTheFullTeam() {
        let row = DashboardController.ReviewTeamRow(
            team: TeamReference(id: "T", organization: "acme", slug: "reviewers"),
            depth: 0,
            isCounting: true,
            pullRequestCount: 2
        )
        XCTAssertEqual(
            ReviewTeamsSettingsPresentation.countHelp(for: row),
            "PRs requesting @acme/reviewers, including ones shown for another reason"
        )
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

    func testGitHubPaneIsTitledAuthAndKeepsItsSecondPosition() {
        XCTAssertEqual(SettingsTab.github.title, "Auth")
        // Still the second tab, so ⌘2 opens it.
        XCTAssertEqual(SettingsTab.allCases, [.general, .github, .notifications, .sources, .teams, .about])
        XCTAssertEqual(SettingsTab.allCases.firstIndex(of: .github).map { $0 + 1 }, 2)
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
    }

    func testTeamsSignedOutStateExplainsAndLinksToTheAuthPane() {
        XCTAssertEqual(ReviewTeamsSettingsPresentation.signedOutHeadline, "Sign in to see your teams")
        XCTAssertEqual(ReviewTeamsSettingsPresentation.signedOutDetail, "Then choose which teams' review requests show up.")
        XCTAssertEqual(OpenAuthSettingsLink.title, "Open Auth settings")
        XCTAssertEqual(OpenAuthSettingsLink.destination, .github)
    }

    func testTeamsNoTeamsStateExplainsWhenTeamsAppear() {
        XCTAssertEqual(ReviewTeamsSettingsPresentation.noTeamsHeadline, "No teams found")
        XCTAssertEqual(
            ReviewTeamsSettingsPresentation.noTeamsDetail,
            "Your GitHub teams appear here after the next successful refresh."
        )
    }

    @MainActor
    private func makeNotificationSettingsController() -> (DashboardController, UserDefaults, String) {
        let suite = "settings-notification-tables-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            notificationClient: RecordingNotificationClient(),
            automaticRefreshInterval: 0
        )
        controller.muteBotNotifications = true
        controller.macOSLocalNotificationsEnabled = false
        return (controller, defaults, suite)
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
