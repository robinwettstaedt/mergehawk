import Foundation

public final class SyncEngine {
    private let source: PullRequestSource
    private let loginProvider: () async throws -> String
    private let accountProvider: () async throws -> GitHubAccount?
    private let authStatusProvider: () -> AuthStatus
    private var preferences: NotificationPreferences
    private let sourcePreferencesProvider: () -> SourcePreferences
    private var snapshots: [String: PullRequest] = [:]

    public init(
        source: PullRequestSource,
        preferences: NotificationPreferences = .defaults,
        loginProvider: @escaping () async throws -> String,
        accountProvider: @escaping () async throws -> GitHubAccount? = { nil },
        authStatusProvider: @escaping () -> AuthStatus = { .signedOut },
        sourcePreferencesProvider: @escaping () -> SourcePreferences = { .defaults }
    ) {
        self.source = source
        self.preferences = preferences
        self.loginProvider = loginProvider
        self.accountProvider = accountProvider
        self.authStatusProvider = authStatusProvider
        self.sourcePreferencesProvider = sourcePreferencesProvider
    }

    public func updatePreferences(_ preferences: NotificationPreferences) {
        self.preferences = preferences
    }

    public func sync() async throws -> DashboardState {
        let login = try await loginProvider()
        let pullRequests = try await source.fetchPullRequests(login: login)
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

        return DashboardState(
            pullRequests: pullRequests,
            events: events,
            syncedAt: Date(),
            source: source.sourceKind,
            account: try await accountProvider() ?? GitHubAccount(login: login),
            authStatus: authStatusProvider()
        )
    }
}
