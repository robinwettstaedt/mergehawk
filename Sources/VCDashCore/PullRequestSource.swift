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
                    url: URL(string: "https://github.com/example/vc-dash/pull/14")!,
                    repo: "example/vc-dash",
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
                    isMine: false,
                    author: "teammate",
                    mergeable: .unknown,
                    draft: false
                )
            ],
            [
                PullRequest(
                    id: "PR_1",
                    title: "Add OAuth device flow",
                    number: 14,
                    url: URL(string: "https://github.com/example/vc-dash/pull/14")!,
                    repo: "example/vc-dash",
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
                    isMine: false,
                    author: "teammate",
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
