@testable import mergehawk
@testable import mergehawkcore
import Foundation
import XCTest

final class SourceRefreshTests: XCTestCase {
    func testSuspendedCatalogDoesNotDelayPATSignInOrFirstPRPublication() async throws {
        let provider = CatalogTestProvider(suspendsCatalog: true)
        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                patGitHubClientFactory: { _ in provider }
            )
        }

        await controller.signInWithToken("github_pat_test")

        await MainActor.run {
            XCTAssertEqual(controller.state.authStatus, AuthStatus.signedIn)
            XCTAssertEqual(controller.state.pullRequests.map { $0.id }, ["PR_SOURCE_TEST"])
            XCTAssertFalse(controller.isSigningInWithToken)
            XCTAssertTrue(controller.isRefreshingSources)
        }
        XCTAssertEqual(provider.fetchPullRequestsCount, 1)
        XCTAssertEqual(provider.fetchSourceCatalogCount, 1)
        provider.finishCatalog()
    }

    func testFreshCatalogSkipsDashboardPollAndExplicitRefreshReloads() async throws {
        let provider = CatalogTestProvider()
        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                patGitHubClientFactory: { _ in provider }
            )
        }

        await controller.signInWithToken("github_pat_test")
        try await waitUntil { provider.fetchSourceCatalogCount == 1 }

        await MainActor.run { controller.refresh() }
        try await waitUntil { provider.fetchPullRequestsCount >= 2 }
        XCTAssertEqual(provider.fetchSourceCatalogCount, 1)

        await MainActor.run { controller.refreshSources() }
        try await waitUntil { provider.fetchSourceCatalogCount == 2 }
    }

    func testCatalogFailureLeavesPublishedPRsAndSetsSourceError() async throws {
        let provider = CatalogTestProvider(catalogError: CatalogTestProvider.TestError.failed)
        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
                automaticRefreshInterval: 0,
                patGitHubClientFactory: { _ in provider }
            )
        }

        await controller.signInWithToken("github_pat_test")
        try await waitUntil {
            await MainActor.run { controller.sourceErrorMessage != nil }
        }

        await MainActor.run {
            XCTAssertEqual(controller.state.pullRequests.map { $0.id }, ["PR_SOURCE_TEST"])
            XCTAssertEqual(controller.sourceErrorMessage, "Catalog failed")
        }
    }

    @MainActor
    func testOAuthAccessTokenCacheCoalescesRefreshAndClearRejectsLateResult() async throws {
        let tokenStore = InMemoryTokenStore()
        let expired = OAuthTokens(
            accessToken: "expired",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 0)
        )
        try tokenStore.storeOAuthTokens(expired)
        let loader = SuspendedRefreshLoader()
        let refresher = OAuthTokenRefresher(
            tokenStore: tokenStore,
            defaultCredentials: OAuthClientCredentials(clientID: "client"),
            load: { request in try await loader.load(request) }
        )
        let cache = OAuthAccessTokenCache(
            tokenStore: tokenStore,
            host: URL(string: "https://github.com")!,
            refresher: refresher
        )

        async let first = cache.accessToken()
        async let second = cache.accessToken()
        await loader.waitUntilRequested()
        XCTAssertEqual(loader.requestCount, 1)

        cache.clear()
        loader.finish()
        do {
            _ = try await (first, second)
            XCTFail("Expected cleared refresh to be rejected")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try tokenStore.loadOAuthTokens(), expired)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }
}

private final class CatalogTestProvider: GitHubProviding {
    enum TestError: Error, LocalizedError {
        case failed
        var errorDescription: String? { "Catalog failed" }
    }

    let sourceKind: DashboardSource = .github
    private let suspendsCatalog: Bool
    private let catalogError: Error?
    private var catalogContinuation: CheckedContinuation<Void, Never>?
    private(set) var fetchPullRequestsCount = 0
    private(set) var fetchSourceCatalogCount = 0

    init(suspendsCatalog: Bool = false, catalogError: Error? = nil) {
        self.suspendsCatalog = suspendsCatalog
        self.catalogError = catalogError
    }

    func fetchViewer() async throws -> GitHubAccount { GitHubAccount(login: "rw") }

    func fetchPullRequests(
        login: String,
        previousPullRequests: [PullRequest]
    ) async throws -> PullRequestFetchResult {
        fetchPullRequestsCount += 1
        return PullRequestFetchResult(pullRequests: [Self.pullRequest])
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        fetchSourceCatalogCount += 1
        if suspendsCatalog {
            await withCheckedContinuation { catalogContinuation = $0 }
        }
        if let catalogError { throw catalogError }
        return SourceCatalog(
            repositories: [RepositorySource(owner: "example", name: "app")],
            accountLogin: accountLogin
        )
    }

    func finishCatalog() {
        catalogContinuation?.resume()
        catalogContinuation = nil
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }

    private static let pullRequest = PullRequest(
        id: "PR_SOURCE_TEST",
        title: "Publish PRs first",
        number: 1,
        url: URL(string: "https://github.com/example/app/pull/1")!,
        repo: "example/app",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        isMine: true,
        author: "rw",
        mergeable: .mergeable,
        draft: false
    )
}

private final class SuspendedRefreshLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var storedRequestCount = 0

    var requestCount: Int { lock.withLock { storedRequestCount } }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let waiters = lock.withLock {
                storedRequestCount += 1
                self.continuation = continuation
                let waiters = requestWaiters
                requestWaiters = []
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRequested() async {
        await withCheckedContinuation { waiter in
            let shouldResume = lock.withLock {
                if storedRequestCount > 0 { return true }
                requestWaiters.append(waiter)
                return false
            }
            if shouldResume { waiter.resume() }
        }
    }

    func finish() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        let data = Data("""
        {"access_token":"fresh","token_type":"bearer","expires_in":28800,"refresh_token":"new-refresh"}
        """.utf8)
        let response = HTTPURLResponse(
            url: URL(string: "https://github.com/login/oauth/access_token")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        continuation?.resume(returning: (data, response))
    }
}
