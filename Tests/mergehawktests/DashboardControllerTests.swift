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
    precondition(controller.state.pullRequests.map(\.id) == ["PR_1", "PR_4", "PR_2", "PR_3", "PR_5"])
    precondition(controller.sortedMyPullRequests.map(\.id) == ["PR_4", "PR_1"])
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_3", "PR_2"])

    controller.selectedReviewRequestFilters = [.team]
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_3"])

    controller.selectedReviewRequestFilters = []
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_3", "PR_2"])
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
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_3", "PR_2"])

    controller.setRepositoryPreferences(
        repo: "mergehawk-labs/desktop-app",
        preferences: RepositorySourcePreferences(
            notifications: .inherit,
            myPullRequests: .inherit,
            reviewRequests: .disabled
        )
    )
    controller.selectedReviewRequestFilters = []
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_3"])
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
