import Foundation

public enum PRActivityDetector {
    public static func detect(previous: PullRequest?, current: PullRequest) -> [PullRequestEvent] {
        guard let previous else {
            return []
        }

        var events: [PullRequestEvent] = []

        if current.commentCount > previous.commentCount {
            events.append(PullRequestEvent(
                type: .newComment,
                prId: current.id,
                count: current.commentCount - previous.commentCount
            ))
        }

        if current.reviewCount > previous.reviewCount {
            events.append(PullRequestEvent(
                type: .newReview,
                prId: current.id,
                count: current.reviewCount - previous.reviewCount
            ))
        }

        if current.isMine, previous.ciState != .failing, current.ciState == .failing {
            events.append(PullRequestEvent(type: .ciFailed, prId: current.id))
        }

        if current.isMine,
           previous.reviewDecision != .changesRequested,
           current.reviewDecision == .changesRequested {
            events.append(PullRequestEvent(type: .changesRequested, prId: current.id))
        }

        return events
    }

    public static func filter(
        _ events: [PullRequestEvent],
        preferences: NotificationPreferences
    ) -> [PullRequestEvent] {
        events.filter { preferences.allows($0.type) }
    }
}
