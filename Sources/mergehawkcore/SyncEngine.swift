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
    private let now: () -> Date
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
        snapshotCacheDidUpdate: @escaping (PullRequestSnapshotCache) -> Void = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.preferences = preferences
        self.loginProvider = loginProvider
        self.accountProvider = accountProvider
        self.authStatusProvider = authStatusProvider
        self.sourcePreferencesProvider = sourcePreferencesProvider
        self.snapshotSeedProvider = snapshotSeedProvider
        self.snapshotCacheDidUpdate = snapshotCacheDidUpdate
        self.now = now
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

    public func prepare(
        previousState: PullRequestSyncState?,
        fetchResult: CompletePullRequestFetchResult
    ) async throws -> PreparedPullRequestRefresh {
        let login = try await loginProvider()
        let account = try await accountProvider() ?? previousState?.account ?? GitHubAccount(login: login)
        let trustedPrevious = previousState?.account.login == account.login ? previousState : nil
        let previousByID = Dictionary(
            uniqueKeysWithValues: (trustedPrevious?.dashboard.pullRequests ?? []).map { ($0.id, $0) }
        )
        let activeIDs = fetchResult.activePullRequests.map(\.id)
        guard Set(activeIDs).count == activeIDs.count else {
            throw GitHubReadError.incompleteCoverage("Duplicate active PR IDs")
        }
        let retiringIDs = fetchResult.retiringPullRequests.map(\.id)
        guard Set(retiringIDs).count == retiringIDs.count,
              Set(activeIDs).isDisjoint(with: retiringIDs),
              Set(activeIDs).isDisjoint(with: fetchResult.quietlyRetiredPullRequestIDs)
        else {
            throw GitHubReadError.incompleteCoverage("Conflicting active and retired PR IDs")
        }

        var processed: [String: ProcessedPullRequestActivity] = [:]
        var events: [PreparedPullRequestEvent] = []
        for current in fetchResult.activePullRequests {
            let previousRecord = trustedPrevious?.processedActivityByPullRequestID[current.id]
            let detected = PRActivityDetector.detectTransitions(
                previous: previousByID[current.id],
                current: current
            ) + PRActivityDetector.detectProcessedPeopleActivity(
                previous: previousRecord,
                current: current
            )
            events.append(contentsOf: detected.map {
                PreparedPullRequestEvent(event: $0, filteringContext: current)
            })
            processed[current.id] = PRActivityDetector.updatedProcessedActivity(
                previous: previousRecord,
                current: current
            )
        }

        for current in fetchResult.retiringPullRequests {
            let previousRecord = trustedPrevious?.processedActivityByPullRequestID[current.id]
            let peopleEvents = PRActivityDetector.detectProcessedPeopleActivity(
                previous: previousRecord,
                current: current
            )
            let context = previousByID[current.id].map {
                Self.retirementFilteringContext(current: current, previous: $0)
            } ?? current
            events.append(contentsOf: peopleEvents.map {
                PreparedPullRequestEvent(event: $0, filteringContext: context)
            })
        }

        return PreparedPullRequestRefresh(
            account: account,
            source: source.sourceKind,
            activePullRequests: fetchResult.activePullRequests,
            retiringPullRequests: fetchResult.retiringPullRequests,
            processedActivityByPullRequestID: processed,
            events: events,
            syncedAt: now()
        )
    }

    private static func retirementFilteringContext(
        current: PullRequest,
        previous: PullRequest
    ) -> PullRequest {
        PullRequest(
            id: current.id,
            title: current.title,
            number: current.number,
            url: current.url,
            repo: current.repo,
            ciState: current.ciState,
            reviewDecision: current.reviewDecision,
            additions: current.additions,
            deletions: current.deletions,
            commentCount: current.commentCount,
            commentActivityCount: current.commentActivityCount,
            recentCommentActivities: current.recentCommentActivities,
            reviewCount: current.reviewCount,
            recentReviews: current.recentReviews,
            headRefOid: current.headRefOid,
            reviewRequestKind: previous.reviewRequestKind,
            isAssignedToViewer: previous.isAssignedToViewer,
            isMine: previous.isMine,
            author: current.author,
            authorAvatarURL: current.authorAvatarURL,
            headRefName: current.headRefName,
            mergeable: current.mergeable,
            draft: current.draft,
            createdAt: current.createdAt,
            updatedAt: current.updatedAt
        )
    }
}
