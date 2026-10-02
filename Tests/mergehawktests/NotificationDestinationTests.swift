@testable import mergehawk
import mergehawkcore
import Foundation
import XCTest

final class NotificationDestinationTests: XCTestCase {
    func testPeopleActivityCarriesProviderDestinationsIncludingReviewChildComments() throws {
        let base = URL(string: "https://github.com/acme/app/pull/1")!
        let discussion = URL(string: "https://github.com/acme/app/pull/1?tab=conversation#issuecomment-1")!
        let inline = URL(string: "https://github.com/acme/app/pull/1/files#discussion_r2")!
        let child = URL(string: "https://github.com/acme/app/pull/1/files#discussion_r3")!
        let comments = [
            comment("C1", url: discussion, source: .pullRequest),
            comment("C2", url: inline, source: .reviewThread),
            comment("C3", url: child, source: .reviewThread, reviewID: "R1")
        ]
        let reviews = [
            review("R1", state: .approved),
            review("R2", state: .changesRequested),
            review("R3", state: .commented)
        ]
        let pullRequest = PullRequest(
            id: "PR_1", title: "Example", number: 1, url: base, repo: "acme/app",
            ciState: .passing, reviewDecision: .approved, commentCount: comments.count,
            recentCommentActivities: comments, reviewCount: reviews.count, recentReviews: reviews,
            isMine: true, author: "rw", mergeable: .mergeable, draft: false
        )
        let events = PRActivityDetector.detectProcessedPeopleActivity(
            previous: ProcessedPullRequestActivity(pullRequestID: "PR_1"),
            current: pullRequest
        )
        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(events.first { $0.activityId == "C1" }?.destinationURL, discussion)
        XCTAssertEqual(events.first { $0.activityId == "C2" }?.destinationURL, inline)
        XCTAssertEqual(events.first { $0.activityId == "C3" }?.destinationURL, child)
        for review in reviews {
            XCTAssertEqual(events.first { $0.activityId == review.id }?.destinationURL, review.url)
        }
        for event in events {
            let notification = PullRequestNotification(event: event, pullRequest: pullRequest)
            XCTAssertEqual(notification.url, base)
            XCTAssertEqual(notification.destinationURL, event.destinationURL)
        }
        XCTAssertNil(PullRequestEvent(type: .ciFailed, prId: "PR_1").destinationURL)
    }

    func testRetainedDestinationRoundTripsThroughSyncStateWithoutDashboardPR() throws {
        let suite = "mergehawk-notification-destination-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = URL(string: "https://github.com/acme/app/pull/1")!
        let destination = URL(string: "https://github.com/acme/app/pull/1?view=comment#discussion_r99")!
        let pullRequest = PullRequest(
            id: "PR_1", title: "Retired", number: 1, url: base, repo: "acme/app",
            ciState: .passing, reviewDecision: .reviewRequired, commentCount: 0,
            reviewCount: 0, isMine: true, author: "rw", mergeable: .mergeable, draft: false
        )
        let notification = PullRequestNotification(
            event: PullRequestEvent(type: .reviewCommented, prId: "PR_1", activityId: "C99", destinationURL: destination),
            pullRequest: pullRequest
        )
        let state = PullRequestSyncState(
            account: GitHubAccount(login: "rw"), dashboard: .empty,
            notificationHistory: [notification]
        )
        try PreferencesStore(defaults: defaults).storePullRequestSyncState(state)
        let restored = try XCTUnwrap(PreferencesStore(defaults: defaults).pullRequestSyncState)
        XCTAssertTrue(restored.dashboard.pullRequests.isEmpty)
        XCTAssertEqual(restored.notificationHistory.first?.url, base)
        XCTAssertEqual(restored.notificationHistory.first?.destinationURL, destination)
    }

    func testMockNotificationTypesUsePreciseDestinationsOnlyForPeopleActivity() {
        let notifications = MockPullRequestSource.notificationTypeFixturePullRequestNotifications
        XCTAssertEqual(notifications.count, 9)
        for notification in notifications {
            switch notification.eventType {
            case .newComment, .reviewApproved, .reviewCommented, .changesRequested:
                XCTAssertNotNil(notification.destinationURL)
                XCTAssertTrue(notification.destinationURL!.absoluteString.hasPrefix(notification.url.absoluteString))
            default:
                XCTAssertNil(notification.destinationURL)
            }
        }
    }

    func testSingleMacOSUpdateRoundTripsBaseAndPreciseDestination() {
        let base = URL(string: "https://github.com/acme/app/pull/1")!
        let destination = URL(string: "https://github.com/acme/app/pull/1?view=comment#discussion_r7")!
        let pullRequest = PullRequest(
            id: "PR_1", title: "Example", number: 1, url: base, repo: "acme/app",
            ciState: .passing, reviewDecision: .reviewRequired, commentCount: 0,
            reviewCount: 0, isMine: true, author: "rw", mergeable: .mergeable, draft: false
        )
        let event = PullRequestEvent(
            type: .reviewCommented, prId: pullRequest.id,
            activityId: "C7", destinationURL: destination
        )
        let route = NotificationClickRoute.route(events: [event], pullRequests: [pullRequest])
        let request = PullRequestOpenRequest(pullRequestURL: base, destinationURL: destination)
        XCTAssertEqual(route, .openPullRequest(request))
        XCTAssertEqual(route.userInfo[NotificationClickRoute.pullRequestURLKey], base.absoluteString)
        XCTAssertEqual(route.userInfo[NotificationClickRoute.destinationURLKey], destination.absoluteString)
        XCTAssertEqual(NotificationClickRoute(userInfo: route.userInfo), .openPullRequest(request))
        let record = NotificationContentBuilder.records(events: [event], pullRequests: [pullRequest])[0]
        XCTAssertEqual(record.clickPullRequestURL, base.absoluteString)
        XCTAssertEqual(record.clickDestinationURL, destination.absoluteString)

        var malformed = route.userInfo
        malformed[NotificationClickRoute.destinationURLKey] = "not a URL"
        XCTAssertEqual(NotificationClickRoute(userInfo: malformed), .openNotifications)
        XCTAssertEqual(NotificationClickRoute.route(events: [event, event], pullRequests: [pullRequest]), .openNotifications)
        XCTAssertEqual(NotificationClickRoute.route(events: [event], pullRequests: []), .openNotifications)
    }

    @MainActor
    func testControllerRoutesPRAndNotificationRequestsToInjectedCollaborator() async throws {
        let suite = "mergehawk-typed-open-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = URL(string: "https://github.com/acme/app/pull/1")!
        let destination = URL(string: "https://github.com/acme/app/pull/1#issuecomment-7")!
        let pullRequest = PullRequest(
            id: "PR_1", title: "Example", number: 1, url: base, repo: "acme/app",
            ciState: .passing, reviewDecision: .reviewRequired, commentCount: 0,
            reviewCount: 0, isMine: true, author: "rw", mergeable: .mergeable, draft: false
        )
        let notification = PullRequestNotification(
            event: PullRequestEvent(
                type: .newComment, prId: pullRequest.id, activityId: "C7", destinationURL: destination
            ),
            pullRequest: pullRequest
        )
        var requests: [PullRequestOpenRequest] = []
        var ordinaryURLs: [URL] = []
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0,
            urlOpener: { ordinaryURLs.append($0) },
            pullRequestOpener: { requests.append($0) }
        )
        controller.openPullRequest(pullRequest)
        controller.openPullRequestNotification(notification)
        controller.open(URL(string: "https://github.com/settings")!)

        XCTAssertEqual(requests, [
            PullRequestOpenRequest(pullRequestURL: base),
            PullRequestOpenRequest(pullRequestURL: base, destinationURL: destination)
        ])
        XCTAssertEqual(ordinaryURLs, [URL(string: "https://github.com/settings")!])
    }

    private func comment(
        _ id: String, url: URL, source: PullRequestCommentActivity.Source,
        reviewID: String? = nil
    ) -> PullRequestCommentActivity {
        PullRequestCommentActivity(
            id: id, url: url, author: "reviewer", createdAt: Date(timeIntervalSince1970: 1),
            source: source, reviewId: reviewID
        )
    }

    private func review(_ id: String, state: PullRequestReviewState) -> PullRequestReview {
        PullRequestReview(
            id: id, url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-\(id)")!,
            state: state, submittedAt: Date(timeIntervalSince1970: 2), author: "reviewer",
            hasSummaryText: true
        )
    }
}
