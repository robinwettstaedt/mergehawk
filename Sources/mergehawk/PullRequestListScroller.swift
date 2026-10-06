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

/// Placed inside a PR list's ScrollView content; it styles the enclosing NSScrollView and styles it again when
/// AppKit resets the style after the system scrollbar preference changes. The system setting is never changed.
struct PullRequestListScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> PullRequestListScrollerStyleView {
        PullRequestListScrollerStyleView()
    }

    func updateNSView(_ view: PullRequestListScrollerStyleView, context: Context) {
        view.apply()
    }
}

final class PullRequestListScrollerStyleView: NSView {
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        observer = NotificationCenter.default.addObserver(
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
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply() {
        guard let scrollView = enclosingScrollView else { return }
        PullRequestListScroller.configure(scrollView)
    }
}
