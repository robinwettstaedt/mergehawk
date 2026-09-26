@testable import mergehawkcore
import Foundation
import XCTest

final class BotAuthorTests: XCTestCase {
    func testAuthorClassificationUsesOnlyConcreteGitHubType() throws {
        for (type, expected) in [("Bot", true), ("User", false), ("Organization", false)] {
            let data = try JSONSerialization.data(withJSONObject: ["login": "new-name[bot]", "__typename": type])
            let author = try JSONDecoder().decode(GitHubPayloadUser.self, from: data)
            XCTAssertEqual(author.isBot, expected)
        }
        XCTAssertNil(try JSONDecoder().decode(GitHubPayloadUser.self, from: Data(#"{"login":"unknown"}"#.utf8)).isBot)
    }

    func testDetectionCarriesClassificationAndPreservesSelfAndReviewChildSuppression() {
        let date = Date(timeIntervalSince1970: 10)
        let comments = [
            PullRequestCommentActivity(id: "bot-comment", url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-bot-comment")!, authorIsBot: true, createdAt: date, source: .pullRequest),
            PullRequestCommentActivity(id: "human-thread", url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-human-thread")!, authorIsBot: false, createdAt: date, source: .reviewThread),
            PullRequestCommentActivity(id: "self", url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-self")!, authorIsBot: true, viewerDidAuthor: true, createdAt: date, source: .pullRequest),
            PullRequestCommentActivity(id: "child", url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-child")!, authorIsBot: true, createdAt: date, source: .reviewThread, reviewId: "bot-review")
        ]
        let reviews = [
            PullRequestReview(id: "bot-review", url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-bot-review")!, state: .commented, submittedAt: date, authorIsBot: true),
            PullRequestReview(id: "human-review", url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-human-review")!, state: .approved, submittedAt: date, authorIsBot: false),
            PullRequestReview(id: "self-review", url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-self-review")!, state: .changesRequested, submittedAt: date, authorIsBot: true, viewerDidAuthor: true)
        ]
        let pr = PullRequest(id: "PR", title: "PR", number: 1, url: URL(string: "https://example.com")!, repo: "acme/app", ciState: .passing, reviewDecision: .approved, commentCount: 1, recentCommentActivities: comments, reviewCount: 3, recentReviews: reviews, isMine: true, author: "rw", mergeable: .mergeable, draft: false)
        let events = PRActivityDetector.detectProcessedPeopleActivity(previous: ProcessedPullRequestActivity(pullRequestID: pr.id), current: pr)
        XCTAssertEqual(Set(events.compactMap(\.activityId)), ["bot-comment", "human-thread", "bot-review", "human-review"])
        XCTAssertEqual(events.first { $0.activityId == "bot-comment" }?.actorIsBot, true)
        XCTAssertEqual(events.first { $0.activityId == "human-thread" }?.actorIsBot, false)
        XCTAssertEqual(events.first { $0.activityId == "bot-review" }?.actorIsBot, true)
        for event in events {
            let activityURL = comments.first { $0.id == event.activityId }?.url
                ?? reviews.first { $0.id == event.activityId }?.url
            XCTAssertEqual(event.destinationURL, activityURL)
        }
        let processed = PRActivityDetector.processedActivity(for: pr)
        XCTAssertEqual(processed.commentIDs, Set(comments.map(\.id)))
        XCTAssertEqual(processed.submittedReviewIDs, Set(reviews.map(\.id)))
    }

    func testOptionalMetadataDecodesOldModelsAndRoundTripsKnownValues() throws {
        let date = Date(timeIntervalSince1970: 10)
        for classification in [true, false] {
            try check(PullRequestCommentActivity(id: "C", url: URL(string: "https://github.com/acme/app/pull/1#issuecomment-C")!, authorIsBot: classification, createdAt: date, source: .pullRequest), key: "authorIsBot") { XCTAssertNil($0.authorIsBot) }
            try check(PullRequestReview(id: "R", url: URL(string: "https://github.com/acme/app/pull/1#pullrequestreview-R")!, state: .approved, submittedAt: date, authorIsBot: classification), key: "authorIsBot") { XCTAssertNil($0.authorIsBot) }
            try check(PullRequestEvent(type: .newComment, prId: "PR", actorIsBot: classification), key: "actorIsBot") { XCTAssertNil($0.actorIsBot) }
        }
    }

    func testCommentPublicationMetadataRoundTripsAndOldActivityCountsAsPublishedAtCreation() throws {
        let created = Date(timeIntervalSince1970: 10)
        let url = URL(string: "https://github.com/acme/app/pull/1#discussion_r1")!
        let pending = PullRequestCommentActivity(id: "P", url: url, createdAt: created, source: .reviewThread, isPublished: false, threadId: "T")
        let published = PullRequestCommentActivity(id: "S", url: url, createdAt: created, source: .reviewThread, publishedAt: Date(timeIntervalSince1970: 20), updatedAt: Date(timeIntervalSince1970: 30), threadId: "T", mentionsViewer: true)
        for value in [pending, published] {
            XCTAssertEqual(try JSONDecoder().decode(PullRequestCommentActivity.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertNil(pending.publishedAt)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(published)) as? [String: Any])
        ["publishedAt", "updatedAt", "threadId", "mentionsViewer"].forEach { object.removeValue(forKey: $0) }
        let old = try JSONDecoder().decode(PullRequestCommentActivity.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.publishedAt, created)
        XCTAssertEqual(old.updatedAt, created)
        XCTAssertNil(old.threadId)
        XCTAssertFalse(old.mentionsViewer)

        let review = PullRequestReview(id: "R", url: url, state: .commented, submittedAt: created, updatedAt: Date(timeIntervalSince1970: 40), hasSummaryText: true, mentionsViewer: true)
        XCTAssertEqual(try JSONDecoder().decode(PullRequestReview.self, from: JSONEncoder().encode(review)), review)
        var reviewObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(review)) as? [String: Any])
        ["updatedAt", "hasSummaryText", "mentionsViewer"].forEach { reviewObject.removeValue(forKey: $0) }
        let oldReview = try JSONDecoder().decode(PullRequestReview.self, from: JSONSerialization.data(withJSONObject: reviewObject))
        XCTAssertEqual(oldReview.updatedAt, created)
        XCTAssertFalse(oldReview.hasSummaryText)
        XCTAssertFalse(oldReview.mentionsViewer)
    }

    private func check<T: Codable & Equatable>(_ value: T, key: String, old: (T) -> Void) throws {
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: data), value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: key)
        old(try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
