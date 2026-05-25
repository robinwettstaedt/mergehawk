@testable import mergehawk
import Foundation
import mergehawkcore

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

    controller.selectedReviewRequestFilters = [.team]
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_3"])

    controller.selectedReviewRequestFilters = [.assigned]
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_7"])

    controller.selectedReviewRequestFilters = []
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_7", "PR_3", "PR_2"])
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
                reviewDecision: .reviewRequired,
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
