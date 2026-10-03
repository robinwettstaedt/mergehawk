import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class GitHubClient: CompletePullRequestFetching, SourceCatalogProviding, GitHubAppInstallationProviding, GitHubViewerProviding, @unchecked Sendable {
    public let sourceKind: DashboardSource = .github

    private let tokenProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let readRetryPolicy = GitHubReadRetryPolicy()

    public init(token: String, session: URLSession = .shared) {
        self.tokenProvider = { token }
        self.session = session
    }

    public init(
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    public func fetchViewer() async throws -> GitHubAccount {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.httpMethod = "GET"
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("Bearer \(try await accessToken())", forHTTPHeaderField: "authorization")
        request.addValue("2022-11-28", forHTTPHeaderField: "x-github-api-version")

        let (data, response) = try await session.data(for: request)
        try validate(response, endpoint: "GitHub user")
        let user = try decoder.decode(ViewerResponse.self, from: data)
        return GitHubAccount(
            login: user.login,
            avatarUrl: user.avatarUrl,
            profileUrl: user.profileUrl
        )
    }

    public func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        let fetcher = GitHubPullRequestFetcher { [weak self] query, variables in
            guard let self else { throw CancellationError() }
            return try await self.completeGraphQL(query: query, variables: variables)
        }
        let viewerTeams = try await fetcher.fetchViewerTeams(login: login)
        let discovery = try await fetcher.discover(login: login)
        let discoveredIDs = Set(discovery.pullRequests.map(\.id))
        let previousPullRequests = previousState?.trusted(for: login)?.dashboard.pullRequests ?? []
        let previousByID = Dictionary(uniqueKeysWithValues: previousPullRequests.map { ($0.id, $0) })

        let discoveredHydration = try await fetcher.hydrateForReconciliation(
            discovery.pullRequests,
            login: login
        )
        let absentIdentities = previousPullRequests
            .filter { !discoveredIDs.contains($0.id) }
            .map(Self.discoveryIdentity(from:))
        let absentHydration = try await fetcher.hydrateForReconciliation(
            absentIdentities,
            login: login,
            includesForbiddenNodes: true
        )

        var missingIDs = discoveredHydration.missingPullRequestIDs
            .union(absentHydration.missingPullRequestIDs)
        var quietlyRetiredIDs = Set<String>()
        var verifiedViewer = false
        let allIdentities = Dictionary(
            uniqueKeysWithValues: (discovery.pullRequests + absentIdentities).map { ($0.id, $0) }
        )
        for id in missingIDs.sorted() {
            guard let identity = allIdentities[id] else { throw GitHubReadError.invalidPayload }
            if try await missingResourceIsTerminal(
                repository: identity.repository,
                number: identity.number,
                expectedLogin: login,
                verifiedViewer: &verifiedViewer
            ) {
                quietlyRetiredIDs.insert(id)
                missingIDs.remove(id)
            }
        }
        guard missingIDs.isEmpty else { throw GitHubReadError.invalidPayload }

        let hydrated = discoveredHydration.pullRequests + absentHydration.pullRequests
        var teamMembershipByRepository: [String: Set<String>] = [:]
        var active: [PullRequest] = []
        var retiring: [PullRequest] = []
        for value in hydrated {
            var pr = value.pullRequest
            // Discovered PRs already carry the team lane's answer; only rechecked PRs need repository confirmation.
            let teamRelevant: Bool
            if value.hasTeamReviewRequest, !discoveredIDs.contains(pr.id) {
                let ids: Set<String>
                if let cached = teamMembershipByRepository[pr.repo] {
                    ids = cached
                } else {
                    ids = try await fetcher.repositoryTeamRequestedPullRequestIDs(
                        repository: pr.repo,
                        login: login
                    )
                    teamMembershipByRepository[pr.repo] = ids
                }
                teamRelevant = ids.contains(pr.id)
                pr.reviewRequestKind = ReviewRequestKind(direct: pr.reviewRequestKind.includesDirect, team: teamRelevant)
            } else {
                teamRelevant = pr.reviewRequestKind.includesTeam
            }
            let baseRelevant = pr.isMine || pr.isAssignedToViewer || pr.reviewRequestKind.includesDirect
            if value.providerState == "OPEN", baseRelevant || teamRelevant {
                active.append(pr)
            } else if previousByID[pr.id] != nil {
                retiring.append(pr)
            }
        }

        return CompletePullRequestFetchResult(
            activePullRequests: active.sorted { $0.id < $1.id },
            retiringPullRequests: retiring.sorted { $0.id < $1.id },
            quietlyRetiredPullRequestIDs: quietlyRetiredIDs,
            viewerTeams: viewerTeams
        )
    }

    private func completeGraphQL(
        query: String,
        variables: [String: GitHubQueryValue]
    ) async throws -> Data {
        try await readRetryPolicy.run { [self] in
            var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
            request.httpMethod = "POST"
            request.addValue("Bearer \(try await accessToken())", forHTTPHeaderField: "authorization")
            request.addValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONEncoder().encode(
                CompleteGraphQLRequest(query: query, variables: variables)
            )
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitHubReadError.http(status: -1)
            }
            try classifyReadResponse(http, data: data)
            if let envelope = try? decoder.decode(CompleteGraphQLErrorEnvelope.self, from: data),
               envelope.errors?.contains(where: { $0.type?.uppercased() == "RATE_LIMITED" }) == true {
                throw GitHubReadError.rateLimited(retryAt: rateLimitRetryDate(from: http))
            }
            return data
        }
    }

    private static func discoveryIdentity(from pullRequest: PullRequest) -> DiscoveredPullRequest {
        DiscoveredPullRequest(
            id: pullRequest.id,
            repository: pullRequest.repo,
            number: pullRequest.number,
            createdAt: pullRequest.createdAt,
            isAuthored: pullRequest.isMine,
            isAssigned: pullRequest.isAssignedToViewer,
            isDirectlyRequested: pullRequest.reviewRequestKind.includesDirect,
            isTeamRequested: pullRequest.reviewRequestKind.includesTeam
        )
    }

    private func missingResourceIsTerminal(
        repository: String,
        number: Int,
        expectedLogin: String,
        verifiedViewer: inout Bool
    ) async throws -> Bool {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repository)/pulls/\(number)")!
        )
        request.httpMethod = "GET"
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("Bearer \(try await accessToken())", forHTTPHeaderField: "authorization")
        request.addValue("2022-11-28", forHTTPHeaderField: "x-github-api-version")
        let (data, http) = try await completeREST(request, allowedStatuses: [403, 404, 410])
        switch http.statusCode {
        case 404, 410:
            if !verifiedViewer {
                try await verifyViewerIdentity(expectedLogin)
                verifiedViewer = true
            }
            return true
        case 403:
            let message = (try? JSONDecoder().decode(RESTMessage.self, from: data).message) ?? ""
            guard Self.accessLossMessageFragments.contains(where: message.localizedCaseInsensitiveContains) else {
                throw GitHubReadError.http(status: 403)
            }
            if !verifiedViewer {
                try await verifyViewerIdentity(expectedLogin)
                verifiedViewer = true
            }
            return true
        default:
            return false
        }
    }

    /// 403 messages meaning the viewer lost access to the repository, as opposed to a temporary refusal.
    private static let accessLossMessageFragments = [
        "resource not accessible",
        "access denied",
        "saml enforcement",
        "oauth app access restrictions"
    ]

    private func verifyViewerIdentity(_ expectedLogin: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.httpMethod = "GET"
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("Bearer \(try await accessToken())", forHTTPHeaderField: "authorization")
        request.addValue("2022-11-28", forHTTPHeaderField: "x-github-api-version")
        let (data, _) = try await completeREST(request)
        let viewer = try decoder.decode(ViewerResponse.self, from: data)
        guard viewer.login.caseInsensitiveCompare(expectedLogin) == .orderedSame else {
            throw GitHubReadError.authentication
        }
    }

    private func completeREST(
        _ request: URLRequest,
        allowedStatuses: Set<Int> = []
    ) async throws -> (Data, HTTPURLResponse) {
        try await readRetryPolicy.run { [self] in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitHubReadError.http(status: -1)
            }
            if isRateLimitResponse(http) {
                try classifyReadResponse(http, data: data)
            } else if !allowedStatuses.contains(http.statusCode) {
                try classifyReadResponse(http, data: data)
            }
            return (data, http)
        }
    }

    private func classifyReadResponse(_ response: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        if response.statusCode == 401 { throw GitHubReadError.authentication }
        if isRateLimitResponse(response) {
            throw GitHubReadError.rateLimited(retryAt: rateLimitRetryDate(from: response))
        }
        if response.statusCode == 403 {
            let message = (try? JSONDecoder().decode(RESTMessage.self, from: data).message) ?? ""
            if message.localizedCaseInsensitiveContains("resource not accessible") {
                throw GitHubReadError.accessDenied
            }
        }
        throw GitHubReadError.http(status: response.statusCode)
    }

    private func isRateLimitResponse(_ response: HTTPURLResponse) -> Bool {
        response.statusCode == 429
            || (response.statusCode == 403
                && (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                    || response.value(forHTTPHeaderField: "Retry-After") != nil))
    }

    private func rateLimitRetryDate(from response: HTTPURLResponse) -> Date? {
        if let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
            return Date().addingTimeInterval(retry)
        }
        if let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
            return Date(timeIntervalSince1970: reset)
        }
        return nil
    }

    public func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        var page = 1
        var repositories: [RepositorySource] = []

        while true {
            let pageRepositories = try await fetchRepositoriesPage(page: page)
            repositories.append(contentsOf: pageRepositories)
            guard pageRepositories.count == 100 else {
                break
            }
            page += 1
        }

        return SourceCatalog(repositories: repositories, accountLogin: accountLogin)
    }

    public func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        var page = 1
        var responses: [GitHubAppInstallationResponse] = []
        while true {
            var components = URLComponents(string: "https://api.github.com/user/installations")!
            components.queryItems = [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
            request.addValue("Bearer \(try await accessToken())", forHTTPHeaderField: "authorization")
            request.addValue("2022-11-28", forHTTPHeaderField: "x-github-api-version")

            let (data, response) = try await session.data(for: request)
            try validate(response, endpoint: "GitHub App installations")
            let payload = try decoder.decode(GitHubAppInstallationsResponse.self, from: data)
            responses.append(contentsOf: payload.installations)
            guard !payload.installations.isEmpty, responses.count < payload.totalCount else {
                break
            }
            page += 1
        }
        return GitHubAppInstallations(installations: responses.map { installation in
            GitHubAppInstallation(
                id: installation.id,
                accountLogin: installation.account.login,
                accountType: installation.account.type,
                repositorySelection: installation.repositorySelection,
                htmlURL: installation.htmlURL
            )
        })
    }

    private func fetchRepositoriesPage(page: Int) async throws -> [RepositorySource] {
        var components = URLComponents(string: "https://api.github.com/user/repos")!
        components.queryItems = [
            URLQueryItem(name: "visibility", value: "all"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
            URLQueryItem(name: "sort", value: "full_name"),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: "\(page)")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("Bearer \(try await accessToken())", forHTTPHeaderField: "authorization")
        request.addValue("2022-11-28", forHTTPHeaderField: "x-github-api-version")

        let (data, response) = try await session.data(for: request)
        try validate(response, endpoint: "GitHub repositories")
        return try decoder.decode([GitHubRepositoryResponse].self, from: data).map { repository in
            RepositorySource(owner: repository.owner.login, name: repository.name)
        }
    }

    private func validate(_ response: URLResponse, endpoint: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GitHubClientError.httpFailure(endpoint: endpoint, status: status)
        }
    }

    private func accessToken() async throws -> String {
        try await tokenProvider()
    }

}

public enum GitHubClientError: Error, LocalizedError {
    case httpFailure(endpoint: String, status: Int)
    case authRefreshFailed(status: Int, detail: String?)
    case graphQLErrors(String)

    /// GitHub rejects refresh credentials with 200 plus an OAuth error body, 400 or 401;
    /// other refresh statuses (rate limits, server errors) are transient.
    public var rejectsCredentials: Bool {
        switch self {
        case .httpFailure(_, let status): status == 401
        case .authRefreshFailed(let status, _): [200, 400, 401].contains(status)
        case .graphQLErrors: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .httpFailure(let endpoint, let status):
            "\(endpoint) request failed with status \(status)."
        case .authRefreshFailed(let status, let detail):
            [
                "Authentication refresh failed (HTTP \(status)).",
                detail.flatMap { $0.isEmpty ? nil : $0 },
                rejectsCredentials ? "Please sign in again." : "MergeHawk will retry."
            ].compactMap { $0 }.joined(separator: " ")
        case .graphQLErrors(let message):
            message
        }
    }
}

private struct CompleteGraphQLRequest: Encodable {
    let query: String
    let variables: [String: GitHubQueryValue]
}

private struct CompleteGraphQLErrorEnvelope: Decodable {
    let errors: [GitHubGraphQLErrorPayload]?
}

private struct RESTMessage: Decodable {
    let message: String
}

private struct GitHubAppInstallationsResponse: Decodable {
    let totalCount: Int
    let installations: [GitHubAppInstallationResponse]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case installations
    }
}

private struct GitHubAppInstallationResponse: Decodable {
    struct Account: Decodable {
        let login: String
        let type: String
    }

    let id: Int
    let account: Account
    let repositorySelection: GitHubAppInstallation.RepositorySelection
    let htmlURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id
        case account
        case repositorySelection = "repository_selection"
        case htmlURL = "html_url"
    }
}

private struct ViewerResponse: Decodable {
    let login: String
    let avatarUrl: URL?
    let profileUrl: URL?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarUrl = "avatar_url"
        case profileUrl = "html_url"
    }
}

private struct GitHubRepositoryResponse: Decodable {
    struct Owner: Decodable {
        let login: String
    }

    let name: String
    let owner: Owner
}
