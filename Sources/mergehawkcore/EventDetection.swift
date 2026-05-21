import Foundation

public enum PRActivityDetector {
    public static func detect(previous: PullRequest?, current: PullRequest) -> [PullRequestEvent] {
        guard let previous else {
            return []
        }

        var events: [PullRequestEvent] = []

        let reviewEvents = reviewOutcomeEvents(previous: previous, current: current)
        events.append(contentsOf: reviewEvents)
        events.append(contentsOf: commentEvents(
            previous: previous,
            current: current,
            reviewEventIds: Set(reviewEvents.compactMap(\.activityId))
        ))

        if current.isMine, previous.ciState != .failing, current.ciState == .failing {
            events.append(PullRequestEvent(type: .ciFailed, prId: current.id))
        }

        return events
    }

    private static func reviewOutcomeEvents(previous: PullRequest, current: PullRequest) -> [PullRequestEvent] {
        let previousReviewIds = Set(previous.recentReviews.map(\.id))
        return current.recentReviews
            .filter { !previousReviewIds.contains($0.id) }
            .filter { !$0.viewerDidAuthor }
            .sorted { $0.submittedAt < $1.submittedAt }
            .map { review in
                PullRequestEvent(
                    type: reviewEventType(for: review.state),
                    prId: current.id,
                    count: 1,
                    actorLogin: review.author,
                    activityId: review.id,
                    happenedAt: review.submittedAt
                )
            }
    }

    private static func commentEvents(
        previous: PullRequest,
        current: PullRequest,
        reviewEventIds: Set<String>
    ) -> [PullRequestEvent] {
        let previousCommentIds = Set(previous.recentCommentActivities.map(\.id))
        let newComments = current.recentCommentActivities
            .filter { !previousCommentIds.contains($0.id) }
        let detectedEvents = newComments
            .filter { !$0.viewerDidAuthor }
            .filter { comment in
                comment.reviewId.map { !reviewEventIds.contains($0) } ?? true
            }
            .sorted { $0.createdAt < $1.createdAt }
            .map { comment in
                PullRequestEvent(
                    type: commentEventType(for: comment.source),
                    prId: current.id,
                    count: 1,
                    actorLogin: comment.author,
                    activityId: comment.id,
                    happenedAt: comment.createdAt
                )
            }
        let missingCount = max(0, current.commentActivityCount - previous.commentActivityCount - newComments.count)
        guard missingCount > 0 else {
            return detectedEvents
        }
        return detectedEvents + [
            PullRequestEvent(type: .newComment, prId: current.id, count: missingCount)
        ]
    }

    private static func reviewEventType(for state: PullRequestReviewState) -> PullRequestEventType {
        switch state {
        case .approved:
            .reviewApproved
        case .changesRequested:
            .changesRequested
        case .commented:
            .reviewCommented
        }
    }

    private static func commentEventType(for source: PullRequestCommentActivity.Source) -> PullRequestEventType {
        switch source {
        case .pullRequest:
            .newComment
        case .reviewThread:
            .reviewCommented
        }
    }

    public static func filter(
        _ events: [PullRequestEvent],
        preferences: NotificationPreferences
    ) -> [PullRequestEvent] {
        events.filter { preferences.allows($0.type) }
    }
}
