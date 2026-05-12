import Foundation

public protocol PullRequestSource: AnyObject {
    var sourceKind: DashboardSource { get }
    func fetchPullRequests(login: String) async throws -> [PullRequest]
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
                    draft: false
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
                    draft: false
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
                    draft: false
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
                    draft: false
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
