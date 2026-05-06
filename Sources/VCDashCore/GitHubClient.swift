import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GitHubPullRequestNode: Decodable, Equatable, Sendable {
    public struct Count: Decodable, Equatable, Sendable {
        public let totalCount: Int
        public init(totalCount: Int) {
            self.totalCount = totalCount
        }
    }

    public struct Repository: Decodable, Equatable, Sendable {
        public let nameWithOwner: String
        public init(nameWithOwner: String) {
            self.nameWithOwner = nameWithOwner
        }
    }

    public struct CommitConnection: Decodable, Equatable, Sendable {
        public struct Node: Decodable, Equatable, Sendable {
            public struct Commit: Decodable, Equatable, Sendable {
                public struct StatusCheckRollup: Decodable, Equatable, Sendable {
                    public let state: String?
                    public init(state: String?) {
                        self.state = state
                    }
                }

                public let statusCheckRollup: StatusCheckRollup?
                public init(statusCheckRollup: StatusCheckRollup?) {
                    self.statusCheckRollup = statusCheckRollup
                }
            }

            public let commit: Commit
            public init(commit: Commit) {
                self.commit = commit
            }
        }

        public let nodes: [Node]
        public init(nodes: [Node]) {
            self.nodes = nodes
        }
    }

    public struct User: Decodable, Equatable, Sendable {
        public let login: String
        public init(login: String) {
            self.login = login
        }
    }

    public struct ReviewThreadConnection: Decodable, Equatable, Sendable {
        public struct Node: Decodable, Equatable, Sendable {
            public let isResolved: Bool
            public init(isResolved: Bool) {
                self.isResolved = isResolved
            }
        }

        public let nodes: [Node]
        public init(nodes: [Node]) {
            self.nodes = nodes
        }
    }

    public let id: String
    public let title: String
    public let number: Int
    public let url: String
    public let createdAt: String
    public let updatedAt: String
    public let isDraft: Bool
    public let mergeable: String?
    public let reviewDecision: String?
    public let comments: Count
    public let reviews: Count
    public let reviewThreads: ReviewThreadConnection
    public let repository: Repository
    public let commits: CommitConnection?
    public let author: User?

    public init(
        id: String,
        title: String,
        number: Int,
        url: String,
        createdAt: String,
        updatedAt: String,
        isDraft: Bool,
        mergeable: String?,
        reviewDecision: String?,
        comments: Count,
        reviews: Count,
        reviewThreads: ReviewThreadConnection,
        repository: Repository,
        commits: CommitConnection?,
        author: User?
    ) {
        self.id = id
        self.title = title
        self.number = number
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.mergeable = mergeable
        self.reviewDecision = reviewDecision
        self.comments = comments
        self.reviews = reviews
        self.reviewThreads = reviewThreads
        self.repository = repository
        self.commits = commits
        self.author = author
    }
}

public enum GitHubPullRequestNormalizer {
    private static let dateFormatter = ISO8601DateFormatter()

    public static func normalize(_ node: GitHubPullRequestNode, login: String) -> PullRequest {
        let rollupState = node.commits?.nodes.last?.commit.statusCheckRollup?.state ?? "UNKNOWN"
        let unresolvedReviewThreadCount = node.reviewThreads.nodes.filter { !$0.isResolved }.count
        return PullRequest(
            id: node.id,
            title: node.title,
            number: node.number,
            url: URL(string: node.url)!,
            repo: node.repository.nameWithOwner,
            ciState: normalizeCIState(rollupState),
            reviewDecision: normalizeReviewDecision(node.reviewDecision),
            commentCount: node.comments.totalCount + unresolvedReviewThreadCount,
            reviewCount: node.reviews.totalCount,
            isMine: node.author?.login == login,
            author: node.author?.login ?? "unknown",
            mergeable: normalizeMergeableState(node.mergeable),
            draft: node.isDraft,
            createdAt: normalizeDate(node.createdAt),
            updatedAt: normalizeDate(node.updatedAt)
        )
    }

    public static func normalizeCIState(_ state: String?) -> CIState {
        switch state {
        case "SUCCESS":
            .passing
        case "FAILURE", "ERROR":
            .failing
        case "PENDING", "EXPECTED":
            .pending
        default:
            .unknown
        }
    }

    public static func normalizeReviewDecision(_ decision: String?) -> ReviewDecision {
        switch decision {
        case "APPROVED":
            .approved
        case "CHANGES_REQUESTED":
            .changesRequested
        case "REVIEW_REQUIRED", nil:
            .reviewRequired
        default:
            .unknown
        }
    }

    public static func normalizeMergeableState(_ mergeable: String?) -> MergeableState {
        switch mergeable {
        case "MERGEABLE":
            .mergeable
        case "CONFLICTING":
            .conflicting
        default:
            .unknown
        }
    }

    public static func normalizeDate(_ date: String) -> Date {
        dateFormatter.date(from: date) ?? Date(timeIntervalSince1970: 0)
    }
}

public final class GitHubClient: PullRequestSource {
    public let sourceKind: DashboardSource = .github

    private let token: String
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    public static func pullRequestSearchQueries(login: String) -> [String] {
        [
            "is:open is:pr author:\(login)",
            "is:open is:pr assignee:\(login)",
            "is:open is:pr user-review-requested:\(login)"
        ]
    }

    public func fetchViewer() async throws -> GitHubAccount {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.httpMethod = "GET"
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("Bearer \(token)", forHTTPHeaderField: "authorization")
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

    public func fetchPullRequests(login: String) async throws -> [PullRequest] {
        var pullRequests: [String: PullRequest] = [:]
        for query in Self.pullRequestSearchQueries(login: login) {
            let data = try await graphql(query: Self.pullRequestSearchQuery, variables: ["query": query])
            let payload = try decoder.decode(GraphQLResponse<PullRequestSearchData>.self, from: data)
            if let errors = payload.errors, !errors.isEmpty {
                throw GitHubClientError.graphQLErrors(errors.map(\.message).joined(separator: "; "))
            }
            for node in payload.data?.search.nodes ?? [] {
                pullRequests[node.id] = GitHubPullRequestNormalizer.normalize(node, login: login)
            }
        }
        return Array(pullRequests.values)
    }

    private func graphql(query: String, variables: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))

        let (data, response) = try await session.data(for: request)
        try validate(response, endpoint: "GitHub GraphQL")
        return data
    }

    private func validate(_ response: URLResponse, endpoint: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GitHubClientError.httpFailure(endpoint: endpoint, status: status)
        }
    }

    private static let pullRequestSearchQuery = """
      query PullRequestDashboard($query: String!) {
        search(query: $query, type: ISSUE, first: 50) {
          nodes {
            ... on PullRequest {
              id
              title
              number
              url
              createdAt
              updatedAt
              isDraft
              mergeable
              reviewDecision
              comments {
                totalCount
              }
              reviews {
                totalCount
              }
              reviewThreads(first: 100) {
                nodes {
                  isResolved
                }
              }
              repository {
                nameWithOwner
              }
              commits(last: 1) {
                nodes {
                  commit {
                    statusCheckRollup {
                      state
                    }
                  }
                }
              }
              author {
                login
              }
            }
          }
        }
      }
    """
}

public enum GitHubClientError: Error, LocalizedError {
    case httpFailure(endpoint: String, status: Int)
    case graphQLErrors(String)

    public var errorDescription: String? {
        switch self {
        case .httpFailure(let endpoint, let status):
            "\(endpoint) request failed with status \(status)."
        case .graphQLErrors(let message):
            message
        }
    }
}

private struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: String]
}

private struct GraphQLResponse<DataPayload: Decodable>: Decodable {
    struct GraphQLError: Decodable {
        let message: String
    }

    let data: DataPayload?
    let errors: [GraphQLError]?
}

private struct PullRequestSearchData: Decodable {
    struct Search: Decodable {
        let nodes: [GitHubPullRequestNode]
    }

    let search: Search
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
