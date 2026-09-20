import Foundation

public struct ProcessedPullRequestActivity: Codable, Equatable, Sendable {
    public let pullRequestID: String
    public var commentIDs: Set<String>
    public var submittedReviewIDs: Set<String>

    public init(
        pullRequestID: String,
        commentIDs: Set<String> = [],
        submittedReviewIDs: Set<String> = []
    ) {
        self.pullRequestID = pullRequestID
        self.commentIDs = commentIDs
        self.submittedReviewIDs = submittedReviewIDs
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
}

public struct CompletePullRequestFetchResult: Equatable, Sendable {
    public let activePullRequests: [PullRequest]
    public let retiringPullRequests: [PullRequest]
    public let quietlyRetiredPullRequestIDs: Set<String>

    public init(
        activePullRequests: [PullRequest],
        retiringPullRequests: [PullRequest] = [],
        quietlyRetiredPullRequestIDs: Set<String> = []
    ) {
        self.activePullRequests = activePullRequests
        self.retiringPullRequests = retiringPullRequests
        self.quietlyRetiredPullRequestIDs = quietlyRetiredPullRequestIDs
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
    public let syncedAt: Date

    public init(
        account: GitHubAccount,
        source: DashboardSource,
        activePullRequests: [PullRequest],
        retiringPullRequests: [PullRequest],
        processedActivityByPullRequestID: [String: ProcessedPullRequestActivity],
        events: [PreparedPullRequestEvent],
        syncedAt: Date
    ) {
        self.account = account
        self.source = source
        self.activePullRequests = activePullRequests
        self.retiringPullRequests = retiringPullRequests
        self.processedActivityByPullRequestID = processedActivityByPullRequestID
        self.events = events
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
