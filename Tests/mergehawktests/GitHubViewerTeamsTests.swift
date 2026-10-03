@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubViewerTeamsTests: XCTestCase {
    func testNestedTeamsListTheDirectTeamAndEveryAncestorWithTheirParents() async throws {
        let transport = ViewerTeamsTransport { _, _ in
            Self.viewerPage(organizations: [
                Self.organization("acme", teams: [
                    Self.team(
                        "T_plm", "plm-team", parent: "T_dev",
                        ancestors: [("T_dev", "developers", "T_eng"), ("T_eng", "engineering", nil)]
                    )
                ])
            ])
        }

        let teams = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")

        XCTAssertEqual(teams, [
            ViewerTeam(team: TeamReference(id: "T_dev", organization: "acme", slug: "developers"), parentTeamID: "T_eng"),
            ViewerTeam(team: TeamReference(id: "T_eng", organization: "acme", slug: "engineering")),
            ViewerTeam(team: TeamReference(id: "T_plm", organization: "acme", slug: "plm-team"), parentTeamID: "T_dev")
        ])
        XCTAssertEqual(transport.queries.count, 1)
        XCTAssertTrue(transport.queries[0].query.contains("userLogins: [$login]"))
        XCTAssertTrue(transport.queries[0].query.contains("id slug avatarUrl(size: 64) parentTeam { id }"))
        XCTAssertEqual(transport.queries[0].variables["login"], .string("rw"))
        XCTAssertEqual(transport.queries[0].variables["orgCursor"], .null)
    }

    func testTeamAncestorAndOrganizationAvatarsAreKeptOnEveryViewerTeam() async throws {
        let transport = ViewerTeamsTransport { query, _ in
            if query.contains("OrganizationViewerTeams") {
                var web = Self.team("T_web", "web")
                web["avatarUrl"] = "https://avatars.githubusercontent.com/t/3?s=64&v=4"
                return Self.json(["data": ["organization": ["teams": Self.teamConnection([web])]]])
            }
            var plm = Self.team("T_plm", "plm-team", parent: "T_dev", ancestors: [("T_dev", "developers", nil)])
            plm["avatarUrl"] = "https://avatars.githubusercontent.com/t/1?s=64&v=4"
            var ancestors = plm["ancestors"] as! [String: Any]
            ancestors["nodes"] = [[
                "id": "T_dev", "slug": "developers", "parentTeam": NSNull(),
                "avatarUrl": "https://avatars.githubusercontent.com/t/2?s=64&v=4"
            ]]
            plm["ancestors"] = ancestors
            return Self.viewerPage(organizations: [
                Self.organization(
                    "acme",
                    teams: [plm],
                    nextTeamCursor: "acme-teams-1",
                    avatarURL: "https://avatars.githubusercontent.com/u/9?v=4"
                ),
                Self.organization("zeta", teams: [Self.team("T_ops", "ops")])
            ])
        }

        let teams = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")

        let byID = Dictionary(uniqueKeysWithValues: teams.map { ($0.team.id, $0) })
        XCTAssertEqual(byID["T_plm"]?.avatarURL?.absoluteString, "https://avatars.githubusercontent.com/t/1?s=64&v=4")
        XCTAssertEqual(byID["T_dev"]?.avatarURL?.absoluteString, "https://avatars.githubusercontent.com/t/2?s=64&v=4")
        XCTAssertEqual(byID["T_web"]?.avatarURL?.absoluteString, "https://avatars.githubusercontent.com/t/3?s=64&v=4")
        for id in ["T_plm", "T_dev", "T_web"] {
            XCTAssertEqual(byID[id]?.organizationAvatarURL?.absoluteString, "https://avatars.githubusercontent.com/u/9?v=4", id)
        }
        XCTAssertNil(byID["T_ops"]?.avatarURL)
        XCTAssertNil(byID["T_ops"]?.organizationAvatarURL)
        // Organizations, direct teams, and ancestors each select an avatar.
        XCTAssertEqual(transport.queries[0].query.components(separatedBy: "avatarUrl(size: 64)").count - 1, 3)
    }

    func testSecretTeamWithoutParentIsOneTopLevelEntry() async throws {
        let transport = ViewerTeamsTransport { _, _ in
            Self.viewerPage(organizations: [Self.organization("acme", teams: [Self.team("T_secret", "secret-squad")])])
        }

        let teams = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")

        XCTAssertEqual(teams, [ViewerTeam(team: TeamReference(id: "T_secret", organization: "acme", slug: "secret-squad"))])
    }

    func testAncestorSharedByTwoDirectTeamsAppearsOnce() async throws {
        let transport = ViewerTeamsTransport { _, _ in
            Self.viewerPage(organizations: [
                Self.organization("acme", teams: [
                    Self.team("T_web", "web", parent: "T_eng", ancestors: [("T_eng", "engineering", nil)]),
                    Self.team("T_api", "api", parent: "T_eng", ancestors: [("T_eng", "engineering", nil)])
                ])
            ])
        }

        let teams = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")

        XCTAssertEqual(teams.map(\.team.slug), ["api", "engineering", "web"])
        XCTAssertEqual(teams.map(\.parentTeamID), ["T_eng", nil, "T_eng"])
    }

    func testTeamThatIsDirectAndAnAncestorOfAnotherDirectTeamAppearsOnce() async throws {
        let transport = ViewerTeamsTransport { _, _ in
            Self.viewerPage(organizations: [
                Self.organization("acme", teams: [
                    Self.team("T_plm", "plm-team", parent: "T_dev", ancestors: [("T_dev", "developers", nil)]),
                    Self.team("T_dev", "developers")
                ])
            ])
        }

        let teams = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")

        XCTAssertEqual(teams, [
            ViewerTeam(team: TeamReference(id: "T_dev", organization: "acme", slug: "developers")),
            ViewerTeam(team: TeamReference(id: "T_plm", organization: "acme", slug: "plm-team"), parentTeamID: "T_dev")
        ])
    }

    func testOrganizationAndPerOrganizationTeamPaginationAreBothFollowed() async throws {
        let transport = ViewerTeamsTransport { query, variables in
            if query.contains("OrganizationViewerTeams") {
                XCTAssertEqual(variables["org"], .string("acme"))
                XCTAssertEqual(variables["login"], .string("rw"))
                XCTAssertEqual(variables["cursor"], .string("acme-teams-1"))
                return Self.json(["data": ["organization": ["teams": Self.teamConnection(
                    [Self.team("T_web", "web", parent: "T_eng", ancestors: [("T_eng", "engineering", nil)])]
                )]]])
            }
            if variables["orgCursor"] == .string("orgs-1") {
                return Self.viewerPage(organizations: [
                    Self.organization("zeta", teams: [Self.team("T_ops", "ops")])
                ])
            }
            return Self.viewerPage(
                organizations: [
                    Self.organization(
                        "acme",
                        teams: [Self.team("T_api", "api")],
                        nextTeamCursor: "acme-teams-1"
                    )
                ],
                nextOrganizationCursor: "orgs-1"
            )
        }

        let teams = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")

        XCTAssertEqual(teams.map(\.team.displayName), ["@acme/api", "@acme/engineering", "@acme/web", "@zeta/ops"])
        XCTAssertEqual(teams.first { $0.team.id == "T_web" }?.parentTeamID, "T_eng")
        XCTAssertEqual(transport.queries.filter { $0.query.contains("OrganizationViewerTeams") }.count, 1)
        XCTAssertEqual(transport.queries.filter { $0.query.contains("query ViewerTeams") }.count, 2)
    }

    func testAncestorsWithMorePagesFailWithIncompleteCoverage() async throws {
        let transport = ViewerTeamsTransport { _, _ in
            Self.viewerPage(organizations: [
                Self.organization("acme", teams: [
                    Self.team(
                        "T_plm", "plm-team", parent: "T_dev",
                        ancestors: [("T_dev", "developers", nil)], ancestorsHaveNextPage: true
                    )
                ])
            ])
        }

        do {
            _ = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")
            XCTFail("Expected truncated ancestors to fail")
        } catch GitHubReadError.incompleteCoverage {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testForbiddenGraphQLErrorFailsWithAccessDenied() async throws {
        let transport = ViewerTeamsTransport { _, _ in
            Self.json([
                "data": ["viewer": ["organizations": [
                    "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
                    "nodes": [["login": "acme", "teams": NSNull()]]
                ]]],
                "errors": [[
                    "message": "Resource not accessible by integration",
                    "type": "FORBIDDEN",
                    "path": ["viewer", "organizations", "nodes", 0, "teams"]
                ]]
            ])
        }

        do {
            _ = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")
            XCTFail("Expected FORBIDDEN to fail")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .accessDenied)
        }
    }

    func testViewerTeamsQueriesStayUnderGitHubsNodeLimit() {
        typealias Queries = GitHubPullRequestQueries
        /// GitHub's documented node cost: the sum over nesting levels of the product of `first` values.
        func nodeCost(_ pageSizes: [Int]) -> Int {
            pageSizes.indices.reduce(0) { total, level in total + pageSizes[...level].reduce(1, *) }
        }
        let viewerTeamsCost = nodeCost([
            Queries.viewerOrganizationPageSize, Queries.viewerTeamsPerOrganizationPageSize, Queries.teamAncestorsPageSize
        ])
        let organizationViewerTeamsCost = nodeCost([
            Queries.organizationViewerTeamsPageSize, Queries.teamAncestorsPageSize
        ])

        XCTAssertLessThan(viewerTeamsCost, 500_000)
        XCTAssertLessThan(organizationViewerTeamsCost, 500_000)
        XCTAssertTrue(Queries.viewerTeams.contains("organizations(first: \(Queries.viewerOrganizationPageSize),"))
        XCTAssertTrue(Queries.viewerTeams.contains("teams(first: \(Queries.viewerTeamsPerOrganizationPageSize),"))
        XCTAssertTrue(Queries.viewerTeams.contains("ancestors(first: \(Queries.teamAncestorsPageSize))"))
        XCTAssertTrue(Queries.organizationViewerTeams.contains("teams(first: \(Queries.organizationViewerTeamsPageSize),"))
        XCTAssertTrue(Queries.organizationViewerTeams.contains("ancestors(first: \(Queries.teamAncestorsPageSize))"))
    }

    private static func fetcher(_ transport: ViewerTeamsTransport) -> GitHubPullRequestFetcher {
        GitHubPullRequestFetcher { query, variables in
            try await transport.read(query: query, variables: variables)
        }
    }

    private static func viewerPage(
        organizations: [[String: Any]],
        nextOrganizationCursor: String? = nil
    ) -> Data {
        json(["data": ["viewer": ["organizations": [
            "pageInfo": [
                "hasNextPage": nextOrganizationCursor != nil,
                "endCursor": nextOrganizationCursor.map { $0 as Any } ?? NSNull()
            ],
            "nodes": organizations
        ]]]])
    }

    private static func organization(
        _ login: String,
        teams: [[String: Any]],
        nextTeamCursor: String? = nil,
        avatarURL: String? = nil
    ) -> [String: Any] {
        [
            "login": login,
            "avatarUrl": avatarURL.map { $0 as Any } ?? NSNull(),
            "teams": teamConnection(teams, nextCursor: nextTeamCursor)
        ]
    }

    private static func teamConnection(_ teams: [[String: Any]], nextCursor: String? = nil) -> [String: Any] {
        [
            "pageInfo": ["hasNextPage": nextCursor != nil, "endCursor": nextCursor.map { $0 as Any } ?? NSNull()],
            "nodes": teams
        ]
    }

    private static func team(
        _ id: String,
        _ slug: String,
        parent: String? = nil,
        ancestors: [(id: String, slug: String, parent: String?)] = [],
        ancestorsHaveNextPage: Bool = false
    ) -> [String: Any] {
        [
            "id": id,
            "slug": slug,
            "parentTeam": parentTeam(parent),
            "ancestors": [
                "pageInfo": ["hasNextPage": ancestorsHaveNextPage],
                "nodes": ancestors.map { ["id": $0.id, "slug": $0.slug, "parentTeam": parentTeam($0.parent)] }
            ]
        ]
    }

    private static func parentTeam(_ id: String?) -> Any {
        id.map { ["id": $0] as Any } ?? NSNull()
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private final class ViewerTeamsTransport: @unchecked Sendable {
    typealias Handler = (String, [String: GitHubQueryValue]) throws -> Data
    private let handler: Handler
    private let lock = NSLock()
    private var storedQueries: [(query: String, variables: [String: GitHubQueryValue])] = []
    var queries: [(query: String, variables: [String: GitHubQueryValue])] { lock.withLock { storedQueries } }

    init(_ handler: @escaping Handler) { self.handler = handler }

    func read(query: String, variables: [String: GitHubQueryValue]) async throws -> Data {
        lock.withLock { storedQueries.append((query, variables)) }
        return try handler(query, variables)
    }
}
