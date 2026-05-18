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

    public init() {
        self.snapshots = [
            [
                PullRequest(
                    id: "PR_1",
                    title: "Add OAuth device flow",
                    number: 14,
                    url: URL(string: "https://github.com/example/mergehawk/pull/14")!,
                    repo: "example/mergehawk",
                    ciState: .passing,
                    reviewDecision: .reviewRequired,
                    commentCount: 2,
                    reviewCount: 0,
                    isMine: true,
                    author: "rw",
                    mergeable: .mergeable,
                    draft: true
                ),
                PullRequest(
                    id: "PR_2",
                    title: "Refactor notification settings",
                    number: 27,
                    url: URL(string: "https://github.com/example/app/pull/27")!,
                    repo: "example/app",
                    ciState: .pending,
                    reviewDecision: .approved,
                    commentCount: 4,
                    reviewCount: 2,
                    reviewRequestKind: .direct,
                    isMine: false,
                    author: "teammate",
                    mergeable: .unknown,
                    draft: false
                ),
                PullRequest(
                    id: "PR_3",
                    title: "Tighten billing retry copy",
                    number: 31,
                    url: URL(string: "https://github.com/example/web/pull/31")!,
                    repo: "example/web",
                    ciState: .passing,
                    reviewDecision: .reviewRequired,
                    commentCount: 1,
                    reviewCount: 0,
                    reviewRequestKind: .team,
                    isMine: false,
                    author: "designer",
                    mergeable: .mergeable,
                    draft: true
                )
            ],
            [
                PullRequest(
                    id: "PR_1",
                    title: "Add OAuth device flow",
                    number: 14,
                    url: URL(string: "https://github.com/example/mergehawk/pull/14")!,
                    repo: "example/mergehawk",
                    ciState: .failing,
                    reviewDecision: .reviewRequired,
                    commentCount: 3,
                    reviewCount: 0,
                    isMine: true,
                    author: "rw",
                    mergeable: .mergeable,
                    draft: true
                ),
                PullRequest(
                    id: "PR_2",
                    title: "Refactor notification settings",
                    number: 27,
                    url: URL(string: "https://github.com/example/app/pull/27")!,
                    repo: "example/app",
                    ciState: .passing,
                    reviewDecision: .approved,
                    commentCount: 4,
                    reviewCount: 2,
                    reviewRequestKind: .direct,
                    isMine: false,
                    author: "teammate",
                    mergeable: .mergeable,
                    draft: false
                ),
                PullRequest(
                    id: "PR_3",
                    title: "Tighten billing retry copy",
                    number: 31,
                    url: URL(string: "https://github.com/example/web/pull/31")!,
                    repo: "example/web",
                    ciState: .passing,
                    reviewDecision: .reviewRequired,
                    commentCount: 1,
                    reviewCount: 0,
                    reviewRequestKind: .team,
                    isMine: false,
                    author: "designer",
                    mergeable: .mergeable,
                    draft: true
                )
            ]
        ]
    }

    public func fetchPullRequests(login: String) async throws -> [PullRequest] {
        let snapshot = snapshots[min(index, snapshots.count - 1)]
        index += 1
        return snapshot
    }
}

extension MockPullRequestSource: SourceCatalogProviding {
    public func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        mockSourceCatalog(accountLogin: accountLogin)
    }

    public func mockSourceCatalog(accountLogin: String?) -> SourceCatalog {
        SourceCatalog(
            repositories: [
                RepositorySource(owner: "agent-fixture", name: "sandbox"),
                RepositorySource(owner: "example", name: "app"),
                RepositorySource(owner: "example", name: "mergehawk"),
                RepositorySource(owner: "example", name: "web")
            ],
            accountLogin: accountLogin
        )
    }
}

extension MockPullRequestSource: GitHubInboxProviding {
    public func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult {
        GitHubInboxFetchResult(
            notifications: [
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
            ],
            metadata: GitHubInboxSyncMetadata(
                eTag: metadata.eTag,
                lastFetchedAt: Date(),
                pollIntervalSeconds: 60
            )
        )
    }

    public func markInboxThreadRead(threadId: String) async throws {}
}
