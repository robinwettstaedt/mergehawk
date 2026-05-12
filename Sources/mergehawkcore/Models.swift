import Foundation

public enum CIState: String, Codable, Equatable, Sendable {
    case passing
    case failing
    case pending
    case unknown
}

public enum ReviewDecision: String, Codable, Equatable, Sendable {
    case approved
    case changesRequested = "changes_requested"
    case reviewRequired = "review_required"
    case unknown
}

public enum MergeableState: String, Codable, Equatable, Sendable {
    case mergeable
    case conflicting
    case unknown
}

public struct PullRequest: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let number: Int
    public let url: URL
    public let repo: String
    public let ciState: CIState
    public let reviewDecision: ReviewDecision
    public let commentCount: Int
    public let reviewCount: Int
    public let isMine: Bool
    public let author: String
    public let mergeable: MergeableState
    public let draft: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        title: String,
        number: Int,
        url: URL,
        repo: String,
        ciState: CIState,
        reviewDecision: ReviewDecision,
        commentCount: Int,
        reviewCount: Int,
        isMine: Bool,
        author: String,
        mergeable: MergeableState,
        draft: Bool,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.title = title
        self.number = number
        self.url = url
        self.repo = repo
        self.ciState = ciState
        self.reviewDecision = reviewDecision
        self.commentCount = commentCount
        self.reviewCount = reviewCount
        self.isMine = isMine
        self.author = author
        self.mergeable = mergeable
        self.draft = draft
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum PullRequestEventType: String, Codable, Equatable, Sendable {
    case newComment = "new_comment"
    case newReview = "new_review"
    case ciFailed = "ci_failed"
    case changesRequested = "changes_requested"
}

public struct PullRequestEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(type.rawValue)-\(prId)-\(count ?? 0)" }
    public let type: PullRequestEventType
    public let prId: String
    public let count: Int?

    public init(type: PullRequestEventType, prId: String, count: Int? = nil) {
        self.type = type
        self.prId = prId
        self.count = count
    }
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var newComment: Bool
    public var newReview: Bool
    public var ciFailed: Bool
    public var changesRequested: Bool

    public static let defaults = NotificationPreferences(
        newComment: true,
        newReview: true,
        ciFailed: true,
        changesRequested: true
    )

    public init(newComment: Bool, newReview: Bool, ciFailed: Bool, changesRequested: Bool) {
        self.newComment = newComment
        self.newReview = newReview
        self.ciFailed = ciFailed
        self.changesRequested = changesRequested
    }

    public func allows(_ type: PullRequestEventType) -> Bool {
        switch type {
        case .newComment: newComment
        case .newReview: newReview
        case .ciFailed: ciFailed
        case .changesRequested: changesRequested
        }
    }
}

public enum DashboardSource: String, Codable, Equatable, Sendable {
    case none
    case mock
    case github
}

public struct GitHubAccount: Codable, Equatable, Sendable {
    public let login: String
    public let avatarUrl: URL?
    public let profileUrl: URL?

    public init(login: String, avatarUrl: URL? = nil, profileUrl: URL? = nil) {
        self.login = login
        self.avatarUrl = avatarUrl
        self.profileUrl = profileUrl
    }
}

public enum AuthStatus: String, Codable, Equatable, Sendable {
    case signedOut = "signed_out"
    case signedIn = "signed_in"
}

public struct DashboardState: Codable, Equatable, Sendable {
    public var pullRequests: [PullRequest]
    public var events: [PullRequestEvent]
    public var syncedAt: Date?
    public var source: DashboardSource
    public var account: GitHubAccount?
    public var authStatus: AuthStatus

    public static let empty = DashboardState(
        pullRequests: [],
        events: [],
        syncedAt: nil,
        source: .none,
        account: nil,
        authStatus: .signedOut
    )

    public init(
        pullRequests: [PullRequest],
        events: [PullRequestEvent],
        syncedAt: Date?,
        source: DashboardSource,
        account: GitHubAccount?,
        authStatus: AuthStatus
    ) {
        self.pullRequests = pullRequests
        self.events = events
        self.syncedAt = syncedAt
        self.source = source
        self.account = account
        self.authStatus = authStatus
    }
}
