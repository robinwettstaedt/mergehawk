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

    public init(direct: Bool, team: Bool) {
        self = switch (direct, team) {
        case (true, true): .directAndTeam
        case (true, false): .direct
        case (false, true): .team
        case (false, false): .none
        }
    }

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
    public let url: URL
    public let state: PullRequestReviewState
    public let submittedAt: Date
    public let author: String?
    public let authorIsBot: Bool?
    public let viewerDidAuthor: Bool
    /// The last edit of the review summary; the submission time when the summary was never edited.
    public let updatedAt: Date
    /// Whether the review summary has any non-whitespace text.
    public let hasSummaryText: Bool
    /// Whether a comment-only review summary directly mentions the viewer. Decisions never carry a mention.
    public let mentionsViewer: Bool

    public init(
        id: String,
        url: URL,
        state: PullRequestReviewState,
        submittedAt: Date,
        author: String? = nil,
        authorIsBot: Bool? = nil,
        viewerDidAuthor: Bool = false,
        updatedAt: Date? = nil,
        hasSummaryText: Bool = false,
        mentionsViewer: Bool = false
    ) {
        self.id = id
        self.url = url
        self.state = state
        self.submittedAt = submittedAt
        self.author = author
        self.authorIsBot = authorIsBot
        self.viewerDidAuthor = viewerDidAuthor
        self.updatedAt = updatedAt ?? submittedAt
        self.hasSummaryText = hasSummaryText
        self.mentionsViewer = mentionsViewer
    }

    enum CodingKeys: String, CodingKey {
        case id, url, state, submittedAt, author, authorIsBot, viewerDidAuthor, updatedAt, hasSummaryText, mentionsViewer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            url: try container.decode(URL.self, forKey: .url),
            state: try container.decode(PullRequestReviewState.self, forKey: .state),
            submittedAt: try container.decode(Date.self, forKey: .submittedAt),
            author: try container.decodeIfPresent(String.self, forKey: .author),
            authorIsBot: try container.decodeIfPresent(Bool.self, forKey: .authorIsBot),
            viewerDidAuthor: try container.decode(Bool.self, forKey: .viewerDidAuthor),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt),
            hasSummaryText: try container.decodeIfPresent(Bool.self, forKey: .hasSummaryText) ?? false,
            mentionsViewer: try container.decodeIfPresent(Bool.self, forKey: .mentionsViewer) ?? false
        )
    }
}

public struct PullRequestCommentActivity: Identifiable, Codable, Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case pullRequest
        case reviewThread = "review_thread"
    }

    public let id: String
    public let url: URL
    public let author: String?
    public let authorIsBot: Bool?
    public let viewerDidAuthor: Bool
    public let createdAt: Date
    public let source: Source
    public let reviewId: String?
    /// When the comment became visible to others; nil while it is part of a pending review.
    public let publishedAt: Date?
    /// The last edit of the comment body; the publication time when the comment was never edited.
    public let updatedAt: Date
    /// The provider review thread holding an inline comment.
    public let threadId: String?
    public let mentionsViewer: Bool

    /// A nil `publishedAt` means publication at `createdAt` unless `isPublished` is false.
    public init(
        id: String,
        url: URL,
        author: String? = nil,
        authorIsBot: Bool? = nil,
        viewerDidAuthor: Bool = false,
        createdAt: Date,
        source: Source,
        reviewId: String? = nil,
        publishedAt: Date? = nil,
        isPublished: Bool = true,
        updatedAt: Date? = nil,
        threadId: String? = nil,
        mentionsViewer: Bool = false
    ) {
        self.id = id
        self.url = url
        self.author = author
        self.authorIsBot = authorIsBot
        self.viewerDidAuthor = viewerDidAuthor
        self.createdAt = createdAt
        self.source = source
        self.reviewId = reviewId
        let published = isPublished ? (publishedAt ?? createdAt) : nil
        self.publishedAt = published
        self.updatedAt = updatedAt ?? published ?? createdAt
        self.threadId = threadId
        self.mentionsViewer = mentionsViewer
    }

    enum CodingKeys: String, CodingKey {
        case id, url, author, authorIsBot, viewerDidAuthor, createdAt, source, reviewId
        case publishedAt, updatedAt, threadId, mentionsViewer
    }

    /// Activity stored before publication metadata existed decodes as published at its creation time.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let isPublished = try !container.contains(.publishedAt) || !container.decodeNil(forKey: .publishedAt)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            url: try container.decode(URL.self, forKey: .url),
            author: try container.decodeIfPresent(String.self, forKey: .author),
            authorIsBot: try container.decodeIfPresent(Bool.self, forKey: .authorIsBot),
            viewerDidAuthor: try container.decode(Bool.self, forKey: .viewerDidAuthor),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            source: try container.decode(Source.self, forKey: .source),
            reviewId: try container.decodeIfPresent(String.self, forKey: .reviewId),
            publishedAt: try container.decodeIfPresent(Date.self, forKey: .publishedAt),
            isPublished: isPublished,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt),
            threadId: try container.decodeIfPresent(String.self, forKey: .threadId),
            mentionsViewer: try container.decodeIfPresent(Bool.self, forKey: .mentionsViewer) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(authorIsBot, forKey: .authorIsBot)
        try container.encode(viewerDidAuthor, forKey: .viewerDidAuthor)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(reviewId, forKey: .reviewId)
        // An explicit null keeps a pending comment distinct from activity stored before publication existed.
        try container.encode(publishedAt, forKey: .publishedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(threadId, forKey: .threadId)
        try container.encode(mentionsViewer, forKey: .mentionsViewer)
    }
}

public struct PullRequest: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let number: Int
    public let url: URL
    public let repo: String
    public let repositoryIsArchived: Bool?
    public let ciState: CIState
    public let reviewDecision: ReviewDecision
    public let additions: Int?
    public let deletions: Int?
    public let commentCount: Int
    public let commentActivityCount: Int
    public var recentCommentActivities: [PullRequestCommentActivity]
    public let reviewCount: Int
    public var recentReviews: [PullRequestReview]
    public let headRefOid: String
    public var reviewRequestKind: ReviewRequestKind
    public let isAssignedToViewer: Bool
    public let isMine: Bool
    public let author: String
    public let authorAvatarURL: URL?
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
        repositoryIsArchived: Bool? = nil,
        ciState: CIState,
        reviewDecision: ReviewDecision,
        additions: Int? = nil,
        deletions: Int? = nil,
        commentCount: Int,
        commentActivityCount: Int? = nil,
        recentCommentActivities: [PullRequestCommentActivity] = [],
        reviewCount: Int,
        recentReviews: [PullRequestReview] = [],
        headRefOid: String = "",
        reviewRequestKind: ReviewRequestKind = .none,
        isAssignedToViewer: Bool = false,
        isMine: Bool,
        author: String,
        authorAvatarURL: URL? = nil,
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
        self.repositoryIsArchived = repositoryIsArchived
        self.ciState = ciState
        self.reviewDecision = reviewDecision
        self.additions = additions
        self.deletions = deletions
        self.commentCount = commentCount
        self.commentActivityCount = commentActivityCount ?? commentCount
        self.recentCommentActivities = recentCommentActivities
        self.reviewCount = reviewCount
        self.recentReviews = recentReviews
        self.headRefOid = headRefOid
        self.reviewRequestKind = reviewRequestKind
        self.isAssignedToViewer = isAssignedToViewer
        self.isMine = isMine
        self.author = author
        self.authorAvatarURL = authorAvatarURL
        self.headRefName = headRefName
        self.mergeable = mergeable
        self.draft = draft
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var withoutActivityHistory: PullRequest {
        var copy = self
        copy.recentCommentActivities = []
        copy.recentReviews = []
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case number
        case url
        case repo
        case repositoryIsArchived
        case ciState
        case reviewDecision
        case additions
        case deletions
        case commentCount
        case commentActivityCount
        case recentCommentActivities
        case reviewCount
        case recentReviews
        case headRefOid
        case reviewRequestKind
        case isAssignedToViewer
        case isMine
        case author
        case authorAvatarURL
        case headRefName
        case mergeable
        case draft
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.number = try container.decode(Int.self, forKey: .number)
        self.url = try container.decode(URL.self, forKey: .url)
        self.repo = try container.decode(String.self, forKey: .repo)
        self.repositoryIsArchived = try container.decodeIfPresent(Bool.self, forKey: .repositoryIsArchived)
        self.ciState = try container.decode(CIState.self, forKey: .ciState)
        self.reviewDecision = try container.decode(ReviewDecision.self, forKey: .reviewDecision)
        self.additions = try container.decodeIfPresent(Int.self, forKey: .additions)
        self.deletions = try container.decodeIfPresent(Int.self, forKey: .deletions)
        self.commentCount = try container.decode(Int.self, forKey: .commentCount)
        self.commentActivityCount = try container.decode(Int.self, forKey: .commentActivityCount)
        self.recentCommentActivities = try container.decode(
            [PullRequestCommentActivity].self,
            forKey: .recentCommentActivities
        )
        self.reviewCount = try container.decode(Int.self, forKey: .reviewCount)
        self.recentReviews = try container.decode([PullRequestReview].self, forKey: .recentReviews)
        self.headRefOid = try container.decodeIfPresent(String.self, forKey: .headRefOid) ?? ""
        self.reviewRequestKind = try container.decode(ReviewRequestKind.self, forKey: .reviewRequestKind)
        self.isAssignedToViewer = try container.decode(Bool.self, forKey: .isAssignedToViewer)
        self.isMine = try container.decode(Bool.self, forKey: .isMine)
        self.author = try container.decode(String.self, forKey: .author)
        self.authorAvatarURL = try container.decodeIfPresent(URL.self, forKey: .authorAvatarURL)
        self.headRefName = try container.decode(String.self, forKey: .headRefName)
        self.mergeable = try container.decode(MergeableState.self, forKey: .mergeable)
        self.draft = try container.decode(Bool.self, forKey: .draft)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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

    public var repositoryCount: Int {
        owners.reduce(0) { count, owner in
            count + owner.repositories.count
        }
    }

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

public struct GitHubAppInstallations: Codable, Equatable, Sendable {
    public let installations: [GitHubAppInstallation]

    public init(installations: [GitHubAppInstallation]) {
        self.installations = installations
    }
}

public struct GitHubAppInstallation: Codable, Equatable, Sendable {
    public enum RepositorySelection: String, Codable, Equatable, Sendable {
        case all
        case selected
    }

    public let id: Int
    public let accountLogin: String
    public let accountType: String
    public let repositorySelection: RepositorySelection
    public let htmlURL: URL?

    public init(
        id: Int,
        accountLogin: String,
        accountType: String,
        repositorySelection: RepositorySelection,
        htmlURL: URL? = nil
    ) {
        self.id = id
        self.accountLogin = accountLogin
        self.accountType = accountType
        self.repositorySelection = repositorySelection
        self.htmlURL = htmlURL
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

/// Why a comment update is relevant to the viewer. Nil on retained history recorded before reasons existed.
public enum PullRequestCommentReason: String, Codable, Equatable, Sendable {
    case mention
    case threadParticipation = "thread_participation"
    case general
}

public struct PullRequestEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: String { activityId ?? "\(type.rawValue)-\(prId)-\(count ?? 0)" }
    public let type: PullRequestEventType
    public let prId: String
    public let count: Int?
    public let actorLogin: String?
    public let actorIsBot: Bool?
    public let activityId: String?
    public let destinationURL: URL?
    public let happenedAt: Date?
    public let relationshipChanges: Set<PullRequestNotificationRelationship>
    public let commentReason: PullRequestCommentReason?

    public init(
        type: PullRequestEventType,
        prId: String,
        count: Int? = nil,
        actorLogin: String? = nil,
        actorIsBot: Bool? = nil,
        activityId: String? = nil,
        destinationURL: URL? = nil,
        happenedAt: Date? = nil,
        relationshipChanges: Set<PullRequestNotificationRelationship> = [],
        commentReason: PullRequestCommentReason? = nil
    ) {
        self.type = type
        self.prId = prId
        self.count = count
        self.actorLogin = actorLogin
        self.actorIsBot = actorIsBot
        self.activityId = activityId
        self.destinationURL = destinationURL
        self.happenedAt = happenedAt
        self.relationshipChanges = relationshipChanges
        self.commentReason = commentReason
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
    public let destinationURL: URL?
    public let actorLogin: String?
    public let activityId: String?
    public let relationshipChanges: Set<PullRequestNotificationRelationship>
    public let commentReason: PullRequestCommentReason?
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
        case destinationURL
        case actorLogin
        case activityId
        case relationshipChanges
        case commentReason
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
        self.destinationURL = event.destinationURL
        self.actorLogin = event.actorLogin
        self.activityId = event.activityId
        self.relationshipChanges = event.relationshipChanges
        self.commentReason = event.commentReason
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
        self.destinationURL = try container.decodeIfPresent(URL.self, forKey: .destinationURL)
        self.actorLogin = try container.decodeIfPresent(String.self, forKey: .actorLogin)
        self.activityId = try container.decodeIfPresent(String.self, forKey: .activityId)
        self.relationshipChanges = try container.decodeIfPresent(
            Set<PullRequestNotificationRelationship>.self,
            forKey: .relationshipChanges
        ) ?? []
        self.commentReason = try container.decodeIfPresent(PullRequestCommentReason.self, forKey: .commentReason)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.prUpdatedAt = try container.decode(Date.self, forKey: .prUpdatedAt)
        self.read = try container.decode(Bool.self, forKey: .read)
    }
}

/// The upper matrix categories. Comment updates are governed by the comment modes instead.
public enum PullRequestNotificationActivity: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case reviewActivity = "review_activity"
    case ciFailures = "ci_failures"
    case relationshipChanges = "relationship_changes"

    /// Nil for comment updates, which follow the comment modes.
    public init?(eventType: PullRequestEventType) {
        switch eventType {
        case .newComment, .reviewCommented:
            return nil
        case .reviewApproved, .newReview, .changesRequested:
            self = .reviewActivity
        case .ciFailed:
            self = .ciFailures
        case .relationshipAdded:
            self = .relationshipChanges
        }
    }
}

public struct PullRequestNotificationActivityPreferences: Codable, Equatable, Sendable {
    public var reviewActivity: Bool
    public var ciFailures: Bool
    public var relationshipChanges: Bool

    public static let authoredDefaults = PullRequestNotificationActivityPreferences(
        reviewActivity: true,
        ciFailures: true,
        relationshipChanges: false
    )
    public static let enabled = PullRequestNotificationActivityPreferences(
        reviewActivity: true,
        ciFailures: true,
        relationshipChanges: true
    )
    public static let disabled = PullRequestNotificationActivityPreferences(
        reviewActivity: false,
        ciFailures: false,
        relationshipChanges: false
    )
    public static let relationshipChangesOnly = PullRequestNotificationActivityPreferences(
        reviewActivity: false,
        ciFailures: false,
        relationshipChanges: true
    )

    enum CodingKeys: String, CodingKey {
        case reviewActivity
        case ciFailures
        case relationshipChanges
    }

    public init(
        reviewActivity: Bool,
        ciFailures: Bool,
        relationshipChanges: Bool = false
    ) {
        self.reviewActivity = reviewActivity
        self.ciFailures = ciFailures
        self.relationshipChanges = relationshipChanges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.reviewActivity = try container.decode(Bool.self, forKey: .reviewActivity)
        self.ciFailures = try container.decode(Bool.self, forKey: .ciFailures)
        self.relationshipChanges = try container.decodeIfPresent(Bool.self, forKey: .relationshipChanges) ?? false
    }

    public func allows(_ activity: PullRequestNotificationActivity) -> Bool {
        switch activity {
        case .reviewActivity:
            reviewActivity
        case .ciFailures:
            ciFailures
        case .relationshipChanges:
            relationshipChanges
        }
    }
}

public enum CommentNotificationMode: String, Codable, CaseIterable, Equatable, Sendable {
    case all
    case mentionsAndThreads = "mentions_and_threads"
    case off
}

extension CommentNotificationMode {
    /// A nil reason is retained or legacy activity and counts as a general comment.
    public func allows(_ reason: PullRequestCommentReason?) -> Bool {
        switch self {
        case .all:
            true
        case .mentionsAndThreads:
            reason == .mention || reason == .threadParticipation
        case .off:
            false
        }
    }
}

public struct CommentNotificationPreferences: Codable, Equatable, Sendable {
    public var authored: CommentNotificationMode
    public var assigned: CommentNotificationMode
    public var directReviewRequests: CommentNotificationMode
    public var teamReviewRequests: CommentNotificationMode

    public static let defaults = CommentNotificationPreferences(
        authored: .all,
        assigned: .all,
        directReviewRequests: .mentionsAndThreads,
        teamReviewRequests: .mentionsAndThreads
    )

    public init(
        authored: CommentNotificationMode,
        assigned: CommentNotificationMode,
        directReviewRequests: CommentNotificationMode,
        teamReviewRequests: CommentNotificationMode
    ) {
        self.authored = authored
        self.assigned = assigned
        self.directReviewRequests = directReviewRequests
        self.teamReviewRequests = teamReviewRequests
    }

    public func mode(for relationship: PullRequestNotificationRelationship) -> CommentNotificationMode {
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

    public mutating func set(_ mode: CommentNotificationMode, for relationship: PullRequestNotificationRelationship) {
        switch relationship {
        case .authored:
            authored = mode
        case .assigned:
            assigned = mode
        case .directReviewRequest:
            directReviewRequests = mode
        case .teamReviewRequest:
            teamReviewRequests = mode
        }
    }
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var authored: PullRequestNotificationActivityPreferences
    public var assigned: PullRequestNotificationActivityPreferences
    public var directReviewRequests: PullRequestNotificationActivityPreferences
    public var teamReviewRequests: PullRequestNotificationActivityPreferences
    public var commentModes: CommentNotificationPreferences

    public static let defaults = NotificationPreferences(
        authored: .authoredDefaults,
        assigned: .relationshipChangesOnly,
        directReviewRequests: .relationshipChangesOnly,
        teamReviewRequests: .relationshipChangesOnly
    )

    enum CodingKeys: String, CodingKey {
        case authored
        case assigned
        case directReviewRequests
        case teamReviewRequests
        case commentModes
    }

    public init(
        authored: PullRequestNotificationActivityPreferences,
        assigned: PullRequestNotificationActivityPreferences,
        directReviewRequests: PullRequestNotificationActivityPreferences,
        teamReviewRequests: PullRequestNotificationActivityPreferences,
        commentModes: CommentNotificationPreferences = .defaults
    ) {
        self.authored = authored
        self.assigned = assigned
        self.directReviewRequests = directReviewRequests
        self.teamReviewRequests = teamReviewRequests
        self.commentModes = commentModes
    }

    /// Comment modes are independent of the upper matrix, so a value saved before they existed gets their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.authored = try container.decode(PullRequestNotificationActivityPreferences.self, forKey: .authored)
        self.assigned = try container.decode(PullRequestNotificationActivityPreferences.self, forKey: .assigned)
        self.directReviewRequests = try container.decode(
            PullRequestNotificationActivityPreferences.self,
            forKey: .directReviewRequests
        )
        self.teamReviewRequests = try container.decode(
            PullRequestNotificationActivityPreferences.self,
            forKey: .teamReviewRequests
        )
        self.commentModes = try container.decodeIfPresent(
            CommentNotificationPreferences.self,
            forKey: .commentModes
        ) ?? .defaults
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

    /// Any matching relationship that allows the update is enough; comment updates use the comment modes.
    public func allows(event: PullRequestEvent, for pullRequest: PullRequest) -> Bool {
        let relationships = event.relationshipChanges.isEmpty
            ? Set(Self.relationships(matching: pullRequest))
            : event.relationshipChanges
        switch event.type {
        case .newComment, .reviewCommented:
            return relationships.contains { relationship in
                commentModes.mode(for: relationship).allows(event.commentReason)
            }
        default:
            guard let activity = PullRequestNotificationActivity(eventType: event.type) else { return false }
            return relationships.contains { relationship in
                preferences(for: relationship).allows(activity)
            }
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
