import Foundation

public final class SyncEngine {
    private let source: PullRequestSource
    private let loginProvider: () async throws -> String
    private let accountProvider: () async throws -> GitHubAccount?
    private let authStatusProvider: () -> AuthStatus
    private var preferences: NotificationPreferences
    private let sourcePreferencesProvider: () -> SourcePreferences
    private let snapshotSeedProvider: (String) -> [PullRequest]
    private let snapshotCacheDidUpdate: (PullRequestSnapshotCache) -> Void
    private var snapshots: [String: PullRequest] = [:]
    public private(set) var lastRefreshWarning: String?

    public init(
        source: PullRequestSource,
        preferences: NotificationPreferences = .defaults,
        loginProvider: @escaping () async throws -> String,
        accountProvider: @escaping () async throws -> GitHubAccount? = { nil },
        authStatusProvider: @escaping () -> AuthStatus = { .signedOut },
        sourcePreferencesProvider: @escaping () -> SourcePreferences = { .defaults },
        initialPullRequests: [PullRequest] = [],
        snapshotSeedProvider: @escaping (String) -> [PullRequest] = { _ in [] },
        snapshotCacheDidUpdate: @escaping (PullRequestSnapshotCache) -> Void = { _ in }
    ) {
        self.source = source
        self.preferences = preferences
        self.loginProvider = loginProvider
        self.accountProvider = accountProvider
        self.authStatusProvider = authStatusProvider
        self.sourcePreferencesProvider = sourcePreferencesProvider
        self.snapshotSeedProvider = snapshotSeedProvider
        self.snapshotCacheDidUpdate = snapshotCacheDidUpdate
        self.snapshots = Dictionary(uniqueKeysWithValues: initialPullRequests.map { ($0.id, $0) })
    }

    public func updatePreferences(_ preferences: NotificationPreferences) {
        self.preferences = preferences
    }

    public func sync() async throws -> DashboardState {
        let login = try await loginProvider()
        if snapshots.isEmpty {
            snapshots = Dictionary(uniqueKeysWithValues: snapshotSeedProvider(login).map { ($0.id, $0) })
        }
        let result = try await source.fetchPullRequests(
            login: login,
            previousPullRequests: Array(snapshots.values)
        )
        let pullRequests = result.pullRequests
        lastRefreshWarning = result.refreshWarning
        let sourcePreferences = sourcePreferencesProvider()
        var events: [PullRequestEvent] = []

        for current in pullRequests {
            let detected = PRActivityDetector.detect(previous: snapshots[current.id], current: current)
            let allowedEvents = PRActivityDetector
                .filter(detected, preferences: preferences, pullRequest: current)
                .filter { _ in sourcePreferences.allowsNotifications(for: current.repo) }
            events.append(contentsOf: allowedEvents)
            snapshots[current.id] = current
        }

        let syncedAt = Date()
        let account = try await accountProvider() ?? GitHubAccount(login: login)
        let state = DashboardState(
            pullRequests: pullRequests,
            events: events,
            syncedAt: syncedAt,
            source: source.sourceKind,
            account: account,
            authStatus: authStatusProvider()
        )
        snapshotCacheDidUpdate(PullRequestSnapshotCache(
            pullRequests: pullRequests,
            account: account,
            fetchedAt: syncedAt,
            source: source.sourceKind
        ))
        return state
    }
}
