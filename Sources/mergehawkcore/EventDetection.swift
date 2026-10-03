import Foundation

public enum PRActivityDetector {
    /// Compares an active PR with its snapshot from the previous trusted refresh. The caller skips this on the
    /// baseline sync. A nil `previous` means the PR is first seen after the baseline: its current relationships
    /// count as newly added, while its draft and CI states stay baselined. A tracked PR the viewer did not author
    /// that changes from draft to ready gets a Ready for review update, timestamped by the refresh that observed it.
    public static func detectTransitions(previous: PullRequest?, current: PullRequest) -> [PullRequestEvent] {
        var events = relationshipAddedEvents(previous: previous, current: current)
        if let previous, previous.draft, !current.draft, !current.isMine {
            events.append(PullRequestEvent(type: .readyForReview, prId: current.id))
        }
        if let previous, previous.ciState != .failing, current.ciState == .failing {
            events.append(PullRequestEvent(type: .ciFailed, prId: current.id))
        }
        return events
    }

    /// Emits review decisions and comment updates that the previous processed record has not seen yet.
    ///
    /// Comment updates are newly published comments, newly submitted comment-only review summaries with text,
    /// and previously processed ones that newly mention the viewer. Decision summaries never become comment
    /// updates, and a review never hides its inline comments.
    public static func detectProcessedPeopleActivity(
        previous: ProcessedPullRequestActivity?,
        current: PullRequest
    ) -> [PullRequestEvent] {
        guard let previous else { return [] }
        let decisionEvents = current.recentReviews
            .filter { $0.state != .commented && !previous.includesReview($0) && !$0.viewerDidAuthor }
            .sorted { $0.submittedAt < $1.submittedAt }
            .map { review in
                PullRequestEvent(
                    type: review.state == .approved ? .reviewApproved : .changesRequested,
                    prId: current.id,
                    count: 1,
                    actorLogin: review.author,
                    actorIsBot: review.authorIsBot,
                    activityId: review.id,
                    destinationURL: review.url,
                    happenedAt: review.submittedAt
                )
            }

        let participationStarts = threadParticipationStarts(in: current)
        let priorMentions = previous.mentioningActivityIDs
        func newlyMentions(_ id: String) -> Bool {
            priorMentions.map { !$0.contains(id) } ?? false
        }
        var commentEvents: [PullRequestEvent] = []
        for review in current.recentReviews where isCommentSummary(review) && !review.viewerDidAuthor {
            let isNew = !previous.includesReview(review)
            guard isNew || (review.mentionsViewer && newlyMentions(review.id)) else { continue }
            commentEvents.append(PullRequestEvent(
                type: .reviewCommented,
                prId: current.id,
                count: 1,
                actorLogin: review.author,
                actorIsBot: review.authorIsBot,
                activityId: review.id,
                destinationURL: review.url,
                happenedAt: isNew ? review.submittedAt : review.updatedAt,
                commentReason: review.mentionsViewer ? .mention : .general
            ))
        }
        for comment in current.recentCommentActivities where !comment.viewerDidAuthor {
            let isNew = !previous.includesComment(comment)
            let reason: PullRequestCommentReason
            let happenedAt: Date
            if isNew {
                reason = comment.mentionsViewer ? .mention
                    : participates(comment, starts: participationStarts) ? .threadParticipation
                    : .general
                happenedAt = comment.publishedAt ?? comment.createdAt
            } else if comment.publishedAt != nil, comment.mentionsViewer, newlyMentions(comment.id) {
                reason = .mention
                happenedAt = comment.updatedAt
            } else {
                continue
            }
            commentEvents.append(PullRequestEvent(
                type: commentEventType(for: comment.source),
                prId: current.id,
                count: 1,
                actorLogin: comment.author,
                actorIsBot: comment.authorIsBot,
                activityId: comment.id,
                destinationURL: comment.url,
                happenedAt: happenedAt,
                commentReason: reason
            ))
        }
        return decisionEvents + commentEvents.enumerated()
            .sorted { ($0.element.happenedAt ?? .distantPast, $0.offset) < ($1.element.happenedAt ?? .distantPast, $1.offset) }
            .map(\.element)
    }

    /// Complete fetches return every comment and review, so the current IDs replace the previous record.
    public static func processedActivity(for current: PullRequest) -> ProcessedPullRequestActivity {
        ProcessedPullRequestActivity(
            pullRequestID: current.id,
            commentIDs: Set(current.recentCommentActivities.map(\.id)),
            submittedReviewIDs: Set(current.recentReviews.map(\.id)),
            mentioningActivityIDs: Set(
                current.recentCommentActivities
                    .filter { $0.publishedAt != nil && $0.mentionsViewer }
                    .map(\.id)
                + current.recentReviews
                    .filter { isCommentSummary($0) && $0.mentionsViewer }
                    .map(\.id)
            )
        )
    }

    /// A comment-only review contributes a comment update only when its summary has text.
    private static func isCommentSummary(_ review: PullRequestReview) -> Bool {
        review.state == .commented && review.hasSummaryText
    }

    /// The earliest publication of a viewer comment still present in each review thread. Unpublished drafts
    /// and deleted comments establish nothing.
    private static func threadParticipationStarts(in pullRequest: PullRequest) -> [String: Date] {
        pullRequest.recentCommentActivities.reduce(into: [:]) { starts, comment in
            guard comment.viewerDidAuthor, let threadId = comment.threadId, let publishedAt = comment.publishedAt else {
                return
            }
            starts[threadId] = min(starts[threadId] ?? publishedAt, publishedAt)
        }
    }

    /// Joining a thread covers comments published at or after the viewer's first comment there, never earlier ones.
    private static func participates(_ comment: PullRequestCommentActivity, starts: [String: Date]) -> Bool {
        guard let threadId = comment.threadId, let start = starts[threadId], let publishedAt = comment.publishedAt else {
            return false
        }
        return publishedAt >= start
    }

    /// One combined update for the relationships the viewer gained, timestamped by the refresh that observed it.
    private static func relationshipAddedEvents(previous: PullRequest?, current: PullRequest) -> [PullRequestEvent] {
        guard !current.isMine else {
            return []
        }
        let changes = Set(NotificationPreferences.relationships(matching: current))
            .subtracting(previous.map(NotificationPreferences.relationships(matching:)) ?? [])
            .subtracting([.authored])
        guard !changes.isEmpty else {
            return []
        }
        return [PullRequestEvent(type: .relationshipAdded, prId: current.id, relationshipChanges: changes)]
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
