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
        window.sendEvent(event)
        settle()
    }

    /// A mouse event at `point` in window coordinates.
    func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    func click(at point: CGPoint) throws {
        send(try mouseEvent(.leftMouseDown, at: point))
        send(try mouseEvent(.leftMouseUp, at: point))
    }
}
