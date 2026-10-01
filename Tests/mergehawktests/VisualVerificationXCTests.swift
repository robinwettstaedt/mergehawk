@testable import mergehawk
import AppKit
import SwiftUI
import mergehawkcore
import XCTest

final class VisualVerificationXCTests: XCTestCase {
    /// One fixed presentation clock for every controller and fixture, so captures do not depend on when they run.
    fileprivate static let visualNow = Date(timeIntervalSince1970: 1_790_000_000)
    fileprivate static func visualClock() -> Date { visualNow }

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
        let menuSizeURL = { (size: MenuSize, name: String) -> URL in
            outputURL.appendingPathComponent("\(MenuSizeCaptures.scenario(size, name)).png")
        }
        let restoreTimeZone = Self.useUTCTimeZone()
        defer { restoreTimeZone() }
        captureSelection = try VisualCaptureSelection(environment: environment)
        renderedFilenames = []
        waitTimeout = try visualWaitTimeout(environment: environment)
        let suiteName = "mergehawk-visual-verification-\(UUID().uuidString)"
        defer {
            for name in [suiteName, "\(suiteName)-delayed", "\(suiteName)-failure", "\(suiteName)-save-error", "\(suiteName)-final", "\(suiteName)-quiet", "\(suiteName)-archived", "\(suiteName)-bots-off", "\(suiteName)-bots-on", "\(suiteName)-comments"] {
                UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            }
        }

        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                now: Self.visualClock
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

        let delayedController = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(
                    defaults: UserDefaults(suiteName: "\(suiteName)-delayed")!
                ),
                launchConfiguration: LaunchConfiguration(
                    usesMockData: true,
                    suppressesMacOSNotifications: true,
                    mockRefreshDelaySeconds: 0.2,
                    mockPullRequestScenario: .delayedRefresh
                ),
                automaticRefreshInterval: 0,
                now: Self.visualClock
            )
        }
        try await waitUntil(context: "delayed-refresh baseline") {
            await MainActor.run { delayedController.state.syncedAt != nil && !delayedController.isRefreshing }
        }
        await MainActor.run { delayedController.refresh() }
        try await waitUntil(context: "delayed complete refresh") {
            await MainActor.run { delayedController.isRefreshing }
        }
        try await MainActor.run {
            delayedController.selectedTab = .myPRs
            try renderMenu(
                controller: delayedController,
                to: outputURL.appendingPathComponent("menu-refresh-loading.png")
            )
            for size in MenuSize.allCases {
                try renderMenu(
                    controller: delayedController,
                    to: menuSizeURL(size, "refresh-loading"),
                    availableFrame: MenuSizeCaptures.stateFrame,
                    menuSize: size
                )
            }
        }
        try await waitUntil(context: "delayed complete refresh completion") {
            await MainActor.run { !delayedController.isRefreshing }
        }

        let failureController = await makeScenarioController(
            .refreshFailure,
            suiteName: "\(suiteName)-failure"
        )
        try await waitUntil(context: "refresh-failure baseline") {
            await MainActor.run { failureController.state.syncedAt != nil && !failureController.isRefreshing }
        }
        await MainActor.run { failureController.refresh() }
        try await waitUntil(context: "refresh-failure result") {
            await MainActor.run { failureController.refreshErrorMessage != nil && !failureController.isRefreshing }
        }
        try await MainActor.run {
            failureController.selectedTab = .myPRs
            try renderMenu(
                controller: failureController,
                to: outputURL.appendingPathComponent("menu-refresh-failure.png")
            )
        }

        let finalActivityController = await makeScenarioController(
            .mergedFinalActivity,
            suiteName: "\(suiteName)-final"
        )
        try await waitUntil(context: "final-activity baseline") {
            await MainActor.run {
                finalActivityController.state.pullRequests.count == 1 && !finalActivityController.isRefreshing
            }
        }
        await MainActor.run { finalActivityController.refresh() }
        try await waitUntil(context: "merged final activity") {
            await MainActor.run {
                finalActivityController.pullRequestNotificationHistory.count == 2
                    && !finalActivityController.isRefreshing
            }
        }
        try await MainActor.run {
            finalActivityController.selectedTab = .notifications
            try renderMenu(
                controller: finalActivityController,
                to: outputURL.appendingPathComponent("menu-final-activity.png")
            )
        }

        let quietRetirementController = await makeScenarioController(
            .quietAccessLoss,
            suiteName: "\(suiteName)-quiet"
        )
        try await waitUntil(context: "quiet-retirement baseline") {
            await MainActor.run {
                quietRetirementController.state.pullRequests.count == 1 && !quietRetirementController.isRefreshing
            }
        }
        await MainActor.run { quietRetirementController.refresh() }
        try await waitUntil(context: "quiet access-loss retirement") {
            await MainActor.run {
                quietRetirementController.state.pullRequests.isEmpty && !quietRetirementController.isRefreshing
            }
        }
        try await MainActor.run {
            quietRetirementController.selectedTab = .notifications
            try renderMenu(
                controller: quietRetirementController,
                to: outputURL.appendingPathComponent("menu-quiet-retirement.png")
            )
        }

        try await MainActor.run {
            let signedOutController = DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                now: Self.visualClock
            )
            try renderMenu(
                controller: signedOutController,
                to: outputURL.appendingPathComponent("menu-signed-out.png")
            )
            for size in MenuSize.allCases {
                try renderMenu(
                    controller: signedOutController,
                    to: menuSizeURL(size, "signed-out"),
                    availableFrame: MenuSizeCaptures.stateFrame,
                    menuSize: size
                )
            }
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
                automaticRefreshInterval: 0,
                now: Self.visualClock
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
                patGitHubClientFactory: { _ in patLoadingClient },
                now: Self.visualClock
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
        for muted in [false, true] {
            let suffix = muted ? "on" : "off"
            let notifications = RecordingNotificationClient()
            let botController = await MainActor.run {
                var preferences = PreferencesStore(defaults: UserDefaults(suiteName: "\(suiteName)-bots-\(suffix)")!)
                preferences.muteBotNotifications = muted
                return DashboardController(
                    tokenStore: InMemoryTokenStore(), preferencesStore: preferences,
                    launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true, mockPullRequestScenario: .botNotifications),
                    notificationClient: notifications, automaticRefreshInterval: 0,
                    now: Self.visualClock
                )
            }
            try await waitUntil(context: "bot-notification \(suffix) baseline") {
                await MainActor.run { botController.state.syncedAt != nil && !botController.isRefreshing }
            }
            await MainActor.run {
                XCTAssertTrue(botController.pullRequestNotificationHistory.isEmpty)
                botController.refresh()
            }
            try await waitUntil(context: "bot-notification \(suffix) updates") {
                await MainActor.run { botController.pullRequestNotificationHistory.count == (muted ? 2 : 12) && !botController.isRefreshing }
            }
            try await MainActor.run {
                XCTAssertEqual(botController.attentionCount, muted ? 2 : 12)
                XCTAssertEqual(Set(notifications.records.map(\.pullRequestId)), muted ? ["PR_BOT_NOTIFICATIONS_MIXED"] : ["PR_BOT_NOTIFICATIONS_MIXED", "PR_BOT_NOTIFICATIONS_ONLY"])
                if muted { XCTAssertTrue(notifications.records.allSatisfy { !$0.body.contains("mergehawk-helper") && !$0.title.contains("mergehawk-helper") }) }
                XCTAssertEqual(botController.isUnreadPullRequest(try XCTUnwrap(botController.state.pullRequests.first { $0.id == "PR_BOT_NOTIFICATIONS_ONLY" })), !muted)
                try renderSettings(
                    SettingsRootView(controller: botController, settingsWindowState: SettingsWindowState(selection: .notifications), softwareUpdateController: SoftwareUpdateController.disabled()),
                    to: outputURL.appendingPathComponent("settings-bot-notifications-\(suffix).png")
                )
                botController.selectedTab = .notifications
                try renderMenu(controller: botController, to: outputURL.appendingPathComponent("menu-bot-notifications-\(suffix).png"))
            }
        }

        let commentController = await MainActor.run {
            makeScenarioController(.commentNotifications, suiteName: "\(suiteName)-comments")
        }
        try await waitUntil(context: "comment-notification baseline") {
            await MainActor.run { commentController.state.syncedAt != nil && !commentController.isRefreshing }
        }
        for (stage, expectedRows) in [(1, 8), (2, 9)] {
            await MainActor.run { commentController.refresh() }
            try await waitUntil(context: "comment-notification stage \(stage)") {
                await MainActor.run {
                    commentController.pullRequestNotificationHistory.count == expectedRows && !commentController.isRefreshing
                }
            }
        }
        try await MainActor.run {
            XCTAssertEqual(
                commentController.pullRequestNotificationHistory.first.map { PullRequestNotificationTitlePresentation.title(for: $0) },
                "@docs-lee mentioned you"
            )
            try renderSettings(
                SettingsRootView(
                    controller: commentController,
                    settingsWindowState: SettingsWindowState(selection: .notifications),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-comment-notifications.png")
            )
            commentController.selectedTab = .notifications
            try renderMenu(controller: commentController, to: outputURL.appendingPathComponent("menu-comment-notifications.png"))
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
                deviceFlowURLOpener: { _ in },
                now: Self.visualClock
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
            for size in MenuSize.allCases {
                try renderMenu(
                    controller: pendingSignInController,
                    to: menuSizeURL(size, "sign-in-pending"),
                    availableFrame: MenuSizeCaptures.stateFrame,
                    menuSize: size
                )
            }
            try renderSettings(
                SettingsRootView(
                    controller: pendingSignInController,
                    settingsWindowState: SettingsWindowState(selection: .github),
                    softwareUpdateController: SoftwareUpdateController.disabled()
                ),
                to: outputURL.appendingPathComponent("settings-github-sign-in-pending.png")
            )
            try renderSettingsIsolation(
                controller: pendingSignInController,
                tabs: MenuSizeCaptures.settingsIsolationPendingSignInTabs,
                outputURL: outputURL
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
                deviceFlowURLOpener: { _ in },
                now: Self.visualClock
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
                deviceFlowURLOpener: { _ in },
                now: Self.visualClock
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
            try renderMenu(
                controller: accessPromptController,
                to: outputURL.appendingPathComponent("menu-repository-access-notifications.png")
            )
            for size in MenuSize.allCases {
                try renderMenu(
                    controller: accessPromptController,
                    to: menuSizeURL(size, "access-prompt"),
                    availableFrame: MenuSizeCaptures.stateFrame,
                    menuSize: size
                )
            }
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

        let archivedSuite = "\(suiteName)-archived"
        let archivedPR = Self.archivedVisualPullRequest(id: "PR_ARCHIVED", repo: "example/archived", archived: true)
        let activePR = Self.archivedVisualPullRequest(id: "PR_ACTIVE", repo: "example/active", archived: false)
        let mixedPRs = [archivedPR, activePR]
        let mixedCatalog = SourceCatalog(
            repositories: [
                RepositorySource(owner: "example", name: "archived"),
                RepositorySource(owner: "example", name: "active")
            ],
            accountLogin: "rw"
        )
        var archivedNotification = PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: archivedPR.id, activityId: "ARCHIVED_COMMENT"),
            pullRequest: archivedPR,
            createdAt: Self.visualNow.addingTimeInterval(-1800)
        )
        archivedNotification.read = false
        var activeNotification = PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: activePR.id, activityId: "ACTIVE_COMMENT"),
            pullRequest: activePR,
            createdAt: Self.visualNow.addingTimeInterval(-3600)
        )
        activeNotification.read = true
        let retainedNotifications = [archivedNotification, activeNotification]
        let archivedProvider = VisualGitHubProvider(
            sourceCatalog: mixedCatalog,
            installations: GitHubAppInstallations(installations: []),
            pullRequests: mixedPRs
        )
        let archivedController = try await MainActor.run { () throws -> DashboardController in
            let store = try Self.seededVisualStore(
                defaults: UserDefaults(suiteName: archivedSuite)!,
                pullRequests: mixedPRs,
                catalog: mixedCatalog,
                notificationHistory: retainedNotifications
            )
            return DashboardController(
                tokenStore: InMemoryTokenStore(token: "visual-fixture"),
                preferencesStore: store,
                launchAtLoginService: InMemoryLaunchAtLoginService(),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                patGitHubClientFactory: { _ in archivedProvider },
                now: Self.visualClock
            )
        }
        try await waitUntil(context: "archived fixture startup refresh") {
            await MainActor.run {
                (archivedController.state.syncedAt ?? .distantPast) > Date(timeIntervalSince1970: 10)
                    && !archivedController.isRefreshing
            }
        }
        try await MainActor.run {
            for (hideArchived, suffix) in [(true, "on"), (false, "off")] {
                archivedController.hideArchivedRepositories = hideArchived
                XCTAssertEqual(PreferencesStore(defaults: UserDefaults(suiteName: archivedSuite)!).hideArchivedRepositories, hideArchived)
                let expectedCount = hideArchived ? 1 : 2
                XCTAssertEqual(archivedController.sortedMyPullRequests.count, expectedCount)
                XCTAssertEqual(archivedController.visiblePullRequestNotifications.count, expectedCount)
                XCTAssertEqual(archivedController.sourceCatalog.repositoryCount, 2)
                try renderSettings(
                    SettingsRootView(
                        controller: archivedController,
                        settingsWindowState: SettingsWindowState(selection: .sources),
                        softwareUpdateController: SoftwareUpdateController.disabled()
                    ),
                    to: outputURL.appendingPathComponent("settings-archived-\(suffix).png")
                )
                archivedController.selectedTab = .myPRs
                try renderMenu(
                    controller: archivedController,
                    to: outputURL.appendingPathComponent("menu-archived-prs-\(suffix).png")
                )
                archivedController.selectedTab = .notifications
                try renderMenu(
                    controller: archivedController,
                    to: outputURL.appendingPathComponent("menu-archived-notifications-\(suffix).png")
                )
            }
        }

        // Saving fails only after startup, so the banner comes from a failed mark-as-read, not a failed refresh.
        let saveFailure = VisualSaveFailure()
        let saveErrorDefaults = UserDefaults(suiteName: "\(suiteName)-save-error")!
        let saveErrorController = try await MainActor.run { () throws -> DashboardController in
            _ = try Self.seededVisualStore(
                defaults: saveErrorDefaults,
                pullRequests: mixedPRs,
                catalog: mixedCatalog,
                notificationHistory: retainedNotifications
            )
            return DashboardController(
                tokenStore: InMemoryTokenStore(token: "visual-fixture"),
                preferencesStore: PreferencesStore(defaults: saveErrorDefaults, syncStateEncoder: { state in
                    if saveFailure.isFailing {
                        throw VisualSaveFailure.Failure()
                    }
                    return try JSONEncoder().encode(state)
                }),
                launchAtLoginService: InMemoryLaunchAtLoginService(),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                patGitHubClientFactory: { _ in archivedProvider },
                now: Self.visualClock
            )
        }
        try await waitUntil(context: "save-error fixture startup refresh") {
            await MainActor.run {
                (saveErrorController.state.syncedAt ?? .distantPast) > Date(timeIntervalSince1970: 10)
                    && !saveErrorController.isRefreshing
            }
        }
        try await MainActor.run {
            saveFailure.isFailing = true
            saveErrorController.markPullRequestNotificationRead(
                try XCTUnwrap(saveErrorController.pullRequestNotificationHistory.first { !$0.read })
            )
            XCTAssertNotNil(saveErrorController.saveErrorMessage)
            saveErrorController.selectedTab = .notifications
            for size in MenuSize.allCases {
                try renderMenu(
                    controller: saveErrorController,
                    to: menuSizeURL(size, "save-error"),
                    availableFrame: MenuSizeCaptures.stateFrame,
                    menuSize: size
                )
            }
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
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-notifications.png"))
            for size in MenuSize.allCases {
                for (tabName, tab) in MenuSizeCaptures.tabs {
                    controller.selectedTab = tab
                    for (frameName, frame) in MenuSizeCaptures.frames {
                        try renderMenu(
                            controller: controller,
                            to: menuSizeURL(size, "\(tabName)-\(frameName)"),
                            availableFrame: frame,
                            menuSize: size
                        )
                    }
                }
            }

            controller.selectedTab = .myPRs
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-my-prs.png"))
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-my-prs-actions-open.png"),
                initialDropdown: .actions(XCTUnwrap(controller.sortedMyPullRequests.first).id)
            )
            for size in MenuSize.allCases {
                try renderMenu(
                    controller: controller,
                    to: menuSizeURL(size, "actions-open"),
                    availableFrame: MenuSizeCaptures.stateFrame,
                    initialDropdown: .actions(XCTUnwrap(controller.sortedMyPullRequests.first).id),
                    menuSize: size
                )
            }
            let tooltipPullRequest = try XCTUnwrap(controller.requestedSections.first?.visible.first)
            try renderHeaderTooltips(
                pullRequest: tooltipPullRequest,
                to: outputURL.appendingPathComponent("menu-header-tooltips.png")
            )
            for size in MenuSize.allCases {
                try renderHeaderTooltips(
                    pullRequest: tooltipPullRequest,
                    metrics: MenuMetrics(scale: size.factor),
                    to: menuSizeURL(size, "header-tooltips")
                )
            }
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-my-prs-laptop.png"),
                availableFrame: CGRect(x: 0, y: 28, width: 1280, height: 740)
            )
            controller.selectedPullRequestFilters = [.changesRequested]
            controller.pullRequestSortOption = .changeSize
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-my-prs-header-filter-open.png"),
                initialDropdown: .filter
            )
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-my-prs-header-sort-open.png"),
                initialDropdown: .sort
            )
            for size in MenuSize.allCases {
                for (stateName, dropdown) in [("filter-open", PullRequestMenuDropdown.filter), ("sort-open", .sort)] {
                    try renderMenu(
                        controller: controller,
                        to: menuSizeURL(size, stateName),
                        availableFrame: MenuSizeCaptures.stateFrame,
                        initialDropdown: dropdown,
                        menuSize: size
                    )
                }
            }
            controller.selectedPullRequestFilters = []
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
            try renderHiddenExpanded(
                controller: controller,
                mode: .authored,
                to: outputURL.appendingPathComponent("menu-my-prs-hidden-expanded.png")
            )
            for size in MenuSize.allCases {
                try renderHiddenExpanded(
                    controller: controller,
                    mode: .authored,
                    metrics: MenuMetrics(scale: size.factor),
                    to: menuSizeURL(size, "my-prs-hidden-expanded")
                )
            }
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
            precondition(controller.collapsedRequestedSections.isEmpty)
            for size in MenuSize.allCases {
                try renderMenu(
                    controller: controller,
                    to: menuSizeURL(size, "requested-sections-expanded"),
                    availableFrame: MenuSizeCaptures.stateFrame,
                    menuSize: size
                )
            }
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-review-requests-laptop.png"),
                availableFrame: CGRect(x: 0, y: 28, width: 1280, height: 740)
            )
            controller.selectedReviewRequestFilters = [.ready]
            controller.reviewRequestSortOption = .updatedDate
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-review-requests-header-filter-open.png"),
                initialDropdown: .filter
            )
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-review-requests-header-sort-open.png"),
                initialDropdown: .sort
            )
            controller.selectedReviewRequestFilters = []
            controller.reviewRequestSortOption = .changeSize
            controller.reviewRequestSortDirection = .ascending
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-change-size.png"))
            controller.reviewRequestSortOption = .createdDate
            controller.reviewRequestSortDirection = .descending
            controller.pinnedPullRequestIds = Set(controller.sourceFilteredReviewRequests.filter { $0.reviewRequestKind != .none }.prefix(1).map(\.id))
            try renderMenu(controller: controller, to: outputURL.appendingPathComponent("menu-review-requests-pinned.png"))
            controller.pinnedPullRequestIds = []
            controller.hiddenPullRequestIds = Set(controller.sortedReviewRequests.prefix(2).map(\.id))
            try renderMenu(
                controller: controller,
                to: outputURL.appendingPathComponent("menu-review-requests-hidden-collapsed.png")
            )
            try renderHiddenExpanded(
                controller: controller,
                mode: .reviewRequests,
                to: outputURL.appendingPathComponent("menu-review-requests-hidden-expanded.png")
            )
            for size in MenuSize.allCases {
                try renderHiddenExpanded(
                    controller: controller,
                    mode: .reviewRequests,
                    metrics: MenuMetrics(scale: size.factor),
                    to: menuSizeURL(size, "review-requests-hidden-expanded")
                )
            }
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

            try renderSettingsIsolation(
                controller: controller,
                tabs: MenuSizeCaptures.settingsIsolationTabs,
                outputURL: outputURL
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

    /// Formats times in UTC for the capture run. `NSTimeZone.default` does not change `TimeZone.current`,
    /// so the process time zone is switched and restored.
    private static func useUTCTimeZone() -> () -> Void {
        let originalTZ = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "UTC", 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        return {
            if let originalTZ {
                setenv("TZ", originalTZ, 1)
            } else {
                unsetenv("TZ")
            }
            tzset()
            NSTimeZone.resetSystemTimeZone()
        }
    }

    private static func archivedVisualPullRequest(id: String, repo: String, archived: Bool) -> PullRequest {
        PullRequest(
            id: id, title: archived ? "Archived repository PR" : "Active repository PR", number: archived ? 68 : 69,
            url: URL(string: "https://github.com/\(repo)/pull/\(archived ? 68 : 69)")!,
            repo: repo, repositoryIsArchived: archived,
            ciState: .passing, reviewDecision: .noReviewYet,
            commentCount: 0, reviewCount: 0, isMine: true, author: "rw",
            mergeable: .mergeable, draft: false,
            createdAt: visualNow.addingTimeInterval(archived ? -7200 : -86_400),
            updatedAt: visualNow.addingTimeInterval(-1800)
        )
    }

    private static func seededVisualStore(
        defaults: UserDefaults,
        pullRequests: [PullRequest],
        catalog: SourceCatalog,
        notificationHistory: [PullRequestNotification]
    ) throws -> PreferencesStore {
        var store = PreferencesStore(defaults: defaults)
        store.authMethod = .pat
        store.sourceCatalog = catalog
        store.sourceCatalogSyncedAt = visualNow
        store.sourceCatalogAccountLogin = "rw"
        let account = GitHubAccount(login: "rw")
        try store.storePullRequestSyncState(PullRequestSyncState(
            account: account,
            dashboard: DashboardState(
                pullRequests: pullRequests, events: [], syncedAt: Date(timeIntervalSince1970: 10),
                source: .github, account: account, authStatus: .signedIn
            ),
            processedActivityByPullRequestID: Dictionary(uniqueKeysWithValues: pullRequests.map {
                ($0.id, PRActivityDetector.processedActivity(for: $0))
            }),
            notificationHistory: notificationHistory
        ))
        return store
    }

    @MainActor
    private func makeScenarioController(
        _ scenario: MockPullRequestScenario,
        suiteName: String
    ) -> DashboardController {
        DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!),
            launchConfiguration: LaunchConfiguration(
                usesMockData: true,
                suppressesMacOSNotifications: true,
                mockPullRequestScenario: scenario
            ),
            automaticRefreshInterval: 0,
            now: Self.visualClock
        )
    }

    @MainActor
    private func renderMenu(
        controller: DashboardController,
        to url: URL,
        availableFrame: CGRect? = nil,
        initialDropdown: PullRequestMenuDropdown? = nil,
        menuSize: MenuSize = .standard
    ) throws {
        // Without a usable frame, the frame is large enough that the panel is never clamped.
        let frame = availableFrame ?? CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        let previousMenuSize = controller.menuSize
        controller.menuSize = menuSize
        defer { controller.menuSize = previousMenuSize }
        let makeMenuView = { () -> NSView in
            let menuView = StatusBarController(controller: controller)
                .makeMenuContentView(availableFrame: frame, initialDropdown: initialDropdown)
            // The status menu hosts the content on the system menu material.
            let materialView = NSVisualEffectView(frame: menuView.frame)
            materialView.material = .menu
            materialView.state = .active
            materialView.addSubview(menuView)
            return materialView
        }

        try renderView(makeMenuView(), appearance: .darkAqua, to: url)

        let lightFilename = url.deletingPathExtension().lastPathComponent + "-light." + url.pathExtension
        let lightURL = url.deletingLastPathComponent().appendingPathComponent(lightFilename)
        try renderView(makeMenuView(), appearance: .aqua, to: lightURL)
    }

    @MainActor
    private func renderHeaderTooltips(
        pullRequest: PullRequest,
        metrics: MenuMetrics = .standard,
        to url: URL
    ) throws {
        let size = CGSize(width: metrics.panel.width, height: 800 * metrics.scale)
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
        .environment(\.menuNow, Self.visualNow)
        .environment(\.menuMetrics, metrics)

        try render(view, size: size, appearance: .darkAqua, to: url)
        let lightFilename = url.deletingPathExtension().lastPathComponent + "-light." + url.pathExtension
        let lightURL = url.deletingLastPathComponent().appendingPathComponent(lightFilename)
        try render(view, size: size, appearance: .aqua, to: lightURL)
    }

    /// Hidden rows can only be expanded through view state, so this fragment is rendered outside the menu factory.
    @MainActor
    private func renderHiddenExpanded(
        controller: DashboardController,
        mode: PullRequestListView.Mode,
        metrics: MenuMetrics = .standard,
        to url: URL
    ) throws {
        let view = PullRequestListView(
            controller: controller,
            mode: mode,
            hiddenPullRequestsExpanded: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .environment(\.menuNow, Self.visualNow)
        .environment(\.menuMetrics, metrics)
        let size = CGSize(width: metrics.panel.width, height: metrics.panelHeight - 100 * metrics.scale)
        try render(view, size: size, to: url)
        let lightFilename = url.deletingPathExtension().lastPathComponent + "-light." + url.pathExtension
        let lightURL = url.deletingLastPathComponent().appendingPathComponent(lightFilename)
        try render(view, size: size, appearance: .aqua, to: lightURL)
    }

    /// The Settings window never scales: each tab renders the same at every menu size as at Default.
    /// Every size renders under the same file names into its own directory, so the comparator can match
    /// them; the Larger renders are kept as artifacts.
    @MainActor
    private func renderSettingsIsolation(
        controller: DashboardController,
        tabs: [(String, SettingsTab)],
        outputURL: URL
    ) throws {
        let workURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mergehawk-settings-isolation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workURL) }
        let previousMenuSize = controller.menuSize
        defer { controller.menuSize = previousMenuSize }

        var directories: [MenuSize: URL] = [:]
        for size in MenuSize.allCases {
            let directory = workURL.appendingPathComponent(size.rawValue)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            directories[size] = directory
            controller.menuSize = size
            for (tabName, tab) in tabs {
                try renderSettings(
                    SettingsRootView(
                        controller: controller,
                        settingsWindowState: SettingsWindowState(selection: tab),
                        softwareUpdateController: SoftwareUpdateController.disabled()
                    ),
                    to: directory.appendingPathComponent("\(MenuSizeCaptures.settingsIsolationScenario(tabName)).png")
                )
            }
        }

        let standardURL = try XCTUnwrap(directories[.standard])
        guard !(try FileManager.default.contentsOfDirectory(atPath: standardURL.path)).isEmpty else {
            return
        }
        for size in MenuSize.allCases where size != .standard {
            let report = try VisualCaptureComparison.compare(before: standardURL, after: try XCTUnwrap(directories[size]))
            XCTAssertFalse(report.failed, "\(size): \(report.description)")
            XCTAssertTrue(report.onlyInAfter.isEmpty, "\(size): \(report.description)")
        }
        let largerURL = try XCTUnwrap(directories[.larger])
        for file in try FileManager.default.contentsOfDirectory(atPath: largerURL.path) {
            let destination = outputURL.appendingPathComponent(file)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: largerURL.appendingPathComponent(file), to: destination)
        }
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
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        try renderView(hostingView, appearance: appearance, to: url, pausesAnimations: pausesAnimations)
    }

    @MainActor
    private func renderView(
        _ view: @autoclosure () -> NSView,
        appearance: NSAppearance.Name,
        to url: URL,
        pausesAnimations: Bool = false
    ) throws {
        guard captureSelection.includes(filename: url.lastPathComponent) else {
            return
        }
        let hostingView = view()
        let frame = NSRect(origin: .zero, size: hostingView.frame.size)
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

/// The menu size captures: every tab on every frame, the listed states and fragments, and Settings isolation.
private enum MenuSizeCaptures {
    static let tabs: [(String, DashboardController.MenuTab)] = [
        ("notifications", .notifications),
        ("authored", .myPRs),
        ("requested", .reviewRequests)
    ]
    static let frames: [(String, CGRect)] = [
        ("1470x919", CGRect(x: 0, y: 0, width: 1470, height: 919)),
        ("900x919", CGRect(x: 0, y: 0, width: 900, height: 919)),
        ("760x600", CGRect(x: 0, y: 0, width: 760, height: 600))
    ]
    /// States are captured on the 13" MacBook Air usable frame.
    static let stateFrame = CGRect(x: 0, y: 0, width: 1470, height: 919)
    static let states = [
        "filter-open",
        "sort-open",
        "actions-open",
        "requested-sections-expanded",
        "refresh-loading",
        "save-error",
        "signed-out",
        "sign-in-pending",
        "access-prompt"
    ]
    static let fragments = ["my-prs-hidden-expanded", "review-requests-hidden-expanded", "header-tooltips"]
    /// General is excluded: its Menu Size control shows the selected size by design.
    static let settingsIsolationTabs: [(String, SettingsTab)] = [
        ("github", .github),
        ("notifications", .notifications),
        ("sources", .sources),
        ("about", .about)
    ]
    /// The GitHub tab while the device-flow sign-in is pending reuses the menu's pending sign-in view.
    static let settingsIsolationPendingSignInTabs: [(String, SettingsTab)] = [
        ("github-sign-in-pending", .github)
    ]

    static func scenario(_ size: MenuSize, _ name: String) -> String {
        "menu-size-\(size == .standard ? "default" : size.rawValue)-\(name)"
    }

    static func settingsIsolationScenario(_ tabName: String) -> String {
        "settings-isolation-larger-\(tabName)"
    }

    static var allScenarios: Set<String> {
        let tabFrameNames = tabs.flatMap { tab in frames.map { frame in "\(tab.0)-\(frame.0)" } }
        let menuNames = tabFrameNames + states + fragments
        return Set(MenuSize.allCases.flatMap { size in menuNames.map { scenario(size, $0) } })
            .union((settingsIsolationTabs + settingsIsolationPendingSignInTabs).map { settingsIsolationScenario($0.0) })
    }
}

/// Lets a fixture's store save normally during startup and fail afterwards.
private final class VisualSaveFailure {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The disk is full." }
    }

    var isFailing = false
}

private struct VisualCaptureSelection {
    private static let baseScenarios: Set<String> = [
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
        "settings-archived-on",
        "settings-archived-off",
        "menu-archived-prs-on",
        "menu-archived-prs-off",
        "menu-archived-notifications-on",
        "menu-archived-notifications-off",
        "settings-general",
        "settings-general-updates",
        "settings-notifications",
        "settings-bot-notifications-off",
        "settings-bot-notifications-on",
        "menu-bot-notifications-off",
        "menu-bot-notifications-on",
        "settings-comment-notifications",
        "menu-comment-notifications",
        "settings-about",
        "menu-notifications",
        "menu-refresh-loading",
        "menu-refresh-failure",
        "menu-final-activity",
        "menu-quiet-retirement",
        "menu-my-prs",
        "menu-my-prs-actions-open",
        "menu-header-tooltips",
        "menu-my-prs-laptop",
        "menu-my-prs-header-filter-open",
        "menu-my-prs-header-sort-open",
        "menu-my-prs-change-size",
        "menu-my-prs-pinned",
        "menu-my-prs-hidden-collapsed",
        "menu-my-prs-hidden-expanded",
        "menu-my-prs-empty",
        "menu-review-requests",
        "menu-review-requests-laptop",
        "menu-review-requests-header-filter-open",
        "menu-review-requests-header-sort-open",
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

    static let allScenarios = baseScenarios.union(MenuSizeCaptures.allScenarios)

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
            expiresAt: VisualVerificationXCTests.visualClock().addingTimeInterval(900),
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
    private var pullRequestsContinuation: CheckedContinuation<CompletePullRequestFetchResult, Never>?
    var isWaitingForPullRequests: Bool {
        pullRequestsContinuation != nil
    }

    func fetchViewer() async throws -> GitHubAccount {
        GitHubAccount(login: "rw")
    }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        await withCheckedContinuation { continuation in
            pullRequestsContinuation = continuation
        }
    }

    func finishPullRequestFetch() {
        pullRequestsContinuation?.resume(returning: CompletePullRequestFetchResult(activePullRequests: []))
        pullRequestsContinuation = nil
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: "rw")
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }

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

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        CompletePullRequestFetchResult(activePullRequests: [])
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: "rw")
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }

}

private final class VisualGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    let sourceCatalog: SourceCatalog
    let installations: GitHubAppInstallations
    let pullRequests: [PullRequest]

    init(sourceCatalog: SourceCatalog, installations: GitHubAppInstallations, pullRequests: [PullRequest] = []) {
        self.sourceCatalog = sourceCatalog
        self.installations = installations
        self.pullRequests = pullRequests
    }

    func fetchViewer() async throws -> GitHubAccount {
        GitHubAccount(login: "rw")
    }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        CompletePullRequestFetchResult(activePullRequests: pullRequests)
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        sourceCatalog
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        installations
    }

}
