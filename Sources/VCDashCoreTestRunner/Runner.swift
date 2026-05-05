import Foundation
import VCDashCore

@main
struct Runner {
    static func main() async throws {
        try testFirstSyncBaselinesWithoutEvents()
        try testDetectsNewActivityAndAuthoredPRStateTransitions()
        try testPreferencesFilterEvents()
        try await testSyncBaselinesFirstFetchAndReportsPRs()
        try await testSyncEmitsFilteredEventsAfterBaseline()
        try testNormalizesPullRequestSearchNodes()
        try testBuildsThreePullRequestSearchQueries()
        try testInMemoryTokenStoreHandlesMissingStoreLoadAndClear()
        print("VCDashCore tests passed")
    }

    private static func testFirstSyncBaselinesWithoutEvents() throws {
        let current = PullRequest.fixture(
            id: "PR_1",
            ciState: .failing,
            reviewDecision: .changesRequested,
            commentCount: 3,
            reviewCount: 1,
            isMine: true
        )

        try expect(PRActivityDetector.detect(previous: nil, current: current) == [])
    }

    private static func testDetectsNewActivityAndAuthoredPRStateTransitions() throws {
        let previous = PullRequest.fixture(
            id: "PR_1",
            ciState: .passing,
            reviewDecision: .reviewRequired,
            commentCount: 1,
            reviewCount: 0,
            isMine: true
        )
        let current = PullRequest.fixture(
            id: "PR_1",
            ciState: .failing,
            reviewDecision: .changesRequested,
            commentCount: 2,
            reviewCount: 1,
            isMine: true
        )

        try expect(
            PRActivityDetector.detect(previous: previous, current: current).map(\.type)
                == [.newComment, .newReview, .ciFailed, .changesRequested]
        )
    }

    private static func testPreferencesFilterEvents() throws {
        let preferences = NotificationPreferences(
            newComment: true,
            newReview: false,
            ciFailed: true,
            changesRequested: false
        )
        let events = [
            PullRequestEvent(type: .newComment, prId: "1", count: 1),
            PullRequestEvent(type: .newReview, prId: "1", count: 1),
            PullRequestEvent(type: .ciFailed, prId: "1"),
            PullRequestEvent(type: .changesRequested, prId: "1")
        ]

        try expect(PRActivityDetector.filter(events, preferences: preferences).map(\.type) == [.newComment, .ciFailed])
    }

    private static func testSyncBaselinesFirstFetchAndReportsPRs() async throws {
        let source = SequencePullRequestSource(snapshots: [[.fixture(id: "1", isMine: true)]])
        let engine = SyncEngine(source: source, loginProvider: { "rw" })

        let result = try await engine.sync()

        try expect(result.pullRequests.count == 1)
        try expect(result.events == [])
        try expect(result.source == .mock)
        try expect(result.account?.login == "rw")
    }

    private static func testSyncEmitsFilteredEventsAfterBaseline() async throws {
        let source = SequencePullRequestSource(snapshots: [
            [.fixture(id: "1", ciState: .passing, commentCount: 0, isMine: true)],
            [.fixture(id: "1", ciState: .failing, commentCount: 1, isMine: true)]
        ])
        let engine = SyncEngine(source: source, loginProvider: { "rw" })

        _ = try await engine.sync()
        let result = try await engine.sync()

        try expect(result.events.map(\.type) == [.newComment, .ciFailed])
    }

    private static func testNormalizesPullRequestSearchNodes() throws {
        let node = GitHubPullRequestNode(
            id: "PR_1",
            title: "Ship dashboard",
            number: 12,
            url: "https://github.com/acme/vc-dash/pull/12",
            isDraft: false,
            mergeable: "MERGEABLE",
            reviewDecision: "REVIEW_REQUIRED",
            comments: .init(totalCount: 2),
            reviews: .init(totalCount: 1),
            reviewThreads: .init(nodes: [.init(isResolved: true), .init(isResolved: false)]),
            repository: .init(nameWithOwner: "acme/vc-dash"),
            commits: .init(nodes: [.init(commit: .init(statusCheckRollup: .init(state: "FAILURE")))]),
            author: .init(login: "rw")
        )

        try expect(GitHubPullRequestNormalizer.normalize(node, login: "rw") == PullRequest(
            id: "PR_1",
            title: "Ship dashboard",
            number: 12,
            url: URL(string: "https://github.com/acme/vc-dash/pull/12")!,
            repo: "acme/vc-dash",
            ciState: .failing,
            reviewDecision: .reviewRequired,
            commentCount: 3,
            reviewCount: 1,
            isMine: true,
            author: "rw",
            mergeable: .mergeable,
            draft: false
        ))
    }

    private static func testBuildsThreePullRequestSearchQueries() throws {
        try expect(GitHubClient.pullRequestSearchQueries(login: "rw") == [
            "is:open is:pr author:rw",
            "is:open is:pr assignee:rw",
            "is:open is:pr user-review-requested:rw"
        ])
    }

    private static func testInMemoryTokenStoreHandlesMissingStoreLoadAndClear() throws {
        let store = InMemoryTokenStore()

        let missing = try store.load()
        try expect(missing == nil)
        try store.store("github_pat_test")
        let stored = try store.load()
        try expect(stored == "github_pat_test")
        try store.clear()
        let cleared = try store.load()
        try expect(cleared == nil)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) throws {
        if !condition() {
            throw TestFailure(file: "\(file)", line: line)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let file: String
    let line: UInt

    var description: String {
        "Test failed at \(file):\(line)"
    }
}

private final class SequencePullRequestSource: PullRequestSource {
    let sourceKind: DashboardSource = .mock
    private var snapshots: [[PullRequest]]

    init(snapshots: [[PullRequest]]) {
        self.snapshots = snapshots
    }

    func fetchPullRequests(login: String) async throws -> [PullRequest] {
        snapshots.isEmpty ? [] : snapshots.removeFirst()
    }
}

private extension PullRequest {
    static func fixture(
        id: String = "PR_1",
        title: String = "Build tray app",
        number: Int = 1,
        url: URL = URL(string: "https://github.com/acme/vc-dash/pull/1")!,
        repo: String = "acme/vc-dash",
        ciState: CIState = .passing,
        reviewDecision: ReviewDecision = .reviewRequired,
        commentCount: Int = 0,
        reviewCount: Int = 0,
        isMine: Bool = false,
        author: String = "rw",
        mergeable: MergeableState = .unknown,
        draft: Bool = false
    ) -> PullRequest {
        PullRequest(
            id: id,
            title: title,
            number: number,
            url: url,
            repo: repo,
            ciState: ciState,
            reviewDecision: reviewDecision,
            commentCount: commentCount,
            reviewCount: reviewCount,
            isMine: isMine,
            author: author,
            mergeable: mergeable,
            draft: draft
        )
    }
}
