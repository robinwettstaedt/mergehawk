import Foundation

public final class SyncEngine {
    private let source: CompletePullRequestFetching
    private let loginProvider: () async throws -> String
    private let accountProvider: () async throws -> GitHubAccount?
    private let now: () -> Date

    public init(
        source: CompletePullRequestFetching,
        loginProvider: @escaping () async throws -> String,
        accountProvider: @escaping () async throws -> GitHubAccount? = { nil },
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.loginProvider = loginProvider
        self.accountProvider = accountProvider
        self.now = now
    }

    public func prepare(
        previousState: PullRequestSyncState?,
        fetchResult: CompletePullRequestFetchResult
    ) async throws -> PreparedPullRequestRefresh {
        try await prepare(
            previousState: previousState,
            fetchResult: fetchResult,
            login: try await loginProvider()
        )
    }

    public func prepare(previousState: PullRequestSyncState?) async throws -> PreparedPullRequestRefresh {
        let login = try await loginProvider()
        let fetchResult = try await source.fetchCompletePullRequests(
            login: login,
            previousState: previousState
        )
        return try await prepare(previousState: previousState, fetchResult: fetchResult, login: login)
    }

    /// Identity always comes from the login the fetch ran as, so another account's state is never trusted.
    private func prepare(
        previousState: PullRequestSyncState?,
        fetchResult: CompletePullRequestFetchResult,
        login: String
    ) async throws -> PreparedPullRequestRefresh {
        let account = [try await accountProvider(), previousState?.account]
            .compactMap { $0 }
            .first { $0.login.caseInsensitiveCompare(login) == .orderedSame }
            ?? GitHubAccount(login: login)
        let trustedPrevious = previousState?.trusted(for: account.login)
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
            processed[current.id] = PRActivityDetector.processedActivity(for: current)
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
            repositoryIsArchived: current.repositoryIsArchived,
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
