@testable import mergehawkcore
import Foundation
import XCTest

final class SyncEngineTests: XCTestCase {
    func testFirstObservationBaselinesQuietlyAndNextObservationEmitsEveryUnseenIDOnce() async throws {
        let baselinePR = Self.pullRequest(
            comments: (0..<12).map { Self.comment("C\($0)") },
            reviews: (0..<12).map { Self.review("R\($0)") }
        )
        let engine = Self.engine()
        let baseline = try await engine.prepare(
            previousState: nil,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [baselinePR])
        )
        XCTAssertTrue(baseline.events.isEmpty)
        XCTAssertEqual(baseline.processedActivityByPullRequestID[baselinePR.id]?.commentIDs.count, 12)
        XCTAssertEqual(baseline.processedActivityByPullRequestID[baselinePR.id]?.submittedReviewIDs.count, 12)

        let nextPR = Self.pullRequest(
            comments: baselinePR.recentCommentActivities + (12..<24).map { Self.comment("C\($0)") },
            reviews: baselinePR.recentReviews + (12..<24).map { Self.review("R\($0)") }
        )
        let previous = Self.state(from: baseline)
        let next = try await engine.prepare(
            previousState: previous,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [nextPR])
        )

        XCTAssertEqual(next.events.count, 24)
        XCTAssertEqual(Set(next.events.compactMap { $0.event.activityId }).count, 24)
        let replay = try await engine.prepare(
            previousState: Self.state(from: next),
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [nextPR])
        )
        XCTAssertTrue(replay.events.isEmpty)
    }

    func testEqualReviewCountPendingToSubmittedStillEmitsReview() async throws {
        let previousPR = Self.pullRequest(reviewCount: 1)
        let previous = PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: Self.dashboard([previousPR]),
            processedActivityByPullRequestID: [
                previousPR.id: ProcessedPullRequestActivity(pullRequestID: previousPR.id)
            ]
        )
        let current = Self.pullRequest(reviewCount: 1, reviews: [Self.review("PENDING_BECAME_SUBMITTED")])

        let prepared = try await Self.engine().prepare(
            previousState: previous,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [current])
        )

        XCTAssertEqual(prepared.events.map(\.event.type), [.reviewApproved])
        XCTAssertEqual(prepared.events.first?.event.activityId, "PENDING_BECAME_SUBMITTED")
    }

    func testSelfAuthoredActivityStaysSuppressedWhileDecisionKeepsChildComments() async throws {
        let current = Self.pullRequest(
            comments: [
                Self.comment("CHILD", reviewID: "REVIEW"),
                Self.comment("UNRELATED"),
                Self.comment("SELF", viewerDidAuthor: true)
            ],
            reviews: [Self.review("REVIEW")]
        )
        let previous = PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: Self.dashboard([Self.pullRequest()]),
            processedActivityByPullRequestID: [
                current.id: ProcessedPullRequestActivity(pullRequestID: current.id)
            ]
        )

        let prepared = try await Self.engine().prepare(
            previousState: previous,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [current])
        )

        XCTAssertEqual(prepared.events.first?.event.activityId, "REVIEW")
        XCTAssertEqual(Set(prepared.events.dropFirst().compactMap(\.event.activityId)), ["CHILD", "UNRELATED"])
    }

    func testRetiringPRUsesPriorRelationshipsAndEmitsOnlyFinalPeopleActivity() async throws {
        let previousPR = Self.pullRequest(
            ci: .passing,
            reviewRequestKind: .direct,
            isAssigned: true,
            isMine: false
        )
        let previous = PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: Self.dashboard([previousPR]),
            processedActivityByPullRequestID: [
                previousPR.id: ProcessedPullRequestActivity(pullRequestID: previousPR.id)
            ]
        )
        let retired = Self.pullRequest(
            ci: .failing,
            repositoryIsArchived: true,
            comments: [Self.comment("FINAL_COMMENT")],
            reviews: [Self.review("FINAL_REVIEW")],
            reviewRequestKind: .none,
            isAssigned: false,
            isMine: false
        )

        let prepared = try await Self.engine().prepare(
            previousState: previous,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [], retiringPullRequests: [retired])
        )

        XCTAssertEqual(Set(prepared.events.map(\.event.type)), [.newComment, .reviewApproved])
        XCTAssertTrue(prepared.events.allSatisfy { $0.filteringContext.reviewRequestKind == .direct })
        XCTAssertTrue(prepared.events.allSatisfy { $0.filteringContext.isAssignedToViewer })
        XCTAssertTrue(prepared.events.allSatisfy { $0.filteringContext.repositoryIsArchived == true })
        XCTAssertNil(prepared.processedActivityByPullRequestID[retired.id])
    }

    func testCIAndRelationshipTransitionsUseCommittedPRIndependentlyOfProcessedIDs() async throws {
        let previousPR = Self.pullRequest(ci: .passing, isAssigned: false, isMine: false)
        let current = Self.pullRequest(ci: .failing, isAssigned: true, isMine: false)
        let previous = PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: Self.dashboard([previousPR]),
            processedActivityByPullRequestID: [
                previousPR.id: ProcessedPullRequestActivity(
                    pullRequestID: previousPR.id,
                    commentIDs: ["MISSING_PROVIDER_COMMENT"],
                    submittedReviewIDs: ["MISSING_PROVIDER_REVIEW"]
                )
            ]
        )

        let prepared = try await Self.engine().prepare(
            previousState: previous,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [current])
        )

        XCTAssertEqual(Set(prepared.events.map(\.event.type)), [.relationshipAdded, .ciFailed])
        XCTAssertEqual(
            prepared.processedActivityByPullRequestID[current.id]?.commentIDs,
            []
        )
    }

    func testStateFromAnotherAccountIsNotTrustedWhenNoAccountIsProvided() async throws {
        let previousPR = Self.pullRequest(comments: [Self.comment("C_OLD")])
        let previous = PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: Self.dashboard([previousPR]),
            processedActivityByPullRequestID: [previousPR.id: PRActivityDetector.processedActivity(for: previousPR)]
        )
        let engine = SyncEngine(
            source: EmptyPullRequestSource(),
            loginProvider: { "bob" },
            accountProvider: { nil }
        )
        let current = Self.pullRequest(comments: [Self.comment("C_OLD"), Self.comment("C_NEW")])

        let prepared = try await engine.prepare(
            previousState: previous,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [current])
        )

        XCTAssertEqual(prepared.account.login, "bob")
        XCTAssertTrue(prepared.events.isEmpty)
    }

    func testProcessedThroughCountsOnlyNewerActivityAsUnseen() async throws {
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let previousPR = Self.pullRequest()
        let previous = PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: Self.dashboard([previousPR]),
            processedActivityByPullRequestID: [
                previousPR.id: ProcessedPullRequestActivity(pullRequestID: previousPR.id, processedThrough: cutoff)
            ]
        )
        func comment(_ id: String, at seconds: TimeInterval) -> PullRequestCommentActivity {
            PullRequestCommentActivity(
                id: id,
                url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
                author: "reviewer",
                viewerDidAuthor: false,
                createdAt: Date(timeIntervalSince1970: seconds),
                source: .pullRequest
            )
        }
        let olderReview = PullRequestReview(
            id: "R_OLD",
            url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
            state: .approved,
            submittedAt: Date(timeIntervalSince1970: 900),
            author: "reviewer"
        )
        let current = Self.pullRequest(
            comments: [comment("C_OLD", at: 900), comment("C_AT_CUTOFF", at: 1_000), comment("C_NEW", at: 1_100)],
            reviews: [olderReview]
        )

        let prepared = try await Self.engine().prepare(
            previousState: previous,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [current])
        )

        XCTAssertEqual(prepared.events.compactMap(\.event.activityId), ["C_NEW"])
        XCTAssertNil(prepared.processedActivityByPullRequestID[current.id]?.processedThrough)
    }

    func testFirstSyncWithAssignedAndRequestedPRsIsQuietBaseline() async throws {
        let current = [
            Self.pullRequest(id: "PR_ASSIGNED", isAssigned: true, isMine: false),
            Self.pullRequest(id: "PR_DIRECT", reviewRequestKind: .direct, isMine: false),
            Self.pullRequest(
                id: "PR_TEAM", ci: .failing, reviewRequestKind: .team, requestedTeams: [Self.reviewersTeam],
                isMine: false
            )
        ]

        let prepared = try await Self.engine().prepare(
            previousState: nil,
            fetchResult: CompletePullRequestFetchResult(
                activePullRequests: current,
                viewerTeams: [ViewerTeam(team: Self.reviewersTeam)]
            )
        )

        XCTAssertTrue(prepared.events.isEmpty)
    }

    func testStateFromAnotherLoginIsBaselineForRelationships() async throws {
        let previous = Self.trustedState([Self.pullRequest(id: "PR_TRACKED", isMine: false)])
        let engine = SyncEngine(
            source: EmptyPullRequestSource(),
            loginProvider: { "bob" },
            accountProvider: { GitHubAccount(login: "bob") }
        )
        let current = [
            Self.pullRequest(id: "PR_TRACKED", isAssigned: true, isMine: false),
            Self.pullRequest(id: "PR_NEW", reviewRequestKind: .direct, isMine: false)
        ]

        let prepared = try await engine.prepare(
            previousState: previous,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: current)
        )

        XCTAssertEqual(prepared.account.login, "bob")
        XCTAssertTrue(prepared.events.isEmpty)
    }

    func testTrustedEmptyDashboardIsBaselineAndFirstRequestNotifies() async throws {
        let current = Self.pullRequest(id: "PR_NEW", reviewRequestKind: .direct, isMine: false)

        let prepared = try await Self.engine().prepare(
            previousState: Self.trustedState([]),
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [current])
        )

        XCTAssertEqual(prepared.events.map(\.event.type), [.relationshipAdded])
        XCTAssertEqual(prepared.events.first?.event.relationshipChanges, [.directReviewRequest])
        XCTAssertEqual(prepared.events.first?.event.prId, current.id)
    }

    func testNewlySeenRequestedPRBaselinesExistingActivityAndNotifiesLaterComments() async throws {
        let engine = Self.engine()
        let newPR = Self.pullRequest(
            id: "PR_NEW",
            comments: [Self.comment("C_EXISTING")],
            reviews: [Self.review("R_EXISTING")],
            reviewRequestKind: .direct,
            isMine: false
        )

        let first = try await engine.prepare(
            previousState: Self.trustedState([]),
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [newPR])
        )

        XCTAssertEqual(first.events.map(\.event.type), [.relationshipAdded])
        XCTAssertEqual(first.processedActivityByPullRequestID[newPR.id]?.commentIDs, ["C_EXISTING"])
        XCTAssertEqual(first.processedActivityByPullRequestID[newPR.id]?.submittedReviewIDs, ["R_EXISTING"])

        let commented = Self.pullRequest(
            id: newPR.id,
            comments: newPR.recentCommentActivities + [Self.comment("C_LATER")],
            reviews: newPR.recentReviews,
            reviewRequestKind: .direct,
            isMine: false
        )
        let next = try await engine.prepare(
            previousState: Self.state(from: first),
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [commented])
        )

        XCTAssertEqual(next.events.map(\.event.type), [.newComment])
        XCTAssertEqual(next.events.map(\.event.activityId), ["C_LATER"])
    }

    func testPRReenteringWithRelationshipNotifiesAgain() async throws {
        let engine = Self.engine()
        let requested = Self.pullRequest(id: "PR_REENTERS", reviewRequestKind: .direct, isMine: false)
        let tracked = try await engine.prepare(
            previousState: Self.trustedState([requested]),
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [requested])
        )
        XCTAssertTrue(tracked.events.isEmpty)
        let left = try await engine.prepare(
            previousState: Self.state(from: tracked),
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [])
        )

        let reentered = try await engine.prepare(
            previousState: Self.state(from: left),
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [requested])
        )

        XCTAssertEqual(reentered.events.map(\.event.type), [.relationshipAdded])
        XCTAssertEqual(reentered.events.first?.event.relationshipChanges, [.directReviewRequest])
    }

    func testBaselineWithReadyRequestedPRIsQuiet() async throws {
        let ready = Self.pullRequest(id: "PR_READY", reviewRequestKind: .direct, isMine: false, draft: false)

        let prepared = try await Self.engine().prepare(
            previousState: nil,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [ready])
        )

        XCTAssertTrue(prepared.events.isEmpty)
    }

    func testRequestedDraftBecomingReadyAfterBaselineEmitsOneReadyForReview() async throws {
        let engine = Self.engine()
        let draft = Self.pullRequest(id: "PR_DRAFT", reviewRequestKind: .direct, isMine: false, draft: true)
        let ready = Self.pullRequest(id: "PR_DRAFT", reviewRequestKind: .direct, isMine: false, draft: false)
        let baseline = try await engine.prepare(
            previousState: nil,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [draft])
        )
        XCTAssertTrue(baseline.events.isEmpty)

        let next = try await engine.prepare(
            previousState: Self.state(from: baseline),
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [ready])
        )

        XCTAssertEqual(next.events.map(\.event.type), [.readyForReview])
        XCTAssertEqual(next.events.first?.event.prId, ready.id)
    }

    func testReadyDraftReadyAcrossRefreshesEmitsTwoReadyForReviewUpdates() async throws {
        let engine = Self.engine()
        let draft = Self.pullRequest(
            id: "PR_TOGGLE", reviewRequestKind: .team, requestedTeams: [Self.reviewersTeam], isMine: false, draft: true
        )
        let ready = Self.pullRequest(
            id: "PR_TOGGLE", reviewRequestKind: .team, requestedTeams: [Self.reviewersTeam], isMine: false, draft: false
        )
        let viewerTeams = [ViewerTeam(team: Self.reviewersTeam)]
        var state = Self.state(from: try await engine.prepare(
            previousState: nil,
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [draft], viewerTeams: viewerTeams)
        ))

        var readyCount = 0
        for pullRequest in [ready, draft, ready] {
            let prepared = try await engine.prepare(
                previousState: state,
                fetchResult: CompletePullRequestFetchResult(activePullRequests: [pullRequest], viewerTeams: viewerTeams)
            )
            readyCount += prepared.events.filter { $0.event.type == .readyForReview }.count
            state = Self.state(from: prepared)
        }

        XCTAssertEqual(readyCount, 2)
    }

    func testNewlySeenAuthoredPREmitsNothing() async throws {
        let authored = Self.pullRequest(
            id: "PR_AUTHORED",
            ci: .failing,
            comments: [Self.comment("C_EXISTING")],
            reviewRequestKind: .direct,
            isAssigned: true,
            isMine: true
        )

        let prepared = try await Self.engine().prepare(
            previousState: Self.trustedState([]),
            fetchResult: CompletePullRequestFetchResult(activePullRequests: [authored])
        )

        XCTAssertTrue(prepared.events.isEmpty)
    }

    func testTurnedOffOnlyTeamThenCountedTeamAddsOneTeamRelationship() throws {
        let previous = Self.trustedState([Self.teamRequested([Self.developers])])

        let prepared = try Self.prepareCounted(
            previous: previous,
            active: [Self.teamRequested([Self.developers, Self.plmTeam])],
            turnedOffTeamIDs: [Self.developers.id]
        )

        XCTAssertEqual(prepared.events.map(\.event.type), [.relationshipAdded])
        XCTAssertEqual(prepared.events.first?.event.relationshipChanges, [.teamReviewRequest])
    }

    func testSecondCountedTeamOnAlreadyCountedPRAddsNoRelationship() throws {
        let previous = Self.trustedState([Self.teamRequested([Self.developers])])

        let prepared = try Self.prepareCounted(
            previous: previous,
            active: [Self.teamRequested([Self.developers, Self.plmTeam])]
        )

        XCTAssertTrue(prepared.events.isEmpty)
    }

    func testChangingTurnedOffTeamsAloneNeverCreatesRelationshipEvents() throws {
        let pullRequests = [
            Self.teamRequested([Self.developers], id: "PR_DEV"),
            Self.teamRequested([Self.developers, Self.plmTeam], id: "PR_BOTH")
        ]
        let previous = Self.trustedState(pullRequests)

        let turnedOff = try Self.prepareCounted(
            previous: previous,
            active: pullRequests,
            turnedOffTeamIDs: [Self.developers.id, Self.plmTeam.id]
        )
        let turnedOn = try Self.prepareCounted(previous: Self.state(from: turnedOff), active: pullRequests)

        XCTAssertTrue(turnedOff.events.isEmpty)
        XCTAssertTrue(turnedOn.events.isEmpty)
    }

    func testTurnedOffOnlyTeamLeavesActivityWithoutTeamRelationship() throws {
        let previous = Self.trustedState([Self.teamRequested([Self.developers])])
        let current = Self.teamRequested(
            [Self.developers],
            comments: [Self.comment("C_NEW")],
            reviews: [Self.review("R_NEW")]
        )

        let prepared = try Self.prepareCounted(
            previous: previous,
            active: [current],
            turnedOffTeamIDs: [Self.developers.id]
        )

        XCTAssertEqual(Set(prepared.events.map(\.event.type)), [.newComment, .reviewApproved])
        for event in prepared.events {
            XCTAssertEqual(event.filteringContext.reviewRequestKind, .none)
            XCTAssertTrue(NotificationPreferences.relationships(matching: event.filteringContext).isEmpty)
        }
    }

    func testDirectRequestWithTurnedOffTeamKeepsOnlyTheDirectRelationship() throws {
        let previous = Self.trustedState([Self.teamRequested([Self.developers], direct: true)])
        let current = Self.teamRequested([Self.developers], direct: true, comments: [Self.comment("C_NEW")])

        let prepared = try Self.prepareCounted(
            previous: previous,
            active: [current],
            turnedOffTeamIDs: [Self.developers.id]
        )

        XCTAssertEqual(prepared.events.map(\.event.type), [.newComment])
        XCTAssertEqual(prepared.events.first?.filteringContext.reviewRequestKind, .direct)
    }

    func testPreparedActivePRsStayRawAndViewerTeamsPassThrough() throws {
        let current = Self.teamRequested([Self.developers])

        let prepared = try Self.prepareCounted(
            previous: Self.trustedState([]),
            active: [current],
            turnedOffTeamIDs: [Self.developers.id]
        )

        XCTAssertEqual(prepared.activePullRequests, [current])
        XCTAssertEqual(prepared.activePullRequests.first?.reviewRequestKind, .team)
        XCTAssertEqual(prepared.viewerTeams, Self.nestedViewerTeams)
    }

    func testJoiningATeamThatAnUnchangedAssignedPRRequestsAddsNoRelationship() throws {
        let pullRequest = Self.teamRequested([Self.plmTeam], isAssigned: true)
        var previous = Self.trustedState([pullRequest])
        previous.dashboard.viewerTeams = []

        let prepared = try Self.prepareCounted(previous: previous, active: [pullRequest])

        XCTAssertTrue(prepared.events.isEmpty)
    }

    func testNewDirectAndTurnedOffTeamRequestAddsOnlyTheDirectRelationship() throws {
        let previous = Self.trustedState([])

        let prepared = try Self.prepareCounted(
            previous: previous,
            active: [Self.teamRequested([Self.developers], direct: true)],
            turnedOffTeamIDs: [Self.developers.id]
        )

        XCTAssertEqual(prepared.events.map(\.event.type), [.relationshipAdded])
        XCTAssertEqual(prepared.events.first?.event.relationshipChanges, [.directReviewRequest])
    }

    func testRetiringTeamOnlyPRKeepsPreviousTeamRelationshipOnlyWhileItCounts() throws {
        let previous = Self.trustedState([Self.teamRequested([Self.developers])])
        let retiring = Self.teamRequested([], comments: [Self.comment("C_FINAL")])

        let counting = try Self.prepareCounted(previous: previous, active: [], retiring: [retiring])
        let turnedOff = try Self.prepareCounted(
            previous: previous,
            active: [],
            retiring: [retiring],
            turnedOffTeamIDs: [Self.developers.id]
        )

        XCTAssertEqual(counting.events.map(\.event.activityId), ["C_FINAL"])
        XCTAssertEqual(counting.events.first?.filteringContext.reviewRequestKind, .team)
        XCTAssertEqual(counting.events.first?.filteringContext.requestedTeams, [Self.developers])
        XCTAssertEqual(turnedOff.events.map(\.event.activityId), ["C_FINAL"])
        XCTAssertEqual(turnedOff.events.first?.filteringContext.reviewRequestKind, ReviewRequestKind.none)
    }

    private static let reviewersTeam = TeamReference(id: "T_REVIEWERS", organization: "acme", slug: "reviewers")
    private static let developers = TeamReference(id: "T_DEV", organization: "acme", slug: "developers")
    private static let plmTeam = TeamReference(id: "T_PLM", organization: "acme", slug: "plm-team")
    private static let nestedViewerTeams = [
        ViewerTeam(team: developers),
        ViewerTeam(team: plmTeam, parentTeamID: developers.id)
    ]

    private static func prepareCounted(
        previous: PullRequestSyncState?,
        active: [PullRequest],
        retiring: [PullRequest] = [],
        viewerTeams: [ViewerTeam] = nestedViewerTeams,
        turnedOffTeamIDs: Set<String> = []
    ) throws -> PreparedPullRequestRefresh {
        try engine().prepare(
            previousState: previous,
            fetched: FetchedPullRequestRefresh(
                login: "rw",
                account: GitHubAccount(login: "rw"),
                fetchResult: CompletePullRequestFetchResult(
                    activePullRequests: active,
                    retiringPullRequests: retiring,
                    viewerTeams: viewerTeams
                )
            ),
            turnedOffTeamIDs: turnedOffTeamIDs
        )
    }

    private static func teamRequested(
        _ teams: [TeamReference],
        id: String = "PR_TEAMS",
        direct: Bool = false,
        comments: [PullRequestCommentActivity] = [],
        reviews: [PullRequestReview] = [],
        isAssigned: Bool = false
    ) -> PullRequest {
        pullRequest(
            id: id,
            comments: comments,
            reviews: reviews,
            reviewRequestKind: ReviewRequestKind(direct: direct, team: !teams.isEmpty),
            requestedTeams: teams,
            isAssigned: isAssigned,
            isMine: false
        )
    }

    private static func engine() -> SyncEngine {
        SyncEngine(
            source: EmptyPullRequestSource(),
            loginProvider: { "rw" },
            accountProvider: { GitHubAccount(login: "rw") },
            now: { Date(timeIntervalSince1970: 100) }
        )
    }

    private static func state(from prepared: PreparedPullRequestRefresh) -> PullRequestSyncState {
        PullRequestSyncState(
            account: prepared.account,
            dashboard: DashboardState(
                pullRequests: prepared.activePullRequests,
                events: prepared.events.map(\.event),
                syncedAt: prepared.syncedAt,
                source: prepared.source,
                account: prepared.account,
                authStatus: .signedIn
            ),
            processedActivityByPullRequestID: prepared.processedActivityByPullRequestID
        )
    }

    /// A stored state for the signed-in account, so the next refresh is not a baseline.
    private static func trustedState(_ pullRequests: [PullRequest]) -> PullRequestSyncState {
        PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: dashboard(pullRequests),
            processedActivityByPullRequestID: Dictionary(
                uniqueKeysWithValues: pullRequests.map { ($0.id, PRActivityDetector.processedActivity(for: $0)) }
            )
        )
    }

    private static func dashboard(_ pullRequests: [PullRequest]) -> DashboardState {
        DashboardState(
            pullRequests: pullRequests,
            events: [],
            syncedAt: Date(timeIntervalSince1970: 1),
            source: .github,
            account: GitHubAccount(login: "rw"),
            authStatus: .signedIn
        )
    }

    private static func pullRequest(
        id: String = "PR_1",
        ci: CIState = .passing,
        repositoryIsArchived: Bool? = nil,
        commentCount: Int? = nil,
        comments: [PullRequestCommentActivity] = [],
        reviewCount: Int? = nil,
        reviews: [PullRequestReview] = [],
        reviewRequestKind: ReviewRequestKind = .none,
        requestedTeams: [TeamReference] = [],
        isAssigned: Bool = false,
        isMine: Bool = true,
        draft: Bool = false
    ) -> PullRequest {
        PullRequest(
            id: id,
            title: "Prepared refresh",
            number: 1,
            url: URL(string: "https://github.com/acme/app/pull/1")!,
            repo: "acme/app",
            repositoryIsArchived: repositoryIsArchived,
            ciState: ci,
            reviewDecision: .reviewRequired,
            commentCount: commentCount ?? comments.count,
            commentActivityCount: comments.count,
            recentCommentActivities: comments,
            reviewCount: reviewCount ?? reviews.count,
            recentReviews: reviews,
            reviewRequestKind: reviewRequestKind,
            requestedTeams: requestedTeams,
            isAssignedToViewer: isAssigned,
            isMine: isMine,
            author: isMine ? "rw" : "author",
            mergeable: .mergeable,
            draft: draft
        )
    }

    private static func comment(
        _ id: String,
        reviewID: String? = nil,
        viewerDidAuthor: Bool = false
    ) -> PullRequestCommentActivity {
        PullRequestCommentActivity(
            id: id,
            url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-fixture")!,
            author: viewerDidAuthor ? "rw" : "reviewer",
            viewerDidAuthor: viewerDidAuthor,
            createdAt: Date(timeIntervalSince1970: TimeInterval(abs(id.hashValue % 10_000))),
            source: reviewID == nil ? .pullRequest : .reviewThread,
            reviewId: reviewID
        )
    }

    private static func review(_ id: String) -> PullRequestReview {
        PullRequestReview(
            id: id,
            url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-fixture")!,
            state: .approved,
            submittedAt: Date(timeIntervalSince1970: TimeInterval(abs(id.hashValue % 10_000))),
            author: "reviewer"
        )
    }
}
