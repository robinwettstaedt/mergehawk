import Foundation
import mergehawkcore

@main
struct Runner {
    static func main() async throws {
        try testFirstSyncBaselinesWithoutEvents()
        try testDetectsNewActivityAndAuthoredPRStateTransitions()
        try testPreferencesFilterEvents()
        try await testSyncBaselinesFirstFetchAndReportsPRs()
        try await testSyncEmitsFilteredEventsAfterBaseline()
        try await testEmptyPullRequestSourceReportsNoneAndNoPullRequests()
        try testNormalizesPullRequestSearchNodes()
        try testNormalizesReviewRequestKinds()
        try testBuildsThreePullRequestSearchQueries()
        try testInMemoryTokenStoreHandlesMissingStoreLoadAndClear()
        print("mergehawkcore tests passed")
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

    private static func testEmptyPullRequestSourceReportsNoneAndNoPullRequests() async throws {
        let source = EmptyPullRequestSource()
        let engine = SyncEngine(
            source: source,
            loginProvider: { "rw" },
            accountProvider: { nil },
            authStatusProvider: { .signedOut }
        )

        let result = try await engine.sync()

        try expect(result.source == .none)
        try expect(result.authStatus == .signedOut)
        try expect(result.account?.login == "rw")
        try expect(result.pullRequests.isEmpty)
        try expect(result.events.isEmpty)
    }

    private static func testNormalizesPullRequestSearchNodes() throws {
        let node = GitHubPullRequestNode(
            id: "PR_1",
            title: "Ship dashboard",
            number: 12,
            url: "https://github.com/acme/mergehawk/pull/12",
            createdAt: "2026-05-01T12:00:00Z",
            updatedAt: "2026-05-02T12:00:00Z",
            isDraft: false,
            mergeable: "MERGEABLE",
            reviewDecision: "REVIEW_REQUIRED",
            comments: .init(totalCount: 2),
            reviews: .init(totalCount: 1),
            reviewThreads: .init(nodes: [.init(isResolved: true), .init(isResolved: false)]),
            repository: .init(nameWithOwner: "acme/mergehawk"),
            commits: .init(nodes: [.init(commit: .init(statusCheckRollup: .init(state: "FAILURE")))]),
            author: .init(login: "rw")
        )

        try expect(GitHubPullRequestNormalizer.normalize(node, login: "rw") == PullRequest(
            id: "PR_1",
            title: "Ship dashboard",
            number: 12,
            url: URL(string: "https://github.com/acme/mergehawk/pull/12")!,
            repo: "acme/mergehawk",
            ciState: .failing,
            reviewDecision: .reviewRequired,
            commentCount: 3,
            reviewCount: 1,
            isMine: true,
            author: "rw",
            mergeable: .mergeable,
            draft: false,
            createdAt: Date(timeIntervalSince1970: 1_777_636_800),
            updatedAt: Date(timeIntervalSince1970: 1_777_723_200)
        ))
    }

    private static func testBuildsThreePullRequestSearchQueries() throws {
        try expect(GitHubClient.pullRequestSearchQueries(login: "rw") == [
            "is:open is:pr author:rw",
            "is:open is:pr assignee:rw",
            "is:open is:pr review-requested:rw"
        ])
    }

    private static func testNormalizesReviewRequestKinds() throws {
        let directNode = GitHubPullRequestNode.reviewRequestFixture(reviewers: [
            .init(typeName: "User", login: "rw")
        ])
        let teamNode = GitHubPullRequestNode.reviewRequestFixture(reviewers: [
            .init(typeName: "Team", slug: "developers", organization: .init(login: "acme"))
        ])
        let directAndTeamNode = GitHubPullRequestNode.reviewRequestFixture(reviewers: [
            .init(typeName: "User", login: "rw"),
            .init(typeName: "Team", slug: "developers", organization: .init(login: "acme"))
        ])
        let noneNode = GitHubPullRequestNode.reviewRequestFixture(reviewers: [])

        try expect(
            GitHubPullRequestNormalizer.normalize(
                directNode,
                login: "rw",
                isReviewRequestResult: true
            ).reviewRequestKind == .direct
        )
        try expect(
            GitHubPullRequestNormalizer.normalize(
                teamNode,
                login: "rw",
                isReviewRequestResult: true
            ).reviewRequestKind == .team
        )
        try expect(
            GitHubPullRequestNormalizer.normalize(
                directAndTeamNode,
                login: "rw",
                isReviewRequestResult: true
            ).reviewRequestKind == .directAndTeam
        )
        try expect(
            GitHubPullRequestNormalizer.normalize(
                noneNode,
                login: "rw"
            ).reviewRequestKind == .none
        )
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

private extension GitHubPullRequestNode {
    static func reviewRequestFixture(reviewers: [RequestedReviewer]) -> GitHubPullRequestNode {
        GitHubPullRequestNode(
            id: "PR_REVIEW",
            title: "Review requested",
            number: 21,
            url: "https://github.com/acme/mergehawk/pull/21",
            createdAt: "2026-05-01T12:00:00Z",
            updatedAt: "2026-05-02T12:00:00Z",
            isDraft: false,
            mergeable: "MERGEABLE",
            reviewDecision: "REVIEW_REQUIRED",
            comments: .init(totalCount: 0),
            reviews: .init(totalCount: 0),
            reviewThreads: .init(nodes: []),
            reviewRequests: .init(nodes: reviewers.map { .init(requestedReviewer: $0) }),
            repository: .init(nameWithOwner: "acme/mergehawk"),
            commits: .init(nodes: []),
            author: .init(login: "teammate")
        )
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
        url: URL = URL(string: "https://github.com/acme/mergehawk/pull/1")!,
        repo: String = "acme/mergehawk",
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
