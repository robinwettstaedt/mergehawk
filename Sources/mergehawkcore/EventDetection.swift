import Foundation

public enum PRActivityDetector {
    public static func detect(previous: PullRequest?, current: PullRequest) -> [PullRequestEvent] {
        guard let previous else {
            return []
        }

        var events: [PullRequestEvent] = []

        events.append(contentsOf: relationshipAddedEvents(previous: previous, current: current))
        events.append(contentsOf: otherCommitEvents(previous: previous, current: current))

        let reviewEvents = reviewOutcomeEvents(previous: previous, current: current)
        events.append(contentsOf: reviewEvents)
        events.append(contentsOf: commentEvents(
            previous: previous,
            current: current,
            reviewEventIds: Set(reviewEvents.compactMap(\.activityId))
        ))

        if previous.ciState != .failing, current.ciState == .failing {
            events.append(PullRequestEvent(type: .ciFailed, prId: current.id))
        }

        return events
    }

    private static func relationshipAddedEvents(previous: PullRequest, current: PullRequest) -> [PullRequestEvent] {
        guard !current.isMine else {
            return []
        }

        var changes = Set<PullRequestNotificationRelationship>()
        if !previous.isAssignedToViewer, current.isAssignedToViewer {
            changes.insert(.assigned)
        }
        if !previous.reviewRequestKind.includesDirect, current.reviewRequestKind.includesDirect {
            changes.insert(.directReviewRequest)
        }
        if !previous.reviewRequestKind.includesTeam, current.reviewRequestKind.includesTeam {
            changes.insert(.teamReviewRequest)
        }

        guard !changes.isEmpty else {
            return []
        }
        return [
            PullRequestEvent(
                type: .relationshipAdded,
                prId: current.id,
                happenedAt: current.updatedAt,
                relationshipChanges: changes
            )
        ]
    }

    private static func otherCommitEvents(previous: PullRequest, current: PullRequest) -> [PullRequestEvent] {
        guard current.isMine, previous.hasRecentCommitMetadata else {
            return []
        }

        let previousCommitIds = Set(previous.recentCommits.map(\.oid))
        let newOtherCommits = current.recentCommits
            .filter { !previousCommitIds.contains($0.oid) }
            .filter { commit in
                !commit.otherLogins(comparedTo: current.author).isEmpty
            }
            .sorted { $0.committedAt < $1.committedAt }

        guard !newOtherCommits.isEmpty else {
            return []
        }

        let actorLogins = newOtherCommits
            .flatMap { $0.otherLogins(comparedTo: current.author) }
            .uniquedCaseInsensitive()

        return [
            PullRequestEvent(
                type: .otherCommitAdded,
                prId: current.id,
                count: newOtherCommits.count,
                actorLogin: actorLogins.count == 1 ? actorLogins[0] : nil,
                happenedAt: newOtherCommits.last?.committedAt
            )
        ]
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
        preferences: NotificationPreferences,
        pullRequest: PullRequest
    ) -> [PullRequestEvent] {
        events.filter { preferences.allows(event: $0, for: pullRequest) }
    }
}

private extension PullRequestCommit {
    func otherLogins(comparedTo viewerLogin: String) -> [String] {
        [authorLogin, committerLogin]
            .compactMap { $0 }
            .filter { $0.caseInsensitiveCompare(viewerLogin) != .orderedSame }
    }
}

private extension Array where Element == String {
    func uniquedCaseInsensitive() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for login in self {
            let key = login.lowercased()
            if seen.insert(key).inserted {
                result.append(login)
            }
        }
        return result
    }
}
