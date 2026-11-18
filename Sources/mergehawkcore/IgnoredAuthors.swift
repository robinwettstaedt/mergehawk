import Foundation

/// Decides whether a PR is ignored because of who opened it: a GitHub bot while bots are ignored, or an account
/// on the ignored accounts list.
public struct IgnoredAuthors: Equatable, Sendable {
    public let ignoresBots: Bool
    private let accounts: Set<String>
    private let knownBotLogins: Set<String>

    /// `accounts` are cleaned logins in any case. `knownBotLogins` are lowercased logins of authors GitHub marked
    /// as bots, used for PRs and rows that carry no bot type of their own.
    public init(ignoresBots: Bool, accounts: [String], knownBotLogins: Set<String>) {
        self.ignoresBots = ignoresBots
        self.accounts = Set(accounts.map { $0.lowercased() })
        self.knownBotLogins = knownBotLogins
    }

    /// The login a user meant when typing `input`, or nil when nothing is left. Removes surrounding whitespace,
    /// one leading `@`, one leading `app/` and one trailing `[bot]`, and keeps the letter case.
    public static func cleanedLogin(_ input: String) -> String? {
        var login = Substring(input.trimmingCharacters(in: .whitespacesAndNewlines))
        if login.hasPrefix("@") {
            login = login.dropFirst()
        }
        if login.lowercased().hasPrefix("app/") {
            login = login.dropFirst(4)
        }
        if login.lowercased().hasSuffix("[bot]") {
            login = login.dropLast(5)
        }
        let cleaned = login.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Lowercased logins of PR authors GitHub marked as bots, from current PRs and stored notification rows.
    public static func knownBotLogins(
        pullRequests: [PullRequest],
        notifications: [PullRequestNotification]
    ) -> Set<String> {
        var logins = Set(pullRequests.filter { $0.authorIsBot == true }.map { $0.author.lowercased() })
        for notification in notifications where notification.prAuthorIsBot == true {
            if let author = notification.prAuthor {
                logins.insert(author.lowercased())
            }
        }
        return logins
    }

    /// Whether a PR opened by `author` is ignored. `isBot` is the author's GitHub type when known. A known
    /// non-bot is never treated as a bot, because a person and a bot can share a login.
    public func ignores(author: String?, isBot: Bool?) -> Bool {
        guard let author else {
            return false
        }
        let login = author.lowercased()
        if accounts.contains(login) {
            return true
        }
        guard ignoresBots else {
            return false
        }
        switch isBot {
        case true?: return true
        case false?: return false
        case nil: return knownBotLogins.contains(login)
        }
    }

    public func contains(account: String) -> Bool {
        accounts.contains(account.lowercased())
    }
}
