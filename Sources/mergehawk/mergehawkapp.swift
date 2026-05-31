import AppKit
import SwiftUI
import UserNotifications

@main
struct mergehawkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(
                controller: appDelegate.controller,
                settingsWindowState: appDelegate.settingsWindowState
            )
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
    let controller = DashboardController(launchConfiguration: .current())
    let settingsWindowState = SettingsWindowState()
    private var statusBarController: StatusBarController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        statusBarController = StatusBarController(controller: controller)
        controller.openSettingsWindow = { [weak self] selection in
            self?.showSettingsWindow(selection: selection)
        }
    }

    private func showSettingsWindow(selection: SettingsTab = .general) {
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
            settingsWindowState.selection = selection
        } else {
            settingsWindowState.selection = selection
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
                    settingsWindowState: settingsWindowState
                )
            )
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            settingsWindow = window
        }

        window.setContentSize(SettingsTab.defaultWindowSize)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
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
        case .openPullRequest(let url):
            controller.open(url)
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
