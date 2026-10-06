import Foundation

public struct ProcessedPullRequestActivity: Codable, Equatable, Sendable {
    public let pullRequestID: String
    public var commentIDs: Set<String>
    public var submittedReviewIDs: Set<String>
    /// Activity at or before this time also counts as processed. Only an imported legacy snapshot sets it,
    /// because that snapshot kept just the most recent comments and reviews.
    public var processedThrough: Date?
    /// Published comments and comment-only review summaries that mentioned the viewer at the last refresh.
    /// Nil means the record predates mention observation, so current mentions become a quiet baseline.
    public var mentioningActivityIDs: Set<String>?

    public init(
        pullRequestID: String,
        commentIDs: Set<String> = [],
        submittedReviewIDs: Set<String> = [],
        processedThrough: Date? = nil,
        mentioningActivityIDs: Set<String>? = nil
    ) {
        self.pullRequestID = pullRequestID
        self.commentIDs = commentIDs
        self.submittedReviewIDs = submittedReviewIDs
        self.processedThrough = processedThrough
        self.mentioningActivityIDs = mentioningActivityIDs
    }

    /// The legacy cutoff compares publication time, so a comment drafted before it but published after stays new.
    func includesComment(_ comment: PullRequestCommentActivity) -> Bool {
        commentIDs.contains(comment.id)
            || processedThrough.map { cutoff in comment.publishedAt.map { $0 <= cutoff } == true } == true
    }

    func includesReview(_ review: PullRequestReview) -> Bool {
        submittedReviewIDs.contains(review.id) || processedThrough.map { review.submittedAt <= $0 } == true
    }
}

public struct PullRequestSyncState: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public var account: GitHubAccount
    public var dashboard: DashboardState
    public var processedActivityByPullRequestID: [String: ProcessedPullRequestActivity]
    public var notificationHistory: [PullRequestNotification]

    public init(
        formatVersion: Int = PullRequestSyncState.currentFormatVersion,
        account: GitHubAccount,
        dashboard: DashboardState,
        processedActivityByPullRequestID: [String: ProcessedPullRequestActivity] = [:],
        notificationHistory: [PullRequestNotification] = []
    ) {
        self.formatVersion = formatVersion
        self.account = account
        self.dashboard = dashboard
        self.processedActivityByPullRequestID = processedActivityByPullRequestID
        self.notificationHistory = notificationHistory
    }

    /// Returns this state only when it belongs to `login`, so another account's history is never reused.
    public func trusted(for login: String) -> PullRequestSyncState? {
        account.login.caseInsensitiveCompare(login) == .orderedSame ? self : nil
    }
}

public struct CompletePullRequestFetchResult: Equatable, Sendable {
    public let activePullRequests: [PullRequest]
    public let retiringPullRequests: [PullRequest]
    public let quietlyRetiredPullRequestIDs: Set<String>
    public let viewerTeams: [ViewerTeam]
    public let stacks: [PullRequestStack]

    public init(
        activePullRequests: [PullRequest],
        retiringPullRequests: [PullRequest] = [],
        quietlyRetiredPullRequestIDs: Set<String> = [],
        viewerTeams: [ViewerTeam] = [],
        stacks: [PullRequestStack] = []
    ) {
        self.activePullRequests = activePullRequests
        self.retiringPullRequests = retiringPullRequests
        self.quietlyRetiredPullRequestIDs = quietlyRetiredPullRequestIDs
        self.viewerTeams = viewerTeams
        self.stacks = stacks
    }
}

/// The provider read of one complete PR refresh, before detection runs.
public struct FetchedPullRequestRefresh: Equatable, Sendable {
    public let login: String
    public let account: GitHubAccount
    public let fetchResult: CompletePullRequestFetchResult

    public init(login: String, account: GitHubAccount, fetchResult: CompletePullRequestFetchResult) {
        self.login = login
        self.account = account
        self.fetchResult = fetchResult
    }
}

public struct PreparedPullRequestEvent: Equatable, Sendable {
    public let event: PullRequestEvent
    public let filteringContext: PullRequest

    public init(event: PullRequestEvent, filteringContext: PullRequest) {
        self.event = event
        self.filteringContext = filteringContext
    }
}

public struct PreparedPullRequestRefresh: Equatable, Sendable {
    public let account: GitHubAccount
    public let source: DashboardSource
    public let activePullRequests: [PullRequest]
    public let retiringPullRequests: [PullRequest]
    public let processedActivityByPullRequestID: [String: ProcessedPullRequestActivity]
    public let events: [PreparedPullRequestEvent]
    public let viewerTeams: [ViewerTeam]
    public let stacks: [PullRequestStack]
    public let syncedAt: Date

    public init(
        account: GitHubAccount,
        source: DashboardSource,
        activePullRequests: [PullRequest],
        retiringPullRequests: [PullRequest],
        processedActivityByPullRequestID: [String: ProcessedPullRequestActivity],
        events: [PreparedPullRequestEvent],
        viewerTeams: [ViewerTeam],
        stacks: [PullRequestStack],
        syncedAt: Date
    ) {
        self.account = account
        self.source = source
        self.activePullRequests = activePullRequests
        self.retiringPullRequests = retiringPullRequests
        self.processedActivityByPullRequestID = processedActivityByPullRequestID
        self.events = events
        self.viewerTeams = viewerTeams
        self.stacks = stacks
        self.syncedAt = syncedAt
    }
}

public protocol CompletePullRequestFetching: AnyObject {
    var sourceKind: DashboardSource { get }
    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult
}
