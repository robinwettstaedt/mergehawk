import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GitHubPullRequestNode: Decodable, Equatable, Sendable {
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

    public struct AssigneeConnection: Decodable, Equatable, Sendable {
        public let nodes: [User]
        public init(nodes: [User]) {
            self.nodes = nodes
        }
    }

    public struct CommentConnection: Decodable, Equatable, Sendable {
        public struct Node: Decodable, Equatable, Sendable {
            public let id: String
            public let createdAt: String
            public let viewerDidAuthor: Bool
            public let author: User?

            public init(
                id: String,
                createdAt: String,
                viewerDidAuthor: Bool,
                author: User? = nil
            ) {
                self.id = id
                self.createdAt = createdAt
                self.viewerDidAuthor = viewerDidAuthor
                self.author = author
            }
        }

        public let totalCount: Int
        public let nodes: [Node]

        public init(totalCount: Int, nodes: [Node] = []) {
            self.totalCount = totalCount
            self.nodes = nodes
        }
    }

    public struct ReviewThreadConnection: Decodable, Equatable, Sendable {
        public struct Node: Decodable, Equatable, Sendable {
            public struct ReviewCommentConnection: Decodable, Equatable, Sendable {
                public struct ReviewComment: Decodable, Equatable, Sendable {
                    public struct Review: Decodable, Equatable, Sendable {
                        public let id: String
                        public init(id: String) {
                            self.id = id
                        }
                    }

                    public let id: String
                    public let createdAt: String
                    public let viewerDidAuthor: Bool
                    public let author: User?
                    public let pullRequestReview: Review?

                    public init(
                        id: String,
                        createdAt: String,
                        viewerDidAuthor: Bool,
                        author: User? = nil,
                        pullRequestReview: Review? = nil
                    ) {
                        self.id = id
                        self.createdAt = createdAt
                        self.viewerDidAuthor = viewerDidAuthor
                        self.author = author
                        self.pullRequestReview = pullRequestReview
                    }
                }

                public let totalCount: Int
                public let nodes: [ReviewComment]
                public init(totalCount: Int? = nil, nodes: [ReviewComment] = []) {
                    self.totalCount = totalCount ?? nodes.count
                    self.nodes = nodes
                }
            }

            public let isResolved: Bool
            public let viewerCanResolve: Bool
            public let comments: ReviewCommentConnection

            public init(
                isResolved: Bool,
                viewerCanResolve: Bool = false,
                comments: ReviewCommentConnection = .init()
            ) {
                self.isResolved = isResolved
                self.viewerCanResolve = viewerCanResolve
                self.comments = comments
            }
        }

        public let nodes: [Node]
        public init(nodes: [Node]) {
            self.nodes = nodes
        }
    }

    public struct ReviewRequestConnection: Decodable, Equatable, Sendable {
        public struct Node: Decodable, Equatable, Sendable {
            public let requestedReviewer: RequestedReviewer?
            public init(requestedReviewer: RequestedReviewer?) {
                self.requestedReviewer = requestedReviewer
            }
        }

        public let nodes: [Node]
        public init(nodes: [Node]) {
            self.nodes = nodes
        }
    }

    public struct ReviewConnection: Decodable, Equatable, Sendable {
        public struct Node: Decodable, Equatable, Sendable {
            public let id: String
            public let state: String
            public let submittedAt: String?
            public let author: User?

            public init(id: String, state: String, submittedAt: String?, author: User? = nil) {
                self.id = id
                self.state = state
                self.submittedAt = submittedAt
                self.author = author
            }
        }

        public let totalCount: Int
        public let nodes: [Node]

        public init(totalCount: Int, nodes: [Node] = []) {
            self.totalCount = totalCount
            self.nodes = nodes
        }
    }

    public struct RequestedReviewer: Decodable, Equatable, Sendable {
        public struct Organization: Decodable, Equatable, Sendable {
            public let login: String
            public init(login: String) {
                self.login = login
            }
        }

        public let typeName: String
        public let login: String?
        public let slug: String?
        public let organization: Organization?

        public init(typeName: String, login: String? = nil, slug: String? = nil, organization: Organization? = nil) {
            self.typeName = typeName
            self.login = login
            self.slug = slug
            self.organization = organization
        }

        enum CodingKeys: String, CodingKey {
            case typeName = "__typename"
            case login
            case slug
            case organization
        }
    }

    public let id: String
    public let title: String
    public let number: Int
    public let url: String
    public let createdAt: String
    public let updatedAt: String
    public let headRefName: String
    public let isDraft: Bool
    public let mergeable: String?
    public let reviewDecision: String?
    public let comments: CommentConnection
    public let reviews: ReviewConnection
    public let latestOpinionatedReviews: ReviewConnection
    public let reviewThreads: ReviewThreadConnection
    public let reviewRequests: ReviewRequestConnection
    public let assignees: AssigneeConnection
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
        headRefName: String = "",
        isDraft: Bool,
        mergeable: String?,
        reviewDecision: String?,
        comments: CommentConnection,
        reviews: ReviewConnection,
        latestOpinionatedReviews: ReviewConnection = .init(totalCount: 0),
        reviewThreads: ReviewThreadConnection,
        reviewRequests: ReviewRequestConnection = .init(nodes: []),
        assignees: AssigneeConnection = .init(nodes: []),
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
        self.headRefName = headRefName
        self.isDraft = isDraft
        self.mergeable = mergeable
        self.reviewDecision = reviewDecision
        self.comments = comments
        self.reviews = reviews
        self.latestOpinionatedReviews = latestOpinionatedReviews
        self.reviewThreads = reviewThreads
        self.reviewRequests = reviewRequests
        self.assignees = assignees
        self.repository = repository
        self.commits = commits
        self.author = author
    }
}

public enum GitHubPullRequestNormalizer {
    private static let dateFormatter = ISO8601DateFormatter()

    public static func normalize(
        _ node: GitHubPullRequestNode,
        login: String,
        isReviewRequestResult: Bool = false
    ) -> PullRequest {
        let rollupState = node.commits?.nodes.last?.commit.statusCheckRollup?.state ?? "UNKNOWN"
        return PullRequest(
            id: node.id,
            title: node.title,
            number: node.number,
            url: URL(string: node.url)!,
            repo: node.repository.nameWithOwner,
            ciState: normalizeCIState(rollupState),
            reviewDecision: normalizeReviewDecision(
                node.reviewDecision,
                latestOpinionatedReviews: node.latestOpinionatedReviews
            ),
            commentCount: normalizeActionableUnresolvedCommentCount(node.reviewThreads),
            commentActivityCount: normalizeCommentActivityCount(node),
            recentCommentActivities: normalizeCommentActivities(node),
            reviewCount: node.reviews.totalCount,
            recentReviews: normalizeReviews(node.reviews, login: login),
            reviewRequestKind: normalizeReviewRequestKind(
                node.reviewRequests,
                login: login,
                isReviewRequestResult: isReviewRequestResult
            ),
            isAssignedToViewer: node.assignees.nodes.contains { $0.login == login },
            isMine: node.author?.login == login,
            author: node.author?.login ?? "unknown",
            headRefName: node.headRefName,
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

    private static func normalizeReviewDecision(
        _ decision: String?,
        latestOpinionatedReviews: GitHubPullRequestNode.ReviewConnection
    ) -> ReviewDecision {
        let reviewStates = latestOpinionatedReviews.nodes.compactMap { normalizeReviewState($0.state) }
        if reviewStates.contains(.changesRequested) {
            return .changesRequested
        }
        if reviewStates.contains(.approved) {
            return .approved
        }
        return normalizeReviewDecision(decision)
    }

    private static func normalizeActionableUnresolvedCommentCount(
        _ reviewThreads: GitHubPullRequestNode.ReviewThreadConnection
    ) -> Int {
        reviewThreads.nodes.filter { thread in
            !thread.isResolved
                && thread.viewerCanResolve
                && thread.comments.nodes.contains { !$0.viewerDidAuthor }
        }.count
    }

    private static func normalizeCommentActivityCount(_ node: GitHubPullRequestNode) -> Int {
        node.comments.totalCount + node.reviewThreads.nodes.reduce(0) { count, thread in
            count + thread.comments.totalCount
        }
    }

    private static func normalizeCommentActivities(_ node: GitHubPullRequestNode) -> [PullRequestCommentActivity] {
        let pullRequestComments = node.comments.nodes.map { comment in
            PullRequestCommentActivity(
                id: comment.id,
                author: comment.author?.login,
                viewerDidAuthor: comment.viewerDidAuthor,
                createdAt: normalizeDate(comment.createdAt),
                source: .pullRequest
            )
        }
        let reviewThreadComments = node.reviewThreads.nodes.flatMap { thread in
            thread.comments.nodes.map { comment in
                PullRequestCommentActivity(
                    id: comment.id,
                    author: comment.author?.login,
                    viewerDidAuthor: comment.viewerDidAuthor,
                    createdAt: normalizeDate(comment.createdAt),
                    source: .reviewThread,
                    reviewId: comment.pullRequestReview?.id
                )
            }
        }
        return (pullRequestComments + reviewThreadComments).sorted { $0.createdAt < $1.createdAt }
    }

    public static func normalizeReviewState(_ state: String) -> PullRequestReviewState? {
        switch state {
        case "APPROVED":
            .approved
        case "CHANGES_REQUESTED":
            .changesRequested
        case "COMMENTED":
            .commented
        default:
            nil
        }
    }

    private static func normalizeReviews(
        _ reviews: GitHubPullRequestNode.ReviewConnection,
        login: String
    ) -> [PullRequestReview] {
        reviews.nodes.compactMap { review in
            guard
                let state = normalizeReviewState(review.state),
                let submittedAt = review.submittedAt
            else {
                return nil
            }
            return PullRequestReview(
                id: review.id,
                state: state,
                submittedAt: normalizeDate(submittedAt),
                author: review.author?.login,
                viewerDidAuthor: review.author?.login == login
            )
        }
    }

    public static func normalizeReviewRequestKind(
        _ reviewRequests: GitHubPullRequestNode.ReviewRequestConnection,
        login: String,
        isReviewRequestResult: Bool
    ) -> ReviewRequestKind {
        let reviewers = reviewRequests.nodes.compactMap(\.requestedReviewer)
        let hasDirectRequest = reviewers.contains { reviewer in
            reviewer.typeName == "User" && reviewer.login == login
        }
        let hasTeamRequest = reviewers.contains { reviewer in
            reviewer.typeName == "Team"
        } && isReviewRequestResult

        switch (hasDirectRequest, hasTeamRequest) {
        case (true, true):
            return .directAndTeam
        case (true, false):
            return .direct
        case (false, true):
            return .team
        case (false, false):
            return .none
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

public final class GitHubClient: PullRequestSource, SourceCatalogProviding {
    public let sourceKind: DashboardSource = .github

    private struct PullRequestSearch {
        let query: String
        let isReviewRequestResult: Bool
    }

    private let tokenProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let decoder = JSONDecoder()

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

    public static func pullRequestSearchQueries(login: String) -> [String] {
        pullRequestSearches(login: login).map(\.query)
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

    public func fetchPullRequests(login: String) async throws -> [PullRequest] {
        var pullRequests: [String: PullRequest] = [:]
        for search in Self.pullRequestSearches(login: login) {
            let data = try await graphql(query: Self.pullRequestSearchQuery, variables: ["query": search.query])
            let payload = try decoder.decode(GraphQLResponse<PullRequestSearchData>.self, from: data)
            if let errors = payload.errors, !errors.isEmpty {
                throw GitHubClientError.graphQLErrors(errors.map(\.message).joined(separator: "; "))
            }
            for node in payload.data?.search.nodes ?? [] {
                pullRequests[node.id] = GitHubPullRequestNormalizer.normalize(
                    node,
                    login: login,
                    isReviewRequestResult: search.isReviewRequestResult
                )
            }
        }
        return Array(pullRequests.values)
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

    private static func pullRequestSearches(login: String) -> [PullRequestSearch] {
        [
            PullRequestSearch(query: "is:open is:pr author:\(login)", isReviewRequestResult: false),
            PullRequestSearch(query: "is:open is:pr assignee:\(login)", isReviewRequestResult: false),
            PullRequestSearch(query: "is:open is:pr review-requested:\(login)", isReviewRequestResult: true)
        ]
    }

    private func graphql(query: String, variables: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(try await accessToken())", forHTTPHeaderField: "authorization")
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))

        let (data, response) = try await session.data(for: request)
        try validate(response, endpoint: "GitHub GraphQL")
        return data
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
              headRefName
              isDraft
              mergeable
              reviewDecision
              comments(last: 20) {
                totalCount
                nodes {
                  id
                  createdAt
                  viewerDidAuthor
                  author {
                    login
                  }
                }
              }
              reviews(last: 5) {
                totalCount
                nodes {
                  id
                  state
                  submittedAt
                  author {
                    login
                  }
                }
              }
              latestOpinionatedReviews(first: 100) {
                totalCount
                nodes {
                  id
                  state
                  submittedAt
                }
              }
              reviewThreads(first: 100) {
                nodes {
                  isResolved
                  viewerCanResolve
                  comments(last: 100) {
                    totalCount
                    nodes {
                      id
                      createdAt
                      viewerDidAuthor
                      author {
                        login
                      }
                      pullRequestReview {
                        id
                      }
                    }
                  }
                }
              }
              reviewRequests(first: 100) {
                nodes {
                  requestedReviewer {
                    __typename
                    ... on User {
                      login
                    }
                    ... on Team {
                      slug
                      organization {
                        login
                      }
                    }
                  }
                }
              }
              assignees(first: 100) {
                nodes {
                  login
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

extension GitHubClient: GitHubInboxProviding {
    public func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult {
        var components = URLComponents(string: "https://api.github.com/notifications")!
        components.queryItems = [
            URLQueryItem(name: "all", value: "true"),
            URLQueryItem(name: "per_page", value: "50")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("Bearer \(try await accessToken())", forHTTPHeaderField: "authorization")
        request.addValue("2022-11-28", forHTTPHeaderField: "x-github-api-version")
        if let eTag = metadata.eTag {
            request.addValue(eTag, forHTTPHeaderField: "if-none-match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubClientError.httpFailure(endpoint: "GitHub notifications", status: -1)
        }

        let nextMetadata = GitHubInboxSyncMetadata(
            eTag: http.value(forHTTPHeaderField: "ETag") ?? metadata.eTag,
            lastFetchedAt: Date(),
            pollIntervalSeconds: http.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(Int.init)
                ?? metadata.pollIntervalSeconds
        )

        if http.statusCode == 304 {
            return GitHubInboxFetchResult(
                notifications: [],
                metadata: nextMetadata,
                isNotModified: true
            )
        }

        try validate(response, endpoint: "GitHub notifications")
        let notifications = try decoder.decode([GitHubNotificationThreadResponse].self, from: data)
            .filter { $0.subject.type != "PullRequest" }
            .compactMap(Self.normalizeInboxNotification)

        return GitHubInboxFetchResult(
            notifications: notifications,
            metadata: nextMetadata
        )
    }

    public func markInboxThreadRead(threadId: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.github.com/notifications/threads/\(threadId)")!)
        request.httpMethod = "PATCH"
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("Bearer \(try await accessToken())", forHTTPHeaderField: "authorization")
        request.addValue("2022-11-28", forHTTPHeaderField: "x-github-api-version")

        let (_, response) = try await session.data(for: request)
        try validate(response, endpoint: "GitHub notification thread")
    }

    private static func normalizeInboxNotification(
        _ response: GitHubNotificationThreadResponse
    ) -> GitHubInboxNotification? {
        guard
            let threadURL = URL(string: response.url),
            let webURL = webURL(for: response)
        else {
            return nil
        }

        return GitHubInboxNotification(
            threadId: response.id,
            repo: response.repository.fullName,
            subjectTitle: response.subject.title,
            subjectType: response.subject.type,
            reason: response.reason,
            unread: response.unread,
            updatedAt: GitHubPullRequestNormalizer.normalizeDate(response.updatedAt),
            threadURL: threadURL,
            webURL: webURL
        )
    }

    private static func webURL(for response: GitHubNotificationThreadResponse) -> URL? {
        if let subjectURL = response.subject.url, let converted = webURL(fromAPIURL: subjectURL) {
            return converted
        }
        return URL(string: "https://github.com/\(response.repository.fullName)")
    }

    private static func webURL(fromAPIURL apiURL: String) -> URL? {
        guard var components = URLComponents(string: apiURL) else {
            return nil
        }
        guard components.host == "api.github.com" else {
            return URL(string: apiURL)
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 4, parts[0] == "repos" else {
            return nil
        }
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/" + parts.dropFirst().joined(separator: "/")
        components.query = nil
        return components.url
    }
}

public enum GitHubClientError: Error, LocalizedError {
    case httpFailure(endpoint: String, status: Int)
    case authRefreshFailed(status: Int, detail: String?)
    case graphQLErrors(String)

    public var errorDescription: String? {
        switch self {
        case .httpFailure(let endpoint, let status):
            "\(endpoint) request failed with status \(status)."
        case .authRefreshFailed(let status, let detail):
            if let detail, !detail.isEmpty {
                "Authentication refresh failed (HTTP \(status)). \(detail) Please sign in again."
            } else {
                "Authentication refresh failed (HTTP \(status)). Please sign in again."
            }
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

private struct GitHubRepositoryResponse: Decodable {
    struct Owner: Decodable {
        let login: String
    }

    let name: String
    let owner: Owner
}

private struct GitHubNotificationThreadResponse: Decodable, Equatable, Sendable {
    struct Repository: Decodable, Equatable, Sendable {
        let fullName: String

        init(fullName: String) {
            self.fullName = fullName
        }

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }

    struct Subject: Decodable, Equatable, Sendable {
        let title: String
        let url: String?
        let type: String

        init(title: String, url: String?, type: String) {
            self.title = title
            self.url = url
            self.type = type
        }

        enum CodingKeys: String, CodingKey {
            case title
            case url
            case type
        }
    }

    let id: String
    let repository: Repository
    let subject: Subject
    let reason: String
    let unread: Bool
    let updatedAt: String
    let url: String

    init(
        id: String,
        repository: Repository,
        subject: Subject,
        reason: String,
        unread: Bool,
        updatedAt: String,
        url: String
    ) {
        self.id = id
        self.repository = repository
        self.subject = subject
        self.reason = reason
        self.unread = unread
        self.updatedAt = updatedAt
        self.url = url
    }

    enum CodingKeys: String, CodingKey {
        case id
        case repository
        case subject
        case reason
        case unread
        case updatedAt = "updated_at"
        case url
    }
}
