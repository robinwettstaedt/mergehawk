@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

final class DashboardControllerXCTests: XCTestCase {
    @MainActor
    func testRequestedSectionsKeepPrioritySortPinsAndSessionCollapse() {
        let suiteName = "requested-sections-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0
        )
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil }

        XCTAssertEqual(controller.requestedSections.map(\.section), [.assigned, .direct, .team])
        XCTAssertEqual(controller.requestedSections.map { $0.visible.map(\.id) }, [["PR_7"], ["PR_5", "PR_2"], ["PR_3"]])
        XCTAssertEqual(controller.requestedSections.map(\.count), [1, 2, 1])

        controller.pinnedPullRequestIds = ["PR_2"]
        XCTAssertEqual(controller.requestedSections[1].visible.map(\.id), ["PR_2", "PR_5"])
        controller.pullRequestSortDirection = .ascending
        XCTAssertEqual(controller.requestedSections[1].visible.map(\.id), ["PR_2", "PR_5"])

        controller.toggleRequestedSection(.direct)
        XCTAssertFalse(controller.isRequestedSectionExpanded(.direct))
        XCTAssertTrue(controller.isRequestedSectionExpanded(.assigned))
        controller.selectedTab = .myPRs
        controller.selectedTab = .reviewRequests
        controller.refresh()
        waitUntil(timeout: 1.0) {
            controller.state.pullRequests.first(where: { $0.id == "PR_2" })?.isAssignedToViewer == true
        }
        XCTAssertFalse(controller.isRequestedSectionExpanded(.direct))
        XCTAssertEqual(controller.requestedSections.map { $0.visible.map(\.id) }, [["PR_2", "PR_7"], ["PR_5"], ["PR_3"]])
        let visibleIds = controller.requestedSections.flatMap { $0.visible.map(\.id) }
        XCTAssertEqual(visibleIds.count, Set(visibleIds).count)
        controller.toggleRequestedSection(.direct)
        XCTAssertTrue(controller.isRequestedSectionExpanded(.direct))
    }

    @MainActor
    func testRequestedSectionsKeepHiddenCountsAndShowEmptyAfterFiltersAndSources() {
        let suiteName = "requested-sections-hidden-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0
        )
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil }

        controller.selectedReviewRequestFilters = [.draft]
        XCTAssertEqual(controller.requestedSections.map(\.count), [0, 0, 1])
        controller.hiddenPullRequestIds = ["PR_3"]
        XCTAssertEqual(controller.requestedSections[2].visible.count, 0)
        XCTAssertEqual(controller.requestedSections[2].hidden.map(\.id), ["PR_3"])
        XCTAssertEqual(controller.requestedSections.map(\.count), [0, 0, 1])

        controller.selectedReviewRequestFilters = [.ready]
        XCTAssertEqual(controller.requestedSections.map(\.count), [1, 2, 0])
        controller.selectedReviewRequestFilters = [.draft]
        controller.setRepositoryPreferences(
            repo: "billing-platform-experiments/customer-subscription-dashboard",
            preferences: RepositorySourcePreferences(
                notifications: .inherit,
                myPullRequests: .inherit,
                reviewRequests: .disabled
            )
        )
        XCTAssertEqual(controller.requestedSections.map(\.section), [.assigned, .direct, .team])
        XCTAssertEqual(controller.requestedSections.map(\.count), [0, 0, 0])
    }

    @MainActor
    func testPATSignInTracksLoadingAndPreventsConcurrentAttempts() async throws {
        let client = DelayedViewerGitHubProvider()
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in client }
        )

        let firstSignIn = Task { await controller.signInWithToken("github_pat_token") }
        try await waitUntilAsync { client.viewerContinuation != nil }

        XCTAssertTrue(controller.isSigningInWithToken)

        await controller.signInWithToken("github_pat_second_token")
        XCTAssertEqual(client.fetchViewerCount, 1)

        client.finishViewerFetch()
        await firstSignIn.value

        XCTAssertFalse(controller.isSigningInWithToken)
        XCTAssertEqual(controller.state.authStatus, .signedIn)
    }

    @MainActor
    func testGitHubAppSignInDoesNotBeginDuringPATSignIn() async throws {
        let client = DelayedViewerGitHubProvider()
        let oauthSignIn = RecordingOAuthSignIn()
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0,
            oauthSignIn: oauthSignIn,
            patGitHubClientFactory: { _ in client }
        )

        let patSignIn = Task { await controller.signInWithToken("github_pat_token") }
        try await waitUntilAsync { client.viewerContinuation != nil }

        await controller.signInWithGitHub()

        XCTAssertEqual(oauthSignIn.requestDeviceCodeCount, 0)
        XCTAssertNil(controller.deviceFlowChallenge)
        XCTAssertTrue(controller.isSigningInWithToken)

        client.finishViewerFetch()
        await patSignIn.value
    }

    @MainActor
    func testPATSignInClearsLoadingAfterFailure() async {
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in FailingViewerGitHubProvider() }
        )

        await controller.signInWithToken("github_pat_token")

        XCTAssertFalse(controller.isSigningInWithToken)
        XCTAssertEqual(controller.errorMessage, FailingViewerGitHubProvider.TestError.failed.localizedDescription)
        XCTAssertEqual(controller.state.authStatus, .signedOut)
    }

    @MainActor
    func testDeviceFlowCopyConfirmationClearsAfterFirstCopy() {
        let oauthSignIn = WaitingOAuthSignIn()
        let copyDate = Date(timeIntervalSince1970: 1_777_800_000)
        var copiedCodes: [String] = []
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0,
            oauthSignIn: oauthSignIn,
            deviceFlowURLOpener: { _ in },
            clipboardWriter: { copiedCodes.append($0) },
            now: { copyDate }
        )

        Task {
            await controller.signInWithGitHub()
        }
        waitUntil(timeout: 1.0) {
            controller.deviceFlowChallenge != nil && oauthSignIn.pollStarted
        }

        controller.copyDeviceFlowUserCode()
        XCTAssertEqual(controller.deviceFlowCodeCopiedAt, copyDate)
        XCTAssertEqual(copiedCodes, ["ABCD-1234"])

        waitUntil(timeout: 2.5) {
            controller.deviceFlowCodeCopiedAt == nil
        }

        controller.cancelDeviceFlowSignIn()
    }

    @MainActor
    func testDeviceFlowCopyConfirmationRestartsAfterRepeatedCopy() {
        let oauthSignIn = WaitingOAuthSignIn()
        let firstCopyDate = Date(timeIntervalSince1970: 1_777_800_000)
        let secondCopyDate = Date(timeIntervalSince1970: 1_777_800_001)
        var currentDate = firstCopyDate
        var copiedCodes: [String] = []
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0,
            oauthSignIn: oauthSignIn,
            deviceFlowURLOpener: { _ in },
            clipboardWriter: { copiedCodes.append($0) },
            now: { currentDate }
        )

        Task {
            await controller.signInWithGitHub()
        }
        waitUntil(timeout: 1.0) {
            controller.deviceFlowChallenge != nil && oauthSignIn.pollStarted
        }

        controller.copyDeviceFlowUserCode()
        XCTAssertEqual(controller.deviceFlowCodeCopiedAt, firstCopyDate)
        XCTAssertEqual(copiedCodes, ["ABCD-1234"])

        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.2))
        currentDate = secondCopyDate
        controller.copyDeviceFlowUserCode()
        XCTAssertEqual(controller.deviceFlowCodeCopiedAt, secondCopyDate)
        XCTAssertEqual(copiedCodes, ["ABCD-1234", "ABCD-1234"])

        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.1))
        XCTAssertEqual(controller.deviceFlowCodeCopiedAt, secondCopyDate)

        waitUntil(timeout: 2.5) {
            controller.deviceFlowCodeCopiedAt == nil
        }

        controller.cancelDeviceFlowSignIn()
    }

    @MainActor
    private func waitUntilAsync(condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestTimeout.timedOut
    }
}

private enum TestTimeout: Error {
    case timedOut
}

@MainActor let mergehawkSignedOutStartsEmptyTest: Void = {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0
    )

    waitUntil(timeout: 1.0) {
        controller.state.syncedAt != nil
    }

    precondition(controller.state.authStatus == .signedOut)
    precondition(controller.state.pullRequests.isEmpty)
    precondition(controller.state.events.isEmpty)
}()

@MainActor let mergehawkGitHubAppAuthDoesNotSupportInboxNotificationsTest: Void = {
    precondition(GitHubAuthMethod.oauth.label == "GitHub App")
    precondition(!GitHubTokenCapabilities.supportsGitHubInboxNotifications(token: "github_pat_fine_grained"))
    precondition(GitHubTokenCapabilities.supportsGitHubInboxNotifications(token: "ghp_classic"))
}()

@MainActor let mergehawkGitHubAppAuthShowsInboxUnavailableHintTest: Void = {
    let suiteName = "mergehawk-github-app-inbox-unavailable-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let tokenStore = InMemoryTokenStore()
    try! tokenStore.storeOAuthTokens(
        OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
    )
    var preferencesStore = PreferencesStore(defaults: defaults)
    preferencesStore.pullRequestSnapshotCache = signedInSnapshotCache()
    preferencesStore.gitHubInboxNotifications = [inboxNotificationFixture()]

    let controller = DashboardController(
        tokenStore: tokenStore,
        preferencesStore: preferencesStore,
        automaticRefreshInterval: 0
    )

    precondition(controller.state.authStatus == .signedIn)
    precondition(controller.showsGitHubInboxUnavailableHint)
    precondition(controller.visibleGitHubInboxNotifications.isEmpty)
}()

@MainActor let mergehawkSignOutClearsCachedNotificationsTest: Void = {
    let suiteName = "mergehawk-signout-clears-notifications-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var preferencesStore = PreferencesStore(defaults: defaults)
    preferencesStore.pullRequestSnapshotCache = signedInSnapshotCache()
    preferencesStore.pullRequestNotificationHistory = [
        PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: "PR_1"),
            pullRequest: signedInSnapshotCache().pullRequests[0]
        )
    ]
    preferencesStore.gitHubInboxNotifications = [inboxNotificationFixture()]
    preferencesStore.gitHubInboxSyncMetadata = GitHubInboxSyncMetadata(
        eTag: #""etag""#,
        lastFetchedAt: Date(timeIntervalSince1970: 1_777_800_000),
        pollIntervalSeconds: 120
    )

    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        preferencesStore: preferencesStore,
        automaticRefreshInterval: 0
    )

    precondition(!controller.pullRequestNotificationHistory.isEmpty)
    precondition(!controller.visibleGitHubInboxNotifications.isEmpty)
    controller.signOut()
    precondition(controller.pullRequestNotificationHistory.isEmpty)
    precondition(controller.visibleGitHubInboxNotifications.isEmpty)
    precondition(preferencesStore.pullRequestNotificationHistory.isEmpty)
    precondition(preferencesStore.gitHubInboxNotifications.isEmpty)
    precondition(preferencesStore.gitHubInboxSyncMetadata == .empty)
}()

@MainActor let mergehawkGitHubAppRepositoryAccessStatusTest: Void = {
    let installation = GitHubAppInstallation(
        id: 12,
        accountLogin: "acme",
        accountType: "Organization",
        repositorySelection: .selected
    )
    let repositoryCatalog = SourceCatalog(repositories: [
        RepositorySource(owner: "acme", name: "mergehawk")
    ])

    precondition(DashboardController.GitHubAppRepositoryAccessStatus.resolved(
        installations: GitHubAppInstallations(installations: []),
        sourceCatalog: repositoryCatalog
    ) == .noInstallations)
    precondition(DashboardController.GitHubAppRepositoryAccessStatus.resolved(
        installations: GitHubAppInstallations(installations: [installation]),
        sourceCatalog: SourceCatalog(repositories: [], accountLogin: "rw")
    ) == .noVisibleRepositories)
    precondition(DashboardController.GitHubAppRepositoryAccessStatus.resolved(
        installations: GitHubAppInstallations(installations: [installation]),
        sourceCatalog: repositoryCatalog
    ) == .configured)
}()

@MainActor let mergehawkGitHubAppRepositoryAccessPromptAfterSignInTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: []))
    )
    var openedURL: URL?
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        urlOpener: { openedURL = $0 },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.gitHubAppRepositoryAccessStatus == .noInstallations
    }

    precondition(fakeClient.fetchInstallationsCount == 1)
    precondition(controller.gitHubAppRepositoryAccessStatus == .noInstallations)
    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
    controller.openGitHubAppInstallation()
    precondition(openedURL == MergeHawkAuthDefaults.installURL)
}()

@MainActor let mergehawkNoInstallationsStillPromptsWhenPublicRepositoriesAreVisibleTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [
            RepositorySource(owner: "rw", name: "public-repo")
        ], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: []))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.gitHubAppRepositoryAccessStatus == .noInstallations
    }

    precondition(controller.sourceCatalog.repositoryCount == 1)
    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
}()

@MainActor let mergehawkNoInstallationsStillPromptsWhenPullRequestsAreVisibleTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [])),
        pullRequests: [
            PullRequest(
                id: "PR_PUBLIC",
                title: "Public authored PR",
                number: 7,
                url: URL(string: "https://github.com/rw/public-repo/pull/7")!,
                repo: "rw/public-repo",
                ciState: .passing,
                reviewDecision: .noReviewYet,
                commentCount: 0,
                reviewCount: 0,
                isMine: true,
                author: "rw",
                mergeable: .mergeable,
                draft: false
            )
        ]
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.state.pullRequests.count == 1
    }

    precondition(controller.gitHubAppRepositoryAccessStatus == .noInstallations)
    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
}()

@MainActor let mergehawkDeviceFlowPendingStateCanCancelTest: Void = {
    let oauthSignIn = WaitingOAuthSignIn()
    let firstCopyDate = Date(timeIntervalSince1970: 1_777_800_000)
    let secondCopyDate = Date(timeIntervalSince1970: 1_777_800_001)
    var currentDate = firstCopyDate
    var foregroundOpenedURL: URL?
    var deviceFlowOpenedURL: URL?
    var copiedCodes: [String] = []
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: oauthSignIn,
        urlOpener: { foregroundOpenedURL = $0 },
        deviceFlowURLOpener: { deviceFlowOpenedURL = $0 },
        clipboardWriter: { copiedCodes.append($0) },
        now: { currentDate }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.deviceFlowChallenge != nil && oauthSignIn.pollStarted
    }

    precondition(controller.deviceFlowChallenge?.userCode == "ABCD-1234")
    precondition(controller.deviceFlowPhase == .enterCode)
    precondition(controller.deviceFlowCodeCopiedAt == nil)
    precondition(!controller.isRequestingDeviceCode)
    precondition(foregroundOpenedURL == nil)
    precondition(deviceFlowOpenedURL?.absoluteString == "https://github.com/login/device")
    precondition(copiedCodes.isEmpty)

    controller.copyDeviceFlowUserCode()
    precondition(controller.deviceFlowCodeCopiedAt == firstCopyDate)
    precondition(copiedCodes == ["ABCD-1234"])

    currentDate = secondCopyDate
    controller.copyDeviceFlowUserCode()
    precondition(controller.deviceFlowCodeCopiedAt == secondCopyDate)
    precondition(copiedCodes == ["ABCD-1234", "ABCD-1234"])

    controller.cancelDeviceFlowSignIn()

    precondition(controller.deviceFlowChallenge == nil)
    precondition(controller.deviceFlowPhase == nil)
    precondition(controller.deviceFlowCodeCopiedAt == nil)
    precondition(!controller.isRequestingDeviceCode)
    precondition(controller.state.authStatus == .signedOut)
}()

@MainActor let mergehawkMenuDeviceFlowSignInRequestsMenuRevealTest: Void = {
    let oauthSignIn = WaitingOAuthSignIn()
    var revealCount = 0
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: oauthSignIn,
        deviceFlowURLOpener: { _ in },
        clipboardWriter: { _ in }
    )
    controller.showDeviceFlowSignInMenu = {
        revealCount += 1
    }

    Task {
        await controller.signInWithGitHub(keepsMenuVisible: true)
    }
    waitUntil(timeout: 1.0) {
        controller.deviceFlowChallenge != nil && oauthSignIn.pollStarted
    }

    precondition(revealCount == 1)
    precondition(controller.deviceFlowPhase == .enterCode)

    controller.cancelDeviceFlowSignIn()
}()

@MainActor let mergehawkSignOutDuringDeviceFlowViewerFetchDoesNotRestoreSessionTest: Void = {
    let fakeClient = DelayedViewerGitHubProvider()
    let tokenStore = InMemoryTokenStore()
    let controller = DashboardController(
        tokenStore: tokenStore,
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        urlOpener: { _ in },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        fakeClient.viewerContinuation != nil
    }

    precondition(controller.deviceFlowPhase == .loadingApp)
    controller.signOut()
    fakeClient.finishViewerFetch()
    waitUntil(timeout: 1.0) {
        fakeClient.viewerFetchCompleted
    }
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))

    precondition(controller.state.authStatus == .signedOut)
    precondition(controller.deviceFlowChallenge == nil)
    precondition(controller.deviceFlowPhase == nil)
    precondition((try? tokenStore.loadOAuthTokens()) == nil)
    precondition(fakeClient.fetchSourceCatalogCount == 0)
    precondition(fakeClient.fetchPullRequestsCount == 0)
}()

@MainActor let mergehawkSignOutBeforeDeviceFlowPollReturnsDoesNotStoreTokensTest: Void = {
    let oauthSignIn = DelayedPollOAuthSignIn()
    let tokenStore = InMemoryTokenStore()
    let controller = DashboardController(
        tokenStore: tokenStore,
        automaticRefreshInterval: 0,
        oauthSignIn: oauthSignIn,
        urlOpener: { _ in },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.deviceFlowChallenge != nil && oauthSignIn.pollContinuation != nil
    }

    precondition(controller.deviceFlowPhase == .enterCode)
    controller.signOut()
    oauthSignIn.finishPolling()
    waitUntil(timeout: 1.0) {
        oauthSignIn.pollCompleted
    }
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))

    precondition(controller.state.authStatus == .signedOut)
    precondition(controller.deviceFlowChallenge == nil)
    precondition(controller.deviceFlowPhase == nil)
    precondition((try? tokenStore.loadOAuthTokens()) == nil)
}()

@MainActor let mergehawkDeviceFlowPollFailureClearsPhaseTest: Void = {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FailingPollOAuthSignIn(),
        urlOpener: { _ in },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.errorMessage != nil
    }

    precondition(controller.state.authStatus == .signedOut)
    precondition(controller.deviceFlowChallenge == nil)
    precondition(controller.deviceFlowPhase == nil)
}()

@MainActor let mergehawkDeviceFlowPendingStateStaysVisibleUntilDashboardReadyTest: Void = {
    let fakeClient = DelayedSyncGitHubProvider()
    let tokenStore = InMemoryTokenStore()
    let controller = DashboardController(
        tokenStore: tokenStore,
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        urlOpener: { _ in },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        fakeClient.pullRequestsContinuation != nil
    }

    precondition(controller.deviceFlowChallenge?.userCode == "ABCD-1234")
    precondition(controller.deviceFlowPhase == .loadingApp)
    precondition(controller.state.authStatus == .signedOut)
    precondition((try? tokenStore.loadOAuthTokens()) == nil)

    fakeClient.finishPullRequestFetch()
    waitUntil(timeout: 1.0) {
        controller.state.authStatus == .signedIn
    }

    precondition(controller.deviceFlowChallenge == nil)
    precondition(controller.deviceFlowPhase == nil)
    precondition((try? tokenStore.loadOAuthTokens()) != nil)
}()

@MainActor let mergehawkGitHubAppRepositoryAccessUsesInstallationManageURLTest: Void = {
    let manageURL = URL(string: "https://github.com/organizations/acme/settings/installations/1002")!
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "acme",
                accountType: "Organization",
                repositorySelection: .selected,
                htmlURL: manageURL
            )
        ]))
    )
    var openedURL: URL?
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        urlOpener: { openedURL = $0 },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.gitHubAppRepositoryAccessStatus == .noVisibleRepositories
    }

    precondition(controller.gitHubAppRepositoryAccessStatus == .noVisibleRepositories)
    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
    controller.openGitHubAppInstallation()
    precondition(openedURL == manageURL)
}()

@MainActor let mergehawkGitHubAppRepositoryAccessPromptHidesAfterInstallationTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "rw",
                accountType: "User",
                repositorySelection: .all
            )
        ])),
        pullRequests: [
            PullRequest(
                id: "PR_AUTHORED",
                title: "Ship story tales",
                number: 7,
                url: URL(string: "https://github.com/rw/story-tales/pull/7")!,
                repo: "rw/story-tales",
                ciState: .passing,
                reviewDecision: .noReviewYet,
                commentCount: 0,
                reviewCount: 0,
                isMine: true,
                author: "rw",
                mergeable: .mergeable,
                draft: false
            )
        ]
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.state.pullRequests.count == 1
    }

    precondition(controller.gitHubAppRepositoryAccessStatus == .configured)
    precondition(!controller.showsGitHubAppRepositoryAccessPrompt)
    precondition(controller.sortedReviewRequests.isEmpty)
}()

@MainActor let mergehawkConfiguredGitHubAppRepositoryAccessUsesInstallURLTest: Void = {
    let manageURL = URL(string: "https://github.com/settings/installations/1002")!
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [
            RepositorySource(owner: "rw", name: "mergehawk")
        ], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "rw",
                accountType: "User",
                repositorySelection: .all,
                htmlURL: manageURL
            )
        ]))
    )
    var openedURL: URL?
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        urlOpener: { openedURL = $0 },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.gitHubAppRepositoryAccessStatus == .configured
    }

    precondition(!controller.showsGitHubAppRepositoryAccessPrompt)
    controller.openGitHubAppInstallation()
    precondition(openedURL == MergeHawkAuthDefaults.installURL)
}()

@MainActor let mergehawkPATDoesNotShowGitHubAppRepositoryAccessPromptTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: []))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        patGitHubClientFactory: { _ in fakeClient }
    )

    Task {
        await controller.signInWithToken("github_pat_token")
    }
    waitUntil(timeout: 1.0) {
        controller.state.authStatus == .signedIn
    }

    precondition(fakeClient.fetchInstallationsCount == 0)
    precondition(controller.gitHubAppRepositoryAccessStatus == .notApplicable)
    precondition(!controller.showsGitHubAppRepositoryAccessPrompt)
}()

@MainActor let mergehawkGitHubAppInstallationCheckRunsWhenSourceCatalogFailsTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .failure(FakeGitHubProvider.TestError.sourceCatalogFailed),
        installationsResult: .success(GitHubAppInstallations(installations: []))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.gitHubAppRepositoryAccessStatus == .noInstallations
            && controller.sourceErrorMessage != nil
    }

    precondition(fakeClient.fetchInstallationsCount == 1)
    precondition(controller.gitHubAppRepositoryAccessStatus == .noInstallations)
    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
    precondition(controller.sourceErrorMessage == FakeGitHubProvider.TestError.sourceCatalogFailed.localizedDescription)
}()

@MainActor let mergehawkGitHubAppRefreshChecksRepositoryAccessTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [
            RepositorySource(owner: "rw", name: "story-tales")
        ], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "rw",
                accountType: "User",
                repositorySelection: .all
            )
        ]))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        fakeClient.fetchInstallationsCount == 1
    }

    fakeClient.installationsResult = .success(GitHubAppInstallations(installations: []))
    controller.refresh()
    waitUntil(timeout: 1.0) {
        fakeClient.fetchInstallationsCount == 2
            && controller.gitHubAppRepositoryAccessStatus == .noInstallations
    }

    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
}()

@MainActor let mergehawkPATRefreshDoesNotCheckGitHubAppInstallationsTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: []))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        patGitHubClientFactory: { _ in fakeClient }
    )

    Task {
        await controller.signInWithToken("github_pat_token")
    }
    waitUntil(timeout: 1.0) {
        controller.state.authStatus == .signedIn
    }

    controller.refresh()
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))

    precondition(fakeClient.fetchInstallationsCount == 0)
    precondition(controller.gitHubAppRepositoryAccessStatus == .notApplicable)
}()

@MainActor let mergehawkAutomaticRefreshTest: Void = {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0.05
    )

    waitUntil(timeout: 1.0) {
        controller.state.syncedAt != nil
    }

    guard let initialSyncDate = controller.state.syncedAt else {
        preconditionFailure("Initial sync did not complete")
    }

    waitUntil(timeout: 1.0) {
        guard let syncedAt = controller.state.syncedAt else {
            return false
        }
        return syncedAt > initialSyncDate
    }
}()

@MainActor let mergehawkAutomaticRefreshChecksGitHubAppInstallationsTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [
            RepositorySource(owner: "rw", name: "story-tales")
        ], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "rw",
                accountType: "User",
                repositorySelection: .all
            )
        ]))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0.05,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        fakeClient.fetchPullRequestsCount == 1
    }
    precondition(fakeClient.fetchInstallationsCount == 1)

    waitUntil(timeout: 1.0) {
        fakeClient.fetchPullRequestsCount > 1
    }

    waitUntil(timeout: 1.0) {
        fakeClient.fetchInstallationsCount > 1
    }
}()

@MainActor let mergehawkStartAtLoginTest: Void = {
    let launchAtLoginService = FakeLaunchAtLoginService(isEnabled: false)
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        launchAtLoginService: launchAtLoginService,
        automaticRefreshInterval: 0
    )

    precondition(controller.startsAtLogin == false)

    controller.setStartsAtLogin(true)
    precondition(controller.startsAtLogin == true)
    precondition(launchAtLoginService.requestedValues == [true])

    controller.setStartsAtLogin(false)
    precondition(controller.startsAtLogin == false)
    precondition(launchAtLoginService.requestedValues == [true, false])
}()

@MainActor let mergehawkMockModeStartsSignedInWithoutTokenTest: Void = {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
        automaticRefreshInterval: 0
    )

    waitUntil(timeout: 1.0) {
        controller.state.syncedAt != nil
    }

    precondition(controller.state.authStatus == .signedIn)
    precondition(controller.state.source == .mock)
    precondition(controller.state.account?.login == "agent-fixture")
    precondition(controller.state.pullRequests.map(\.id) == ["PR_1", "PR_4", "PR_6", "PR_2", "PR_3", "PR_7", "PR_5"])
    precondition(controller.sortedMyPullRequests.map(\.id) == ["PR_6", "PR_4", "PR_1"])
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_7", "PR_3", "PR_2"])

    precondition(controller.requestedSections.map(\.section) == [.assigned, .direct, .team])
    precondition(controller.requestedSections.map { $0.visible.map(\.id) } == [["PR_7", "PR_2"], ["PR_5"], ["PR_3"]])

    controller.selectedReviewRequestFilters = [.draft]
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_3"])

    controller.selectedReviewRequestFilters = []
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_7", "PR_3", "PR_2"])
}()

@MainActor let mergehawkHiddenPullRequestOrganizationTest: Void = {
    let suiteName = "mergehawk-hidden-organization-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        preferencesStore: PreferencesStore(defaults: defaults),
        launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
        automaticRefreshInterval: 0
    )

    waitUntil(timeout: 1.0) {
        controller.state.syncedAt != nil
    }

    let authored = controller.sourceFilteredMyPullRequests
    let firstAuthored = authored[0]
    controller.pinnedPullRequestIds = [firstAuthored.id]
    controller.toggleHide(firstAuthored)
    precondition(controller.isHidden(firstAuthored))
    precondition(!controller.isPinned(firstAuthored))
    precondition(PreferencesStore(defaults: defaults).hiddenPullRequestIds == [firstAuthored.id])

    controller.togglePin(firstAuthored)
    precondition(controller.isPinned(firstAuthored))
    precondition(!controller.isHidden(firstAuthored))
    precondition(PreferencesStore(defaults: defaults).pinnedPullRequestIds == [firstAuthored.id])
    precondition(PreferencesStore(defaults: defaults).hiddenPullRequestIds.isEmpty)

    controller.togglePin(firstAuthored)
    controller.toggleHide(firstAuthored)
    controller.toggleHide(firstAuthored)
    precondition(!controller.isHidden(firstAuthored))
    precondition(!controller.isPinned(firstAuthored))

    controller.hiddenPullRequestIds = ["PR_1", "PR_4", "PR_6"]
    controller.pullRequestSortOption = .createdDate
    controller.pullRequestSortDirection = .descending
    precondition(controller.sortedMyPullRequests.isEmpty)
    precondition(controller.hiddenMyPullRequests.map(\.id) == ["PR_6", "PR_4", "PR_1"])
    controller.pullRequestSortDirection = .ascending
    precondition(controller.hiddenMyPullRequests.map(\.id) == ["PR_1", "PR_4", "PR_6"])

    controller.hiddenPullRequestIds = ["PR_4"]
    controller.pullRequestSortDirection = .descending
    precondition(controller.sortedMyPullRequests.map(\.id) == ["PR_6", "PR_1"])
    controller.pullRequestSortDirection = .ascending
    precondition(controller.sortedMyPullRequests.map(\.id) == ["PR_1", "PR_6"])

    controller.selectedPullRequestFilters = [.draft]
    precondition(controller.hiddenMyPullRequests.isEmpty)
    precondition(controller.sortedMyPullRequests.map(\.id) == ["PR_1"])

    controller.selectedPullRequestFilters = []
    controller.hiddenPullRequestIds = ["PR_2", "PR_3", "PR_5", "PR_7"]
    controller.pullRequestSortOption = .updatedDate
    controller.pullRequestSortDirection = .descending
    precondition(controller.hiddenReviewRequests.map(\.id) == ["PR_7", "PR_3", "PR_2", "PR_5"])
    controller.pullRequestSortDirection = .ascending
    precondition(controller.hiddenReviewRequests.map(\.id) == ["PR_5", "PR_2", "PR_3", "PR_7"])

    controller.hiddenPullRequestIds = ["PR_2", "PR_5"]
    controller.pullRequestSortDirection = .descending
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_7", "PR_3"])
    controller.pullRequestSortDirection = .ascending
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_3", "PR_7"])

    controller.hiddenPullRequestIds = ["PR_7"]
    controller.selectedReviewRequestFilters = [.ready]
    precondition(controller.hiddenReviewRequests.map(\.id) == ["PR_7"])
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_2"])

    controller.setRepositoryPreferences(
        repo: "mergehawk-labs/review-router",
        preferences: RepositorySourcePreferences(
            notifications: .inherit,
            myPullRequests: .inherit,
            reviewRequests: .disabled
        )
    )
    precondition(controller.hiddenReviewRequests.isEmpty)
}()

@MainActor let mergehawkSourcePreferencesFilterDashboardListsTest: Void = {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
        automaticRefreshInterval: 0
    )

    waitUntil(timeout: 1.0) {
        controller.state.syncedAt != nil
    }

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
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_7", "PR_3", "PR_2"])

    controller.setRepositoryPreferences(
        repo: "mergehawk-labs/desktop-app",
        preferences: RepositorySourcePreferences(
            notifications: .inherit,
            myPullRequests: .inherit,
            reviewRequests: .disabled
        )
    )
    controller.selectedReviewRequestFilters = []
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_7", "PR_3"])
}()

@MainActor
private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    preconditionFailure("Timed out waiting for condition")
}

@MainActor
private struct FakeOAuthSignIn: GitHubOAuthSigningIn {
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
        OAuthTokens(accessToken: "oauth-access", refreshToken: "oauth-refresh", expiresAt: .distantFuture)
    }
}

@MainActor
private final class WaitingOAuthSignIn: GitHubOAuthSigningIn {
    private(set) var pollStarted = false

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
        pollStarted = true
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }
}

@MainActor
private final class DelayedPollOAuthSignIn: GitHubOAuthSigningIn {
    var pollContinuation: CheckedContinuation<OAuthTokens, Never>?
    private(set) var pollCompleted = false

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
        let tokens = await withCheckedContinuation { continuation in
            pollContinuation = continuation
        }
        pollCompleted = true
        return tokens
    }

    func finishPolling() {
        pollContinuation?.resume(
            returning: OAuthTokens(accessToken: "oauth-access", refreshToken: "oauth-refresh", expiresAt: .distantFuture)
        )
        pollContinuation = nil
    }
}

@MainActor
private struct FailingPollOAuthSignIn: GitHubOAuthSigningIn {
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
        throw DeviceFlowError.accessDenied
    }
}

private final class FakeGitHubProvider: GitHubProviding {
    enum TestError: Error, LocalizedError {
        case sourceCatalogFailed

        var errorDescription: String? {
            "Source catalog failed"
        }
    }

    let sourceKind: DashboardSource = .github
    var sourceCatalogResult: Result<SourceCatalog, Error>
    var installationsResult: Result<GitHubAppInstallations, Error>
    var pullRequests: [PullRequest]
    private(set) var fetchInstallationsCount = 0
    private(set) var fetchPullRequestsCount = 0

    init(
        sourceCatalogResult: Result<SourceCatalog, Error>,
        installationsResult: Result<GitHubAppInstallations, Error>,
        pullRequests: [PullRequest] = []
    ) {
        self.sourceCatalogResult = sourceCatalogResult
        self.installationsResult = installationsResult
        self.pullRequests = pullRequests
    }

    func fetchViewer() async throws -> GitHubAccount {
        GitHubAccount(login: "rw")
    }

    func fetchPullRequests(
        login: String,
        previousPullRequests: [PullRequest]
    ) async throws -> PullRequestFetchResult {
        fetchPullRequestsCount += 1
        return PullRequestFetchResult(pullRequests: pullRequests)
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        try sourceCatalogResult.get()
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        fetchInstallationsCount += 1
        return try installationsResult.get()
    }

    func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult {
        GitHubInboxFetchResult(notifications: [], metadata: metadata)
    }

    func markInboxThreadRead(threadId: String) async throws {}
}

private final class DelayedViewerGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    var viewerContinuation: CheckedContinuation<GitHubAccount, Never>?
    private(set) var viewerFetchCompleted = false
    private(set) var fetchViewerCount = 0
    private(set) var fetchSourceCatalogCount = 0
    private(set) var fetchPullRequestsCount = 0

    func fetchViewer() async throws -> GitHubAccount {
        fetchViewerCount += 1
        let viewer = await withCheckedContinuation { continuation in
            viewerContinuation = continuation
        }
        viewerFetchCompleted = true
        return viewer
    }

    func finishViewerFetch() {
        viewerContinuation?.resume(returning: GitHubAccount(login: "rw"))
        viewerContinuation = nil
    }

    func fetchPullRequests(
        login: String,
        previousPullRequests: [PullRequest]
    ) async throws -> PullRequestFetchResult {
        fetchPullRequestsCount += 1
        return PullRequestFetchResult(pullRequests: [])
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        fetchSourceCatalogCount += 1
        return SourceCatalog(repositories: [], accountLogin: "rw")
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }

    func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult {
        GitHubInboxFetchResult(notifications: [], metadata: metadata)
    }

    func markInboxThreadRead(threadId: String) async throws {}
}

private final class FailingViewerGitHubProvider: GitHubProviding {
    enum TestError: Error, LocalizedError {
        case failed

        var errorDescription: String? { "Viewer failed" }
    }

    let sourceKind: DashboardSource = .github

    func fetchViewer() async throws -> GitHubAccount {
        throw TestError.failed
    }

    func fetchPullRequests(
        login: String,
        previousPullRequests: [PullRequest]
    ) async throws -> PullRequestFetchResult {
        PullRequestFetchResult(pullRequests: [])
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: accountLogin)
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }

    func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult {
        GitHubInboxFetchResult(notifications: [], metadata: metadata)
    }

    func markInboxThreadRead(threadId: String) async throws {}
}

@MainActor
private final class RecordingOAuthSignIn: GitHubOAuthSigningIn {
    private(set) var requestDeviceCodeCount = 0

    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        requestDeviceCodeCount += 1
        return DeviceFlowChallenge(
            userCode: "ABCD-1234",
            deviceCode: "fake-device-code",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: .distantFuture,
            interval: 5
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
    }
}

private final class DelayedSyncGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    var pullRequestsContinuation: CheckedContinuation<PullRequestFetchResult, Never>?

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

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    private(set) var requestedValues: [Bool] = []
    var isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ isEnabled: Bool) throws {
        requestedValues.append(isEnabled)
        self.isEnabled = isEnabled
    }
}

private func signedInSnapshotCache() -> PullRequestSnapshotCache {
    PullRequestSnapshotCache(
        pullRequests: [
            PullRequest(
                id: "PR_1",
                title: "Cached PR",
                number: 12,
                url: URL(string: "https://github.com/example/mergehawk/pull/12")!,
                repo: "example/mergehawk",
                ciState: .passing,
                reviewDecision: .noReviewYet,
                commentCount: 0,
                reviewCount: 0,
                isMine: true,
                author: "rw",
                mergeable: .mergeable,
                draft: false
            )
        ],
        account: GitHubAccount(login: "rw"),
        fetchedAt: Date(timeIntervalSince1970: 1_777_800_000),
        source: .github
    )
}

private func inboxNotificationFixture() -> GitHubInboxNotification {
    GitHubInboxNotification(
        threadId: "issue-thread",
        repo: "example/mergehawk",
        subjectTitle: "Cached issue",
        subjectType: "Issue",
        reason: "mention",
        unread: true,
        updatedAt: Date(timeIntervalSince1970: 1_777_800_000),
        threadURL: URL(string: "https://api.github.com/notifications/threads/issue-thread")!,
        webURL: URL(string: "https://github.com/example/mergehawk/issues/1")!
    )
}
