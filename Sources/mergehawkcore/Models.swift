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
    public let author: String?
    public let viewerDidAuthor: Bool

    public init(
        id: String,
        state: PullRequestReviewState,
        submittedAt: Date,
        author: String? = nil,
        viewerDidAuthor: Bool = false
    ) {
        self.id = id
        self.state = state
        self.submittedAt = submittedAt
        self.author = author
        self.viewerDidAuthor = viewerDidAuthor
    }
}

public struct PullRequestCommentActivity: Identifiable, Codable, Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case pullRequest
        case reviewThread = "review_thread"
    }

    public let id: String
    public let author: String?
    public let viewerDidAuthor: Bool
    public let createdAt: Date
    public let source: Source
    public let reviewId: String?

    public init(
        id: String,
        author: String? = nil,
        viewerDidAuthor: Bool = false,
        createdAt: Date,
        source: Source,
        reviewId: String? = nil
    ) {
        self.id = id
        self.author = author
        self.viewerDidAuthor = viewerDidAuthor
        self.createdAt = createdAt
        self.source = source
        self.reviewId = reviewId
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
    public let recentCommentActivities: [PullRequestCommentActivity]
    public let reviewCount: Int
    public let recentReviews: [PullRequestReview]
    public let reviewRequestKind: ReviewRequestKind
    public let isAssignedToViewer: Bool
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
        recentCommentActivities: [PullRequestCommentActivity] = [],
        reviewCount: Int,
        recentReviews: [PullRequestReview] = [],
        reviewRequestKind: ReviewRequestKind = .none,
        isAssignedToViewer: Bool = false,
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
        self.recentCommentActivities = recentCommentActivities
        self.reviewCount = reviewCount
        self.recentReviews = recentReviews
        self.reviewRequestKind = reviewRequestKind
        self.isAssignedToViewer = isAssignedToViewer
        self.isMine = isMine
        self.author = author
        self.headRefName = headRefName
        self.mergeable = mergeable
        self.draft = draft
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PullRequestSnapshotCache: Codable, Equatable, Sendable {
    public var pullRequests: [PullRequest]
    public var account: GitHubAccount?
    public var fetchedAt: Date?
    public var source: DashboardSource

    public static let empty = PullRequestSnapshotCache(
        pullRequests: [],
        account: nil,
        fetchedAt: nil,
        source: .none
    )

    public init(
        pullRequests: [PullRequest],
        account: GitHubAccount?,
        fetchedAt: Date?,
        source: DashboardSource
    ) {
        self.pullRequests = pullRequests
        self.account = account
        self.fetchedAt = fetchedAt
        self.source = source
    }
}

public struct PullRequestFetchResult: Equatable, Sendable {
    public let pullRequests: [PullRequest]
    public let refreshWarning: String?

    public init(pullRequests: [PullRequest], refreshWarning: String? = nil) {
        self.pullRequests = pullRequests
        self.refreshWarning = refreshWarning
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
    case relationshipAdded = "relationship_added"
}

public enum PullRequestNotificationRelationship: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case authored
    case assigned
    case directReviewRequest = "direct_review_request"
    case teamReviewRequest = "team_review_request"
}

public struct PullRequestEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: String { activityId ?? "\(type.rawValue)-\(prId)-\(count ?? 0)" }
    public let type: PullRequestEventType
    public let prId: String
    public let count: Int?
    public let actorLogin: String?
    public let activityId: String?
    public let happenedAt: Date?
    public let relationshipChanges: Set<PullRequestNotificationRelationship>

    public init(
        type: PullRequestEventType,
        prId: String,
        count: Int? = nil,
        actorLogin: String? = nil,
        activityId: String? = nil,
        happenedAt: Date? = nil,
        relationshipChanges: Set<PullRequestNotificationRelationship> = []
    ) {
        self.type = type
        self.prId = prId
        self.count = count
        self.actorLogin = actorLogin
        self.activityId = activityId
        self.happenedAt = happenedAt
        self.relationshipChanges = relationshipChanges
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
    public let actorLogin: String?
    public let activityId: String?
    public let relationshipChanges: Set<PullRequestNotificationRelationship>
    public let createdAt: Date
    public let prUpdatedAt: Date
    public var read: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case eventType
        case count
        case prId
        case prTitle
        case prNumber
        case repo
        case url
        case actorLogin
        case activityId
        case relationshipChanges
        case createdAt
        case prUpdatedAt
        case read
    }

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
        self.actorLogin = event.actorLogin
        self.activityId = event.activityId
        self.relationshipChanges = event.relationshipChanges
        self.createdAt = createdAt
        self.prUpdatedAt = pullRequest.updatedAt
        self.read = read
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.eventType = try container.decode(PullRequestEventType.self, forKey: .eventType)
        self.count = try container.decodeIfPresent(Int.self, forKey: .count)
        self.prId = try container.decode(String.self, forKey: .prId)
        self.prTitle = try container.decode(String.self, forKey: .prTitle)
        self.prNumber = try container.decode(Int.self, forKey: .prNumber)
        self.repo = try container.decode(String.self, forKey: .repo)
        self.url = try container.decode(URL.self, forKey: .url)
        self.actorLogin = try container.decodeIfPresent(String.self, forKey: .actorLogin)
        self.activityId = try container.decodeIfPresent(String.self, forKey: .activityId)
        self.relationshipChanges = try container.decodeIfPresent(
            Set<PullRequestNotificationRelationship>.self,
            forKey: .relationshipChanges
        ) ?? []
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.prUpdatedAt = try container.decode(Date.self, forKey: .prUpdatedAt)
        self.read = try container.decode(Bool.self, forKey: .read)
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

public enum PullRequestNotificationActivity: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case comments
    case reviewActivity = "review_activity"
    case ciFailures = "ci_failures"
    case relationshipChanges = "relationship_changes"

    public init(eventType: PullRequestEventType) {
        switch eventType {
        case .newComment:
            self = .comments
        case .reviewApproved, .reviewCommented, .newReview, .changesRequested:
            self = .reviewActivity
        case .ciFailed:
            self = .ciFailures
        case .relationshipAdded:
            self = .relationshipChanges
        }
    }
}

public struct PullRequestNotificationActivityPreferences: Codable, Equatable, Sendable {
    public var comments: Bool
    public var reviewActivity: Bool
    public var ciFailures: Bool
    public var relationshipChanges: Bool

    public static let authoredDefaults = PullRequestNotificationActivityPreferences(
        comments: true,
        reviewActivity: true,
        ciFailures: true,
        relationshipChanges: false
    )
    public static let enabled = PullRequestNotificationActivityPreferences(
        comments: true,
        reviewActivity: true,
        ciFailures: true,
        relationshipChanges: true
    )
    public static let disabled = PullRequestNotificationActivityPreferences(
        comments: false,
        reviewActivity: false,
        ciFailures: false,
        relationshipChanges: false
    )
    public static let relationshipChangesOnly = PullRequestNotificationActivityPreferences(
        comments: false,
        reviewActivity: false,
        ciFailures: false,
        relationshipChanges: true
    )

    enum CodingKeys: String, CodingKey {
        case comments
        case reviewActivity
        case ciFailures
        case relationshipChanges
    }

    public init(
        comments: Bool,
        reviewActivity: Bool,
        ciFailures: Bool,
        relationshipChanges: Bool = false
    ) {
        self.comments = comments
        self.reviewActivity = reviewActivity
        self.ciFailures = ciFailures
        self.relationshipChanges = relationshipChanges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.comments = try container.decode(Bool.self, forKey: .comments)
        self.reviewActivity = try container.decode(Bool.self, forKey: .reviewActivity)
        self.ciFailures = try container.decode(Bool.self, forKey: .ciFailures)
        self.relationshipChanges = try container.decodeIfPresent(Bool.self, forKey: .relationshipChanges) ?? false
    }

    public func allows(_ activity: PullRequestNotificationActivity) -> Bool {
        switch activity {
        case .comments:
            comments
        case .reviewActivity:
            reviewActivity
        case .ciFailures:
            ciFailures
        case .relationshipChanges:
            relationshipChanges
        }
    }
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var authored: PullRequestNotificationActivityPreferences
    public var assigned: PullRequestNotificationActivityPreferences
    public var directReviewRequests: PullRequestNotificationActivityPreferences
    public var teamReviewRequests: PullRequestNotificationActivityPreferences

    public static let defaults = NotificationPreferences(
        authored: .authoredDefaults,
        assigned: .relationshipChangesOnly,
        directReviewRequests: .relationshipChangesOnly,
        teamReviewRequests: .relationshipChangesOnly
    )

    public init(
        authored: PullRequestNotificationActivityPreferences,
        assigned: PullRequestNotificationActivityPreferences,
        directReviewRequests: PullRequestNotificationActivityPreferences,
        teamReviewRequests: PullRequestNotificationActivityPreferences
    ) {
        self.authored = authored
        self.assigned = assigned
        self.directReviewRequests = directReviewRequests
        self.teamReviewRequests = teamReviewRequests
    }

    public func preferences(for relationship: PullRequestNotificationRelationship) -> PullRequestNotificationActivityPreferences {
        switch relationship {
        case .authored:
            authored
        case .assigned:
            assigned
        case .directReviewRequest:
            directReviewRequests
        case .teamReviewRequest:
            teamReviewRequests
        }
    }

    public mutating func set(
        _ preferences: PullRequestNotificationActivityPreferences,
        for relationship: PullRequestNotificationRelationship
    ) {
        switch relationship {
        case .authored:
            authored = preferences
        case .assigned:
            assigned = preferences
        case .directReviewRequest:
            directReviewRequests = preferences
        case .teamReviewRequest:
            teamReviewRequests = preferences
        }
    }

    public func allows(event: PullRequestEvent, for pullRequest: PullRequest) -> Bool {
        let activity = PullRequestNotificationActivity(eventType: event.type)
        let relationships = event.relationshipChanges.isEmpty
            ? Set(Self.relationships(matching: pullRequest))
            : event.relationshipChanges
        return relationships.contains { relationship in
            preferences(for: relationship).allows(activity)
        }
    }

    public static func relationships(matching pullRequest: PullRequest) -> [PullRequestNotificationRelationship] {
        var relationships: [PullRequestNotificationRelationship] = []
        if pullRequest.isMine {
            relationships.append(.authored)
        }
        if pullRequest.isAssignedToViewer {
            relationships.append(.assigned)
        }
        if pullRequest.reviewRequestKind.includesDirect {
            relationships.append(.directReviewRequest)
        }
        if pullRequest.reviewRequestKind.includesTeam {
            relationships.append(.teamReviewRequest)
        }
        return relationships
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
