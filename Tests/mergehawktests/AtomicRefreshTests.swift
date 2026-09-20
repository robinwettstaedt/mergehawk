@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

final class AtomicRefreshTests: XCTestCase {
    @MainActor
    func testFailedRefreshPreservesStoredAndPublishedPresentationWithoutNotifications() async throws {
        let fixture = try makeFixture(provider: AtomicGitHubProvider(result: .failure))
        defer { fixture.cleanup() }

        await waitUntil { fixture.controller.errorMessage != nil }

        XCTAssertEqual(fixture.controller.state, fixture.previous.dashboard)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState, fixture.previous)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
    }

    @MainActor
    func testPersistenceEncodingFailureLeavesPriorLiveAndStoredStateUnchanged() async throws {
        let updated = makePullRequest(id: "PR_UPDATED", title: "Updated")
        let fixture = try makeFixture(
            provider: AtomicGitHubProvider(
                result: .success(CompletePullRequestFetchResult(activePullRequests: [updated]))
            ),
            encoder: { _ in throw AtomicTestError.encodingFailed }
        )
        defer { fixture.cleanup() }

        await waitUntil { fixture.controller.errorMessage != nil }

        XCTAssertEqual(fixture.controller.state, fixture.previous.dashboard)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState, fixture.previous)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
    }

    @MainActor
    func testReadDuringSuspendedRefreshIsMergedIntoCommittedState() async throws {
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }

        fixture.controller.markPullRequestNotificationRead(
            fixture.controller.pullRequestNotificationHistory[0]
        )
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory[0].read)
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [fixture.pullRequest]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory[0].read)
        XCTAssertTrue(fixture.preferences.pullRequestSyncState?.notificationHistory[0].read == true)
    }

    @MainActor
    func testRepeatedRefreshRequestsShareOneSuspendedAttempt() async throws {
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }

        fixture.controller.refresh()
        fixture.controller.refresh()
        await Task.yield()
        XCTAssertEqual(provider.fetchCount, 1)
        XCTAssertEqual(fixture.controller.state, fixture.previous.dashboard)

        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [fixture.pullRequest]))
        await waitUntil { !fixture.controller.isRefreshing }
        XCTAssertEqual(provider.fetchCount, 1)
    }

    @MainActor
    func testSignOutPreventsLateRefreshWriteAndNotificationDelivery() async throws {
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }

        fixture.controller.signOut()
        let late = makePullRequest(
            id: fixture.pullRequest.id,
            title: "Late",
            comments: fixture.pullRequest.recentCommentActivities + [
                PullRequestCommentActivity(
                    id: "COMMENT_LATE",
                    author: "teammate",
                    createdAt: Date(timeIntervalSince1970: 20),
                    source: .pullRequest
                )
            ]
        )
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [late]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.state.authStatus, .signedOut)
        XCTAssertTrue(fixture.controller.state.pullRequests.isEmpty)
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
    }

    @MainActor
    func testFinalRetirementNotificationRetainsTitleAndOpenableURL() async throws {
        let baseline = makePullRequest(id: "PR_MERGED", title: "Ship atomic refresh")
        let final = makePullRequest(
            id: baseline.id,
            title: baseline.title,
            comments: baseline.recentCommentActivities + [
                PullRequestCommentActivity(
                    id: "COMMENT_FINAL",
                    author: "reviewer",
                    createdAt: Date(timeIntervalSince1970: 20),
                    source: .pullRequest
                )
            ]
        )
        let provider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [], retiringPullRequests: [final]))
        )
        var openedURLs: [URL] = []
        let fixture = try makeFixture(
            pullRequest: baseline,
            provider: provider,
            urlOpener: { openedURLs.append($0) }
        )
        defer { fixture.cleanup() }

        await waitUntil { provider.fetchCount == 1 }
        await waitUntil { !fixture.controller.isRefreshing }
        let notification = try XCTUnwrap(
            fixture.controller.pullRequestNotificationHistory.first { $0.activityId == "COMMENT_FINAL" }
        )
        XCTAssertEqual(notification.prTitle, baseline.title)
        XCTAssertEqual(notification.url, baseline.url)
        XCTAssertTrue(fixture.controller.state.pullRequests.isEmpty)
        XCTAssertEqual(fixture.notifications.records.map(\.eventType), ["new_comment"])

        fixture.controller.openPullRequestNotification(notification)
        XCTAssertEqual(openedURLs, [baseline.url])
    }

    @MainActor
    private func makeFixture(
        pullRequest: PullRequest = makePullRequest(id: "PR_BASELINE", title: "Baseline"),
        provider: AtomicGitHubProvider,
        encoder: @escaping (PullRequestSyncState) throws -> Data = { try JSONEncoder().encode($0) },
        urlOpener: @escaping @MainActor (URL) -> Void = { _ in }
    ) throws -> AtomicFixture {
        let suiteName = "atomic-refresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var seedPreferences = PreferencesStore(defaults: defaults)
        seedPreferences.authMethod = .pat
        let notification = PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: pullRequest.id, activityId: "COMMENT_OLD"),
            pullRequest: pullRequest,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let previous = PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: DashboardState(
                pullRequests: [pullRequest],
                events: [],
                syncedAt: Date(timeIntervalSince1970: 10),
                source: .github,
                account: GitHubAccount(login: "rw"),
                authStatus: .signedIn
            ),
            processedActivityByPullRequestID: [
                pullRequest.id: ProcessedPullRequestActivity(
                    pullRequestID: pullRequest.id,
                    commentIDs: Set(pullRequest.recentCommentActivities.map(\.id))
                )
            ],
            notificationHistory: [notification]
        )
        try seedPreferences.storePullRequestSyncState(previous)
        let preferences = PreferencesStore(defaults: defaults, syncStateEncoder: encoder)
        let notifications = RecordingNotificationClient()
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            notificationClient: notifications,
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in provider },
            urlOpener: urlOpener
        )
        return AtomicFixture(
            suiteName: suiteName,
            controller: controller,
            provider: provider,
            notifications: notifications,
            preferences: preferences,
            previous: previous,
            pullRequest: pullRequest
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }
}

private enum AtomicTestError: Error, LocalizedError {
    case refreshFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .refreshFailed: "Refresh failed"
        case .encodingFailed: "Encoding failed"
        }
    }
}

private final class AtomicGitHubProvider: GitHubProviding {
    enum ResultMode {
        case success(CompletePullRequestFetchResult)
        case failure
        case suspended
    }

    let sourceKind: DashboardSource = .github
    private var result: ResultMode
    private var continuation: CheckedContinuation<CompletePullRequestFetchResult, Error>?
    private(set) var fetchCount = 0

    init(result: ResultMode) {
        self.result = result
    }

    func fetchViewer() async throws -> GitHubAccount {
        GitHubAccount(login: "rw")
    }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        fetchCount += 1
        switch result {
        case .success(let value): return value
        case .failure: throw AtomicTestError.refreshFailed
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    func finish(with result: CompletePullRequestFetchResult) {
        self.result = .success(result)
        continuation?.resume(returning: result)
        continuation = nil
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: accountLogin)
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }
}

@MainActor
private struct AtomicFixture {
    let suiteName: String
    let controller: DashboardController
    let provider: AtomicGitHubProvider
    let notifications: RecordingNotificationClient
    let preferences: PreferencesStore
    let previous: PullRequestSyncState
    let pullRequest: PullRequest

    func cleanup() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}

private func makePullRequest(
    id: String,
    title: String,
    comments: [PullRequestCommentActivity] = [
        PullRequestCommentActivity(
            id: "COMMENT_OLD",
            author: "teammate",
            createdAt: Date(timeIntervalSince1970: 5),
            source: .pullRequest
        )
    ]
) -> PullRequest {
    PullRequest(
        id: id,
        title: title,
        number: 42,
        url: URL(string: "https://github.com/acme/app/pull/42")!,
        repo: "acme/app",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: comments.count,
        commentActivityCount: comments.count,
        recentCommentActivities: comments,
        reviewCount: 0,
        recentReviews: [],
        headRefOid: "abc",
        isMine: true,
        author: "rw",
        headRefName: "feature",
        mergeable: .mergeable,
        draft: false,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 20)
    )
}
