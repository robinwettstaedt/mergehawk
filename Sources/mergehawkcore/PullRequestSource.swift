import Foundation

public func isGitHubReadAuthenticationError(_ error: Error) -> Bool {
    guard let readError = error as? GitHubReadError else { return false }
    return readError == .authentication
}

public func gitHubReadRateLimitRetryDate(_ error: Error) -> Date? {
    guard let readError = error as? GitHubReadError,
          case .rateLimited(let retryAt) = readError else { return nil }
    return retryAt
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

public typealias GitHubProviding = CompletePullRequestFetching
    & SourceCatalogProviding
    & GitHubAppInstallationProviding
    & GitHubViewerProviding

public final class EmptyPullRequestSource {
    public let sourceKind: DashboardSource = .none

    public init() {}

}

public enum MockPullRequestScenario: String, CaseIterable, Sendable {
    case standard
    case botNotifications = "bot-notifications"
    case commentNotifications = "comment-notifications"
    case delayedRefresh = "delayed-refresh"
    case refreshFailure = "refresh-failure"
    case mergedFinalActivity = "merged-final-activity"
    case quietAccessLoss = "quiet-access-loss"
    case longLists = "long-lists"
    case newReviewRequest = "new-review-request"
    case reviewTeams = "review-teams"
}

public enum MockPullRequestError: Error, LocalizedError, Equatable, Sendable {
    case refreshFailed

    public var errorDescription: String? {
        "The mock pull request refresh failed."
    }
}

public final class MockPullRequestSource {
    public let sourceKind: DashboardSource = .mock
    private var index = 0
    private let snapshots: [[PullRequest]]
    private let scenario: MockPullRequestScenario

    public init(
        showsNotificationTypeFixtures: Bool = false,
        referenceDate: Date = Date(),
        scenario: MockPullRequestScenario = .standard
    ) {
        self.scenario = scenario
        let minute: TimeInterval = 60
        let hour = 60 * minute
        let day = 24 * hour
        func ago(_ interval: TimeInterval) -> Date { referenceDate.addingTimeInterval(-interval) }

        self.snapshots = [
            [
                PullRequest(
                    id: "PR_1",
                    title: "feat(MER-14): Add OAuth device flow",
                    number: 14,
                    url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/14")!,
                    repo: "mergehawk-labs/mergehawk",
                    ciState: .passing,
                    reviewDecision: .reviewRequired,
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
                    // Reviewed, but GitHub no longer counts the approvals.
                    reviewDecision: .reviewRequired,
                    additions: 12_345,
                    deletions: 6_789,
                    commentCount: 5,
                    reviewCount: 2,
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
                    reviewDecision: .reviewRequired,
                    additions: 1_200_000,
                    deletions: 0,
                    commentCount: 1,
                    reviewCount: 0,
                    reviewRequestKind: .team,
                    requestedTeams: [Self.billingReviewersTeam],
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
                    requestedTeams: [Self.reviewersTeam],
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
                    reviewDecision: .reviewRequired,
                    additions: 0,
                    deletions: 0,
                    commentCount: 3,
                    recentCommentActivities: [
                        PullRequestCommentActivity(
                            id: "PR_1_COMMENT_NEW",
                            url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/14#issuecomment-PR_1_COMMENT_NEW")!,
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
                    // Reviewed, but GitHub no longer counts the approvals.
                    reviewDecision: .reviewRequired,
                    additions: 12_345,
                    deletions: 6_789,
                    commentCount: 5,
                    reviewCount: 2,
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
                    reviewDecision: .reviewRequired,
                    additions: 1_200_000,
                    deletions: 0,
                    commentCount: 1,
                    reviewCount: 0,
                    reviewRequestKind: .team,
                    requestedTeams: [Self.billingReviewersTeam],
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
                    requestedTeams: [Self.reviewersTeam],
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

    /// The active pull requests the scenario's first refresh returns.
    public var firstRefreshPullRequests: [PullRequest] {
        switch scenario {
        case .standard, .delayedRefresh:
            snapshots[0]
        case .botNotifications:
            Self.botNotificationPullRequests(includesUpdates: false)
        case .commentNotifications:
            Self.commentNotificationPullRequests(stage: 0)
        case .longLists:
            Self.longListPullRequests(stage: 0)
        case .newReviewRequest:
            Self.newReviewRequestPullRequests(stage: 0)
        case .reviewTeams:
            Self.reviewTeamPullRequests(stage: 0)
        case .refreshFailure, .mergedFinalActivity, .quietAccessLoss:
            [Self.scenarioBaselinePullRequest]
        }
    }

    /// The viewer's teams every refresh of this scenario returns.
    public var viewerTeams: [ViewerTeam] {
        switch scenario {
        case .reviewTeams:
            Self.reviewTeamViewerTeams
        case .standard, .botNotifications, .commentNotifications, .delayedRefresh, .refreshFailure,
             .mergedFinalActivity, .quietAccessLoss, .longLists, .newReviewRequest:
            Self.standardViewerTeams
        }
    }

    static let reviewersTeam = TeamReference(id: "T_MOCK_REVIEWERS", organization: "mergehawk-labs", slug: "reviewers")
    static let billingReviewersTeam = TeamReference(
        id: "T_MOCK_BILLING_REVIEWERS",
        organization: "billing-platform-experiments",
        slug: "billing-reviewers"
    )
    static let standardViewerTeams = [ViewerTeam(team: billingReviewersTeam), ViewerTeam(team: reviewersTeam)]

    static let engineeringTeam = TeamReference(id: "T_MOCK_ENGINEERING", organization: "mergehawk-labs", slug: "engineering")
    static let developersTeam = TeamReference(id: "T_MOCK_DEVELOPERS", organization: "mergehawk-labs", slug: "developers")
    static let plmTeam = TeamReference(id: "T_MOCK_PLM", organization: "mergehawk-labs", slug: "plm-team")
    static let secretSquadTeam = TeamReference(id: "T_MOCK_SECRET_SQUAD", organization: "mergehawk-labs", slug: "secret-squad")
    static let securityTeam = TeamReference(id: "T_MOCK_SECURITY", organization: "mergehawk-labs", slug: "security")
    /// `engineering` -> `developers` -> `plm-team`, with the viewer directly in `plm-team` and a secret team.
    static let reviewTeamViewerTeams = [
        ViewerTeam(team: developersTeam, inheritedVia: plmTeam),
        ViewerTeam(team: engineeringTeam, inheritedVia: plmTeam),
        ViewerTeam(team: plmTeam),
        ViewerTeam(team: secretSquadTeam)
    ]

    /// Stage 0 has pull requests requesting each nested team, a team the viewer is not in, and combinations.
    /// Stage 1 adds `plm-team` to the `developers`-only pull request. Later refreshes repeat stage 1.
    private static func reviewTeamPullRequests(stage: Int) -> [PullRequest] {
        let base = Date(timeIntervalSince1970: 1_778_000_000)
        func pullRequest(
            _ id: String, number: Int, title: String, teams: [TeamReference], direct: Bool = false,
            author: String = "platform-nora"
        ) -> PullRequest {
            PullRequest(
                id: id, title: title, number: number,
                url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/\(number)")!,
                repo: "mergehawk-labs/mergehawk", ciState: .passing, reviewDecision: .reviewRequired,
                additions: 24, deletions: 4, commentCount: 0, reviewCount: 0,
                headRefOid: "review-teams-fixture",
                // Like GitHub discovery, the raw team flag only reflects requests to one of the viewer's teams.
                reviewRequestKind: ReviewRequestKind(
                    direct: direct,
                    team: teams.contains { team in reviewTeamViewerTeams.contains { $0.team.id == team.id } }
                ),
                requestedTeams: teams, isMine: false, author: author,
                headRefName: "MER-81-review-teams-\(number)", mergeable: .mergeable, draft: false,
                createdAt: base.addingTimeInterval(-86_400 - Double(number) * 60),
                updatedAt: base.addingTimeInterval(stage >= 1 && number == 101 ? 600 : -Double(number) * 60)
            )
        }
        return [
            pullRequest(
                "PR_TEAMS_DEVELOPERS", number: 101, title: "Ask the broad developers team for review",
                teams: stage >= 1 ? [developersTeam, plmTeam] : [developersTeam]
            ),
            pullRequest("PR_TEAMS_PLM", number: 102, title: "Ask plm-team for review", teams: [plmTeam], author: "backend-mateo"),
            pullRequest(
                "PR_TEAMS_ENGINEERING", number: 103, title: "Ask the engineering org team for review",
                teams: [engineeringTeam], author: "docs-lee"
            ),
            pullRequest(
                "PR_TEAMS_SECURITY", number: 104, title: "Ask the security team for review",
                teams: [securityTeam], author: "frontend-sam"
            ),
            pullRequest(
                "PR_TEAMS_DEVELOPERS_SECURITY", number: 105, title: "Ask developers and security for review",
                teams: [developersTeam, securityTeam], author: "frontend-sam"
            ),
            pullRequest(
                "PR_TEAMS_DEVELOPERS_PLM", number: 106, title: "Ask developers and plm-team for review",
                teams: [developersTeam, plmTeam], author: "design-systems-amy"
            ),
            pullRequest(
                "PR_TEAMS_DIRECT_DEVELOPERS", number: 107, title: "Ask you and developers for review",
                teams: [developersTeam], direct: true, author: "backend-mateo"
            ),
        ]
    }

    private func nextPullRequests() -> [PullRequest] {
        let snapshot = snapshots[min(index, snapshots.count - 1)]
        index += 1
        return snapshot
    }

    private static func botNotificationPullRequests(includesUpdates: Bool) -> [PullRequest] {
        let date = Date(timeIntervalSince1970: 1_777_810_000)
        return [false, true].map { mixed in
            let id = mixed ? "PR_BOT_NOTIFICATIONS_MIXED" : "PR_BOT_NOTIFICATIONS_ONLY"
            let url = URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/\(mixed ? 73 : 72)")!
            var comments: [PullRequestCommentActivity] = []
            var reviews: [PullRequestReview] = []
            if includesUpdates {
                comments = [
                    PullRequestCommentActivity(id: "\(id)_BOT_COMMENT", url: URL(string: "\(url.absoluteString)#issuecomment-\(id)_BOT_COMMENT")!, author: "mergehawk-helper", authorIsBot: true, createdAt: date, source: .pullRequest),
                    PullRequestCommentActivity(id: "\(id)_BOT_THREAD", url: URL(string: "\(url.absoluteString)#discussion_r\(id)_BOT_THREAD")!, author: "mergehawk-helper", authorIsBot: true, createdAt: date.addingTimeInterval(1), source: .reviewThread)
                ]
                reviews = [PullRequestReviewState.commented, .changesRequested, .approved].enumerated().map { index, state in
                    PullRequestReview(id: "\(id)_BOT_REVIEW_\(index)", url: URL(string: "\(url.absoluteString)#pullrequestreview-\(id)_BOT_REVIEW_\(index)")!, state: state, submittedAt: date.addingTimeInterval(Double(index + 2)), author: "mergehawk-helper", authorIsBot: true, hasSummaryText: true)
                }
                if mixed {
                    comments.append(PullRequestCommentActivity(id: "\(id)_HUMAN_COMMENT", url: URL(string: "\(url.absoluteString)#issuecomment-\(id)_HUMAN_COMMENT")!, author: "frontend-sam", authorIsBot: false, createdAt: date.addingTimeInterval(5), source: .pullRequest))
                    reviews.append(PullRequestReview(id: "\(id)_HUMAN_REVIEW", url: URL(string: "\(url.absoluteString)#pullrequestreview-\(id)_HUMAN_REVIEW")!, state: .approved, submittedAt: date.addingTimeInterval(6), author: "platform-nora", authorIsBot: false))
                }
            }
            return PullRequest(
                id: id, title: mixed ? "Review updates from bots and teammates" : "Review updates from bots",
                number: mixed ? 73 : 72,
                url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/\(mixed ? 73 : 72)")!,
                repo: "mergehawk-labs/mergehawk", ciState: .passing, reviewDecision: .approved,
                additions: 72, deletions: 12, commentCount: mixed ? 2 : 1,
                commentActivityCount: comments.count, recentCommentActivities: comments,
                reviewCount: mixed ? 4 : 3, recentReviews: reviews,
                headRefOid: "bot-notification-fixture", isMine: true, author: "agent-fixture",
                headRefName: "MER-72-bot-notifications", mergeable: .mergeable, draft: false,
                createdAt: date.addingTimeInterval(-86_400), updatedAt: date.addingTimeInterval(6)
            )
        }
    }

    /// Stage 0 is the quiet baseline, stage 1 adds new activity for every relationship, and stage 2 edits an
    /// already observed comment to mention the viewer. Later refreshes repeat stage 2 unchanged.
    private static func commentNotificationPullRequests(stage: Int) -> [PullRequest] {
        let base = Date(timeIntervalSince1970: 1_777_820_000)
        func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }
        func url(_ number: Int, _ fragment: String = "") -> URL {
            URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/\(number)\(fragment)")!
        }
        func comment(
            _ id: String, number: Int, author: String, offset: TimeInterval, thread: String? = nil,
            review: String? = nil, updatedOffset: TimeInterval? = nil, mention: Bool = false
        ) -> PullRequestCommentActivity {
            PullRequestCommentActivity(
                id: id,
                url: url(number, thread == nil ? "#issuecomment-\(id)" : "#discussion_r\(id)"),
                author: author,
                authorIsBot: false,
                viewerDidAuthor: author == "agent-fixture",
                createdAt: at(offset),
                source: thread == nil ? .pullRequest : .reviewThread,
                reviewId: review,
                updatedAt: updatedOffset.map(at),
                threadId: thread,
                mentionsViewer: mention
            )
        }
        func review(
            _ id: String, number: Int, state: PullRequestReviewState, offset: TimeInterval, mention: Bool = false
        ) -> PullRequestReview {
            PullRequestReview(
                id: id, url: url(number, "#pullrequestreview-\(id)"), state: state, submittedAt: at(offset),
                author: "platform-nora", authorIsBot: false, hasSummaryText: true, mentionsViewer: mention
            )
        }
        let hasUpdates = stage >= 1
        let editsMention = stage >= 2

        var authoredComments = [comment("COMMENT_AUTHORED_OLD", number: 80, author: "frontend-sam", offset: 10)]
        var authoredReviews: [PullRequestReview] = []
        var assignedComments: [PullRequestCommentActivity] = []
        var directComments = [
            comment("COMMENT_DIRECT_JOINED", number: 82, author: "agent-fixture", offset: 20, thread: "THREAD_DIRECT_JOINED"),
            comment("COMMENT_DIRECT_OLD", number: 82, author: "backend-mateo", offset: 21),
        ]
        var teamComments = [
            comment(
                "COMMENT_TEAM_EDITED", number: 83, author: "docs-lee", offset: 30,
                updatedOffset: editsMention ? 400 : nil, mention: editsMention
            )
        ]
        var teamReviews: [PullRequestReview] = []
        if hasUpdates {
            authoredComments += [
                comment("COMMENT_AUTHORED_NEW", number: 80, author: "frontend-sam", offset: 200),
                comment("INLINE_AUTHORED_1", number: 80, author: "platform-nora", offset: 210, thread: "THREAD_AUTHORED_1", review: "REVIEW_AUTHORED_APPROVAL"),
                comment("INLINE_AUTHORED_2", number: 80, author: "platform-nora", offset: 210, thread: "THREAD_AUTHORED_2", review: "REVIEW_AUTHORED_APPROVAL"),
            ]
            authoredReviews = [review("REVIEW_AUTHORED_APPROVAL", number: 80, state: .approved, offset: 210, mention: true)]
            assignedComments = [comment("COMMENT_ASSIGNED_NEW", number: 81, author: "backend-mateo", offset: 220)]
            directComments += [
                comment("REPLY_DIRECT_JOINED", number: 82, author: "backend-mateo", offset: 230, thread: "THREAD_DIRECT_JOINED"),
                comment("COMMENT_DIRECT_UNRELATED", number: 82, author: "backend-mateo", offset: 231),
                comment("INLINE_DIRECT_MENTION", number: 82, author: "design-systems-amy", offset: 232, thread: "THREAD_DIRECT_OTHER", mention: true),
            ]
            teamComments += [comment("COMMENT_TEAM_UNRELATED", number: 83, author: "docs-lee", offset: 240)]
            teamReviews = [review("REVIEW_TEAM_SUMMARY_MENTION", number: 83, state: .commented, offset: 241, mention: true)]
        }

        func pullRequest(
            _ id: String, number: Int, title: String, comments: [PullRequestCommentActivity],
            reviews: [PullRequestReview] = [], request: ReviewRequestKind = .none, assigned: Bool = false,
            mine: Bool = false
        ) -> PullRequest {
            PullRequest(
                id: id, title: title, number: number, url: url(number), repo: "mergehawk-labs/mergehawk",
                ciState: .passing, reviewDecision: reviews.contains { $0.state == .approved } ? .approved : .reviewRequired,
                additions: 40, deletions: 8, commentCount: 0, commentActivityCount: comments.count,
                recentCommentActivities: comments, reviewCount: reviews.count, recentReviews: reviews,
                headRefOid: "comment-notification-fixture", reviewRequestKind: request,
                requestedTeams: request.includesTeam ? [Self.reviewersTeam] : [], isAssignedToViewer: assigned,
                isMine: mine, author: mine ? "agent-fixture" : "platform-nora",
                headRefName: "MER-73-comment-notifications", mergeable: .mergeable, draft: false,
                createdAt: at(-86_400), updatedAt: at(editsMention ? 400 : hasUpdates ? 241 : 30)
            )
        }
        return [
            pullRequest("PR_COMMENTS_AUTHORED", number: 80, title: "Tailor comment notifications", comments: authoredComments, reviews: authoredReviews, mine: true),
            pullRequest("PR_COMMENTS_ASSIGNED", number: 81, title: "Own the comment settings rollout", comments: assignedComments, assigned: true),
            pullRequest("PR_COMMENTS_DIRECT", number: 82, title: "Review mention parsing", comments: directComments, request: .direct),
            pullRequest("PR_COMMENTS_TEAM", number: 83, title: "Review joined thread detection", comments: teamComments, reviews: teamReviews, request: .team),
        ]
    }

    /// Stage 0 is a quiet baseline of 20 authored and 20 review-request pull requests; stage 1 adds one new human
    /// comment to each. Later refreshes repeat stage 1 unchanged.
    private static func longListPullRequests(stage: Int) -> [PullRequest] {
        let base = Date(timeIntervalSince1970: 1_777_900_000)
        func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }
        let hasUpdates = stage >= 1
        func pullRequest(_ ordinal: Int, mine: Bool) -> PullRequest {
            let number = (mine ? 100 : 200) + ordinal
            let id = "PR_LONG_LIST_\(mine ? "AUTHORED" : "REQUESTED")_\(ordinal)"
            let url = URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/\(number)")!
            let comments = hasUpdates ? [
                PullRequestCommentActivity(
                    id: "\(id)_COMMENT",
                    url: URL(string: "\(url.absoluteString)#issuecomment-\(id)_COMMENT")!,
                    author: "frontend-sam",
                    authorIsBot: false,
                    createdAt: at(TimeInterval(1_000 + number)),
                    source: .pullRequest
                ),
            ] : []
            let request: ReviewRequestKind = mine ? .none : [.none, .direct, .team][ordinal % 3]
            return PullRequest(
                id: id,
                title: mine ? "Refine long list layout step \(ordinal + 1)" : "Review long list layout step \(ordinal + 1)",
                number: number, url: url, repo: "mergehawk-labs/mergehawk",
                ciState: .passing, reviewDecision: .reviewRequired,
                additions: 20 + ordinal, deletions: ordinal, commentCount: 0,
                commentActivityCount: comments.count, recentCommentActivities: comments,
                reviewCount: 0, recentReviews: [],
                headRefOid: "long-list-fixture", reviewRequestKind: request,
                requestedTeams: request.includesTeam ? [Self.reviewersTeam] : [],
                isAssignedToViewer: !mine && ordinal % 3 == 0,
                isMine: mine, author: mine ? "agent-fixture" : "platform-nora",
                headRefName: "MER-76-long-list-\(number)", mergeable: .mergeable, draft: false,
                createdAt: at(TimeInterval(-86_400 - number * 60)),
                updatedAt: at(hasUpdates ? TimeInterval(1_000 + number) : TimeInterval(-number * 60))
            )
        }
        return (0..<20).map { pullRequest($0, mine: true) } + (0..<20).map { pullRequest($0, mine: false) }
    }

    /// Stage 0 is a quiet baseline with one authored pull request. Stage 1 adds newly seen pull requests for every
    /// relationship kind: a direct request with an existing comment and failing CI, an assignment, a team request,
    /// and an assignment with a direct request, plus a newly seen authored one. Later refreshes repeat stage 1.
    private static func newReviewRequestPullRequests(stage: Int) -> [PullRequest] {
        let base = Date(timeIntervalSince1970: 1_777_950_000)
        func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }
        func url(_ number: Int, _ fragment: String = "") -> URL {
            URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/\(number)\(fragment)")!
        }
        func pullRequest(
            _ id: String, number: Int, title: String, ci: CIState = .passing,
            comments: [PullRequestCommentActivity] = [], request: ReviewRequestKind = .none, assigned: Bool = false,
            author: String = "platform-nora", mine: Bool = false
        ) -> PullRequest {
            PullRequest(
                id: id, title: title, number: number, url: url(number), repo: "mergehawk-labs/mergehawk",
                ciState: ci, reviewDecision: .reviewRequired,
                additions: 36, deletions: 6, commentCount: comments.count, commentActivityCount: comments.count,
                recentCommentActivities: comments, reviewCount: 0, recentReviews: [],
                headRefOid: "new-review-request-fixture", reviewRequestKind: request,
                requestedTeams: request.includesTeam ? [Self.reviewersTeam] : [], isAssignedToViewer: assigned,
                isMine: mine, author: mine ? "agent-fixture" : author,
                headRefName: "MER-82-new-review-request-\(number)", mergeable: .mergeable, draft: false,
                createdAt: at(-86_400), updatedAt: at(-3_600)
            )
        }
        let baseline = pullRequest("PR_NEW_REQUEST_BASELINE", number: 90, title: "Keep the baseline quiet", mine: true)
        guard stage >= 1 else {
            return [baseline]
        }
        let existingComment = PullRequestCommentActivity(
            id: "COMMENT_NEW_REQUEST_EXISTING",
            url: url(91, "#issuecomment-COMMENT_NEW_REQUEST_EXISTING"),
            author: "backend-mateo",
            authorIsBot: false,
            createdAt: at(-7_200),
            source: .pullRequest
        )
        return [
            baseline,
            pullRequest(
                "PR_NEW_REQUEST_DIRECT", number: 91, title: "Notify for newly requested reviews", ci: .failing,
                comments: [existingComment], request: .direct
            ),
            pullRequest("PR_NEW_REQUEST_AUTHORED", number: 92, title: "Open a follow-up pull request", mine: true),
            pullRequest(
                "PR_NEW_REQUEST_ASSIGNED", number: 93, title: "Show assignments on newly seen pull requests",
                assigned: true, author: "backend-mateo"
            ),
            pullRequest(
                "PR_NEW_REQUEST_TEAM", number: 94, title: "Show team review requests on newly seen pull requests",
                request: .team, author: "docs-lee"
            ),
            pullRequest(
                "PR_NEW_REQUEST_COMBINED", number: 95,
                title: "Combine an assignment and a review request on a newly seen pull request",
                request: .direct, assigned: true, author: "design-systems-amy"
            ),
        ]
    }

    private static let scenarioBaselinePullRequest = PullRequest(
        id: "PR_SCENARIO",
        title: "Preserve final pull request activity",
        number: 88,
        url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/88")!,
        repo: "mergehawk-labs/mergehawk",
        ciState: .passing,
        reviewDecision: .reviewRequired,
        additions: 120,
        deletions: 18,
        commentCount: 0,
        commentActivityCount: 0,
        recentCommentActivities: [],
        reviewCount: 0,
        recentReviews: [],
        headRefOid: "scenario-baseline",
        isMine: true,
        author: "agent-fixture",
        headRefName: "MER-66-final-activity",
        mergeable: .mergeable,
        draft: false,
        createdAt: Date(timeIntervalSince1970: 1_777_700_000),
        updatedAt: Date(timeIntervalSince1970: 1_777_800_000)
    )

    private static let scenarioFinalPullRequest = PullRequest(
        id: scenarioBaselinePullRequest.id,
        title: scenarioBaselinePullRequest.title,
        number: scenarioBaselinePullRequest.number,
        url: scenarioBaselinePullRequest.url,
        repo: scenarioBaselinePullRequest.repo,
        ciState: .passing,
        reviewDecision: .approved,
        additions: scenarioBaselinePullRequest.additions,
        deletions: scenarioBaselinePullRequest.deletions,
        commentCount: 0,
        commentActivityCount: 1,
        recentCommentActivities: [
            PullRequestCommentActivity(
                id: "PR_SCENARIO_FINAL_COMMENT",
                url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/88#issuecomment-PR_SCENARIO_FINAL_COMMENT")!,
                author: "frontend-sam",
                createdAt: Date(timeIntervalSince1970: 1_777_810_000),
                source: .pullRequest
            )
        ],
        reviewCount: 1,
        recentReviews: [
            PullRequestReview(
                id: "PR_SCENARIO_FINAL_REVIEW",
                url: URL(string: "https://github.com/mergehawk-labs/mergehawk/pull/88#pullrequestreview-PR_SCENARIO_FINAL_REVIEW")!,
                state: .approved,
                submittedAt: Date(timeIntervalSince1970: 1_777_811_000),
                author: "platform-nora"
            )
        ],
        headRefOid: "scenario-final",
        isMine: true,
        author: "agent-fixture",
        headRefName: "MER-66-final-activity",
        mergeable: .mergeable,
        draft: false,
        createdAt: scenarioBaselinePullRequest.createdAt,
        updatedAt: Date(timeIntervalSince1970: 1_777_812_000)
    )

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
                    activityId: "PR_NOTIFICATION_COMMENT_ACTIVITY",
                    destinationURL: URL(string: "https://github.com/example/mergehawk/pull/41#issuecomment-PR_NOTIFICATION_COMMENT_ACTIVITY")!
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
                    activityId: "PR_NOTIFICATION_APPROVAL_REVIEW",
                    destinationURL: URL(string: "https://github.com/example/app/pull/42#pullrequestreview-PR_NOTIFICATION_APPROVAL_REVIEW")!
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
                    activityId: "PR_NOTIFICATION_REVIEW_COMMENT",
                    destinationURL: URL(string: "https://github.com/example/docs/pull/43#discussion_rPR_NOTIFICATION_REVIEW_COMMENT")!
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
                    activityId: "PR_NOTIFICATION_CHANGES_REVIEW",
                    destinationURL: URL(string: "https://github.com/enterprise-billing-platform-engineering/billing-platform-customer-notification-preferences-and-retry-scheduling-service-for-enterprise-plans-and-regional-invoicing-workflows/pull/1284#pullrequestreview-PR_NOTIFICATION_CHANGES_REVIEW")!
                ),
                pullRequest: notificationFixtureChangesRequestedPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_798_800)
            ),
            PullRequestNotification(
                event: PullRequestEvent(type: .ciFailed, prId: notificationFixtureCIPullRequest.id),
                pullRequest: notificationFixtureCIPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_795_200)
            ),
            PullRequestNotification(
                event: PullRequestEvent(
                    type: .newReview,
                    prId: notificationFixtureLegacyReviewPullRequest.id,
                    count: 1,
                    actorLogin: "qa-rin"
                ),
                pullRequest: notificationFixtureLegacyReviewPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_791_600)
            ),
            PullRequestNotification(
                event: PullRequestEvent(
                    type: .otherCommitAdded,
                    prId: notificationFixtureOtherCommitPullRequest.id,
                    count: 1,
                    actorLogin: "teammate-kai"
                ),
                pullRequest: notificationFixtureOtherCommitPullRequest,
                createdAt: Date(timeIntervalSince1970: 1_777_788_000)
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
        reviewDecision: .reviewRequired,
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
        reviewDecision: .reviewRequired,
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
        title: "Clarify notification grouping copy across the settings pane, onboarding checklist, release notes, and the menu bar tooltip for new users",
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
        number: 1284,
        url: URL(string: "https://github.com/enterprise-billing-platform-engineering/billing-platform-customer-notification-preferences-and-retry-scheduling-service-for-enterprise-plans-and-regional-invoicing-workflows/pull/1284")!,
        repo: "enterprise-billing-platform-engineering/billing-platform-customer-notification-preferences-and-retry-scheduling-service-for-enterprise-plans-and-regional-invoicing-workflows",
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

    private static let notificationFixtureLegacyReviewPullRequest = PullRequest(
        id: "PR_NOTIFICATION_LEGACY_REVIEW",
        title: "Harden rate limit headers",
        number: 46,
        url: URL(string: "https://github.com/example/api/pull/46")!,
        repo: "example/api",
        ciState: .passing,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 1,
        isMine: true,
        author: "agent-fixture",
        headRefName: "rate-limit-headers",
        mergeable: .mergeable,
        draft: false,
        updatedAt: Date(timeIntervalSince1970: 1_777_791_600)
    )

    private static let notificationFixtureOtherCommitPullRequest = PullRequest(
        id: "PR_NOTIFICATION_OTHER_COMMIT",
        title: "Refresh onboarding checklist",
        number: 47,
        url: URL(string: "https://github.com/example/app/pull/47")!,
        repo: "example/app",
        ciState: .pending,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        isMine: true,
        author: "agent-fixture",
        headRefName: "onboarding-checklist",
        mergeable: .mergeable,
        draft: false,
        updatedAt: Date(timeIntervalSince1970: 1_777_788_000)
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

extension EmptyPullRequestSource: CompletePullRequestFetching {
    public func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        CompletePullRequestFetchResult(activePullRequests: [])
    }
}

extension MockPullRequestSource: CompletePullRequestFetching {
    public func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        let result = try fetchScenarioPullRequests(previousState: previousState)
        return CompletePullRequestFetchResult(
            activePullRequests: result.activePullRequests,
            retiringPullRequests: result.retiringPullRequests,
            quietlyRetiredPullRequestIDs: result.quietlyRetiredPullRequestIDs,
            viewerTeams: viewerTeams
        )
    }

    private func fetchScenarioPullRequests(
        previousState: PullRequestSyncState?
    ) throws -> CompletePullRequestFetchResult {
        switch scenario {
        case .reviewTeams:
            let stage = min(index, 1)
            index += 1
            return CompletePullRequestFetchResult(activePullRequests: Self.reviewTeamPullRequests(stage: stage))
        case .botNotifications:
            let hasBaseline = Self.botNotificationPullRequests(includesUpdates: false).contains {
                previousState?.processedActivityByPullRequestID[$0.id] != nil
            }
            return CompletePullRequestFetchResult(
                activePullRequests: Self.botNotificationPullRequests(includesUpdates: hasBaseline)
            )
        case .commentNotifications:
            let stage = min(index, 2)
            index += 1
            return CompletePullRequestFetchResult(activePullRequests: Self.commentNotificationPullRequests(stage: stage))
        case .longLists:
            let stage = min(index, 1)
            index += 1
            return CompletePullRequestFetchResult(activePullRequests: Self.longListPullRequests(stage: stage))
        case .newReviewRequest:
            let stage = min(index, 1)
            index += 1
            return CompletePullRequestFetchResult(activePullRequests: Self.newReviewRequestPullRequests(stage: stage))
        case .standard, .delayedRefresh:
            return CompletePullRequestFetchResult(activePullRequests: nextPullRequests())
        case .refreshFailure:
            guard index > 0 else {
                index += 1
                return CompletePullRequestFetchResult(activePullRequests: [Self.scenarioBaselinePullRequest])
            }
            throw MockPullRequestError.refreshFailed
        case .mergedFinalActivity:
            guard index > 0 else {
                index += 1
                return CompletePullRequestFetchResult(activePullRequests: [Self.scenarioBaselinePullRequest])
            }
            return CompletePullRequestFetchResult(
                activePullRequests: [],
                retiringPullRequests: [Self.scenarioFinalPullRequest]
            )
        case .quietAccessLoss:
            guard index > 0 else {
                index += 1
                return CompletePullRequestFetchResult(activePullRequests: [Self.scenarioBaselinePullRequest])
            }
            return CompletePullRequestFetchResult(
                activePullRequests: [],
                quietlyRetiredPullRequestIDs: [Self.scenarioBaselinePullRequest.id]
            )
        }
    }
}
