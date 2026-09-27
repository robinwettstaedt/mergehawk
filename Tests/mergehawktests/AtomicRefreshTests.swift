@testable import mergehawk
@testable import mergehawkcore
import Foundation
import XCTest

final class AtomicRefreshTests: XCTestCase {
    @MainActor
    func testFailedRefreshPreservesStoredAndPublishedPresentationWithoutNotifications() async throws {
        let fixture = try makeFixture(provider: AtomicGitHubProvider(result: .failure))
        defer { fixture.cleanup() }

        await waitUntil { fixture.controller.refreshErrorMessage != nil }

        XCTAssertEqual(fixture.controller.state, fixture.previous.dashboard)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState, fixture.previous)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
    }

    @MainActor
    func testRefreshFailureIsReportedSeparatelyAndClearedByNextSuccessfulRefresh() async throws {
        let provider = AtomicGitHubProvider(result: .failure)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { fixture.controller.refreshErrorMessage != nil }

        XCTAssertEqual(fixture.controller.refreshErrorMessage, "Refresh failed")
        XCTAssertNil(fixture.controller.errorMessage)

        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [fixture.pullRequest]))
        fixture.controller.refresh()
        await waitUntil { provider.fetchCount == 2 && !fixture.controller.isRefreshing }

        XCTAssertNil(fixture.controller.refreshErrorMessage)
    }

    @MainActor
    func testFailedReadSaveIsReportedAsSaveErrorAndKeepsPriorState() async throws {
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(
            provider: provider,
            encoder: { _ in throw AtomicTestError.encodingFailed }
        )
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }

        fixture.controller.markPullRequestNotificationRead(
            fixture.controller.pullRequestNotificationHistory[0]
        )

        XCTAssertNotNil(fixture.controller.saveErrorMessage)
        XCTAssertNil(fixture.controller.refreshErrorMessage)
        XCTAssertNil(fixture.controller.errorMessage)
        XCTAssertFalse(fixture.controller.pullRequestNotificationHistory[0].read)
        fixture.controller.dismissSaveError()
        XCTAssertNil(fixture.controller.saveErrorMessage)

        fixture.controller.markPullRequestNotificationRead(
            fixture.controller.pullRequestNotificationHistory[0]
        )
        XCTAssertNotNil(fixture.controller.saveErrorMessage)
        fixture.controller.signOut()
        XCTAssertNil(fixture.controller.saveErrorMessage)
    }

    @MainActor
    func testPersistenceEncodingFailureLeavesPriorLiveAndStoredStateUnchanged() async throws {
        let updated = makePullRequest(id: "PR_UPDATED", title: "Updated")
        let fixture = try makeFixture(
            provider: AtomicGitHubProvider(
                result: .success(CompletePullRequestFetchResult(activePullRequests: [updated]))
            ),
            encoder: { _ in throw AtomicTestError.encodingFailed }
        )
        defer { fixture.cleanup() }

        await waitUntil { fixture.controller.refreshErrorMessage != nil }

        XCTAssertEqual(fixture.controller.state, fixture.previous.dashboard)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState, fixture.previous)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
    }

    @MainActor
    func testReadDuringSuspendedRefreshIsMergedIntoCommittedState() async throws {
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }

        fixture.controller.markPullRequestNotificationRead(
            fixture.controller.pullRequestNotificationHistory[0]
        )
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory[0].read)
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [fixture.pullRequest]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory[0].read)
        XCTAssertTrue(fixture.preferences.pullRequestSyncState?.notificationHistory[0].read == true)
    }

    @MainActor
    func testNotificationAndSourcePreferenceChangesDuringFetchApplyAtCommit() async throws {
        for mode in ["notification", "source"] {
            let provider = AtomicGitHubProvider(result: .suspended)
            let fixture = try makeFixture(provider: provider)
            defer { fixture.cleanup() }
            await waitUntil { provider.fetchCount == 1 }
            if mode == "notification" {
                fixture.controller.preferences = NotificationPreferences(
                    authored: .disabled,
                    assigned: .disabled,
                    directReviewRequests: .disabled,
                    teamReviewRequests: .disabled,
                    commentModes: CommentNotificationPreferences(
                        authored: .off, assigned: .off, directReviewRequests: .off, teamReviewRequests: .off
                    )
                )
            } else {
                fixture.controller.setRepositoryPreferences(
                    repo: fixture.pullRequest.repo,
                    preferences: RepositorySourcePreferences(
                        notifications: .disabled,
                        myPullRequests: .inherit,
                        reviewRequests: .inherit
                    )
                )
            }
            let current = makePullRequest(
                id: fixture.pullRequest.id,
                title: fixture.pullRequest.title,
                comments: fixture.pullRequest.recentCommentActivities + [
                    PullRequestCommentActivity(
                        id: "COMMENT_\(mode)",
                        url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-fixture")!,
                        author: "reviewer",
                        createdAt: Date(timeIntervalSince1970: 30),
                        source: .pullRequest
                    )
                ]
            )
            provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [current]))
            await waitUntil { !fixture.controller.isRefreshing }

            XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
            XCTAssertTrue(fixture.notifications.records.isEmpty)
        }
    }

    @MainActor
    func testArchivedActivityIsProcessedWithoutNewHistoryOrDeliveryAndDoesNotReplay() async throws {
        let baseline = makePullRequest(id: "PR_ARCHIVED", title: "Archived", archived: true)
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(pullRequest: baseline, provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }
        let firstComment = PullRequestCommentActivity(
            id: "COMMENT_ARCHIVED",
            url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-COMMENT_ARCHIVED")!,
            author: "reviewer", createdAt: Date(timeIntervalSince1970: 30),
            source: .pullRequest
        )
        let first = makePullRequest(
            id: baseline.id, title: baseline.title, archived: true,
            comments: baseline.recentCommentActivities + [firstComment]
        )
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [first]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState?.processedActivityByPullRequestID[baseline.id]?.commentIDs.count, 2)
        XCTAssertEqual(fixture.controller.state.pullRequests.first?.repositoryIsArchived, true)

        fixture.controller.hideArchivedRepositories = false
        fixture.controller.refresh()
        await waitUntil { provider.fetchCount == 2 && !fixture.controller.isRefreshing }
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
        XCTAssertTrue(fixture.notifications.records.isEmpty)

        let secondComment = PullRequestCommentActivity(
            id: "COMMENT_RESTORED",
            url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-COMMENT_RESTORED")!,
            author: "reviewer", createdAt: Date(timeIntervalSince1970: 40),
            source: .pullRequest
        )
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [makePullRequest(
            id: baseline.id, title: baseline.title, archived: true,
            comments: first.recentCommentActivities + [secondComment]
        )]))
        fixture.controller.refresh()
        await waitUntil { provider.fetchCount == 3 && !fixture.controller.isRefreshing }
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.compactMap(\.activityId).filter { $0 == "COMMENT_RESTORED" }, ["COMMENT_RESTORED"])
        XCTAssertEqual(fixture.notifications.records.map(\.pullRequestId), [baseline.id])
    }

    @MainActor
    func testRetiringPRUsesCurrentArchiveStatusForNotificationSuppression() async throws {
        let baseline = makePullRequest(id: "PR_RETIRING", title: "Retiring", archived: false)
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(pullRequest: baseline, provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }
        let finalComment = PullRequestCommentActivity(
            id: "COMMENT_FINAL",
            url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-COMMENT_FINAL")!,
            author: "reviewer", createdAt: Date(timeIntervalSince1970: 30),
            source: .pullRequest
        )
        let retired = makePullRequest(
            id: baseline.id, title: baseline.title, archived: true,
            comments: baseline.recentCommentActivities + [finalComment]
        )
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [], retiringPullRequests: [retired]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertTrue(fixture.controller.state.pullRequests.isEmpty)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
    }

    @MainActor
    func testArchiveToggleChangedDuringSuspendedRefreshIsUsedAtCommit() async throws {
        let baseline = makePullRequest(id: "PR_ARCHIVED", title: "Archived", archived: true)
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(pullRequest: baseline, provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }
        fixture.controller.hideArchivedRepositories = false
        let comment = PullRequestCommentActivity(
            id: "COMMENT_DURING_FETCH",
            url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-COMMENT_DURING_FETCH")!,
            author: "reviewer", createdAt: Date(timeIntervalSince1970: 30),
            source: .pullRequest
        )
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [makePullRequest(
            id: baseline.id, title: baseline.title, archived: true,
            comments: baseline.recentCommentActivities + [comment]
        )]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.contains { $0.activityId == comment.id })
        XCTAssertEqual(fixture.notifications.records.map(\.pullRequestId), [baseline.id])
        XCTAssertFalse(fixture.preferences.hideArchivedRepositories)
    }

    @MainActor
    func testArchivedSiblingSuppressesNonArchivedPRActivityAcrossSameRepositoryUntilToggleOff() async throws {
        let primary = makePullRequest(id: "PR_PRIMARY", title: "Primary", archived: false)
        let sibling = makePullRequest(id: "PR_SIBLING", title: "Sibling", archived: false)
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(
            pullRequest: primary, additionalPullRequests: [sibling], provider: provider
        )
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }

        let firstComment = PullRequestCommentActivity(
            id: "COMMENT_MIXED_SUPPRESSED",
            url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-COMMENT_MIXED_SUPPRESSED")!,
            author: "reviewer",
            createdAt: Date(timeIntervalSince1970: 30), source: .pullRequest
        )
        let currentPrimary = makePullRequest(
            id: primary.id, title: primary.title, archived: false,
            comments: primary.recentCommentActivities + [firstComment]
        )
        let currentSibling = makePullRequest(id: sibling.id, title: sibling.title, archived: true)
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [currentPrimary, currentSibling]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState?.processedActivityByPullRequestID[primary.id]?.commentIDs.count, 2)
        XCTAssertEqual(fixture.controller.state.pullRequests.count, 2)

        fixture.controller.hideArchivedRepositories = false
        let secondComment = PullRequestCommentActivity(
            id: "COMMENT_MIXED_ALLOWED",
            url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-COMMENT_MIXED_ALLOWED")!,
            author: "reviewer",
            createdAt: Date(timeIntervalSince1970: 40), source: .pullRequest
        )
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [
            makePullRequest(
                id: primary.id, title: primary.title, archived: false,
                comments: currentPrimary.recentCommentActivities + [secondComment]
            ),
            currentSibling
        ]))
        fixture.controller.refresh()
        await waitUntil { provider.fetchCount == 2 && !fixture.controller.isRefreshing }

        XCTAssertEqual(
            fixture.controller.pullRequestNotificationHistory.compactMap(\.activityId).filter { $0 == secondComment.id },
            [secondComment.id]
        )
        XCTAssertFalse(fixture.controller.pullRequestNotificationHistory.contains { $0.activityId == firstComment.id })
        XCTAssertEqual(fixture.notifications.records.map(\.pullRequestId), [primary.id])
    }

    @MainActor
    func testArchivedRetiringSiblingSuppressesActiveAndFinalActivityFromSameRepository() async throws {
        let primary = makePullRequest(id: "PR_PRIMARY", title: "Primary", archived: false)
        let sibling = makePullRequest(id: "PR_RETIRING_SIBLING", title: "Retiring sibling", archived: false)
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(
            pullRequest: primary, additionalPullRequests: [sibling], provider: provider
        )
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }

        let activeComment = PullRequestCommentActivity(
            id: "COMMENT_ACTIVE_MIXED",
            url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-COMMENT_ACTIVE_MIXED")!,
            author: "reviewer",
            createdAt: Date(timeIntervalSince1970: 30), source: .pullRequest
        )
        let finalComment = PullRequestCommentActivity(
            id: "COMMENT_RETIRED_MIXED",
            url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-COMMENT_RETIRED_MIXED")!,
            author: "reviewer",
            createdAt: Date(timeIntervalSince1970: 40), source: .pullRequest
        )
        let currentPrimary = makePullRequest(
            id: primary.id, title: primary.title, archived: false,
            comments: primary.recentCommentActivities + [activeComment]
        )
        let retiringSibling = makePullRequest(
            id: sibling.id, title: sibling.title, archived: true,
            comments: sibling.recentCommentActivities + [finalComment]
        )
        provider.finish(with: CompletePullRequestFetchResult(
            activePullRequests: [currentPrimary], retiringPullRequests: [retiringSibling]
        ))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.state.pullRequests.map(\.id), [primary.id])
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState?.processedActivityByPullRequestID[primary.id]?.commentIDs.count, 2)
    }

    @MainActor
    func testSuccessfulArchiveStatusRefreshUpdatesPresentationAndFailedRefreshPreservesIt() async throws {
        let baseline = makePullRequest(id: "PR_ARCHIVED", title: "Archived", archived: true)
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(pullRequest: baseline, provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }
        XCTAssertTrue(fixture.controller.sourceFilteredMyPullRequests.isEmpty)
        XCTAssertTrue(fixture.controller.visiblePullRequestNotifications.isEmpty)

        let unarchived = makePullRequest(id: baseline.id, title: baseline.title, archived: false)
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [unarchived]))
        await waitUntil { !fixture.controller.isRefreshing }
        XCTAssertEqual(fixture.controller.sourceFilteredMyPullRequests.map(\.id), [baseline.id])
        XCTAssertEqual(fixture.controller.visiblePullRequestNotifications.count, 1)

        provider.failNextFetch()
        fixture.controller.refresh()
        await waitUntil { provider.fetchCount == 2 && !fixture.controller.isRefreshing }
        XCTAssertNotNil(fixture.controller.refreshErrorMessage)
        XCTAssertEqual(fixture.controller.sourceFilteredMyPullRequests.map(\.id), [baseline.id])
        XCTAssertEqual(fixture.preferences.pullRequestSyncState?.dashboard.pullRequests.first?.repositoryIsArchived, false)

        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [baseline]))
        fixture.controller.refresh()
        await waitUntil { provider.fetchCount == 3 && !fixture.controller.isRefreshing }
        XCTAssertTrue(fixture.controller.sourceFilteredMyPullRequests.isEmpty)
        XCTAssertTrue(fixture.controller.visiblePullRequestNotifications.isEmpty)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, 1)
    }

    @MainActor
    func testUnarchiveRefreshRestoresVisibilityAndDeliversNewCommentWithToggleOn() async throws {
        let baseline = makePullRequest(id: "PR_UNARCHIVED", title: "Unarchived", archived: true)
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(pullRequest: baseline, provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }
        XCTAssertTrue(fixture.controller.hideArchivedRepositories)
        XCTAssertTrue(fixture.controller.sourceFilteredMyPullRequests.isEmpty)
        XCTAssertTrue(fixture.controller.visiblePullRequestNotifications.isEmpty)

        let comment = PullRequestCommentActivity(
            id: "COMMENT_AFTER_UNARCHIVE",
            url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-COMMENT_AFTER_UNARCHIVE")!,
            author: "reviewer",
            createdAt: Date(timeIntervalSince1970: 30), source: .pullRequest
        )
        let unarchived = makePullRequest(
            id: baseline.id, title: baseline.title, archived: false,
            comments: baseline.recentCommentActivities + [comment]
        )
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [unarchived]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertTrue(fixture.controller.hideArchivedRepositories)
        XCTAssertEqual(fixture.controller.sourceFilteredMyPullRequests.map(\.id), [baseline.id])
        XCTAssertEqual(fixture.controller.visiblePullRequestNotifications.count, 2)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, fixture.previous.notificationHistory.count + 1)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.filter { $0.activityId == comment.id }.count, 1)
        XCTAssertEqual(fixture.notifications.records.map(\.pullRequestId), [baseline.id])

        fixture.controller.refresh()
        await waitUntil { provider.fetchCount == 2 && !fixture.controller.isRefreshing }
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.filter { $0.activityId == comment.id }.count, 1)
        XCTAssertEqual(fixture.notifications.records.count, 1)
    }

    @MainActor
    func testLargeCompleteResultPublishesOnlyAfterAllActivityIsPrepared() async throws {
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }
        let comments = (0..<61).map { index in
            PullRequestCommentActivity(
                id: "LARGE_COMMENT_\(index)",
                url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-fixture")!,
                author: "reviewer",
                createdAt: Date(timeIntervalSince1970: TimeInterval(100 + 2 * index)),
                source: .pullRequest
            )
        }
        let reviews = (0..<60).map { index in
            PullRequestReview(
                id: "LARGE_REVIEW_\(index)",
                url: URL(string: "https://github.com/acme/app/pull/42#pullrequestreview-fixture")!,
                state: .approved,
                submittedAt: Date(timeIntervalSince1970: TimeInterval(101 + 2 * index)),
                author: "reviewer"
            )
        }
        let current = makePullRequest(
            id: fixture.pullRequest.id,
            title: "Large complete result",
            comments: comments,
            reviews: reviews
        )

        XCTAssertEqual(fixture.controller.state, fixture.previous.dashboard)
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [current]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.state.pullRequests.first?.recentCommentActivities, [])
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, 100)
        let expectedNewest = (
            comments.map { ($0.id, $0.createdAt) }
                + reviews.map { ($0.id, $0.submittedAt) }
        ).sorted { $0.1 > $1.1 }.prefix(100).map(\.0)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.compactMap(\.activityId), expectedNewest)
        XCTAssertEqual(fixture.notifications.records.count, 121)
    }

    @MainActor
    func testEqualActivityTimestampsUseDeterministicHistoryTieBreak() async throws {
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }
        let timestamp = Date(timeIntervalSince1970: 200)
        let comments = (0..<56).map { index in
            PullRequestCommentActivity(
                id: String(format: "EQUAL_COMMENT_%02d", index),
                url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-fixture")!,
                author: "reviewer",
                createdAt: timestamp,
                source: .pullRequest
            )
        }
        let reviews = (0..<55).map { index in
            PullRequestReview(
                id: String(format: "EQUAL_REVIEW_%02d", index),
                url: URL(string: "https://github.com/acme/app/pull/42#pullrequestreview-fixture")!,
                state: .approved,
                submittedAt: timestamp,
                author: "reviewer"
            )
        }
        let current = makePullRequest(
            id: fixture.pullRequest.id,
            title: "Equal timestamps",
            comments: comments,
            reviews: reviews
        )

        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [current]))
        await waitUntil { !fixture.controller.isRefreshing }

        let expected = (comments.map(\.id) + reviews.map(\.id)).sorted(by: >).prefix(100)
        XCTAssertEqual(
            fixture.controller.pullRequestNotificationHistory.compactMap(\.activityId),
            Array(expected)
        )
        XCTAssertEqual(fixture.notifications.records.count, 111)
    }

    @MainActor
    func testRepeatedRefreshRequestsShareOneSuspendedAttempt() async throws {
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }

        fixture.controller.refresh()
        fixture.controller.refresh()
        await Task.yield()
        XCTAssertEqual(provider.fetchCount, 1)
        XCTAssertEqual(fixture.controller.state, fixture.previous.dashboard)

        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [fixture.pullRequest]))
        await waitUntil { !fixture.controller.isRefreshing }
        XCTAssertEqual(provider.fetchCount, 1)
    }

    @MainActor
    func testSignOutPreventsLateRefreshWriteAndNotificationDelivery() async throws {
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }

        fixture.controller.signOut()
        let late = makePullRequest(
            id: fixture.pullRequest.id,
            title: "Late",
            comments: fixture.pullRequest.recentCommentActivities + [
                PullRequestCommentActivity(
                    id: "COMMENT_LATE",
                    url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-fixture")!,
                    author: "teammate",
                    createdAt: Date(timeIntervalSince1970: 20),
                    source: .pullRequest
                )
            ]
        )
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [late]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.state.authStatus, .signedOut)
        XCTAssertTrue(fixture.controller.state.pullRequests.isEmpty)
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
    }

    @MainActor
    func testFinalRetirementNotificationRetainsTitleAndOpenableURL() async throws {
        let baseline = makePullRequest(id: "PR_MERGED", title: "Ship atomic refresh")
        let final = makePullRequest(
            id: baseline.id,
            title: baseline.title,
            comments: baseline.recentCommentActivities + [
                PullRequestCommentActivity(
                    id: "COMMENT_FINAL",
                    url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-COMMENT_FINAL")!,
                    author: "reviewer",
                    createdAt: Date(timeIntervalSince1970: 20),
                    source: .pullRequest
                )
            ]
        )
        let provider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [], retiringPullRequests: [final]))
        )
        var openedURLs: [URL] = []
        let fixture = try makeFixture(
            pullRequest: baseline,
            provider: provider,
            urlOpener: { openedURLs.append($0) }
        )
        defer { fixture.cleanup() }

        await waitUntil { provider.fetchCount == 1 }
        await waitUntil { !fixture.controller.isRefreshing }
        let notification = try XCTUnwrap(
            fixture.controller.pullRequestNotificationHistory.first { $0.activityId == "COMMENT_FINAL" }
        )
        XCTAssertEqual(notification.prTitle, baseline.title)
        XCTAssertEqual(notification.url, baseline.url)
        XCTAssertTrue(fixture.controller.state.pullRequests.isEmpty)
        XCTAssertEqual(fixture.notifications.records.map(\.eventType), ["new_comment"])

        fixture.controller.openPullRequestNotification(notification)
        XCTAssertEqual(openedURLs, [notification.destinationURL!])
    }

    @MainActor
    func testRefreshAuthenticationFailureKeepsStateForSameAccountSignIn() async throws {
        let provider = AtomicGitHubProvider(
            result: .error(GitHubClientError.httpFailure(endpoint: "GitHub GraphQL", status: 401))
        )
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 && !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.state.authStatus, .signedOut)
        XCTAssertNotNil(fixture.controller.errorMessage)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState, fixture.previous)

        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [fixture.pullRequest]))
        await fixture.controller.signInWithToken("pat")

        XCTAssertEqual(fixture.controller.state.authStatus, .signedIn)
        XCTAssertEqual(fixture.controller.state.pullRequests.map(\.id), [fixture.pullRequest.id])
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, fixture.previous.notificationHistory)
    }

    @MainActor
    func testTransientTokenRefreshFailuresDoNotSignOut() async throws {
        for status in [429, 502] {
            let provider = AtomicGitHubProvider(
                result: .error(GitHubClientError.authRefreshFailed(status: status, detail: nil))
            )
            let fixture = try makeFixture(provider: provider)
            defer { fixture.cleanup() }
            await waitUntil { provider.fetchCount == 1 && !fixture.controller.isRefreshing }

            XCTAssertEqual(fixture.controller.state, fixture.previous.dashboard, "status \(status)")
            XCTAssertNotNil(fixture.controller.refreshErrorMessage)
            XCTAssertEqual(fixture.preferences.pullRequestSyncState, fixture.previous)
        }
    }

    @MainActor
    func testRetryAfterSuppressesAutomaticAttemptsUntilPermitted() async throws {
        let suiteName = "atomic-rate-limit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        let pullRequest = makePullRequest(id: "PR_RATE", title: "Rate limited")
        try preferences.storePullRequestSyncState(makeSyncState(pullRequest))
        let provider = RateLimitedGitHubProvider(
            retryAt: .distantPast,
            retryDelay: 1,
            result: CompletePullRequestFetchResult(activePullRequests: [pullRequest])
        )
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            automaticRefreshInterval: 0.01,
            patGitHubClientFactory: { _ in provider }
        )

        await waitUntil { provider.fetchCount == 2 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(provider.fetchCount, 2)
        await waitUntil(timeout: 3) { provider.fetchCount >= 3 }
        XCTAssertGreaterThanOrEqual(provider.requestDates[2], try XCTUnwrap(provider.issuedRetryAt))
        _ = controller
    }

    @MainActor
    func testHTTP200GraphQLRateLimitHeadersDeferAutomaticClientRequests() async throws {
        let suiteName = "atomic-graphql-rate-limit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            AtomicRateLimitURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suiteName)
        }
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        let transport = AtomicRateLimitTransport(retryAfter: 0.15)
        AtomicRateLimitURLProtocol.handler = { request in try transport.response(for: request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AtomicRateLimitURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            automaticRefreshInterval: 0.01,
            patGitHubClientFactory: { GitHubClient(token: $0, session: session) }
        )

        await waitUntil { transport.graphQLRequestDates.count == 1 }
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(transport.graphQLRequestDates.count, 1)
        await waitUntil(timeout: 0.6) {
            transport.graphQLRequestDates.count >= 3 && controller.state.authStatus == .signedIn
        }

        let requestDates = transport.graphQLRequestDates
        XCTAssertGreaterThanOrEqual(requestDates[1].timeIntervalSince(requestDates[0]), 0.14)
        XCTAssertEqual(controller.state.authStatus, .signedIn)
    }

    @MainActor
    func testCredentialReplacementClearsAccountScopedRateDeferral() async throws {
        let suiteName = "atomic-rate-account-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        let pullRequest = makePullRequest(id: "PR_RATE_ACCOUNT", title: "Old account")
        try preferences.storePullRequestSyncState(makeSyncState(pullRequest))
        let oldProvider = RateLimitedGitHubProvider(
            retryAt: Date().addingTimeInterval(60),
            result: CompletePullRequestFetchResult(activePullRequests: [pullRequest]),
            login: "rw"
        )
        let newPR = makePullRequest(id: "PR_NEW_ACCOUNT", title: "New account")
        let newProvider = RateLimitedGitHubProvider(
            retryAt: .distantFuture,
            result: CompletePullRequestFetchResult(activePullRequests: [newPR]),
            login: "new-user",
            emitsRateLimit: false
        )
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "old"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            automaticRefreshInterval: 0.01,
            patGitHubClientFactory: { token -> any GitHubProviding in
                token == "new" ? newProvider : oldProvider
            }
        )
        await waitUntil { oldProvider.fetchCount == 2 }

        await controller.signInWithToken("new")

        XCTAssertEqual(newProvider.fetchCount, 1)
        XCTAssertEqual(controller.state.account?.login, "new-user")
        XCTAssertEqual(controller.state.pullRequests.map(\.id), [newPR.id])
    }

    @MainActor
    func testNewAccountCompletionDoesNotPersistPriorAccountHistory() async throws {
        let newPR = makePullRequest(id: "PR_BOB", title: "Bob's PR")
        let provider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [newPR])),
            login: "bob"
        )
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }

        await waitUntil { provider.fetchCount == 1 && !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.state.account?.login, "bob")
        XCTAssertEqual(fixture.controller.state.pullRequests.map(\.id), [newPR.id])
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState?.account.login, "bob")
        XCTAssertTrue(fixture.preferences.pullRequestSyncState?.notificationHistory.isEmpty == true)
    }

    @MainActor
    func testFailedPATAccountReplacementClearsPriorAccountStateAndRelaunchCannotRestoreIt() async throws {
        let oldProvider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_ALICE", title: "Alice's PR")
            ])),
            login: "rw"
        )
        let bobProvider = AtomicGitHubProvider(result: .failure, login: "bob")
        let fixture = try makeFixture(
            provider: oldProvider,
            patProviderFactory: { token in token == "bob-token" ? bobProvider : oldProvider }
        )
        defer { fixture.cleanup() }
        await waitUntil { oldProvider.fetchCount == 1 && !fixture.controller.isRefreshing }

        await fixture.controller.signInWithToken("bob-token")

        XCTAssertEqual(fixture.controller.refreshErrorMessage, "Refresh failed")
        XCTAssertTrue(fixture.controller.state.pullRequests.isEmpty)
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertNil(fixture.preferences.pullRequestSyncState)
        XCTAssertEqual(fixture.preferences.pullRequestSnapshotCache, .empty)
        XCTAssertTrue(fixture.preferences.pullRequestNotificationHistory.isEmpty)

        let relaunched = DashboardController(
            tokenStore: InMemoryTokenStore(token: "bob-token"),
            preferencesStore: fixture.preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in bobProvider }
        )
        await waitUntil { bobProvider.fetchCount >= 2 && relaunched.refreshErrorMessage != nil }
        XCTAssertTrue(relaunched.state.pullRequests.isEmpty)
        XCTAssertTrue(relaunched.pullRequestNotificationHistory.isEmpty)
    }

    @MainActor
    func testFailedOAuthAccountReplacementClearsPriorAccountState() async throws {
        let oldProvider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_ALICE_OAUTH", title: "Alice before OAuth")
            ]))
        )
        let bobProvider = AtomicGitHubProvider(result: .failure, login: "bob")
        var openedDeviceFlowURLs: [URL] = []
        let fixture = try makeFixture(
            provider: oldProvider,
            oauthSignIn: ImmediateAtomicOAuthSignIn(),
            oauthProvider: bobProvider,
            deviceFlowURLOpener: { openedDeviceFlowURLs.append($0) }
        )
        defer { fixture.cleanup() }
        await waitUntil { oldProvider.fetchCount == 1 && !fixture.controller.isRefreshing }

        await fixture.controller.signInWithGitHub()
        await waitUntil { fixture.controller.refreshErrorMessage == "Refresh failed" }

        XCTAssertEqual(openedDeviceFlowURLs, [URL(string: "https://github.com/login/device")!])
        XCTAssertTrue(fixture.controller.state.pullRequests.isEmpty)
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertNil(fixture.preferences.pullRequestSyncState)
        XCTAssertEqual(fixture.preferences.pullRequestSnapshotCache, .empty)
        XCTAssertTrue(fixture.preferences.pullRequestNotificationHistory.isEmpty)
    }

    @MainActor
    func testUnverifiedPATReplacementFailureRetainsPriorAccountState() async throws {
        let oldProvider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_ALICE_UNVERIFIED", title: "Alice remains")
            ]))
        )
        let invalidProvider = AtomicGitHubProvider(result: .failure, login: "bob", viewerFails: true)
        let fixture = try makeFixture(
            provider: oldProvider,
            patProviderFactory: { token in token == "invalid" ? invalidProvider : oldProvider }
        )
        defer { fixture.cleanup() }
        await waitUntil { oldProvider.fetchCount == 1 && !fixture.controller.isRefreshing }
        let priorDashboard = fixture.controller.state
        let priorHistory = fixture.controller.pullRequestNotificationHistory
        let priorPersisted = fixture.preferences.pullRequestSyncState

        await fixture.controller.signInWithToken("invalid")

        XCTAssertEqual(fixture.controller.state, priorDashboard)
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory, priorHistory)
        XCTAssertEqual(fixture.preferences.pullRequestSyncState, priorPersisted)
    }

    @MainActor
    func testDifferentAccountReplacementClearsSourcesCatalogBeforeSuspendedRefreshCompletes() async throws {
        let oldProvider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_SOURCE_OWNER", title: "Old source owner")
            ]))
        )
        let bobProvider = AtomicGitHubProvider(result: .suspended, login: "bob")
        let catalog = SourceCatalog(
            repositories: [RepositorySource(owner: "acme", name: "private-app")],
            accountLogin: "rw"
        )
        let fixture = try makeFixture(
            provider: oldProvider,
            patProviderFactory: { token in token == "bob" ? bobProvider : oldProvider },
            sourceCatalog: catalog
        )
        defer { fixture.cleanup() }
        await waitUntil { oldProvider.fetchCount == 1 && !fixture.controller.isRefreshing }
        let sourcePreferences = SourcePreferences(
            owners: [
                "acme": OwnerSourcePreferences(
                    notifications: false,
                    myPullRequests: true,
                    reviewRequests: false
                )
            ],
            repositories: [:]
        )
        fixture.controller.sourcePreferences = sourcePreferences

        let signIn = Task { await fixture.controller.signInWithToken("bob") }
        await waitUntil { bobProvider.fetchCount == 1 }

        XCTAssertEqual(fixture.controller.sourceCatalog, .empty)
        XCTAssertEqual(fixture.preferences.sourceCatalog, .empty)
        XCTAssertNil(fixture.preferences.sourceCatalogSyncedAt)
        XCTAssertNil(fixture.preferences.sourceCatalogAccountLogin)
        XCTAssertEqual(fixture.controller.sourcePreferences, sourcePreferences)
        bobProvider.finish(with: CompletePullRequestFetchResult(activePullRequests: []))
        await signIn.value
    }

    @MainActor
    func testSameAccountCaseVariationPreservesSourcesCatalogDuringSuspendedRefresh() async throws {
        let oldProvider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_SOURCE_SAME", title: "Same source owner")
            ]))
        )
        let sameProvider = AtomicGitHubProvider(result: .suspended, login: "RW")
        let catalog = SourceCatalog(
            repositories: [RepositorySource(owner: "acme", name: "private-app")],
            accountLogin: "rw"
        )
        let fixture = try makeFixture(
            provider: oldProvider,
            patProviderFactory: { token in token == "same" ? sameProvider : oldProvider },
            sourceCatalog: catalog
        )
        defer { fixture.cleanup() }
        await waitUntil { oldProvider.fetchCount == 1 && !fixture.controller.isRefreshing }

        let signIn = Task { await fixture.controller.signInWithToken("same") }
        await waitUntil { sameProvider.fetchCount == 1 }

        XCTAssertEqual(fixture.controller.sourceCatalog, catalog)
        XCTAssertEqual(fixture.preferences.sourceCatalog, catalog)
        XCTAssertNotNil(fixture.preferences.sourceCatalogSyncedAt)
        XCTAssertEqual(fixture.preferences.sourceCatalogAccountLogin, "rw")
        sameProvider.finish(with: CompletePullRequestFetchResult(activePullRequests: []))
        await signIn.value
    }

    @MainActor
    func testSameAccountReauthenticationRetainsHistoryReadFlags() async throws {
        let provider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [
                makePullRequest(id: "PR_BASELINE", title: "Baseline")
            ]))
        )
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 && !fixture.controller.isRefreshing }
        fixture.controller.markPullRequestNotificationRead(
            fixture.controller.pullRequestNotificationHistory[0]
        )

        await fixture.controller.signInWithToken("replacement-pat")

        XCTAssertEqual(provider.fetchCount, 2)
        XCTAssertEqual(fixture.controller.state.account?.login, "rw")
        XCTAssertEqual(fixture.controller.pullRequestNotificationHistory.count, 1)
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory[0].read)
        XCTAssertTrue(fixture.preferences.pullRequestSyncState?.notificationHistory[0].read == true)
    }

    @MainActor
    func testSameAccountLegacyImportRetainsHistoryOnFirstCompleteRefresh() async throws {
        let suiteName = "atomic-legacy-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        let pullRequest = makePullRequest(id: "PR_LEGACY", title: "Legacy history")
        var notification = PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: pullRequest.id, activityId: "LEGACY_COMMENT"),
            pullRequest: pullRequest,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        notification.read = true
        preferences.pullRequestSnapshotCache = PullRequestSnapshotCache(
            pullRequests: [pullRequest],
            account: GitHubAccount(login: "rw"),
            fetchedAt: Date(timeIntervalSince1970: 10),
            source: .github
        )
        preferences.pullRequestNotificationHistory = [notification]
        let provider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [pullRequest]))
        )
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in provider }
        )

        await waitUntil { provider.fetchCount == 1 && !controller.isRefreshing }

        XCTAssertEqual(controller.pullRequestNotificationHistory, [notification])
        XCTAssertEqual(preferences.pullRequestSyncState?.notificationHistory, [notification])
        XCTAssertTrue(preferences.pullRequestSyncState?.notificationHistory[0].read == true)
    }

    @MainActor
    func testLateOldProviderCompletionCannotOverwriteReplacementCredentials() async throws {
        let suiteName = "atomic-late-provider-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = PreferencesStore(defaults: defaults)
        preferences.authMethod = .pat
        let oldPR = makePullRequest(id: "PR_OLD", title: "Old provider")
        try preferences.storePullRequestSyncState(makeSyncState(oldPR))
        let oldProvider = AtomicGitHubProvider(result: .suspended)
        let newPR = makePullRequest(id: "PR_NEW", title: "New provider")
        let newProvider = RateLimitedGitHubProvider(
            retryAt: .distantFuture,
            result: CompletePullRequestFetchResult(activePullRequests: [newPR]),
            login: "new-user",
            emitsRateLimit: false
        )
        let notifications = RecordingNotificationClient()
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "old"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            notificationClient: notifications,
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { token -> any GitHubProviding in
                if token == "new" { return newProvider }
                return oldProvider
            }
        )
        await waitUntil { oldProvider.fetchCount == 1 }

        await controller.signInWithToken("new")
        oldProvider.finish(with: CompletePullRequestFetchResult(activePullRequests: [
            makePullRequest(
                id: oldPR.id,
                title: oldPR.title,
                comments: oldPR.recentCommentActivities + [
                    PullRequestCommentActivity(
                        id: "COMMENT_LATE_OLD_PROVIDER",
                        url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-fixture")!,
                        author: "reviewer",
                        createdAt: Date(timeIntervalSince1970: 40),
                        source: .pullRequest
                    )
                ]
            )
        ]))
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(controller.state.account?.login, "new-user")
        XCTAssertEqual(controller.state.pullRequests.map(\.id), [newPR.id])
        XCTAssertTrue(notifications.records.isEmpty)
    }

    @MainActor
    func testRelationshipUpdateIsTimestampedAtTheRefreshThatObservedIt() async throws {
        let stored = makePullRequest(id: "PR_TRACKED", title: "Tracked", isMine: false)
        let assigned = makePullRequest(
            id: stored.id, title: stored.title, isAssignedToViewer: true, isMine: false,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let provider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [assigned]))
        )
        let fixture = try makeFixture(pullRequest: stored, provider: provider)
        defer { fixture.cleanup() }
        await waitUntilRefreshed(fixture)

        let added = fixture.addedHistory
        XCTAssertEqual(added.map(\.eventType), [.relationshipAdded])
        XCTAssertEqual(added.first?.relationshipChanges, [.assigned])
        XCTAssertEqual(added.first?.createdAt, fixture.controller.state.syncedAt)
    }

    @MainActor
    func testRelationshipUpdateForOldPRStaysAtTopOfFullHistory() async throws {
        let stored = makePullRequest(id: "PR_TRACKED", title: "Tracked", isMine: false)
        let assigned = makePullRequest(
            id: stored.id, title: stored.title, isAssignedToViewer: true, isMine: false,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let seeded = (0..<DashboardController.pullRequestNotificationHistoryLimit).map { index in
            PullRequestNotification(
                event: PullRequestEvent(type: .newComment, prId: stored.id, activityId: "COMMENT_\(index)"),
                pullRequest: stored,
                createdAt: Date(timeIntervalSince1970: 1_000 + TimeInterval(index))
            )
        }
        let provider = AtomicGitHubProvider(
            result: .success(CompletePullRequestFetchResult(activePullRequests: [assigned]))
        )
        let fixture = try makeFixture(pullRequest: stored, notificationHistory: seeded, provider: provider)
        defer { fixture.cleanup() }
        await waitUntilRefreshed(fixture)

        let history = fixture.controller.pullRequestNotificationHistory
        XCTAssertEqual(history.count, DashboardController.pullRequestNotificationHistoryLimit)
        XCTAssertEqual(history.first?.eventType, .relationshipAdded)
        XCTAssertEqual(history.first?.relationshipChanges, [.assigned])
        XCTAssertFalse(history.contains { $0.activityId == "COMMENT_0" })
        XCTAssertTrue(history.contains { $0.activityId == "COMMENT_1" })
    }

    @MainActor
    func testNewlySeenRequestedPRRecordsOneRowAndNotification() async throws {
        let newPR = makePullRequest(id: "PR_NEW", title: "New", reviewRequestKind: .direct, isMine: false)
        let provider = AtomicGitHubProvider(result: .success(CompletePullRequestFetchResult(
            activePullRequests: [makePullRequest(id: "PR_BASELINE", title: "Baseline"), newPR]
        )))
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntilRefreshed(fixture)

        let added = fixture.addedHistory
        XCTAssertEqual(added.map(\.eventType), [.relationshipAdded])
        XCTAssertEqual(added.first?.prId, newPR.id)
        XCTAssertEqual(added.first?.relationshipChanges, [.directReviewRequest])
        XCTAssertEqual(fixture.notifications.records.map(\.title), ["Review requested"])
        XCTAssertEqual(fixture.notifications.records.map(\.pullRequestId), [newPR.id])
    }

    @MainActor
    func testSuppressedNewlySeenPRIsConsumedAndNotReplayedWhenFilterIsReenabled() async throws {
        enum Filter: CaseIterable { case repositoryNotifications, relationshipPreference, archivedRepository }
        for filter in Filter.allCases {
            let newPR = makePullRequest(
                id: "PR_NEW", title: "New", archived: filter == .archivedRepository ? true : nil,
                reviewRequestKind: .direct, isMine: false
            )
            let provider = AtomicGitHubProvider(result: .suspended)
            let fixture = try makeFixture(provider: provider)
            defer { fixture.cleanup() }
            await waitUntil { provider.fetchCount == 1 }
            let controller = fixture.controller
            switch filter {
            case .repositoryNotifications:
                controller.setRepositoryPreferences(
                    repo: newPR.repo,
                    preferences: RepositorySourcePreferences(
                        notifications: .disabled, myPullRequests: .inherit, reviewRequests: .inherit
                    )
                )
            case .relationshipPreference:
                controller.preferences.directReviewRequests.relationshipChanges = false
            case .archivedRepository:
                XCTAssertTrue(controller.hideArchivedRepositories)
            }
            provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [fixture.pullRequest, newPR]))
            await waitUntil { !controller.isRefreshing }

            XCTAssertTrue(fixture.addedHistory.isEmpty, "\(filter)")
            XCTAssertTrue(fixture.notifications.records.isEmpty, "\(filter)")
            XCTAssertEqual(
                fixture.preferences.pullRequestSyncState?.dashboard.pullRequests.map(\.id).contains(newPR.id),
                true,
                "\(filter)"
            )

            switch filter {
            case .repositoryNotifications:
                controller.setRepositoryPreferences(repo: newPR.repo, preferences: .defaults)
            case .relationshipPreference:
                controller.preferences.directReviewRequests.relationshipChanges = true
            case .archivedRepository:
                controller.hideArchivedRepositories = false
            }
            controller.refresh()
            await waitUntil { provider.fetchCount == 2 && !controller.isRefreshing }

            XCTAssertTrue(fixture.addedHistory.isEmpty, "\(filter)")
            XCTAssertTrue(fixture.notifications.records.isEmpty, "\(filter)")
        }
    }

    @MainActor
    func testNewlySeenCombinedPRIsSuppressedOnlyWhenEveryAddedRelationshipIsOff() async throws {
        for assignedEnabled in [false, true] {
            let newPR = makePullRequest(
                id: "PR_NEW", title: "New", reviewRequestKind: .direct, isAssignedToViewer: true, isMine: false
            )
            let provider = AtomicGitHubProvider(result: .suspended)
            let fixture = try makeFixture(provider: provider)
            defer { fixture.cleanup() }
            await waitUntil { provider.fetchCount == 1 }
            fixture.controller.preferences.assigned.relationshipChanges = assignedEnabled
            fixture.controller.preferences.directReviewRequests.relationshipChanges = false
            provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [fixture.pullRequest, newPR]))
            await waitUntil { !fixture.controller.isRefreshing }

            if assignedEnabled {
                XCTAssertEqual(fixture.addedHistory.map(\.relationshipChanges), [[.assigned, .directReviewRequest]])
                XCTAssertEqual(fixture.notifications.records.map(\.title), ["Assigned and review requested"])
            } else {
                XCTAssertTrue(fixture.addedHistory.isEmpty)
                XCTAssertTrue(fixture.notifications.records.isEmpty)
            }
        }
    }

    @MainActor
    func testNewlySeenRequestedPRKeepsHistoryRowWhenMacOSNotificationsAreOff() async throws {
        let newPR = makePullRequest(id: "PR_NEW", title: "New", reviewRequestKind: .direct, isMine: false)
        let provider = AtomicGitHubProvider(result: .suspended)
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntil { provider.fetchCount == 1 }
        fixture.controller.macOSLocalNotificationsEnabled = false
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [fixture.pullRequest, newPR]))
        await waitUntil { !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.addedHistory.map(\.eventType), [.relationshipAdded])
        XCTAssertTrue(fixture.notifications.records.isEmpty)
    }

    @MainActor
    func testNewlySeenRequestedPRIsDeliveredOnceAfterFailedPersistenceIsRetried() async throws {
        let persistence = PersistenceSwitch()
        let newPR = makePullRequest(id: "PR_NEW", title: "New", reviewRequestKind: .direct, isMine: false)
        let provider = AtomicGitHubProvider(result: .success(CompletePullRequestFetchResult(
            activePullRequests: [makePullRequest(id: "PR_BASELINE", title: "Baseline"), newPR]
        )))
        let fixture = try makeFixture(provider: provider, encoder: { state in
            if persistence.fails { throw AtomicTestError.encodingFailed }
            return try JSONEncoder().encode(state)
        })
        defer { fixture.cleanup() }
        await waitUntil { fixture.controller.refreshErrorMessage != nil }

        XCTAssertTrue(fixture.addedHistory.isEmpty)
        XCTAssertTrue(fixture.notifications.records.isEmpty)

        persistence.fails = false
        fixture.controller.refresh()
        await waitUntil { provider.fetchCount == 2 && !fixture.controller.isRefreshing }
        XCTAssertEqual(fixture.addedHistory.map(\.eventType), [.relationshipAdded])
        XCTAssertEqual(fixture.notifications.records.count, 1)

        fixture.controller.refresh()
        await waitUntil { provider.fetchCount == 3 && !fixture.controller.isRefreshing }
        XCTAssertEqual(fixture.addedHistory.count, 1)
        XCTAssertEqual(fixture.notifications.records.count, 1)
    }

    @MainActor
    func testSameAccountReauthenticationNotifiesForNewlySeenRequestedPR() async throws {
        let provider = AtomicGitHubProvider(result: .success(CompletePullRequestFetchResult(
            activePullRequests: [makePullRequest(id: "PR_BASELINE", title: "Baseline")]
        )))
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntilRefreshed(fixture)
        XCTAssertTrue(fixture.addedHistory.isEmpty)

        let newPR = makePullRequest(id: "PR_NEW", title: "New", reviewRequestKind: .direct, isMine: false)
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [fixture.pullRequest, newPR]))
        await fixture.controller.signInWithToken("replacement-pat")
        await waitUntil { provider.fetchCount == 2 && !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.state.account?.login, "rw")
        XCTAssertEqual(fixture.addedHistory.map(\.prId), [newPR.id])
        XCTAssertEqual(fixture.notifications.records.map(\.pullRequestId), [newPR.id])
    }

    @MainActor
    func testSignInAfterSignOutIsQuietBaselineForRequestedPRs() async throws {
        let provider = AtomicGitHubProvider(result: .success(CompletePullRequestFetchResult(
            activePullRequests: [makePullRequest(id: "PR_BASELINE", title: "Baseline")]
        )))
        let fixture = try makeFixture(provider: provider)
        defer { fixture.cleanup() }
        await waitUntilRefreshed(fixture)

        fixture.controller.signOut()
        await waitUntil { !fixture.controller.isRefreshing }
        provider.finish(with: CompletePullRequestFetchResult(activePullRequests: [
            makePullRequest(id: "PR_ASSIGNED", title: "Assigned", isAssignedToViewer: true, isMine: false),
            makePullRequest(id: "PR_DIRECT", title: "Direct", reviewRequestKind: .direct, isMine: false)
        ]))
        await fixture.controller.signInWithToken("pat")
        await waitUntil { provider.fetchCount == 2 && !fixture.controller.isRefreshing }

        XCTAssertEqual(fixture.controller.state.pullRequests.map(\.id).sorted(), ["PR_ASSIGNED", "PR_DIRECT"])
        XCTAssertTrue(fixture.controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertTrue(fixture.notifications.records.isEmpty)
    }

    @MainActor
    private func makeFixture(
        pullRequest: PullRequest = makePullRequest(id: "PR_BASELINE", title: "Baseline"),
        additionalPullRequests: [PullRequest] = [],
        notificationHistory: [PullRequestNotification]? = nil,
        provider: AtomicGitHubProvider,
        encoder: @escaping (PullRequestSyncState) throws -> Data = { try JSONEncoder().encode($0) },
        urlOpener: @escaping @MainActor (URL) -> Void = { _ in },
        oauthSignIn: GitHubOAuthSigningIn? = nil,
        oauthProvider: AtomicGitHubProvider? = nil,
        patProviderFactory: ((String) -> any GitHubProviding)? = nil,
        sourceCatalog: SourceCatalog? = nil,
        deviceFlowURLOpener: @escaping @MainActor (URL) -> Void = { _ in }
    ) throws -> AtomicFixture {
        let suiteName = "atomic-refresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var seedPreferences = PreferencesStore(defaults: defaults)
        seedPreferences.authMethod = .pat
        if let sourceCatalog {
            seedPreferences.sourceCatalog = sourceCatalog
            seedPreferences.sourceCatalogSyncedAt = Date()
            seedPreferences.sourceCatalogAccountLogin = "rw"
        }
        let notification = PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: pullRequest.id, activityId: "COMMENT_OLD"),
            pullRequest: pullRequest,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let previous = PullRequestSyncState(
            account: GitHubAccount(login: "rw"),
            dashboard: DashboardState(
                pullRequests: [pullRequest] + additionalPullRequests,
                events: [],
                syncedAt: Date(timeIntervalSince1970: 10),
                source: .github,
                account: GitHubAccount(login: "rw"),
                authStatus: .signedIn
            ),
            processedActivityByPullRequestID: Dictionary(uniqueKeysWithValues:
                ([pullRequest] + additionalPullRequests).map { pr in
                    (pr.id, ProcessedPullRequestActivity(
                        pullRequestID: pr.id,
                        commentIDs: Set(pr.recentCommentActivities.map(\.id))
                    ))
                }
            ),
            notificationHistory: notificationHistory ?? [notification]
        )
        try seedPreferences.storePullRequestSyncState(previous)
        let preferences = PreferencesStore(defaults: defaults, syncStateEncoder: encoder)
        let notifications = RecordingNotificationClient()
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: preferences,
            launchConfiguration: LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true
            ),
            notificationClient: notifications,
            automaticRefreshInterval: 0,
            oauthSignIn: oauthSignIn,
            patGitHubClientFactory: patProviderFactory ?? { _ in provider },
            oauthGitHubClientFactory: { _ in oauthProvider ?? provider },
            urlOpener: urlOpener,
            deviceFlowURLOpener: deviceFlowURLOpener
        )
        return AtomicFixture(
            suiteName: suiteName,
            controller: controller,
            provider: provider,
            notifications: notifications,
            preferences: preferences,
            previous: previous,
            pullRequest: pullRequest
        )
    }

    /// Waits for a refresh that commits after the stored state, which the fixture seeds at sync time 10.
    @MainActor
    private func waitUntilRefreshed(_ fixture: AtomicFixture) async {
        await waitUntil {
            fixture.controller.state.syncedAt.map { $0 > fixture.previous.dashboard.syncedAt! } == true
                && !fixture.controller.isRefreshing
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }
}

private enum AtomicTestError: Error, LocalizedError {
    case refreshFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .refreshFailed: "Refresh failed"
        case .encodingFailed: "Encoding failed"
        }
    }
}

private final class PersistenceSwitch: @unchecked Sendable {
    var fails = true
}

private final class AtomicGitHubProvider: GitHubProviding {
    enum ResultMode {
        case success(CompletePullRequestFetchResult)
        case failure
        case error(Error)
        case suspended
    }

    let sourceKind: DashboardSource = .github
    private var result: ResultMode
    private let login: String
    private let viewerFails: Bool
    private var continuation: CheckedContinuation<CompletePullRequestFetchResult, Error>?
    private(set) var fetchCount = 0

    init(result: ResultMode, login: String = "rw", viewerFails: Bool = false) {
        self.result = result
        self.login = login
        self.viewerFails = viewerFails
    }

    func fetchViewer() async throws -> GitHubAccount {
        if viewerFails { throw AtomicTestError.refreshFailed }
        return GitHubAccount(login: login)
    }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        fetchCount += 1
        switch result {
        case .success(let value): return value
        case .failure: throw AtomicTestError.refreshFailed
        case .error(let error): throw error
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    func finish(with result: CompletePullRequestFetchResult) {
        self.result = .success(result)
        continuation?.resume(returning: result)
        continuation = nil
    }

    func failNextFetch() { result = .failure }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: accountLogin)
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }
}

@MainActor
private struct ImmediateAtomicOAuthSignIn: GitHubOAuthSigningIn {
    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        DeviceFlowChallenge(
            userCode: "CODE",
            deviceCode: "device",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: Date().addingTimeInterval(600),
            interval: 1
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        OAuthTokens(accessToken: "bob-access", refreshToken: "bob-refresh", expiresAt: .distantFuture)
    }
}

private final class RateLimitedGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    private let lock = NSLock()
    private let retryAt: Date
    private let retryDelay: TimeInterval?
    private let result: CompletePullRequestFetchResult
    private let login: String
    private let emitsRateLimit: Bool
    private var storedRequestDates: [Date] = []
    private var storedIssuedRetryAt: Date?

    /// `retryDelay` measures the retry window from the rate-limited request itself, independent of scheduling delays.
    init(
        retryAt: Date,
        retryDelay: TimeInterval? = nil,
        result: CompletePullRequestFetchResult,
        login: String = "rw",
        emitsRateLimit: Bool = true
    ) {
        self.retryAt = retryAt
        self.retryDelay = retryDelay
        self.result = result
        self.login = login
        self.emitsRateLimit = emitsRateLimit
    }

    var fetchCount: Int { lock.withLock { storedRequestDates.count } }
    var requestDates: [Date] { lock.withLock { storedRequestDates } }
    var issuedRetryAt: Date? { lock.withLock { storedIssuedRetryAt } }

    func fetchViewer() async throws -> GitHubAccount { GitHubAccount(login: login) }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        let count = lock.withLock { () -> Int in
            storedRequestDates.append(Date())
            return storedRequestDates.count
        }
        if emitsRateLimit, count == 2 {
            let issued = retryDelay.map { Date().addingTimeInterval($0) } ?? retryAt
            lock.withLock { storedIssuedRetryAt = issued }
            throw GitHubReadError.rateLimited(retryAt: issued)
        }
        return result
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: accountLogin)
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }
}

private final class AtomicRateLimitTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let retryAfter: TimeInterval
    private var storedGraphQLRequestDates: [Date] = []

    init(retryAfter: TimeInterval) {
        self.retryAfter = retryAfter
    }

    var graphQLRequestDates: [Date] { lock.withLock { storedGraphQLRequestDates } }

    func response(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/user" {
            return response(Self.json(["login": "rw"]), request)
        }
        if request.url?.path == "/user/repos" {
            return response(Self.json([]), request)
        }
        guard request.url?.path == "/graphql" else {
            return response(Self.json(["message": "unexpected"]), request, status: 404)
        }
        let requestNumber = lock.withLock { () -> Int in
            storedGraphQLRequestDates.append(Date())
            return storedGraphQLRequestDates.count
        }
        if requestNumber == 1 {
            return response(
                Self.json(["errors": [["message": "exhausted", "type": "RATE_LIMITED"]]]),
                request,
                headers: ["Retry-After": String(retryAfter)]
            )
        }
        let query = Self.graphQLQuery(request)
        if query.contains("DiscoveryBounds") {
            var data: [String: Any] = [:]
            for lane in GitHubDiscoveryLane.allCases {
                data["\(lane.rawValue)Oldest"] = ["nodes": []]
                data["\(lane.rawValue)Newest"] = ["nodes": []]
            }
            return response(Self.json(["data": data]), request)
        }
        if query.contains("DiscoverPullRequests") {
            var data: [String: Any] = [:]
            for lane in GitHubDiscoveryLane.allCases {
                data[lane.rawValue] = [
                    "issueCount": 0,
                    "nodes": [],
                    "pageInfo": [
                        "startCursor": NSNull(),
                        "endCursor": NSNull(),
                        "hasPreviousPage": false,
                        "hasNextPage": false
                    ]
                ]
            }
            return response(Self.json(["data": data]), request)
        }
        return response(Self.json(["message": "unexpected query"]), request, status: 500)
    }

    private func response(
        _ data: Data,
        _ request: URLRequest,
        status: Int = 200,
        headers: [String: String]? = nil
    ) -> (Data, HTTPURLResponse) {
        (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }

    private static func graphQLQuery(_ request: URLRequest) -> String {
        guard let body = requestBody(request),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ""
        }
        return object["query"] as? String ?? ""
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private final class AtomicRateLimitURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
private struct AtomicFixture {
    let suiteName: String
    let controller: DashboardController
    let provider: AtomicGitHubProvider
    let notifications: RecordingNotificationClient
    let preferences: PreferencesStore
    let previous: PullRequestSyncState
    let pullRequest: PullRequest

    func cleanup() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    /// History rows the controller added on top of the seeded history.
    var addedHistory: [PullRequestNotification] {
        let seededIDs = Set(previous.notificationHistory.map(\.id))
        return controller.pullRequestNotificationHistory.filter { !seededIDs.contains($0.id) }
    }
}

private func makePullRequest(
    id: String,
    title: String,
    archived: Bool? = nil,
    comments: [PullRequestCommentActivity] = [
        PullRequestCommentActivity(
            id: "COMMENT_OLD",
            url: URL(string: "https://github.com/acme/app/pull/42#issuecomment-fixture")!,
            author: "teammate",
            createdAt: Date(timeIntervalSince1970: 5),
            source: .pullRequest
        )
    ],
    reviews: [PullRequestReview] = [],
    reviewRequestKind: ReviewRequestKind = .none,
    isAssignedToViewer: Bool = false,
    isMine: Bool = true,
    updatedAt: Date = Date(timeIntervalSince1970: 20)
) -> PullRequest {
    PullRequest(
        id: id,
        title: title,
        number: 42,
        url: URL(string: "https://github.com/acme/app/pull/42")!,
        repo: "acme/app",
        repositoryIsArchived: archived,
        ciState: .passing,
        reviewDecision: .noReviewYet,
        commentCount: comments.count,
        commentActivityCount: comments.count,
        recentCommentActivities: comments,
        reviewCount: reviews.count,
        recentReviews: reviews,
        headRefOid: "abc",
        reviewRequestKind: reviewRequestKind,
        isAssignedToViewer: isAssignedToViewer,
        isMine: isMine,
        author: isMine ? "rw" : "teammate",
        headRefName: "feature",
        mergeable: .mergeable,
        draft: false,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: updatedAt
    )
}

private func makeSyncState(_ pullRequest: PullRequest) -> PullRequestSyncState {
    let account = GitHubAccount(login: "rw")
    return PullRequestSyncState(
        account: account,
        dashboard: DashboardState(
            pullRequests: [pullRequest],
            events: [],
            syncedAt: Date(timeIntervalSince1970: 10),
            source: .github,
            account: account,
            authStatus: .signedIn
        ),
        processedActivityByPullRequestID: [
            pullRequest.id: ProcessedPullRequestActivity(
                pullRequestID: pullRequest.id,
                commentIDs: Set(pullRequest.recentCommentActivities.map(\.id))
            )
        ]
    )
}
