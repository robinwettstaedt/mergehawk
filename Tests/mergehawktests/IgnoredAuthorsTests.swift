import Foundation
import mergehawkcore
import XCTest

final class IgnoredAuthorsTests: XCTestCase {
    func testCleanedLoginRemovesDecorationAndKeepsCase() {
        let cases: [(String, String?)] = [
            ("@Name", "Name"),
            (" name ", "name"),
            ("app/dependabot", "dependabot"),
            ("dependabot[bot]", "dependabot"),
            ("@renovate[BOT]", "renovate"),
            ("APP/Renovate", "Renovate"),
            ("\tplatform-nora\n", "platform-nora"),
            ("", nil),
            ("  ", nil),
            ("@", nil),
            ("[bot]", nil),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(IgnoredAuthors.cleanedLogin(input), expected, "input \(input.debugDescription)")
        }
    }

    func testIgnoreRule() {
        let known: Set<String> = ["dependabot"]
        struct Case {
            let ignoresBots: Bool
            let accounts: [String]
            let author: String?
            let isBot: Bool?
            let expected: Bool
            let line: UInt
        }
        let cases = [
            // Accounts match case-insensitively whatever the bot flag and toggle.
            Case(ignoresBots: false, accounts: ["Platform-Nora"], author: "platform-nora", isBot: false, expected: true, line: #line),
            Case(ignoresBots: false, accounts: ["platform-nora"], author: "PLATFORM-NORA", isBot: nil, expected: true, line: #line),
            Case(ignoresBots: true, accounts: ["renovate"], author: "Renovate", isBot: true, expected: true, line: #line),
            Case(ignoresBots: false, accounts: ["platform-nora"], author: "teammate", isBot: false, expected: false, line: #line),
            Case(ignoresBots: true, accounts: ["platform-nora"], author: nil, isBot: true, expected: false, line: #line),
            // Bots toggle off.
            Case(ignoresBots: false, accounts: [], author: "dependabot", isBot: true, expected: false, line: #line),
            Case(ignoresBots: false, accounts: [], author: "dependabot", isBot: nil, expected: false, line: #line),
            // Bots toggle on.
            Case(ignoresBots: true, accounts: [], author: "renovate", isBot: true, expected: true, line: #line),
            Case(ignoresBots: true, accounts: [], author: "dependabot", isBot: false, expected: false, line: #line),
            Case(ignoresBots: true, accounts: [], author: "Dependabot", isBot: nil, expected: true, line: #line),
            Case(ignoresBots: true, accounts: [], author: "renovate", isBot: nil, expected: false, line: #line),
            Case(ignoresBots: true, accounts: [], author: nil, isBot: nil, expected: false, line: #line),
        ]
        for value in cases {
            let rule = IgnoredAuthors(ignoresBots: value.ignoresBots, accounts: value.accounts, knownBotLogins: known)
            XCTAssertEqual(rule.ignores(author: value.author, isBot: value.isBot), value.expected, line: value.line)
        }
    }

    func testKnownBotLoginsCollectFlaggedPullRequestsAndRowsLowercased() {
        let pullRequests = [
            pullRequest(id: "PR_BOT", author: "Dependabot", authorIsBot: true),
            pullRequest(id: "PR_HUMAN", author: "teammate", authorIsBot: false),
            pullRequest(id: "PR_UNKNOWN", author: "old-bot", authorIsBot: nil),
        ]
        let rows = [
            notification(for: pullRequest(id: "PR_ROW_BOT", author: "Renovate", authorIsBot: true)),
            notification(for: pullRequest(id: "PR_ROW_HUMAN", author: "reviewer", authorIsBot: false)),
            notification(for: pullRequest(id: "PR_ROW_UNKNOWN", author: "legacy", authorIsBot: nil)),
        ]
        XCTAssertEqual(
            IgnoredAuthors.knownBotLogins(pullRequests: pullRequests, notifications: rows),
            ["dependabot", "renovate"]
        )
    }

    private func pullRequest(id: String, author: String, authorIsBot: Bool?) -> PullRequest {
        PullRequest(
            id: id,
            title: id,
            number: 1,
            url: URL(string: "https://github.com/acme/app/pull/1")!,
            repo: "acme/app",
            ciState: .passing,
            reviewDecision: .reviewRequired,
            commentCount: 0,
            reviewCount: 0,
            isMine: false,
            author: author,
            authorIsBot: authorIsBot,
            mergeable: .mergeable,
            draft: false
        )
    }

    private func notification(for pullRequest: PullRequest) -> PullRequestNotification {
        PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: pullRequest.id),
            pullRequest: pullRequest
        )
    }
}
