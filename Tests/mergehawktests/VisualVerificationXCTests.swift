@testable import mergehawk
import AppKit
import SwiftUI
import mergehawkcore
import XCTest

final class VisualVerificationXCTests: XCTestCase {
    private var captureSelection = VisualCaptureSelection.all
    private var renderedFilenames: Set<String> = []
    private var waitTimeout: TimeInterval = 5

    func testWritesMockMenuScreenshots() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["MERGEHAWK_UI_ARTIFACT_DIR"], !outputPath.isEmpty else {
            throw XCTSkip("Set MERGEHAWK_UI_ARTIFACT_DIR to write UI verification artifacts.")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        captureSelection = try VisualCaptureSelection(environment: environment)
        renderedFilenames = []
        waitTimeout = try visualWaitTimeout(environment: environment)
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

        try await waitUntil(context: "initial mock synchronization") {
            await MainActor.run {
                controller.state.syncedAt != nil
            }
        }

        await MainActor.run {
            controller.refresh()
        }
        try await waitUntil(context: "mock refresh events") {
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
            try renderSettings(
                SettingsRootView(
                    controller: signedOutController,
                    settingsWindowState: SettingsWindowState(selection: .github),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-github-signed-out.png")
            )
        }

        try await MainActor.run {
            let patIdleController = DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0
            )
            patIdleController.openGitHubSettingsInPATMode = true
            try renderSettings(
                SettingsRootView(
                    controller: patIdleController,
                    settingsWindowState: SettingsWindowState(selection: .github),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-github-pat-idle.png"),
                prepareLightRender: {
                    patIdleController.openGitHubSettingsInPATMode = true
                }
            )
        }

        let patLoadingClient = VisualPATLoadingGitHubProvider()
        let patLoadingController = await MainActor.run {
            let controller = DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                patGitHubClientFactory: { _ in patLoadingClient }
            )
            controller.openGitHubSettingsInPATMode = true
            return controller
        }
        Task {
            await patLoadingController.signInWithToken("github_pat_visual")
        }
        try await waitUntil(context: "PAT viewer request to start") {
            await MainActor.run {
                patLoadingController.isSigningInWithToken
            } && patLoadingClient.isWaitingForViewer
        }
        try await MainActor.run {
            try renderSettings(
                SettingsRootView(
                    controller: patLoadingController,
                    settingsWindowState: SettingsWindowState(selection: .github),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-github-pat-loading.png"),
                pausesAnimations: true,
                prepareLightRender: {
                    patLoadingController.openGitHubSettingsInPATMode = true
                }
            )
            patLoadingClient.finishViewerFetch()
        }
        try await waitUntil(context: "PAT sign-in to finish") {
            await MainActor.run {
                !patLoadingController.isSigningInWithToken
            }
        }

        let pendingSignInController = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                oauthSignIn: VisualPendingOAuthSignIn(),
                urlOpener: { _ in },
                deviceFlowURLOpener: { _ in }
            )
        }
        Task {
            await pendingSignInController.signInWithGitHub()
        }
        try await waitUntil(context: "device-flow challenge") {
            await MainActor.run {
                pendingSignInController.deviceFlowChallenge != nil
            }
        }
        try await MainActor.run {
            try renderMenu(
                controller: pendingSignInController,
                to: outputURL.appendingPathComponent("menu-sign-in-pending.png")
            )
            try renderSettings(
                SettingsRootView(
                    controller: pendingSignInController,
                    settingsWindowState: SettingsWindowState(selection: .github),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-github-sign-in-pending.png")
            )
            pendingSignInController.cancelDeviceFlowSignIn()
        }

        let loadingClient = VisualLoadingGitHubProvider()
        let loadingSignInController = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                oauthSignIn: VisualOAuthSignIn(),
                oauthGitHubClientFactory: { _ in loadingClient },
                urlOpener: { _ in },
                deviceFlowURLOpener: { _ in }
            )
        }
        Task {
            await loadingSignInController.signInWithGitHub()
        }
        try await waitUntil(context: "signed-in pull request loading phase") {
            await MainActor.run {
                loadingSignInController.deviceFlowPhase == .loadingApp
            } && loadingClient.isWaitingForPullRequests
        }
        try await MainActor.run {
            try renderMenu(
                controller: loadingSignInController,
                to: outputURL.appendingPathComponent("menu-sign-in-loading.png")
            )
            try renderSettings(
                SettingsRootView(
                    controller: loadingSignInController,
                    settingsWindowState: SettingsWindowState(selection: .github),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-github-sign-in-loading.png")
            )
            loadingClient.finishPullRequestFetch()
        }
        try await waitUntil(context: "signed-in loading to finish") {
            await MainActor.run {
                loadingSignInController.state.authStatus == .signedIn
            }
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
                urlOpener: { _ in },
                deviceFlowURLOpener: { _ in }
            )
        }
        try await waitUntil(context: "repository-access fixture synchronization") {
            await MainActor.run {
                accessPromptController.state.syncedAt != nil
            }
        }
        await accessPromptController.signInWithGitHub()
        try await waitUntil(context: "repository-access prompt") {
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
            try renderSettings(
                SettingsRootView(
                    controller: accessPromptController,
                    settingsWindowState: SettingsWindowState(selection: .sources),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-sources-repository-access.png")
            )
        }

        try await MainActor.run {
            try renderSettings(
                SettingsRootView(
                    controller: controller,
                    settingsWindowState: SettingsWindowState(selection: .general),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-general.png")
            )
            try renderSettings(
                SettingsRootView(
                    controller: controller,
                    settingsWindowState: SettingsWindowState(selection: .general),
                    softwareUpdateController: SoftwareUpdateController.testing()
                ),
                to: outputURL.appendingPathComponent("settings-general-updates.png")
            )
            try renderSettings(
                SettingsRootView(
                    controller: controller,
                    settingsWindowState: SettingsWindowState(selection: .notifications),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-notifications.png")
            )
            try renderSettings(
                SettingsRootView(
                    controller: controller,
                    settingsWindowState: SettingsWindowState(selection: .about),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-about.png")
            )
            controller.selectedTab = .notifications
            controller.selectedNotificationSubtab = .pullRequests
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-notifications.png"))

            controller.selectedNotificationSubtab = .other
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-notifications-other.png"))

            controller.selectedTab = .myPRs
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-my-prs.png"))
            try renderHeaderTooltips(
                pullRequest: XCTUnwrap(controller.requestedSections.first?.visible.first),
                to: outputURL.appendingPathComponent("menu-header-tooltips.png")
            )
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-my-prs-laptop.png"),
                availableFrame: CGRect(x: 0, y: 28, width: 1280, height: 740)
            )
            controller.pullRequestSortOption = .changeSize
            controller.pullRequestSortDirection = .ascending
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-my-prs-change-size.png"))
            controller.pullRequestSortOption = .createdDate
            controller.pullRequestSortDirection = .descending
            controller.pinnedPullRequestIds = Set(controller.sourceFilteredMyPullRequests.prefix(1).map(\.id))
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-my-prs-pinned.png"))
            controller.pinnedPullRequestIds = []
            controller.hiddenPullRequestIds = Set(controller.sourceFilteredMyPullRequests.prefix(2).map(\.id))
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-my-prs-hidden-collapsed.png"))
            try render(
                PullRequestListView(
                    controller: controller,
                    mode: .authored,
                    hiddenPullRequestsExpanded: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.regularMaterial),
                size: CGSize(width: MenuRootView.Layout.width, height: MenuRootView.Layout.height - 100),
                to: outputURL.appendingPathComponent("menu-my-prs-hidden-expanded.png")
            )
            try render(
                PullRequestListView(
                    controller: controller,
                    mode: .authored,
                    hiddenPullRequestsExpanded: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.regularMaterial),
                size: CGSize(width: MenuRootView.Layout.width, height: MenuRootView.Layout.height - 100),
                appearance: .aqua,
                to: outputURL.appendingPathComponent("menu-my-prs-hidden-expanded-light.png")
            )
            controller.hiddenPullRequestIds = []
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
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-review-requests-laptop.png"),
                availableFrame: CGRect(x: 0, y: 28, width: 1280, height: 740)
            )
            controller.pullRequestSortOption = .changeSize
            controller.pullRequestSortDirection = .ascending
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-change-size.png"))
            controller.pullRequestSortOption = .createdDate
            controller.pullRequestSortDirection = .descending
            controller.pinnedPullRequestIds = Set(controller.sourceFilteredReviewRequests.filter { $0.reviewRequestKind != .none }.prefix(1).map(\.id))
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-pinned.png"))
            controller.pinnedPullRequestIds = []
            controller.hiddenPullRequestIds = Set(controller.sortedReviewRequests.prefix(2).map(\.id))
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-review-requests-hidden-collapsed.png")
            )
            try render(
                PullRequestListView(
                    controller: controller,
                    mode: .reviewRequests,
                    hiddenPullRequestsExpanded: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.regularMaterial),
                size: CGSize(width: MenuRootView.Layout.width, height: MenuRootView.Layout.height - 100),
                to: outputURL.appendingPathComponent("menu-review-requests-hidden-expanded.png")
            )
            try render(
                PullRequestListView(
                    controller: controller,
                    mode: .reviewRequests,
                    hiddenPullRequestsExpanded: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.regularMaterial),
                size: CGSize(width: MenuRootView.Layout.width, height: MenuRootView.Layout.height - 100),
                appearance: .aqua,
                to: outputURL.appendingPathComponent("menu-review-requests-hidden-expanded-light.png")
            )
            controller.hiddenPullRequestIds = []
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

            controller.selectedReviewRequestFilters = []
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-all.png"))

            controller.toggleRequestedSection(.direct)
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-review-requests-section-collapsed.png")
            )
            controller.toggleRequestedSection(.direct)

            controller.setRepositoryPreferences(
                repo: "billing-platform-experiments/customer-subscription-dashboard",
                preferences: RepositorySourcePreferences(
                    notifications: .inherit,
                    myPullRequests: .inherit,
                    reviewRequests: .disabled
                )
            )
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-review-requests-section-empty.png")
            )

            controller.selectedReviewRequestFilters = [.draft]
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-review-requests-filtered-empty.png")
            )
            controller.sourcePreferences = populatedSourcePreferences

            controller.selectedReviewRequestFilters = [.draft]
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-draft.png"))

            controller.selectedReviewRequestFilters = [.ready]
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-ready.png"))

            controller.selectedTab = .notifications
            controller.selectedNotificationSubtab = .pullRequests
            controller.markAllNotificationsRead()
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-notifications-read.png"))

            try renderSettings(
                SettingsRootView(
                    controller: controller,
                    settingsWindowState: SettingsWindowState(selection: .sources),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-sources.png")
            )
            try renderSettings(
                SettingsRootView(
                    controller: controller,
                    settingsWindowState: SettingsWindowState(selection: .sources),
                    softwareUpdateController: SoftwareUpdateController.disabled(),
                    initialSourcesSearchState: ExpandableSearchState(isExpanded: true, query: "example")
                ),
                to: outputURL.appendingPathComponent("settings-sources-search-example.png")
            )
        }

        let expectedFilenames = captureSelection.expectedFilenames
        guard renderedFilenames == expectedFilenames else {
            let missing = expectedFilenames.subtracting(renderedFilenames).sorted().joined(separator: ", ")
            let unexpected = renderedFilenames.subtracting(expectedFilenames).sorted().joined(separator: ", ")
            XCTFail("Visual capture output mismatch. Missing: [\(missing)]. Unexpected: [\(unexpected)].")
            throw VisualCaptureError.outputMismatch
        }
        for filename in renderedFilenames.sorted() {
            print("UI artifact: \(filename)")
        }
    }

    private func waitUntil(context: String, condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(waitTimeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out after \(waitTimeout) seconds waiting for \(context)")
        throw VisualCaptureError.timedOut(context: context, seconds: waitTimeout)
    }

    @MainActor
    private func renderMenu(
        controller: DashboardController,
        to url: URL,
        availableFrame: CGRect? = nil
    ) throws {
        let size = availableFrame.map { MenuPanelSize.resolve(availableFrame: $0) }
            ?? CGSize(width: MenuRootView.Layout.width, height: MenuRootView.Layout.height)
        let view = MenuRootView(controller: controller, footerModel: MenuFooterModel(), resolvedSize: size)
            .background(.regularMaterial)

        try render(view, size: size, appearance: .darkAqua, to: url)

        let lightFilename = url.deletingPathExtension().lastPathComponent + "-light." + url.pathExtension
        let lightURL = url.deletingLastPathComponent().appendingPathComponent(lightFilename)
        try render(view, size: size, appearance: .aqua, to: lightURL)
    }

    @MainActor
    private func renderHeaderTooltips(pullRequest: PullRequest, to url: URL) throws {
        let size = CGSize(width: MenuRootView.Layout.width, height: 920)
        let view = ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 36) {
                ForEach(PullRequestColumnLegend.Column.allCases) { column in
                    VStack(spacing: 3) {
                        RequestedSectionHeading(
                            section: .assigned,
                            count: 1,
                            isExpanded: true,
                            previewHoveredColumn: column,
                            action: {}
                        )
                        PullRequestRow(
                            pullRequest: pullRequest,
                            isAttention: false,
                            isPinned: false,
                            isHidden: false,
                            toggleHide: {},
                            togglePin: {},
                            action: {}
                        )
                    }
                }
            }
            .padding(.top, 12)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(.regularMaterial)

        try render(view, size: size, appearance: .darkAqua, to: url)
        let lightFilename = url.deletingPathExtension().lastPathComponent + "-light." + url.pathExtension
        let lightURL = url.deletingLastPathComponent().appendingPathComponent(lightFilename)
        try render(view, size: size, appearance: .aqua, to: lightURL)
    }

    @MainActor
    private func renderSettings<Content: View>(
        _ makeView: @autoclosure () -> Content,
        to url: URL,
        pausesAnimations: Bool = false,
        prepareLightRender: () -> Void = {}
    ) throws {
        let size = SettingsTab.defaultWindowSize
        let darkView = makeView()
            .background(Color(nsColor: .windowBackgroundColor))
        try render(
            darkView,
            size: size,
            appearance: .darkAqua,
            to: url,
            pausesAnimations: pausesAnimations
        )

        prepareLightRender()
        let lightFilename = url.deletingPathExtension().lastPathComponent + "-light." + url.pathExtension
        let lightURL = url.deletingLastPathComponent().appendingPathComponent(lightFilename)
        let lightView = makeView()
            .background(Color(nsColor: .windowBackgroundColor))
        try render(
            lightView,
            size: size,
            appearance: .aqua,
            to: lightURL,
            pausesAnimations: pausesAnimations
        )
    }

    @MainActor
    private func render<Content: View>(
        _ view: Content,
        size: CGSize,
        appearance: NSAppearance.Name = .darkAqua,
        to url: URL,
        pausesAnimations: Bool = false
    ) throws {
        guard captureSelection.includes(filename: url.lastPathComponent) else {
            return
        }
        let frame = NSRect(origin: .zero, size: size)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = frame
        hostingView.appearance = NSAppearance(named: appearance)
        if pausesAnimations {
            hostingView.wantsLayer = true
            hostingView.layer?.speed = 0
        }

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
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
        renderedFilenames.insert(url.lastPathComponent)

        _ = window
    }
}

private enum VisualCaptureError: LocalizedError {
    case invalidScenarios([String])
    case invalidSurfaces([String])
    case invalidWaitTimeout(String)
    case noMatchingOutputs
    case outputMismatch
    case timedOut(context: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .invalidScenarios(values):
            "Unknown visual scenarios: \(values.joined(separator: ", "))"
        case let .invalidSurfaces(values):
            "Unknown visual surfaces: \(values.joined(separator: ", "))"
        case let .invalidWaitTimeout(value):
            "MERGEHAWK_UI_WAIT_TIMEOUT_SECONDS must be positive, got: \(value)"
        case .noMatchingOutputs:
            "The selected scenarios and surfaces match no visual outputs"
        case .outputMismatch:
            "Visual capture did not produce exactly the selected outputs"
        case let .timedOut(context, seconds):
            "Timed out after \(seconds) seconds waiting for \(context)"
        }
    }
}

private struct VisualCaptureSelection {
    static let allScenarios: Set<String> = [
        "menu-signed-out",
        "settings-github-signed-out",
        "settings-github-pat-idle",
        "settings-github-pat-loading",
        "menu-sign-in-pending",
        "settings-github-sign-in-pending",
        "menu-sign-in-loading",
        "settings-github-sign-in-loading",
        "menu-repository-access-notifications",
        "menu-repository-access-authored",
        "menu-repository-access-requested",
        "settings-sources-repository-access",
        "settings-general",
        "settings-general-updates",
        "settings-notifications",
        "settings-about",
        "menu-notifications",
        "menu-notifications-other",
        "menu-my-prs",
        "menu-header-tooltips",
        "menu-my-prs-laptop",
        "menu-my-prs-change-size",
        "menu-my-prs-pinned",
        "menu-my-prs-hidden-collapsed",
        "menu-my-prs-hidden-expanded",
        "menu-my-prs-empty",
        "menu-review-requests",
        "menu-review-requests-laptop",
        "menu-review-requests-change-size",
        "menu-review-requests-pinned",
        "menu-review-requests-hidden-collapsed",
        "menu-review-requests-hidden-expanded",
        "menu-review-requests-empty",
        "menu-review-requests-all",
        "menu-review-requests-section-collapsed",
        "menu-review-requests-section-empty",
        "menu-review-requests-filtered-empty",
        "menu-review-requests-draft",
        "menu-review-requests-ready",
        "menu-notifications-read",
        "settings-sources",
        "settings-sources-search-example",
    ]

    static let all = VisualCaptureSelection(scenarios: allScenarios)

    let scenarios: Set<String>

    init(scenarios: Set<String>) {
        self.scenarios = scenarios
    }

    init(environment: [String: String]) throws {
        let requestedScenarios = Self.values(in: environment["MERGEHAWK_UI_SCENARIOS"])
        let invalidScenarios = requestedScenarios.subtracting(Self.allScenarios)
        guard invalidScenarios.isEmpty else {
            throw VisualCaptureError.invalidScenarios(invalidScenarios.sorted())
        }

        let requestedSurfaces = Self.values(in: environment["MERGEHAWK_UI_SURFACES"])
        let validSurfaces: Set<String> = ["menu", "settings"]
        let invalidSurfaces = requestedSurfaces.subtracting(validSurfaces)
        guard invalidSurfaces.isEmpty else {
            throw VisualCaptureError.invalidSurfaces(invalidSurfaces.sorted())
        }

        let scenarioCandidates = requestedScenarios.isEmpty ? Self.allScenarios : requestedScenarios
        scenarios = Set(scenarioCandidates.filter { scenario in
            requestedSurfaces.isEmpty || requestedSurfaces.contains(Self.surface(for: scenario))
        })
        guard !scenarios.isEmpty else {
            throw VisualCaptureError.noMatchingOutputs
        }
    }

    var expectedFilenames: Set<String> {
        Set(scenarios.flatMap { scenario in
            ["\(scenario).png", "\(scenario)-light.png"]
        })
    }

    func includes(filename: String) -> Bool {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let scenario = stem.hasSuffix("-light") ? String(stem.dropLast("-light".count)) : stem
        return scenarios.contains(scenario)
    }

    private static func values(in rawValue: String?) -> Set<String> {
        Set((rawValue ?? "").split(separator: ",").compactMap { rawPart in
            let value = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })
    }

    private static func surface(for scenario: String) -> String {
        scenario.hasPrefix("settings-") ? "settings" : "menu"
    }
}

private func visualWaitTimeout(environment: [String: String]) throws -> TimeInterval {
    guard let rawValue = environment["MERGEHAWK_UI_WAIT_TIMEOUT_SECONDS"], !rawValue.isEmpty else {
        return 5
    }
    guard let value = TimeInterval(rawValue), value > 0 else {
        throw VisualCaptureError.invalidWaitTimeout(rawValue)
    }
    return value
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

@MainActor
private struct VisualPendingOAuthSignIn: GitHubOAuthSigningIn {
    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        DeviceFlowChallenge(
            userCode: "ABCD-1234",
            deviceCode: "fake-device-code",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: Date().addingTimeInterval(900),
            interval: 5
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }
}

private final class VisualLoadingGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    private var pullRequestsContinuation: CheckedContinuation<PullRequestFetchResult, Never>?
    var isWaitingForPullRequests: Bool {
        pullRequestsContinuation != nil
    }

    func fetchViewer() async throws -> GitHubAccount {
        GitHubAccount(login: "rw")
    }

    func fetchPullRequests(
        login: String,
        previousPullRequests: [PullRequest]
    ) async throws -> PullRequestFetchResult {
        await withCheckedContinuation { continuation in
            pullRequestsContinuation = continuation
        }
    }

    func finishPullRequestFetch() {
        pullRequestsContinuation?.resume(returning: PullRequestFetchResult(pullRequests: []))
        pullRequestsContinuation = nil
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: "rw")
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }

    func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult {
        GitHubInboxFetchResult(notifications: [], metadata: metadata)
    }

    func markInboxThreadRead(threadId: String) async throws {}
}

private final class VisualPATLoadingGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    private var viewerContinuation: CheckedContinuation<GitHubAccount, Never>?
    var isWaitingForViewer: Bool { viewerContinuation != nil }

    func fetchViewer() async throws -> GitHubAccount {
        await withCheckedContinuation { continuation in
            viewerContinuation = continuation
        }
    }

    func finishViewerFetch() {
        viewerContinuation?.resume(returning: GitHubAccount(login: "rw"))
        viewerContinuation = nil
    }

    func fetchPullRequests(
        login: String,
        previousPullRequests: [PullRequest]
    ) async throws -> PullRequestFetchResult {
        PullRequestFetchResult(pullRequests: [])
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: "rw")
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }

    func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult {
        GitHubInboxFetchResult(notifications: [], metadata: metadata)
    }

    func markInboxThreadRead(threadId: String) async throws {}
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
