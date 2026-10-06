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
    func makeNSView(context: Context) -> PullRequestListScrollerStyleView {
        PullRequestListScrollerStyleView()
    }

    func updateNSView(_ view: PullRequestListScrollerStyleView, context: Context) {
        view.apply()
    }
}

final class PullRequestListScrollerStyleView: NSView {
    private var preferenceObserver: NSObjectProtocol?
    private var styleObservation: NSKeyValueObservation?
    private weak var observedScrollView: NSScrollView?
    private var isApplying = false

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
