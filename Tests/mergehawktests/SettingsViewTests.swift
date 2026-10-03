import AppKit
@testable import mergehawk
import mergehawkcore
import SwiftUI
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
