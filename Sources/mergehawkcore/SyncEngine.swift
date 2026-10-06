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
        let login = try await loginProvider()
        return try prepare(
            previousState: previousState,
            fetched: FetchedPullRequestRefresh(
                login: login,
                account: try await resolveAccount(login: login, previousState: previousState),
                fetchResult: fetchResult
            ),
            turnedOffTeamIDs: []
        )
    }

    public func prepare(previousState: PullRequestSyncState?) async throws -> PreparedPullRequestRefresh {
        try prepare(
            previousState: previousState,
            fetched: try await fetchRefresh(previousState: previousState),
            turnedOffTeamIDs: []
        )
    }

    /// The asynchronous half of a refresh: everything that reads the provider or the account.
    public func fetchRefresh(previousState: PullRequestSyncState?) async throws -> FetchedPullRequestRefresh {
        let login = try await loginProvider()
        let fetchResult = try await source.fetchCompletePullRequests(
            login: login,
            previousState: previousState
        )
        return FetchedPullRequestRefresh(
            login: login,
            account: try await resolveAccount(login: login, previousState: previousState),
            fetchResult: fetchResult
        )
    }

    /// Identity always comes from the login the fetch ran as, so another account's state is never trusted.
    private func resolveAccount(login: String, previousState: PullRequestSyncState?) async throws -> GitHubAccount {
        [try await accountProvider(), previousState?.account]
            .compactMap { $0 }
            .first { $0.login.caseInsensitiveCompare(login) == .orderedSame }
            ?? GitHubAccount(login: login)
    }

    /// The synchronous half of a refresh. Previous and current PRs are both counted with the current team
    /// membership and turned-off teams, so a settings or membership change alone never looks like a new request.
    public func prepare(
        previousState: PullRequestSyncState?,
        fetched: FetchedPullRequestRefresh,
        turnedOffTeamIDs: Set<String>
    ) throws -> PreparedPullRequestRefresh {
        let account = fetched.account
        let fetchResult = fetched.fetchResult
        let counting = TeamReviewCounting(viewerTeams: fetchResult.viewerTeams, turnedOffTeamIDs: turnedOffTeamIDs)
        let trustedPrevious = previousState?.trusted(for: account.login)
        let previousByID = Dictionary(
            uniqueKeysWithValues: (trustedPrevious?.dashboard.pullRequests ?? []).map { ($0.id, counting.applied(to: $0)) }
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
            let counted = counting.applied(to: current)
            let previousRecord = trustedPrevious?.processedActivityByPullRequestID[current.id]
            // Without a trusted previous state this refresh is the baseline, so no transition is new.
            let transitions = trustedPrevious == nil ? [] : PRActivityDetector.detectTransitions(
                previous: previousByID[current.id],
                current: counted
            )
            let detected = transitions + PRActivityDetector.detectProcessedPeopleActivity(
                previous: previousRecord,
                current: current
            )
            events.append(contentsOf: detected.map {
                PreparedPullRequestEvent(event: $0, filteringContext: counted)
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
            } ?? counting.applied(to: current)
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
            viewerTeams: fetchResult.viewerTeams,
            stacks: fetchResult.stacks,
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
            requestedTeams: previous.requestedTeams,
            isAssignedToViewer: previous.isAssignedToViewer,
            isMine: previous.isMine,
            author: current.author,
            authorAvatarURL: current.authorAvatarURL,
            headRefName: current.headRefName,
            mergeable: current.mergeable,
            draft: current.draft,
            createdAt: current.createdAt,
            updatedAt: current.updatedAt,
            stackID: current.stackID
        )
    }
}
