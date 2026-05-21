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

public enum ReviewRequestKind: String, Codable, Equatable, Sendable {
    case none
    case direct
    case team
    case directAndTeam = "direct_and_team"

    public var includesDirect: Bool {
        switch self {
        case .direct, .directAndTeam:
            true
        case .none, .team:
            false
        }
    }

    public var includesTeam: Bool {
        switch self {
        case .team, .directAndTeam:
            true
        case .none, .direct:
            false
        }
    }
}

public enum MergeableState: String, Codable, Equatable, Sendable {
    case mergeable
    case conflicting
    case unknown
}

public enum PullRequestReviewState: String, Codable, Equatable, Sendable {
    case approved
    case changesRequested = "changes_requested"
    case commented
}

public struct PullRequestReview: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let state: PullRequestReviewState
    public let submittedAt: Date

    public init(id: String, state: PullRequestReviewState, submittedAt: Date) {
        self.id = id
        self.state = state
        self.submittedAt = submittedAt
    }
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
    public let commentActivityCount: Int
    public let reviewCount: Int
    public let recentReviews: [PullRequestReview]
    public let reviewRequestKind: ReviewRequestKind
    public let isMine: Bool
    public let author: String
    public let headRefName: String
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
        commentActivityCount: Int? = nil,
        reviewCount: Int,
        recentReviews: [PullRequestReview] = [],
        reviewRequestKind: ReviewRequestKind = .none,
        isMine: Bool,
        author: String,
        headRefName: String = "",
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
        self.commentActivityCount = commentActivityCount ?? commentCount
        self.reviewCount = reviewCount
        self.recentReviews = recentReviews
        self.reviewRequestKind = reviewRequestKind
        self.isMine = isMine
        self.author = author
        self.headRefName = headRefName
        self.mergeable = mergeable
        self.draft = draft
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RepositoryIdentity: Codable, Equatable, Hashable, Comparable, Sendable {
    public let owner: String
    public let name: String

    public var nameWithOwner: String {
        "\(owner)/\(name)"
    }

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public init?(nameWithOwner: String) {
        let parts = nameWithOwner.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            return nil
        }
        self.owner = String(parts[0])
        self.name = String(parts[1])
    }

    public static func < (lhs: RepositoryIdentity, rhs: RepositoryIdentity) -> Bool {
        if lhs.owner.localizedCaseInsensitiveCompare(rhs.owner) != .orderedSame {
            return lhs.owner.localizedCaseInsensitiveCompare(rhs.owner) == .orderedAscending
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

public struct RepositorySource: Identifiable, Codable, Equatable, Comparable, Sendable {
    public var id: String { identity.nameWithOwner }
    public let identity: RepositoryIdentity

    public init(identity: RepositoryIdentity) {
        self.identity = identity
    }

    public init(owner: String, name: String) {
        self.identity = RepositoryIdentity(owner: owner, name: name)
    }

    public static func < (lhs: RepositorySource, rhs: RepositorySource) -> Bool {
        lhs.identity < rhs.identity
    }
}

public struct OwnerSource: Identifiable, Codable, Equatable, Comparable, Sendable {
    public var id: String { owner }
    public let owner: String
    public let repositories: [RepositorySource]

    public init(owner: String, repositories: [RepositorySource]) {
        self.owner = owner
        self.repositories = repositories.sorted()
    }

    public static func < (lhs: OwnerSource, rhs: OwnerSource) -> Bool {
        lhs.owner.localizedCaseInsensitiveCompare(rhs.owner) == .orderedAscending
    }
}

public struct SourceCatalog: Codable, Equatable, Sendable {
    public var owners: [OwnerSource]

    public static let empty = SourceCatalog(owners: [])

    public init(owners: [OwnerSource]) {
        self.owners = owners.sorted()
    }

    public init(repositories: [RepositorySource], accountLogin: String? = nil) {
        var repositoriesByOwner = Dictionary(grouping: repositories, by: \.identity.owner)
        if let accountLogin, !accountLogin.isEmpty {
            repositoriesByOwner[accountLogin] = repositoriesByOwner[accountLogin] ?? []
        }
        self.init(owners: repositoriesByOwner.map { owner, repositories in
            OwnerSource(owner: owner, repositories: repositories)
        })
    }
}

public enum SourceOverride: String, Codable, CaseIterable, Equatable, Sendable {
    case inherit
    case enabled
    case disabled

    public func resolved(default defaultValue: Bool) -> Bool {
        switch self {
        case .inherit:
            defaultValue
        case .enabled:
            true
        case .disabled:
            false
        }
    }
}

public struct OwnerSourcePreferences: Codable, Equatable, Sendable {
    public var notifications: Bool
    public var myPullRequests: Bool
    public var reviewRequests: Bool

    public static let defaults = OwnerSourcePreferences(
        notifications: true,
        myPullRequests: true,
        reviewRequests: true
    )

    public init(notifications: Bool, myPullRequests: Bool, reviewRequests: Bool) {
        self.notifications = notifications
        self.myPullRequests = myPullRequests
        self.reviewRequests = reviewRequests
    }
}

public struct RepositorySourcePreferences: Codable, Equatable, Sendable {
    public var notifications: SourceOverride
    public var myPullRequests: SourceOverride
    public var reviewRequests: SourceOverride

    public static let defaults = RepositorySourcePreferences(
        notifications: .inherit,
        myPullRequests: .inherit,
        reviewRequests: .inherit
    )

    public init(
        notifications: SourceOverride,
        myPullRequests: SourceOverride,
        reviewRequests: SourceOverride
    ) {
        self.notifications = notifications
        self.myPullRequests = myPullRequests
        self.reviewRequests = reviewRequests
    }
}

public struct SourcePreferences: Codable, Equatable, Sendable {
    public var owners: [String: OwnerSourcePreferences]
    public var repositories: [String: RepositorySourcePreferences]

    public static let defaults = SourcePreferences(owners: [:], repositories: [:])

    public init(
        owners: [String: OwnerSourcePreferences],
        repositories: [String: RepositorySourcePreferences]
    ) {
        self.owners = owners
        self.repositories = repositories
    }

    public func allowsNotifications(for repo: String) -> Bool {
        resolved(repo: repo).notifications
    }

    public func allowsMyPullRequests(for repo: String) -> Bool {
        resolved(repo: repo).myPullRequests
    }

    public func allowsReviewRequests(for repo: String) -> Bool {
        resolved(repo: repo).reviewRequests
    }

    public func ownerPreferences(for owner: String) -> OwnerSourcePreferences {
        owners[owner] ?? .defaults
    }

    public func repositoryPreferences(for repo: String) -> RepositorySourcePreferences {
        repositories[repo] ?? .defaults
    }

    private func resolved(repo: String) -> OwnerSourcePreferences {
        guard let identity = RepositoryIdentity(nameWithOwner: repo) else {
            return .defaults
        }
        let ownerPreference = ownerPreferences(for: identity.owner)
        let repoPreference = repositoryPreferences(for: identity.nameWithOwner)
        return OwnerSourcePreferences(
            notifications: repoPreference.notifications.resolved(default: ownerPreference.notifications),
            myPullRequests: repoPreference.myPullRequests.resolved(default: ownerPreference.myPullRequests),
            reviewRequests: repoPreference.reviewRequests.resolved(default: ownerPreference.reviewRequests)
        )
    }
}

public enum PullRequestEventType: String, Codable, Equatable, Sendable {
    case newComment = "new_comment"
    case reviewApproved = "review_approved"
    case reviewCommented = "review_commented"
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

public struct PullRequestNotification: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let eventType: PullRequestEventType
    public let count: Int?
    public let prId: String
    public let prTitle: String
    public let prNumber: Int
    public let repo: String
    public let url: URL
    public let createdAt: Date
    public let prUpdatedAt: Date
    public var read: Bool

    public init(
        id: String = UUID().uuidString,
        event: PullRequestEvent,
        pullRequest: PullRequest,
        createdAt: Date = Date(),
        read: Bool = false
    ) {
        self.id = id
        self.eventType = event.type
        self.count = event.count
        self.prId = event.prId
        self.prTitle = pullRequest.title
        self.prNumber = pullRequest.number
        self.repo = pullRequest.repo
        self.url = pullRequest.url
        self.createdAt = createdAt
        self.prUpdatedAt = pullRequest.updatedAt
        self.read = read
    }
}

public struct GitHubInboxNotification: Identifiable, Codable, Equatable, Sendable {
    public var id: String { threadId }
    public let threadId: String
    public let repo: String
    public let subjectTitle: String
    public let subjectType: String
    public let reason: String
    public var unread: Bool
    public let updatedAt: Date
    public let threadURL: URL
    public let webURL: URL

    public init(
        threadId: String,
        repo: String,
        subjectTitle: String,
        subjectType: String,
        reason: String,
        unread: Bool,
        updatedAt: Date,
        threadURL: URL,
        webURL: URL
    ) {
        self.threadId = threadId
        self.repo = repo
        self.subjectTitle = subjectTitle
        self.subjectType = subjectType
        self.reason = reason
        self.unread = unread
        self.updatedAt = updatedAt
        self.threadURL = threadURL
        self.webURL = webURL
    }
}

public struct GitHubInboxSyncMetadata: Codable, Equatable, Sendable {
    public var eTag: String?
    public var lastFetchedAt: Date?
    public var pollIntervalSeconds: Int?

    public static let empty = GitHubInboxSyncMetadata(
        eTag: nil,
        lastFetchedAt: nil,
        pollIntervalSeconds: nil
    )

    public init(eTag: String?, lastFetchedAt: Date?, pollIntervalSeconds: Int?) {
        self.eTag = eTag
        self.lastFetchedAt = lastFetchedAt
        self.pollIntervalSeconds = pollIntervalSeconds
    }
}

public struct GitHubInboxFetchResult: Equatable, Sendable {
    public let notifications: [GitHubInboxNotification]
    public let metadata: GitHubInboxSyncMetadata
    public let isNotModified: Bool

    public init(
        notifications: [GitHubInboxNotification],
        metadata: GitHubInboxSyncMetadata,
        isNotModified: Bool = false
    ) {
        self.notifications = notifications
        self.metadata = metadata
        self.isNotModified = isNotModified
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
        case .reviewApproved, .reviewCommented, .newReview: newReview
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
