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

    func testSelfAuthoredAndRepresentedReviewChildCommentsStaySuppressed() async throws {
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

        XCTAssertEqual(prepared.events.map(\.event.activityId), ["REVIEW", "UNRELATED"])
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
        ci: CIState = .passing,
        commentCount: Int? = nil,
        comments: [PullRequestCommentActivity] = [],
        reviewCount: Int? = nil,
        reviews: [PullRequestReview] = [],
        reviewRequestKind: ReviewRequestKind = .none,
        isAssigned: Bool = false,
        isMine: Bool = true
    ) -> PullRequest {
        PullRequest(
            id: "PR_1",
            title: "Prepared refresh",
            number: 1,
            url: URL(string: "https://github.com/acme/app/pull/1")!,
            repo: "acme/app",
            ciState: ci,
            reviewDecision: .noReviewYet,
            commentCount: commentCount ?? comments.count,
            commentActivityCount: comments.count,
            recentCommentActivities: comments,
            reviewCount: reviewCount ?? reviews.count,
            recentReviews: reviews,
            reviewRequestKind: reviewRequestKind,
            isAssignedToViewer: isAssigned,
            isMine: isMine,
            author: isMine ? "rw" : "author",
            mergeable: .mergeable,
            draft: false
        )
    }

    private static func comment(
        _ id: String,
        reviewID: String? = nil,
        viewerDidAuthor: Bool = false
    ) -> PullRequestCommentActivity {
        PullRequestCommentActivity(
            id: id,
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
            state: .approved,
            submittedAt: Date(timeIntervalSince1970: TimeInterval(abs(id.hashValue % 10_000))),
            author: "reviewer"
        )
    }
}
