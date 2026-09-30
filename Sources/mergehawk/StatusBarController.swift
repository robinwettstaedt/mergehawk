import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = StatusBarMenu()
    private let controller: DashboardController
    private let footerModel = MenuFooterModel()
    private var quitAction: () -> Void = { NSApp.terminate(nil) }
    private var cancellables: Set<AnyCancellable> = []
    private var isMenuOpen = false

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
        menu.settingsKeyHandler = { [weak self] in
            self?.dismissAndShowSettings()
        }
        menu.quitKeyHandler = { [weak self] in
            self?.dismissAndQuit()
        }
        controller.showDeviceFlowSignInMenu = { [weak self] in
            self?.showDeviceFlowSignInMenu()
        }
        menu.removeVerticalEdgePadding()
        statusItem.menu = menu
        observeStatusButtonInputs()
        updateStatusButton()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    func rebuildMenuForTesting() -> [NSMenuItem] {
        rebuildMenu()
        return menu.items
    }

    func performMenuKeyEquivalentForTesting(_ event: NSEvent) -> Bool {
        menu.performKeyEquivalent(with: event)
    }

    func refreshFlashCountForTesting() -> Int {
        footerModel.refreshFlashCount
    }

    func setQuitActionForTesting(_ action: @escaping () -> Void) {
        quitAction = action
    }

    func statusButtonHasAttentionForTesting() -> Bool {
        statusItem.button?.image?.isTemplate == false
    }

    func updateStatusButton() {
        guard let button = statusItem.button else {
            return
        }
        button.image = StatusIcon.make(attention: controller.hasAttention)
        button.image?.isTemplate = !controller.hasAttention
        button.title = ""
    }

    private func observeStatusButtonInputs() {
        controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.updateStatusButton()
            }
            .store(in: &cancellables)

        controller.$sourcePreferences
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButton()
            }
            .store(in: &cancellables)
    }

    func showMenu(selecting tab: DashboardController.MenuTab? = nil) {
        prepareMenu(selecting: tab)
        statusItem.button?.performClick(nil)
    }

    func showMenuForTesting(selecting tab: DashboardController.MenuTab? = nil) -> [NSMenuItem] {
        prepareMenu(selecting: tab)
        return menu.items
    }

    private func rebuildMenu() {
        updateStatusButton()
        menu.removeAllItems()

        let item = NSMenuItem()
        item.view = makeMenuContentView()
        menu.addItem(item)
        menu.addItem(makeKeyEquivalentTrapItem(
            title: "Settings",
            action: #selector(handleSettingsKeyEquivalent),
            keyEquivalent: ","
        ))
        menu.addItem(makeKeyEquivalentTrapItem(
            title: "Quit",
            action: #selector(handleQuitKeyEquivalent),
            keyEquivalent: "q"
        ))
    }

    // Reuse the actual menu content in a persistent mock verification window.
    func makeMenuContentView(
        availableFrame: CGRect? = nil,
        initialDropdown: PullRequestMenuDropdown? = nil
    ) -> NSView {
        let screenFrame = availableFrame
            ?? statusItem.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(origin: .zero, size: MenuMetrics.standard.panelSize)
        let metrics = MenuMetrics.standard
        let resolvedSize = MenuPanelSize.resolve(availableFrame: screenFrame, metrics: metrics)
        let hostingView = MenuRootHostingView(
            controller: controller,
            footerModel: footerModel,
            metrics: metrics,
            resolvedSize: resolvedSize,
            initialDropdown: initialDropdown,
            refreshKeyHandler: { [weak self] in
                self?.performKeyboardRefresh()
            },
            tabShortcutHandler: { [weak self] tab in
                self?.selectKeyboardTab(tab) == true
            },
            dismissMenu: { [weak self] in
                self?.dismissMenu()
            },
            showSettings: { [weak self] in
                self?.controller.showSettings()
            },
            showAbout: { [weak self] in
                self?.controller.showSettings(selection: .about)
            },
            quit: { [weak self] in
                self?.quitAction()
            }
        )
        hostingView.frame = NSRect(origin: .zero, size: resolvedSize)
        return hostingView
    }

    // During NSMenu tracking, key equivalents are matched against the open menu's own native
    // items first and then forwarded straight to the app's main menu — the hosted view hierarchy
    // is never consulted. Hidden native items are the only way to outrank the main menu (e.g. the
    // SwiftUI Settings scene's auto-generated ⌘, item) while the menu is open.
    private func makeKeyEquivalentTrapItem(
        title: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    @objc private func handleSettingsKeyEquivalent() {
        dismissAndShowSettings()
    }

    @objc private func handleQuitKeyEquivalent() {
        dismissAndQuit()
    }

    private func prepareMenu(selecting tab: DashboardController.MenuTab?) {
        if let tab {
            controller.selectedTab = tab
        }
        rebuildMenu()
    }

    private func showDeviceFlowSignInMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self,
                  self.controller.deviceFlowChallenge != nil,
                  self.controller.state.authStatus == .signedOut else {
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            if !self.isMenuOpen {
                self.showMenu()
            }
        }
    }

    private func performKeyboardRefresh() {
        footerModel.flashRefresh()
        controller.refresh()
    }

    private func selectKeyboardTab(_ tab: DashboardController.MenuTab) -> Bool {
        guard controller.state.authStatus == .signedIn else {
            return false
        }
        controller.selectedTab = tab
        return true
    }

    private func dismissMenu() {
        menu.cancelTracking()
    }

    private func dismissAndShowSettings() {
        dismissMenu()
        controller.showSettings()
    }

    private func dismissAndQuit() {
        dismissMenu()
        quitAction()
    }
}

final class MenuRootHostingView: NSHostingView<MenuRootView> {
    private let refreshKeyHandler: () -> Void
    private let tabShortcutHandler: (DashboardController.MenuTab) -> Bool
    private let settingsKeyHandler: () -> Void
    private let quitKeyHandler: () -> Void

    init(
        controller: DashboardController,
        footerModel: MenuFooterModel,
        metrics: MenuMetrics,
        resolvedSize: CGSize,
        initialDropdown: PullRequestMenuDropdown?,
        refreshKeyHandler: @escaping () -> Void,
        tabShortcutHandler: @escaping (DashboardController.MenuTab) -> Bool,
        dismissMenu: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        showAbout: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.refreshKeyHandler = refreshKeyHandler
        self.tabShortcutHandler = tabShortcutHandler
        self.settingsKeyHandler = {
            dismissMenu()
            showSettings()
        }
        self.quitKeyHandler = {
            dismissMenu()
            quit()
        }
        super.init(rootView: MenuRootView(
            controller: controller,
            footerModel: footerModel,
            metrics: metrics,
            resolvedSize: resolvedSize,
            initialDropdown: initialDropdown,
            dismissMenu: dismissMenu,
            showSettings: showSettings,
            showAbout: showAbout,
            quit: quit
        ))
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let tab = menuTabShortcut(for: event), tabShortcutHandler(tab) {
            return true
        }
        if isRefreshKeyEvent(event) {
            refreshKeyHandler()
            return true
        }
        if isSettingsKeyEvent(event) {
            settingsKeyHandler()
            return true
        }
        if isQuitKeyEvent(event) {
            quitKeyHandler()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let tab = menuTabShortcut(for: event), tabShortcutHandler(tab) {
            return
        }
        if isRefreshKeyEvent(event) {
            refreshKeyHandler()
            return
        }
        if isSettingsKeyEvent(event) {
            settingsKeyHandler()
            return
        }
        if isQuitKeyEvent(event) {
            quitKeyHandler()
            return
        }
        super.keyDown(with: event)
    }
}

private final class StatusBarMenu: NSMenu {
    var refreshKeyHandler: (() -> Void)?
    var tabShortcutHandler: ((DashboardController.MenuTab) -> Bool)?
    var settingsKeyHandler: (() -> Void)?
    var quitKeyHandler: (() -> Void)?

    // NSMenu reserves 5pt of vertical padding above and below the item area that item views
    // cannot cover, which shows as a raw vibrancy strip beneath the footer. There is no public
    // API to remove it, so this uses the private -[NSMenu _setHasPadding:onEdge:]. The
    // responds(to:) guard makes this a graceful no-op (falling back to the default insets) if a
    // future macOS removes the selector.
    func removeVerticalEdgePadding() {
        let selector = NSSelectorFromString("_setHasPadding:onEdge:")
        guard responds(to: selector) else {
            return
        }
        let setHasPadding = unsafeBitCast(
            method(for: selector),
            to: (@convention(c) (NSMenu, Selector, ObjCBool, Int) -> Void).self
        )
        // NSRectEdge raw values: 1 = minY, 3 = maxY. Clear both so the top and bottom insets
        // are removed regardless of coordinate-system flippedness.
        setHasPadding(self, selector, false, 1)
        setHasPadding(self, selector, false, 3)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let tab = menuTabShortcut(for: event), tabShortcutHandler?(tab) == true {
            return true
        }
        if isRefreshKeyEvent(event) {
            refreshKeyHandler?()
            return true
        }
        if isSettingsKeyEvent(event) {
            settingsKeyHandler?()
            return true
        }
        if isQuitKeyEvent(event) {
            quitKeyHandler?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

func isRefreshKeyEvent(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "r"
}

func isSettingsKeyEvent(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command && event.charactersIgnoringModifiers == ","
}

func isQuitKeyEvent(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "q"
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
        let resourceName = "MenuBarIconTemplate"
        let resourceExtension = "svg"
        let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
            ?? Bundle.module.url(forResource: resourceName, withExtension: resourceExtension)

        guard let url, let image = NSImage(contentsOf: url) else {
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
