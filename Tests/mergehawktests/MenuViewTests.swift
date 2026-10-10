@testable import mergehawk
import AppKit
import Combine
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
        XCTAssertEqual(PullRequestChangesPresentation.text(additions: 9_949, deletions: 9_950), "+9.9k −10k")
        XCTAssertEqual(PullRequestChangesPresentation.text(additions: 9_949_999, deletions: 9_999_999), "+9.9m −10m")
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
        let (host, _) = hostMenuRoot(controller: controller, tooltips: tooltips)
        defer { host.close() }

        let tabs: [DashboardController.MenuTab] = [.myPRs, .reviewRequests, .notifications]
        var nextTab = tabs.makeIterator()
        assertHookDismissesTooltips(tooltips, clock: clock) {
            let tab = nextTab.next() ?? .myPRs
            controller.selectedTab = tab
            host.settle()
        }
    }

    @MainActor
    func testOpeningADropdownDismissesTooltips() throws {
        let clock = ManualTooltipClock()
        let tooltips = clock.makeController()
        let controller = signedInMockController()
        controller.selectedTab = .myPRs
        let (host, size) = hostMenuRoot(controller: controller, tooltips: tooltips)
        defer { host.close() }
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
        host.send(try host.mouseEvent(.leftMouseDown, at: sortMenuPoint))
        let visible = UUID()
        clock.moveMouse()
        tooltips.hovering(id: visible)
        clock.advance(by: delay)
        XCTAssertEqual(tooltips.visibleID, visible)
        host.send(try host.mouseEvent(.leftMouseUp, at: sortMenuPoint))
        XCTAssertNil(tooltips.visibleID, "visible tooltip hidden")

        // Close the sort menu again, then open it with a tooltip pending.
        host.send(try host.mouseEvent(.leftMouseDown, at: sortMenuPoint))
        host.send(try host.mouseEvent(.leftMouseUp, at: sortMenuPoint))
        host.send(try host.mouseEvent(.leftMouseDown, at: sortMenuPoint))
        let pending = UUID()
        clock.moveMouse()
        tooltips.hovering(id: pending)
        host.send(try host.mouseEvent(.leftMouseUp, at: sortMenuPoint))
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
    private func hostMenuRoot(
        controller: DashboardController,
        tooltips: MenuTooltipController,
        initialDropdown: PullRequestMenuDropdown? = nil
    ) -> (OffScreenHost, CGSize) {
        let size = MenuMetrics.standard.panelSize
        let hostingView = NSHostingView(rootView: MenuRootView(
            controller: controller,
            footerModel: MenuFooterModel(),
            tooltipController: tooltips,
            initialDropdown: initialDropdown
        ))
        hostingView.frame = CGRect(origin: .zero, size: size)
        return (OffScreenHost(hostingView), size)
    }

    // MARK: - Header dropdown dismissal

    @MainActor
    func testClicksInEmptyTopBarSpaceCloseTheFilterDropdown() throws {
        for (name, point) in [
            ("leading inset", { (bar: TopBarPoints) in CGPoint(x: bar.leadingInsetMidX, y: bar.midY) }),
            ("above the controls", { bar in CGPoint(x: bar.filterButton.midX, y: bar.aboveControlsY) }),
            // The filter dropdown hangs below the filter button, so this point sits below the sort control.
            ("below the controls", { bar in CGPoint(x: bar.sortControlMidX, y: bar.belowControlsY) }),
            ("between the filter and sort controls", { bar in CGPoint(x: bar.filterSortGapMidX, y: bar.midY) }),
            ("between the tab switcher and the filter button", { bar in
                CGPoint(x: (bar.tabSwitcherTrailing + bar.filterButton.minX) / 2, y: bar.midY)
            }),
        ] as [(String, (TopBarPoints) -> CGPoint)] {
            try assertClickInTopBar(with: .filter, at: point, closesDropdown: true, name)
        }
    }

    @MainActor
    func testClicksInEmptyTopBarSpaceCloseTheSortDropdown() throws {
        for (name, point) in [
            ("between the sort and refresh controls", { (bar: TopBarPoints) in
                CGPoint(x: bar.sortRefreshGapMidX, y: bar.midY)
            }),
            ("trailing inset", { bar in CGPoint(x: bar.trailingInsetMidX, y: bar.midY) }),
        ] as [(String, (TopBarPoints) -> CGPoint)] {
            try assertClickInTopBar(with: .sort, at: point, closesDropdown: true, name)
        }
    }

    @MainActor
    func testClickInTheTopBarLeadingInsetClosesAPullRequestActionsMenu() throws {
        let controller = try isolatedSignedInMockController()
        let firstID = try XCTUnwrap(controller.sortedMyPullRequests.first).id
        try assertClickInTopBar(
            controller: controller,
            with: .actions(firstID),
            at: { CGPoint(x: $0.leadingInsetMidX, y: $0.midY) },
            closesDropdown: true
        )
    }

    @MainActor
    func testClickingAFilterItemTogglesItAndKeepsTheDropdownOpen() throws {
        let options = DashboardController.PullRequestFilterOption.allCases
        for index in [1, options.count - 1] {
            let controller = try isolatedSignedInMockController()
            let option = options[index]
            XCTAssertFalse(controller.selectedPullRequestFilters.contains(option))
            try assertClickInTopBar(
                controller: controller,
                with: .filter,
                at: { $0.filterItem(index) },
                closesDropdown: false,
                "\(option)"
            )
            XCTAssertEqual(controller.selectedPullRequestFilters, [option])
        }
    }

    @MainActor
    func testClickOnTheFilterDropdownPaddingKeepsItOpen() throws {
        let controller = try isolatedSignedInMockController()
        let filters = controller.selectedPullRequestFilters
        // The padding below the last item lies over the PR list.
        try assertClickInTopBar(
            controller: controller,
            with: .filter,
            at: { $0.filterDropdownBottomPadding },
            closesDropdown: false
        )
        XCTAssertEqual(controller.selectedPullRequestFilters, filters)
    }

    @MainActor
    func testClickingASortItemSetsTheSortAndClosesTheDropdown() throws {
        let controller = try isolatedSignedInMockController()
        let options = DashboardController.PullRequestSortOption.allCases
        let index = try XCTUnwrap(options.firstIndex { $0 != controller.pullRequestSortOption })
        try assertClickInTopBar(controller: controller, with: .sort, at: { $0.sortItem(index) }, closesDropdown: true)
        XCTAssertEqual(controller.pullRequestSortOption, options[index])
    }

    @MainActor
    func testClickingTheSortDirectionFlipsItAndKeepsTheSortDropdownOpen() throws {
        let controller = try isolatedSignedInMockController()
        let direction = controller.pullRequestSortDirection
        try assertClickInTopBar(
            controller: controller,
            with: .sort,
            at: { CGPoint(x: $0.sortDirection.midX, y: $0.midY) },
            closesDropdown: false
        )
        XCTAssertEqual(controller.pullRequestSortDirection, direction.toggled)
    }

    @MainActor
    func testClickingRefreshWithADropdownOpenRefreshesAndClosesIt() throws {
        let controller = try isolatedSignedInMockController()
        var startedRefresh = false
        let observation = controller.$isRefreshing.sink { if $0 { startedRefresh = true } }
        defer { observation.cancel() }
        try assertClickInTopBar(
            controller: controller,
            with: .filter,
            at: { CGPoint(x: $0.refreshControlMidX, y: $0.midY) },
            closesDropdown: true
        )
        XCTAssertTrue(startedRefresh)
    }

    @MainActor
    func testClickingAnotherTabWithADropdownOpenSwitchesTabsAndClosesIt() throws {
        let controller = try isolatedSignedInMockController()
        try assertClickInTopBar(
            controller: controller,
            with: .sort,
            at: { CGPoint(x: $0.requestedTabMidX, y: $0.midY) },
            closesDropdown: true
        )
        XCTAssertEqual(controller.selectedTab, .reviewRequests)
    }

    @MainActor
    func testClickingTheSortControlWithTheFilterDropdownOpenSwitchesToTheSortDropdown() throws {
        let controller = try isolatedSignedInMockController()
        let (host, size) = hostMenuRoot(
            controller: controller,
            tooltips: MenuTooltipController(),
            initialDropdown: .filter
        )
        defer { host.close() }
        let bar = try TopBarPoints(host: host, size: size, controller: controller)

        try clickAsTheCurrentEvent(host, at: CGPoint(x: bar.sortMenuMidX, y: bar.midY))
        try assertDropdown(in: host, isOpen: true)

        // Only the sort dropdown has an item at this point, and choosing it closes the dropdown.
        let options = DashboardController.PullRequestSortOption.allCases
        let index = try XCTUnwrap(options.firstIndex { $0 != controller.pullRequestSortOption })
        try clickAsTheCurrentEvent(host, at: bar.sortItem(index))
        XCTAssertEqual(controller.pullRequestSortOption, options[index])
        try assertDropdown(in: host, isOpen: false)
    }

    @MainActor
    func testClickingTheFilterButtonWithTheSortDropdownOpenSwitchesToTheFilterDropdown() throws {
        let controller = try isolatedSignedInMockController()
        let (host, size) = hostMenuRoot(
            controller: controller,
            tooltips: MenuTooltipController(),
            initialDropdown: .sort
        )
        defer { host.close() }
        let bar = try TopBarPoints(host: host, size: size, controller: controller)

        try clickAsTheCurrentEvent(host, at: CGPoint(x: bar.filterButton.midX, y: bar.midY))
        try assertDropdown(in: host, isOpen: true)

        // Only the filter dropdown has an item at this point, and toggling it keeps the dropdown open.
        let option = DashboardController.PullRequestFilterOption.allCases[1]
        try clickAsTheCurrentEvent(host, at: bar.filterItem(1))
        XCTAssertEqual(controller.selectedPullRequestFilters, [option])
        try assertDropdown(in: host, isOpen: true)
    }

    /// Checks that every outside-click catcher in the hosted menu reports a dropdown open, or every one reports none.
    @MainActor
    private func assertDropdown(
        in host: OffScreenHost,
        isOpen: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let catchers = outsideClickCatchers(in: try XCTUnwrap(host.window.contentView))
        XCTAssertFalse(catchers.isEmpty, file: file, line: line)
        XCTAssertTrue(catchers.allSatisfy { $0.isActive == isOpen }, "open: \(isOpen)", file: file, line: line)
    }

    /// A signed-in mock controller whose filter and sort choices do not persist past the test.
    @MainActor
    private func isolatedSignedInMockController() throws -> DashboardController {
        let controller = signedInMockController(preferencesStore: PreferencesStore(defaults: try isolatedDefaults()))
        controller.selectedTab = .myPRs
        return controller
    }

    /// Hosts the menu on the My PRs tab with `dropdown` open, clicks the point `at` picks, and checks whether every
    /// outside-click catcher then reports the dropdown closed or open.
    @MainActor
    private func assertClickInTopBar(
        controller: DashboardController? = nil,
        with dropdown: PullRequestMenuDropdown,
        at point: (TopBarPoints) -> CGPoint,
        closesDropdown: Bool,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let controller = try controller ?? isolatedSignedInMockController()
        let (host, size) = hostMenuRoot(
            controller: controller,
            tooltips: MenuTooltipController(),
            initialDropdown: dropdown
        )
        defer { host.close() }
        let openCatchers = outsideClickCatchers(in: try XCTUnwrap(host.window.contentView))
        XCTAssertFalse(openCatchers.isEmpty, file: file, line: line)
        XCTAssertTrue(openCatchers.allSatisfy(\.isActive), "opened \(message)", file: file, line: line)

        try clickAsTheCurrentEvent(host, at: point(try TopBarPoints(host: host, size: size, controller: controller)))

        // Judge by the catchers present after the click: a tab switch rebuilds the content and its catcher.
        let catchers = outsideClickCatchers(in: try XCTUnwrap(host.window.contentView))
        XCTAssertFalse(catchers.isEmpty, file: file, line: line)
        if closesDropdown {
            XCTAssertTrue(catchers.allSatisfy { !$0.isActive }, "closed \(message)", file: file, line: line)
        } else {
            XCTAssertTrue(catchers.allSatisfy(\.isActive), "still open \(message)", file: file, line: line)
        }
    }

    /// Clicks with `OffScreenHost.click(at:)` while `NSApp.currentEvent` holds a matching mouse down, as AppKit sets it
    /// for a real click. The outside-click catchers read the current event to claim only mouse downs, and sending an
    /// event straight to the window leaves it unset.
    @MainActor
    private func clickAsTheCurrentEvent(_ host: OffScreenHost, at point: CGPoint) throws {
        NSApp.postEvent(try host.mouseEvent(.leftMouseDown, at: point), atStart: true)
        let current = NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast, inMode: .default, dequeue: true)
        XCTAssertEqual(current?.type, .leftMouseDown)
        try host.click(at: point)
    }

    /// Every outside-click catcher in the hosted menu. They all read the same dropdown state.
    @MainActor
    private func outsideClickCatchers(in view: NSView) -> [DropdownOutsideClickNSView] {
        view.subviews.flatMap { subview in
            [subview as? DropdownOutsideClickNSView].compactMap { $0 } + outsideClickCatchers(in: subview)
        }
    }

    // MARK: - Stack control and card clicks

    private static let stackedPullRequest = PullRequest(
        id: "PR_STACKED", title: "Read stack metadata during hydration", number: 202,
        url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/202")!,
        repo: "mergehawk-labs/mergehawk", ciState: .failing, reviewDecision: .reviewRequired,
        additions: 120, deletions: 14, commentCount: 3, reviewCount: 0, reviewRequestKind: .direct,
        isMine: false, author: "platform-nora", mergeable: .conflicting, draft: false,
        createdAt: Date(timeIntervalSince1970: 1_000_000_000), updatedAt: Date(timeIntervalSince1970: 1_000_000_000),
        stackID: "STACK"
    )

    private static func stackEntry(position: Int) -> PullRequestStackEntry {
        PullRequestStackEntry(
            position: position, pullRequestID: "PR_ENTRY_\(position)", number: 600 + position,
            title: "Entry \(position)", url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/\(600 + position)")!,
            state: .open, isDraft: false, author: "docs-lee"
        )
    }

    private static func stackGroup(
        additional: Int = 1,
        excluded: Int = 0,
        size: Int = 4,
        representativePosition: Int = 2,
        entryPositions: [Int] = []
    ) -> StackGroup {
        let requestedIDs = Set(["PR_STACKED"] + (0..<additional).map { "PR_MORE_\($0)" })
        let entries = entryPositions.map(stackEntry(position:))
        return StackGroup(
            stack: PullRequestStack(id: "STACK", size: size, entries: entries),
            representativePosition: representativePosition,
            requestedMemberIDs: requestedIDs,
            matchingMemberIDs: Set(requestedIDs.sorted().dropLast(excluded)),
            members: entries.map { .context($0) }
        )
    }

    func testCollapsedStackControlShowsTheRepresentativePositionAndExpandedTheFirstMember() {
        let group = Self.stackGroup(size: 3, entryPositions: [1, 2, 3])
        let collapsed = StackControlPresentation(group: group, displayedPosition: group.representativePosition, isExpanded: false)
        XCTAssertEqual(collapsed.fractionText, "2/3")
        XCTAssertEqual(collapsed.chevronSymbolName, "chevron.down")

        let expanded = StackControlPresentation(group: group, displayedPosition: group.topMemberPosition, isExpanded: true)
        XCTAssertEqual(expanded.fractionText, "1/3")
        XCTAssertEqual(expanded.chevronSymbolName, "chevron.up")
    }

    func testExpandedStackControlShowsTheFirstReadablePosition() {
        // GitHub returned no readable entry at position 1.
        let group = Self.stackGroup(size: 3, representativePosition: 3, entryPositions: [2, 3])
        XCTAssertEqual(group.topMemberPosition, 2)
        XCTAssertEqual(
            StackControlPresentation(group: group, displayedPosition: group.topMemberPosition, isExpanded: true).fractionText,
            "2/3"
        )
    }

    func testStacksExpandAndCollapseWithAnimationUnlessReduceMotionIsOn() {
        XCTAssertEqual(StackExpansionAnimation.animation(reduceMotion: false), .easeInOut(duration: 0.15))
        XCTAssertNil(StackExpansionAnimation.animation(reduceMotion: true))
    }

    func testExpandedStackUnfoldsFromTheCollapsedCardToItsFullHeight() {
        // Four rows of 60pt: the reveal starts at the first row, where the collapsed card was.
        func height(_ progress: CGFloat) -> CGFloat {
            StackUnfoldReveal.revealedHeight(containerHeight: 240, rowCount: 4, progress: progress)
        }
        XCTAssertEqual(height(0), 60)
        XCTAssertEqual(height(0.5), 150)
        XCTAssertEqual(height(1), 240)
    }

    func testStackControlShowsNoCountOrStackWordAndKeepsRequestsInTheTooltip() {
        let presentation = StackControlPresentation(group: Self.stackGroup(), displayedPosition: 2, isExpanded: false)
        XCTAssertEqual(presentation.fractionText, "2/4")
        XCTAssertFalse(presentation.fractionText.contains("+"))
        XCTAssertFalse(presentation.fractionText.contains("Stack"))
        XCTAssertEqual(presentation.tooltip, "Stack · position 2 of 4 · 1 more review request · Expand stack")
        XCTAssertEqual(presentation.accessibilityLabel, presentation.tooltip)
        XCTAssertEqual(
            StackControlPresentation(group: Self.stackGroup(additional: 2), displayedPosition: 1, isExpanded: true).tooltip,
            "Stack · position 1 of 4 · 2 more review requests · Collapse stack"
        )
        XCTAssertEqual(
            StackControlPresentation(group: Self.stackGroup(excluded: 1), displayedPosition: 2, isExpanded: false).tooltip,
            "Stack · position 2 of 4 · 1 more review request · 1 outside the current filter · Expand stack"
        )
        XCTAssertEqual(
            StackControlPresentation(group: Self.stackGroup(additional: 0), displayedPosition: 2, isExpanded: false).tooltip,
            "Stack · position 2 of 4 · Expand stack"
        )
    }

    @MainActor
    func testStackControlKeepsOneSizeForItsGroupInBothStates() {
        func size(_ presentation: StackControlPresentation, metrics: MenuMetrics) -> CGSize {
            NSHostingView(rootView: StackControl(presentation: presentation) {}.environment(\.menuMetrics, metrics)).fittingSize
        }
        for menuSize in MenuSize.allCases {
            let metrics = MenuMetrics(scale: menuSize.factor)
            let small = Self.stackGroup(size: 3, entryPositions: [1, 2, 3])
            let collapsed = size(.init(group: small, displayedPosition: 2, isExpanded: false), metrics: metrics)
            XCTAssertGreaterThan(collapsed.width, 0)
            XCTAssertEqual(size(.init(group: small, displayedPosition: 1, isExpanded: true), metrics: metrics), collapsed, "\(menuSize)")

            let large = Self.stackGroup(size: 12, representativePosition: 10, entryPositions: Array(1...12))
            let twoDigits = size(.init(group: large, displayedPosition: 10, isExpanded: false), metrics: metrics)
            for (position, isExpanded) in [(9, false), (1, true), (10, true)] {
                XCTAssertEqual(
                    size(.init(group: large, displayedPosition: position, isExpanded: isExpanded), metrics: metrics),
                    twoDigits,
                    "\(position)/12, expanded: \(isExpanded), at \(menuSize)"
                )
            }
        }
    }

    private final class RowEvents {
        var opened = 0
        var toggledStack = 0
        var toggledActions = 0
        /// The stack control's frame in the hosted row, top-left origin.
        var controlFrame: CGRect = .zero
    }

    @MainActor
    private func hostRow(
        stacked: Bool,
        events: RowEvents,
        metrics: MenuMetrics = .standard,
        width: CGFloat = 800
    ) -> (host: OffScreenHost, view: NSView) {
        let control = stacked ? AnyView(StackControl(
            presentation: StackControlPresentation(group: Self.stackGroup(), displayedPosition: 2, isExpanded: false)
        ) { events.toggledStack += 1 }
            .background(GeometryReader { proxy in
                Color.clear.onAppear { events.controlFrame = proxy.frame(in: .global) }
            })) : nil
        let row = PullRequestRow(
            pullRequest: Self.stackedPullRequest, isAttention: false, isPinned: false, isHidden: false,
            toggleActions: { events.toggledActions += 1 }, toggleHide: {}, togglePin: {},
            stackControl: control
        ) { events.opened += 1 }
        let content = row
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.menuMetrics, metrics)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: CGSize(width: width, height: hostingView.fittingSize.height))
        return (OffScreenHost(hostingView), hostingView)
    }

    @MainActor
    private func windowPoint(_ host: OffScreenHost, topLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: host.window.contentView!.bounds.height - point.y)
    }

    /// Clicks a point given from the card's top-leading corner.
    @MainActor
    private func click(_ host: OffScreenHost, atTopLeft point: CGPoint) throws {
        let location = windowPoint(host, topLeft: point)
        host.send(try host.mouseEvent(.leftMouseDown, at: location))
        host.send(try host.mouseEvent(.leftMouseUp, at: location))
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
    func testClickingAnywhereInTheStackControlTogglesExpansionWithoutOpeningThePR() throws {
        let events = RowEvents()
        let (host, _) = hostRow(stacked: true, events: events)
        defer { host.close() }
        let frame = events.controlFrame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, MenuMetrics.standard.prRow.stackControlHeight - 1)

        // The center, then the padding near each corner and edge, inside the rounded border.
        let inset: CGFloat = 4
        let points = [
            CGPoint(x: frame.midX, y: frame.midY),
            CGPoint(x: frame.minX + inset, y: frame.minY + inset),
            CGPoint(x: frame.maxX - inset, y: frame.minY + inset),
            CGPoint(x: frame.minX + inset, y: frame.maxY - inset),
            CGPoint(x: frame.maxX - inset, y: frame.maxY - inset),
            CGPoint(x: frame.minX + 1.5, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.minY + 1.5)
        ]
        for (index, point) in points.enumerated() {
            try click(host, atTopLeft: point)
            XCTAssertEqual(events.toggledStack, index + 1, "\(point)")
        }
        XCTAssertEqual(events.opened, 0)
    }

    @MainActor
    func testClickingAnywhereElseOnTheCardOpensThePRWithOrWithoutAStackControl() throws {
        for stacked in [false, true] {
            let events = RowEvents()
            let (host, view) = hostRow(stacked: stacked, events: events)
            defer { host.close() }
            let points = RowPoints(width: view.bounds.width, height: view.bounds.height)
            let targets: [(String, CGPoint)] = [
                ("title", points.title), ("metadata", points.metadata), ("age column", points.ageColumn),
                ("status column", points.statusColumn), ("changes column", points.changesColumn),
                ("leading padding", points.leadingPadding), ("top padding", points.topPadding)
            ]

            for (index, target) in targets.enumerated() {
                try click(host, atTopLeft: target.1)
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
            let (host, view) = hostRow(stacked: stacked, events: events)
            defer { host.close() }

            try click(host, atTopLeft: RowPoints(width: view.bounds.width, height: view.bounds.height).actionsButton)

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
                unstacked.host.close()
                stacked.host.close()
            }

            XCTAssertEqual(stacked.view.bounds.height, unstacked.view.bounds.height, "\(size)")
        }
    }

    // MARK: - Expanded stack members

    @MainActor
    private func prStacksGroup(_ stackID: String) throws -> (controller: DashboardController, row: ReviewRequestRow) {
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: try isolatedDefaults()),
            launchConfiguration: LaunchConfiguration(
                usesMockData: true, suppressesMacOSNotifications: true, mockPullRequestScenario: .prStacks
            ),
            automaticRefreshInterval: 0
        )
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil && !controller.isRefreshing }
        let row = try XCTUnwrap(controller.requestedSections.flatMap(\.visible).first { $0.stack?.stack.id == stackID })
        return (controller, row)
    }

    @MainActor
    func testExpandedGroupListsEveryReadableMemberTopOfTheStackFirst() throws {
        let group = try XCTUnwrap(try prStacksGroup("STACK_MOCK_UNREADABLE").row.stack)
        var rendered: [(id: String, position: Int, minY: CGFloat)] = []
        let list = StackMemberContainer(group: group, isUnread: false) { member, position in
            GeometryReader { proxy in
                Color.clear.onAppear {
                    rendered.append((member.pullRequestID, position, proxy.frame(in: .global).minY))
                }
            }
            .frame(height: 10)
        }
        let hostingView = NSHostingView(rootView: list.frame(width: 400))
        hostingView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let host = OffScreenHost(hostingView)
        defer { host.close() }

        let topToBottom = rendered.sorted { $0.minY < $1.minY }
        XCTAssertEqual(topToBottom.map(\.position), [4, 2, 1])
        XCTAssertEqual(topToBottom.map(\.id), [
            "PR_STACK_MOCK_UNREADABLE_4", "PR_STACK_MOCK_UNREADABLE_2", "PR_STACK_MOCK_UNREADABLE_1"
        ])
    }

    @MainActor
    func testContextMembersShowDraftThenTheirStateAfterTheTitle() throws {
        let unreadable = try XCTUnwrap(try prStacksGroup("STACK_MOCK_UNREADABLE").row.stack)
        // Draft open context, then closed context.
        XCTAssertEqual(unreadable.contextBadges, [[.draft, .open], [.closed]])

        let filter = try XCTUnwrap(try prStacksGroup("STACK_MOCK_FILTER").row.stack)
        // One open context member.
        XCTAssertEqual(filter.contextBadges, [[.open]])

        let assigned = try XCTUnwrap(try prStacksGroup("STACK_MOCK_ASSIGNED").row.stack)
        XCTAssertEqual(assigned.contextBadges, [[.merged]])
        XCTAssertEqual([StackMemberBadge.open, .merged, .closed].map(\.title), ["Open", "Merged", "Closed"])
    }

    private static let longTitle = String(repeating: "Explain every skipped stack entry in detail ", count: 6)

    private static func contextEntry(draft: Bool, state: PullRequestStackEntry.State = .open) -> PullRequestStackEntry {
        PullRequestStackEntry(
            position: 3, pullRequestID: "PR_CONTEXT", number: 214, title: longTitle,
            url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/214")!,
            state: state, isDraft: draft, author: "docs-lee"
        )
    }

    private static func pullRequest(title: String, draft: Bool) -> PullRequest {
        PullRequest(
            id: "PR_MEMBER", title: title, number: 212,
            url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/212")!,
            repo: "mergehawk-labs/mergehawk", ciState: .passing, reviewDecision: .reviewRequired,
            additions: 12, deletions: 3, commentCount: 1, reviewCount: 0, reviewRequestKind: .direct,
            isMine: false, author: "docs-lee", mergeable: .mergeable, draft: draft,
            createdAt: Date(timeIntervalSince1970: 1_000_000_000), updatedAt: Date(timeIntervalSince1970: 1_000_000_000)
        )
    }

    private final class ColumnFrames {
        var frames: [CGRect] = []
        var parts: [PullRequestCardPart: CGRect] = [:]
    }

    private struct CardMeasurement {
        let height: CGFloat
        /// Value columns and the actions column, left to right.
        let columns: [CGRect]
        let parts: [PullRequestCardPart: CGRect]
        /// One device pixel in points. Layout snaps edges to the pixel grid, so a distance between two edges can
        /// differ from its metric by up to one pixel (a whole point on a 1x display).
        let pixel: CGFloat

        /// The tolerance for a distance between two laid-out edges.
        var edgeTolerance: CGFloat { pixel + 0.01 }
    }

    /// Hosts `card` at `width` and returns its fitted height, its column frames, and its part frames.
    @MainActor
    private func measure(_ card: some View, width: CGFloat, metrics: MenuMetrics) -> CardMeasurement {
        let box = ColumnFrames()
        let measured = card
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .overlayPreferenceValue(PullRequestCardColumnAnchorsKey.self) { anchors in
                GeometryReader { proxy in
                    Color.clear.onAppear { box.frames = anchors.map { proxy[$0] } }
                }
            }
            .overlayPreferenceValue(PullRequestCardPartAnchorsKey.self) { anchors in
                GeometryReader { proxy in
                    Color.clear.onAppear { box.parts = anchors.mapValues { proxy[$0] } }
                }
            }
            .environment(\.menuMetrics, metrics)
        let hostingView = NSHostingView(rootView: measured)
        let height = hostingView.fittingSize.height
        hostingView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let host = OffScreenHost(hostingView)
        let pixel = 1 / host.window.backingScaleFactor
        host.close()
        return CardMeasurement(height: height, columns: box.frames, parts: box.parts, pixel: pixel)
    }

    /// A stand-in stack control with a fixed size, for checks of the card layout rather than the control.
    private static let stackControlStandIn = AnyView(
        Text("1/3").padding(.horizontal, 12).frame(height: 20).background(Color.blue)
    )

    /// An unstacked card, a collapsed stacked card, and a requested member row and a context row below the top of an
    /// expanded group, which show their stack position in the metadata.
    @MainActor
    private func memberCards(
        title: String,
        draft: Bool,
        contextState: PullRequestStackEntry.State = .merged,
        stackControl: AnyView? = nil
    ) -> [(String, AnyView)] {
        let pullRequest = Self.pullRequest(title: title, draft: draft)
        let control = stackControl ?? AnyView(StackControl(
            presentation: StackControlPresentation(group: Self.stackGroup(), displayedPosition: 2, isExpanded: false)
        ) {})
        return [
            ("unstacked card", AnyView(PullRequestRow(
                pullRequest: pullRequest, isAttention: false, isPinned: false, isHidden: false,
                toggleHide: {}, togglePin: {}, action: {}
            ))),
            ("collapsed stacked card", AnyView(PullRequestRow(
                pullRequest: pullRequest, isAttention: false, isPinned: false, isHidden: false,
                toggleHide: {}, togglePin: {}, stackControl: control, action: {}
            ))),
            ("requested member row", AnyView(PullRequestRow(
                pullRequest: pullRequest, isAttention: false, isPinned: false, isHidden: false,
                toggleHide: {}, togglePin: {},
                metadataAccessory: AnyView(StackPositionLabel(pullRequestID: pullRequest.id, position: 2, size: 12)),
                chrome: .containerRow, showsActions: false, action: {}
            ))),
            ("context row", AnyView(StackContextCard(
                entry: Self.contextEntry(draft: draft, state: contextState), repo: pullRequest.repo, chrome: .containerRow,
                metadataAccessory: AnyView(StackPositionLabel(pullRequestID: "PR_CONTEXT", position: 12, size: 12))
            ) {}))
        ]
    }

    @MainActor
    func testTheRepositoryTruncatesBeforeAMetadataStackPosition() throws {
        let metrics = MenuMetrics.standard
        /// The position label's frame and the identity slot's frame in a context row for `repo`.
        func layout(repo: String) throws -> (label: CGRect, identity: CGRect) {
            let card = StackContextCard(
                entry: Self.contextEntry(draft: false, state: .merged), repo: repo, chrome: .containerRow,
                metadataAccessory: AnyView(StackPositionLabel(pullRequestID: "PR_CONTEXT", position: 12, size: 12))
            ) {}
            let box = ColumnFrames()
            let hosted = card
                .frame(width: 800)
                .fixedSize(horizontal: false, vertical: true)
                .overlayPreferenceValue(StackPositionLabelAnchorsKey.self) { anchors in
                    GeometryReader { proxy in
                        Color.clear.onAppear { box.frames = anchors.values.map { proxy[$0] } }
                    }
                }
                .environment(\.menuMetrics, metrics)
            let (host, _) = self.host(hosted, width: 800)
            defer { host.close() }
            let identity = try XCTUnwrap(measure(card, width: 800, metrics: metrics).parts[.identity])
            return (try XCTUnwrap(box.frames.first), identity)
        }

        let short = try layout(repo: "a/b")
        let long = try layout(repo: String(repeating: "mergehawk-labs/a-very-long-repository-name-", count: 6))

        XCTAssertEqual(long.label.width, short.label.width, "the stack position keeps its full width")
        XCTAssertLessThanOrEqual(long.label.maxX, long.identity.maxX + 0.5, "the long repository truncates instead")
        XCTAssertGreaterThan(long.label.minX, short.label.minX, "the repository takes the rest of the line")
    }

    @MainActor
    func testEveryKindOfPRCardHasTheSameHeightAtEveryMenuSize() {
        for size in MenuSize.allCases {
            let metrics = MenuMetrics(scale: size.factor)
            var heights: [(String, CGFloat)] = []
            for draft in [false, true] {
                for title in ["Short title", Self.longTitle] {
                    for (name, card) in memberCards(title: title, draft: draft) {
                        let label = "\(name), draft: \(draft), \(title.count) characters"
                        heights.append((label, measure(card, width: 800 * size.factor, metrics: metrics).height))
                    }
                }
            }
            for state in [PullRequestStackEntry.State.open, .closed] {
                let card = StackContextCard(entry: Self.contextEntry(draft: false, state: state), repo: "a/b") {}
                heights.append(("context \(state)", measure(card, width: 800 * size.factor, metrics: metrics).height))
            }
            let reference = heights[0]
            for (label, height) in heights {
                XCTAssertEqual(height, reference.1, "\(label) at \(size) vs \(reference.0)")
            }
        }
    }

    /// Lays `view` out at `width` with its ideal height and returns that height unrounded, unlike `fittingSize`.
    @MainActor
    private func exactHeight(_ view: some View, width: CGFloat, metrics: MenuMetrics) -> CGFloat {
        let box = ExactHeight()
        let measured = view
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in Color.clear.onAppear { box.height = proxy.size.height } })
            .frame(width: width, height: 200, alignment: .top)
            .environment(\.menuMetrics, metrics)
        let hostingView = NSHostingView(rootView: measured)
        hostingView.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        OffScreenHost(hostingView).close()
        XCTAssertGreaterThan(box.height, 0, "the view was laid out")
        return box.height
    }

    private final class ExactHeight {
        var height: CGFloat = 0
    }

    /// The menu sizes' factors plus factors from 0.70 to 1.30 in 0.02 steps: the panel scales by any factor in
    /// between when it shrinks to fit the screen.
    private static let layoutFactors = MenuSize.allCases.map(\.factor) + stride(from: 70, through: 130, by: 2).map {
        CGFloat($0) / 100
    }

    @MainActor
    func testLargerCardTextKeepsTheCardHeightAtEveryScale() {
        for factor in Self.layoutFactors {
            let metrics = MenuMetrics(scale: factor)
            // The card text sizes before MER-95.
            var before = metrics
            before.type.cardTitle.size = 11 * factor
            before.type.cardMetadata.size = 10 * factor
            for (name, card) in memberCards(title: "Short title", draft: false) {
                XCTAssertEqual(
                    exactHeight(card, width: 800 * factor, metrics: metrics),
                    exactHeight(card, width: 800 * factor, metrics: before),
                    accuracy: 0.001,
                    "\(name) at \(factor)"
                )
            }
        }
    }

    @MainActor
    func testNotificationRowIsExactlyAsTallAsAPRCardAtEveryScale() {
        let notification = PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: "PR_1"),
            pullRequest: Self.pullRequest(title: "Short title", draft: false)
        )
        for factor in Self.layoutFactors {
            let metrics = MenuMetrics(scale: factor)
            let card = memberCards(title: "Short title", draft: false)[0].1
            let row = PullRequestNotificationRow(notification: notification, action: {}, onMarkRead: {})
            XCTAssertEqual(
                exactHeight(row, width: 800 * factor, metrics: metrics),
                exactHeight(card, width: 800 * factor, metrics: metrics),
                accuracy: 0.001,
                "at \(factor)"
            )
        }
    }

    @MainActor
    func testExpandedMemberCardColumnsLineUpWithOrdinaryCardsAtTheReducedWidth() throws {
        let group = try XCTUnwrap(try prStacksGroup("STACK_MOCK_SPREAD").row.stack)
        for size in MenuSize.allCases {
            let layout = MenuPanelSize.resolve(availableFrame: Self.largerTextFrame, menuSize: size)
            let width = layout.metrics.prList.cardWidth(inPanelWidth: layout.size.width)
            let measured = memberCards(title: Self.longTitle, draft: true).map { name, card in
                (name, measure(card, width: width, metrics: layout.metrics).columns)
            }
            let ordinary = measured[0].1
            XCTAssertEqual(ordinary.count, 7, "six value columns and the actions column at \(size)")
            for (name, columns) in measured {
                XCTAssertEqual(columns.map(\.minX), ordinary.map(\.minX), "\(name) at \(size)")
                XCTAssertEqual(columns.map(\.width), ordinary.map(\.width), "\(name) at \(size)")
            }

            // Inside an expanded group the same cards keep their width and every column's x-position.
            let cards = memberCards(title: Self.longTitle, draft: true).map(\.1)
            let list = StackMemberContainer(group: group, isUnread: false) { _, position in cards[(position - 1) % cards.count] }
            let expanded = measure(list, width: width, metrics: layout.metrics)
            XCTAssertEqual(expanded.columns.count, ordinary.count * group.members.count, "\(size)")
            for (index, start) in stride(from: 0, to: expanded.columns.count, by: ordinary.count).enumerated() {
                let columns = Array(expanded.columns[start..<start + ordinary.count])
                XCTAssertEqual(columns.map(\.minX), ordinary.map(\.minX), "expanded member \(index) at \(size)")
                XCTAssertEqual(columns.map(\.width), ordinary.map(\.width), "expanded member \(index) at \(size)")
            }
        }
    }

    @MainActor
    func testEveryKindOfPRCardStartsItsAvatarTitleAndMetadataAtTheSameX() throws {
        for size in MenuSize.allCases {
            let layout = MenuPanelSize.resolve(availableFrame: Self.largerTextFrame, menuSize: size)
            let width = layout.metrics.prList.cardWidth(inPanelWidth: layout.size.width)
            // Every badge follows the title, so draft and non-draft cards of every kind start their title together.
            let reference = measure(memberCards(title: Self.longTitle, draft: false)[0].1, width: width, metrics: layout.metrics).parts
            for (draft, state) in [false, true].flatMap({ draft in
                [PullRequestStackEntry.State.open, .merged, .closed].map { (draft, $0) }
            }) {
                let measured = memberCards(title: Self.longTitle, draft: draft, contextState: state).map { name, card in
                    (name, measure(card, width: width, metrics: layout.metrics).parts)
                }
                for (name, parts) in measured {
                    for part in [PullRequestCardPart.avatar, .title, .metadata] {
                        let label = "\(part) of \(name), draft: \(draft), \(state), at \(size)"
                        let expected = try XCTUnwrap(reference[part], label)
                        XCTAssertEqual(try XCTUnwrap(parts[part], label).minX, expected.minX, label)
                    }
                }
            }
        }
    }

    @MainActor
    func testIdentitySlotEndsAtTheStackControlOrOtherwiseAtTheChangesColumn() throws {
        for size in MenuSize.allCases {
            let metrics = MenuMetrics(scale: size.factor)
            let cards = memberCards(title: Self.longTitle, draft: false, stackControl: Self.stackControlStandIn)
            for (name, card) in cards {
                let measured = measure(card, width: 800 * size.factor, metrics: metrics)
                let identity = try XCTUnwrap(measured.parts[.identity], name)
                let changes = try XCTUnwrap(measured.columns.first, name)
                if let control = measured.parts[.stackControl] {
                    XCTAssertEqual(name, "collapsed stacked card")
                    let tolerance = measured.edgeTolerance
                    XCTAssertEqual(control.minX - identity.maxX, metrics.prColumns.spacing, accuracy: tolerance, "\(name) at \(size)")
                    XCTAssertEqual(changes.minX - control.maxX, metrics.prColumns.spacing, accuracy: tolerance, "\(name) at \(size)")
                    let title = try XCTUnwrap(measured.parts[.title], name)
                    XCTAssertLessThanOrEqual(title.maxX, identity.maxX + 0.5, "the long title stops at the control at \(size)")
                } else {
                    XCTAssertEqual(
                        changes.minX - identity.maxX, metrics.prColumns.spacing, accuracy: measured.edgeTolerance, "\(name) at \(size)"
                    )
                }
            }
        }
    }

    /// Renders `view` at `width` on a white background in the light appearance.
    @MainActor
    private func renderBitmap(_ view: some View, width: CGFloat, metrics: MenuMetrics = .standard) throws
        -> (bitmap: NSBitmapImageRep, measurement: CardMeasurement) {
        let measurement = measure(view, width: width, metrics: metrics)
        let content = view
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.white)
            .environment(\.menuMetrics, metrics)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(x: 0, y: 0, width: width, height: measurement.height)
        let host = OffScreenHost(hostingView)
        defer { host.close() }
        host.window.appearance = NSAppearance(named: .aqua)
        hostingView.layoutSubtreeIfNeeded()
        host.settle()
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return (bitmap, measurement)
    }

    /// The pixels inside `rect`, given in points from the top-leading corner.
    private func pixels(of bitmap: NSBitmapImageRep, in rect: CGRect, viewWidth: CGFloat) -> [UInt32] {
        let scale = CGFloat(bitmap.pixelsWide) / viewWidth
        var result: [UInt32] = []
        for y in Int((rect.minY * scale).rounded())..<Int((rect.maxY * scale).rounded()) {
            for x in Int((rect.minX * scale).rounded())..<Int((rect.maxX * scale).rounded()) {
                var pixel = [Int](repeating: 0, count: 4)
                bitmap.getPixel(&pixel, atX: x, y: y)
                result.append(pixel.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1 & 0xFF) })
            }
        }
        return result
    }

    @MainActor
    func testAContextCardDimsItsAvatarButNotItsStackControl() throws {
        let width: CGFloat = 800
        let entry = Self.contextEntry(draft: false)
        let pullRequest = Self.pullRequest(title: Self.longTitle, draft: false)
        let context = try renderBitmap(StackContextCard(
            entry: entry, repo: pullRequest.repo, stackControl: Self.stackControlStandIn
        ) {}, width: width)
        let requested = try renderBitmap(PullRequestRow(
            pullRequest: pullRequest, isAttention: false, isPinned: false, isHidden: false,
            toggleHide: {}, togglePin: {}, stackControl: Self.stackControlStandIn, action: {}
        ), width: width)

        let contextControl = try XCTUnwrap(context.measurement.parts[.stackControl])
        XCTAssertEqual(contextControl, requested.measurement.parts[.stackControl])
        XCTAssertTrue(
            pixels(of: context.bitmap, in: contextControl, viewWidth: width)
                == pixels(of: requested.bitmap, in: contextControl, viewWidth: width),
            "the control on a context card renders at full strength"
        )
        let avatar = try XCTUnwrap(context.measurement.parts[.avatar])
        XCTAssertEqual(avatar, requested.measurement.parts[.avatar])
        XCTAssertFalse(
            pixels(of: context.bitmap, in: avatar, viewWidth: width)
                == pixels(of: requested.bitmap, in: avatar, viewWidth: width),
            "the context card's avatar is dimmed"
        )
    }

    @MainActor
    func testContainerRowChromeDrawsNoBorderOrFill() throws {
        let width: CGFloat = 800
        let pullRequest = Self.pullRequest(title: "Member", draft: false)
        func row(_ chrome: PullRequestCardChrome) -> some View {
            PullRequestRow(
                pullRequest: pullRequest, isAttention: false, isPinned: false, isHidden: false,
                toggleHide: {}, togglePin: {}, chrome: chrome, action: {}
            )
        }
        let card = try renderBitmap(row(.card), width: width)
        let containerRow = try renderBitmap(row(.containerRow), width: width)
        let white = UInt32(0xFFFF_FFFF)
        // The leading edge and the leading padding, at mid-height.
        let edge = CGRect(x: 0, y: card.measurement.height / 2, width: 1, height: 1)
        let padding = CGRect(x: 2, y: card.measurement.height / 2, width: 1, height: 1)

        let cardEdge = pixels(of: card.bitmap, in: edge, viewWidth: width)
        XCTAssertNotEqual(cardEdge, [UInt32](repeating: white, count: cardEdge.count), "a card draws its border")
        for rect in [edge, padding] {
            let rendered = pixels(of: containerRow.bitmap, in: rect, viewWidth: width)
            XCTAssertFalse(rendered.isEmpty)
            XCTAssertEqual(rendered, [UInt32](repeating: white, count: rendered.count), "\(rect)")
        }
        XCTAssertEqual(containerRow.measurement.height, card.measurement.height)
    }

    @MainActor
    func testExpandedContainerIsExactlyTheMemberCountTimesTheCardHeight() throws {
        let group = try XCTUnwrap(try prStacksGroup("STACK_MOCK_SPREAD").row.stack)
        for size in MenuSize.allCases {
            let metrics = MenuMetrics(scale: size.factor)
            let width = 800 * size.factor
            let cards = memberCards(title: Self.longTitle, draft: false)
            // As many ordinary cards, stacked without gaps, so fractional sizes round the same way.
            let ordinaryCards = VStack(spacing: 0) {
                ForEach(group.members, id: \.pullRequestID) { _ in cards[0].1 }
            }
            // Requested member rows and context rows, alternating.
            let container = StackMemberContainer(group: group, isUnread: false) { _, position in
                cards[2 + position % 2].1
            }
            XCTAssertEqual(
                measure(container, width: width, metrics: metrics).height,
                measure(ordinaryCards, width: width, metrics: metrics).height,
                "\(size)"
            )
        }
    }

    @MainActor
    func testExpandedContainerUsesTheAccentBorderOnlyForAnUnreadGroup() throws {
        let group = try XCTUnwrap(try prStacksGroup("STACK_MOCK_SPREAD").row.stack)
        let width: CGFloat = 800
        let cards = memberCards(title: "Member", draft: false)
        func container(isUnread: Bool) -> some View {
            StackMemberContainer(group: group, isUnread: isUnread) { _, position in cards[2 + position % 2].1 }
        }
        let read = try renderBitmap(container(isUnread: false), width: width)
        let unread = try renderBitmap(container(isUnread: true), width: width)
        let ordinary = try renderBitmap(cards[0].1, width: width)
        let edge = CGRect(x: 0, y: ordinary.measurement.height / 2, width: 1, height: 1)

        XCTAssertEqual(
            pixels(of: read.bitmap, in: edge, viewWidth: width),
            pixels(of: ordinary.bitmap, in: edge, viewWidth: width),
            "a read group has the ordinary neutral card border"
        )
        XCTAssertNotEqual(
            pixels(of: unread.bitmap, in: edge, viewWidth: width),
            pixels(of: read.bitmap, in: edge, viewWidth: width),
            "an unread group has the accent border"
        )
    }

    /// The width `view` takes when it is offered all the width it wants.
    @MainActor
    private func intrinsicWidth(_ view: some View, metrics: MenuMetrics) -> CGFloat {
        NSHostingView(rootView: view.fixedSize().environment(\.menuMetrics, metrics)).fittingSize.width
    }

    @MainActor
    func testTheWidestChangeCountsFitTheChangesColumnUnscaled() {
        // The widest labels of realistic counts, below 10 million lines: "+999k", "+9.9m" and "+10m".
        let widest = [999_499, 9_949_999, 9_999_999].flatMap { value in
            [PullRequestChangesPresentation.additionsText(value), PullRequestChangesPresentation.deletionsText(value)]
        }
        for size in MenuSize.allCases {
            let metrics = MenuMetrics(scale: size.factor)
            for text in widest {
                let width = intrinsicWidth(Text(text).font(metrics.type.metricValue.font), metrics: metrics)
                XCTAssertLessThanOrEqual(width, metrics.prColumns.changesWidth, "\(text) at \(size)")
            }
        }
    }

    @MainActor
    func testLongContextTitlesTruncateBeforeTheirFullWidthBadges() throws {
        let smallest = try XCTUnwrap(MenuSize.allCases.min { $0.factor < $1.factor })
        for size in [smallest, .standard] {
            let layout = MenuPanelSize.resolve(availableFrame: Self.largerTextFrame, menuSize: size)
            let metrics = layout.metrics
            let width = metrics.prList.cardWidth(inPanelWidth: layout.size.width)
            let titleIdealWidth = intrinsicWidth(Text(Self.longTitle).font(metrics.type.cardTitle.font), metrics: metrics)
            let draftWidth = intrinsicWidth(StackMemberBadgeView(badge: .draft), metrics: metrics)
            for state in [PullRequestStackEntry.State.open, .merged, .closed] {
                for (draft, withControl) in [(false, false), (true, false), (true, true)] {
                    let label = "\(state), draft: \(draft), control: \(withControl), at \(size)"
                    let card = StackContextCard(
                        entry: Self.contextEntry(draft: draft, state: state),
                        repo: "mergehawk-labs/mergehawk",
                        chrome: .containerRow,
                        stackControl: withControl ? AnyView(StackControl(
                            presentation: StackControlPresentation(group: Self.stackGroup(), displayedPosition: 1, isExpanded: true)
                        ) {}) : nil
                    ) {}
                    let parts = measure(card, width: width, metrics: metrics).parts
                    let title = try XCTUnwrap(parts[.title], label)
                    let badge = try XCTUnwrap(parts[.stateBadge], label)
                    let stateBadge: StackMemberBadge = switch state {
                    case .open: .open
                    case .merged: .merged
                    case .closed: .closed
                    }
                    XCTAssertEqual(
                        badge.width, intrinsicWidth(StackMemberBadgeView(badge: stateBadge), metrics: metrics),
                        accuracy: 0.5, "full state badge, \(label)"
                    )
                    XCTAssertLessThan(title.width, titleIdealWidth - 1, "the title truncates, \(label)")
                    if draft {
                        let draftBadge = try XCTUnwrap(parts[.draftBadge], label)
                        XCTAssertEqual(draftBadge.width, draftWidth, accuracy: 0.5, "full Draft badge, \(label)")
                        XCTAssertLessThanOrEqual(title.maxX, draftBadge.minX + 0.5, "the title ends before Draft, \(label)")
                        XCTAssertLessThanOrEqual(draftBadge.maxX, badge.minX + 0.5, "Draft before the state, \(label)")
                    } else {
                        XCTAssertNil(parts[.draftBadge], label)
                        XCTAssertLessThanOrEqual(title.maxX, badge.minX + 0.5, "the title ends before the badge, \(label)")
                    }
                    let identity = try XCTUnwrap(parts[.identity], label)
                    XCTAssertLessThanOrEqual(badge.maxX, identity.maxX + 0.5, "the badge stays in the identity slot, \(label)")
                    if withControl {
                        let control = try XCTUnwrap(parts[.stackControl], label)
                        XCTAssertLessThanOrEqual(badge.maxX, control.minX - metrics.prColumns.spacing + 0.5, label)
                    }
                }
            }
        }
    }

    @MainActor
    func testLongDraftPRTitlesTruncateBeforeAFullWidthDraftBadgeAndTheStackControl() throws {
        let smallest = try XCTUnwrap(MenuSize.allCases.min { $0.factor < $1.factor })
        for size in [smallest, .standard] {
            let layout = MenuPanelSize.resolve(availableFrame: Self.largerTextFrame, menuSize: size)
            let metrics = layout.metrics
            let width = metrics.prList.cardWidth(inPanelWidth: layout.size.width)
            let titleIdealWidth = intrinsicWidth(Text(Self.longTitle).font(metrics.type.cardTitle.font), metrics: metrics)
            let draftWidth = intrinsicWidth(DraftPullRequestIndicator(), metrics: metrics)
            // An unstacked card, a collapsed stacked card, and a requested member row.
            for (name, card) in memberCards(title: Self.longTitle, draft: true).prefix(3) {
                let label = "\(name) at \(size)"
                let parts = measure(card, width: width, metrics: metrics).parts
                let title = try XCTUnwrap(parts[.title], label)
                let draftBadge = try XCTUnwrap(parts[.draftBadge], label)
                let identity = try XCTUnwrap(parts[.identity], label)
                XCTAssertLessThan(title.width, titleIdealWidth - 1, "the title truncates, \(label)")
                XCTAssertEqual(draftBadge.width, draftWidth, accuracy: 0.5, "full Draft badge, \(label)")
                XCTAssertLessThanOrEqual(title.maxX, draftBadge.minX + 0.5, "the title ends before Draft, \(label)")
                XCTAssertLessThanOrEqual(draftBadge.maxX, identity.maxX + 0.5, "Draft stays in the identity slot, \(label)")
                if let control = parts[.stackControl] {
                    XCTAssertLessThanOrEqual(draftBadge.maxX, control.minX - metrics.prColumns.spacing + 0.5, label)
                }
            }
        }
    }

    @MainActor
    func testALongUnstackedTitleReachesTheChangesColumnPastAStackControl() throws {
        for size in MenuSize.allCases {
            let layout = MenuPanelSize.resolve(availableFrame: Self.largerTextFrame, menuSize: size)
            let width = layout.metrics.prList.cardWidth(inPanelWidth: layout.size.width)
            let cards = memberCards(title: Self.longTitle, draft: false)
            let unstacked = measure(cards[0].1, width: width, metrics: layout.metrics)
            let stacked = measure(cards[1].1, width: width, metrics: layout.metrics)
            let title = try XCTUnwrap(unstacked.parts[.title])
            let neighbouringControl = try XCTUnwrap(stacked.parts[.stackControl])
            let changes = try XCTUnwrap(unstacked.columns.first)

            // The truncated title ends at its last glyph, within a few points of the changes column.
            XCTAssertGreaterThan(title.maxX, neighbouringControl.midX, "\(size)")
            XCTAssertLessThanOrEqual(title.maxX, changes.minX - layout.metrics.prColumns.spacing + 0.5, "\(size)")
        }
    }

    @MainActor
    func testContextRowsLeaveEveryValueColumnEmpty() throws {
        let width: CGFloat = 800
        let row = try renderBitmap(StackContextCard(
            entry: Self.contextEntry(draft: false, state: .merged), repo: "mergehawk-labs/mergehawk", chrome: .containerRow
        ) {}, width: width)
        let requested = try renderBitmap(PullRequestRow(
            pullRequest: Self.pullRequest(title: "Member", draft: false), isAttention: false, isPinned: false, isHidden: false,
            toggleHide: {}, togglePin: {}, chrome: .containerRow, showsActions: false, action: {}
        ), width: width)
        let white = UInt32(0xFFFF_FFFF)
        XCTAssertEqual(row.measurement.columns.count, 7)
        for (index, column) in row.measurement.columns.enumerated() {
            let rendered = pixels(of: row.bitmap, in: column, viewWidth: width)
            XCTAssertFalse(rendered.isEmpty)
            XCTAssertTrue(rendered.allSatisfy { $0 == white }, "column \(index) is empty")
        }
        let requestedChanges = try XCTUnwrap(requested.measurement.columns.first)
        XCTAssertFalse(
            pixels(of: requested.bitmap, in: requestedChanges, viewWidth: width).allSatisfy { $0 == white },
            "a requested row draws its values"
        )
    }

    private final class ConnectorFrames {
        var avatars: [String: CGRect] = [:]
        var connectors: [CGRect] = []
    }

    @MainActor
    func testExpandedStackJoinsConsecutiveAvatarsWithAGappedLineAtEveryMenuSize() throws {
        let group = try XCTUnwrap(try prStacksGroup("STACK_MOCK_SPREAD").row.stack)
        for size in MenuSize.allCases {
            let metrics = MenuMetrics(scale: size.factor)
            let width = 800 * size.factor
            let cards = memberCards(title: Self.longTitle, draft: false)
            let container = StackMemberContainer(group: group, isUnread: false) { _, position in cards[2 + position % 2].1 }
            let box = ConnectorFrames()
            let hosted = container
                .overlayPreferenceValue(StackMemberAvatarAnchorsKey.self) { anchors in
                    GeometryReader { proxy in
                        Color.clear.onAppear { box.avatars = anchors.mapValues { proxy[$0] } }
                    }
                }
                .overlayPreferenceValue(StackConnectorAnchorsKey.self) { anchors in
                    GeometryReader { proxy in
                        Color.clear.onAppear { box.connectors = anchors.map { proxy[$0] } }
                    }
                }
            let tolerance = measure(hosted, width: width, metrics: metrics).edgeTolerance

            let avatars = try group.members.map { try XCTUnwrap(box.avatars[$0.pullRequestID], "\(size)") }
            let segments = box.connectors.sorted { $0.minY < $1.minY }
            XCTAssertEqual(segments.count, group.members.count - 1, "\(size)")
            let gap = metrics.prRow.stackConnectorGap
            for (index, segment) in segments.enumerated() {
                let label = "segment \(index) at \(size)"
                XCTAssertEqual(segment.midX, avatars[index].midX, accuracy: tolerance, label)
                XCTAssertEqual(segment.width, metrics.prRow.stackConnectorWidth, accuracy: tolerance, label)
                XCTAssertEqual(segment.minY, avatars[index].maxY + gap, accuracy: tolerance, label)
                XCTAssertEqual(segment.maxY, avatars[index + 1].minY - gap, accuracy: tolerance, label)
            }

            // The line adds no height: the container stays as tall as the same number of ordinary cards.
            let ordinaryCards = VStack(spacing: 0) {
                ForEach(group.members, id: \.pullRequestID) { _ in cards[0].1 }
            }
            XCTAssertEqual(
                measure(container, width: width, metrics: metrics).height,
                measure(ordinaryCards, width: width, metrics: metrics).height,
                "\(size)"
            )
        }
    }

    // MARK: - Expanded stacks in the menu

    private struct ResolvedStackControl: Equatable {
        let frame: CGRect
        let fractionText: String
    }

    /// Frames in the hosted menu, top-left origin, as the menu last laid them out.
    private final class StackMenuFrames {
        var controls: [String: ResolvedStackControl] = [:]
        var rows: [String: CGRect] = [:]
        var positionLabels: [String: CGRect] = [:]
        var connectors: [CGRect] = []
        /// Every rendered card's value and actions columns.
        var columns: [CGRect] = []
    }

    @MainActor
    private func stackMenuController(
        filters: Set<DashboardController.ReviewRequestFilterOption>? = nil,
        opened: @escaping (URL) -> Void = { _ in }
    ) throws -> DashboardController {
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: try isolatedDefaults()),
            launchConfiguration: LaunchConfiguration(
                usesMockData: true, suppressesMacOSNotifications: true, mockPullRequestScenario: .prStacks
            ),
            automaticRefreshInterval: 0,
            urlOpener: opened
        )
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil && !controller.isRefreshing }
        controller.selectedTab = .reviewRequests
        if let filters {
            controller.selectedReviewRequestFilters = filters
        }
        return controller
    }

    @MainActor
    private func hostStackMenu(_ controller: DashboardController, frames: StackMenuFrames) -> (host: OffScreenHost, view: NSView) {
        let size = MenuMetrics.standard.panelSize
        let root = MenuRootView(controller: controller, footerModel: MenuFooterModel(), tooltipController: MenuTooltipController())
            .overlayPreferenceValue(StackControlAnchorsKey.self) { anchors in
                GeometryReader { proxy in
                    let resolved = anchors.mapValues { ResolvedStackControl(frame: proxy[$0.bounds], fractionText: $0.fractionText) }
                    Color.clear
                        .onAppear { frames.controls = resolved }
                        .onChange(of: resolved) { _, new in frames.controls = new }
                }
            }
            .overlayPreferenceValue(StackMemberRowAnchorsKey.self) { anchors in
                GeometryReader { proxy in
                    let resolved = anchors.mapValues { proxy[$0] }
                    Color.clear
                        .onAppear { frames.rows = resolved }
                        .onChange(of: resolved) { _, new in frames.rows = new }
                }
            }
            .overlayPreferenceValue(PullRequestCardColumnAnchorsKey.self) { anchors in
                GeometryReader { proxy in
                    let resolved = anchors.map { proxy[$0] }
                    Color.clear
                        .onAppear { frames.columns = resolved }
                        .onChange(of: resolved) { _, new in frames.columns = new }
                }
            }
            .overlayPreferenceValue(StackConnectorAnchorsKey.self) { anchors in
                GeometryReader { proxy in
                    let resolved = anchors.map { proxy[$0] }
                    Color.clear
                        .onAppear { frames.connectors = resolved }
                        .onChange(of: resolved) { _, new in frames.connectors = new }
                }
            }
            .overlayPreferenceValue(StackPositionLabelAnchorsKey.self) { anchors in
                GeometryReader { proxy in
                    let resolved = anchors.mapValues { proxy[$0] }
                    Color.clear
                        .onAppear { frames.positionLabels = resolved }
                        .onChange(of: resolved) { _, new in frames.positionLabels = new }
                }
            }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(origin: .zero, size: size)
        return (OffScreenHost(hostingView), hostingView)
    }

    @MainActor
    private func relayout(_ host: OffScreenHost) {
        host.window.contentView?.layoutSubtreeIfNeeded()
        host.settle()
        host.window.contentView?.layoutSubtreeIfNeeded()
        host.settle()
    }

    /// Lets a clicked stack control's expand or collapse animation finish, so frames are read at rest whether or
    /// not Reduce Motion is on.
    @MainActor
    private func settleStackToggle(_ host: OffScreenHost) {
        RunLoop.main.run(until: Date().addingTimeInterval(StackExpansionAnimation.duration + 0.1))
        relayout(host)
    }

    private static let spreadMemberIDs = (1...4).map { "PR_STACK_MOCK_SPREAD_\($0)" }

    @MainActor
    func testTogglingAStackKeepsItsControlUnderThePointerInAScrolledList() throws {
        // The position-3 stack is the oldest Direct card; the reversed sort moves it away from the end of the list,
        // where collapsing shrinks the content below the scroll offset and the scroll view clamps it (accepted).
        let cases: [(stackID: String, size: Int, representative: Int, reversesSort: Bool)] = [
            ("STACK_MOCK_SPREAD", 4, 2, false),
            ("STACK_MOCK_POSITION_3", 3, 3, true)
        ]
        for testCase in cases {
            let label = testCase.stackID
            let controller = try stackMenuController()
            if testCase.reversesSort {
                controller.reviewRequestSortDirection = controller.reviewRequestSortDirection.toggled
            }
            let visibleRows = controller.requestedSections.flatMap(\.visible)
            XCTAssertGreaterThan(
                try XCTUnwrap(visibleRows.firstIndex { $0.stack?.stack.id == testCase.stackID }, label), 0,
                "other cards sit above the group, \(label)"
            )
            // Every other group expanded makes the list long enough to scroll.
            for other in visibleRows.compactMap(\.stack?.stack.id) where other != testCase.stackID {
                controller.toggleStackExpanded(other)
            }
            let frames = StackMenuFrames()
            let (host, view) = hostStackMenu(controller, frames: frames)
            defer { host.close() }

            // Scroll the list until the group sits in the upper part of the list, at a nonzero offset.
            let scrollView = try XCTUnwrap(scrollViews(in: view).first { $0.documentView != nil }, label)
            var offset: CGFloat = 0
            repeat {
                offset += 30
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                relayout(host)
            } while (frames.controls[testCase.stackID].map { $0.frame.minY > 400 } ?? true) && offset < 3_000
            XCTAssertEqual(scrollView.contentView.bounds.minY, offset, "the list scrolled, \(label)")
            let collapsed = try XCTUnwrap(frames.controls[testCase.stackID], label)
            XCTAssertGreaterThan(collapsed.frame.minY, 100, label)
            XCTAssertEqual(collapsed.fractionText, "\(testCase.representative)/\(testCase.size)", label)

            try click(host, atTopLeft: CGPoint(x: collapsed.frame.midX, y: collapsed.frame.midY))
            settleStackToggle(host)
            XCTAssertTrue(controller.isStackExpanded(testCase.stackID), label)
            XCTAssertEqual(scrollView.contentView.bounds.minY, offset, "expanding keeps the offset, \(label)")
            let expanded = try XCTUnwrap(frames.controls[testCase.stackID], label)
            XCTAssertEqual(expanded.frame, collapsed.frame, "expanded, \(label)")
            XCTAssertEqual(expanded.fractionText, "\(testCase.size)/\(testCase.size)", label)
            let topRow = try XCTUnwrap(frames.rows["PR_\(testCase.stackID)_\(testCase.size)"], label)
            XCTAssertTrue(topRow.contains(expanded.frame), "the control sits on the top row, \(label)")

            try click(host, atTopLeft: CGPoint(x: expanded.frame.midX, y: expanded.frame.midY))
            settleStackToggle(host)
            XCTAssertFalse(controller.isStackExpanded(testCase.stackID), label)
            let collapsedAgain = try XCTUnwrap(frames.controls[testCase.stackID], label)
            XCTAssertEqual(collapsedAgain, collapsed, "collapsed again, \(label)")
        }
    }

    // MARK: - PR list scroller

    @MainActor
    private func listScrollView(in view: NSView) throws -> NSScrollView {
        try XCTUnwrap(scrollViews(in: view).first { $0.documentView != nil })
    }

    private func isScrollable(_ scrollView: NSScrollView) -> Bool {
        (scrollView.documentView?.frame.height ?? 0) > scrollView.contentView.bounds.height + 0.5
    }

    /// The distinct x-positions and widths of every rendered card column, rounded to the point.
    private func columnLayout(_ frames: StackMenuFrames) -> Set<[CGFloat]> {
        Set(frames.columns.map { [$0.minX.rounded(), $0.width.rounded()] })
    }

    @MainActor
    func testCardsAndStackControlsKeepTheirXWhenTheListBecomesScrollable() throws {
        // As in the live inspection: Assigned collapsed, so Direct and Team fit until a Direct stack expands.
        for (stackID, representative) in [("STACK_MOCK_SPREAD", "2/4"), ("STACK_MOCK_POSITION_3", "3/3")] {
            let controller = try stackMenuController()
            controller.toggleRequestedSection(.assigned)
            let frames = StackMenuFrames()
            let (host, view) = hostStackMenu(controller, frames: frames)
            defer { host.close() }
            let scrollView = try listScrollView(in: view)
            // Whatever this host's scrollbar setting, reset the list to the legacy style the inspected Mac used, as
            // AppKit and SwiftUI do. The list's style view restores the overlay style before the next layout.
            scrollView.scrollerStyle = .legacy
            XCTAssertEqual(scrollView.scrollerStyle, .overlay, "restored at once, \(stackID)")
            relayout(host)
            XCTAssertFalse(isScrollable(scrollView), "the list fits before expanding, \(stackID)")
            let collapsed = try XCTUnwrap(frames.controls[stackID], stackID)
            XCTAssertEqual(collapsed.fractionText, representative)
            let columns = columnLayout(frames)
            XCTAssertEqual(columns.count, 7, stackID)
            let otherControls = frames.controls.filter { $0.key != stackID }.mapValues(\.frame)

            controller.toggleStackExpanded(stackID)
            relayout(host)
            XCTAssertTrue(isScrollable(scrollView), "expanding makes the list scrollable, \(stackID)")
            XCTAssertEqual(scrollView.scrollerStyle, .overlay, stackID)
            XCTAssertEqual(scrollView.verticalScroller?.controlSize, .small, stackID)
            XCTAssertEqual(frames.controls[stackID]?.frame, collapsed.frame, "expanded, \(stackID)")
            XCTAssertEqual(columnLayout(frames), columns, "expanded, \(stackID)")
            for (id, frame) in otherControls {
                XCTAssertEqual(frames.controls[id]?.frame.minX, frame.minX, "\(id) while \(stackID) is expanded")
                XCTAssertEqual(frames.controls[id]?.frame.width, frame.width, "\(id) while \(stackID) is expanded")
            }

            // A reset while the list scrolls, as macOS 15 makes after the content grows, is undone the same way.
            scrollView.scrollerStyle = .legacy
            relayout(host)
            XCTAssertEqual(scrollView.scrollerStyle, .overlay, "restored while scrollable, \(stackID)")
            XCTAssertEqual(scrollView.verticalScroller?.controlSize, .small, "restored while scrollable, \(stackID)")
            XCTAssertEqual(frames.controls[stackID]?.frame, collapsed.frame, "restored while scrollable, \(stackID)")
            XCTAssertEqual(columnLayout(frames), columns, "restored while scrollable, \(stackID)")

            controller.toggleStackExpanded(stackID)
            relayout(host)
            XCTAssertFalse(isScrollable(scrollView), "collapsing makes the list fit again, \(stackID)")
            XCTAssertEqual(frames.controls[stackID], collapsed, "collapsed again, \(stackID)")
            XCTAssertEqual(columnLayout(frames), columns, "collapsed again, \(stackID)")
        }
    }

    @MainActor
    func testPRListsUseTheSlimOverlayScrollerAndRestoreItAfterThePreferenceChanges() throws {
        let controller = try stackMenuController()
        for tab in [DashboardController.MenuTab.myPRs, .reviewRequests] {
            controller.selectedTab = tab
            let (host, view) = hostStackMenu(controller, frames: StackMenuFrames())
            defer { host.close() }
            let scrollView = try listScrollView(in: view)
            XCTAssertEqual(scrollView.scrollerStyle, .overlay, "\(tab)")
            XCTAssertEqual(scrollView.verticalScroller?.controlSize, .small, "\(tab)")

            // AppKit resets every scroll view to the system style when the preference changes.
            scrollView.scrollerStyle = .legacy
            XCTAssertEqual(scrollView.scrollerStyle, .overlay, "restored at once, \(tab)")
            NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            host.settle()
            XCTAssertEqual(scrollView.scrollerStyle, .overlay, "restored, \(tab)")
            XCTAssertEqual(scrollView.verticalScroller?.controlSize, .small, "restored, \(tab)")
        }
    }

    @MainActor
    func testTheScrollerSitsRightOfEveryCard() throws {
        let controller = try stackMenuController()
        controller.toggleStackExpanded("STACK_MOCK_SPREAD")
        let frames = StackMenuFrames()
        let (host, view) = hostStackMenu(controller, frames: frames)
        defer { host.close() }
        let scrollView = try listScrollView(in: view)
        XCTAssertTrue(isScrollable(scrollView))
        let scroller = try XCTUnwrap(scrollView.verticalScroller)
        let scrollerFrame = scroller.convert(scroller.bounds, to: view)
        XCTAssertGreaterThan(scrollerFrame.width, 0)
        XCTAssertEqual(scrollerFrame.width, PullRequestListScroller.width, accuracy: 0.5)

        let cardMaxX = try XCTUnwrap(frames.rows.values.map(\.maxX).max())
        let cardWidth = try XCTUnwrap(frames.rows.values.first?.width)
        XCTAssertEqual(cardWidth, MenuMetrics.standard.prList.cardWidth(inPanelWidth: view.bounds.width), accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(
            scrollerFrame.minX, cardMaxX + MenuMetrics.standard.prList.scrollerGap - 0.5,
            "the scroller and its gap sit in the list's right margin"
        )
        let actionsMaxX = try XCTUnwrap(frames.columns.map(\.maxX).max())
        XCTAssertLessThan(actionsMaxX, scrollerFrame.minX)
    }

    @MainActor
    func testAuthoredAndRequestedCardsShareOneWidth() throws {
        let controller = try stackMenuController()
        var layouts: [Set<[CGFloat]>] = []
        for tab in [DashboardController.MenuTab.myPRs, .reviewRequests] {
            controller.selectedTab = tab
            let frames = StackMenuFrames()
            let (host, _) = hostStackMenu(controller, frames: frames)
            defer { host.close() }
            XCTAssertFalse(frames.columns.isEmpty, "\(tab)")
            layouts.append(columnLayout(frames))
        }
        XCTAssertEqual(layouts[0], layouts[1])
        XCTAssertEqual(layouts[0].count, 7)
    }

    @MainActor
    func testClickingEachExpandedRowOpensItsMemberAndTheControlOnlyToggles() throws {
        var opened: [String] = []
        let controller = try stackMenuController { opened.append($0.absoluteString) }
        controller.toggleStackExpanded("STACK_MOCK_SPREAD")
        let frames = StackMenuFrames()
        let (host, _) = hostStackMenu(controller, frames: frames)
        defer { host.close() }
        let columns = MenuMetrics.standard.prColumns

        for id in Self.spreadMemberIDs {
            let row = try XCTUnwrap(frames.rows[id], id)
            let titleX = row.minX + columns.horizontalInset + columns.avatarSize + columns.identitySpacing + 4
            try click(host, atTopLeft: CGPoint(x: titleX, y: row.minY + columns.verticalInset + 4))
        }
        XCTAssertEqual(opened, (201...204).map { "https://github.com/mergehawk-labs/mergehawk/pull/\($0)" })

        // The avatar line takes no clicks: a click on it, just below the top avatar, opens the top member.
        let firstSegment = try XCTUnwrap(frames.connectors.min { $0.minY < $1.minY })
        try click(host, atTopLeft: CGPoint(x: firstSegment.midX, y: firstSegment.minY + 1))
        XCTAssertEqual(opened.last, "https://github.com/mergehawk-labs/mergehawk/pull/204")
        opened.removeLast()

        // The top row, position 4, is the viewer's own context member; its control stays fully operable.
        let control = try XCTUnwrap(frames.controls["STACK_MOCK_SPREAD"])
        XCTAssertTrue(try XCTUnwrap(frames.rows[Self.spreadMemberIDs[3]]).contains(control.frame))
        try click(host, atTopLeft: CGPoint(x: control.frame.minX + 3, y: control.frame.midY))
        XCTAssertFalse(controller.isStackExpanded("STACK_MOCK_SPREAD"))
        XCTAssertEqual(opened.count, 4, "the control opens nothing")
    }

    @MainActor
    func testOnlyTheRepresentativeRowHasTheActionsButtonWhereverItLands() throws {
        var opened: [String] = []
        let controller = try stackMenuController { opened.append($0.absoluteString) }
        controller.toggleStackExpanded("STACK_MOCK_SPREAD")
        let frames = StackMenuFrames()
        let (host, _) = hostStackMenu(controller, frames: frames)
        defer { host.close() }
        let columns = MenuMetrics.standard.prColumns
        func clickActionsColumn(_ id: String) throws {
            let row = try XCTUnwrap(frames.rows[id], id)
            try click(host, atTopLeft: CGPoint(x: row.maxX - columns.horizontalInset - columns.actionsWidth / 2, y: row.midY))
        }

        // Position 2 is the representative, below the position-1 context row. Elsewhere the empty actions column
        // is part of the card, so a click there opens that member.
        for id in [Self.spreadMemberIDs[0], Self.spreadMemberIDs[2], Self.spreadMemberIDs[3]] {
            try clickActionsColumn(id)
        }
        XCTAssertEqual(opened, [201, 203, 204].map { "https://github.com/mergehawk-labs/mergehawk/pull/\($0)" })
        try clickActionsColumn(Self.spreadMemberIDs[1])
        XCTAssertEqual(opened.count, 3, "the representative row's actions button takes the click")
    }

    @MainActor
    func testOnlyRowsBelowTheTopShowTheirStackPosition() throws {
        let controller = try stackMenuController()
        let frames = StackMenuFrames()
        let (host, _) = hostStackMenu(controller, frames: frames)
        defer { host.close() }
        XCTAssertFalse(frames.controls.isEmpty)
        XCTAssertEqual(frames.positionLabels, [:], "collapsed cards show no metadata position")
        XCTAssertEqual(frames.connectors, [], "collapsed and unstacked cards have no avatar line")

        controller.toggleStackExpanded("STACK_MOCK_SPREAD")
        relayout(host)

        XCTAssertEqual(Set(frames.positionLabels.keys), Set(Self.spreadMemberIDs.dropLast()))
        for position in 1...3 {
            let id = Self.spreadMemberIDs[position - 1]
            let row = try XCTUnwrap(frames.rows[id])
            let label = try XCTUnwrap(frames.positionLabels[id])
            XCTAssertTrue(row.contains(label), "position \(position)")
            XCTAssertGreaterThan(label.midY, row.midY, "on the metadata line, position \(position)")
        }
        XCTAssertEqual(frames.controls["STACK_MOCK_SPREAD"]?.fractionText, "4/4")
        XCTAssertEqual(frames.connectors.count, 3, "one segment per consecutive pair of the four members")
    }

    @MainActor
    func testOnlyTheRepresentativeMemberHasAnActionsButton() throws {
        let pullRequest = Self.pullRequest(title: "Member", draft: false)
        for showsActions in [true, false] {
            var opened = 0
            var toggledActions = 0
            let row = PullRequestRow(
                pullRequest: pullRequest, isAttention: false, isPinned: false, isHidden: false,
                toggleActions: { toggledActions += 1 }, toggleHide: {}, togglePin: {},
                showsActions: showsActions
            ) { opened += 1 }
            let (host, view) = self.host(row, width: 800)
            defer { host.close() }

            try click(host, atTopLeft: RowPoints(width: view.bounds.width, height: view.bounds.height).actionsButton)

            XCTAssertEqual(toggledActions, showsActions ? 1 : 0, "shows actions: \(showsActions)")
            XCTAssertEqual(opened, showsActions ? 0 : 1, "shows actions: \(showsActions)")
        }
    }

    @MainActor
    func testClickingAContextCardOpensItsEntry() throws {
        var opened = 0
        let card = StackContextCard(entry: Self.contextEntry(draft: false), repo: "mergehawk-labs/mergehawk") {
            opened += 1
        }
        let (host, view) = self.host(card, width: 800)
        defer { host.close() }
        let points = RowPoints(width: view.bounds.width, height: view.bounds.height)

        try click(host, atTopLeft: points.title)
        try click(host, atTopLeft: points.statusColumn)
        try click(host, atTopLeft: points.actionsButton)

        XCTAssertEqual(opened, 3)
    }

    @MainActor
    func testOpeningMembersOpensTheirOwnURLs() throws {
        var opened: [URL] = []
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: try isolatedDefaults()),
            launchConfiguration: LaunchConfiguration(
                usesMockData: true, suppressesMacOSNotifications: true, mockPullRequestScenario: .prStacks
            ),
            automaticRefreshInterval: 0,
            urlOpener: { opened.append($0) }
        )
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil && !controller.isRefreshing }
        let group = try XCTUnwrap(controller.requestedSections.flatMap(\.visible).first {
            $0.stack?.stack.id == "STACK_MOCK_SPREAD"
        }?.stack)

        group.members.forEach(controller.openStackMember)

        XCTAssertEqual(
            opened.map(\.absoluteString), (201...204).reversed().map { "https://github.com/mergehawk-labs/mergehawk/pull/\($0)" }
        )
    }

    @MainActor
    func testCollapsingAnExpandedGroupReturnsToTheSingleCollapsedCard() throws {
        let (controller, row) = try prStacksGroup("STACK_MOCK_SPREAD")
        controller.selectedTab = .reviewRequests
        let stackID = try XCTUnwrap(row.stack?.stack.id)
        let collapsed = try renderMenu(controller)

        controller.toggleStackExpanded(stackID)
        let expanded = try renderMenu(controller)
        controller.toggleStackExpanded(stackID)

        XCTAssertNotEqual(expanded, collapsed)
        XCTAssertEqual(try renderMenu(controller), collapsed)
    }

    @MainActor
    private func renderMenu(_ controller: DashboardController) throws -> Data {
        let size = MenuMetrics.standard.panelSize
        let hostingView = NSHostingView(rootView: MenuRootView(
            controller: controller,
            footerModel: MenuFooterModel(),
            tooltipController: MenuTooltipController()
        )
        .environment(\.menuNow, Date(timeIntervalSince1970: 1_778_100_000)))
        hostingView.frame = CGRect(origin: .zero, size: size)
        let host = OffScreenHost(hostingView)
        defer { host.close() }
        host.window.appearance = NSAppearance(named: .aqua)
        hostingView.layoutSubtreeIfNeeded()
        host.settle()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func host(_ view: some View, width: CGFloat) -> (host: OffScreenHost, view: NSView) {
        let hostingView = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        hostingView.frame = CGRect(origin: .zero, size: CGSize(width: width, height: hostingView.fittingSize.height))
        return (OffScreenHost(hostingView), hostingView)
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
private func signedInMockController(preferencesStore: PreferencesStore = PreferencesStore()) -> DashboardController {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        preferencesStore: preferencesStore,
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
        previousState: PullRequestSyncState?,
        reusableViewerTeams: [ViewerTeam]?
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

extension StackGroup {
    /// The badges of each context member, in position order.
    var contextBadges: [[StackMemberBadge]] {
        members.compactMap { member in
            if case .context(let entry) = member { StackMemberBadge.badges(for: entry) } else { nil }
        }
    }
}

/// Window points in the hosted menu's top bar, from `MenuMetrics.standard`. Window coordinates have their origin at the
/// bottom left, and the top bar is the top `topBar.height` points of the panel. The filter and sort controls move with
/// their title widths, so their frames come from the accessibility tree, as VoiceOver sees them.
@MainActor
private struct TopBarPoints {
    let size: CGSize
    let filterButton: CGRect
    let sortDirection: CGRect
    private let metrics = MenuMetrics.standard

    init(host: OffScreenHost, size: CGSize, controller: DashboardController) throws {
        self.size = size
        filterButton = try accessibilityButtonFrame(labeled: "Filter pull requests", in: host)
        sortDirection = try accessibilityButtonFrame(
            labeled: controller.pullRequestSortOption.directionHelp(for: controller.pullRequestSortDirection),
            in: host
        )
    }

    var midY: CGFloat { size.height - metrics.topBar.height / 2 }
    var aboveControlsY: CGFloat { (size.height + controlsTop) / 2 }
    var belowControlsY: CGFloat { (size.height - metrics.topBar.height + controlsBottom) / 2 }
    private var controlsTop: CGFloat { midY + metrics.controls.height / 2 }
    private var controlsBottom: CGFloat { midY - metrics.controls.height / 2 }

    var leadingInsetMidX: CGFloat { metrics.topBar.leadingInset / 2 }
    var tabSwitcherTrailing: CGFloat {
        metrics.topBar.leadingInset + metrics.tabSwitcher.leadingInset + metrics.tabSwitcher.width
    }
    /// Requested is the last tab segment.
    var requestedTabMidX: CGFloat { tabSwitcherTrailing - metrics.tabSwitcher.textSegmentWidth / 2 }
    /// The sort control starts with its direction part.
    var filterSortGapMidX: CGFloat { (filterButton.maxX + sortDirection.minX) / 2 }
    var sortControlMidX: CGFloat { (sortDirection.minX + sortControlTrailing) / 2 }
    /// The sort control's menu part follows its direction part and a one point divider.
    var sortMenuMidX: CGFloat { (sortDirection.maxX + 1 + sortControlTrailing) / 2 }
    var sortRefreshGapMidX: CGFloat { (sortControlTrailing + refreshControlLeading) / 2 }
    var refreshControlMidX: CGFloat { refreshControlLeading + metrics.topBar.refreshStatusWidth / 2 }
    var trailingInsetMidX: CGFloat { size.width - metrics.topBar.trailingInset / 2 }
    private var refreshControlLeading: CGFloat {
        size.width - metrics.topBar.trailingInset - metrics.topBar.refreshStatusWidth
    }
    private var sortControlTrailing: CGFloat { refreshControlLeading - metrics.topBar.headerControlsTrailingSpacing }

    func filterItem(_ index: Int) -> CGPoint {
        dropdownItem(index, trailing: filterButton.maxX, width: metrics.dropdown.authoredFilterWidth)
    }

    func sortItem(_ index: Int) -> CGPoint {
        dropdownItem(index, trailing: sortControlTrailing, width: metrics.dropdown.sortWidth)
    }

    var filterDropdownBottomPadding: CGPoint {
        let lastIndex = DashboardController.PullRequestFilterOption.allCases.count - 1
        let lastItemBottom = dropdownItemTop(lastIndex) - metrics.dropdown.itemHeight
        return CGPoint(
            x: filterButton.maxX - metrics.dropdown.authoredFilterWidth / 2,
            y: lastItemBottom - metrics.dropdown.verticalPadding / 2
        )
    }

    // A dropdown hangs from its control's top trailing corner, `dropdownOffset` down.
    private func dropdownItem(_ index: Int, trailing: CGFloat, width: CGFloat) -> CGPoint {
        CGPoint(x: trailing - width / 2, y: dropdownItemTop(index) - metrics.dropdown.itemHeight / 2)
    }

    private func dropdownItemTop(_ index: Int) -> CGFloat {
        let dropdown = metrics.dropdown
        return controlsTop - metrics.dropdownOffset - dropdown.verticalPadding
            - CGFloat(index) * (dropdown.itemHeight + dropdown.itemSpacing)
    }
}

/// The window frame of the one accessibility button with this label in the hosted view, found through the in-process
/// NSAccessibility protocol, so it needs no Accessibility permission.
@MainActor
private func accessibilityButtonFrame(labeled label: String, in host: OffScreenHost) throws -> CGRect {
    // SwiftUI builds its accessibility tree only once an assistive client asks for it.
    let enhancedInterface = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    NSApplication.shared.accessibilitySetValue(true, forAttribute: enhancedInterface)
    defer { NSApplication.shared.accessibilitySetValue(false, forAttribute: enhancedInterface) }
    let deadline = Date().addingTimeInterval(2)
    var matches: [NSAccessibilityElementProtocol] = []
    repeat {
        host.settle()
        var queue: [AnyObject] = [try XCTUnwrap(host.window.contentView)]
        var visited: Set<ObjectIdentifier> = []
        matches = []
        var index = 0
        while index < queue.count, visited.count < 5_000 {
            let object = queue[index]
            index += 1
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.accessibilityLabel?() == label, object.accessibilityRole?() == .button,
               let element = object as? NSAccessibilityElementProtocol {
                matches.append(element)
            }
            queue += ((object.accessibilityChildren?() ?? nil) ?? []).map { $0 as AnyObject }
        }
    } while matches.isEmpty && Date() < deadline
    XCTAssertEqual(matches.count, 1, "buttons labeled \(label)")
    let screenFrame = try XCTUnwrap(matches.first).accessibilityFrame()
    return host.window.convertFromScreen(screenFrame)
}
