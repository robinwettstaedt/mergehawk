import Foundation

public protocol PullRequestSource: AnyObject {
    var sourceKind: DashboardSource { get }
    func fetchPullRequests(login: String) async throws -> [PullRequest]
}

public protocol SourceCatalogProviding: AnyObject {
    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog
}

public protocol GitHubInboxProviding: AnyObject {
    func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult
    func markInboxThreadRead(threadId: String) async throws
}

public final class EmptyPullRequestSource: PullRequestSource {
    public let sourceKind: DashboardSource = .none

    public init() {}

    public func fetchPullRequests(login: String) async throws -> [PullRequest] {
        []
    }
}

public final class MockPullRequestSource: PullRequestSource {
    public let sourceKind: DashboardSource = .mock
    private var index = 0
    private let snapshots: [[PullRequest]]
    private let inboxNotifications: [GitHubInboxNotification]

    public init(showsNotificationTypeFixtures: Bool = false) {
        self.inboxNotifications = showsNotificationTypeFixtures
            ? Self.notificationTypeFixtureInboxNotifications
            : Self.defaultInboxNotifications
        self.snapshots = [
            [
                PullRequest(
                    id: "PR_1",
                    title: "Add OAuth device flow",
                    number: 14,
                    url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/14")!,
                    repo: "mergehawk-labs/mergehawk",
                    ciState: .passing,
                    reviewDecision: .reviewRequired,
                    commentCount: 2,
                    reviewCount: 0,
                    isMine: true,
                    author: "rw",
                    headRefName: "MER-14-oauth-device-flow",
                    mergeable: .mergeable,
                    draft: true,
                    createdAt: Date(timeIntervalSince1970: 1_777_750_000),
                    updatedAt: Date(timeIntervalSince1970: 1_777_805_000)
                ),
                PullRequest(
                    id: "PR_4",
                    title: "Add reviewer assignment summary",
                    number: 48,
                    url: URL(string: "https://github.com/customer-success-platform/team-portal-web/pull/48")!,
                    repo: "customer-success-platform/team-portal-web",
                    ciState: .passing,
                    reviewDecision: .approved,
                    commentCount: 5,
                    reviewCount: 2,
                    isMine: true,
                    author: "rw",
                    headRefName: "MER-33-review-assignment-summary",
                    mergeable: .mergeable,
                    draft: false,
                    createdAt: Date(timeIntervalSince1970: 1_777_760_000),
                    updatedAt: Date(timeIntervalSince1970: 1_777_806_000)
                ),
                PullRequest(
                    id: "PR_2",
                    title: "Show PR author in requested rows",
                    number: 27,
                    url: URL(string: "https://github.com/mergehawk-labs/desktop-app/pull/27")!,
                    repo: "mergehawk-labs/desktop-app",
                    ciState: .pending,
                    reviewDecision: .approved,
                    commentCount: 4,
                    reviewCount: 2,
                    reviewRequestKind: .direct,
                    isMine: false,
                    author: "teammate",
                    headRefName: "MER-27-show-pr-author-rows",
                    mergeable: .unknown,
                    draft: false,
                    createdAt: Date(timeIntervalSince1970: 1_777_770_000),
                    updatedAt: Date(timeIntervalSince1970: 1_777_807_000)
                ),
                PullRequest(
                    id: "PR_3",
                    title: "Tighten billing retry copy",
                    number: 31,
                    url: URL(string: "https://github.com/billing-platform-experiments/customer-dashboard/pull/31")!,
                    repo: "billing-platform-experiments/customer-dashboard",
                    ciState: .passing,
                    reviewDecision: .reviewRequired,
                    commentCount: 1,
                    reviewCount: 0,
                    reviewRequestKind: .team,
                    isMine: false,
                    author: "design-systems-amy",
                    headRefName: "MER-18-tighten-billing-copy",
                    mergeable: .mergeable,
                    draft: true,
                    createdAt: Date(timeIntervalSince1970: 1_777_780_000),
                    updatedAt: Date(timeIntervalSince1970: 1_777_808_000)
                ),
                PullRequest(
                    id: "PR_5",
                    title: "Surface stale review requests",
                    number: 52,
                    url: URL(string: "https://github.com/mergehawk-labs/review-router/pull/52")!,
                    repo: "mergehawk-labs/review-router",
                    ciState: .failing,
                    reviewDecision: .changesRequested,
                    commentCount: 8,
                    reviewCount: 3,
                    reviewRequestKind: .directAndTeam,
                    isMine: false,
                    author: "backend-mateo",
                    headRefName: "MER-41-stale-review-alerts",
                    mergeable: .conflicting,
                    draft: false,
                    createdAt: Date(timeIntervalSince1970: 1_777_790_000),
                    updatedAt: Date(timeIntervalSince1970: 1_777_809_000)
                )
            ],
            [
                PullRequest(
                    id: "PR_1",
                    title: "Add OAuth device flow",
                    number: 14,
                    url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/14")!,
                    repo: "mergehawk-labs/mergehawk",
                    ciState: .failing,
                    reviewDecision: .reviewRequired,
                    commentCount: 3,
                    reviewCount: 0,
                    isMine: true,
                    author: "rw",
                    headRefName: "MER-14-oauth-device-flow",
                    mergeable: .mergeable,
                    draft: true,
                    createdAt: Date(timeIntervalSince1970: 1_777_750_000),
                    updatedAt: Date(timeIntervalSince1970: 1_777_815_000)
                ),
                PullRequest(
                    id: "PR_4",
                    title: "Add reviewer assignment summary",
                    number: 48,
                    url: URL(string: "https://github.com/customer-success-platform/team-portal-web/pull/48")!,
                    repo: "customer-success-platform/team-portal-web",
                    ciState: .passing,
                    reviewDecision: .approved,
                    commentCount: 5,
                    reviewCount: 2,
                    isMine: true,
                    author: "rw",
                    headRefName: "MER-33-review-assignment-summary",
                    mergeable: .mergeable,
                    draft: false,
                    createdAt: Date(timeIntervalSince1970: 1_777_760_000),
                    updatedAt: Date(timeIntervalSince1970: 1_777_806_000)
                ),
                PullRequest(
                    id: "PR_2",
                    title: "Show PR author in requested rows",
                    number: 27,
                    url: URL(string: "https://github.com/mergehawk-labs/desktop-app/pull/27")!,
                    repo: "mergehawk-labs/desktop-app",
                    ciState: .passing,
                    reviewDecision: .approved,
                    commentCount: 4,
                    reviewCount: 2,
                    reviewRequestKind: .direct,
                    isMine: false,
                    author: "teammate",
                    headRefName: "MER-27-show-pr-author-rows",
                    mergeable: .mergeable,
                    draft: false,
                    createdAt: Date(timeIntervalSince1970: 1_777_770_000),
                    updatedAt: Date(timeIntervalSince1970: 1_777_807_000)
                ),
                PullRequest(
                    id: "PR_3",
                    title: "Tighten billing retry copy",
                    number: 31,
                    url: URL(string: "https://github.com/billing-platform-experiments/customer-dashboard/pull/31")!,
                    repo: "billing-platform-experiments/customer-dashboard",
                    ciState: .passing,
                    reviewDecision: .reviewRequired,
                    commentCount: 1,
                    reviewCount: 0,
                    reviewRequestKind: .team,
                    isMine: false,
                    author: "design-systems-amy",
                    headRefName: "MER-18-tighten-billing-copy",
                    mergeable: .mergeable,
                    draft: true,
                    createdAt: Date(timeIntervalSince1970: 1_777_780_000),
                    updatedAt: Date(timeIntervalSince1970: 1_777_808_000)
                ),
                PullRequest(
                    id: "PR_5",
                    title: "Surface stale review requests",
                    number: 52,
                    url: URL(string: "https://github.com/mergehawk-labs/review-router/pull/52")!,
                    repo: "mergehawk-labs/review-router",
                    ciState: .failing,
                    reviewDecision: .changesRequested,
                    commentCount: 8,
                    reviewCount: 3,
                    reviewRequestKind: .directAndTeam,
                    isMine: false,
                    author: "backend-mateo",
                    headRefName: "MER-41-stale-review-alerts",
                    mergeable: .conflicting,
                    draft: false,
                    createdAt: Date(timeIntervalSince1970: 1_777_790_000),
                    updatedAt: Date(timeIntervalSince1970: 1_777_809_000)
                )
            ]
        ]
    }

    public func fetchPullRequests(login: String) async throws -> [PullRequest] {
        let snapshot = snapshots[min(index, snapshots.count - 1)]
        index += 1
        return snapshot
    }

    public static var notificationTypeFixturePullRequestNotifications: [PullRequestNotification] {
        [
            PullRequestNotification(
                event: PullRequestEvent(type: .newComment, prId: notificationFixtureCommentPullRequest.id, count: 1),
                pullRequest: notificationFixtureCommentPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_809_600)
            ),
            PullRequestNotification(
                event: PullRequestEvent(type: .reviewApproved, prId: notificationFixtureApprovalPullRequest.id),
                pullRequest: notificationFixtureApprovalPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_806_000)
            ),
            PullRequestNotification(
                event: PullRequestEvent(type: .reviewCommented, prId: notificationFixtureReviewCommentPullRequest.id),
                pullRequest: notificationFixtureReviewCommentPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_802_400)
            ),
            PullRequestNotification(
                event: PullRequestEvent(
                    type: .changesRequested,
                    prId: notificationFixtureChangesRequestedPullRequest.id
                ),
                pullRequest: notificationFixtureChangesRequestedPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_798_800)
            ),
            PullRequestNotification(
                event: PullRequestEvent(type: .ciFailed, prId: notificationFixtureCIPullRequest.id),
                pullRequest: notificationFixtureCIPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_795_200)
            )
        ]
    }

    private static let notificationFixtureCommentPullRequest = PullRequest(
        id: "PR_NOTIFICATION_COMMENT",
        title: "Add inline notification grouping",
        number: 41,
        url: URL(string: "https://github.com/example/mergehawk/pull/41")!,
        repo: "example/mergehawk",
        ciState: .passing,
        reviewDecision: .reviewRequired,
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
        reviewDecision: .reviewRequired,
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
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        isMine: true,
        author: "agent-fixture",
        headRefName: "release-signing",
        mergeable: .unknown,
        draft: false,
        updatedAt: Date(timeIntervalSince1970: 1_777_795_200)
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
                RepositorySource(owner: "billing-platform-experiments", name: "customer-dashboard"),
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
