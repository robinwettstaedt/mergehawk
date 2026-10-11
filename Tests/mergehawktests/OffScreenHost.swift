import AppKit
import XCTest

/// Hosts a view in a borderless window ordered in off screen, so SwiftUI controls receive synthesized clicks.
@MainActor
final class OffScreenHost {
    let window: NSWindow

    init(_ view: NSView) {
        window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        // SwiftUI buttons only receive synthesized clicks in an ordered-in window; keep it off screen.
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        settle()
    }

    func close() {
        window.orderOut(nil)
    }

    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func send(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: true)
        deliverQueuedEvent(matching: NSEvent.EventTypeMask(type: event.type))
        settle()
    }

    /// Takes the first queued event of these types and sends it to the window. Every event is posted and taken off
    /// the queue before delivery, as AppKit does with a real event, so it is `NSApp.currentEvent` while the window
    /// handles it. Code that reads the current event, like the dropdown outside-click catcher, then sees the event
    /// being handled, and no stale event from an earlier click leaks into later tests.
    private func deliverQueuedEvent(matching mask: NSEvent.EventTypeMask) {
        if let event = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) {
            window.sendEvent(event)
        }
    }

    /// A mouse event at `point` in window coordinates.
    func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    /// Clicks at `point` in window coordinates. AppKit controls such as bordered buttons and switches track a mouse
    /// down until they dequeue the matching mouse up, so the mouse up is queued before the mouse down is sent.
    func click(at point: CGPoint) throws {
        NSApp.postEvent(try mouseEvent(.leftMouseUp, at: point), atStart: false)
        NSApp.postEvent(try mouseEvent(.leftMouseDown, at: point), atStart: true)
        deliverQueuedEvent(matching: .leftMouseDown)
        // A control that did not track leaves the mouse up queued; deliver it so the click completes and no stray
        // event reaches a later test.
        deliverQueuedEvent(matching: .leftMouseUp)
        settle()
    }
}
