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

    // Real usable frames (NSScreen.visibleFrame, Dock hidden or at the bottom unless stated).
    /// MacBook Pro 14" in the "Larger Text" display mode (1024 × 665 screen).
    static let largerTextFrame = CGRect(x: 0, y: 0, width: 1024, height: 632)
    /// MacBook Air 13" M1 / MacBook Pro 13" default (1440 × 900 screen).
    static let macBookAir13Frame = CGRect(x: 0, y: 0, width: 1440, height: 876)
    /// MacBook Pro 14" default (measured).
    static let macBookPro14Frame = CGRect(x: 0, y: 0, width: 1512, height: 949)
    /// MacBook Pro 16" default (1728 × 1117 screen).
    static let macBookPro16Frame = CGRect(x: 0, y: 0, width: 1728, height: 1084)
    /// 1080p external display with the Dock at the bottom.
    static let external1080pFrame = CGRect(x: 0, y: 0, width: 1920, height: 985)
    /// 4K external display at "looks like 2560 × 1440" (measured).
    static let external2560Frame = CGRect(x: 0, y: 0, width: 2560, height: 1410)
    /// MacBook Pro 14" (1512 pt) with the Dock on the left.
    static let sideDockFrame = CGRect(x: 64, y: 0, width: 1448, height: 949)

    private static let realFrames = [
        largerTextFrame, macBookAir13Frame, macBookPro14Frame, macBookPro16Frame,
        external1080pFrame, external2560Frame, sideDockFrame
    ]

    func testWidthBudgetIsSixtyPercentOfTheUsableWidthRoundedDown() {
        XCTAssertEqual(MenuPanelSize.widthBudget(for: Self.macBookPro14Frame), 907)
        XCTAssertEqual(MenuPanelSize.widthBudget(for: Self.external2560Frame), 1536)
        XCTAssertEqual(MenuPanelSize.widthBudget(for: Self.macBookAir13Frame), 864)
        XCTAssertEqual(MenuPanelSize.widthBudget(for: Self.largerTextFrame), 614)
    }

    func testEachSizeKeepsItsFactorFromItsThresholdOn() {
        // (size, usable widths below / at / above the threshold, budgets, factors)
        let cases: [(MenuSize, [CGFloat], [CGFloat], [CGFloat])] = [
            (.small, [1161, 1162, 1163], [696, 697, 697], [696.0 / 820, 0.85, 0.85]),
            (.standard, [1366, 1367, 1368], [819, 820, 820], [819.0 / 820, 1, 1]),
            (.large, [1571, 1572, 1573], [942, 943, 943], [942.0 / 820, 1.15, 1.15]),
            (.larger, [1776, 1777, 1778], [1065, 1066, 1066], [1065.0 / 820, 1.3, 1.3])
        ]
        for (size, widths, budgets, factors) in cases {
            for index in widths.indices {
                let frame = CGRect(x: 0, y: 0, width: widths[index], height: 1410)
                let label = "\(size) on \(widths[index])"
                XCTAssertEqual(MenuPanelSize.widthBudget(for: frame), budgets[index], label)
                let resolved = MenuPanelSize.resolve(availableFrame: frame, menuSize: size)
                XCTAssertEqual(resolved.metrics.scale, factors[index], accuracy: 1e-9, label)
                XCTAssertEqual(resolved.size.width, budgets[index], accuracy: 1e-9, label)
            }
        }
    }

    func testLargeAndLargerShareTheBudgetOnAMacBookPro14() {
        for size in [MenuSize.large, .larger] {
            let resolved = MenuPanelSize.resolve(availableFrame: Self.macBookPro14Frame, menuSize: size)
            XCTAssertEqual(resolved.metrics.scale, 907.0 / 820, accuracy: 1e-9, "\(size)")
            XCTAssertEqual(resolved.size.width, 907, "\(size)")
        }
        let small = MenuPanelSize.resolve(availableFrame: Self.macBookPro14Frame, menuSize: .small)
        XCTAssertEqual(small.metrics.scale, 0.85)
        XCTAssertEqual(small.size.width, 697, accuracy: 1e-9)
        XCTAssertEqual(small.size.height, 650.4, accuracy: 1e-9)
        let standard = MenuPanelSize.resolve(availableFrame: Self.macBookPro14Frame, menuSize: .standard)
        XCTAssertEqual(standard.metrics, .standard)
        XCTAssertEqual(standard.size, CGSize(width: 820, height: 765))
    }

    func testLargeAndLargerShrinkOnAMacBookAir13() {
        for size in [MenuSize.large, .larger] {
            let resolved = MenuPanelSize.resolve(availableFrame: Self.macBookAir13Frame, menuSize: size)
            XCTAssertEqual(resolved.metrics.scale, 864.0 / 820, accuracy: 1e-9, "\(size)")
            XCTAssertEqual(resolved.size.width, 864, "\(size)")
        }
    }

    func testEverySizeShrinksToTheBudgetInLargerTextMode() {
        for size in MenuSize.allCases {
            let resolved = MenuPanelSize.resolve(availableFrame: Self.largerTextFrame, menuSize: size)
            XCTAssertEqual(resolved.metrics.scale, 614.0 / 820, accuracy: 1e-9, "\(size)")
            XCTAssertEqual(resolved.size.width, 614, accuracy: 1e-9, "\(size)")
            // 1 + 764 × 614 / 820, below the 608 pt height limit.
            XCTAssertEqual(resolved.size.height, 573.0682926829269, accuracy: 1e-9, "\(size)")
        }
    }

    func testOnlyLargerShrinksOnAMacBookPro16() {
        let large = MenuPanelSize.resolve(availableFrame: Self.macBookPro16Frame, menuSize: .large)
        XCTAssertEqual(large.metrics.scale, 1.15)
        XCTAssertEqual(large.size.width, 943, accuracy: 1e-9)
        let larger = MenuPanelSize.resolve(availableFrame: Self.macBookPro16Frame, menuSize: .larger)
        XCTAssertEqual(larger.metrics.scale, 1036.0 / 820, accuracy: 1e-9)
        XCTAssertEqual(larger.size.width, 1036, accuracy: 1e-9)
    }

    func testLargerKeepsItsWidthAndClampsItsHeightOnA1080pDisplay() {
        let larger = MenuPanelSize.resolve(availableFrame: Self.external1080pFrame, menuSize: .larger)
        XCTAssertEqual(larger.metrics.scale, 1.3)
        XCTAssertEqual(larger.size.width, 1066, accuracy: 1e-9)
        XCTAssertEqual(larger.size.height, 961)
    }

    func testEachMenuSizeKeepsItsFullPanelSizeOnA2560Display() throws {
        // Panel at factor f: width 820f, height 650f + footer (1 + 114f) = 1 + 764f.
        let expected: [MenuSize: CGSize] = [
            .small: CGSize(width: 697, height: 650.4),
            .standard: CGSize(width: 820, height: 765),
            .large: CGSize(width: 943, height: 879.6),
            .larger: CGSize(width: 1066, height: 994.2)
        ]
        for size in MenuSize.allCases {
            let full = try XCTUnwrap(expected[size])
            let resolved = MenuPanelSize.resolve(availableFrame: Self.external2560Frame, menuSize: size)
            XCTAssertEqual(resolved.metrics.scale, size.factor, "\(size)")
            XCTAssertEqual(resolved.size.width, full.width, accuracy: 1e-9, "\(size)")
            XCTAssertEqual(resolved.size.height, full.height, accuracy: 1e-9, "\(size)")
        }
    }

    func testASideDockLimitsTheBudgetToTheUsableWidth() {
        XCTAssertEqual(MenuPanelSize.widthBudget(for: Self.sideDockFrame), 868)
        let larger = MenuPanelSize.resolve(availableFrame: Self.sideDockFrame, menuSize: .larger)
        XCTAssertEqual(larger.metrics.scale, 868.0 / 820, accuracy: 1e-9)
        XCTAssertEqual(larger.size.width, 868)
    }

    func testResolvedSizeNeverExceedsTheMenuWidthLimitOrTheUsableHeight() {
        for frame in Self.realFrames {
            for size in MenuSize.allCases {
                let resolved = MenuPanelSize.resolve(availableFrame: frame, menuSize: size).size
                let label = "\(size) on \(frame)"
                XCTAssertLessThanOrEqual(resolved.width, (frame.width * 0.6).rounded(.down), label)
                XCTAssertLessThanOrEqual(resolved.width, frame.width - 24, label)
                XCTAssertLessThanOrEqual(resolved.height, frame.height - 24, label)
            }
        }
    }

    @MainActor
    func testNativeHostAndRootUseTheSameResolvedSize() throws {
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: try isolatedDefaults()),
            automaticRefreshInterval: 0
        )
        let statusBarController = StatusBarController(controller: controller)
        for frame in [Self.macBookPro14Frame, Self.largerTextFrame] {
            for size in MenuSize.allCases {
                controller.menuSize = size
                let label = "\(size) on \(frame.size)"
                let hosted = try XCTUnwrap(statusBarController.makeMenuContentView(availableFrame: frame) as? MenuRootHostingView)
                let resolved = MenuPanelSize.resolve(availableFrame: frame, menuSize: size)
                XCTAssertEqual(hosted.frame.size, resolved.size, label)
                XCTAssertEqual(hosted.rootView.resolvedSize, resolved.size, label)
                XCTAssertEqual(hosted.rootView.metrics, resolved.metrics, label)
            }
        }
    }

    @MainActor
    func testChangedMenuSizeAppliesWhenTheMenuIsRebuilt() throws {
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: try isolatedDefaults()),
            automaticRefreshInterval: 0
        )
        let statusBarController = StatusBarController(controller: controller)
        // Every size keeps its own factor on this frame, so Small and Default differ.
        let frame = Self.external2560Frame
        let built = try XCTUnwrap(statusBarController.rebuildMenuForTesting(availableFrame: frame).first?.view as? MenuRootHostingView)
        let builtSize = built.frame.size
        XCTAssertEqual(built.rootView.metrics, .standard)

        controller.menuSize = .small

        XCTAssertEqual(built.frame.size, builtSize)
        XCTAssertEqual(built.rootView.metrics, .standard)
        let rebuilt = try XCTUnwrap(statusBarController.rebuildMenuForTesting(availableFrame: frame).first?.view as? MenuRootHostingView)
        XCTAssertEqual(rebuilt.rootView.metrics, MenuMetrics(scale: MenuSize.small.factor))
        XCTAssertEqual(rebuilt.frame.size, rebuilt.rootView.resolvedSize)
        XCTAssertNotEqual(rebuilt.frame.size, builtSize)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "menu-view-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    func testAgeLabelsUseTheMenuNowFromTheEnvironment() throws {
        // Ages computed against menuNow render the same for the same offsets, decades apart;
        // ages computed against wall-clock time would differ.
        let decade: TimeInterval = 10 * 31_536_000
        let early = Date(timeIntervalSince1970: 1_000_000_000)
        let late = early.addingTimeInterval(decade)
        let reference = try renderAgeRow(menuNow: early, updatedAgo: 3 * 3_600)
        XCTAssertEqual(try renderAgeRow(menuNow: late, updatedAgo: 3 * 3_600), reference)
        XCTAssertNotEqual(try renderAgeRow(menuNow: early, updatedAgo: 5 * 3_600), reference)
    }

    @MainActor
    private func renderAgeRow(menuNow: Date, updatedAgo: TimeInterval) throws -> Data {
        let pullRequest = PullRequest(
            id: "PR_AGE", title: "Age", number: 1,
            url: URL(string: "https://github.com/example/app/pull/1")!,
            repo: "example/app", ciState: .passing, reviewDecision: .reviewRequired,
            commentCount: 0, reviewCount: 0, isMine: true, author: "rw",
            mergeable: .mergeable, draft: false,
            createdAt: menuNow.addingTimeInterval(-2 * 86_400),
            updatedAt: menuNow.addingTimeInterval(-updatedAgo)
        )
        let row = PullRequestRow(
            pullRequest: pullRequest, isAttention: false, isPinned: false, isHidden: false,
            toggleHide: {}, togglePin: {}, action: {}
        )
        .environment(\.menuNow, menuNow)
        let hostingView = NSHostingView(rootView: row)
        hostingView.frame = CGRect(x: 0, y: 0, width: 800, height: 60)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        window.contentView = nil
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    func testIndependentStatusDescriptionsAndMixedSignals() {
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .approved).label, "Review approved")
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .reviewRequired).label, "Review required")
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
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .reviewRequired).signal, .unavailable)
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
            ReviewDecisionIndicator.Kind(reviewDecision: .reviewRequired).label,
            CIStatusIndicator.Kind(ciState: .passing).label,
            MergeConflictIndicator.Kind(mergeable: .mergeable).label
        )
        XCTAssertEqual(clear.0, "Review required")
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
    func testReviewRequiredFilterKeepsSavedTagAndMatchesOnlyItsState() throws {
        XCTAssertEqual(ReviewDecision.reviewRequired.rawValue, "review_required")
        XCTAssertEqual(try JSONEncoder().encode([ReviewDecision.reviewRequired]), Data(#"["review_required"]"#.utf8))
        XCTAssertEqual(
            try JSONDecoder().decode([ReviewDecision].self, from: Data(#"["review_required"]"#.utf8)),
            [.reviewRequired]
        )
        XCTAssertEqual(DashboardController.PullRequestFilterOption.reviewRequired.rawValue, "reviewRequired")
        XCTAssertEqual(DashboardController.PullRequestFilterOption.reviewRequired.label, "Review required")

        func pullRequest(_ id: String, _ decision: ReviewDecision, reviewCount: Int) -> PullRequest {
            PullRequest(
                id: id, title: id, number: 1,
                url: URL(string: "https://github.com/acme/app/pull/1")!, repo: "acme/app",
                ciState: .unknown, reviewDecision: decision, commentCount: 0,
                reviewCount: reviewCount, isMine: true, author: "rw", mergeable: .unknown,
                draft: false
            )
        }
        let pullRequests = [
            pullRequest("approved", .approved, reviewCount: 1),
            pullRequest("required-reviewed", .reviewRequired, reviewCount: 2),
            pullRequest("required-unreviewed", .reviewRequired, reviewCount: 0),
            pullRequest("changes", .changesRequested, reviewCount: 1),
            pullRequest("unknown", .unknown, reviewCount: 0),
        ]
        XCTAssertEqual(
            DashboardController.filtered(pullRequests, by: [.approved], events: []).map(\.id),
            ["approved"]
        )
        XCTAssertEqual(
            Set(DashboardController.filtered(pullRequests, by: [.reviewRequired], events: []).map(\.id)),
            ["required-reviewed", "required-unreviewed"]
        )
        XCTAssertEqual(
            DashboardController.filtered([pullRequests[4]], by: [.ready], events: []).map(\.id),
            ["unknown"]
        )
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
    // native main-menu items.
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

        var keyboardSettingsCount = 0
        controller.openSettingsWindowPreservingSelection = {
            keyboardSettingsCount += 1
        }
        var quitInvocationCount = 0
        statusBarController.setQuitActionForTesting {
            quitInvocationCount += 1
        }

        _ = settingsTrapItem.target?.perform(settingsTrapItem.action, with: settingsTrapItem)
        XCTAssertEqual(keyboardSettingsCount, 1)
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

        var keyboardSettingsCount = 0
        controller.openSettingsWindowPreservingSelection = {
            keyboardSettingsCount += 1
        }
        var quitInvocationCount = 0
        statusBarController.setQuitActionForTesting {
            quitInvocationCount += 1
        }
        XCTAssertFalse(hostedView.performKeyEquivalent(with: keyEvent(characters: ",", modifiers: [])))
        XCTAssertFalse(hostedView.performKeyEquivalent(with: keyEvent(characters: "q", modifiers: [])))
        XCTAssertEqual(keyboardSettingsCount, 0)
        XCTAssertEqual(quitInvocationCount, 0)
        XCTAssertTrue(hostedView.performKeyEquivalent(with: keyEvent(characters: ",", modifiers: .command)))
        XCTAssertEqual(keyboardSettingsCount, 1)
        XCTAssertTrue(hostedView.performKeyEquivalent(with: keyEvent(characters: "q", modifiers: .command)))
        XCTAssertEqual(quitInvocationCount, 1)
    }

    @MainActor
    func testMenuCloseDismissesTooltipsAndReopenShowsNone() {
        let clock = ManualTooltipClock()
        let tooltips = clock.makeController()
        let controller = DashboardController(tokenStore: InMemoryTokenStore(), automaticRefreshInterval: 0)
        let statusBarController = StatusBarController(controller: controller, tooltipController: tooltips)
        let menu = NSMenu()

        assertHookDismissesTooltips(tooltips, clock: clock) {
            statusBarController.menuDidClose(menu)
        }

        clock.moveMouse()
        tooltips.hovering(id: UUID())
        clock.advance(by: MenuTooltipMetrics.showDelay)
        XCTAssertNotNil(tooltips.visibleID)
        statusBarController.menuDidClose(menu)
        statusBarController.menuWillOpen(menu)
        XCTAssertNil(tooltips.visibleID)
    }

    @MainActor
    func testTabSwitchDismissesTooltips() {
        let clock = ManualTooltipClock()
        let tooltips = clock.makeController()
        let controller = signedInMockController()
        controller.selectedTab = .notifications
        let (window, _) = hostMenuRoot(controller: controller, tooltips: tooltips)
        defer { window.orderOut(nil) }

        let tabs: [DashboardController.MenuTab] = [.myPRs, .reviewRequests, .notifications]
        var nextTab = tabs.makeIterator()
        assertHookDismissesTooltips(tooltips, clock: clock) {
            let tab = nextTab.next() ?? .myPRs
            controller.selectedTab = tab
            settleRunLoop()
        }
    }

    @MainActor
    func testOpeningADropdownDismissesTooltips() throws {
        let clock = ManualTooltipClock()
        let tooltips = clock.makeController()
        let controller = signedInMockController()
        controller.selectedTab = .myPRs
        let (window, size) = hostMenuRoot(controller: controller, tooltips: tooltips)
        defer { window.orderOut(nil) }
        let delay = MenuTooltipMetrics.showDelay

        // The sort menu button ends just left of the refresh control at the trailing edge of the top bar.
        let topBar = MenuMetrics.standard.topBar
        let sortMenuPoint = CGPoint(
            x: size.width - topBar.trailingInset - topBar.refreshStatusWidth - topBar.headerControlsTrailingSpacing - 12,
            y: size.height - topBar.height / 2
        )
        // The button acts on mouse up; a click's mouse down already dismisses through the event
        // observer, so show a tooltip in between to isolate the dropdown-open hook. Synthesized
        // events do not drive SwiftUI hover here, so the test reports hover and pointer movement.
        send(window, try mouseEvent(.leftMouseDown, at: sortMenuPoint, in: window))
        let visible = UUID()
        clock.moveMouse()
        tooltips.hovering(id: visible)
        clock.advance(by: delay)
        XCTAssertEqual(tooltips.visibleID, visible)
        send(window, try mouseEvent(.leftMouseUp, at: sortMenuPoint, in: window))
        XCTAssertNil(tooltips.visibleID, "visible tooltip hidden")

        // Close the sort menu again, then open it with a tooltip pending.
        send(window, try mouseEvent(.leftMouseDown, at: sortMenuPoint, in: window))
        send(window, try mouseEvent(.leftMouseUp, at: sortMenuPoint, in: window))
        send(window, try mouseEvent(.leftMouseDown, at: sortMenuPoint, in: window))
        let pending = UUID()
        clock.moveMouse()
        tooltips.hovering(id: pending)
        send(window, try mouseEvent(.leftMouseUp, at: sortMenuPoint, in: window))
        clock.advance(by: 2)
        XCTAssertNil(tooltips.visibleID, "pending tooltip cancelled")

        // After leaving and re-entering, the next hover waits the full delay (grace ended).
        tooltips.hoverEnded(id: pending)
        clock.moveMouse()
        tooltips.hovering(id: pending)
        XCTAssertNil(tooltips.visibleID)
        clock.advance(by: delay)
        XCTAssertEqual(tooltips.visibleID, pending)
    }

    // Checks that `hook` hides a visible tooltip, cancels a pending one, and ends the grace window.
    @MainActor
    private func assertHookDismissesTooltips(
        _ tooltips: MenuTooltipController,
        clock: ManualTooltipClock,
        file: StaticString = #filePath,
        line: UInt = #line,
        hook: () -> Void
    ) {
        let delay = MenuTooltipMetrics.showDelay
        let visible = UUID()
        clock.moveMouse()
        tooltips.hovering(id: visible)
        clock.advance(by: delay)
        XCTAssertEqual(tooltips.visibleID, visible, file: file, line: line)
        hook()
        XCTAssertNil(tooltips.visibleID, "visible tooltip hidden", file: file, line: line)

        tooltips.hoverEnded(id: visible)
        let next = UUID()
        clock.moveMouse()
        tooltips.hovering(id: next)
        XCTAssertNil(tooltips.visibleID, "grace window ended", file: file, line: line)
        hook()
        clock.advance(by: 2)
        XCTAssertNil(tooltips.visibleID, "pending tooltip cancelled", file: file, line: line)

        tooltips.hoverEnded(id: next)
        clock.moveMouse()
        tooltips.hovering(id: next)
        clock.advance(by: delay)
        XCTAssertEqual(tooltips.visibleID, next, file: file, line: line)
        tooltips.hoverEnded(id: next)
    }

    @MainActor
    private func hostMenuRoot(controller: DashboardController, tooltips: MenuTooltipController) -> (NSWindow, CGSize) {
        let size = MenuMetrics.standard.panelSize
        let hostingView = NSHostingView(rootView: MenuRootView(
            controller: controller,
            footerModel: MenuFooterModel(),
            tooltipController: tooltips
        ))
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hostingView
        // SwiftUI buttons only receive synthesized clicks in an ordered-in window; keep it off screen.
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        settleRunLoop()
        return (window, size)
    }

    @MainActor
    private func send(_ window: NSWindow, _ event: NSEvent) {
        window.sendEvent(event)
        settleRunLoop()
    }

    @MainActor
    private func settleRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    // MARK: - Stack chip and card clicks

    private static let stackedPullRequest = PullRequest(
        id: "PR_STACKED", title: "Read stack metadata during hydration", number: 202,
        url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/202")!,
        repo: "mergehawk-labs/mergehawk", ciState: .failing, reviewDecision: .reviewRequired,
        additions: 120, deletions: 14, commentCount: 3, reviewCount: 0, reviewRequestKind: .direct,
        isMine: false, author: "platform-nora", mergeable: .conflicting, draft: false,
        createdAt: Date(timeIntervalSince1970: 1_000_000_000), updatedAt: Date(timeIntervalSince1970: 1_000_000_000),
        stackID: "STACK"
    )

    private static func stackGroup(additional: Int = 1, excluded: Int = 0) -> StackGroup {
        let requestedIDs = Set(["PR_STACKED"] + (0..<additional).map { "PR_MORE_\($0)" })
        return StackGroup(
            stack: PullRequestStack(id: "STACK", size: 4, entries: []),
            representativePosition: 2,
            requestedMemberIDs: requestedIDs,
            matchingMemberIDs: Set(requestedIDs.sorted().dropLast(excluded)),
            members: []
        )
    }

    func testStackChipShowsPositionSizeAndAdditionalRequests() {
        let presentation = StackChipPresentation(group: Self.stackGroup(), isExpanded: false)

        XCTAssertEqual(presentation.positionText, "2 of 4")
        XCTAssertEqual(presentation.additionalRequestsText, "+1")
        XCTAssertEqual(presentation.chevronSymbolName, "chevron.right")
        XCTAssertEqual(presentation.tooltip, "Stack · 2 of 4 · 1 more review request")
        XCTAssertEqual(presentation.accessibilityLabel, presentation.tooltip)
        XCTAssertEqual(StackChipPresentation(group: Self.stackGroup(), isExpanded: true).chevronSymbolName, "chevron.down")
        XCTAssertEqual(
            StackChipPresentation(group: Self.stackGroup(additional: 2), isExpanded: false).tooltip,
            "Stack · 2 of 4 · 2 more review requests"
        )
    }

    func testStackChipWithoutOtherRequestsHasNoCountOrRequestClause() {
        let presentation = StackChipPresentation(group: Self.stackGroup(additional: 0), isExpanded: false)

        XCTAssertNil(presentation.additionalRequestsText)
        XCTAssertEqual(presentation.tooltip, "Stack · 2 of 4")
    }

    func testStackChipTooltipNamesRequestsOutsideTheCurrentFilter() {
        let presentation = StackChipPresentation(group: Self.stackGroup(excluded: 1), isExpanded: false)

        XCTAssertEqual(presentation.tooltip, "Stack · 2 of 4 · 1 more review request · 1 outside the current filter")
    }

    private final class RowEvents {
        var opened = 0
        var toggledStack = 0
        var toggledActions = 0
        /// The chip's frame in the hosted row, top-left origin.
        var chipFrame: CGRect = .zero
    }

    @MainActor
    private func hostRow(
        stacked: Bool,
        events: RowEvents,
        metrics: MenuMetrics = .standard,
        width: CGFloat = 800
    ) -> (window: NSWindow, view: NSView) {
        let chip = stacked ? AnyView(StackChip(
            presentation: StackChipPresentation(group: Self.stackGroup(), isExpanded: false)
        ) { events.toggledStack += 1 }
            .background(GeometryReader { proxy in
                Color.clear.onAppear { events.chipFrame = proxy.frame(in: .global) }
            })) : nil
        let row = PullRequestRow(
            pullRequest: Self.stackedPullRequest, isAttention: false, isPinned: false, isHidden: false,
            toggleActions: { events.toggledActions += 1 }, toggleHide: {}, togglePin: {},
            metadataAccessory: chip
        ) { events.opened += 1 }
        let content = row
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.menuMetrics, metrics)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: CGSize(width: width, height: hostingView.fittingSize.height))
        let window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hostingView
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        settleRunLoop()
        return (window, hostingView)
    }

    @MainActor
    private func windowPoint(_ window: NSWindow, topLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: window.contentView!.bounds.height - point.y)
    }

    /// Clicks a point given from the card's top-leading corner.
    @MainActor
    private func click(_ window: NSWindow, atTopLeft point: CGPoint) throws {
        let location = windowPoint(window, topLeft: point)
        send(window, try mouseEvent(.leftMouseDown, at: location, in: window))
        send(window, try mouseEvent(.leftMouseUp, at: location, in: window))
    }

    /// Points on the card, from its top-leading corner, for a row of `width` laid out with `metrics`.
    private struct RowPoints {
        let title: CGPoint
        let metadata: CGPoint
        let ageColumn: CGPoint
        let changesColumn: CGPoint
        let statusColumn: CGPoint
        let leadingPadding: CGPoint
        let topPadding: CGPoint
        let actionsButton: CGPoint

        init(width: CGFloat, height: CGFloat, metrics: MenuMetrics = .standard) {
            let columns = metrics.prColumns
            let identityX = columns.horizontalInset + columns.avatarSize + columns.identitySpacing
            title = CGPoint(x: identityX + 4, y: columns.verticalInset + 4)
            metadata = CGPoint(x: identityX + 4, y: height - columns.verticalInset - 4)
            let actionsMinX = width - columns.horizontalInset - columns.actionsWidth
            actionsButton = CGPoint(x: actionsMinX + columns.actionsWidth / 2, y: height / 2)
            let ageMaxX = actionsMinX - columns.spacing
            ageColumn = CGPoint(x: ageMaxX - columns.ageWidth / 2, y: height / 2)
            let statusMaxX = ageMaxX - columns.ageWidth - columns.spacing
            // Status, merge and review columns, then comments, then changes, right to left.
            statusColumn = CGPoint(x: statusMaxX - 2.5 * columns.statusWidth - 2 * columns.spacing, y: height / 2)
            let changesMaxX = statusMaxX - 3 * columns.statusWidth - 3 * columns.spacing - columns.commentsWidth - columns.spacing
            changesColumn = CGPoint(x: changesMaxX - columns.changesWidth / 2, y: height / 2)
            leadingPadding = CGPoint(x: columns.horizontalInset / 2, y: height / 2)
            topPadding = CGPoint(x: width / 2, y: columns.verticalInset / 2)
        }
    }

    @MainActor
    func testClickingTheStackChipTogglesExpansionWithoutOpeningThePR() throws {
        let events = RowEvents()
        let (window, _) = hostRow(stacked: true, events: events)
        defer { window.orderOut(nil) }
        XCTAssertGreaterThan(events.chipFrame.width, 0)

        try click(window, atTopLeft: CGPoint(x: events.chipFrame.midX, y: events.chipFrame.midY))

        XCTAssertEqual(events.toggledStack, 1)
        XCTAssertEqual(events.opened, 0)
    }

    @MainActor
    func testClickingAnywhereElseOnTheCardOpensThePRWithOrWithoutAChip() throws {
        for stacked in [false, true] {
            let events = RowEvents()
            let (window, view) = hostRow(stacked: stacked, events: events)
            defer { window.orderOut(nil) }
            let points = RowPoints(width: view.bounds.width, height: view.bounds.height)
            let targets: [(String, CGPoint)] = [
                ("title", points.title), ("metadata", points.metadata), ("age column", points.ageColumn),
                ("status column", points.statusColumn), ("changes column", points.changesColumn),
                ("leading padding", points.leadingPadding), ("top padding", points.topPadding)
            ]

            for (index, target) in targets.enumerated() {
                try click(window, atTopLeft: target.1)
                XCTAssertEqual(events.opened, index + 1, "\(target.0), stacked: \(stacked)")
            }
            XCTAssertEqual(events.toggledStack, 0)
            XCTAssertEqual(events.toggledActions, 0)
        }
    }

    @MainActor
    func testActionsButtonOpensTheActionsMenuWithoutOpeningThePR() throws {
        for stacked in [false, true] {
            let events = RowEvents()
            let (window, view) = hostRow(stacked: stacked, events: events)
            defer { window.orderOut(nil) }

            try click(window, atTopLeft: RowPoints(width: view.bounds.width, height: view.bounds.height).actionsButton)

            XCTAssertEqual(events.toggledActions, 1, "stacked: \(stacked)")
            XCTAssertEqual(events.opened, 0, "stacked: \(stacked)")
        }
    }

    @MainActor
    func testStackedCardKeepsTheUnstackedCardHeightAtEveryMenuSize() {
        for size in MenuSize.allCases {
            let metrics = MenuMetrics(scale: size.factor)
            let width = 800 * size.factor
            let unstacked = hostRow(stacked: false, events: RowEvents(), metrics: metrics, width: width)
            let stacked = hostRow(stacked: true, events: RowEvents(), metrics: metrics, width: width)
            defer {
                unstacked.window.orderOut(nil)
                stacked.window.orderOut(nil)
            }

            XCTAssertEqual(stacked.view.bounds.height, unstacked.view.bounds.height, "\(size)")
        }
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

        let statusBarController = StatusBarController(controller: controller)
        let frames = [Self.largerTextFrame, Self.macBookPro14Frame, Self.external2560Frame]
        for size in MenuSize.allCases {
            controller.menuSize = size
            for frame in frames {
                for tab in DashboardController.MenuTab.allCases {
                    controller.selectedTab = tab
                    let label = "\(size) \(tab.rawValue) on \(frame.size)"
                    let hostingView = statusBarController.makeMenuContentView(availableFrame: frame)
                    let window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.contentView = hostingView
                    hostingView.layoutSubtreeIfNeeded()

                    let scrollViews = scrollViews(in: hostingView)
                    XCTAssertFalse(scrollViews.isEmpty, label)
                    XCTAssertTrue(scrollViews.allSatisfy(\.hasVerticalScroller), label)
                    window.contentView = nil
                }
            }
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
        XCTAssertEqual(PullRequestNotificationIconPresentation.symbolName(for: .readyForReview), "eye")
    }

    func testNotificationIconColorsMatchUpdateTypes() {
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .reviewApproved), .green)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .changesRequested), .red)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .ciFailed), .red)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .newComment), .blue)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .reviewCommented), .blue)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .newReview), .blue)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .relationshipAdded), .purple)
        XCTAssertEqual(PullRequestNotificationIconPresentation.color(for: .readyForReview), .orange)
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
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .reviewRequired) == .reviewRequired)
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
    // open menu outrank the app's native main menu, so these dismiss tracking before Settings or Quit (MER-58 regression).
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
        reviewDecision: .reviewRequired,
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
    precondition(DashboardController.filtered([older, newer, draft], by: [.reviewRequired], events: [event]).map(\.id) == ["draft"])
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
        reviewDecision: .reviewRequired,
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
        reviewDecision: .reviewRequired,
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
        reviewDecision: .reviewRequired,
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
        reviewDecision: .reviewRequired,
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
        reviewDecision: .reviewRequired,
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
        reviewDecision: .reviewRequired,
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
        reviewDecision: .reviewRequired,
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
