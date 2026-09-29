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
        XCTAssertEqual(PullRequestNotificationActivity.allCases, [.reviewActivity, .ciFailures, .relationshipChanges])
        XCTAssertEqual(
            PullRequestNotificationActivity.allCases.map(\.rowTitle),
            ["Review decisions", "CI failed", "Assigned or requested"]
        )
        XCTAssertEqual(CommentNotificationMode.allCases.map(\.title), ["All comments", "Mentions & threads you joined", "Off"])
        XCTAssertEqual(
            PullRequestNotificationRelationship.allCases.map(\.columnTitle),
            ["Authored", "Assigned", "Direct", "Team"]
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
                    !(relationship == .authored && activity == .relationshipChanges),
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
            PullRequestNotificationActivity.allCases.map { "\(PullRequestNotificationRelationship.directReviewRequest.title) \($0.accessibilityTitle)" },
            [
                "Direct review requests review decisions",
                "Direct review requests CI failures",
                "Direct review requests assigned or requested",
            ]
        )
        XCTAssertEqual(NotificationMatrixLayout.tableWidth, 414)
        XCTAssertEqual(
            PullRequestNotificationRelationship.allCases.map(NotificationMatrixLayout.relationshipColumnLeadingX(for:)),
            [160, 226, 292, 358]
        )
        XCTAssertEqual(
            NotificationMatrixLayout.relationshipColumnLeadingX(for: .teamReviewRequest) + NotificationMatrixLayout.relationshipColumnWidth,
            NotificationMatrixLayout.tableWidth
        )
        XCTAssertEqual(
            NotificationMatrixLayout.reviewRequestedSpanLeadingX,
            NotificationMatrixLayout.relationshipColumnLeadingX(for: .directReviewRequest)
        )
        XCTAssertEqual(
            NotificationMatrixLayout.reviewRequestedSpanLeadingX + NotificationMatrixLayout.reviewRequestedSpanWidth,
            NotificationMatrixLayout.relationshipColumnLeadingX(for: .teamReviewRequest) + NotificationMatrixLayout.relationshipColumnWidth
        )
        // The grouped form insets leave well under the 500pt window for both tables.
        XCTAssertLessThanOrEqual(NotificationMatrixLayout.tableWidth, SettingsTab.defaultWindowSize.width - 80)
    }

    @MainActor
    func testCommentRadioGroupStacksModesTopToBottomInTheRelationshipColumn() {
        let rowHeight = NotificationMatrixLayout.commentModeRowHeight
        let group = CommentModeRadioGroup.RadioGroupView(frame: CGRect(
            x: 0,
            y: 0,
            width: NotificationMatrixLayout.relationshipColumnWidth,
            height: rowHeight * CGFloat(CommentNotificationMode.allCases.count)
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
            XCTAssertEqual(button.frame.midY, (CGFloat(button.tag) + 0.5) * rowHeight, accuracy: 1, "tag \(button.tag)")
        }
        // Flipped, so tag 0 sits in the top slot.
        XCTAssertTrue(group.isFlipped)
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
