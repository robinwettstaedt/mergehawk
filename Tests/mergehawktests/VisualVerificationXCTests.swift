@testable import mergehawk
import AppKit
import SwiftUI
import mergehawkcore
import XCTest

final class VisualVerificationXCTests: XCTestCase {
    func testWritesMockMenuScreenshots() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["MERGEHAWK_UI_ARTIFACT_DIR"], !outputPath.isEmpty else {
            throw XCTSkip("Set MERGEHAWK_UI_ARTIFACT_DIR to write UI verification artifacts.")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let suiteName = "mergehawk-visual-verification-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0
            )
        }

        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                controller.state.syncedAt != nil
            }
        }

        await MainActor.run {
            controller.refresh()
        }
        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                controller.state.events.isEmpty == false
            }
        }

        try await MainActor.run {
            let signedOutController = DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0
            )
            try renderMenu(
                controller: signedOutController,
                to: outputURL.appendingPathComponent("menu-signed-out.png")
            )
            try render(
                SettingsRootView(controller: signedOutController, selection: .github),
                size: SettingsTab.defaultWindowSize,
                to: outputURL.appendingPathComponent("settings-github-signed-out.png")
            )

            controller.selectedTab = .notifications
            controller.selectedNotificationSubtab = .pullRequests
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-notifications.png"))

            controller.selectedNotificationSubtab = .other
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-notifications-other.png"))

            controller.selectedTab = .myPRs
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-my-prs.png"))

            controller.selectedTab = .reviewRequests
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests.png"))

            controller.selectedReviewRequestFilters = [.team]
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-team.png"))

            controller.selectedReviewRequestFilters = []
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-all.png"))

            controller.selectedReviewRequestFilters = [.direct, .team]
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-multiple.png"))

            controller.selectedReviewRequestFilters = [.draft]
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-draft.png"))

            controller.selectedReviewRequestFilters = [.ready]
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-ready.png"))

            controller.selectedTab = .notifications
            controller.selectedNotificationSubtab = .pullRequests
            controller.markAllNotificationsRead()
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-notifications-read.png"))

            try render(
                SettingsRootView(controller: controller, selection: .sources),
                size: SettingsTab.defaultWindowSize,
                to: outputURL.appendingPathComponent("settings-sources.png")
            )
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    @MainActor
    private func renderMenu(controller: DashboardController, to url: URL) throws {
        try render(
            MenuRootView(controller: controller)
                .background(.regularMaterial),
            size: CGSize(width: MenuRootView.Layout.width, height: MenuRootView.Layout.height),
            to: url
        )
    }

    @MainActor
    private func render<Content: View>(_ view: Content, size: CGSize, to url: URL) throws {
        let frame = NSRect(origin: .zero, size: size)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = frame

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: frame) else {
            XCTFail("Could not create bitmap representation")
            return
        }
        hostingView.cacheDisplay(in: frame, to: representation)

        guard let data = representation.representation(using: .png, properties: [:]) else {
            XCTFail("Could not create PNG data")
            return
        }
        XCTAssertGreaterThan(data.count, 1_000)
        try data.write(to: url, options: .atomic)

        _ = window
    }
}
