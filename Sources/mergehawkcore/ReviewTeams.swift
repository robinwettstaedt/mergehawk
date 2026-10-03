import Foundation

/// A GitHub team, identified by its GraphQL node ID. The slug is the latest one fetched and changes on rename.
public struct TeamReference: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let organization: String
    public let slug: String

    public init(id: String, organization: String, slug: String) {
        self.id = id
        self.organization = organization
        self.slug = slug
    }

    public var displayName: String {
        "@\(organization)/\(slug)"
    }
}

/// A team the viewer belongs to, either directly or as an ancestor of one of their direct teams.
public struct ViewerTeam: Codable, Equatable, Sendable {
    public let team: TeamReference
    /// The node ID of the team's parent team, or nil for a top-level team.
    public let parentTeamID: String?
    public let avatarURL: URL?
    public let organizationAvatarURL: URL?

    public init(
        team: TeamReference,
        parentTeamID: String? = nil,
        avatarURL: URL? = nil,
        organizationAvatarURL: URL? = nil
    ) {
        self.team = team
        self.parentTeamID = parentTeamID
        self.avatarURL = avatarURL
        self.organizationAvatarURL = organizationAvatarURL
    }
}

/// Projects a raw PR onto the review request relationship the viewer counts:
/// a team request counts only when it names one of the viewer's teams that is not turned off.
public struct TeamReviewCounting: Equatable, Sendable {
    public let countedTeamIDs: Set<String>

    public init(viewerTeams: [ViewerTeam], turnedOffTeamIDs: Set<String>) {
        countedTeamIDs = Set(viewerTeams.map(\.team.id)).subtracting(turnedOffTeamIDs)
    }

    /// The raw team flag is ignored; the counted flag comes from the requested teams alone.
    public func applied(to pullRequest: PullRequest) -> PullRequest {
        var copy = pullRequest
        copy.reviewRequestKind = ReviewRequestKind(
            direct: pullRequest.reviewRequestKind.includesDirect,
            team: pullRequest.requestedTeams.contains { countedTeamIDs.contains($0.id) }
        )
        return copy
    }
}
