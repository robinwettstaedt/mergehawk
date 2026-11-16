@testable import mergehawk
import mergehawkcore
import Foundation
import XCTest

final class RelationshipNotificationTitleTests: XCTestCase {
    func testReviewRequestTitlesNameThePRAuthorOnBothSurfaces() throws {
        let cases: [(Set<PullRequestNotificationRelationship>, String)] = [
            ([.directReviewRequest], "Review requested on @alice's PR"),
            ([.teamReviewRequest], "Review requested on @alice's PR"),
            ([.directReviewRequest, .teamReviewRequest], "Review requested on @alice's PR"),
            ([.assigned, .directReviewRequest], "Assigned and review requested on @alice's PR"),
            ([.assigned, .teamReviewRequest], "Assigned and review requested on @alice's PR"),
        ]
        for (changes, expected) in cases {
            try assertTitles(changes: changes, author: "alice", expected: expected)
        }
    }

    func testAssignmentOnlyTitleIgnoresThePRAuthor() throws {
        try assertTitles(changes: [.assigned], author: "alice", expected: "Assigned to you")
        try assertTitles(changes: [.assigned], author: nil, expected: "Assigned to you")
    }

    func testReviewRequestTitlesFallBackWithoutAUsableAuthor() throws {
        for author in [nil, "", "unknown"] as [String?] {
            try assertTitles(changes: [.directReviewRequest], author: author, expected: "Review requested")
            try assertTitles(changes: [.teamReviewRequest], author: author, expected: "Review requested")
            try assertTitles(
                changes: [.assigned, .directReviewRequest], author: author, expected: "Assigned and review requested"
            )
        }
    }

    func testReviewRequestTitlesNameGhostAndUseTheSamePossessiveForLoginsEndingInS() throws {
        try assertTitles(changes: [.directReviewRequest], author: "ghost", expected: "Review requested on @ghost's PR")
        try assertTitles(changes: [.directReviewRequest], author: "james", expected: "Review requested on @james's PR")
    }

    func testPRNotificationHistoryRowWithoutAStoredAuthorShowsThePlainTitle() throws {
        let pullRequest = titlePR(author: "alice")
        let event = PullRequestEvent(
            type: .relationshipAdded, prId: pullRequest.id, relationshipChanges: [.directReviewRequest]
        )
        let row = try PullRequestNotification(event: event, pullRequest: pullRequest).withoutStoredPRAuthor()
        XCTAssertNil(row.prAuthor)
        XCTAssertEqual(PullRequestNotificationTitlePresentation.title(for: row), "Review requested")
    }

    func testNotificationTypeFixtureTopRowNamesALongPRAuthor() throws {
        let rows = MockPullRequestSource.notificationTypeFixturePullRequestNotifications
        let top = try XCTUnwrap(rows.max { $0.createdAt < $1.createdAt })
        XCTAssertEqual(top.id, rows.first?.id)
        XCTAssertEqual(
            PullRequestNotificationTitlePresentation.title(for: top),
            "Review requested on @release-engineering-automation-bot01's PR"
        )
    }

    /// Checks the PR notification history row and the single-update macOS local notification.
    /// A nil author means the row has no stored author and the macOS post has no matching PR.
    private func assertTitles(
        changes: Set<PullRequestNotificationRelationship>,
        author: String?,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let pullRequest = titlePR(author: author ?? "alice")
        let event = PullRequestEvent(type: .relationshipAdded, prId: pullRequest.id, relationshipChanges: changes)
        var row = PullRequestNotification(event: event, pullRequest: pullRequest)
        if author == nil {
            row = try row.withoutStoredPRAuthor()
        }
        let posted = author == nil ? [] : [pullRequest]
        let label = "\(changes.map(\.rawValue).sorted()) by \(author ?? "nil")"

        XCTAssertEqual(PullRequestNotificationTitlePresentation.title(for: row), expected, label, file: file, line: line)
        XCTAssertEqual(
            NotificationContentBuilder.summaryTitle(for: [event], pullRequests: posted), expected, label,
            file: file, line: line
        )
        XCTAssertEqual(
            NotificationContentBuilder.records(events: [event], pullRequests: posted).first?.title, expected, label,
            file: file, line: line
        )
    }

    private func titlePR(author: String) -> PullRequest {
        PullRequest(
            id: "PR_1", title: "Example", number: 1, url: URL(string: "https://github.com/acme/app/pull/1")!,
            repo: "acme/app", ciState: .passing, reviewDecision: .reviewRequired, commentCount: 0,
            reviewCount: 0, reviewRequestKind: .direct, isAssignedToViewer: true, isMine: false,
            author: author, mergeable: .mergeable, draft: false
        )
    }
}
