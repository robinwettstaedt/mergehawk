@testable import mergehawk
import AppKit
import XCTest

final class SettingsWindowTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { _ = NSApplication.shared }
    }

    @MainActor
    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.controller = DashboardController(
            launchConfiguration: LaunchConfiguration(
                usesMockData: true, suppressesMacOSNotifications: true, verificationUI: .settings
            ),
            automaticRefreshInterval: 0
        )
        delegate.activateApplication = {}
        delegate.configureSettingsRouting()
        return delegate
    }

    @MainActor
    func testStartupAssignsDelegateBeforeRunLoop() {
        let delegate = makeDelegate()
        let previousDelegate = NSApplication.shared.delegate
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        defer {
            NSApplication.shared.delegate = previousDelegate
            NSApplication.shared.setActivationPolicy(previousActivationPolicy)
        }
        mergehawkApp.runApplication(delegate: delegate) {
            XCTAssertTrue(NSApplication.shared.delegate === delegate)
            delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            XCTAssertEqual(
                UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)["NSInitialToolTipDelay"] as? Int,
                500
            )
        }
    }

    @MainActor
    func testAutomaticVerificationSettingsIsBackgroundButExplicitRoutesActivate() throws {
        let delegate = makeDelegate()
        var activations = 0
        delegate.activateApplication = { activations += 1 }
        defer { delegate.settingsWindow?.close() }
        delegate.showVerificationUI(.settings)
        let window = try XCTUnwrap(delegate.settingsWindow)
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(delegate.settingsWindowState.selection, .general)
        for selection in [SettingsTab.about, .general, .github] {
            delegate.controller.showSettings(selection: selection)
            XCTAssertTrue(delegate.settingsWindow === window)
            XCTAssertEqual(delegate.settingsWindowState.selection, selection)
        }
        XCTAssertEqual(activations, 3)
        window.close()
        delegate.controller.showGitHubSettings()
        XCTAssertTrue(delegate.settingsWindow === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(delegate.settingsWindowState.selection, .github)
    }

    @MainActor
    func testKeyboardSettingsPreservesSelectionAfterCloseAndMinimize() throws {
        let delegate = makeDelegate()
        defer { delegate.settingsWindow?.close() }
        delegate.controller.showSettingsPreservingSelection()
        let window = try XCTUnwrap(delegate.settingsWindow)
        XCTAssertEqual(delegate.settingsWindowState.selection, .general)
        delegate.controller.showSettings(selection: .about)
        delegate.controller.showSettingsPreservingSelection()
        XCTAssertEqual(delegate.settingsWindowState.selection, .about)
        window.close()
        delegate.controller.showSettingsPreservingSelection()
        XCTAssertTrue(delegate.settingsWindow === window)
        XCTAssertEqual(delegate.settingsWindowState.selection, .about)
        window.miniaturize(nil)
        waitUntil { window.isMiniaturized }
        XCTAssertTrue(window.isMiniaturized)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        XCTAssertTrue(window.isMiniaturized)
        delegate.controller.showSettingsPreservingSelection()
        waitUntil { !window.isMiniaturized }
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(delegate.settingsWindow === window)
        XCTAssertEqual(delegate.settingsWindowState.selection, .about)
    }

    @MainActor
    func testSettingsWindowIsOpenFromShowUntilClose() throws {
        let delegate = makeDelegate()
        XCTAssertFalse(delegate.settingsWindowState.isOpen)
        delegate.showSettingsWindow()
        let window = try XCTUnwrap(delegate.settingsWindow)
        XCTAssertTrue(delegate.settingsWindowState.isOpen)

        window.close()
        XCTAssertFalse(delegate.settingsWindowState.isOpen)

        delegate.showSettingsWindow(selection: .general)
        XCTAssertTrue(delegate.settingsWindow === window)
        XCTAssertTrue(delegate.settingsWindowState.isOpen)
        window.close()
        XCTAssertFalse(delegate.settingsWindowState.isOpen)
    }

    @MainActor
    func testReopenNeverCreatesOrShowsSettings() throws {
        let delegate = makeDelegate()
        XCTAssertFalse(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        XCTAssertNil(delegate.settingsWindow)
        delegate.controller.showSettings()
        let window = try XCTUnwrap(delegate.settingsWindow)
        window.close()
        XCTAssertFalse(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(delegate.settingsWindow === window)
    }

    @MainActor
    func testMainMenuSettingsAndAboutUseSharedWindowAndKeepOrdinaryCommands() throws {
        let delegate = makeDelegate()
        let application = NSApplication.shared
        let priorMenu = application.mainMenu
        let priorServicesMenu = application.servicesMenu
        let priorWindowsMenu = application.windowsMenu
        let priorHelpMenu = application.helpMenu
        defer {
            delegate.settingsWindow?.close()
            application.mainMenu = priorMenu
            application.servicesMenu = priorServicesMenu
            application.windowsMenu = priorWindowsMenu
            application.helpMenu = priorHelpMenu
        }
        delegate.installMainMenu()
        let menu = try XCTUnwrap(application.mainMenu)
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        let settings = try XCTUnwrap(appMenu.items.first { $0.keyEquivalent == "," })
        XCTAssertTrue(settings.target as? AppDelegate === delegate)
        XCTAssertTrue(application.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        let window = try XCTUnwrap(delegate.settingsWindow)
        delegate.controller.showGitHubSettings()
        XCTAssertTrue(application.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        XCTAssertEqual(delegate.settingsWindowState.selection, .github)
        let about = try XCTUnwrap(appMenu.items.first { $0.title.hasPrefix("About ") })
        XCTAssertTrue(application.sendAction(try XCTUnwrap(about.action), to: about.target, from: about))
        XCTAssertEqual(delegate.settingsWindowState.selection, .about)
        XCTAssertTrue(delegate.settingsWindow === window)
        let quit = try XCTUnwrap(appMenu.items.first { $0.keyEquivalent == "q" })
        XCTAssertEqual(quit.action, #selector(NSApplication.terminate(_:)))
        XCTAssertNil(quit.target)
        let edit = try XCTUnwrap(menu.items.first { $0.title == "Edit" }?.submenu)
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "z"),
                                      ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                      ("Paste", "paste:", "v"), ("Delete", "delete:", ""),
                                      ("Select All", "selectAll:", "a")] {
            let item = try XCTUnwrap(edit.items.first { $0.title == title })
            XCTAssertEqual(item.action, NSSelectorFromString(selector))
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertNil(item.target)
        }
        let windows = try XCTUnwrap(application.windowsMenu)
        XCTAssertEqual(windows.items.first { $0.title == "Close" }?.action, #selector(NSWindow.performClose(_:)))
        XCTAssertEqual(windows.items.first { $0.title == "Minimize" }?.action, #selector(NSWindow.performMiniaturize(_:)))
        let minimizeAll = try XCTUnwrap(windows.items.first { $0.title == "Minimize All" })
        XCTAssertEqual(minimizeAll.action, #selector(NSApplication.miniaturizeAll(_:)))
        XCTAssertNil(minimizeAll.target)

        let unrelated = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        unrelated.isReleasedWhenClosed = false
        defer { unrelated.close() }
        unrelated.orderBack(nil)
        XCTAssertTrue(unrelated.isVisible)
        XCTAssertTrue(window.isVisible)
        let closeAll = try XCTUnwrap(windows.items.first { $0.title == "Close All" })
        XCTAssertTrue(application.sendAction(try XCTUnwrap(closeAll.action), to: closeAll.target, from: closeAll))
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(unrelated.isVisible)
    }

    @MainActor
    func testStatusAndHostedKeyboardRoutesPreserveSelectionButFooterSelectsGeneral() throws {
        let delegate = makeDelegate()
        defer { delegate.settingsWindow?.close() }
        delegate.controller.showSettings(selection: .github)
        let window = try XCTUnwrap(delegate.settingsWindow)
        let status = StatusBarController(controller: delegate.controller)
        let items = status.rebuildMenuForTesting()
        _ = items[1].target?.perform(items[1].action, with: items[1])
        XCTAssertEqual(delegate.settingsWindowState.selection, .github)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: ",", charactersIgnoringModifiers: ",",
            isARepeat: false, keyCode: 43
        ))
        XCTAssertTrue(status.performMenuKeyEquivalentForTesting(event))
        XCTAssertEqual(delegate.settingsWindowState.selection, .github)
        let hosted = try XCTUnwrap(items[0].view as? MenuRootHostingView)
        XCTAssertTrue(hosted.performKeyEquivalent(with: event))
        XCTAssertEqual(delegate.settingsWindowState.selection, .github)
        hosted.rootView.showSettings()
        XCTAssertEqual(delegate.settingsWindowState.selection, .general)
        XCTAssertTrue(delegate.settingsWindow === window)
    }
    @MainActor
    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

}
