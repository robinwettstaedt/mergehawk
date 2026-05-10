import AppKit
import Combine
import SwiftUI

@main
struct VCDashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(controller: appDelegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DashboardController(launchConfiguration: .current())
    private var statusBarController: StatusBarController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(controller: controller)
        controller.openSettingsWindow = { [weak self] in
            self?.showSettingsWindow()
        }
        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.statusBarController?.updateStatusButton()
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    private func showSettingsWindow() {
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            let size = SettingsTab.defaultWindowSize
            window = SettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "VC Dash Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: SettingsRootView(controller: controller))
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
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
