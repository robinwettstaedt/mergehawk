@testable import mergehawk
import AppKit
import Foundation
import mergehawkcore
import SwiftUI
import XCTest

final class MenuViewTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            // SwiftPM tests do not run NSApplicationMain. Initialize AppKit before
            // creating native menu hosts or keyboard events on a fresh CI runner.
            _ = NSApplication.shared
        }
    }

    @MainActor
    func testDropdownDismissalNeverCapturesHoverOrTheOriginalButton() {
        let view = DropdownOutsideClickNSView(frame: CGRect(x: 0, y: 0, width: 820, height: 600))
        view.isActive = true
        view.excludedBounds = [CGRect(x: 742, y: 80, width: 28, height: 28)]

        for type: NSEvent.EventType in [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged, .scrollWheel] {
            XCTAssertFalse(view.capturesClick(at: CGPoint(x: 400, y: 400), eventType: type))
        }
        // The glyph and its padded hit area continue reaching the original button.
        for point in [CGPoint(x: 756, y: 94), CGPoint(x: 743, y: 81), CGPoint(x: 769, y: 107)] {
            XCTAssertFalse(view.capturesClick(at: point, eventType: .leftMouseDown))
        }
        XCTAssertTrue(view.capturesClick(at: CGPoint(x: 400, y: 400), eventType: .leftMouseDown))
        XCTAssertFalse(view.capturesClick(at: CGPoint(x: 900, y: 400), eventType: .leftMouseDown))
    }

    @MainActor
    func testOpenDropdownLeavesOtherRowButtonsClickable() {
        let view = DropdownOutsideClickNSView(frame: CGRect(x: 0, y: 0, width: 820, height: 600))
        view.isActive = true
        view.excludedBounds = [
            CGRect(x: 742, y: 80, width: 28, height: 28),
            CGRect(x: 742, y: 132, width: 28, height: 28),
            CGRect(x: 742, y: 184, width: 28, height: 28)
        ]
        for point in [CGPoint(x: 756, y: 94), CGPoint(x: 756, y: 146), CGPoint(x: 756, y: 198)] {
            XCTAssertFalse(view.capturesClick(at: point, eventType: .leftMouseDown))
        }
        // Only the buttons pass through. Clicking a row's body or the gaps still dismisses.
        XCTAssertTrue(view.capturesClick(at: CGPoint(x: 700, y: 146), eventType: .leftMouseDown))
        XCTAssertTrue(view.capturesClick(at: CGPoint(x: 756, y: 120), eventType: .leftMouseDown))

        var state = PullRequestMenuDropdownState(openMenu: .actions("first"))
        state.toggle(.actions("second"))
        XCTAssertEqual(state.openMenu, .actions("second"))
        state.toggle(.actions("second"))
        XCTAssertNil(state.openMenu)
    }

    @MainActor
    func testOutsideClickImmediatelyReleasesListForFurtherMouseEvents() throws {
        let view = DropdownOutsideClickNSView(frame: CGRect(x: 0, y: 0, width: 820, height: 600))
        let point = CGPoint(x: 400, y: 400)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        var dismissCount = 0
        view.dismiss = { dismissCount += 1 }

        // Reopen/dismiss several times without replacing the view or moving out of the list.
        for _ in 0..<4 {
            view.isActive = true
            XCTAssertTrue(view.capturesClick(at: point, eventType: .leftMouseDown))
            view.mouseDown(with: click)
            XCTAssertFalse(view.isActive)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp, .mouseMoved, .mouseEntered, .mouseExited] {
                XCTAssertFalse(view.capturesClick(at: point, eventType: type))
            }
        }
        XCTAssertEqual(dismissCount, 4)
    }

    func testPanelSizeUsesPreferredWidthAndFitsUsableScreen() {
        let large = MenuPanelSize.resolve(availableFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        XCTAssertEqual(large.width, 820)
        XCTAssertEqual(large.height, MenuRootView.Layout.height)

        let laptopUsableFrame = CGRect(x: 0, y: 28, width: 1280, height: 740)
        let laptop = MenuPanelSize.resolve(availableFrame: laptopUsableFrame)
        XCTAssertEqual(laptop.width, 820)
        XCTAssertLessThan(laptop.height, MenuRootView.Layout.height)
        XCTAssertLessThanOrEqual(laptop.height + MenuPanelSize.margin * 2, laptopUsableFrame.height)
        XCTAssertGreaterThan(laptop.height, MenuRootView.Layout.footerHeight + MenuRootView.Layout.topBarHeight)

        let narrow = MenuPanelSize.resolve(availableFrame: CGRect(x: 0, y: 0, width: 760, height: 600))
        XCTAssertLessThanOrEqual(narrow.width + MenuPanelSize.margin * 2, 760)
        XCTAssertLessThanOrEqual(narrow.height + MenuPanelSize.margin * 2, 600)
    }

    @MainActor
    func testNativeHostAndRootUseTheSameResolvedSize() throws {
        let controller = DashboardController(tokenStore: InMemoryTokenStore(), automaticRefreshInterval: 0)
        let statusBarController = StatusBarController(controller: controller)
        let frame = CGRect(x: 0, y: 28, width: 1280, height: 740)
        let hosted = try XCTUnwrap(statusBarController.makeMenuContentView(availableFrame: frame) as? MenuRootHostingView)
        let resolved = MenuPanelSize.resolve(availableFrame: frame)
        XCTAssertEqual(hosted.frame.size, resolved)
        XCTAssertEqual(hosted.rootView.resolvedSize, resolved)
    }

    func testIndependentStatusDescriptionsAndMixedSignals() {
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .approved).label, "Review approved")
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .noReviewYet).label, "No review yet")
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .unknown).label, "Review status unknown")
        XCTAssertEqual(CIStatusIndicator.Kind(ciState: .failing).label, "CI failing")
        XCTAssertEqual(CIStatusIndicator.Kind(ciState: .pending).label, "CI pending (waiting or running)")
        XCTAssertEqual(CIStatusIndicator.Kind(ciState: .passing).label, "CI successful")
        XCTAssertEqual(CIStatusIndicator.Kind(ciState: .unknown).label, "CI status unknown")
        XCTAssertEqual(MergeConflictIndicator.Kind(mergeable: .conflicting).label, "Merge conflicts")
        XCTAssertEqual(MergeConflictIndicator.Kind(mergeable: .unknown).label, "Mergeability unknown")
        XCTAssertTrue(MergeConflictIndicator.Kind(mergeable: .mergeable).label.contains("No merge conflicts"))
        XCTAssertTrue(MergeConflictIndicator.Kind(mergeable: .mergeable).label.contains("other requirements"))
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .approved).signal, .positive)
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .changesRequested).signal, .negative)
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .noReviewYet).signal, .unavailable)
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .unknown).signal, .unavailable)
        XCTAssertEqual(MergeConflictIndicator.Kind(mergeable: .mergeable).signal, .positive)
        XCTAssertEqual(MergeConflictIndicator.Kind(mergeable: .conflicting).signal, .negative)
        XCTAssertEqual(MergeConflictIndicator.Kind(mergeable: .unknown).signal, .unavailable)

        let blocked = (
            ReviewDecisionIndicator.Kind(reviewDecision: .approved).label,
            CIStatusIndicator.Kind(ciState: .failing).label,
            MergeConflictIndicator.Kind(mergeable: .conflicting).label
        )
        XCTAssertEqual(blocked.0, "Review approved")
        XCTAssertEqual(blocked.1, "CI failing")
        XCTAssertEqual(blocked.2, "Merge conflicts")
        let clear = (
            ReviewDecisionIndicator.Kind(reviewDecision: .noReviewYet).label,
            CIStatusIndicator.Kind(ciState: .passing).label,
            MergeConflictIndicator.Kind(mergeable: .mergeable).label
        )
        XCTAssertEqual(clear.0, "No review yet")
        XCTAssertEqual(clear.1, "CI successful")
        XCTAssertTrue(clear.2.contains("No merge conflicts"))
    }

    func testUnresolvedCommentCountLabelsIncludeZero() {
        XCTAssertEqual(CommentCountIndicator.label(for: 0), "0 unresolved comments")
        XCTAssertEqual(CommentCountIndicator.label(for: 1), "1 unresolved comment")
        XCTAssertEqual(CommentCountIndicator.label(for: 3), "3 unresolved comments")
    }

    func testColumnHeadersExplainEachValue() {
        XCTAssertEqual(
            PullRequestColumnLegend.Column.allCases.map(\.label),
            ["Changes", "Unresolved comments", "CI", "Merge status", "Review feedback", "Updated / Opened"]
        )
    }

    func testPullRequestAgePresentationIncludesMonthsAndFieldNames() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(TimeInterval, String)] = [
            (59, "now"),
            (60, "1m"),
            (3_599, "59m"),
            (3_600, "1h"),
            (86_400, "1d"),
            (604_800, "1w"),
            (2_591_999, "4w"),
            (2_592_000, "1mo"),
            (5_184_000, "2mo"),
            (31_536_000, "1y"),
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(PullRequestAgePresentation.shortText(for: now.addingTimeInterval(-seconds), now: now), expected)
        }
        XCTAssertEqual(PullRequestAgePresentation.label(for: now, field: .opened, now: now), "Opened just now")
        XCTAssertEqual(
            PullRequestAgePresentation.label(for: now.addingTimeInterval(-2_592_000), field: .opened, now: now),
            "Opened 1mo ago"
        )
        XCTAssertEqual(
            PullRequestAgePresentation.label(for: now.addingTimeInterval(-3_600), field: .updated, now: now),
            "Updated 1h ago"
        )
    }

    func testSortDirectionHelpMatchesSelectedValue() {
        XCTAssertEqual(DashboardController.PullRequestSortOption.createdDate.directionHelp(for: .descending), "Sorted newest first")
        XCTAssertEqual(DashboardController.PullRequestSortOption.updatedDate.directionHelp(for: .ascending), "Sorted oldest first")
        XCTAssertEqual(DashboardController.PullRequestSortOption.changeSize.directionHelp(for: .descending), "Sorted largest first")
        XCTAssertEqual(DashboardController.PullRequestSortOption.changeSize.directionHelp(for: .ascending), "Sorted smallest first")
    }

    func testRequestedFiltersOfferOnlyStatusChoices() {
        XCTAssertEqual(DashboardController.ReviewRequestFilterOption.allCases.map(\.label), ["All", "Draft", "Ready"])
    }

    func testChangeCountPresentationKeepsExactAccessibleValues() {
        XCTAssertEqual(PullRequestChangesPresentation.additionsText(0), "+0")
        XCTAssertEqual(PullRequestChangesPresentation.deletionsText(0), "−0")
        XCTAssertEqual(PullRequestChangesPresentation.text(additions: 0, deletions: 0), "+0 −0")
        XCTAssertEqual(PullRequestChangesPresentation.label(additions: 0, deletions: 0), "0 additions, 0 deletions")
        XCTAssertEqual(PullRequestChangesPresentation.text(additions: nil, deletions: 0), "—")
        XCTAssertEqual(PullRequestChangesPresentation.label(additions: nil, deletions: 0), "Change counts unavailable")
        XCTAssertEqual(PullRequestChangesPresentation.text(additions: 12_345, deletions: 6_789), "+12k −6.8k")
        XCTAssertEqual(PullRequestChangesPresentation.additionsText(12_345), "+12k")
        XCTAssertEqual(PullRequestChangesPresentation.deletionsText(6_789), "−6.8k")
        XCTAssertEqual(PullRequestChangesPresentation.label(additions: 12_345, deletions: 6_789), "12,345 additions, 6,789 deletions")
    }

    func testChangeCountRoundingPromotesAtSuffixBoundaries() {
        XCTAssertEqual(
            PullRequestChangesPresentation.text(additions: 999_499, deletions: 999_500),
            "+999k −1.0m"
        )
        XCTAssertEqual(
            PullRequestChangesPresentation.label(additions: 999_499, deletions: 999_500),
            "999,499 additions, 999,500 deletions"
        )
        XCTAssertEqual(
            PullRequestChangesPresentation.text(additions: 999_499_999, deletions: 999_500_000),
            "+999m −1.0b"
        )
        XCTAssertEqual(
            PullRequestChangesPresentation.label(additions: 999_499_999, deletions: 999_500_000),
            "999,499,999 additions, 999,500,000 deletions"
        )
    }

    @MainActor
    func testNoReviewFilterKeepsSavedTagAndExcludesUnknown() {
        XCTAssertEqual(ReviewDecision.noReviewYet.rawValue, "review_required")
        XCTAssertEqual(DashboardController.PullRequestFilterOption.noReviewYet.rawValue, "reviewRequired")
        XCTAssertEqual(DashboardController.PullRequestFilterOption.noReviewYet.label, "No review yet")
        let unknown = PullRequest(
            id: "unknown", title: "Unknown feedback", number: 1,
            url: URL(string: "https://github.com/acme/app/pull/1")!, repo: "acme/app",
            ciState: .unknown, reviewDecision: .unknown, commentCount: 0,
            reviewCount: 0, isMine: true, author: "rw", mergeable: .unknown,
            draft: false
        )
        XCTAssertTrue(DashboardController.filtered([unknown], by: [.noReviewYet], events: []).isEmpty)
        XCTAssertTrue(DashboardController.filtered([unknown], by: [.approved], events: []).isEmpty)
        XCTAssertEqual(DashboardController.filtered([unknown], by: [.ready], events: []).map(\.id), ["unknown"])
    }

    func testPullRequestListEmptyCopy() {
        XCTAssertEqual(PullRequestListCopy.emptyReviewRequests, "No review requests or assigned PRs.")
    }

    func testRefreshStatusPresentationDistinguishesSuccessLoadingAndFailure() {
        let idle = RefreshStatusPresentation(
            isRefreshing: false,
            errorMessage: nil,
            lastUpdatedText: "14:30",
            help: "Refresh",
            accessibilityLabel: "Refresh"
        )
        XCTAssertEqual(idle.state, .idle)
        XCTAssertEqual(idle.symbolName, "arrow.clockwise")
        XCTAssertEqual(idle.help, "Refresh")
        XCTAssertEqual(idle.accessibilityLabel, "Refresh")

        let loading = RefreshStatusPresentation(
            isRefreshing: true,
            errorMessage: "Stale failure",
            lastUpdatedText: "14:30",
            help: "Refresh",
            accessibilityLabel: "Refresh"
        )
        XCTAssertEqual(loading.state, .refreshing)
        XCTAssertEqual(loading.accessibilityLabel, "Refresh, refreshing")

        let failed = RefreshStatusPresentation(
            isRefreshing: false,
            errorMessage: "The refresh failed.",
            lastUpdatedText: "14:30",
            help: "Refresh",
            accessibilityLabel: "Refresh"
        )
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.symbolName, "exclamationmark.triangle.fill")
        XCTAssertEqual(failed.help, "Refresh failed: The refresh failed. Click to retry.")
        XCTAssertEqual(
            failed.accessibilityLabel,
            "Refresh failed. The refresh failed. Last successful refresh at 14:30. Activate to retry."
        )

        let sourcesDefault = RefreshStatusPresentation(
            isRefreshing: false,
            errorMessage: nil,
            lastUpdatedText: "never",
            help: "Refresh sources",
            accessibilityLabel: "Refresh sources"
        )
        XCTAssertEqual(sourcesDefault.state, .idle)
        XCTAssertEqual(sourcesDefault.help, "Refresh sources")
        XCTAssertEqual(sourcesDefault.accessibilityLabel, "Refresh sources")
    }

    // MER-58 regression: during NSMenu tracking, key equivalents are matched against the open
    // menu's native items first and then the app's main menu — the hosted view hierarchy is never
    // consulted. Hidden native trap items are required so ⌘, and ⌘Q do not fall through to the
    // SwiftUI Settings scene's auto-generated main-menu items.
    @MainActor
    func testStatusMenuAddsHiddenKeyEquivalentTrapItems() {
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0
        )
        let statusBarController = StatusBarController(controller: controller)
        let items = statusBarController.rebuildMenuForTesting()
        XCTAssertEqual(items.count, 3)
        XCTAssertNotNil(items[0].view)

        let settingsTrapItem = items[1]
        XCTAssertEqual(settingsTrapItem.title, "Settings")
        XCTAssertEqual(settingsTrapItem.keyEquivalent, ",")
        XCTAssertTrue(settingsTrapItem.isHidden)
        XCTAssertTrue(settingsTrapItem.allowsKeyEquivalentWhenHidden)

        let quitTrapItem = items[2]
        XCTAssertEqual(quitTrapItem.title, "Quit")
        XCTAssertEqual(quitTrapItem.keyEquivalent, "q")
        XCTAssertTrue(quitTrapItem.isHidden)
        XCTAssertTrue(quitTrapItem.allowsKeyEquivalentWhenHidden)

        var settingsSelections: [SettingsTab] = []
        controller.openSettingsWindow = { selection in
            settingsSelections.append(selection)
        }
        var quitInvocationCount = 0
        statusBarController.setQuitActionForTesting {
            quitInvocationCount += 1
        }

        _ = settingsTrapItem.target?.perform(settingsTrapItem.action, with: settingsTrapItem)
        XCTAssertEqual(settingsSelections, [.general])
        _ = quitTrapItem.target?.perform(quitTrapItem.action, with: quitTrapItem)
        XCTAssertEqual(quitInvocationCount, 1)
    }

    @MainActor
    func testHostedMenuViewConsumesKeyEquivalents() throws {
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0
        )
        let statusBarController = StatusBarController(controller: controller)
        let items = statusBarController.rebuildMenuForTesting()
        let hostedView = try XCTUnwrap(items[0].view)

        XCTAssertEqual(statusBarController.refreshFlashCountForTesting(), 0)
        XCTAssertTrue(hostedView.performKeyEquivalent(with: keyEvent(characters: "r", modifiers: .command)))
        XCTAssertEqual(statusBarController.refreshFlashCountForTesting(), 1)
        XCTAssertFalse(hostedView.performKeyEquivalent(with: keyEvent(characters: "r", modifiers: [])))
        XCTAssertEqual(statusBarController.refreshFlashCountForTesting(), 1)

        var settingsSelections: [SettingsTab] = []
        controller.openSettingsWindow = { selection in
            settingsSelections.append(selection)
        }
        var quitInvocationCount = 0
        statusBarController.setQuitActionForTesting {
            quitInvocationCount += 1
        }
        XCTAssertFalse(hostedView.performKeyEquivalent(with: keyEvent(characters: ",", modifiers: [])))
        XCTAssertFalse(hostedView.performKeyEquivalent(with: keyEvent(characters: "q", modifiers: [])))
        XCTAssertEqual(settingsSelections, [])
        XCTAssertEqual(quitInvocationCount, 0)
        XCTAssertTrue(hostedView.performKeyEquivalent(with: keyEvent(characters: ",", modifiers: .command)))
        XCTAssertEqual(settingsSelections, [.general])
        XCTAssertTrue(hostedView.performKeyEquivalent(with: keyEvent(characters: "q", modifiers: .command)))
        XCTAssertEqual(quitInvocationCount, 1)
    }

    @MainActor
    func testEveryMenuListShowsTheNativeVerticalScrollIndicator() throws {
        let suite = "menu-list-scrollbars-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(
                usesMockData: true,
                suppressesMacOSNotifications: true,
                mockPullRequestScenario: .longLists
            ),
            notificationClient: RecordingNotificationClient(),
            automaticRefreshInterval: 0
        )
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil && !controller.isRefreshing }
        controller.refresh()
        waitUntil(timeout: 1.0) { !controller.visiblePullRequestNotifications.isEmpty && !controller.isRefreshing }

        for tab in DashboardController.MenuTab.allCases {
            controller.selectedTab = tab
            let size = CGSize(width: MenuRootView.Layout.width, height: MenuRootView.Layout.height)
            let hostingView = NSHostingView(rootView: MenuRootView(controller: controller, footerModel: MenuFooterModel()))
            hostingView.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hostingView
            hostingView.layoutSubtreeIfNeeded()

            let scrollViews = scrollViews(in: hostingView)
            XCTAssertFalse(scrollViews.isEmpty, tab.rawValue)
            XCTAssertTrue(scrollViews.allSatisfy(\.hasVerticalScroller), tab.rawValue)
            window.contentView = nil
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }

    @MainActor
    func testMenuFooterClickFeedbackSuppressesSelectionAndIgnoresRepeatedClicks() async {
        let feedback = MenuFooterClickFeedback()
        var actionCount = 0
        var selectionWasSuppressedWhenActionRan: Bool?

        feedback.perform {
            actionCount += 1
            selectionWasSuppressedWhenActionRan = feedback.suppressesSelection
        }
        feedback.perform {
            actionCount += 1
        }

        XCTAssertTrue(feedback.suppressesSelection)
        XCTAssertTrue(feedback.isActive)
        XCTAssertEqual(actionCount, 0)

        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(feedback.suppressesSelection)
        XCTAssertFalse(feedback.isActive)
        XCTAssertEqual(actionCount, 1)
        XCTAssertEqual(selectionWasSuppressedWhenActionRan, false)
    }

    func testNotificationIconSymbolNamesMatchUpdateTypes() {
        XCTAssertEqual(PullRequestNotificationIconPresentation.symbolName(for: .newComment), "text.bubble")
        XCTAssertEqual(PullRequestNotificationIconPresentation.symbolName(for: .reviewApproved), "checkmark.seal")
        XCTAssertEqual(PullRequestNotificationIconPresentation.symbolName(for: .reviewCommented), "quote.bubble")
        XCTAssertEqual(PullRequestNotificationIconPresentation.symbolName(for: .newReview), "checkmark.seal")
        XCTAssertEqual(PullRequestNotificationIconPresentation.symbolName(for: .ciFailed), "xmark.octagon")
        XCTAssertEqual(PullRequestNotificationIconPresentation.symbolName(for: .changesRequested), "exclamationmark.triangle")
        XCTAssertEqual(PullRequestNotificationIconPresentation.symbolName(for: .relationshipAdded), "person.badge.plus")
        XCTAssertEqual(PullRequestNotificationIconPresentation.symbolName(for: .otherCommitAdded), "arrow.trianglehead.branch")
    }

    func testNotificationIconColorsMatchUpdateTypes() {
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .reviewApproved), .green)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .changesRequested), .red)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .ciFailed), .red)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .newComment), .blue)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .reviewCommented), .blue)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .newReview), .blue)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .relationshipAdded), .purple)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .otherCommitAdded), .orange)
    }
}

@MainActor let mergehawkMenuViewTest: Void = {
    precondition(DashboardController.MenuTab.allCases.map(\.rawValue) == ["Notifications", "Authored", "Requested"])
    precondition(MenuTabShortcutHint.title(for: .notifications) == "⌘1")
    precondition(MenuTabShortcutHint.title(for: .myPRs) == "⌘2")
    precondition(MenuTabShortcutHint.title(for: .reviewRequests) == "⌘3")
    precondition(MenuNotificationTabPresentation.label(for: 0).isEmpty)
    precondition(MenuNotificationTabPresentation.label(for: 1) == "1")
    precondition(MenuNotificationTabPresentation.label(for: 3) == "3")
    precondition(MenuNotificationTabPresentation.help(for: 0) == "Notifications")
    precondition(MenuNotificationTabPresentation.help(for: 1) == "1 new PR update")
    precondition(MenuNotificationTabPresentation.help(for: 3) == "3 new PR updates")
    precondition(CIStatusIndicator.Kind(ciState: .failing) == .failing)
    precondition(CIStatusIndicator.Kind(ciState: .pending) == .pending)
    precondition(CIStatusIndicator.Kind(ciState: .passing) == .successful)

    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .approved) == .approved)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .changesRequested) == .changesRequested)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .noReviewYet) == .noReviewYet)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .unknown) == .unknown)

    let prURL = URL(string: "https://github.com/acme/mergehawk/pull/12")!
    precondition(PullRequestActionsMenu.clipboardString(for: prURL) == "https://github.com/acme/mergehawk/pull/12")
    precondition(CommentCountIndicator.label(for: 3) == "3 unresolved comments")
    precondition(CommentCountIndicator.label(for: 1) == "1 unresolved comment")
    precondition(GitHubSignInView.Copy.title == "Connect GitHub")
    precondition(GitHubSignInView.Copy.buttonTitle == "Sign in with GitHub")
    precondition(GitHubSignInView.Copy.permissionText.contains("GitHub App"))
    precondition(GitHubSignInView.Copy.enterCodeTitle == "Enter code on GitHub")
    precondition(GitHubSignInView.Copy.copyCode == "Copy Code")
    precondition(GitHubSignInView.Copy.codeCopied == "Code copied to clipboard")
    precondition(GitHubSignInView.Copy.openGitHub == "Open GitHub")
    precondition(GitHubSignInView.Copy.loadingTitle == "Authorized")
    precondition(GitHubSignInView.Copy.loadingDetail == "Loading MergeHawk...")
    precondition(GitHubSignInView.Copy.patButtonTitle == "Open Settings")
    precondition(GitHubAppRepositoryAccessCopy.buttonTitle == "Install or Manage Repository Access")
    precondition(GitHubAppRepositoryAccessCopy.title(for: .noInstallations) == "Repository access not configured")
    precondition(GitHubAppRepositoryAccessCopy.message(for: .noVisibleRepositories).contains("no accessible repositories"))
    let templateStatusIcon = StatusIcon.make(attention: false)
    precondition(templateStatusIcon.isTemplate)
    precondition(templateStatusIcon.size == NSSize(width: 26.5, height: 16))
    let attentionStatusIcon = StatusIcon.make(attention: true)
    precondition(!attentionStatusIcon.isTemplate)
    precondition(attentionStatusIcon.size == NSSize(width: 29, height: 18))

    var dropdownState = PullRequestMenuDropdownState()
    precondition(dropdownState.openMenu == nil)
    dropdownState.toggle(.filter)
    precondition(dropdownState.openMenu == .filter)
    dropdownState.toggle(.sort)
    precondition(dropdownState.openMenu == .sort)
    dropdownState.dismiss()
    precondition(dropdownState.openMenu == nil)

    precondition(CountSearchPresentation.countLabel(for: 0, singular: "PR", plural: "PRs") == "0 PRs")
    precondition(CountSearchPresentation.countLabel(for: 1, singular: "PR", plural: "PRs") == "1 PR")
    precondition(CountSearchPresentation.countLabel(for: 9, singular: "PR", plural: "PRs") == "9 PRs")
    precondition(NotificationTimestampPresentation.label(
        for: Date(timeIntervalSince1970: 60 * 60),
        timeZone: TimeZone(secondsFromGMT: 0)!
    ) == "01:00")
    precondition(NotificationReadPresentation.symbolName == "envelope.open")
    precondition(NotificationReadPresentation.markAllTitle == "Mark all as read")
    precondition(NotificationReadPresentation.markAllHelp == "Mark all notifications as read")
    precondition(NotificationReadPresentation.markOneHelp == "Mark as read")
    precondition(NotificationReadPresentation.markPRAccessibilityLabel == "Mark PR notification as read")
    precondition(PullRequestListCopy.emptyAuthored == "No authored PRs.")
    precondition(PullRequestListCopy.emptyReviewRequests == "No review requests or assigned PRs.")
    precondition(PullRequestListCopy.noFilterMatches == "No PRs match these filters.")
    precondition(HiddenPullRequestsDisclosurePresentation.title(count: 3) == "Hidden (3)")
    precondition(HiddenPullRequestsDisclosurePresentation.accessibilityLabel(
        count: 3,
        isExpanded: false
    ) == "Hidden (3), collapsed")
    precondition(HiddenPullRequestsDisclosurePresentation.accessibilityLabel(
        count: 3,
        isExpanded: true
    ) == "Hidden (3), expanded")
    let otherCommitNotificationPullRequest = PullRequest(
        id: "other-commit",
        title: "Other commit notification",
        number: 13,
        url: URL(string: "https://github.com/acme/mergehawk/pull/13")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        isMine: true,
        author: "rw",
        mergeable: .mergeable,
        draft: false
    )
    precondition(PullRequestNotificationTitlePresentation.title(for: PullRequestNotification(
        event: PullRequestEvent(type: .otherCommitAdded, prId: "other-commit", count: 1, actorLogin: "frontend-sam"),
        pullRequest: otherCommitNotificationPullRequest
    )) == "New commit by @frontend-sam")
    precondition(PullRequestNotificationTitlePresentation.title(for: PullRequestNotification(
        event: PullRequestEvent(type: .otherCommitAdded, prId: "other-commit", count: 2),
        pullRequest: otherCommitNotificationPullRequest
    )) == "2 commits by others")
    precondition(PullRequestPinPresentation.symbolName(isPinned: false) == "pin")
    precondition(PullRequestPinPresentation.symbolName(isPinned: true) == "pin.fill")
    precondition(PullRequestPinPresentation.label(isPinned: false) == "Pin")
    precondition(PullRequestPinPresentation.label(isPinned: true) == "Unpin")
    precondition(PullRequestHidePresentation.symbolName == "eye.slash")
    precondition(PullRequestHidePresentation.label(isHidden: false) == "Hide")
    precondition(PullRequestHidePresentation.label(isHidden: true) == "Unhide")

    var searchState = ExpandableSearchState()
    precondition(!searchState.isExpanded)
    searchState.expand()
    precondition(searchState.isExpanded)
    searchState.blur()
    precondition(!searchState.isExpanded)
    searchState.expand()
    searchState.query = "billing"
    searchState.blur()
    precondition(searchState.isExpanded)
    searchState.handleEscape()
    precondition(searchState.query.isEmpty)
    precondition(searchState.isExpanded)
    searchState.handleEscape()
    precondition(!searchState.isExpanded)

    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0
    )
    let statusBarController = StatusBarController(controller: controller)
    let statusMenuItems = statusBarController.rebuildMenuForTesting()
    precondition(statusMenuItems.count == 3)
    precondition(statusMenuItems[0].view != nil)
    // Hidden native key-equivalent trap items: during NSMenu tracking only native items of the
    // open menu outrank the app's main menu, so these keep ⌘, and ⌘Q from reaching the SwiftUI
    // Settings scene's auto-generated main-menu items (MER-58 regression).
    precondition(statusMenuItems[1].title == "Settings")
    precondition(statusMenuItems[1].keyEquivalent == ",")
    precondition(statusMenuItems[1].isHidden)
    precondition(statusMenuItems[1].allowsKeyEquivalentWhenHidden)
    precondition(statusMenuItems[2].title == "Quit")
    precondition(statusMenuItems[2].keyEquivalent == "q")
    precondition(statusMenuItems[2].isHidden)
    precondition(statusMenuItems[2].allowsKeyEquivalentWhenHidden)

    precondition(isRefreshKeyEvent(keyEvent(characters: "r", modifiers: .command)))
    precondition(isRefreshKeyEvent(keyEvent(characters: "R", modifiers: .command)))
    precondition(!isRefreshKeyEvent(keyEvent(characters: "r", modifiers: [])))
    precondition(!isRefreshKeyEvent(keyEvent(characters: "q", modifiers: .command)))
    precondition(!isRefreshKeyEvent(keyEvent(characters: "r", modifiers: [.command, .shift])))
    precondition(menuTabShortcut(for: keyEvent(characters: "1", modifiers: .command)) == .notifications)
    precondition(menuTabShortcut(for: keyEvent(characters: "2", modifiers: .command)) == .myPRs)
    precondition(menuTabShortcut(for: keyEvent(characters: "3", modifiers: .command)) == .reviewRequests)
    precondition(menuTabShortcut(for: keyEvent(characters: "1", modifiers: [])) == nil)
    precondition(menuTabShortcut(for: keyEvent(characters: "1", modifiers: [.command, .shift])) == nil)
    precondition(menuTabShortcut(for: keyEvent(characters: "4", modifiers: .command)) == nil)
    precondition(menuTabShortcut(for: keyEvent(characters: "r", modifiers: .command)) == nil)
    precondition(isSettingsKeyEvent(keyEvent(characters: ",", modifiers: .command)))
    precondition(!isSettingsKeyEvent(keyEvent(characters: ",", modifiers: [])))
    precondition(isQuitKeyEvent(keyEvent(characters: "q", modifiers: .command)))
    precondition(isQuitKeyEvent(keyEvent(characters: "Q", modifiers: .command)))
    precondition(!isQuitKeyEvent(keyEvent(characters: "q", modifiers: [])))

    precondition(statusBarController.refreshFlashCountForTesting() == 0)
    precondition(statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: .command)))
    precondition(statusBarController.refreshFlashCountForTesting() == 1)
    precondition(!statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: [])))
    precondition(statusBarController.refreshFlashCountForTesting() == 1)

    var quitInvocationCount = 0
    statusBarController.setQuitActionForTesting {
        quitInvocationCount += 1
    }
    precondition(!statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: ",", modifiers: [])))
    precondition(!statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "q", modifiers: [])))
    precondition(quitInvocationCount == 0)
    precondition(statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: ",", modifiers: .command)))
    precondition(statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "q", modifiers: .command)))
    precondition(quitInvocationCount == 1)

    let manualRefreshClient = MenuFakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [
            RepositorySource(owner: "rw", name: "story-tales")
        ], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "rw",
                accountType: "User",
                repositorySelection: .all
            )
        ]))
    )
    let manualRefreshController = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: MenuOAuthSignIn(),
        oauthGitHubClientFactory: { _ in manualRefreshClient },
        deviceFlowURLOpener: { _ in }
    )
    Task {
        await manualRefreshController.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        manualRefreshClient.fetchInstallationsCount == 1
    }
    manualRefreshClient.installationsResult = .success(GitHubAppInstallations(installations: []))
    let manualRefreshStatusBarController = StatusBarController(controller: manualRefreshController)
    _ = manualRefreshStatusBarController.showMenuForTesting(selecting: .myPRs)
    precondition(manualRefreshStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: .command)))
    waitUntil(timeout: 1.0) {
        manualRefreshClient.fetchInstallationsCount == 2
            && manualRefreshController.gitHubAppRepositoryAccessStatus == .noInstallations
    }

    controller.selectedTab = .reviewRequests
    precondition(!statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "1", modifiers: .command)))
    precondition(controller.selectedTab == .reviewRequests)

    let signedInController = signedInMockController()
    let signedInStatusBarController = StatusBarController(controller: signedInController)
    _ = signedInStatusBarController.rebuildMenuForTesting()
    signedInController.selectedTab = .reviewRequests
    let revealedMenuItems = signedInStatusBarController.showMenuForTesting(selecting: .notifications)
    precondition(signedInController.selectedTab == .notifications)
    precondition(revealedMenuItems.count == 3)
    precondition(revealedMenuItems[0].view != nil)
    signedInController.selectedTab = .reviewRequests
    precondition(signedInStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "1", modifiers: .command)))
    precondition(signedInController.selectedTab == .notifications)
    precondition(signedInStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "2", modifiers: .command)))
    precondition(signedInController.selectedTab == .myPRs)
    precondition(signedInStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "3", modifiers: .command)))
    precondition(signedInController.selectedTab == .reviewRequests)
    precondition(!signedInStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "4", modifiers: .command)))
    precondition(signedInController.selectedTab == .reviewRequests)
    precondition(!signedInStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "1", modifiers: [.command, .shift])))
    precondition(signedInController.selectedTab == .reviewRequests)

    _ = signedInStatusBarController.showMenuForTesting(selecting: .myPRs)
    precondition(signedInController.selectedTab == .myPRs)
    _ = signedInStatusBarController.showMenuForTesting(selecting: .reviewRequests)
    precondition(signedInController.selectedTab == .reviewRequests)

    let markAllController = signedInMockController()
    let markAllStatusBarController = StatusBarController(controller: markAllController)
    precondition(!markAllStatusBarController.statusButtonHasAttentionForTesting())
    markAllController.refresh()
    waitUntil(timeout: 1.0) {
        markAllController.attentionCount == 2 && markAllStatusBarController.statusButtonHasAttentionForTesting()
    }
    markAllController.markAllNotificationsRead()
    waitUntil(timeout: 1.0) {
        markAllController.attentionCount == 0 && !markAllStatusBarController.statusButtonHasAttentionForTesting()
    }

    let markOneController = signedInMockController()
    let markOneStatusBarController = StatusBarController(controller: markOneController)
    markOneController.refresh()
    waitUntil(timeout: 1.0) {
        markOneController.attentionCount == 2 && markOneStatusBarController.statusButtonHasAttentionForTesting()
    }
    markOneController.markPullRequestNotificationRead(markOneController.visiblePullRequestNotifications[0])
    waitUntil(timeout: 1.0) {
        markOneController.attentionCount == 1 && markOneStatusBarController.statusButtonHasAttentionForTesting()
    }
    if let unreadNotification = markOneController.visiblePullRequestNotifications.first(where: { !$0.read }) {
        markOneController.markPullRequestNotificationRead(unreadNotification)
    }
    waitUntil(timeout: 1.0) {
        markOneController.attentionCount == 0 && !markOneStatusBarController.statusButtonHasAttentionForTesting()
    }

    let sourceFilteredController = signedInMockController()
    let sourceFilteredStatusBarController = StatusBarController(controller: sourceFilteredController)
    sourceFilteredController.refresh()
    waitUntil(timeout: 1.0) {
        sourceFilteredController.attentionCount == 2 && sourceFilteredStatusBarController.statusButtonHasAttentionForTesting()
    }
    sourceFilteredController.setOwnerPreferences(
        owner: "example",
        preferences: OwnerSourcePreferences(
            notifications: false,
            myPullRequests: true,
            reviewRequests: true
        )
    )
    waitUntil(timeout: 1.0) {
        sourceFilteredController.attentionCount == 0
            && !sourceFilteredStatusBarController.statusButtonHasAttentionForTesting()
    }

    let older = PullRequest(
        id: "older",
        title: "Older PR",
        number: 1,
        url: URL(string: "https://github.com/acme/mergehawk/pull/1")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .approved,
        commentCount: 0,
        reviewCount: 1,
        isMine: true,
        author: "rw",
        headRefName: "older-branch",
        mergeable: .mergeable,
        draft: false,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 400)
    )
    let newer = PullRequest(
        id: "newer",
        title: "Newer PR",
        number: 2,
        url: URL(string: "https://github.com/acme/mergehawk/pull/2")!,
        repo: "acme/mergehawk",
        ciState: .failing,
        reviewDecision: .changesRequested,
        commentCount: 2,
        reviewCount: 0,
        isMine: true,
        author: "rw",
        headRefName: "feature/newer",
        mergeable: .conflicting,
        draft: false,
        createdAt: Date(timeIntervalSince1970: 200),
        updatedAt: Date(timeIntervalSince1970: 300)
    )
    let draft = PullRequest(
        id: "draft",
        title: "Draft PR",
        number: 3,
        url: URL(string: "https://github.com/acme/mergehawk/pull/3")!,
        repo: "acme/mergehawk",
        ciState: .pending,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        isMine: true,
        author: "rw",
        headRefName: "draft-flow",
        mergeable: .unknown,
        draft: true,
        createdAt: Date(timeIntervalSince1970: 300),
        updatedAt: Date(timeIntervalSince1970: 500)
    )
    let event = PullRequestEvent(type: .ciFailed, prId: "newer")

    precondition(DashboardController.PullRequestSortOption.allCases.map(\.label) == ["Created", "Updated", "Change size"])
    precondition(DashboardController.ReviewRequestFilterOption.allCases.map(\.label) == ["All", "Draft", "Ready"])
    precondition(DashboardController.sorted([older, newer], by: .createdDate).map(\.id) == ["newer", "older"])
    precondition(DashboardController.sorted([older, newer], by: .updatedDate).map(\.id) == ["older", "newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: [], events: [event]).map(\.id) == ["older", "newer", "draft"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.all], events: [event]).map(\.id) == ["older", "newer", "draft"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.needsAttention], events: [event]).map(\.id) == ["newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.draft], events: [event]).map(\.id) == ["draft"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.ready], events: [event]).map(\.id) == ["older", "newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.changesRequested], events: [event]).map(\.id) == ["newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.noReviewYet], events: [event]).map(\.id) == ["draft"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.approved], events: [event]).map(\.id) == ["older"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.ciFailing], events: [event]).map(\.id) == ["newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.changesRequested, .draft], events: [event]).map(\.id) == ["newer", "draft"])
    precondition(DashboardController.sortedWithPins([older, newer, draft], pinnedIds: ["older"], by: .createdDate).map(\.id) == ["older", "draft", "newer"])
    precondition(DashboardController.sortedWithPins([older, newer, draft], pinnedIds: ["draft", "older"], by: .updatedDate).map(\.id) == ["draft", "older", "newer"])
    precondition(DashboardController.sortedWithPins(
        DashboardController.filtered([older, newer, draft], by: [.ready], events: [event]),
        pinnedIds: ["draft"],
        by: .createdDate
    ).map(\.id) == ["newer", "older"])

    let directReview = PullRequest(
        id: "direct",
        title: "Direct review",
        number: 4,
        url: URL(string: "https://github.com/acme/mergehawk/pull/4")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        reviewRequestKind: .direct,
        isMine: false,
        author: "teammate",
        mergeable: .mergeable,
        draft: false
    )
    let teamReview = PullRequest(
        id: "team",
        title: "Team review",
        number: 5,
        url: URL(string: "https://github.com/acme/mergehawk/pull/5")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        reviewRequestKind: .team,
        isMine: false,
        author: "teammate",
        mergeable: .mergeable,
        draft: false
    )
    let directAndTeamReview = PullRequest(
        id: "direct-team",
        title: "Direct and team review",
        number: 6,
        url: URL(string: "https://github.com/acme/mergehawk/pull/6")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        reviewRequestKind: .directAndTeam,
        isMine: false,
        author: "teammate",
        mergeable: .mergeable,
        draft: false
    )
    let draftDirectReview = PullRequest(
        id: "draft-direct",
        title: "Draft direct review",
        number: 7,
        url: URL(string: "https://github.com/acme/mergehawk/pull/7")!,
        repo: "acme/mergehawk",
        ciState: .failing,
        reviewDecision: .changesRequested,
        commentCount: 3,
        reviewCount: 1,
        reviewRequestKind: .direct,
        isMine: false,
        author: "teammate",
        mergeable: .unknown,
        draft: true
    )
    let assignedReview = PullRequest(
        id: "assigned",
        title: "Assigned review",
        number: 8,
        url: URL(string: "https://github.com/acme/mergehawk/pull/8")!,
        repo: "acme/mergehawk",
        ciState: .pending,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        isAssignedToViewer: true,
        isMine: false,
        author: "teammate",
        mergeable: .unknown,
        draft: false
    )
    let assignedDraftReview = PullRequest(
        id: "assigned-draft",
        title: "Assigned draft review",
        number: 9,
        url: URL(string: "https://github.com/acme/mergehawk/pull/9")!,
        repo: "acme/mergehawk",
        ciState: .pending,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        isAssignedToViewer: true,
        isMine: false,
        author: "teammate",
        mergeable: .unknown,
        draft: true
    )
    let directAssignedReview = PullRequest(
        id: "direct-assigned",
        title: "Direct assigned review",
        number: 10,
        url: URL(string: "https://github.com/acme/mergehawk/pull/10")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        reviewRequestKind: .direct,
        isAssignedToViewer: true,
        isMine: false,
        author: "teammate",
        mergeable: .mergeable,
        draft: false
    )
    let selfAssignedReview = PullRequest(
        id: "self-assigned",
        title: "Self assigned review",
        number: 11,
        url: URL(string: "https://github.com/acme/mergehawk/pull/11")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        reviewRequestKind: .directAndTeam,
        isAssignedToViewer: true,
        isMine: true,
        author: "rw",
        mergeable: .mergeable,
        draft: false
    )
    let reviewRequests = [
        older,
        directReview,
        teamReview,
        directAndTeamReview,
        draftDirectReview,
        assignedReview,
        assignedDraftReview,
        directAssignedReview,
        selfAssignedReview
    ]
    precondition(DashboardController.RequestedSection.section(for: directAndTeamReview) == .direct)
    precondition(DashboardController.RequestedSection.section(for: directAssignedReview) == .assigned)
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: []).map(\.id) == ["direct", "team", "direct-team", "draft-direct", "assigned", "assigned-draft", "direct-assigned"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.all]).map(\.id) == ["direct", "team", "direct-team", "draft-direct", "assigned", "assigned-draft", "direct-assigned"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.draft]).map(\.id) == ["draft-direct", "assigned-draft"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.ready]).map(\.id) == ["direct", "team", "direct-team", "assigned", "direct-assigned"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.draft, .ready]).map(\.id) == ["direct", "team", "direct-team", "draft-direct", "assigned", "assigned-draft", "direct-assigned"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.all, .draft]).map(\.id) == ["draft-direct", "assigned-draft"])
}()

@MainActor
private func signedInMockController() -> DashboardController {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
        automaticRefreshInterval: 0
    )
    waitUntil(timeout: 1.0) {
        controller.state.authStatus == .signedIn
    }
    return controller
}

@MainActor
private func waitUntil(
    timeout: TimeInterval,
    file: StaticString = #file,
    line: UInt = #line,
    condition: () -> Bool
) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    preconditionFailure("Timed out waiting for condition", file: file, line: line)
}

private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    )!
}

@MainActor
private struct MenuOAuthSignIn: GitHubOAuthSigningIn {
    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        DeviceFlowChallenge(
            userCode: "ABCD-1234",
            deviceCode: "fake-device-code",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: .distantFuture,
            interval: 5
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        OAuthTokens(accessToken: "oauth-access", refreshToken: "oauth-refresh", expiresAt: .distantFuture)
    }
}

private final class MenuFakeGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    var sourceCatalogResult: Result<SourceCatalog, Error>
    var installationsResult: Result<GitHubAppInstallations, Error>
    private(set) var fetchInstallationsCount = 0

    init(
        sourceCatalogResult: Result<SourceCatalog, Error>,
        installationsResult: Result<GitHubAppInstallations, Error>
    ) {
        self.sourceCatalogResult = sourceCatalogResult
        self.installationsResult = installationsResult
    }

    func fetchViewer() async throws -> GitHubAccount {
        GitHubAccount(login: "rw")
    }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        CompletePullRequestFetchResult(activePullRequests: [])
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        try sourceCatalogResult.get()
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        fetchInstallationsCount += 1
        return try installationsResult.get()
    }

}
