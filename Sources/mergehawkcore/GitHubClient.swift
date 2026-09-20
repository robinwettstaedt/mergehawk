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

    public struct StatusCheckRollup: Decodable, Equatable, Sendable {
        public let state: String?
        public init(state: String?) {
            self.state = state
        }
    }

    public struct User: Decodable, Equatable, Sendable {
        public let login: String
        public let avatarUrl: URL?
        public init(login: String, avatarUrl: URL? = nil) {
            self.login = login
            self.avatarUrl = avatarUrl
        }
    }

    public struct AssigneeConnection: Decodable, Equatable, Sendable {
        public let nodes: [User]
        public init(nodes: [User]) {
            self.nodes = nodes
        }

        private enum CodingKeys: String, CodingKey {
            case nodes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.nodes = try container.decodeIfPresent([User].self, forKey: .nodes) ?? []
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

        private enum CodingKeys: String, CodingKey {
            case totalCount
            case nodes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.totalCount = try container.decode(Int.self, forKey: .totalCount)
            self.nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
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

                private enum CodingKeys: String, CodingKey {
                    case totalCount
                    case nodes
                }

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    let nodes = try container.decodeIfPresent([ReviewComment].self, forKey: .nodes) ?? []
                    self.nodes = nodes
                    self.totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? nodes.count
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

        private enum CodingKeys: String, CodingKey {
            case nodes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
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

        private enum CodingKeys: String, CodingKey {
            case nodes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
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

        private enum CodingKeys: String, CodingKey {
            case totalCount
            case nodes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.totalCount = try container.decode(Int.self, forKey: .totalCount)
            self.nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        }
    }

    public struct OpinionatedReviewConnection: Decodable, Equatable, Sendable {
        public struct Node: Decodable, Equatable, Sendable {
            public let id: String?
            public let state: String?
            public let submittedAt: String?
            public let author: User?

            public init(id: String? = nil, state: String? = nil, submittedAt: String? = nil, author: User? = nil) {
                self.id = id
                self.state = state
                self.submittedAt = submittedAt
                self.author = author
            }
        }

        public let totalCount: Int?
        public let nodes: [Node]?
        public let hasMissingNodes: Bool

        public init(totalCount: Int, nodes: [Node]? = nil) {
            self.totalCount = totalCount
            self.nodes = nodes
            self.hasMissingNodes = false
        }

        private enum CodingKeys: String, CodingKey {
            case totalCount
            case nodes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount)
            let decodedNodes = try container.decodeIfPresent([Node?].self, forKey: .nodes)
            self.nodes = decodedNodes?.compactMap { $0 }
            self.hasMissingNodes = decodedNodes?.contains { $0 == nil } ?? false
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
    public let headRefOid: String
    public let statusCheckRollup: StatusCheckRollup?
    public let isDraft: Bool
    public let mergeable: String?
    public let additions: Int?
    public let deletions: Int?
    public let comments: CommentConnection
    public let reviews: ReviewConnection
    public let latestOpinionatedReviews: OpinionatedReviewConnection?
    public let reviewThreads: ReviewThreadConnection
    public let reviewRequests: ReviewRequestConnection
    public let assignees: AssigneeConnection
    public let repository: Repository
    public let author: User?

    public init(
        id: String,
        title: String,
        number: Int,
        url: String,
        createdAt: String,
        updatedAt: String,
        headRefName: String = "",
        headRefOid: String = "",
        statusCheckRollup: StatusCheckRollup? = nil,
        isDraft: Bool,
        mergeable: String?,
        additions: Int? = nil,
        deletions: Int? = nil,
        comments: CommentConnection,
        reviews: ReviewConnection,
        latestOpinionatedReviews: OpinionatedReviewConnection? = nil,
        reviewThreads: ReviewThreadConnection,
        reviewRequests: ReviewRequestConnection = .init(nodes: []),
        assignees: AssigneeConnection = .init(nodes: []),
        repository: Repository,
        author: User?
    ) {
        self.id = id
        self.title = title
        self.number = number
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.statusCheckRollup = statusCheckRollup
        self.isDraft = isDraft
        self.mergeable = mergeable
        self.additions = additions
        self.deletions = deletions
        self.comments = comments
        self.reviews = reviews
        self.latestOpinionatedReviews = latestOpinionatedReviews
        self.reviewThreads = reviewThreads
        self.reviewRequests = reviewRequests
        self.assignees = assignees
        self.repository = repository
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
        let rollupState = node.statusCheckRollup?.state ?? "UNKNOWN"
        return PullRequest(
            id: node.id,
            title: node.title,
            number: node.number,
            url: URL(string: node.url)!,
            repo: node.repository.nameWithOwner,
            ciState: normalizeCIState(rollupState),
            reviewDecision: normalizeReviewDecision(
                node.latestOpinionatedReviews,
                pullRequestAuthor: node.author?.login
            ),
            additions: node.additions,
            deletions: node.deletions,
            commentCount: normalizeActionableUnresolvedCommentCount(node.reviewThreads),
            commentActivityCount: normalizeCommentActivityCount(node),
            recentCommentActivities: normalizeCommentActivities(node),
            reviewCount: node.reviews.totalCount,
            recentReviews: normalizeReviews(node.reviews, login: login),
            headRefOid: node.headRefOid,
            reviewRequestKind: normalizeReviewRequestKind(
                node.reviewRequests,
                login: login,
                isReviewRequestResult: isReviewRequestResult
            ),
            isAssignedToViewer: node.assignees.nodes.contains { $0.login == login },
            isMine: node.author?.login == login,
            author: node.author?.login ?? "unknown",
            authorAvatarURL: node.author?.avatarUrl,
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

    private static func normalizeReviewDecision(
        _ connection: GitHubPullRequestNode.OpinionatedReviewConnection?,
        pullRequestAuthor: String?
    ) -> ReviewDecision {
        guard let connection, let nodes = connection.nodes else { return .unknown }
        var hasApproval = false
        var hasUncertainty = connection.hasMissingNodes || (connection.totalCount.map { $0 > nodes.count } ?? true)

        for review in nodes {
            let state = review.state?.uppercased()
            switch state {
            case "COMMENTED", "PENDING", "DISMISSED":
                continue
            case "APPROVED", "CHANGES_REQUESTED":
                guard
                    let reviewer = review.author?.login,
                    let pullRequestAuthor
                else {
                    hasUncertainty = true
                    continue
                }
                if reviewer.caseInsensitiveCompare(pullRequestAuthor) == .orderedSame {
                    continue
                }
                if state == "CHANGES_REQUESTED" { return .changesRequested }
                hasApproval = true
            default:
                hasUncertainty = true
            }
        }

        if hasUncertainty { return .unknown }
        return hasApproval ? .approved : .noReviewYet
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

public final class GitHubClient: CompletePullRequestFetching, SourceCatalogProviding, GitHubAppInstallationProviding, GitHubViewerProviding, @unchecked Sendable {
    public let sourceKind: DashboardSource = .github

    private struct PullRequestSearch {
        let query: String
        let isReviewRequestResult: Bool
    }

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

    public func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?
    ) async throws -> CompletePullRequestFetchResult {
        let fetcher = GitHubPullRequestFetcher { [weak self] query, variables in
            guard let self else { throw CancellationError() }
            return try await self.completeGraphQL(query: query, variables: variables)
        }
        let discovery = try await fetcher.discover(login: login)
        let discoveredIDs = Set(discovery.pullRequests.map(\.id))
        let previousPullRequests = previousState?.account.login == login
            ? previousState?.dashboard.pullRequests ?? []
            : []
        let previousByID = Dictionary(uniqueKeysWithValues: previousPullRequests.map { ($0.id, $0) })

        let discoveredHydration = try await fetcher.hydrateForReconciliation(
            discovery.pullRequests,
            login: login
        )
        let absentIdentities = previousPullRequests
            .filter { !discoveredIDs.contains($0.id) }
            .map(Self.discoveryIdentity(from:))
        let absentHydration = try await fetcher.hydrateForReconciliation(absentIdentities, login: login)

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
            let pr = value.pullRequest
            let wasDiscovered = discoveredIDs.contains(pr.id)
            let baseRelevant = pr.isMine || pr.isAssignedToViewer || pr.reviewRequestKind.includesDirect
            var teamRelevant = false
            if pr.reviewRequestKind.includesTeam {
                if wasDiscovered && value.discovery.isTeamRequested {
                    teamRelevant = true
                } else {
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
                }
            }
            if value.providerState == "OPEN", baseRelevant || teamRelevant {
                active.append(pr)
            } else if previousByID[pr.id] != nil {
                retiring.append(pr)
            }
        }

        return CompletePullRequestFetchResult(
            activePullRequests: active.sorted { $0.id < $1.id },
            retiringPullRequests: retiring.sorted { $0.id < $1.id },
            quietlyRetiredPullRequestIDs: quietlyRetiredIDs
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
            guard message.localizedCaseInsensitiveContains("resource not accessible")
                    || message.localizedCaseInsensitiveContains("access denied") else {
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
            if http.statusCode == 403,
               http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
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
        if response.statusCode == 429
            || (response.statusCode == 403
                && (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                    || response.value(forHTTPHeaderField: "Retry-After") != nil)) {
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

    private static func pullRequestSearches(login: String) -> [PullRequestSearch] {
        [
            PullRequestSearch(query: "is:open is:pr author:\(login)", isReviewRequestResult: false),
            PullRequestSearch(query: "is:open is:pr assignee:\(login)", isReviewRequestResult: false),
            PullRequestSearch(query: "is:open is:pr review-requested:\(login)", isReviewRequestResult: true)
        ]
    }

    private func graphql(query: String, variables: [String: GraphQLVariable]) async throws -> Data {
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

    private func hasNonIgnorableGraphQLErrors<DataPayload>(
        _ errors: [GraphQLResponse<DataPayload>.GraphQLError]
    ) -> Bool {
        !errors.isEmpty
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
    let variables: [String: GraphQLVariable]
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

private enum GraphQLVariable: Encodable {
    case string(String)
    case strings([String])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .strings(let values):
            try container.encode(values)
        }
    }
}

private struct GraphQLResponse<DataPayload: Decodable>: Decodable {
    struct GraphQLError: Decodable {
        let message: String
        let path: [GraphQLErrorPathComponent]?

    }

    let data: DataPayload?
    let errors: [GraphQLError]?
}

private enum GraphQLErrorPathComponent: Decodable, Equatable {
    case field(String)
    case index(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .field(string)
        } else {
            self = .index(try container.decode(Int.self))
        }
    }
}

private struct PullRequestSearchData: Decodable {
    struct Search: Decodable {
        let nodes: [GitHubPullRequestNode]
    }

    let search: Search
}

private struct PullRequestNodesData: Decodable {
    let nodes: [GitHubPullRequestNode?]
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

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else {
            return [self]
        }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}

private struct GitHubRepositoryResponse: Decodable {
    struct Owner: Decodable {
        let login: String
    }

    let name: String
    let owner: Owner
}
