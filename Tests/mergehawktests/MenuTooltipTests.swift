@testable import mergehawk
import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest

final class MenuTooltipTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let delay = MenuTooltipMetrics.showDelay
    private let grace = MenuTooltipMetrics.graceWindow
    private let tooltipMetrics = MenuMetrics.standard.tooltip
    // Clock steps are powers of two so the manual clock's sums are exact.
    private let justBeforeDelay = MenuTooltipMetrics.showDelay - 0.25

    // MARK: - Controller

    @MainActor
    func testHoverShowsOnlyAfterTheDelayElapses() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: justBeforeDelay)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: 0.25)
        XCTAssertEqual(controller.visibleID, a)
    }

    @MainActor
    func testHoverEndedBeforeTheDelayCancelsThePendingShow() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: 0.5)
        controller.hoverEnded(id: a)
        clock.advance(by: 2)
        XCTAssertNil(controller.visibleID)
    }

    @MainActor
    func testEnteringAnotherTargetWhileOneIsVisibleShowsItImmediatelyAndIgnoresTheLateExit() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: delay)
        controller.hovering(id: b)
        XCTAssertEqual(controller.visibleID, b)
        controller.hoverEnded(id: a)
        XCTAssertEqual(controller.visibleID, b)
    }

    @MainActor
    func testEnteringAnotherTargetWithinTheGraceWindowShowsItImmediately() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: delay)
        controller.hoverEnded(id: a)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: 0.125)
        controller.hovering(id: b)
        XCTAssertEqual(controller.visibleID, b)
    }

    @MainActor
    func testEnteringAnotherTargetAfterTheGraceWindowWaitsTheFullDelay() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: delay)
        controller.hoverEnded(id: a)
        clock.advance(by: grace)
        controller.hovering(id: b)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: justBeforeDelay)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: 0.25)
        XCTAssertEqual(controller.visibleID, b)
    }

    @MainActor
    func testHoverOnAnotherTargetReplacesThePendingShow() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: 0.5)
        controller.hovering(id: b)
        clock.advance(by: 0.75)
        XCTAssertNil(controller.visibleID, "A's original deadline passed without showing A")
        clock.advance(by: 0.25)
        XCTAssertEqual(controller.visibleID, b)
        controller.hoverEnded(id: a)
        XCTAssertEqual(controller.visibleID, b, "a late exit for A leaves B visible")
    }

    @MainActor
    func testDismissHidesTheVisibleTooltipAndEndsTheGraceWindow() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: delay)
        controller.dismiss()
        XCTAssertNil(controller.visibleID)

        clock.moveMouse()
        controller.hovering(id: b)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: delay)
        XCTAssertEqual(controller.visibleID, b)
    }

    @MainActor
    func testRepeatedHoverEventsForThePendingTargetDoNotRestartTheDelay() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: 0.5)
        controller.hovering(id: a)
        clock.advance(by: 0.25)
        controller.hovering(id: a)
        clock.advance(by: 0.25)
        XCTAssertEqual(controller.visibleID, a)
    }

    @MainActor
    func testHoverAfterDismissWithAStillPointerShowsNothing() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: delay)
        controller.dismiss()

        // Content scrolled under the still pointer: a different target reports hover.
        controller.hovering(id: b)
        clock.advance(by: 2)
        controller.hovering(id: b)
        clock.advance(by: 2)
        XCTAssertNil(controller.visibleID)
    }

    @MainActor
    func testAnySmallPointerMoveAfterDismissLetsANewTargetShowAfterTheFullDelay() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        controller.dismiss()

        clock.moveMouse(by: 0.5)
        controller.hovering(id: b)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: justBeforeDelay)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: 0.25)
        XCTAssertEqual(controller.visibleID, b)
    }

    @MainActor
    func testTargetHoveredWhileSuppressedShowsOnceThePointerMovesWithinIt() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: delay)
        controller.dismiss()

        controller.hovering(id: b)
        clock.advance(by: 2)
        XCTAssertNil(controller.visibleID)

        clock.moveMouse(by: 0.5)
        controller.hovering(id: b)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: delay)
        XCTAssertEqual(controller.visibleID, b)
    }

    @MainActor
    func testTargetUnderThePointerAtDismissStaysHiddenUntilLeftAndReentered() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: delay)
        controller.dismiss()

        clock.moveMouse(by: 3)
        controller.hovering(id: a)
        clock.advance(by: 2)
        clock.moveMouse(by: 3)
        controller.hovering(id: a)
        clock.advance(by: 2)
        XCTAssertNil(controller.visibleID)

        controller.hoverEnded(id: a)
        controller.hovering(id: a)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: delay)
        XCTAssertEqual(controller.visibleID, a)
    }

    @MainActor
    func testRepeatedDismissalsWithAStillPointerDoNotBlockTheElementThatScrolledUnderIt() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: delay)
        controller.dismiss()

        // The list keeps scrolling under the still pointer: b arrives, a leaves, more scroll events.
        controller.hovering(id: b)
        controller.hoverEnded(id: a)
        controller.dismiss()

        clock.moveMouse(by: 0.5)
        controller.hovering(id: b)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: justBeforeDelay)
        XCTAssertNil(controller.visibleID)
        clock.advance(by: 0.25)
        XCTAssertEqual(controller.visibleID, b)
    }

    @MainActor
    func testASingleDismissalStillBlocksTheHoveredElementAfterThePointerMoves() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: delay)
        controller.dismiss()

        clock.moveMouse(by: 0.5)
        controller.hovering(id: a)
        clock.advance(by: 2)
        XCTAssertNil(controller.visibleID)
    }

    @MainActor
    func testDismissCancelsAPendingShow() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        clock.advance(by: 0.5)
        controller.dismiss()
        clock.advance(by: 2)
        XCTAssertNil(controller.visibleID)
    }

    @MainActor
    func testHoverEndedForAnUnknownTargetChangesNothing() {
        let (controller, clock) = makeController()
        controller.hovering(id: a)
        controller.hoverEnded(id: UUID())
        clock.advance(by: delay)
        XCTAssertEqual(controller.visibleID, a)
        controller.hoverEnded(id: UUID())
        XCTAssertEqual(controller.visibleID, a)
    }

    // MARK: - Placement

    func testPlacesTheBubbleBelowTheAnchorCenteredWhenItFits() {
        let origin = MenuTooltipPlacement.origin(
            anchor: CGRect(x: 300, y: 100, width: 40, height: 20),
            size: CGSize(width: 100, height: 24),
            container: CGSize(width: 820, height: 600),
            metrics: tooltipMetrics
        )
        XCTAssertEqual(origin, CGPoint(x: 270, y: 124))
    }

    func testFlipsTheBubbleAboveTheAnchorWhenThereIsNoRoomBelow() {
        let origin = MenuTooltipPlacement.origin(
            anchor: CGRect(x: 300, y: 570, width: 40, height: 20),
            size: CGSize(width: 100, height: 24),
            container: CGSize(width: 820, height: 600),
            metrics: tooltipMetrics
        )
        XCTAssertEqual(origin, CGPoint(x: 270, y: 542))
    }

    func testClampsTheBubbleInsideTheContainerWhenThereIsNoRoomAboveOrBelow() {
        let origin = MenuTooltipPlacement.origin(
            anchor: CGRect(x: 300, y: 40, width: 40, height: 20),
            size: CGSize(width: 100, height: 80),
            container: CGSize(width: 820, height: 100),
            metrics: tooltipMetrics
        )
        XCTAssertEqual(origin.y, 16)
        XCTAssertGreaterThanOrEqual(origin.y, tooltipMetrics.edgeMargin)
        XCTAssertLessThanOrEqual(origin.y + 80, 100 - tooltipMetrics.edgeMargin)
    }

    func testClampsTheBubbleToTheSideMarginsNearTheEdges() {
        let size = CGSize(width: 200, height: 24)
        let container = CGSize(width: 820, height: 600)
        let left = MenuTooltipPlacement.origin(anchor: CGRect(x: 2, y: 100, width: 20, height: 20), size: size, container: container, metrics: tooltipMetrics)
        XCTAssertEqual(left.x, 4)
        let right = MenuTooltipPlacement.origin(anchor: CGRect(x: 800, y: 100, width: 20, height: 20), size: size, container: container, metrics: tooltipMetrics)
        XCTAssertEqual(right.x, 820 - 4 - 200)
    }

    func testPinsABubbleWiderThanTheContainerToTheLeftMargin() {
        let origin = MenuTooltipPlacement.origin(
            anchor: CGRect(x: 100, y: 20, width: 20, height: 20),
            size: CGSize(width: 400, height: 24),
            container: CGSize(width: 300, height: 600),
            metrics: tooltipMetrics
        )
        XCTAssertEqual(origin.x, 4)
    }

    // MARK: - Measuring

    @MainActor
    func testLongSingleLineTextWrapsAtTheMaxWidth() {
        let text = String(repeating: "Refactor the billing reconciliation pipeline ", count: 4)
        let single = measuredBubble("Changes", container: CGSize(width: 820, height: 600))
        let long = measuredBubble(text, container: CGSize(width: 820, height: 600))
        XCTAssertLessThanOrEqual(long.width, tooltipMetrics.maxWidth)
        XCTAssertGreaterThan(long.height, single.height * 1.5)
    }

    @MainActor
    func testTextTallerThanTheContainerStaysWithinTheProposedHeight() {
        let container = CGSize(width: 820, height: 90)
        let text = String(repeating: "The refresh failed because the provider returned an unexpected response. ", count: 20)
        let size = measuredBubble(text, container: container)
        let proposedHeight = container.height - 2 * tooltipMetrics.edgeMargin
        XCTAssertLessThanOrEqual(size.height, proposedHeight)
        XCTAssertLessThanOrEqual(size.width, tooltipMetrics.maxWidth)
    }

    // MARK: - Event observer

    @MainActor
    func testEventObserverDismissesOnClicksAndScrollsOnly() {
        let view = MenuTooltipEventObserverNSView()
        for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel] {
            XCTAssertTrue(view.dismisses(eventType: type), "\(type)")
        }
        for type: NSEvent.EventType in [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged, .leftMouseUp] {
            XCTAssertFalse(view.dismisses(eventType: type), "\(type)")
        }
        XCTAssertFalse(view.dismisses(eventType: nil))
    }

    @MainActor
    func testEventObserverNeverTakesTheHitTest() throws {
        _ = NSApplication.shared
        let view = MenuTooltipEventObserverNSView(frame: CGRect(x: 0, y: 0, width: 820, height: 600))
        var dismissCount = 0
        view.dismiss = { dismissCount += 1 }
        let point = CGPoint(x: 400, y: 300)

        let dismissing = try [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown].map(mouseEvent) + [scrollEvent()]
        let passive = try [NSEvent.EventType.mouseMoved, .leftMouseDragged, .leftMouseUp].map(mouseEvent)
        for event in dismissing + passive {
            makeCurrent(event)
            XCTAssertEqual(NSApp.currentEvent?.type, event.type)
            XCTAssertNil(view.hitTest(point), "\(event.type)")
        }
        XCTAssertEqual(dismissCount, dismissing.count)
    }

    // MARK: - Target and host

    @MainActor
    func testTargetOutsideAHostFindsNoControllerAndUsesNativeHelp() throws {
        var found: MenuTooltipController?? = .none
        let probe = ControllerProbe { found = .some($0) }
        let hostingView = NSHostingView(rootView: probe.menuTooltip("Refresh sources"))
        hostingView.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        hostingView.layoutSubtreeIfNeeded()
        let reported = try XCTUnwrap(found, "the probe body was evaluated")
        XCTAssertNil(reported)

        let controller = MenuTooltipController()
        found = .none
        let hosted = NSHostingView(rootView: ControllerProbe { found = .some($0) }.menuTooltipHost(controller))
        hosted.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        hosted.layoutSubtreeIfNeeded()
        XCTAssertTrue(try XCTUnwrap(found) === controller)
    }

    @MainActor
    func testHostDrawsAtMostOneForcedBubbleAndNoneWithoutHoverOrForce() throws {
        let unhosted = try renderTargets(forced: (false, false), hosted: false)
        let none = try renderTargets(forced: (false, false), hosted: true)
        let first = try renderTargets(forced: (true, false), hosted: true)
        let second = try renderTargets(forced: (false, true), hosted: true)
        let both = try renderTargets(forced: (true, true), hosted: true)

        XCTAssertEqual(none, unhosted, "an unhovered, unforced target draws no bubble")
        XCTAssertNotEqual(first, none, "a forced target draws its bubble")
        XCTAssertNotEqual(second, first, "each target's bubble is distinguishable")
        XCTAssertEqual(both, first, "two forced targets still draw exactly one bubble")
    }

    @MainActor
    func testEmptyTooltipTextDrawsNoBubbleInsideAHost() throws {
        let plain = try renderTargets(texts: ("", ""), forced: (false, false), hosted: false, tooltips: false)
        let empty = try renderTargets(texts: ("", ""), forced: (true, true), hosted: true)
        let filled = try renderTargets(texts: ("", "Second target"), forced: (true, true), hosted: true)

        XCTAssertEqual(empty, plain, "forced empty-text targets inside a host draw nothing")
        XCTAssertNotEqual(filled, plain, "a non-empty forced target next to an empty one still draws")
    }

    // MARK: - Helpers

    @MainActor
    private func renderTargets(
        texts: (String, String) = ("First target", "Second target"),
        forced: (Bool, Bool),
        hosted: Bool,
        tooltips: Bool = true
    ) throws -> Data {
        let targets = VStack(spacing: 80) {
            if tooltips {
                Color.gray.frame(width: 40, height: 20).menuTooltip(texts.0, forcesVisible: forced.0)
                Color.gray.frame(width: 40, height: 20).menuTooltip(texts.1, forcesVisible: forced.1)
            } else {
                Color.gray.frame(width: 40, height: 20)
                Color.gray.frame(width: 40, height: 20)
            }
        }
        .frame(width: 300, height: 300)
        .background(Color.white)
        let root = hosted ? AnyView(targets.menuTooltipHost(MenuTooltipController())) : AnyView(targets)

        let frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: frame))
        hostingView.cacheDisplay(in: frame, to: representation)
        window.contentView = nil
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: CGPoint(x: 400, y: 300), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func scrollEvent() throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -4, wheel2: 0, wheel3: 0
        ))
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    // NSApp.currentEvent is the last event the app dequeued.
    @MainActor
    private func makeCurrent(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: true)
        _ = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
    }

    @MainActor
    private func measuredBubble(_ text: String, container: CGSize) -> CGSize {
        let proposal = MenuTooltipLayout.bubbleProposal(container: container, metrics: tooltipMetrics)
        let host = NSHostingController(rootView: MenuTooltipBubble(text: text))
        return host.sizeThatFits(in: CGSize(width: proposal.width ?? .infinity, height: proposal.height ?? .infinity))
    }

    @MainActor
    private func makeController() -> (MenuTooltipController, ManualTooltipClock) {
        let clock = ManualTooltipClock()
        return (clock.makeController(), clock)
    }
}

private struct ControllerProbe: View {
    let report: (MenuTooltipController?) -> Void
    @Environment(\.menuTooltipController) private var controller

    var body: some View {
        report(controller)
        return Color.clear
    }
}

// A manual clock, scheduler, and mouse location for MenuTooltipController: scheduled actions run
// only when `advance(by:)` moves time past their deadline, and the pointer moves only on `moveMouse`.
@MainActor
final class ManualTooltipClock {
    private(set) var mouse = CGPoint(x: 400, y: 400)

    func makeController() -> MenuTooltipController {
        MenuTooltipController(now: now, schedule: schedule, mouseLocation: { [unowned self] in mouse })
    }

    func moveMouse(by distance: CGFloat = 10) {
        mouse.x += distance
    }

    private struct Entry {
        let id: Int
        let deadline: Date
        let action: () -> Void
    }

    private(set) var current = Date(timeIntervalSinceReferenceDate: 0)
    private var entries: [Entry] = []
    private var nextID = 0

    var now: () -> Date {
        { [unowned self] in current }
    }

    var schedule: MenuTooltipController.Schedule {
        { [unowned self] delay, action in
            let id = nextID
            nextID += 1
            entries.append(Entry(id: id, deadline: current.addingTimeInterval(delay), action: action))
            return AnyCancellable { [weak self] in
                self?.entries.removeAll { $0.id == id }
            }
        }
    }

    func advance(by interval: TimeInterval) {
        let target = current.addingTimeInterval(interval)
        while let next = entries.filter({ $0.deadline <= target }).min(by: { $0.deadline < $1.deadline }) {
            entries.removeAll { $0.id == next.id }
            current = next.deadline
            next.action()
        }
        current = target
    }
}
