@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubViewerTeamsTests: XCTestCase {
    func testNestedTeamsListTheDirectTeamAndItsAncestorsInheritedViaIt() async throws {
        let transport = ViewerTeamsTransport { _, _ in
            Self.viewerPage(organizations: [
                Self.organization("acme", teams: [
                    Self.team("T_plm", "plm-team", ancestors: [("T_dev", "developers"), ("T_eng", "engineering")])
                ])
            ])
        }

        let teams = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")

        let plm = TeamReference(id: "T_plm", organization: "acme", slug: "plm-team")
        XCTAssertEqual(teams, [
            ViewerTeam(team: TeamReference(id: "T_dev", organization: "acme", slug: "developers"), inheritedVia: plm),
            ViewerTeam(team: TeamReference(id: "T_eng", organization: "acme", slug: "engineering"), inheritedVia: plm),
            ViewerTeam(team: plm)
        ])
        XCTAssertEqual(transport.queries.count, 1)
        XCTAssertTrue(transport.queries[0].query.contains("userLogins: [$login]"))
        XCTAssertEqual(transport.queries[0].variables["login"], .string("rw"))
        XCTAssertEqual(transport.queries[0].variables["orgCursor"], .null)
    }

    func testSecretTeamWithoutParentIsOneDirectEntry() async throws {
        let transport = ViewerTeamsTransport { _, _ in
            Self.viewerPage(organizations: [Self.organization("acme", teams: [Self.team("T_secret", "secret-squad")])])
        }

        let teams = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")

        XCTAssertEqual(teams, [ViewerTeam(team: TeamReference(id: "T_secret", organization: "acme", slug: "secret-squad"))])
    }

    func testAncestorSharedByTwoDirectTeamsAppearsOnceViaTheFirstDirectTeamBySlug() async throws {
        let transport = ViewerTeamsTransport { _, _ in
            Self.viewerPage(organizations: [
                Self.organization("acme", teams: [
                    Self.team("T_web", "web", ancestors: [("T_eng", "engineering")]),
                    Self.team("T_api", "api", ancestors: [("T_eng", "engineering")])
                ])
            ])
        }

        let teams = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")

        XCTAssertEqual(teams.map(\.team.slug), ["api", "engineering", "web"])
        XCTAssertEqual(teams.first { $0.team.id == "T_eng" }?.inheritedVia?.slug, "api")
    }

    func testTeamThatIsDirectAndAnAncestorAppearsOnceAsDirect() async throws {
        let transport = ViewerTeamsTransport { _, _ in
            Self.viewerPage(organizations: [
                Self.organization("acme", teams: [
                    Self.team("T_plm", "plm-team", ancestors: [("T_dev", "developers")]),
                    Self.team("T_dev", "developers")
                ])
            ])
        }

        let teams = try await Self.fetcher(transport).fetchViewerTeams(login: "rw")

        XCTAssertEqual(teams.count, 2)
        XCTAssertEqual(teams.first { $0.team.id == "T_dev" }, ViewerTeam(
            team: TeamReference(id: "T_dev", organization: "acme", slug: "developers")
        ))
    }

    func testOrganizationAndPerOrganizationTeamPaginationAreBothFollowed() async throws {
        let transport = ViewerTeamsTransport { query, variables in
            if query.contains("OrganizationViewerTeams") {
                XCTAssertEqual(variables["org"], .string("acme"))
                XCTAssertEqual(variables["login"], .string("rw"))
                XCTAssertEqual(variables["cursor"], .string("acme-teams-1"))
                return Self.json(["data": ["organization": ["teams": Self.teamConnection(
                    [Self.team("T_web", "web", ancestors: [("T_eng", "engineering")])]
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
        XCTAssertEqual(teams.first { $0.team.id == "T_eng" }?.inheritedVia?.slug, "web")
        XCTAssertEqual(transport.queries.filter { $0.query.contains("OrganizationViewerTeams") }.count, 1)
        XCTAssertEqual(transport.queries.filter { $0.query.contains("query ViewerTeams") }.count, 2)
    }

    func testAncestorsWithMorePagesFailWithIncompleteCoverage() async throws {
        let transport = ViewerTeamsTransport { _, _ in
            Self.viewerPage(organizations: [
                Self.organization("acme", teams: [
                    Self.team("T_plm", "plm-team", ancestors: [("T_dev", "developers")], ancestorsHaveNextPage: true)
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
        nextTeamCursor: String? = nil
    ) -> [String: Any] {
        ["login": login, "teams": teamConnection(teams, nextCursor: nextTeamCursor)]
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
        ancestors: [(String, String)] = [],
        ancestorsHaveNextPage: Bool = false
    ) -> [String: Any] {
        [
            "id": id,
            "slug": slug,
            "ancestors": [
                "pageInfo": ["hasNextPage": ancestorsHaveNextPage],
                "nodes": ancestors.map { ["id": $0.0, "slug": $0.1] }
            ]
        ]
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
