import AppKit
import SwiftUI
import UserNotifications

@main
struct mergehawkApp {
    @MainActor
    static func main() {
        runApplication(delegate: AppDelegate()) { NSApplication.shared.run() }
    }

    // NSApplication holds its delegate weakly. Keep it alive through the run loop.
    @MainActor
    static func runApplication(
        delegate: AppDelegate,
        run: @MainActor () -> Void
    ) {
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            run()
        }
    }
}

@MainActor
final class SettingsWindowState: ObservableObject {
    @Published var selection: SettingsTab

    init(selection: SettingsTab = .general) {
        self.selection = selection
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var browserOpener = PullRequestBrowserOpener.live(openNormally: { NSWorkspace.shared.open($0) })
    lazy var controller = DashboardController(
        launchConfiguration: .current(),
        pullRequestOpener: { [weak self] request in self?.browserOpener.open(request) }
    )
    let settingsWindowState = SettingsWindowState()
    let softwareUpdateController = SoftwareUpdateController.disabled()
    private var statusBarController: StatusBarController?
    private(set) var settingsWindow: NSWindow?
    var activateApplication: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    private var verificationMenuWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppKit's default tooltip delay is about 2 seconds; value is in milliseconds.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        softwareUpdateController.enableSparkleIfConfigured()
        UNUserNotificationCenter.current().delegate = self
        statusBarController = StatusBarController(controller: controller)
        configureSettingsRouting()
        installMainMenu()
        if let surface = LaunchConfiguration.current().verificationUI {
            DispatchQueue.main.async { [weak self] in
                self?.showVerificationUI(surface)
            }
        }
    }

    func showVerificationUI(_ surface: LaunchConfiguration.VerificationUI) {
        switch surface {
        case .settings:
            showSettingsWindow(selection: .general, presentation: .background)
        case .menu:
            showVerificationMenuWindow()
        }
    }

    private func showVerificationMenuWindow() {
        guard let contentView = statusBarController?.makeMenuContentView() else { return }
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MergeHawk Verification Menu"
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        verificationMenuWindow = window
        window.orderBack(nil)
        window.makeKey()
        window.makeFirstResponder(contentView)
    }

    enum SettingsPresentation {
        case foreground
        case background
    }

    func configureSettingsRouting() {
        controller.openSettingsWindow = { [weak self] selection in
            self?.showSettingsWindow(selection: selection)
        }
        controller.openSettingsWindowPreservingSelection = { [weak self] in
            self?.showSettingsWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    @objc private func openSettings(_ sender: Any?) {
        controller.showSettingsPreservingSelection()
    }

    @objc private func openAbout(_ sender: Any?) {
        controller.showSettings(selection: .about)
    }

    @objc private func closeAllWindows(_ sender: Any?) {
        NSApp.windows.filter { $0.isVisible || $0.isMiniaturized }.forEach { $0.performClose(sender) }
    }

    @objc private func minimizeAllWindows(_ sender: Any?) {
        NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.miniaturizable) }
            .forEach { $0.performMiniaturize(sender) }
    }

    @objc private func zoomAllWindows(_ sender: Any?) {
        NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.resizable) }
            .forEach { $0.performZoom(sender) }
    }

    func installMainMenu(bundle: Bundle = .main) {
        let application = NSApplication.shared
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        let mainMenu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            mainMenu.addItem(item)
            return menu
        }
        @discardableResult
        func command(
            _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
            modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
            return item
        }
        let appMenu = submenu(appName)
        command(appMenu, "About \(appName)", #selector(openAbout), target: self)
        appMenu.addItem(.separator())
        command(appMenu, "Settings…", #selector(openSettings), ",", target: self)
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        application.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        command(appMenu, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
        command(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        command(appMenu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        command(appMenu, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")

        let editMenu = submenu("Edit")
        command(editMenu, "Undo", NSSelectorFromString("undo:"), "z")
        command(editMenu, "Redo", NSSelectorFromString("redo:"), "z", modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        command(editMenu, "Cut", #selector(NSText.cut(_:)), "x")
        command(editMenu, "Copy", #selector(NSText.copy(_:)), "c")
        command(editMenu, "Paste", #selector(NSText.paste(_:)), "v")
        command(editMenu, "Delete", #selector(NSText.delete(_:)))
        command(editMenu, "Select All", #selector(NSText.selectAll(_:)), "a")

        let viewMenu = submenu("View")
        command(viewMenu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        let windowMenu = submenu("Window")
        command(windowMenu, "Close", #selector(NSWindow.performClose(_:)), "w")
        command(windowMenu, "Close All", #selector(closeAllWindows), "w", modifiers: [.command, .option], target: self)
        command(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        command(windowMenu, "Minimize All", #selector(minimizeAllWindows), "m", modifiers: [.command, .option], target: self)
        command(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
        command(windowMenu, "Zoom All", #selector(zoomAllWindows), target: self)
        windowMenu.addItem(.separator())
        command(windowMenu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        application.windowsMenu = windowMenu
        let helpMenu = submenu("Help")
        command(helpMenu, "\(appName) Help", #selector(NSApplication.showHelp(_:)), "?")
        application.helpMenu = helpMenu
        application.mainMenu = mainMenu
    }

    func showSettingsWindow(selection: SettingsTab? = nil, presentation: SettingsPresentation = .foreground) {
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
            if let selection { settingsWindowState.selection = selection }
        } else {
            if let selection { settingsWindowState.selection = selection }
            let size = SettingsTab.defaultWindowSize
            window = SettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "MergeHawk Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(
                rootView: SettingsRootView(
                    controller: controller,
                    settingsWindowState: settingsWindowState,
                    softwareUpdateController: softwareUpdateController
                )
            )
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            settingsWindow = window
        }

        window.setContentSize(SettingsTab.defaultWindowSize)
        if presentation == .background {
            window.orderBack(nil)
            window.makeKey()
            window.makeMain()
        } else {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            activateApplication()
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in
            self?.handleNotificationResponse(response)
            completionHandler()
        }
    }

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        switch NotificationClickRoute(userInfo: userInfo) {
        case .openPullRequest(let request):
            controller.openPullRequest(request)
        case .openNotifications:
            statusBarController?.showMenu(selecting: .notifications)
        }
    }
}

private final class SettingsWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}
