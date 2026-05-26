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
                SettingsRootView(controller: signedOutController, settingsWindowState: SettingsWindowState(selection: .github)),
                size: SettingsTab.defaultWindowSize,
                to: outputURL.appendingPathComponent("settings-github-signed-out.png")
            )
        }

        let accessPromptClient = VisualGitHubProvider(
            sourceCatalog: SourceCatalog(repositories: [], accountLogin: "rw"),
            installations: GitHubAppInstallations(installations: [])
        )
        let accessPromptController = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                oauthSignIn: VisualOAuthSignIn(),
                oauthGitHubClientFactory: { _ in accessPromptClient },
                urlOpener: { _ in }
            )
        }
        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                accessPromptController.state.syncedAt != nil
            }
        }
        await accessPromptController.signInWithGitHub()
        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                accessPromptController.showsGitHubAppRepositoryAccessPrompt
            }
        }

        try await MainActor.run {
            accessPromptController.selectedTab = .notifications
            accessPromptController.selectedNotificationSubtab = .pullRequests
            try renderMenu(
                controller: accessPromptController,
                to: outputURL.appendingPathComponent("menu-repository-access-notifications.png")
            )
            accessPromptController.selectedTab = .myPRs
            try renderMenu(
                controller: accessPromptController,
                to: outputURL.appendingPathComponent("menu-repository-access-authored.png")
            )
            accessPromptController.selectedTab = .reviewRequests
            try renderMenu(
                controller: accessPromptController,
                to: outputURL.appendingPathComponent("menu-repository-access-requested.png")
            )
            try render(
                SettingsRootView(controller: accessPromptController, settingsWindowState: SettingsWindowState(selection: .sources)),
                size: SettingsTab.defaultWindowSize,
                to: outputURL.appendingPathComponent("settings-sources-repository-access.png")
            )
        }

        try await MainActor.run {
            try render(
                SettingsRootView(controller: controller, settingsWindowState: SettingsWindowState(selection: .general)),
                size: SettingsTab.defaultWindowSize,
                to: outputURL.appendingPathComponent("settings-general.png")
            )
            try render(
                SettingsRootView(controller: controller, settingsWindowState: SettingsWindowState(selection: .notifications)),
                size: SettingsTab.defaultWindowSize,
                to: outputURL.appendingPathComponent("settings-notifications.png")
            )
            try render(
                SettingsRootView(controller: controller, selection: .about),
                size: SettingsTab.defaultWindowSize,
                to: outputURL.appendingPathComponent("settings-about.png")
            )

            controller.selectedTab = .notifications
            controller.selectedNotificationSubtab = .pullRequests
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-notifications.png"))

            controller.selectedNotificationSubtab = .other
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-notifications-other.png"))

            controller.selectedTab = .myPRs
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-my-prs.png"))
            controller.pinnedPullRequestIds = Set(controller.sourceFilteredMyPullRequests.prefix(1).map(\.id))
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-my-prs-pinned.png"))
            controller.pinnedPullRequestIds = []
            let populatedSourcePreferences = controller.sourcePreferences
            controller.setOwnerPreferences(
                owner: "mergehawk-labs",
                preferences: OwnerSourcePreferences(
                    notifications: true,
                    myPullRequests: false,
                    reviewRequests: true
                )
            )
            controller.setOwnerPreferences(
                owner: "customer-success-platform",
                preferences: OwnerSourcePreferences(
                    notifications: true,
                    myPullRequests: false,
                    reviewRequests: true
                )
            )
            precondition(controller.sortedMyPullRequests.isEmpty)
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-my-prs-empty.png"))
            controller.sourcePreferences = populatedSourcePreferences

            controller.selectedTab = .reviewRequests
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests.png"))
            controller.pinnedPullRequestIds = Set(controller.sourceFilteredReviewRequests.filter { $0.reviewRequestKind != .none }.prefix(1).map(\.id))
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-pinned.png"))
            controller.pinnedPullRequestIds = []
            controller.setOwnerPreferences(
                owner: "mergehawk-labs",
                preferences: OwnerSourcePreferences(
                    notifications: true,
                    myPullRequests: true,
                    reviewRequests: false
                )
            )
            controller.setOwnerPreferences(
                owner: "billing-platform-experiments",
                preferences: OwnerSourcePreferences(
                    notifications: true,
                    myPullRequests: true,
                    reviewRequests: false
                )
            )
            precondition(controller.sortedReviewRequests.isEmpty)
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-review-requests-empty.png")
            )
            controller.sourcePreferences = populatedSourcePreferences

            controller.selectedReviewRequestFilters = [.team]
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-team.png"))

            controller.selectedReviewRequestFilters = []
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-all.png"))

            controller.selectedReviewRequestFilters = [.assigned]
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-assigned.png"))

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
                SettingsRootView(controller: controller, settingsWindowState: SettingsWindowState(selection: .sources)),
                size: SettingsTab.defaultWindowSize,
                to: outputURL.appendingPathComponent("settings-sources.png")
            )
            try render(
                SettingsRootView(
                    controller: controller,
                    settingsWindowState: SettingsWindowState(selection: .sources),
                    initialSourcesSearchState: ExpandableSearchState(isExpanded: true, query: "example")
                ),
                size: SettingsTab.defaultWindowSize,
                to: outputURL.appendingPathComponent("settings-sources-search-example.png")
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
    private func renderMenu(
        controller: DashboardController,
        to url: URL
    ) throws {
        try render(
            MenuRootView(
                controller: controller
            )
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

@MainActor
private struct VisualOAuthSignIn: GitHubOAuthSigningIn {
    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        DeviceFlowChallenge(
            userCode: "ABCD-1234",
            deviceCode: "fake-device-code",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: .distantFuture,
            interval: 5
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        OAuthTokens(accessToken: "visual-access", refreshToken: "visual-refresh", expiresAt: .distantFuture)
    }
}

private final class VisualGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    let sourceCatalog: SourceCatalog
    let installations: GitHubAppInstallations

    init(sourceCatalog: SourceCatalog, installations: GitHubAppInstallations) {
        self.sourceCatalog = sourceCatalog
        self.installations = installations
    }

    func fetchViewer() async throws -> GitHubAccount {
        GitHubAccount(login: "rw")
    }

    func fetchPullRequests(
        login: String,
        previousPullRequests: [PullRequest]
    ) async throws -> PullRequestFetchResult {
        PullRequestFetchResult(pullRequests: [])
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        sourceCatalog
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        installations
    }

    func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult {
        GitHubInboxFetchResult(notifications: [], metadata: metadata)
    }

    func markInboxThreadRead(threadId: String) async throws {}
}
