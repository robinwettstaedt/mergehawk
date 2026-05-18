import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = StatusBarMenu()
    private let controller: DashboardController
    private weak var refreshMenuItemView: RefreshMenuItemView?
    private var observation: NSKeyValueObservation?

    init(controller: DashboardController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.refreshKeyHandler = { [weak self] in
            self?.performKeyboardRefresh()
        }
        menu.tabShortcutHandler = { [weak self] tab in
            self?.selectKeyboardTab(tab) == true
        }
        statusItem.menu = menu
        updateStatusButton()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    func rebuildMenuForTesting() -> [NSMenuItem] {
        rebuildMenu()
        return menu.items
    }

    func performMenuKeyEquivalentForTesting(_ event: NSEvent) -> Bool {
        menu.performKeyEquivalent(with: event)
    }

    func refreshMenuItemIsSelectedForTesting() -> Bool {
        refreshMenuItemView?.isSelectedForTesting == true
    }

    func performRefreshMenuItemKeyEquivalentForTesting(_ event: NSEvent) -> Bool {
        refreshMenuItemView?.performKeyEquivalent(with: event) == true
    }

    func updateStatusButton() {
        guard let button = statusItem.button else {
            return
        }
        button.image = StatusIcon.make(attention: controller.hasAttention)
        button.image?.isTemplate = !controller.hasAttention
        button.title = ""
    }

    private func rebuildMenu() {
        updateStatusButton()
        menu.removeAllItems()

        let hostingView = MenuRootHostingView(
            controller: controller,
            refreshKeyHandler: { [weak self] in
                self?.performKeyboardRefresh()
            },
            tabShortcutHandler: { [weak self] tab in
                self?.selectKeyboardTab(tab) == true
            }
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: MenuRootView.Layout.width, height: MenuRootView.Layout.height)

        let item = NSMenuItem()
        item.view = hostingView
        menu.addItem(item)

        menu.addItem(footerSeparatorItem())
        menu.addItem(refreshItem())
        menu.addItem(actionItem("Settings", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(actionItem("About MergeHawk", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(actionItem("Quit", action: #selector(quit), keyEquivalent: "q"))
    }

    private func refreshItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "")
        item.target = self
        let view = RefreshMenuItemView(target: self, action: #selector(refresh))
        view.frame = NSRect(x: 0, y: 0, width: MenuRootView.Layout.width, height: FooterActionLayout.rowHeight)
        item.view = view
        refreshMenuItemView = view
        return item
    }

    private func footerSeparatorItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSHostingView(rootView: FooterSeparatorView())
        view.frame = NSRect(
            x: 0,
            y: 0,
            width: MenuRootView.Layout.width,
            height: FooterSeparatorLayout.height
        )
        item.view = view
        return item
    }

    private func actionItem(_ title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func refresh() {
        controller.refresh()
    }

    private func performKeyboardRefresh() {
        refreshMenuItemView?.showKeyboardSelection()
        controller.refresh()
    }

    private func selectKeyboardTab(_ tab: DashboardController.MenuTab) -> Bool {
        guard controller.state.authStatus == .signedIn else {
            return false
        }
        controller.selectedTab = tab
        return true
    }

    @objc private func showSettings() {
        controller.showSettings()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Native macOS menu bar dashboard for GitHub pull requests."
            )
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private final class MenuRootHostingView: NSHostingView<MenuRootView> {
    private let refreshKeyHandler: () -> Void
    private let tabShortcutHandler: (DashboardController.MenuTab) -> Bool

    init(
        controller: DashboardController,
        refreshKeyHandler: @escaping () -> Void,
        tabShortcutHandler: @escaping (DashboardController.MenuTab) -> Bool
    ) {
        self.refreshKeyHandler = refreshKeyHandler
        self.tabShortcutHandler = tabShortcutHandler
        super.init(rootView: MenuRootView(controller: controller))
    }

    @available(*, unavailable)
    required init(rootView: MenuRootView) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if let tab = menuTabShortcut(for: event), tabShortcutHandler(tab) {
            return
        }
        if isRefreshKeyEvent(event) {
            refreshKeyHandler()
            return
        }
        super.keyDown(with: event)
    }
}

private final class StatusBarMenu: NSMenu {
    var refreshKeyHandler: (() -> Void)?
    var tabShortcutHandler: ((DashboardController.MenuTab) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let tab = menuTabShortcut(for: event), tabShortcutHandler?(tab) == true {
            return true
        }
        if isRefreshKeyEvent(event) {
            refreshKeyHandler?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private enum FooterSeparatorLayout {
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let height: CGFloat = 13
}

private enum FooterActionLayout {
    static let rowHeight: CGFloat = 24
    static let selectionInsetX: CGFloat = 5
    static let selectionInsetY: CGFloat = 1
    static let selectionCornerRadius: CGFloat = 5
    static let titleLeading: CGFloat = 14
    static let titleWidthPadding: CGFloat = 4
    static let shortcutTrailing: CGFloat = 9
    static let shortcutWidthPadding: CGFloat = 8
    static let shortcutKern: CGFloat = 2
    static let keyboardSelectionDuration: TimeInterval = 0.1
}

func isRefreshKeyEvent(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "r"
}

func menuTabShortcut(for event: NSEvent) -> DashboardController.MenuTab? {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifiers == .command,
          let characters = event.charactersIgnoringModifiers,
          let index = Int(characters),
          DashboardController.MenuTab.allCases.indices.contains(index - 1)
    else {
        return nil
    }
    return DashboardController.MenuTab.allCases[index - 1]
}

private final class RefreshMenuItemView: NSControl {
    private let titleField = NSTextField(labelWithString: "Refresh")
    private let shortcutField = NSTextField(labelWithString: "⌘R")
    private var isHovering = false {
        didSet {
            updateSelectionAppearance(from: oldValue, to: isHovering)
        }
    }
    private var isKeyboardSelecting = false {
        didSet {
            updateSelectionAppearance(from: oldValue, to: isKeyboardSelecting)
        }
    }
    private var keyboardSelectionResetWorkItem: DispatchWorkItem?

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendAction(action, to: target)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRefreshKeyEvent(event) else {
            return super.performKeyEquivalent(with: event)
        }
        performKeyboardRefresh()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRefreshKeyEvent(event) else {
            super.keyDown(with: event)
            return
        }
        performKeyboardRefresh()
    }

    func showKeyboardSelection() {
        keyboardSelectionResetWorkItem?.cancel()
        isKeyboardSelecting = true
        let resetWorkItem = DispatchWorkItem { [weak self] in
            self?.isKeyboardSelecting = false
        }
        keyboardSelectionResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + FooterActionLayout.keyboardSelectionDuration,
            execute: resetWorkItem
        )
    }

    private func performKeyboardRefresh() {
        showKeyboardSelection()
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isSelected else {
            return
        }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: FooterActionLayout.selectionInsetX, dy: FooterActionLayout.selectionInsetY),
            xRadius: FooterActionLayout.selectionCornerRadius,
            yRadius: FooterActionLayout.selectionCornerRadius
        ).fill()
    }

    override func layout() {
        super.layout()
        let titleSize = titleField.intrinsicContentSize
        let shortcutSize = shortcutField.intrinsicContentSize
        let titleWidth = titleSize.width + FooterActionLayout.titleWidthPadding
        let shortcutWidth = shortcutSize.width + FooterActionLayout.shortcutWidthPadding
        titleField.frame = NSRect(
            x: FooterActionLayout.titleLeading,
            y: (bounds.height - titleSize.height) / 2,
            width: min(titleWidth, bounds.width - FooterActionLayout.titleLeading - FooterActionLayout.shortcutTrailing - shortcutWidth),
            height: titleSize.height
        )
        shortcutField.frame = NSRect(
            x: bounds.width - FooterActionLayout.shortcutTrailing - shortcutWidth,
            y: (bounds.height - shortcutSize.height) / 2,
            width: shortcutWidth,
            height: shortcutSize.height
        )
    }

    private func setup() {
        titleField.font = .menuFont(ofSize: 0)
        shortcutField.font = .menuFont(ofSize: 0)
        titleField.drawsBackground = false
        shortcutField.drawsBackground = false
        titleField.isSelectable = false
        shortcutField.isSelectable = false
        shortcutField.alignment = .right
        updateColors()
        addSubview(titleField)
        addSubview(shortcutField)
    }

    private func updateColors() {
        titleField.textColor = isSelected ? .selectedMenuItemTextColor : .labelColor
        let shortcutColor: NSColor = isSelected ? .selectedMenuItemTextColor : .tertiaryLabelColor
        shortcutField.attributedStringValue = NSAttributedString(
            string: shortcutField.stringValue,
            attributes: [
                .font: shortcutField.font ?? NSFont.menuFont(ofSize: 0),
                .foregroundColor: shortcutColor,
                .kern: FooterActionLayout.shortcutKern
            ]
        )
    }

    private var isSelected: Bool {
        isHovering || isKeyboardSelecting
    }

    var isSelectedForTesting: Bool {
        isSelected
    }

    private func updateSelectionAppearance(from oldValue: Bool, to newValue: Bool) {
        guard oldValue != newValue else {
            return
        }
        updateColors()
        needsDisplay = true
    }
}

private struct FooterSeparatorView: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.horizontal, FooterSeparatorLayout.horizontalPadding)
            .padding(.vertical, FooterSeparatorLayout.verticalPadding)
    }
}

enum StatusIcon {
    static func make(attention: Bool) -> NSImage {
        if !attention {
            return markImage(isTemplate: true)
        }

        let size = NSSize(
            width: Layout.markSize.width + Layout.badgeDiameter - Layout.badgeOverlap,
            height: Layout.statusItemHeight
        )
        let image = NSImage(size: size, flipped: false) { rect in
            let markRect = NSRect(
                x: rect.minX,
                y: rect.minY + (rect.height - Layout.markSize.height) / 2,
                width: Layout.markSize.width,
                height: Layout.markSize.height
            )
            markImage(isTemplate: false).draw(in: markRect)
            NSColor.labelColor.setFill()
            markRect.fill(using: .sourceIn)

            NSColor.systemRed.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: rect.minX + Layout.markSize.width - Layout.badgeOverlap,
                    y: rect.minY + rect.height - Layout.badgeDiameter,
                    width: Layout.badgeDiameter,
                    height: Layout.badgeDiameter
                )
            ).fill()
            return true
        }

        image.isTemplate = false
        return image
    }

    private static func markImage(isTemplate: Bool) -> NSImage {
        guard let url = Bundle.module.url(
            forResource: "MenuBarIconTemplate",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) else {
            preconditionFailure("MenuBarIconTemplate.svg must be bundled with mergehawk")
        }

        image.size = Layout.markSize
        image.isTemplate = isTemplate
        return image
    }

    private enum Layout {
        static let markSize = NSSize(width: 26.5, height: 16)
        static let statusItemHeight: CGFloat = 18
        static let badgeDiameter: CGFloat = 5
        static let badgeOverlap: CGFloat = 2.5
    }
}
