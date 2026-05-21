import Foundation

public enum PRActivityDetector {
    public static func detect(previous: PullRequest?, current: PullRequest) -> [PullRequestEvent] {
        guard let previous else {
            return []
        }

        var events: [PullRequestEvent] = []

        let reviewEvents = reviewOutcomeEvents(previous: previous, current: current)
        events.append(contentsOf: reviewEvents)

        if reviewEvents.isEmpty, current.commentActivityCount > previous.commentActivityCount {
            events.append(PullRequestEvent(
                type: .newComment,
                prId: current.id,
                count: current.commentActivityCount - previous.commentActivityCount
            ))
        }

        if current.isMine, previous.ciState != .failing, current.ciState == .failing {
            events.append(PullRequestEvent(type: .ciFailed, prId: current.id))
        }

        return events
    }

    private static func reviewOutcomeEvents(previous: PullRequest, current: PullRequest) -> [PullRequestEvent] {
        let previousReviewIds = Set(previous.recentReviews.map(\.id))
        return current.recentReviews
            .filter { !previousReviewIds.contains($0.id) }
            .sorted { $0.submittedAt < $1.submittedAt }
            .map { review in
                PullRequestEvent(type: reviewEventType(for: review.state), prId: current.id)
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
