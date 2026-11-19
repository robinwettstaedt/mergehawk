import AppKit
import SwiftUI

/// The PR lists' native scroller: the slim overlay style at the small control size, whatever the system
/// scrollbar setting. An overlay scroller floats over the content, so showing it never narrows the cards; the
/// lists' right margin holds its full frame (`MenuMetrics.PRList.trailingPadding`).
enum PullRequestListScroller {
    static let controlSize: NSControl.ControlSize = .small

    /// The overlay scroller's full frame width, its hover-expanded state included.
    static var width: CGFloat {
        NSScroller.scrollerWidth(for: controlSize, scrollerStyle: .overlay)
    }

    static func configure(_ scrollView: NSScrollView) {
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        if let scroller = scrollView.verticalScroller, scroller.controlSize != controlSize {
            scroller.controlSize = controlSize
        }
    }
}

/// Placed inside a PR list's ScrollView content; it styles the enclosing NSScrollView and keeps it styled. AppKit and
/// SwiftUI reset the style to the system preference, for example after the preference changes or when the content
/// changes size (seen on macOS 15 with the legacy preference), so the view restores it whenever the scroll view's
/// style changes, the content resizes, or the preference changes. The system setting is never changed.
struct PullRequestListScrollerStyle: NSViewRepresentable {
    /// Also told which scroll view holds the list.
    var anchor: PullRequestListScrollAnchor? = nil

    func makeNSView(context: Context) -> PullRequestListScrollerStyleView {
        PullRequestListScrollerStyleView()
    }

    func updateNSView(_ view: PullRequestListScrollerStyleView, context: Context) {
        view.anchor = anchor
        view.apply()
    }
}

final class PullRequestListScrollerStyleView: NSView {
    private var preferenceObserver: NSObjectProtocol?
    private var styleObservation: NSKeyValueObservation?
    private weak var observedScrollView: NSScrollView?
    private var isApplying = false
    weak var anchor: PullRequestListScrollAnchor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // AppKit's own observers reset the scroll view's style during this notification; apply ours after them.
            DispatchQueue.main.async { self?.apply() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    /// The view is the list content's background, so it resizes whenever the list's content does.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        apply()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply() {
        guard let scrollView = enclosingScrollView else { return }
        anchor?.scrollView = scrollView
        if scrollView !== observedScrollView {
            observe(scrollView)
        }
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        PullRequestListScroller.configure(scrollView)
    }

    /// Restores the style as soon as anything else sets the scroll view's style, before the list lays out again.
    private func observe(_ scrollView: NSScrollView) {
        observedScrollView = scrollView
        styleObservation = scrollView.observe(\.scrollerStyle, options: [.new]) { [weak self] scrollView, _ in
            guard scrollView.scrollerStyle != .overlay else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isApplying {
                    DispatchQueue.main.async { self.apply() }
                } else {
                    self.apply()
                }
            }
        }
    }
}

/// Each laid-out PR list row's frame, by row ID.
struct PullRequestListRowFramesKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// Keeps the visible rows in place on screen while the list changes around them. SwiftUI animates the rows to their
/// new places, so rows appearing or leaving above the visible area would slide the visible rows down or up. The
/// anchor scrolls the list by the same amount on the move animation's curve, so on screen the two cancel out.
@MainActor
final class PullRequestListScrollAnchor {
    weak var scrollView: NSScrollView?
    /// Every row's frame in the list content's coordinates, which are the scroll view's document coordinates.
    /// During an animation these are the animated frames.
    private(set) var rowFrames: [String: CGRect] = [:]

    var visibleMinY: CGFloat? { scrollView?.contentView.bounds.minY }

    /// Called with every layout's row frames.
    func record(_ frames: [String: CGRect]) {
        rowFrames = frames
    }

    /// Scrolls by `delta` alongside the change being made now. `contentHeightChange` is how much the list grows,
    /// so the scroll stays within the content it ends with.
    func scroll(by delta: CGFloat, contentHeightChange: CGFloat, animated: Bool) {
        removePendingScroll()
        guard abs(delta) > 0.5, let scrollView, let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let maxY = max(0, documentView.frame.height + contentHeightChange - clipView.bounds.height)
        let target = min(max(0, clipView.bounds.minY + delta), maxY)
        guard target != clipView.bounds.minY else { return }
        guard target > max(0, documentView.frame.height - clipView.bounds.height) else {
            Self.scroll(scrollView, to: target, animated: animated)
            return
        }
        // The content grows with the change, and the clip view keeps its origin within the old content height, so
        // the scroll waits for SwiftUI to lay out the taller content.
        documentView.postsFrameChangedNotifications = true
        pendingScroll = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: documentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let scrollView = self.scrollView else { return }
                self.removePendingScroll()
                Self.scroll(scrollView, to: target, animated: animated)
            }
        }
    }

    private var pendingScroll: NSObjectProtocol?

    private func removePendingScroll() {
        if let pendingScroll {
            NotificationCenter.default.removeObserver(pendingScroll)
        }
        pendingScroll = nil
    }

    private static func scroll(_ scrollView: NSScrollView, to y: CGFloat, animated: Bool) {
        let clipView = scrollView.contentView
        let origin = clipView.constrainBoundsRect(CGRect(origin: CGPoint(x: clipView.bounds.minX, y: y), size: clipView.bounds.size)).origin
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PullRequestMoveAnimation.duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clipView.animator().setBoundsOrigin(origin)
            }
        } else {
            clipView.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clipView)
    }
}
