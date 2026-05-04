import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let controller: DashboardController
    private var observation: NSKeyValueObservation?

    init(controller: DashboardController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusButton()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    func updateStatusButton() {
        guard let button = statusItem.button else {
            return
        }
        button.image = StatusIcon.make(attention: controller.hasAttention)
        button.image?.isTemplate = !controller.hasAttention
        button.title = controller.attentionCount > 0 ? " \(controller.attentionCount)" : ""
    }

    private func rebuildMenu() {
        updateStatusButton()
        menu.removeAllItems()

        let root = MenuRootView(controller: controller)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 470)

        let item = NSMenuItem()
        item.view = hostingView
        menu.addItem(item)

        menu.addItem(.separator())
        menu.addItem(Self.makeRefreshItem(target: self, action: #selector(refresh)))
        menu.addItem(actionItem("Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(actionItem("About VC Dash", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit VC Dash", action: #selector(quit), keyEquivalent: "q"))
    }

    static func makeRefreshItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "Refresh", action: action, keyEquivalent: "r")
        item.target = target
        return item
    }

    private func actionItem(_ title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func refresh() {
        controller.refresh()
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    @objc private func showSettings() {
        controller.showSettings()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

enum StatusIcon {
    static func make(attention: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(x: 2, y: 2, width: 14, height: 14)
        NSColor.labelColor.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.lineWidth = 1.8
        path.stroke()

        NSColor.labelColor.setFill()
        NSBezierPath(rect: NSRect(x: 6, y: 6, width: 6, height: 1.8)).fill()
        NSBezierPath(rect: NSRect(x: 6, y: 10, width: 6, height: 1.8)).fill()

        if attention {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 12, y: 12, width: 5, height: 5)).fill()
        }

        image.isTemplate = !attention
        return image
    }
}
