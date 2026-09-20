import Foundation

struct DiscoveredPullRequest: Equatable, Sendable {
    let id: String
    let repository: String
    let number: Int
    let createdAt: Date
    var isAuthored: Bool
    var isAssigned: Bool
    var isDirectlyRequested: Bool
    var isTeamRequested: Bool
}

struct GitHubDiscoveryResult: Equatable, Sendable {
    let pullRequests: [DiscoveredPullRequest]
    let coveredIntervals: [GitHubDiscoveryLane: [ClosedRange<Int>]]
}

struct GitHubHydratedPullRequest: Equatable, Sendable {
    let pullRequest: PullRequest
    let providerState: String
    let discovery: DiscoveredPullRequest
}

struct GitHubHydrationResult: Equatable, Sendable {
    let pullRequests: [GitHubHydratedPullRequest]
    let missingPullRequestIDs: Set<String>
}

enum GitHubDiscoveryLane: String, CaseIterable, Codable, Hashable, Sendable {
    case authored
    case assigned
    case direct
    case team
}

struct GitHubPullRequestFetcher: Sendable {
    typealias Read = @Sendable (_ query: String, _ variables: [String: GitHubQueryValue]) async throws -> Data

    private struct Bounds: Sendable {
        let lower: Int
        let upper: Int
    }

    private struct LaneAccumulator {
        var nodesByID: [String: GitHubDiscoveryNode] = [:]
        var cursor: String?
        var hasNext = true
        var finalCount = 0
    }

    private struct DiscoveryData: Decodable {
        let authored: GitHubDiscoverySearchPayload
        let assigned: GitHubDiscoverySearchPayload
        let direct: GitHubDiscoverySearchPayload
        let team: GitHubDiscoverySearchPayload

        func payload(for lane: GitHubDiscoveryLane) -> GitHubDiscoverySearchPayload {
            switch lane {
            case .authored: authored
            case .assigned: assigned
            case .direct: direct
            case .team: team
            }
        }
    }

    private struct HydrationData: Decodable {
        let nodes: [GitHubCompletePullRequestPayload?]
    }

    private struct RepositoryTeamData: Decodable {
        let search: GitHubDiscoverySearchPayload
    }

    private enum ConnectionKind: Hashable, Sendable {
        case comments(prID: String)
        case reviews(prID: String)
        case opinionatedReviews(prID: String)
        case threads(prID: String)
        case assignees(prID: String)
        case reviewRequests(prID: String)
        case threadComments(prID: String, threadID: String)

        var parentID: String {
            switch self {
            case .comments(let id), .reviews(let id), .opinionatedReviews(let id), .threads(let id),
                 .assignees(let id), .reviewRequests(let id): id
            case .threadComments(_, let threadID): threadID
            }
        }

        var connectionName: String {
            switch self {
            case .comments, .threadComments: "comments"
            case .reviews: "reviews"
            case .opinionatedReviews: "latestOpinionatedReviews"
            case .threads: "reviewThreads"
            case .assignees: "assignees"
            case .reviewRequests: "reviewRequests"
            }
        }
    }

    private struct Continuation: Hashable, Sendable {
        let kind: ConnectionKind
        let before: String
        let expectedTotal: Int?
    }

    private struct HydrationAccumulator {
        let payload: GitHubCompletePullRequestPayload
        let discovery: DiscoveredPullRequest
        var comments: [String: GitHubPayloadComment]
        var reviews: [String: GitHubPayloadReview]
        var opinionatedReviews: [String: GitHubPayloadReview]
        var threads: [String: GitHubPayloadReviewThread]
        var threadComments: [String: [String: GitHubPayloadComment]]
        var assignees: [String: GitHubPayloadUser]
        var reviewRequests: [String: GitHubPayloadReviewRequest]

        init(payload: GitHubCompletePullRequestPayload, discovery: DiscoveredPullRequest) {
            self.payload = payload
            self.discovery = discovery
            comments = Dictionary(uniqueKeysWithValues: payload.comments.nodes.map { ($0.id, $0) })
            reviews = Dictionary(uniqueKeysWithValues: payload.reviews.nodes.map { ($0.id, $0) })
            opinionatedReviews = Dictionary(uniqueKeysWithValues: payload.latestOpinionatedReviews.nodes.map { ($0.id, $0) })
            threads = Dictionary(uniqueKeysWithValues: payload.reviewThreads.nodes.map { ($0.id, $0) })
            threadComments = Dictionary(uniqueKeysWithValues: payload.reviewThreads.nodes.map { thread in
                (thread.id, Dictionary(uniqueKeysWithValues: thread.comments.nodes.map { ($0.id, $0) }))
            })
            assignees = Dictionary(uniqueKeysWithValues: payload.assignees.nodes.map { ($0.id ?? $0.login, $0) })
            reviewRequests = Dictionary(uniqueKeysWithValues: payload.reviewRequests.nodes.map { ($0.id, $0) })
        }
    }

    private struct BoundSearch: Decodable {
        let nodes: [GitHubDiscoveryNode?]
    }

    private struct BoundsData: Decodable {
        let authoredOldest: BoundSearch
        let authoredNewest: BoundSearch
        let assignedOldest: BoundSearch
        let assignedNewest: BoundSearch
        let directOldest: BoundSearch
        let directNewest: BoundSearch
        let teamOldest: BoundSearch
        let teamNewest: BoundSearch

        func pair(for lane: GitHubDiscoveryLane) -> (BoundSearch, BoundSearch) {
            switch lane {
            case .authored: (authoredOldest, authoredNewest)
            case .assigned: (assignedOldest, assignedNewest)
            case .direct: (directOldest, directNewest)
            case .team: (teamOldest, teamNewest)
            }
        }
    }

    private let read: Read
    private let decoder: JSONDecoder

    init(read: @escaping Read, decoder: JSONDecoder = JSONDecoder()) {
        self.read = read
        self.decoder = decoder
    }

    func discover(login: String) async throws -> GitHubDiscoveryResult {
        let bounds = try await fetchBounds(login: login)
        var identities: [String: DiscoveredPullRequest] = [:]
        var coverage: [GitHubDiscoveryLane: [ClosedRange<Int>]] = [:]
        let initialData = try await read(
            GitHubPullRequestQueries.discoveryPage,
            discoveryVariables(login: login, bounds: bounds)
        )
        let initialPayload = try decoder.decode(GitHubGraphQLPayload<DiscoveryData>.self, from: initialData)
        try validate(errors: initialPayload.errors)
        guard let initial = initialPayload.data else { throw GitHubReadError.invalidPayload }

        for lane in GitHubDiscoveryLane.allCases {
            guard let laneBounds = bounds[lane] else {
                coverage[lane] = []
                continue
            }
            let interval = laneBounds.lower...laneBounds.upper
            let firstPage = initial.payload(for: lane)
            let leaves: [LeafResult]
            if firstPage.issueCount > 1_000 {
                leaves = try await discoverLane(lane, login: login, bounds: laneBounds, allowRetry: true)
            } else {
                let result = try await fetchLeaf(
                    lane,
                    login: login,
                    interval: interval,
                    initialPage: firstPage
                )
                if result.nodes.count < result.finalCount {
                    let retry = try await fetchLeaf(lane, login: login, interval: interval)
                    guard !retry.exceededCap, retry.nodes.count >= retry.finalCount else {
                        throw GitHubReadError.incompleteCoverage("Incomplete \(lane.rawValue) discovery interval")
                    }
                    leaves = [LeafResult(interval: interval, nodes: retry.nodes)]
                } else {
                    leaves = [LeafResult(interval: interval, nodes: result.nodes)]
                }
            }
            coverage[lane] = leaves.map(\.interval)
            for leaf in leaves {
                for node in leaf.nodes {
                    let date = try parseDate(node.createdAt)
                    var value = identities[node.id] ?? DiscoveredPullRequest(
                        id: node.id,
                        repository: node.repository.nameWithOwner,
                        number: node.number,
                        createdAt: date,
                        isAuthored: false,
                        isAssigned: false,
                        isDirectlyRequested: false,
                        isTeamRequested: false
                    )
                    switch lane {
                    case .authored: value.isAuthored = true
                    case .assigned: value.isAssigned = true
                    case .direct: value.isDirectlyRequested = true
                    case .team: value.isTeamRequested = true
                    }
                    identities[node.id] = value
                }
            }
        }

        return GitHubDiscoveryResult(
            pullRequests: identities.values.sorted { $0.id < $1.id },
            coveredIntervals: coverage
        )
    }

    func hydrate(
        _ discovered: [DiscoveredPullRequest],
        login: String
    ) async throws -> [GitHubHydratedPullRequest] {
        let result = try await hydrateForReconciliation(discovered, login: login)
        guard result.missingPullRequestIDs.isEmpty else { throw GitHubReadError.invalidPayload }
        return result.pullRequests
    }

    func hydrateForReconciliation(
        _ discovered: [DiscoveredPullRequest],
        login: String
    ) async throws -> GitHubHydrationResult {
        var accumulators: [String: HydrationAccumulator] = [:]
        var continuations: [Continuation] = []
        var missingIDs = Set<String>()
        let discoveredByID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })

        for start in stride(from: 0, to: discovered.count, by: GitHubPullRequestQueries.hydrationBatchSize) {
            let chunk = Array(discovered[start..<min(start + GitHubPullRequestQueries.hydrationBatchSize, discovered.count)])
            let data = try await read(
                GitHubPullRequestQueries.hydration,
                ["ids": .strings(chunk.map { $0.id })]
            )
            let envelope = try decoder.decode(GitHubGraphQLPayload<HydrationData>.self, from: data)
            if let errors = envelope.errors, !errors.isEmpty {
                let onlyScopedNodeErrors = errors.allSatisfy { error in
                    guard let path = error.path, path.count >= 2 else { return false }
                    return path[0] == .field("nodes")
                }
                if !onlyScopedNodeErrors { try validate(errors: errors) }
            }
            guard let nodes = envelope.data?.nodes, nodes.count == chunk.count else {
                throw GitHubReadError.invalidPayload
            }
            for (index, node) in nodes.enumerated() {
                let expected = chunk[index]
                guard let node else {
                    missingIDs.insert(expected.id)
                    continue
                }
                guard node.id == expected.id, let discovery = discoveredByID[node.id] else { throw GitHubReadError.invalidPayload }
                guard accumulators[node.id] == nil else {
                    throw GitHubReadError.incompleteCoverage("Duplicate hydration node \(node.id)")
                }
                accumulators[node.id] = HydrationAccumulator(payload: node, discovery: discovery)
                continuations.append(contentsOf: try initialContinuations(for: node))
            }
        }

        var visitedCursors: [ConnectionKind: Set<String>] = [:]
        while !continuations.isEmpty {
            let batch = Array(continuations.prefix(GitHubPullRequestQueries.continuationBatchSize))
            continuations.removeFirst(min(batch.count, continuations.count))
            for item in batch {
                guard visitedCursors[item.kind, default: []].insert(item.before).inserted else {
                    throw GitHubReadError.incompleteCoverage("Repeated continuation cursor")
                }
            }
            let query = continuationQuery(batch)
            let variables = continuationVariables(batch)
            let data = try await read(query, variables)
            let pages = try decodeContinuationPages(data, batch: batch)
            for (item, page) in zip(batch, pages) {
                try merge(page: page, for: item, into: &accumulators, queue: &continuations)
            }
        }

        let pullRequests = try discovered.compactMap { discovery -> GitHubHydratedPullRequest? in
            guard let accumulator = accumulators[discovery.id] else {
                guard missingIDs.contains(discovery.id) else { throw GitHubReadError.invalidPayload }
                return nil
            }
            return GitHubHydratedPullRequest(
                pullRequest: try normalize(accumulator, login: login),
                providerState: accumulator.payload.state,
                discovery: discovery
            )
        }
        return GitHubHydrationResult(pullRequests: pullRequests, missingPullRequestIDs: missingIDs)
    }

    func repositoryTeamRequestedPullRequestIDs(
        repository: String,
        login: String
    ) async throws -> Set<String> {
        let queryValue = "is:open is:pr repo:\(repository) team-review-requested-user:\(login)"
        var cursor: String?
        var ids = Set<String>()
        repeat {
            let data = try await read(
                GitHubPullRequestQueries.repositoryTeamMembership,
                [
                    "query": .string(queryValue),
                    "cursor": cursor.map(GitHubQueryValue.string) ?? .null
                ]
            )
            let envelope = try decoder.decode(GitHubGraphQLPayload<RepositoryTeamData>.self, from: data)
            try validate(errors: envelope.errors)
            guard let page = envelope.data?.search else { throw GitHubReadError.invalidPayload }
            guard page.issueCount <= 1_000 else {
                throw GitHubReadError.incompleteCoverage("Repository team search exceeded 1,000 PRs")
            }
            try requiredNodes(page.nodes).forEach { ids.insert($0.id) }
            if page.pageInfo.hasNextPage {
                guard let next = page.pageInfo.endCursor, next != cursor else {
                    throw GitHubReadError.incompleteCoverage("Non-advancing repository team cursor")
                }
                cursor = next
            } else {
                cursor = nil
                guard ids.count >= page.issueCount else {
                    throw GitHubReadError.incompleteCoverage("Incomplete repository team search")
                }
                return ids
            }
        } while cursor != nil
        return ids
    }

    private func fetchBounds(login: String) async throws -> [GitHubDiscoveryLane: Bounds] {
        var variables: [String: GitHubQueryValue] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            let base = baseQuery(for: lane, login: login)
            variables["\(lane.rawValue)Oldest"] = .string("\(base) sort:created-asc")
            variables["\(lane.rawValue)Newest"] = .string("\(base) sort:created-desc")
        }
        let data = try await read(GitHubPullRequestQueries.discoveryBounds, variables)
        let payload = try decoder.decode(GitHubGraphQLPayload<BoundsData>.self, from: data)
        try validate(errors: payload.errors)
        guard let response = payload.data else { throw GitHubReadError.invalidPayload }
        var result: [GitHubDiscoveryLane: Bounds] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            let pair = response.pair(for: lane)
            guard let oldest = try requiredSingleNode(pair.0), let newest = try requiredSingleNode(pair.1) else { continue }
            let lower = Int(try parseDate(oldest.createdAt).timeIntervalSince1970)
            let upper = Int(try parseDate(newest.createdAt).timeIntervalSince1970)
            guard lower <= upper else { throw GitHubReadError.incompleteCoverage("Invalid creation bounds for \(lane.rawValue)") }
            result[lane] = Bounds(lower: lower, upper: upper)
        }
        return result
    }

    private enum ContinuationPage {
        case comments(GitHubStrictConnection<GitHubPayloadComment>)
        case reviews(GitHubStrictConnection<GitHubPayloadReview>)
        case threads(GitHubStrictConnection<GitHubPayloadReviewThread>)
        case users(GitHubStrictConnection<GitHubPayloadUser>)
        case requests(GitHubStrictConnection<GitHubPayloadReviewRequest>)

        var pageInfo: GitHubPageInfo {
            switch self {
            case .comments(let value): value.pageInfo
            case .reviews(let value): value.pageInfo
            case .threads(let value): value.pageInfo
            case .users(let value): value.pageInfo
            case .requests(let value): value.pageInfo
            }
        }

        var totalCount: Int? {
            switch self {
            case .comments(let value): value.totalCount
            case .reviews(let value): value.totalCount
            case .threads(let value): value.totalCount
            case .users(let value): value.totalCount
            case .requests(let value): value.totalCount
            }
        }

        var nodeCount: Int {
            switch self {
            case .comments(let value): value.nodes.count
            case .reviews(let value): value.nodes.count
            case .threads(let value): value.nodes.count
            case .users(let value): value.nodes.count
            case .requests(let value): value.nodes.count
            }
        }
    }

    private func initialContinuations(for payload: GitHubCompletePullRequestPayload) throws -> [Continuation] {
        var result: [Continuation] = []
        try appendContinuation(
            kind: .comments(prID: payload.id), connection: payload.comments, to: &result
        )
        try appendContinuation(
            kind: .reviews(prID: payload.id), connection: payload.reviews, to: &result
        )
        try appendContinuation(
            kind: .opinionatedReviews(prID: payload.id), connection: payload.latestOpinionatedReviews, to: &result
        )
        try appendContinuation(
            kind: .threads(prID: payload.id), connection: payload.reviewThreads, to: &result
        )
        try appendContinuation(
            kind: .assignees(prID: payload.id), connection: payload.assignees, to: &result
        )
        try appendContinuation(
            kind: .reviewRequests(prID: payload.id), connection: payload.reviewRequests, to: &result
        )
        for thread in payload.reviewThreads.nodes {
            try appendContinuation(
                kind: .threadComments(prID: payload.id, threadID: thread.id),
                connection: thread.comments,
                to: &result
            )
        }
        return result
    }

    private func appendContinuation<Node>(
        kind: ConnectionKind,
        connection: GitHubStrictConnection<Node>,
        to result: inout [Continuation]
    ) throws where Node: Decodable & Equatable & Sendable {
        guard connection.pageInfo.hasPreviousPage else {
            if let total = connection.totalCount, connection.nodes.count < total {
                throw GitHubReadError.incompleteCoverage("Connection omitted required items")
            }
            return
        }
        guard let cursor = connection.pageInfo.startCursor else { throw GitHubReadError.invalidPayload }
        result.append(Continuation(kind: kind, before: cursor, expectedTotal: connection.totalCount))
    }

    private func continuationQuery(_ batch: [Continuation]) -> String {
        let declarations = batch.indices.flatMap { index in
            ["$id\(index): ID!", "$cursor\(index): String!"]
        }.joined(separator: ", ")
        let selections = batch.enumerated().map { index, continuation in
            "c\(index): node(id: $id\(index)) { \(continuationSelection(for: continuation.kind, cursor: "$cursor\(index)")) }"
        }.joined(separator: "\n")
        return "query ContinuePullRequestConnections(\(declarations)) {\n\(selections)\n}"
    }

    private func continuationSelection(for kind: ConnectionKind, cursor: String) -> String {
        switch kind {
        case .comments:
            return "... on PullRequest { comments(last: 10, before: \(cursor)) { \(commentConnectionFields) } }"
        case .reviews:
            return "... on PullRequest { reviews(last: 10, before: \(cursor)) { \(reviewConnectionFields) } }"
        case .opinionatedReviews:
            return "... on PullRequest { latestOpinionatedReviews(last: 20, before: \(cursor)) { \(reviewConnectionFields) } }"
        case .threads:
            return """
            ... on PullRequest { reviewThreads(last: 20, before: \(cursor)) {
              totalCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
              nodes {
                id isResolved viewerCanResolve
                comments(last: 10) { \(commentConnectionFields) }
              }
            } }
            """
        case .assignees:
            return "... on PullRequest { assignees(last: 20, before: \(cursor)) { totalCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage } nodes { id login avatarUrl(size: 64) } } }"
        case .reviewRequests:
            return """
            ... on PullRequest { reviewRequests(last: 20, before: \(cursor)) {
              totalCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
              nodes { id requestedReviewer { __typename ... on User { id login } ... on Team { id slug organization { login } } } }
            } }
            """
        case .threadComments:
            return "... on PullRequestReviewThread { comments(last: 10, before: \(cursor)) { \(commentConnectionFields) } }"
        }
    }

    private var commentConnectionFields: String {
        "totalCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage } nodes { id createdAt viewerDidAuthor author { id login } pullRequestReview { id } }"
    }

    private var reviewConnectionFields: String {
        "totalCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage } nodes { id state submittedAt viewerDidAuthor author { id login } }"
    }

    private func continuationVariables(_ batch: [Continuation]) -> [String: GitHubQueryValue] {
        var result: [String: GitHubQueryValue] = [:]
        for (index, continuation) in batch.enumerated() {
            result["id\(index)"] = .string(continuation.kind.parentID)
            result["cursor\(index)"] = .string(continuation.before)
        }
        return result
    }

    private func decodeContinuationPages(_ data: Data, batch: [Continuation]) throws -> [ContinuationPage] {
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let errorObject = envelope?["errors"] {
            let errorsData = try JSONSerialization.data(withJSONObject: ["errors": errorObject])
            struct ErrorOnly: Decodable { let errors: [GitHubGraphQLErrorPayload] }
            let errors = try decoder.decode(ErrorOnly.self, from: errorsData).errors
            try validate(errors: errors)
        }
        guard let dataObject = envelope?["data"] as? [String: Any] else { throw GitHubReadError.invalidPayload }
        return try batch.enumerated().map { index, continuation in
            guard
                let node = dataObject["c\(index)"] as? [String: Any],
                let connection = node[continuation.kind.connectionName]
            else {
                throw GitHubReadError.invalidPayload
            }
            let connectionData = try JSONSerialization.data(withJSONObject: connection)
            switch continuation.kind {
            case .comments, .threadComments:
                return .comments(try decoder.decode(GitHubStrictConnection<GitHubPayloadComment>.self, from: connectionData))
            case .reviews, .opinionatedReviews:
                return .reviews(try decoder.decode(GitHubStrictConnection<GitHubPayloadReview>.self, from: connectionData))
            case .threads:
                return .threads(try decoder.decode(GitHubStrictConnection<GitHubPayloadReviewThread>.self, from: connectionData))
            case .assignees:
                return .users(try decoder.decode(GitHubStrictConnection<GitHubPayloadUser>.self, from: connectionData))
            case .reviewRequests:
                return .requests(try decoder.decode(GitHubStrictConnection<GitHubPayloadReviewRequest>.self, from: connectionData))
            }
        }
    }

    private func merge(
        page: ContinuationPage,
        for continuation: Continuation,
        into accumulators: inout [String: HydrationAccumulator],
        queue: inout [Continuation]
    ) throws {
        let prID: String
        switch continuation.kind {
        case .comments(let id), .reviews(let id), .opinionatedReviews(let id), .threads(let id),
             .assignees(let id), .reviewRequests(let id), .threadComments(let id, _):
            prID = id
        }
        guard var accumulator = accumulators[prID] else { throw GitHubReadError.invalidPayload }
        if let expected = continuation.expectedTotal, let observed = page.totalCount, observed < expected {
            throw GitHubReadError.incompleteCoverage("Connection total decreased during traversal")
        }
        switch (continuation.kind, page) {
        case (.comments, .comments(let value)):
            value.nodes.forEach { accumulator.comments[$0.id] = $0 }
        case (.threadComments(_, let threadID), .comments(let value)):
            value.nodes.forEach { accumulator.threadComments[threadID, default: [:]][$0.id] = $0 }
        case (.reviews, .reviews(let value)):
            value.nodes.forEach { accumulator.reviews[$0.id] = $0 }
        case (.opinionatedReviews, .reviews(let value)):
            value.nodes.forEach { accumulator.opinionatedReviews[$0.id] = $0 }
        case (.threads, .threads(let value)):
            for thread in value.nodes {
                accumulator.threads[thread.id] = thread
                thread.comments.nodes.forEach { accumulator.threadComments[thread.id, default: [:]][$0.id] = $0 }
                try appendContinuation(
                    kind: .threadComments(prID: prID, threadID: thread.id),
                    connection: thread.comments,
                    to: &queue
                )
            }
        case (.assignees, .users(let value)):
            value.nodes.forEach { accumulator.assignees[$0.id ?? $0.login] = $0 }
        case (.reviewRequests, .requests(let value)):
            value.nodes.forEach { accumulator.reviewRequests[$0.id] = $0 }
        default:
            throw GitHubReadError.invalidPayload
        }
        accumulators[prID] = accumulator

        if page.pageInfo.hasPreviousPage {
            guard let cursor = page.pageInfo.startCursor else { throw GitHubReadError.invalidPayload }
            queue.append(Continuation(kind: continuation.kind, before: cursor, expectedTotal: continuation.expectedTotal))
        } else if let expected = continuation.expectedTotal {
            let actual = accumulatedCount(for: continuation.kind, in: accumulator)
            guard actual >= expected else {
                throw GitHubReadError.incompleteCoverage("Connection returned \(actual) of \(expected) items")
            }
        }
    }

    private func accumulatedCount(for kind: ConnectionKind, in value: HydrationAccumulator) -> Int {
        switch kind {
        case .comments: value.comments.count
        case .reviews: value.reviews.count
        case .opinionatedReviews: value.opinionatedReviews.count
        case .threads: value.threads.count
        case .assignees: value.assignees.count
        case .reviewRequests: value.reviewRequests.count
        case .threadComments(_, let threadID): value.threadComments[threadID]?.count ?? 0
        }
    }

    private func normalize(_ value: HydrationAccumulator, login: String) throws -> PullRequest {
        let payload = value.payload
        let topLevelComments = try value.comments.values.map { comment in
            PullRequestCommentActivity(
                id: comment.id,
                author: comment.author?.login,
                viewerDidAuthor: comment.viewerDidAuthor,
                createdAt: try parseDate(comment.createdAt),
                source: .pullRequest
            )
        }
        let threadComments = try value.threadComments.values.flatMap(\.values).map { comment in
            PullRequestCommentActivity(
                id: comment.id,
                author: comment.author?.login,
                viewerDidAuthor: comment.viewerDidAuthor,
                createdAt: try parseDate(comment.createdAt),
                source: .reviewThread,
                reviewId: comment.pullRequestReview?.id
            )
        }
        let allComments = (topLevelComments + threadComments).reduce(into: [String: PullRequestCommentActivity]()) {
            $0[$1.id] = $1
        }.values.sorted { $0.createdAt < $1.createdAt }
        let reviews = try value.reviews.values.compactMap { review -> PullRequestReview? in
            guard let submittedAt = review.submittedAt, let state = normalizeReviewState(review.state) else { return nil }
            return PullRequestReview(
                id: review.id,
                state: state,
                submittedAt: try parseDate(submittedAt),
                author: review.author?.login,
                viewerDidAuthor: review.viewerDidAuthor
            )
        }.sorted { $0.submittedAt < $1.submittedAt }
        let actionableThreads = value.threads.values.filter { thread in
            !thread.isResolved && thread.viewerCanResolve
                && (value.threadComments[thread.id]?.values.contains { !$0.viewerDidAuthor } ?? false)
        }.count

        return PullRequest(
            id: payload.id,
            title: payload.title,
            number: payload.number,
            url: URL(string: payload.url)!,
            repo: payload.repository.nameWithOwner,
            ciState: GitHubPullRequestNormalizer.normalizeCIState(payload.statusCheckRollup?.state),
            reviewDecision: normalizeReviewDecision(
                Array(value.opinionatedReviews.values),
                pullRequestAuthor: payload.author?.login
            ),
            additions: payload.additions,
            deletions: payload.deletions,
            commentCount: actionableThreads,
            commentActivityCount: allComments.count,
            recentCommentActivities: Array(allComments),
            reviewCount: value.reviews.count,
            recentReviews: reviews,
            headRefOid: payload.headRefOid,
            reviewRequestKind: reviewRequestKind(for: value, login: login),
            isAssignedToViewer: value.assignees.values.contains { $0.login.caseInsensitiveCompare(login) == .orderedSame },
            isMine: value.discovery.isAuthored || payload.author?.login.caseInsensitiveCompare(login) == .orderedSame,
            author: payload.author?.login ?? "unknown",
            authorAvatarURL: payload.author?.avatarUrl,
            headRefName: payload.headRefName,
            mergeable: GitHubPullRequestNormalizer.normalizeMergeableState(payload.mergeable),
            draft: payload.isDraft,
            createdAt: try parseDate(payload.createdAt),
            updatedAt: try parseDate(payload.updatedAt)
        )
    }

    private func normalizeReviewState(_ state: String) -> PullRequestReviewState? {
        GitHubPullRequestNormalizer.normalizeReviewState(state.uppercased())
    }

    private func normalizeReviewDecision(
        _ reviews: [GitHubPayloadReview],
        pullRequestAuthor: String?
    ) -> ReviewDecision {
        var approved = false
        for review in reviews {
            guard let author = review.author?.login, let pullRequestAuthor else { return .unknown }
            if author.caseInsensitiveCompare(pullRequestAuthor) == .orderedSame { continue }
            switch review.state.uppercased() {
            case "CHANGES_REQUESTED": return .changesRequested
            case "APPROVED": approved = true
            case "COMMENTED", "PENDING", "DISMISSED": continue
            default: return .unknown
            }
        }
        return approved ? .approved : .noReviewYet
    }

    private func reviewRequestKind(for value: HydrationAccumulator, login: String) -> ReviewRequestKind {
        let direct = value.reviewRequests.values.contains { request in
            request.requestedReviewer?.typename == "User"
                && request.requestedReviewer?.login?.caseInsensitiveCompare(login) == .orderedSame
        }
        let team = value.discovery.isTeamRequested && value.reviewRequests.values.contains {
            $0.requestedReviewer?.typename == "Team"
        }
        return switch (direct, team) {
        case (true, true): .directAndTeam
        case (true, false): .direct
        case (false, true): .team
        case (false, false): .none
        }
    }

    private struct LeafResult {
        let interval: ClosedRange<Int>
        let nodes: [GitHubDiscoveryNode]
    }

    private func discoverLane(
        _ lane: GitHubDiscoveryLane,
        login: String,
        bounds: Bounds,
        allowRetry: Bool
    ) async throws -> [LeafResult] {
        var queue = [bounds.lower...bounds.upper]
        var complete: [LeafResult] = []
        while let interval = queue.popLast() {
            let pageResult = try await fetchLeaf(lane, login: login, interval: interval)
            if pageResult.exceededCap {
                guard interval.lowerBound < interval.upperBound else {
                    throw GitHubReadError.incompleteCoverage("More than 1,000 \(lane.rawValue) PRs share one creation second")
                }
                let midpoint = interval.lowerBound + (interval.upperBound - interval.lowerBound) / 2
                queue.append((midpoint + 1)...interval.upperBound)
                queue.append(interval.lowerBound...midpoint)
                continue
            }
            if pageResult.nodes.count < pageResult.finalCount {
                guard allowRetry else {
                    throw GitHubReadError.incompleteCoverage("Incomplete \(lane.rawValue) discovery interval")
                }
                let retry = try await fetchLeaf(lane, login: login, interval: interval)
                guard !retry.exceededCap, retry.nodes.count >= retry.finalCount else {
                    throw GitHubReadError.incompleteCoverage("Incomplete \(lane.rawValue) discovery interval")
                }
                complete.append(LeafResult(interval: interval, nodes: retry.nodes))
            } else {
                complete.append(LeafResult(interval: interval, nodes: pageResult.nodes))
            }
        }
        return complete.sorted { $0.interval.lowerBound < $1.interval.lowerBound }
    }

    private func fetchLeaf(
        _ lane: GitHubDiscoveryLane,
        login: String,
        interval: ClosedRange<Int>,
        initialPage: GitHubDiscoverySearchPayload? = nil
    ) async throws -> (nodes: [GitHubDiscoveryNode], finalCount: Int, exceededCap: Bool) {
        var accumulator = LaneAccumulator()
        var pendingPage = initialPage
        repeat {
            let page: GitHubDiscoverySearchPayload
            if let firstPage = pendingPage {
                page = firstPage
                pendingPage = nil
            } else {
                let variables = discoveryVariables(
                    activeLane: lane,
                    login: login,
                    interval: interval,
                    cursor: accumulator.cursor
                )
                let data = try await read(GitHubPullRequestQueries.discoveryPage, variables)
                let payload = try decoder.decode(GitHubGraphQLPayload<DiscoveryData>.self, from: data)
                try validate(errors: payload.errors)
                guard let response = payload.data else { throw GitHubReadError.invalidPayload }
                page = response.payload(for: lane)
            }
            if page.issueCount > 1_000 {
                return ([], page.issueCount, true)
            }
            let nodes = try requiredNodes(page.nodes)
            for node in nodes { accumulator.nodesByID[node.id] = node }
            accumulator.finalCount = page.issueCount
            if page.pageInfo.hasNextPage {
                guard let next = page.pageInfo.endCursor, next != accumulator.cursor else {
                    throw GitHubReadError.incompleteCoverage("Non-advancing \(lane.rawValue) discovery cursor")
                }
                accumulator.cursor = next
            }
            accumulator.hasNext = page.pageInfo.hasNextPage
        } while accumulator.hasNext
        return (Array(accumulator.nodesByID.values), accumulator.finalCount, false)
    }

    private func discoveryVariables(
        login: String,
        bounds: [GitHubDiscoveryLane: Bounds]
    ) -> [String: GitHubQueryValue] {
        var result: [String: GitHubQueryValue] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            if let bounds = bounds[lane] {
                result["\(lane.rawValue)Query"] = .string(
                    "\(baseQuery(for: lane, login: login)) created:\(formatSecond(bounds.lower))..\(formatSecond(bounds.upper))"
                )
            } else {
                result["\(lane.rawValue)Query"] = .string("is:open is:pr repo:__mergehawk__/__empty__")
            }
            result["\(lane.rawValue)Cursor"] = .null
        }
        return result
    }

    private func discoveryVariables(
        activeLane: GitHubDiscoveryLane,
        login: String,
        interval: ClosedRange<Int>,
        cursor: String?
    ) -> [String: GitHubQueryValue] {
        var result: [String: GitHubQueryValue] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            let query: String
            if lane == activeLane {
                query = "\(baseQuery(for: lane, login: login)) created:\(formatSecond(interval.lowerBound))..\(formatSecond(interval.upperBound))"
            } else {
                query = "is:open is:pr repo:__mergehawk__/__empty__"
            }
            result["\(lane.rawValue)Query"] = .string(query)
            result["\(lane.rawValue)Cursor"] = lane == activeLane ? cursor.map(GitHubQueryValue.string) ?? .null : .null
        }
        return result
    }

    private func baseQuery(for lane: GitHubDiscoveryLane, login: String) -> String {
        switch lane {
        case .authored: "is:open is:pr author:\(login)"
        case .assigned: "is:open is:pr assignee:\(login)"
        case .direct: "is:open is:pr user-review-requested:@me"
        case .team: "is:open is:pr team-review-requested-user:\(login)"
        }
    }

    private func requiredNodes(_ nodes: [GitHubDiscoveryNode?]) throws -> [GitHubDiscoveryNode] {
        guard nodes.allSatisfy({ $0 != nil }) else { throw GitHubReadError.invalidPayload }
        return nodes.compactMap { $0 }
    }

    private func requiredSingleNode(_ search: BoundSearch) throws -> GitHubDiscoveryNode? {
        let nodes = try requiredNodes(search.nodes)
        guard nodes.count <= 1 else { throw GitHubReadError.invalidPayload }
        return nodes.first
    }

    private func validate(errors: [GitHubGraphQLErrorPayload]?) throws {
        guard let errors, !errors.isEmpty else { return }
        if errors.contains(where: { $0.type == "VALIDATION" }) {
            throw GitHubReadError.validation(errors.map(\.message).joined(separator: "; "))
        }
        throw GitHubReadError.graphQL(errors)
    }

    private func parseDate(_ value: String) throws -> Date {
        guard let date = Self.dateFormatter.date(from: value) else { throw GitHubReadError.invalidPayload }
        return date
    }

    private func formatSecond(_ value: Int) -> String {
        Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(value)))
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
