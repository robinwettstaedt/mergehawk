import Foundation

public protocol PullRequestSource: AnyObject {
    var sourceKind: DashboardSource { get }
    func fetchPullRequests(
        login: String,
        previousPullRequests: [PullRequest]
    ) async throws -> PullRequestFetchResult
}

public protocol SourceCatalogProviding: AnyObject {
    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog
}

public protocol GitHubAppInstallationProviding: AnyObject {
    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations
}

public protocol GitHubViewerProviding: AnyObject {
    func fetchViewer() async throws -> GitHubAccount
}

public typealias GitHubProviding = PullRequestSource
    & SourceCatalogProviding
    & GitHubAppInstallationProviding
    & GitHubViewerProviding
    & GitHubInboxProviding

public protocol GitHubInboxProviding: AnyObject {
    func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult
    func markInboxThreadRead(threadId: String) async throws
}

public final class EmptyPullRequestSource: PullRequestSource {
    public let sourceKind: DashboardSource = .none

    public init() {}

    public func fetchPullRequests(
        login: String,
        previousPullRequests: [PullRequest]
    ) async throws -> PullRequestFetchResult {
        PullRequestFetchResult(pullRequests: [])
    }
}

public final class MockPullRequestSource: PullRequestSource {
    public let sourceKind: DashboardSource = .mock
    private var index = 0
    private let snapshots: [[PullRequest]]
    private let inboxNotifications: [GitHubInboxNotification]

    public init(showsNotificationTypeFixtures: Bool = false, referenceDate: Date = Date()) {
        let minute: TimeInterval = 60
        let hour = 60 * minute
        let day = 24 * hour
        func ago(_ interval: TimeInterval) -> Date { referenceDate.addingTimeInterval(-interval) }

        self.inboxNotifications = showsNotificationTypeFixtures
            ? Self.notificationTypeFixtureInboxNotifications
            : Self.defaultInboxNotifications
        self.snapshots = [
            [
                PullRequest(
                    id: "PR_1",
                    title: "feat(MER-14): Add OAuth device flow",
                    number: 14,
                    url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/14")!,
                    repo: "mergehawk-labs/mergehawk",
                    ciState: .passing,
                    reviewDecision: .noReviewYet,
                    additions: 0,
                    deletions: 0,
                    commentCount: 2,
                    reviewCount: 0,
                    isMine: true,
                    author: "rw",
                    headRefName: "MER-14-oauth-device-flow",
                    mergeable: .mergeable,
                    draft: true,
                    createdAt: ago(150 * day),
                    updatedAt: ago(3 * hour)
                ),
                PullRequest(
                    id: "PR_4",
                    title: "chore(MER-33): Add reviewer assignment summary and synchronize long organization policy names across the desktop settings screens",
                    number: 48,
                    url: URL(string: "https://github.com/customer-success-platform/team-portal-web/pull/48")!,
                    repo: "customer-success-platform/team-portal-web",
                    ciState: .failing,
                    reviewDecision: .approved,
                    additions: 12_345,
                    deletions: 6_789,
                    commentCount: 5,
                    reviewCount: 2,
                    recentCommits: [
                        PullRequestCommit(
                            oid: "PR_4_COMMIT_BASELINE",
                            authoredAt: Date(timeIntervalSince1970: 1_777_806_000),
                            committedAt: Date(timeIntervalSince1970: 1_777_806_000),
                            authorLogin: "rw",
                            committerLogin: "rw"
                        )
                    ],
                    isMine: true,
                    author: "rw",
                    headRefName: "MER-33-review-assignment-summary",
                    mergeable: .conflicting,
                    draft: false,
                    createdAt: ago(180 * day),
                    updatedAt: ago(45 * day)
                ),
                PullRequest(
                    id: "PR_6",
                    title: "fix(MER-44): Handle requested changes",
                    number: 56,
                    url: URL(string: "https://github.com/mergehawk-labs/desktop-app/pull/56")!,
                    repo: "mergehawk-labs/desktop-app",
                    ciState: .passing,
                    reviewDecision: .changesRequested,
                    commentCount: 222,
                    reviewCount: 2,
                    isMine: true,
                    author: "rw",
                    headRefName: "MER-44-handle-requested-changes",
                    mergeable: .mergeable,
                    draft: false,
                    createdAt: ago(45 * minute),
                    updatedAt: ago(35 * minute)
                ),
                PullRequest(
                    id: "PR_2",
                    title: "feat(MER-27): Show PR author in requested rows",
                    number: 27,
                    url: URL(string: "https://github.com/mergehawk-labs/desktop-app/pull/27")!,
                    repo: "mergehawk-labs/desktop-app",
                    ciState: .pending,
                    reviewDecision: .approved,
                    additions: 650,
                    deletions: 30,
                    commentCount: 4,
                    reviewCount: 2,
                    reviewRequestKind: .direct,
                    isMine: false,
                    author: "teammate",
                    headRefName: "MER-27-show-pr-author-rows",
                    mergeable: .unknown,
                    draft: false,
                    createdAt: ago(28 * day),
                    updatedAt: ago(8 * hour)
                ),
                PullRequest(
                    id: "PR_3",
                    title: "fix(MER-18): Tighten billing retry copy",
                    number: 31,
                    url: URL(
                        string: "https://github.com/billing-platform-experiments/customer-subscription-dashboard/pull/31"
                    )!,
                    repo: "billing-platform-experiments/customer-subscription-dashboard",
                    ciState: .unknown,
                    reviewDecision: .noReviewYet,
                    additions: 1_200_000,
                    deletions: 0,
                    commentCount: 1,
                    reviewCount: 0,
                    reviewRequestKind: .team,
                    isMine: false,
                    author: "design-systems-amy",
                    headRefName: "MER-18-tighten-billing-retry-copy-for-failed-payment-state-when-card-network-times-out",
                    mergeable: .unknown,
                    draft: true,
                    createdAt: ago(60 * day),
                    updatedAt: ago(14 * day)
                ),
                PullRequest(
                    id: "PR_7",
                    title: "feat(MER-36): Handle assigned incoming PRs",
                    number: 61,
                    url: URL(string: "https://github.com/mergehawk-labs/review-router/pull/61")!,
                    repo: "mergehawk-labs/review-router",
                    ciState: .pending,
                    reviewDecision: .unknown,
                    commentCount: 0,
                    reviewCount: 0,
                    isAssignedToViewer: true,
                    isMine: false,
                    author: "platform-nora",
                    headRefName: "MER-36-assigned-incoming-prs",
                    mergeable: .unknown,
                    draft: false,
                    createdAt: ago(2 * hour),
                    updatedAt: ago(12 * minute)
                ),
                PullRequest(
                    id: "PR_5",
                    title: "refactor(MER-41): Surface stale review requests and consolidate the reviewer assignment summary into a single daily digest",
                    number: 52,
                    url: URL(string: "https://github.com/mergehawk-labs/review-router/pull/52")!,
                    repo: "mergehawk-labs/review-router",
                    ciState: .failing,
                    reviewDecision: .changesRequested,
                    additions: 123_456,
                    deletions: 987_654,
                    commentCount: 8,
                    reviewCount: 3,
                    reviewRequestKind: .directAndTeam,
                    isMine: false,
                    author: "backend-mateo",
                    headRefName: "MER-41-stale-review-alerts",
                    mergeable: .conflicting,
                    draft: false,
                    createdAt: ago(5 * day),
                    updatedAt: ago(2 * day)
                )
            ],
            [
                PullRequest(
                    id: "PR_1",
                    title: "feat(MER-14): Add OAuth device flow",
                    number: 14,
                    url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/14")!,
                    repo: "mergehawk-labs/mergehawk",
                    ciState: .failing,
                    reviewDecision: .noReviewYet,
                    additions: 0,
                    deletions: 0,
                    commentCount: 3,
                    recentCommentActivities: [
                        PullRequestCommentActivity(
                            id: "PR_1_COMMENT_NEW",
                            author: "frontend-sam",
                            createdAt: Date(timeIntervalSince1970: 1_777_815_000),
                            source: .pullRequest
                        )
                    ],
                    reviewCount: 0,
                    isMine: true,
                    author: "rw",
                    headRefName: "MER-14-oauth-device-flow",
                    mergeable: .mergeable,
                    draft: true,
                    createdAt: ago(150 * day),
                    updatedAt: ago(3 * hour)
                ),
                PullRequest(
                    id: "PR_4",
                    title: "chore(MER-33): Add reviewer assignment summary and synchronize long organization policy names across the desktop settings screens",
                    number: 48,
                    url: URL(string: "https://github.com/customer-success-platform/team-portal-web/pull/48")!,
                    repo: "customer-success-platform/team-portal-web",
                    ciState: .failing,
                    reviewDecision: .approved,
                    additions: 12_345,
                    deletions: 6_789,
                    commentCount: 5,
                    reviewCount: 2,
                    recentCommits: [
                        PullRequestCommit(
                            oid: "PR_4_COMMIT_BASELINE",
                            authoredAt: Date(timeIntervalSince1970: 1_777_806_000),
                            committedAt: Date(timeIntervalSince1970: 1_777_806_000),
                            authorLogin: "rw",
                            committerLogin: "rw"
                        ),
                        PullRequestCommit(
                            oid: "PR_4_COMMIT_OTHER",
                            authoredAt: Date(timeIntervalSince1970: 1_777_814_000),
                            committedAt: Date(timeIntervalSince1970: 1_777_814_200),
                            authorLogin: "platform-nora",
                            committerLogin: "platform-nora"
                        )
                    ],
                    isMine: true,
                    author: "rw",
                    headRefName: "MER-33-review-assignment-summary",
                    mergeable: .conflicting,
                    draft: false,
                    createdAt: ago(180 * day),
                    updatedAt: ago(45 * day)
                ),
                PullRequest(
                    id: "PR_6",
                    title: "fix(MER-44): Handle requested changes",
                    number: 56,
                    url: URL(string: "https://github.com/mergehawk-labs/desktop-app/pull/56")!,
                    repo: "mergehawk-labs/desktop-app",
                    ciState: .passing,
                    reviewDecision: .changesRequested,
                    commentCount: 222,
                    reviewCount: 2,
                    isMine: true,
                    author: "rw",
                    headRefName: "MER-44-handle-requested-changes",
                    mergeable: .mergeable,
                    draft: false,
                    createdAt: ago(45 * minute),
                    updatedAt: ago(35 * minute)
                ),
                PullRequest(
                    id: "PR_2",
                    title: "feat(MER-27): Show PR author in requested rows",
                    number: 27,
                    url: URL(string: "https://github.com/mergehawk-labs/desktop-app/pull/27")!,
                    repo: "mergehawk-labs/desktop-app",
                    ciState: .passing,
                    reviewDecision: .approved,
                    additions: 650,
                    deletions: 30,
                    commentCount: 4,
                    reviewCount: 2,
                    reviewRequestKind: .direct,
                    isAssignedToViewer: true,
                    isMine: false,
                    author: "teammate",
                    headRefName: "MER-27-show-pr-author-rows",
                    mergeable: .mergeable,
                    draft: false,
                    createdAt: ago(28 * day),
                    updatedAt: ago(8 * hour)
                ),
                PullRequest(
                    id: "PR_3",
                    title: "fix(MER-18): Tighten billing retry copy",
                    number: 31,
                    url: URL(
                        string: "https://github.com/billing-platform-experiments/customer-subscription-dashboard/pull/31"
                    )!,
                    repo: "billing-platform-experiments/customer-subscription-dashboard",
                    ciState: .unknown,
                    reviewDecision: .noReviewYet,
                    additions: 1_200_000,
                    deletions: 0,
                    commentCount: 1,
                    reviewCount: 0,
                    reviewRequestKind: .team,
                    isMine: false,
                    author: "design-systems-amy",
                    headRefName: "MER-18-tighten-billing-retry-copy-for-failed-payment-state-when-card-network-times-out",
                    mergeable: .unknown,
                    draft: true,
                    createdAt: ago(60 * day),
                    updatedAt: ago(14 * day)
                ),
                PullRequest(
                    id: "PR_7",
                    title: "feat(MER-36): Handle assigned incoming PRs",
                    number: 61,
                    url: URL(string: "https://github.com/mergehawk-labs/review-router/pull/61")!,
                    repo: "mergehawk-labs/review-router",
                    ciState: .pending,
                    reviewDecision: .unknown,
                    commentCount: 0,
                    reviewCount: 0,
                    isAssignedToViewer: true,
                    isMine: false,
                    author: "platform-nora",
                    headRefName: "MER-36-assigned-incoming-prs",
                    mergeable: .unknown,
                    draft: false,
                    createdAt: ago(2 * hour),
                    updatedAt: ago(12 * minute)
                ),
                PullRequest(
                    id: "PR_5",
                    title: "refactor(MER-41): Surface stale review requests and consolidate the reviewer assignment summary into a single daily digest",
                    number: 52,
                    url: URL(string: "https://github.com/mergehawk-labs/review-router/pull/52")!,
                    repo: "mergehawk-labs/review-router",
                    ciState: .failing,
                    reviewDecision: .changesRequested,
                    additions: 123_456,
                    deletions: 987_654,
                    commentCount: 8,
                    reviewCount: 3,
                    reviewRequestKind: .directAndTeam,
                    isMine: false,
                    author: "backend-mateo",
                    headRefName: "MER-41-stale-review-alerts",
                    mergeable: .conflicting,
                    draft: false,
                    createdAt: ago(5 * day),
                    updatedAt: ago(2 * day)
                )
            ]
        ]
    }

    public func fetchPullRequests(
        login: String,
        previousPullRequests: [PullRequest]
    ) async throws -> PullRequestFetchResult {
        let snapshot = snapshots[min(index, snapshots.count - 1)]
        index += 1
        return PullRequestFetchResult(pullRequests: snapshot)
    }

    public static var notificationTypeFixturePullRequestNotifications: [PullRequestNotification] {
        [
            PullRequestNotification(
                event: PullRequestEvent(
                    type: .relationshipAdded,
                    prId: notificationFixtureRelationshipPullRequest.id,
                    relationshipChanges: [.assigned, .directReviewRequest]
                ),
                pullRequest: notificationFixtureRelationshipPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_813_200)
            ),
            PullRequestNotification(
                event: PullRequestEvent(
                    type: .relationshipAdded,
                    prId: notificationFixtureAssignedPullRequest.id,
                    relationshipChanges: [.assigned]
                ),
                pullRequest: notificationFixtureAssignedPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_811_400)
            ),
            PullRequestNotification(
                event: PullRequestEvent(
                    type: .newComment,
                    prId: notificationFixtureCommentPullRequest.id,
                    count: 1,
                    actorLogin: "frontend-sam",
                    activityId: "PR_NOTIFICATION_COMMENT_ACTIVITY"
                ),
                pullRequest: notificationFixtureCommentPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_809_600)
            ),
            PullRequestNotification(
                event: PullRequestEvent(
                    type: .reviewApproved,
                    prId: notificationFixtureApprovalPullRequest.id,
                    count: 1,
                    actorLogin: "platform-nora",
                    activityId: "PR_NOTIFICATION_APPROVAL_REVIEW"
                ),
                pullRequest: notificationFixtureApprovalPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_806_000)
            ),
            PullRequestNotification(
                event: PullRequestEvent(
                    type: .reviewCommented,
                    prId: notificationFixtureReviewCommentPullRequest.id,
                    count: 1,
                    actorLogin: "docs-lee",
                    activityId: "PR_NOTIFICATION_REVIEW_COMMENT"
                ),
                pullRequest: notificationFixtureReviewCommentPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_802_400)
            ),
            PullRequestNotification(
                event: PullRequestEvent(
                    type: .changesRequested,
                    prId: notificationFixtureChangesRequestedPullRequest.id,
                    count: 1,
                    actorLogin: "billing-ivy",
                    activityId: "PR_NOTIFICATION_CHANGES_REVIEW"
                ),
                pullRequest: notificationFixtureChangesRequestedPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_798_800)
            ),
            PullRequestNotification(
                event: PullRequestEvent(
                    type: .otherCommitAdded,
                    prId: notificationFixtureOtherCommitPullRequest.id,
                    count: 1,
                    actorLogin: "platform-nora"
                ),
                pullRequest: notificationFixtureOtherCommitPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_797_000)
            ),
            PullRequestNotification(
                event: PullRequestEvent(type: .ciFailed, prId: notificationFixtureCIPullRequest.id),
                pullRequest: notificationFixtureCIPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_795_200)
            )
        ]
    }

    private static let notificationFixtureRelationshipPullRequest = PullRequest(
        id: "PR_NOTIFICATION_RELATIONSHIP",
        title: "Route newly requested reviews",
        number: 40,
        url: URL(string: "https://github.com/example/review-router/pull/40")!,
        repo: "example/review-router",
        ciState: .pending,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        reviewRequestKind: .direct,
        isAssignedToViewer: true,
        isMine: false,
        author: "platform-nora",
        headRefName: "new-review-routing",
        mergeable: .unknown,
        draft: false,
        updatedAt: Date(timeIntervalSince1970: 1_777_813_200)
    )

    private static let notificationFixtureAssignedPullRequest = PullRequest(
        id: "PR_NOTIFICATION_ASSIGNED",
        title: "Follow up on assigned review",
        number: 39,
        url: URL(string: "https://github.com/example/review-router/pull/39")!,
        repo: "example/review-router",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        isAssignedToViewer: true,
        isMine: false,
        author: "backend-mateo",
        headRefName: "assigned-review-follow-up",
        mergeable: .mergeable,
        draft: false,
        updatedAt: Date(timeIntervalSince1970: 1_777_811_400)
    )

    private static let notificationFixtureCommentPullRequest = PullRequest(
        id: "PR_NOTIFICATION_COMMENT",
        title: "Add inline notification grouping",
        number: 41,
        url: URL(string: "https://github.com/example/mergehawk/pull/41")!,
        repo: "example/mergehawk",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: 1,
        reviewCount: 0,
        isMine: true,
        author: "agent-fixture",
        headRefName: "notification-grouping",
        mergeable: .mergeable,
        draft: false,
        updatedAt: Date(timeIntervalSince1970: 1_777_809_600)
    )

    private static let notificationFixtureApprovalPullRequest = PullRequest(
        id: "PR_NOTIFICATION_APPROVAL",
        title: "Review source preference filters",
        number: 42,
        url: URL(string: "https://github.com/example/app/pull/42")!,
        repo: "example/app",
        ciState: .passing,
        reviewDecision: .approved,
        commentCount: 2,
        reviewCount: 1,
        isMine: true,
        author: "agent-fixture",
        headRefName: "source-preference-filters",
        mergeable: .mergeable,
        draft: false,
        updatedAt: Date(timeIntervalSince1970: 1_777_806_000)
    )

    private static let notificationFixtureReviewCommentPullRequest = PullRequest(
        id: "PR_NOTIFICATION_REVIEW_COMMENT",
        title: "Clarify notification grouping copy",
        number: 43,
        url: URL(string: "https://github.com/example/docs/pull/43")!,
        repo: "example/docs",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: 1,
        reviewCount: 1,
        isMine: true,
        author: "agent-fixture",
        headRefName: "notification-copy",
        mergeable: .mergeable,
        draft: false,
        updatedAt: Date(timeIntervalSince1970: 1_777_802_400)
    )

    private static let notificationFixtureCIPullRequest = PullRequest(
        id: "PR_NOTIFICATION_CI",
        title: "Stabilize release signing",
        number: 45,
        url: URL(string: "https://github.com/example/mobile/pull/45")!,
        repo: "example/mobile",
        ciState: .failing,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        isMine: true,
        author: "agent-fixture",
        headRefName: "release-signing",
        mergeable: .unknown,
        draft: false,
        updatedAt: Date(timeIntervalSince1970: 1_777_795_200)
    )

    private static let notificationFixtureOtherCommitPullRequest = PullRequest(
        id: "PR_NOTIFICATION_OTHER_COMMIT",
        title: "Coordinate authored branch updates",
        number: 46,
        url: URL(string: "https://github.com/example/desktop/pull/46")!,
        repo: "example/desktop",
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: 0,
        reviewCount: 0,
        isMine: true,
        author: "agent-fixture",
        headRefName: "authored-branch-updates",
        mergeable: .mergeable,
        draft: false,
        updatedAt: Date(timeIntervalSince1970: 1_777_797_000)
    )

    private static let notificationFixtureChangesRequestedPullRequest = PullRequest(
        id: "PR_NOTIFICATION_CHANGES",
        title: "Tighten billing retry copy",
        number: 44,
        url: URL(string: "https://github.com/example/web/pull/44")!,
        repo: "example/web",
        ciState: .passing,
        reviewDecision: .changesRequested,
        commentCount: 3,
        reviewCount: 2,
        isMine: true,
        author: "agent-fixture",
        headRefName: "billing-retry-copy",
        mergeable: .mergeable,
        draft: false,
        updatedAt: Date(timeIntervalSince1970: 1_777_798_800)
    )
}

extension MockPullRequestSource: SourceCatalogProviding {
    public func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        mockSourceCatalog(accountLogin: accountLogin)
    }

    public func mockSourceCatalog(accountLogin: String?) -> SourceCatalog {
        SourceCatalog(
            repositories: [
                RepositorySource(owner: "agent-fixture", name: "sandbox"),
                RepositorySource(owner: "billing-platform-experiments", name: "customer-subscription-dashboard"),
                RepositorySource(owner: "customer-success-platform", name: "team-portal-web"),
                RepositorySource(owner: "mergehawk-labs", name: "desktop-app"),
                RepositorySource(owner: "mergehawk-labs", name: "mergehawk"),
                RepositorySource(owner: "mergehawk-labs", name: "review-router")
            ],
            accountLogin: accountLogin
        )
    }
}

extension MockPullRequestSource: GitHubInboxProviding {
    public func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult {
        GitHubInboxFetchResult(
            notifications: inboxNotifications,
            metadata: GitHubInboxSyncMetadata(
                eTag: metadata.eTag,
                lastFetchedAt: Date(),
                pollIntervalSeconds: 60
            )
        )
    }

    public func markInboxThreadRead(threadId: String) async throws {}

    private static let defaultInboxNotifications = [
        GitHubInboxNotification(
            threadId: "mock-issue-1",
            repo: "example/app",
            subjectTitle: "Crash when saving source preferences",
            subjectType: "Issue",
            reason: "mention",
            unread: true,
            updatedAt: Date(timeIntervalSince1970: 1_777_809_600),
            threadURL: URL(string: "https://api.github.com/notifications/threads/mock-issue-1")!,
            webURL: URL(string: "https://github.com/example/app/issues/42")!
        ),
        GitHubInboxNotification(
            threadId: "mock-discussion-1",
            repo: "example/web",
            subjectTitle: "Ideas for review request grouping",
            subjectType: "Discussion",
            reason: "subscribed",
            unread: false,
            updatedAt: Date(timeIntervalSince1970: 1_777_723_200),
            threadURL: URL(string: "https://api.github.com/notifications/threads/mock-discussion-1")!,
            webURL: URL(string: "https://github.com/example/web/discussions/8")!
        )
    ]

    public static let notificationTypeFixtureInboxNotifications = [
        GitHubInboxNotification(
            threadId: "mock-fixture-issue",
            repo: "example/app",
            subjectTitle: "Crash when saving source preferences",
            subjectType: "Issue",
            reason: "mention",
            unread: true,
            updatedAt: Date(timeIntervalSince1970: 1_777_809_600),
            threadURL: URL(string: "https://api.github.com/notifications/threads/mock-fixture-issue")!,
            webURL: URL(string: "https://github.com/example/app/issues/42")!
        ),
        GitHubInboxNotification(
            threadId: "mock-fixture-discussion",
            repo: "example/web",
            subjectTitle: "Ideas for review request grouping",
            subjectType: "Discussion",
            reason: "subscribed",
            unread: true,
            updatedAt: Date(timeIntervalSince1970: 1_777_806_000),
            threadURL: URL(string: "https://api.github.com/notifications/threads/mock-fixture-discussion")!,
            webURL: URL(string: "https://github.com/example/web/discussions/8")!
        ),
        GitHubInboxNotification(
            threadId: "mock-fixture-release",
            repo: "example/desktop",
            subjectTitle: "MergeHawk 0.2.0",
            subjectType: "Release",
            reason: "subscribed",
            unread: true,
            updatedAt: Date(timeIntervalSince1970: 1_777_802_400),
            threadURL: URL(string: "https://api.github.com/notifications/threads/mock-fixture-release")!,
            webURL: URL(string: "https://github.com/example/desktop/releases/tag/v0.2.0")!
        ),
        GitHubInboxNotification(
            threadId: "mock-fixture-commit",
            repo: "example/mergehawk",
            subjectTitle: "Improve menu snapshot coverage",
            subjectType: "Commit",
            reason: "author",
            unread: true,
            updatedAt: Date(timeIntervalSince1970: 1_777_798_800),
            threadURL: URL(string: "https://api.github.com/notifications/threads/mock-fixture-commit")!,
            webURL: URL(string: "https://github.com/example/mergehawk/commit/mock-fixture")!
        ),
        GitHubInboxNotification(
            threadId: "mock-fixture-check-suite",
            repo: "example/app",
            subjectTitle: "CI workflow requires attention",
            subjectType: "CheckSuite",
            reason: "ci_activity",
            unread: true,
            updatedAt: Date(timeIntervalSince1970: 1_777_795_200),
            threadURL: URL(string: "https://api.github.com/notifications/threads/mock-fixture-check-suite")!,
            webURL: URL(string: "https://github.com/example/app/actions/runs/123456")!
        ),
        GitHubInboxNotification(
            threadId: "mock-fixture-vulnerability-alert",
            repo: "example/security",
            subjectTitle: "Dependency alert for swift-argument-parser",
            subjectType: "RepositoryVulnerabilityAlert",
            reason: "security_alert",
            unread: true,
            updatedAt: Date(timeIntervalSince1970: 1_777_791_600),
            threadURL: URL(string: "https://api.github.com/notifications/threads/mock-fixture-vulnerability-alert")!,
            webURL: URL(string: "https://github.com/example/security/security/dependabot")!
        )
    ]
}
