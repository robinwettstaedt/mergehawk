import Foundation

public enum PRActivityDetector {
    public static func detectTransitions(previous: PullRequest?, current: PullRequest) -> [PullRequestEvent] {
        guard let previous else { return [] }
        var events = relationshipAddedEvents(previous: previous, current: current)
        if previous.ciState != .failing, current.ciState == .failing {
            events.append(PullRequestEvent(type: .ciFailed, prId: current.id))
        }
        return events
    }

    public static func detectProcessedPeopleActivity(
        previous: ProcessedPullRequestActivity?,
        current: PullRequest
    ) -> [PullRequestEvent] {
        guard let previous else { return [] }
        let newReviews = current.recentReviews
            .filter { !previous.includesReview($0) }
            .filter { !$0.viewerDidAuthor }
            .sorted { $0.submittedAt < $1.submittedAt }
        let reviewEvents = newReviews.map { review in
            PullRequestEvent(
                type: reviewEventType(for: review.state),
                prId: current.id,
                count: 1,
                actorLogin: review.author,
                activityId: review.id,
                destinationURL: review.url,
                happenedAt: review.submittedAt
            )
        }
        let representedReviewIDs = Set(newReviews.map(\.id))
        let commentEvents = current.recentCommentActivities
            .filter { !previous.includesComment($0) }
            .filter { !$0.viewerDidAuthor }
            .filter { comment in
                comment.reviewId.map { !representedReviewIDs.contains($0) } ?? true
            }
            .sorted { $0.createdAt < $1.createdAt }
            .map { comment in
                PullRequestEvent(
                    type: commentEventType(for: comment.source),
                    prId: current.id,
                    count: 1,
                    actorLogin: comment.author,
                    activityId: comment.id,
                    destinationURL: comment.url,
                    happenedAt: comment.createdAt
                )
            }
        return reviewEvents + commentEvents
    }

    /// Complete fetches return every comment and review, so the current IDs replace the previous record.
    public static func processedActivity(for current: PullRequest) -> ProcessedPullRequestActivity {
        ProcessedPullRequestActivity(
            pullRequestID: current.id,
            commentIDs: Set(current.recentCommentActivities.map(\.id)),
            submittedReviewIDs: Set(current.recentReviews.map(\.id))
        )
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
