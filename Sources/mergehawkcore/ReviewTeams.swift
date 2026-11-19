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

/// The viewer's teams in Settings › Teams order, each with its nesting depth: organizations in order, top-level teams
/// by slug within an organization, each team followed directly by its child teams, siblings by slug. A team whose
/// parent is not one of the viewer's teams is top level.
public func settingsOrder(of viewerTeams: [ViewerTeam]) -> [(viewerTeam: ViewerTeam, depth: Int)] {
    let viewerTeamIDs = Set(viewerTeams.map(\.team.id))
    let bySlug: (ViewerTeam, ViewerTeam) -> Bool = {
        ($0.team.organization, $0.team.slug, $0.team.id) < ($1.team.organization, $1.team.slug, $1.team.id)
    }
    let childrenByParentID = Dictionary(grouping: viewerTeams.filter {
        $0.parentTeamID.map(viewerTeamIDs.contains) == true
    }) { $0.parentTeamID! }
    let roots = viewerTeams.filter { $0.parentTeamID.map(viewerTeamIDs.contains) != true }.sorted(by: bySlug)

    var ordered: [(viewerTeam: ViewerTeam, depth: Int)] = []
    func append(_ viewerTeam: ViewerTeam, depth: Int) {
        ordered.append((viewerTeam, depth))
        for child in (childrenByParentID[viewerTeam.team.id] ?? []).sorted(by: bySlug) {
            append(child, depth: depth + 1)
        }
    }
    roots.forEach { append($0, depth: 0) }
    return ordered
}

/// Projects a raw PR onto the review request relationship the viewer counts:
/// a team request counts only when it names one of the viewer's teams that is not turned off.
public struct TeamReviewCounting: Equatable, Sendable {
    public let countedTeamIDs: Set<String>
    /// The counted teams in Settings › Teams order.
    public let sectionTeams: [TeamReference]
    /// Parent links of the viewer's whole team tree, turned-off teams included.
    private let parentTeamIDByTeamID: [String: String]

    public init(viewerTeams: [ViewerTeam], turnedOffTeamIDs: Set<String>) {
        let countedTeamIDs = Set(viewerTeams.map(\.team.id)).subtracting(turnedOffTeamIDs)
        self.countedTeamIDs = countedTeamIDs
        sectionTeams = settingsOrder(of: viewerTeams).map(\.viewerTeam.team).filter { countedTeamIDs.contains($0.id) }
        parentTeamIDByTeamID = Dictionary(
            viewerTeams.compactMap { viewerTeam in viewerTeam.parentTeamID.map { (viewerTeam.team.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
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

    /// The team section a PR requesting these teams goes under: of the counted ones, a team that is an ancestor of
    /// another is set aside, so the most specific team wins, then the first remaining one in Settings order.
    /// Nil when no requested team is counted.
    public func sectionTeam(for requestedTeams: [TeamReference]) -> TeamReference? {
        let counted = Set(requestedTeams.map(\.id)).intersection(countedTeamIDs)
        let ancestors = Set(counted.flatMap(ancestorIDs(of:)))
        return sectionTeams.first { counted.contains($0.id) && !ancestors.contains($0.id) }
    }

    private func ancestorIDs(of teamID: String) -> [String] {
        var ancestors: [String] = []
        var current = parentTeamIDByTeamID[teamID]
        while let parent = current, !ancestors.contains(parent) {
            ancestors.append(parent)
            current = parentTeamIDByTeamID[parent]
        }
        return ancestors
    }
}
