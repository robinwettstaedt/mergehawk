import Foundation

public enum PRActivityDetector {
    public static func detect(previous: PullRequest?, current: PullRequest) -> [PullRequestEvent] {
        guard let previous else {
            return []
        }

        var events: [PullRequestEvent] = []

        let reviewEvents = reviewOutcomeEvents(previous: previous, current: current)
        events.append(contentsOf: reviewEvents)
        events.append(contentsOf: commentEvents(previous: previous, current: current))

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

    private static func commentEvents(previous: PullRequest, current: PullRequest) -> [PullRequestEvent] {
        let previousCommentIds = Set(previous.recentCommentActivities.map(\.id))
        return current.recentCommentActivities
            .filter { !previousCommentIds.contains($0.id) }
            .filter { !$0.viewerDidAuthor }
            .sorted { $0.createdAt < $1.createdAt }
            .map { comment in
                PullRequestEvent(
                    type: .newComment,
                    prId: current.id,
                    count: 1,
                    actorLogin: comment.author,
                    activityId: comment.id,
                    happenedAt: comment.createdAt
                )
            }
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

    public static func filter(
        _ events: [PullRequestEvent],
        preferences: NotificationPreferences
    ) -> [PullRequestEvent] {
        events.filter { preferences.allows($0.type) }
    }
}
