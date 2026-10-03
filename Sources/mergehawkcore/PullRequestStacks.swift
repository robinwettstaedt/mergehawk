import Foundation

/// A GitHub native PR stack as read by one complete PR refresh.
public struct PullRequestStack: Codable, Equatable, Sendable, Identifiable {
    /// The stack's node ID.
    public let id: String
    /// The stack size as GitHub reports it, including entries without a readable PR.
    public let size: Int
    /// Entries that have a PR, sorted by position ascending (1 is closest to the base branch).
    public let entries: [PullRequestStackEntry]

    public init(id: String, size: Int, entries: [PullRequestStackEntry]) {
        self.id = id
        self.size = size
        self.entries = entries.sorted { $0.position < $1.position }
    }
}

/// The short summary of one stack member's PR.
public struct PullRequestStackEntry: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case open
        case merged
        case closed
    }

    public let position: Int
    public let pullRequestID: String
    public let number: Int
    public let title: String
    public let url: URL
    public let state: State
    public let isDraft: Bool
    public let author: String
    public let authorAvatarURL: URL?

    public init(
        position: Int,
        pullRequestID: String,
        number: Int,
        title: String,
        url: URL,
        state: State,
        isDraft: Bool,
        author: String,
        authorAvatarURL: URL? = nil
    ) {
        self.position = position
        self.pullRequestID = pullRequestID
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.author = author
        self.authorAvatarURL = authorAvatarURL
    }
}
