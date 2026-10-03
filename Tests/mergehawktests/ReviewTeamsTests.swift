@testable import mergehawkcore
import Foundation
import XCTest

final class ReviewTeamsTests: XCTestCase {
    static let engineering = TeamReference(id: "T_engineering", organization: "acme", slug: "engineering")
    static let developers = TeamReference(id: "T_developers", organization: "acme", slug: "developers")
    static let plmTeam = TeamReference(id: "T_plm", organization: "acme", slug: "plm-team")
    static let security = TeamReference(id: "T_security", organization: "acme", slug: "security")

    static let viewerTeams = [
        ViewerTeam(
            team: plmTeam,
            parentTeamID: developers.id,
            avatarURL: URL(string: "https://avatars.githubusercontent.com/t/1?s=64&v=4"),
            organizationAvatarURL: URL(string: "https://avatars.githubusercontent.com/u/9?v=4")
        ),
        ViewerTeam(team: developers, parentTeamID: engineering.id),
        ViewerTeam(team: engineering)
    ]

    func testRequestedTeamTheViewerIsNotInNeverCounts() {
        let counting = TeamReviewCounting(viewerTeams: Self.viewerTeams, turnedOffTeamIDs: [])

        let projected = counting.applied(to: Self.pullRequest(kind: .team, requestedTeams: [Self.security]))

        XCTAssertEqual(projected.reviewRequestKind, .none)
    }

    func testDirectViewerTeamCountsUntilTurnedOff() {
        let pr = Self.pullRequest(kind: .team, requestedTeams: [Self.plmTeam])

        XCTAssertEqual(
            TeamReviewCounting(viewerTeams: Self.viewerTeams, turnedOffTeamIDs: []).applied(to: pr).reviewRequestKind,
            .team
        )
        XCTAssertEqual(
            TeamReviewCounting(viewerTeams: Self.viewerTeams, turnedOffTeamIDs: [Self.plmTeam.id])
                .applied(to: pr).reviewRequestKind,
            .none
        )
    }

    func testInheritedAncestorCountsOnItsOwnAndTurningOffDevelopersDoesNotCascade() {
        let counting = TeamReviewCounting(viewerTeams: Self.viewerTeams, turnedOffTeamIDs: [Self.developers.id])

        XCTAssertEqual(
            counting.applied(to: Self.pullRequest(kind: .team, requestedTeams: [Self.engineering])).reviewRequestKind,
            .team
        )
        XCTAssertEqual(
            counting.applied(to: Self.pullRequest(kind: .team, requestedTeams: [Self.plmTeam])).reviewRequestKind,
            .team
        )
        XCTAssertEqual(
            counting.applied(to: Self.pullRequest(kind: .team, requestedTeams: [Self.developers])).reviewRequestKind,
            .none
        )
    }

    func testTurnedOffTeamPlusNonMemberTeamLosesTheTeamFlag() {
        let counting = TeamReviewCounting(viewerTeams: Self.viewerTeams, turnedOffTeamIDs: [Self.developers.id])

        let projected = counting.applied(
            to: Self.pullRequest(kind: .team, requestedTeams: [Self.developers, Self.security])
        )

        XCTAssertEqual(projected.reviewRequestKind, .none)
    }

    func testTurnedOffTeamPlusCountedTeamKeepsTheTeamFlag() {
        let counting = TeamReviewCounting(viewerTeams: Self.viewerTeams, turnedOffTeamIDs: [Self.developers.id])

        let projected = counting.applied(
            to: Self.pullRequest(kind: .team, requestedTeams: [Self.developers, Self.plmTeam])
        )

        XCTAssertEqual(projected.reviewRequestKind, .team)
    }

    func testDirectRequestAssignmentAndAuthorshipAreNeverChanged() {
        let counting = TeamReviewCounting(viewerTeams: Self.viewerTeams, turnedOffTeamIDs: [Self.developers.id])
        let raw = Self.pullRequest(
            kind: .directAndTeam,
            requestedTeams: [Self.developers],
            isAssignedToViewer: true,
            isMine: true
        )

        let projected = counting.applied(to: raw)

        XCTAssertEqual(projected.reviewRequestKind, .direct)
        XCTAssertTrue(projected.isAssignedToViewer)
        XCTAssertTrue(projected.isMine)
        XCTAssertEqual(projected.requestedTeams, raw.requestedTeams)
        var expected = raw
        expected.reviewRequestKind = .direct
        XCTAssertEqual(projected, expected)
    }

    func testCountedTeamFlagDependsOnlyOnRequestedTeams() {
        let counting = TeamReviewCounting(viewerTeams: Self.viewerTeams, turnedOffTeamIDs: [])

        let flaggedWithoutCountedTeam = counting.applied(to: Self.pullRequest(kind: .team, requestedTeams: []))
        let unflaggedWithCountedTeam = counting.applied(
            to: Self.pullRequest(kind: .direct, requestedTeams: [Self.developers])
        )

        XCTAssertEqual(flaggedWithoutCountedTeam.reviewRequestKind, .none)
        XCTAssertEqual(unflaggedWithCountedTeam.reviewRequestKind, .directAndTeam)
    }

    func testPullRequestAndDashboardStateRoundTripWithTeams() throws {
        let pr = Self.pullRequest(kind: .team, requestedTeams: [Self.developers, Self.security])
        let dashboard = DashboardState(
            pullRequests: [pr],
            events: [],
            syncedAt: Date(timeIntervalSince1970: 1_000),
            source: .github,
            account: GitHubAccount(login: "rw"),
            authStatus: .signedIn,
            viewerTeams: Self.viewerTeams
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let decodedPR = try decoder.decode(PullRequest.self, from: encoder.encode(pr))
        let decodedDashboard = try decoder.decode(DashboardState.self, from: encoder.encode(dashboard))

        XCTAssertEqual(decodedPR, pr)
        XCTAssertEqual(decodedPR.requestedTeams, [Self.developers, Self.security])
        XCTAssertEqual(decodedDashboard, dashboard)
        XCTAssertEqual(decodedDashboard.viewerTeams, Self.viewerTeams)
    }

    static func pullRequest(
        kind: ReviewRequestKind,
        requestedTeams: [TeamReference],
        isAssignedToViewer: Bool = false,
        isMine: Bool = false
    ) -> PullRequest {
        PullRequest(
            id: "PR_1",
            title: "Teams",
            number: 1,
            url: URL(string: "https://github.com/acme/app/pull/1")!,
            repo: "acme/app",
            ciState: .passing,
            reviewDecision: .reviewRequired,
            commentCount: 0,
            reviewCount: 0,
            reviewRequestKind: kind,
            requestedTeams: requestedTeams,
            isAssignedToViewer: isAssignedToViewer,
            isMine: isMine,
            author: "octo",
            mergeable: .mergeable,
            draft: false
        )
    }
}
