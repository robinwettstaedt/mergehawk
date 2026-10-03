import AppKit
import Combine
import SwiftUI

// Sizes live in `MenuMetrics.Tooltip` so they follow the Menu Size setting.
enum MenuTooltipMetrics {
    static let showDelay: TimeInterval = 1.0
    static let graceWindow: TimeInterval = 0.25
}

// Menu-scoped show/hide state for the single MergeHawk-drawn tooltip. Native `.help`
// tooltips never appear inside the status-bar NSMenu, so tooltip targets report hover here.
//
// Every decision uses the target's own hover event plus the real pointer position, so the order
// in which SwiftUI delivers hover callbacks does not matter.
@MainActor
final class MenuTooltipController: ObservableObject {
    typealias Schedule = (_ delay: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable

    @Published private(set) var visibleID: UUID?

    private let now: () -> Date
    private let schedule: Schedule
    private let mouseLocation: () -> CGPoint
    private var pendingID: UUID?
    private var pendingShow: AnyCancellable?
    private var lastPointerExitHide: Date?
    private var hoveredID: UUID?
    // The element under the pointer at a dismissal stays hidden until it is left and re-entered.
    private var blockedID: UUID?
    // After a dismissal nothing shows until the pointer moves, so content that scrolls or switches
    // under a still pointer stays quiet. Screen coordinates do not change when content scrolls.
    private var suppressionPoint: CGPoint?

    init(
        now: @escaping () -> Date = Date.init,
        schedule: @escaping Schedule = MenuTooltipController.scheduleOnMainQueue,
        mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }
    ) {
        self.now = now
        self.schedule = schedule
        self.mouseLocation = mouseLocation
    }

    // Called for every hover event while the pointer is over the target.
    func hovering(id: UUID) {
        hoveredID = id
        if pendingID == id || visibleID == id {
            return
        }
        if id == blockedID {
            return
        }
        if let suppressionPoint {
            if mouseLocation() == suppressionPoint {
                return
            }
            self.suppressionPoint = nil
        }
        cancelPendingShow()
        if visibleID != nil || isInGraceWindow {
            visibleID = id
            return
        }
        pendingID = id
        pendingShow = schedule(MenuTooltipMetrics.showDelay) { [weak self] in
            self?.showPending(id)
        }
    }

    func hoverEnded(id: UUID) {
        if blockedID == id {
            blockedID = nil
        }
        if hoveredID == id {
            hoveredID = nil
        }
        if pendingID == id {
            cancelPendingShow()
        }
        if visibleID == id {
            visibleID = nil
            lastPointerExitHide = now()
        }
    }

    func dismiss() {
        cancelPendingShow()
        visibleID = nil
        lastPointerExitHide = nil
        // Repeated dismissals with a still pointer (a trackpad or momentum scroll) keep the target
        // blocked by the first one; elements that scrolled under the pointer are not blocked.
        let location = mouseLocation()
        if let suppressionPoint, suppressionPoint == location {
            return
        }
        blockedID = hoveredID
        suppressionPoint = location
    }

    private var isInGraceWindow: Bool {
        guard let lastPointerExitHide else {
            return false
        }
        return now().timeIntervalSince(lastPointerExitHide) < MenuTooltipMetrics.graceWindow
    }

    private func showPending(_ id: UUID) {
        guard pendingID == id else {
            return
        }
        pendingID = nil
        pendingShow = nil
        visibleID = id
    }

    private func cancelPendingShow() {
        pendingShow?.cancel()
        pendingShow = nil
        pendingID = nil
    }

    private nonisolated static func scheduleOnMainQueue(delay: TimeInterval, action: @escaping () -> Void) -> AnyCancellable {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return AnyCancellable { workItem.cancel() }
    }
}

enum MenuTooltipPlacement {
    // Below the anchor when it fits, else above, else clamped; always inside the container margins.
    static func origin(anchor: CGRect, size: CGSize, container: CGSize, metrics: MenuMetrics.Tooltip) -> CGPoint {
        let margin = metrics.edgeMargin
        let gap = metrics.gap
        let x = max(margin, min(anchor.midX - size.width / 2, container.width - margin - size.width))

        let below = anchor.maxY + gap
        let above = anchor.minY - gap - size.height
        let y: CGFloat
        if below + size.height <= container.height - margin {
            y = below
        } else if above >= margin {
            y = above
        } else {
            y = max(margin, min(below, container.height - margin - size.height))
        }
        return CGPoint(x: x, y: y)
    }
}

// Fills its container and places its single bubble next to `anchor`, measured with a proposal
// bounded by the max width and the container's height so oversized text truncates in place.
struct MenuTooltipLayout: Layout {
    let anchor: CGRect
    let metrics: MenuMetrics.Tooltip

    static func bubbleProposal(container: CGSize, metrics: MenuMetrics.Tooltip) -> ProposedViewSize {
        let margin = metrics.edgeMargin
        return ProposedViewSize(
            width: min(metrics.maxWidth, container.width - 2 * margin),
            height: container.height - 2 * margin
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let bubbleProposal = Self.bubbleProposal(container: bounds.size, metrics: metrics)
        for subview in subviews {
            let size = subview.sizeThatFits(bubbleProposal)
            let origin = MenuTooltipPlacement.origin(anchor: anchor, size: size, container: bounds.size, metrics: metrics)
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: bubbleProposal
            )
        }
    }
}

struct MenuTooltipBubble: View {
    let text: String
    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        let tooltip = metrics.tooltip
        Text(text)
            .font(metrics.type.tooltip.font)
            .foregroundStyle(Color(nsColor: .labelColor))
            .truncationMode(.tail)
            .padding(.horizontal, tooltip.horizontalPadding)
            .padding(.vertical, tooltip.verticalPadding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: tooltip.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: tooltip.cornerRadius)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: tooltip.shadowRadius, y: tooltip.shadowOffsetY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// A plain reference, so reading it does not subscribe targets to tooltip changes.
private struct MenuTooltipControllerKey: EnvironmentKey {
    static let defaultValue: MenuTooltipController? = nil
}

extension EnvironmentValues {
    var menuTooltipController: MenuTooltipController? {
        get { self[MenuTooltipControllerKey.self] }
        set { self[MenuTooltipControllerKey.self] = newValue }
    }
}

struct MenuTooltipAnchor {
    let id: UUID
    let text: String
    let bounds: Anchor<CGRect>
    let forced: Bool
}

struct MenuTooltipAnchorKey: PreferenceKey {
    static var defaultValue: [MenuTooltipAnchor] { [] }

    static func reduce(value: inout [MenuTooltipAnchor], nextValue: () -> [MenuTooltipAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    // Inside a `menuTooltipHost` this draws MergeHawk's tooltip; anywhere else it is native `.help`.
    // Empty text leaves the content unchanged.
    // `providesAccessibilityHint` keeps the accessibility help that `.help` provided; pass false
    // for targets that never had `.help` and already carry the text as their accessibility label.
    func menuTooltip(
        _ text: String,
        forcesVisible: Bool = false,
        providesAccessibilityHint: Bool = true
    ) -> some View {
        modifier(MenuTooltipModifier(
            text: text,
            forcesVisible: forcesVisible,
            providesAccessibilityHint: providesAccessibilityHint
        ))
    }

    func menuTooltipHost(_ controller: MenuTooltipController) -> some View {
        modifier(MenuTooltipHostModifier(controller: controller))
    }
}

private struct MenuTooltipModifier: ViewModifier {
    let text: String
    let forcesVisible: Bool
    let providesAccessibilityHint: Bool
    @Environment(\.menuTooltipController) private var controller
    @State private var id = UUID()
    @State private var isHovered = false

    func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else if let controller {
            content
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        if !isHovered {
                            isHovered = true
                        }
                        controller.hovering(id: id)
                    case .ended:
                        isHovered = false
                        controller.hoverEnded(id: id)
                    }
                }
                .anchorPreference(key: MenuTooltipAnchorKey.self, value: .bounds) { bounds in
                    isHovered || forcesVisible
                        ? [MenuTooltipAnchor(id: id, text: text, bounds: bounds, forced: forcesVisible)]
                        : []
                }
                .accessibilityHint(text, isEnabled: providesAccessibilityHint)
                .onDisappear {
                    isHovered = false
                    controller.hoverEnded(id: id)
                }
        } else {
            content.help(text)
        }
    }
}

private extension View {
    @ViewBuilder
    func accessibilityHint(_ hint: String, isEnabled: Bool) -> some View {
        if isEnabled {
            accessibilityHint(hint)
        } else {
            self
        }
    }
}

private struct MenuTooltipHostModifier: ViewModifier {
    let controller: MenuTooltipController

    func body(content: Content) -> some View {
        content
            .environment(\.menuTooltipController, controller)
            .overlayPreferenceValue(MenuTooltipAnchorKey.self) { anchors in
                MenuTooltipOverlay(controller: controller, anchors: anchors)
            }
            .overlay {
                MenuTooltipEventObserverView(dismiss: { controller.dismiss() })
            }
    }
}

// The only view that observes the controller, so tooltip changes re-render just this overlay.
private struct MenuTooltipOverlay: View {
    @ObservedObject var controller: MenuTooltipController
    let anchors: [MenuTooltipAnchor]
    @Environment(\.menuMetrics) private var metrics

    private var activeAnchor: MenuTooltipAnchor? {
        anchors.first { $0.id == controller.visibleID } ?? anchors.first(where: \.forced)
    }

    var body: some View {
        GeometryReader { geometry in
            if let anchor = activeAnchor {
                MenuTooltipLayout(anchor: geometry[anchor.bounds], metrics: metrics.tooltip) {
                    MenuTooltipBubble(text: anchor.text)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct MenuTooltipEventObserverView: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> MenuTooltipEventObserverNSView {
        MenuTooltipEventObserverNSView()
    }

    func updateNSView(_ view: MenuTooltipEventObserverNSView, context: Context) {
        view.dismiss = dismiss
    }
}

// Observes clicks and scrolls over the menu without consuming them: hit-testing always
// passes through, so the event still reaches the element under the pointer.
final class MenuTooltipEventObserverNSView: NSView {
    var dismiss: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        if dismisses(eventType: NSApp.currentEvent?.type) {
            dismiss()
        }
        return nil
    }

    func dismisses(eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            true
        default:
            false
        }
    }
}
