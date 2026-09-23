@testable import mergehawk
@testable import mergehawkcore
import Foundation
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
    func testNotificationAndSourcePreferenceChangesDuringFetchApplyAtCommit() async throws {
        for mode in ["notification", "source"] {
            let provider = AtomicGitHubProvider(result: .suspended)
            let fixture = try makeFixture(provider: provider)
            defer { fixture.cleanup() }
            await waitUntil { provider.fetchCount == 1 }
            if mode == "notification" {
                fixture.controller.preferences = NotificationPreferences(
                    authored: .disabled,
                    assigned: .disabled,
                    directReviewRequests: .disabled,
                    teamReviewRequests: .disabled
                )
            } else {
                fixture.controller.setRepositoryPreferences(
                    repo: fixture.pullRequest.repo,
                    preferences: RepositorySourcePreferences(
                        notifications: .disabled,
                        myPullRequests: .inherit,
                        reviewRequests: .inherit
                    )
                )
            }
            let current = makePullRequest(
                id: fixture.pullRequest.id,
                title: fixture.pullRequest.title,
                comments: fixture.pullRequest.recentCommentActivities + [
                    PullRequestCommentActivity(
                        id: "COMMENT_\(mode)",
                        author: "reviewer",
                        createdAt: Date(timeIntervalSince1970: 30),
                        source: .pullRequest
                    )
                ]
            )
            provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [current]))
            await waitUntil { !fixture.controller.isRefreshing }

            XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
            XCTAssertTrue(fixture.notifications.records.isEmpty)
        }
    }

    @MainActor
    func testLargeCompleteResultPublishesOnlyAfterAllActivityIsPrepared() async throws {
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }
        let comments = (0..<61).map { index in
            PullRequestCommentActivity(
                id: "LARGE_COMMENT_\(index)",
                author: "reviewer",
                createdAt: Date(timeIntervalSince1970: TimeInterval(100 + 2 * index)),
                source: .pullRequest
            )
        }
        let reviews = (0..<60).map { index in
            PullRequestReview(
                id: "LARGE_REVIEW_\(index)",
                state: .approved,
                submittedAt: Date(timeIntervalSince1970: TimeInterval(101 + 2 * index)),
                author: "reviewer"
            )
        }
        let current = makePullRequest(
            id: fixture.pullRequest.id,
            title: "Large complete result",
            comments: comments,
            reviews: reviews
        )

        XCTAssertEqual(fixture.controller.state, fixture.previous.dashboard)
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [current]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.state.pullRequests.first?.recentCommentActivities, [])
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, 30)
        let expectedNewest = (
            comments.map { ($0.id, $0.createdAt) }
                + reviews.map { ($0.id, $0.submittedAt) }
        ).sorted { $0.1 > $1.1 }.prefix(30).map(\.0)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.compactMap(\.activityId), expectedNewest)
        XCTAssertEqual(fixture.notifications.records.count, 121)
    }

    @MainActor
    func testEqualActivityTimestampsUseDeterministicHistoryTieBreak() async throws {
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }
        let timestamp = Date(timeIntervalSince1970: 200)
        let comments = (0..<16).map { index in
            PullRequestCommentActivity(
                id: String(format: "EQUAL_COMMENT_%02d", index),
                author: "reviewer",
                createdAt: timestamp,
                source: .pullRequest
            )
        }
        let reviews = (0..<15).map { index in
            PullRequestReview(
                id: String(format: "EQUAL_REVIEW_%02d", index),
                state: .approved,
                submittedAt: timestamp,
                author: "reviewer"
            )
        }
        let current = makePullRequest(
            id: fixture.pullRequest.id,
            title: "Equal timestamps",
            comments: comments,
            reviews: reviews
        )

        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [current]))
        await waitUntil { !fixture.controller.isRefreshing }

        let expected = (comments.map(\.id) + reviews.map(\.id)).sorted(by: >).prefix(30)
        XCTAssertEqual(
            fixture.controller.pullRequestNotificationHistory.compactMap(\.activityId),
            Array(expected)
        )
        XCTAssertEqual(fixture.notifications.records.count, 31)
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
    func testRefreshAuthenticationFailureKeepsStateForSameAccountSignIn() async throws {
        let provider = AtomicGitHubProvider(
            result: .error(GitHubClientError.httpFailure(endpoint: "GitHub GraphQL", status: 401))
        )
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 && !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.state.authStatus, .signedOut)
        XCTAssertNotNil(fixture.controller.errorMessage)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState, fixture.previous)

        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [fixture.pullRequest]))
        await fixture.controller.signInWithToken("pat")

        XCTAssertEqual(fixture.controller.state.authStatus, .signedIn)
        XCTAssertEqual(fixture.controller.state.pullRequests.map(\.id), [fixture.pullRequest.id])
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
    }

    @MainActor
    func testTransientTokenRefreshFailuresDoNotSignOut() async throws {
        for status in [429, 502] {
            let provider = AtomicGitHubProvider(
                result: .error(GitHubClientError.authRefreshFailed(status: status, detail: nil))
            )
            let fixture = try makeFixture(provider: provider)
            defer { fixture.cleanup() }
            await waitUntil { provider.fetchCount == 1 && !fixture.controller.isRefreshing }

            XCTAssertEqual(fixture.controller.state, fixture.previous.dashboard, "status \(status)")
            XCTAssertNotNil(fixture.controller.errorMessage)
            XCTAssertEqual(fixture.preferences.pullRequestSyncState, fixture.previous)
        }
    }

    @MainActor
    func testRetryAfterSuppressesAutomaticAttemptsUntilPermitted() async throws {
        let suiteName = "atomic-rate-limit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        let pullRequest = makePullRequest(id: "PR_RATE", title: "Rate limited")
        try preferences.storePullRequestSyncState(makeSyncState(pullRequest))
        let provider = RateLimitedGitHubProvider(
            retryAt: .distantPast,
            retryDelay: 1,
            result: CompletePullRequestFetchResult(activePullRequests: [pullRequest])
        )
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            automaticRefreshInterval: 0.01,
            patGitHubClientFactory: { _ in provider }
        )

        await waitUntil { provider.fetchCount == 2 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(provider.fetchCount, 2)
        await waitUntil(timeout: 3) { provider.fetchCount >= 3 }
        XCTAssertGreaterThanOrEqual(provider.requestDates[2], try XCTUnwrap(provider.issuedRetryAt))
        _ = controller
    }

    @MainActor
    func testHTTP200GraphQLRateLimitHeadersDeferAutomaticClientRequests() async throws {
        let suiteName = "atomic-graphql-rate-limit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            AtomicRateLimitURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suiteName)
        }
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        let transport = AtomicRateLimitTransport(retryAfter: 0.15)
        AtomicRateLimitURLProtocol.handler = { request in try transport.response(for: request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AtomicRateLimitURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            automaticRefreshInterval: 0.01,
            patGitHubClientFactory: { GitHubClient(token: $0, session: session) }
        )

        await waitUntil { transport.graphQLRequestDates.count == 1 }
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(transport.graphQLRequestDates.count, 1)
        await waitUntil(timeout: 0.6) {
            transport.graphQLRequestDates.count >= 3 && controller.state.authStatus == .signedIn
        }

        let requestDates = transport.graphQLRequestDates
        XCTAssertGreaterThanOrEqual(requestDates[1].timeIntervalSince(requestDates[0]), 0.14)
        XCTAssertEqual(controller.state.authStatus, .signedIn)
    }

    @MainActor
    func testCredentialReplacementClearsAccountScopedRateDeferral() async throws {
        let suiteName = "atomic-rate-account-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        let pullRequest = makePullRequest(id: "PR_RATE_ACCOUNT", title: "Old account")
        try preferences.storePullRequestSyncState(makeSyncState(pullRequest))
        let oldProvider = RateLimitedGitHubProvider(
            retryAt: Date().addingTimeInterval(60),
            result: CompletePullRequestFetchResult(activePullRequests: [pullRequest]),
            login: "rw"
        )
        let newPR = makePullRequest(id: "PR_NEW_ACCOUNT", title: "New account")
        let newProvider = RateLimitedGitHubProvider(
            retryAt: .distantFuture,
            result: CompletePullRequestFetchResult(activePullRequests: [newPR]),
            login: "new-user",
            emitsRateLimit: false
        )
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "old"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            automaticRefreshInterval: 0.01,
            patGitHubClientFactory: { token -> any GitHubProviding in
                token == "new" ? newProvider : oldProvider
            }
        )
        await waitUntil { oldProvider.fetchCount == 2 }

        await controller.signInWithToken("new")

        XCTAssertEqual(newProvider.fetchCount, 1)
        XCTAssertEqual(controller.state.account?.login, "new-user")
        XCTAssertEqual(controller.state.pullRequests.map(\.id), [newPR.id])
    }

    @MainActor
    func testNewAccountCompletionDoesNotPersistPriorAccountHistory() async throws {
        let newPR = makePullRequest(id: "PR_BOB", title: "Bob's PR")
        let provider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [newPR])),
            login: "bob"
        )
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }

        await waitUntil { provider.fetchCount == 1 && !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.state.account?.login, "bob")
        XCTAssertEqual(fixture.controller.state.pullRequests.map(\.id), [newPR.id])
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState?.account.login, "bob")
        XCTAssertTrue(fixture.preferences.pullRequestSyncState?.notificationHistory.isEmpty == true)
    }

    @MainActor
    func testFailedPATAccountReplacementClearsPriorAccountStateAndRelaunchCannotRestoreIt() async throws {
        let oldProvider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_ALICE", title: "Alice's PR")
            ])),
            login: "rw"
        )
        let bobProvider = AtomicGitHubProvider(result: .failure, login: "bob")
        let fixture = try makeFixture(
            provider: oldProvider,
            patProviderFactory: { token in token == "bob-token" ? bobProvider : oldProvider }
        )
        defer { fixture.cleanup() }
        await waitUntil { oldProvider.fetchCount == 1 && !fixture.controller.isRefreshing }

        await fixture.controller.signInWithToken("bob-token")

        XCTAssertEqual(fixture.controller.errorMessage, "Refresh failed")
        XCTAssertTrue(fixture.controller.state.pullRequests.isEmpty)
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertNil(fixture.preferences.pullRequestSyncState)
        XCTAssertEqual(fixture.preferences.pullRequestSnapshotCache, .empty)
        XCTAssertTrue(fixture.preferences.pullRequestNotificationHistory.isEmpty)

        let relaunched = DashboardController(
            tokenStore: InMemoryTokenStore(token: "bob-token"),
            preferencesStore: fixture.preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in bobProvider }
        )
        await waitUntil { bobProvider.fetchCount >= 2 && relaunched.errorMessage != nil }
        XCTAssertTrue(relaunched.state.pullRequests.isEmpty)
        XCTAssertTrue(relaunched.pullRequestNotificationHistory.isEmpty)
    }

    @MainActor
    func testFailedOAuthAccountReplacementClearsPriorAccountState() async throws {
        let oldProvider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_ALICE_OAUTH", title: "Alice before OAuth")
            ]))
        )
        let bobProvider = AtomicGitHubProvider(result: .failure, login: "bob")
        var openedDeviceFlowURLs: [URL] = []
        let fixture = try makeFixture(
            provider: oldProvider,
            oauthSignIn: ImmediateAtomicOAuthSignIn(),
            oauthProvider: bobProvider,
            deviceFlowURLOpener: { openedDeviceFlowURLs.append($0) }
        )
        defer { fixture.cleanup() }
        await waitUntil { oldProvider.fetchCount == 1 && !fixture.controller.isRefreshing }

        await fixture.controller.signInWithGitHub()
        await waitUntil { fixture.controller.errorMessage == "Refresh failed" }

        XCTAssertEqual(openedDeviceFlowURLs, [URL(string: "https://github.com/login/device")!])
        XCTAssertTrue(fixture.controller.state.pullRequests.isEmpty)
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertNil(fixture.preferences.pullRequestSyncState)
        XCTAssertEqual(fixture.preferences.pullRequestSnapshotCache, .empty)
        XCTAssertTrue(fixture.preferences.pullRequestNotificationHistory.isEmpty)
    }

    @MainActor
    func testUnverifiedPATReplacementFailureRetainsPriorAccountState() async throws {
        let oldProvider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_ALICE_UNVERIFIED", title: "Alice remains")
            ]))
        )
        let invalidProvider = AtomicGitHubProvider(result: .failure, login: "bob", viewerFails: true)
        let fixture = try makeFixture(
            provider: oldProvider,
            patProviderFactory: { token in token == "invalid" ? invalidProvider : oldProvider }
        )
        defer { fixture.cleanup() }
        await waitUntil { oldProvider.fetchCount == 1 && !fixture.controller.isRefreshing }
        let priorDashboard = fixture.controller.state
        let priorHistory = fixture.controller.pullRequestNotificationHistory
        let priorPersisted = fixture.preferences.pullRequestSyncState

        await fixture.controller.signInWithToken("invalid")

        XCTAssertEqual(fixture.controller.state, priorDashboard)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, priorHistory)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState, priorPersisted)
    }

    @MainActor
    func testDifferentAccountReplacementClearsSourcesCatalogBeforeSuspendedRefreshCompletes() async throws {
        let oldProvider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_SOURCE_OWNER", title: "Old source owner")
            ]))
        )
        let bobProvider = AtomicGitHubProvider(result: .suspended, login: "bob")
        let catalog = SourceCatalog(
            repositories: [RepositorySource(owner: "acme", name: "private-app")],
            accountLogin: "rw"
        )
        let fixture = try makeFixture(
            provider: oldProvider,
            patProviderFactory: { token in token == "bob" ? bobProvider : oldProvider },
            sourceCatalog: catalog
        )
        defer { fixture.cleanup() }
        await waitUntil { oldProvider.fetchCount == 1 && !fixture.controller.isRefreshing }
        let sourcePreferences = SourcePreferences(
            owners: [
                "acme": OwnerSourcePreferences(
                    notifications: false,
                    myPullRequests: true,
                    reviewRequests: false
                )
            ],
            repositories: [:]
        )
        fixture.controller.sourcePreferences = sourcePreferences

        let signIn = Task { await fixture.controller.signInWithToken("bob") }
        await waitUntil { bobProvider.fetchCount == 1 }

        XCTAssertEqual(fixture.controller.sourceCatalog, .empty)
        XCTAssertEqual(fixture.preferences.sourceCatalog, .empty)
        XCTAssertNil(fixture.preferences.sourceCatalogSyncedAt)
        XCTAssertNil(fixture.preferences.sourceCatalogAccountLogin)
        XCTAssertEqual(fixture.controller.sourcePreferences, sourcePreferences)
        bobProvider.finish(with: CompletePullRequestFetchResult(activePullRequests: []))
        await signIn.value
    }

    @MainActor
    func testSameAccountCaseVariationPreservesSourcesCatalogDuringSuspendedRefresh() async throws {
        let oldProvider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_SOURCE_SAME", title: "Same source owner")
            ]))
        )
        let sameProvider = AtomicGitHubProvider(result: .suspended, login: "RW")
        let catalog = SourceCatalog(
            repositories: [RepositorySource(owner: "acme", name: "private-app")],
            accountLogin: "rw"
        )
        let fixture = try makeFixture(
            provider: oldProvider,
            patProviderFactory: { token in token == "same" ? sameProvider : oldProvider },
            sourceCatalog: catalog
        )
        defer { fixture.cleanup() }
        await waitUntil { oldProvider.fetchCount == 1 && !fixture.controller.isRefreshing }

        let signIn = Task { await fixture.controller.signInWithToken("same") }
        await waitUntil { sameProvider.fetchCount == 1 }

        XCTAssertEqual(fixture.controller.sourceCatalog, catalog)
        XCTAssertEqual(fixture.preferences.sourceCatalog, catalog)
        XCTAssertNotNil(fixture.preferences.sourceCatalogSyncedAt)
        XCTAssertEqual(fixture.preferences.sourceCatalogAccountLogin, "rw")
        sameProvider.finish(with: CompletePullRequestFetchResult(activePullRequests: []))
        await signIn.value
    }

    @MainActor
    func testSameAccountReauthenticationRetainsHistoryReadFlags() async throws {
        let provider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_BASELINE", title: "Baseline")
            ]))
        )
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 && !fixture.controller.isRefreshing }
        fixture.controller.markPullRequestNotificationRead(
            fixture.controller.pullRequestNotificationHistory[0]
        )

        await fixture.controller.signInWithToken("replacement-pat")

        XCTAssertEqual(provider.fetchCount, 2)
        XCTAssertEqual(fixture.controller.state.account?.login, "rw")
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, 1)
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory[0].read)
        XCTAssertTrue(fixture.preferences.pullRequestSyncState?.notificationHistory[0].read == true)
    }

    @MainActor
    func testSameAccountLegacyImportRetainsHistoryOnFirstCompleteRefresh() async throws {
        let suiteName = "atomic-legacy-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        let pullRequest = makePullRequest(id: "PR_LEGACY", title: "Legacy history")
        var notification = PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: pullRequest.id, activityId: "LEGACY_COMMENT"),
            pullRequest: pullRequest,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        notification.read = true
        preferences.pullRequestSnapshotCache = PullRequestSnapshotCache(
            pullRequests: [pullRequest],
            account: GitHubAccount(login: "rw"),
            fetchedAt: Date(timeIntervalSince1970: 10),
            source: .github
        )
        preferences.pullRequestNotificationHistory = [notification]
        let provider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [pullRequest]))
        )
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in provider }
        )

        await waitUntil { provider.fetchCount == 1 && !controller.isRefreshing }

        XCTAssertEqual(controller.pullRequestNotificationHistory, [notification])
        XCTAssertEqual(preferences.pullRequestSyncState?.notificationHistory, [notification])
        XCTAssertTrue(preferences.pullRequestSyncState?.notificationHistory[0].read == true)
    }

    @MainActor
    func testLateOldProviderCompletionCannotOverwriteReplacementCredentials() async throws {
        let suiteName = "atomic-late-provider-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        let oldPR = makePullRequest(id: "PR_OLD", title: "Old provider")
        try preferences.storePullRequestSyncState(makeSyncState(oldPR))
        let oldProvider = AtomicGitHubProvider(result: .suspended)
        let newPR = makePullRequest(id: "PR_NEW", title: "New provider")
        let newProvider = RateLimitedGitHubProvider(
            retryAt: .distantFuture,
            result: CompletePullRequestFetchResult(activePullRequests: [newPR]),
            login: "new-user",
            emitsRateLimit: false
        )
        let notifications = RecordingNotificationClient()
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "old"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            notificationClient: notifications,
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { token -> any GitHubProviding in
                if token == "new" { return newProvider }
                return oldProvider
            }
        )
        await waitUntil { oldProvider.fetchCount == 1 }

        await controller.signInWithToken("new")
        oldProvider.finish(with: CompletePullRequestFetchResult(activePullRequests: [
            makePullRequest(
                id: oldPR.id,
                title: oldPR.title,
                comments: oldPR.recentCommentActivities + [
                    PullRequestCommentActivity(
                        id: "COMMENT_LATE_OLD_PROVIDER",
                        author: "reviewer",
                        createdAt: Date(timeIntervalSince1970: 40),
                        source: .pullRequest
                    )
                ]
            )
        ]))
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(controller.state.account?.login, "new-user")
        XCTAssertEqual(controller.state.pullRequests.map(\.id), [newPR.id])
        XCTAssertTrue(notifications.records.isEmpty)
    }

    @MainActor
    private func makeFixture(
        pullRequest: PullRequest = makePullRequest(id: "PR_BASELINE", title: "Baseline"),
        provider: AtomicGitHubProvider,
        encoder: @escaping (PullRequestSyncState) throws -> Data = { try JSONEncoder().encode($0) },
        urlOpener: @escaping @MainActor (URL) -> Void = { _ in },
        oauthSignIn: GitHubOAuthSigningIn? = nil,
        oauthProvider: AtomicGitHubProvider? = nil,
        patProviderFactory: ((String) -> any GitHubProviding)? = nil,
        sourceCatalog: SourceCatalog? = nil,
        deviceFlowURLOpener: @escaping @MainActor (URL) -> Void = { _ in }
    ) throws -> AtomicFixture {
        let suiteName = "atomic-refresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var seedPreferences = PreferencesStore(defaults: defaults)
        seedPreferences.authMethod = .pat
        if let sourceCatalog {
            seedPreferences.sourceCatalog = sourceCatalog
            seedPreferences.sourceCatalogSyncedAt = Date()
            seedPreferences.sourceCatalogAccountLogin = "rw"
        }
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
            oauthSignIn: oauthSignIn,
            patGitHubClientFactory: patProviderFactory ?? { _ in provider },
            oauthGitHubClientFactory: { _ in oauthProvider ?? provider },
            urlOpener: urlOpener,
            deviceFlowURLOpener: deviceFlowURLOpener
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
        case error(Error)
        case suspended
    }

    let sourceKind: DashboardSource = .github
    private var result: ResultMode
    private let login: String
    private let viewerFails: Bool
    private var continuation: CheckedContinuation<CompletePullRequestFetchResult, Error>?
    private(set) var fetchCount = 0

    init(result: ResultMode, login: String = "rw", viewerFails: Bool = false) {
        self.result = result
        self.login = login
        self.viewerFails = viewerFails
    }

    func fetchViewer() async throws -> GitHubAccount {
        if viewerFails { throw AtomicTestError.refreshFailed }
        return GitHubAccount(login: login)
    }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        fetchCount += 1
        switch result {
        case .success(let value): return value
        case .failure: throw AtomicTestError.refreshFailed
        case .error(let error): throw error
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
private struct ImmediateAtomicOAuthSignIn: GitHubOAuthSigningIn {
    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        DeviceFlowChallenge(
            userCode: "CODE",
            deviceCode: "device",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: Date().addingTimeInterval(600),
            interval: 1
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        OAuthTokens(accessToken: "bob-access", refreshToken: "bob-refresh", expiresAt: .distantFuture)
    }
}

private final class RateLimitedGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    private let lock = NSLock()
    private let retryAt: Date
    private let retryDelay: TimeInterval?
    private let result: CompletePullRequestFetchResult
    private let login: String
    private let emitsRateLimit: Bool
    private var storedRequestDates: [Date] = []
    private var storedIssuedRetryAt: Date?

    /// `retryDelay` measures the retry window from the rate-limited request itself, independent of scheduling delays.
    init(
        retryAt: Date,
        retryDelay: TimeInterval? = nil,
        result: CompletePullRequestFetchResult,
        login: String = "rw",
        emitsRateLimit: Bool = true
    ) {
        self.retryAt = retryAt
        self.retryDelay = retryDelay
        self.result = result
        self.login = login
        self.emitsRateLimit = emitsRateLimit
    }

    var fetchCount: Int { lock.withLock { storedRequestDates.count } }
    var requestDates: [Date] { lock.withLock { storedRequestDates } }
    var issuedRetryAt: Date? { lock.withLock { storedIssuedRetryAt } }

    func fetchViewer() async throws -> GitHubAccount { GitHubAccount(login: login) }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        let count = lock.withLock { () -> Int in
            storedRequestDates.append(Date())
            return storedRequestDates.count
        }
        if emitsRateLimit, count == 2 {
            let issued = retryDelay.map { Date().addingTimeInterval($0) } ?? retryAt
            lock.withLock { storedIssuedRetryAt = issued }
            throw GitHubReadError.rateLimited(retryAt: issued)
        }
        return result
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: accountLogin)
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }
}

private final class AtomicRateLimitTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let retryAfter: TimeInterval
    private var storedGraphQLRequestDates: [Date] = []

    init(retryAfter: TimeInterval) {
        self.retryAfter = retryAfter
    }

    var graphQLRequestDates: [Date] { lock.withLock { storedGraphQLRequestDates } }

    func response(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/user" {
            return response(Self.json(["login": "rw"]), request)
        }
        if request.url?.path == "/user/repos" {
            return response(Self.json([]), request)
        }
        guard request.url?.path == "/graphql" else {
            return response(Self.json(["message": "unexpected"]), request, status: 404)
        }
        let requestNumber = lock.withLock { () -> Int in
            storedGraphQLRequestDates.append(Date())
            return storedGraphQLRequestDates.count
        }
        if requestNumber == 1 {
            return response(
                Self.json(["errors": [["message": "exhausted", "type": "RATE_LIMITED"]]]),
                request,
                headers: ["Retry-After": String(retryAfter)]
            )
        }
        let query = Self.graphQLQuery(request)
        if query.contains("DiscoveryBounds") {
            var data: [String: Any] = [:]
            for lane in GitHubDiscoveryLane.allCases {
                data["\(lane.rawValue)Oldest"] = ["nodes": []]
                data["\(lane.rawValue)Newest"] = ["nodes": []]
            }
            return response(Self.json(["data": data]), request)
        }
        if query.contains("DiscoverPullRequests") {
            var data: [String: Any] = [:]
            for lane in GitHubDiscoveryLane.allCases {
                data[lane.rawValue] = [
                    "issueCount": 0,
                    "nodes": [],
                    "pageInfo": [
                        "startCursor": NSNull(),
                        "endCursor": NSNull(),
                        "hasPreviousPage": false,
                        "hasNextPage": false
                    ]
                ]
            }
            return response(Self.json(["data": data]), request)
        }
        return response(Self.json(["message": "unexpected query"]), request, status: 500)
    }

    private func response(
        _ data: Data,
        _ request: URLRequest,
        status: Int = 200,
        headers: [String: String]? = nil
    ) -> (Data, HTTPURLResponse) {
        (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }

    private static func graphQLQuery(_ request: URLRequest) -> String {
        guard let body = requestBody(request),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ""
        }
        return object["query"] as? String ?? ""
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private final class AtomicRateLimitURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
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
    ],
    reviews: [PullRequestReview] = []
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
        reviewCount: reviews.count,
        recentReviews: reviews,
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

private func makeSyncState(_ pullRequest: PullRequest) -> PullRequestSyncState {
    let account = GitHubAccount(login: "rw")
    return PullRequestSyncState(
        account: account,
        dashboard: DashboardState(
            pullRequests: [pullRequest],
            events: [],
            syncedAt: Date(timeIntervalSince1970: 10),
            source: .github,
            account: account,
            authStatus: .signedIn
        ),
        processedActivityByPullRequestID: [
            pullRequest.id: ProcessedPullRequestActivity(
                pullRequestID: pullRequest.id,
                commentIDs: Set(pullRequest.recentCommentActivities.map(\.id))
            )
        ]
    )
}
