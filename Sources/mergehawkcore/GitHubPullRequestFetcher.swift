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
    let hasTeamReviewRequest: Bool
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

    private struct SearchData: Decodable {
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

    /// A page request for one connection. `before == nil` re-reads the connection from its newest page.
    private struct Continuation: Hashable, Sendable {
        let kind: ConnectionKind
        let before: String?
        let expectedTotal: Int?
        let attempt: Int

        init(kind: ConnectionKind, before: String?, expectedTotal: Int?, attempt: Int = 0) {
            self.kind = kind
            self.before = before
            self.expectedTotal = expectedTotal
            self.attempt = attempt
        }
    }

    private struct ContinuationVisit: Hashable {
        let kind: ConnectionKind
        let attempt: Int
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
            let firstPage = initial.payload(for: lane)
            let leaves: [LeafResult]
            guard let laneBounds = bounds[lane] else {
                leaves = try await discoverNewlyPopulatedLane(lane, login: login, firstPage: firstPage)
                coverage[lane] = leaves.map(\.interval)
                try record(leaves, lane: lane, into: &identities)
                continue
            }
            let interval = laneBounds.lower...laneBounds.upper
            if firstPage.issueCount > 1_000 {
                leaves = try await discoverLane(lane, login: login, bounds: laneBounds, splitsInitialInterval: true)
            } else {
                let result = try await fetchLeaf(
                    lane,
                    login: login,
                    interval: interval,
                    laneUpper: laneBounds.upper,
                    initialPage: firstPage
                )
                if result.exceededCap {
                    leaves = try await discoverLane(lane, login: login, bounds: laneBounds, splitsInitialInterval: true)
                } else if result.nodes.count < result.finalCount {
                    let retry = try await fetchLeaf(lane, login: login, interval: interval, laneUpper: laneBounds.upper)
                    if retry.exceededCap {
                        leaves = try await discoverLane(lane, login: login, bounds: laneBounds, splitsInitialInterval: true)
                    } else if retry.nodes.count >= retry.finalCount {
                        leaves = [LeafResult(interval: interval, nodes: retry.nodes)]
                    } else {
                        throw GitHubReadError.incompleteCoverage("Incomplete \(lane.rawValue) discovery interval")
                    }
                } else {
                    leaves = [LeafResult(interval: interval, nodes: result.nodes)]
                }
            }
            coverage[lane] = leaves.map(\.interval)
            try record(leaves, lane: lane, into: &identities)
        }

        return GitHubDiscoveryResult(
            pullRequests: identities.values.sorted { $0.id < $1.id },
            coveredIntervals: coverage
        )
    }

    private func record(
        _ leaves: [LeafResult],
        lane: GitHubDiscoveryLane,
        into identities: inout [String: DiscoveredPullRequest]
    ) throws {
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

    /// A lane that was empty at the bounds query is searched without a date range, so PRs created since still count.
    private func discoverNewlyPopulatedLane(
        _ lane: GitHubDiscoveryLane,
        login: String,
        firstPage: GitHubDiscoverySearchPayload
    ) async throws -> [LeafResult] {
        guard firstPage.issueCount > 0 else { return [] }
        let query = baseQuery(for: lane, login: login)
        var result = try await fetchSearchLeaf(query: query, initialPage: firstPage)
        if !result.exceededCap, result.nodes.count < result.finalCount {
            result = try await fetchSearchLeaf(query: query, initialPage: nil)
        }
        guard !result.exceededCap, result.nodes.count >= result.finalCount else {
            throw GitHubReadError.incompleteCoverage("Incomplete \(lane.rawValue) discovery")
        }
        let seconds = try result.nodes.map { Int(try parseDate($0.createdAt).timeIntervalSince1970) }
        guard let lower = seconds.min(), let upper = seconds.max() else { return [] }
        return [LeafResult(interval: lower...upper, nodes: result.nodes)]
    }

    func hydrate(
        _ discovered: [DiscoveredPullRequest],
        login: String
    ) async throws -> [GitHubHydratedPullRequest] {
        let result = try await hydrateForReconciliation(discovered, login: login)
        guard result.missingPullRequestIDs.isEmpty else { throw GitHubReadError.invalidPayload }
        return result.pullRequests
    }

    /// `includesForbiddenNodes` treats a node GitHub refuses to return like a missing one. Use it only for PRs
    /// that dropped out of search, where lost access (SAML, OAuth App restrictions) is the expected cause.
    func hydrateForReconciliation(
        _ discovered: [DiscoveredPullRequest],
        login: String,
        includesForbiddenNodes: Bool = false
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
            let raw = try rawHydrationResponse(data, expectedCount: chunk.count)
            var failedIndices = Set<Int>()
            if !raw.errors.isEmpty {
                for error in raw.errors {
                    guard let path = error.path,
                          path.count >= 2,
                          path[0] == .field("nodes"),
                          case .index(let index) = path[1],
                          chunk.indices.contains(index) else {
                        try validate(errors: raw.errors)
                        throw GitHubReadError.invalidPayload
                    }
                    failedIndices.insert(index)
                }
            }
            for (index, rawNode) in raw.nodes.enumerated() {
                let expected = chunk[index]
                if failedIndices.contains(index) { continue }
                let node = try decodeHydrationNode(rawNode)
                guard let node else {
                    missingIDs.insert(expected.id)
                    continue
                }
                try storeHydrationNode(
                    node,
                    expected: expected,
                    discoveredByID: discoveredByID,
                    accumulators: &accumulators,
                    continuations: &continuations
                )
            }
            for index in failedIndices.sorted() {
                let expected = chunk[index]
                let retryData = try await read(
                    GitHubPullRequestQueries.hydration,
                    ["ids": .strings([expected.id])]
                )
                let retry = try rawHydrationResponse(retryData, expectedCount: 1)
                if isMissingNodeCandidate(
                    retry.nodes[0],
                    errors: retry.errors,
                    index: 0,
                    includesForbiddenNodes: includesForbiddenNodes
                ) {
                    missingIDs.insert(expected.id)
                    continue
                }
                try validate(errors: retry.errors)
                guard let node = try decodeHydrationNode(retry.nodes[0]) else {
                    missingIDs.insert(expected.id)
                    continue
                }
                try storeHydrationNode(
                    node,
                    expected: expected,
                    discoveredByID: discoveredByID,
                    accumulators: &accumulators,
                    continuations: &continuations
                )
            }
        }

        var visitedCursors: [ContinuationVisit: Set<String?>] = [:]
        while !continuations.isEmpty {
            let batch = Array(continuations.prefix(GitHubPullRequestQueries.continuationBatchSize))
            continuations.removeFirst(min(batch.count, continuations.count))
            for item in batch {
                let visit = ContinuationVisit(kind: item.kind, attempt: item.attempt)
                guard visitedCursors[visit, default: []].insert(item.before).inserted else {
                    throw GitHubReadError.incompleteCoverage("Repeated continuation cursor")
                }
            }
            let query = continuationQuery(batch)
            let variables = continuationVariables(batch)
            let data = try await read(query, variables)
            let decoded = try decodeContinuationPages(data, batch: batch, allowsScopedErrors: true)
            // Thread-comment results for a PR whose thread list restarts in this batch belong to the discarded read.
            var restartedThreadPRs = Set<String>()
            func isSuperseded(_ item: Continuation) -> Bool {
                guard case .threadComments(let prID, _) = item.kind else { return false }
                return restartedThreadPRs.contains(prID)
            }
            for (index, page) in decoded.pages.sorted(by: { $0.key < $1.key }) where !isSuperseded(batch[index]) {
                try merge(
                    page: page,
                    for: batch[index],
                    into: &accumulators,
                    queue: &continuations,
                    restartedThreadPRs: &restartedThreadPRs
                )
            }
            for index in decoded.failedIndices.sorted() where !isSuperseded(batch[index]) {
                let item = batch[index]
                let retryData = try await read(
                    continuationQuery([item]),
                    continuationVariables([item])
                )
                let retry = try decodeContinuationPages(
                    retryData,
                    batch: [item],
                    allowsScopedErrors: false
                )
                guard let page = retry.pages[0], retry.failedIndices.isEmpty else {
                    throw GitHubReadError.invalidPayload
                }
                try merge(
                    page: page,
                    for: item,
                    into: &accumulators,
                    queue: &continuations,
                    restartedThreadPRs: &restartedThreadPRs
                )
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
                discovery: discovery,
                hasTeamReviewRequest: accumulator.reviewRequests.values.contains {
                    $0.requestedReviewer?.typename == "Team"
                }
            )
        }
        return GitHubHydrationResult(pullRequests: pullRequests, missingPullRequestIDs: missingIDs)
    }

    private func rawHydrationResponse(
        _ data: Data,
        expectedCount: Int
    ) throws -> (nodes: [Any], errors: [GitHubGraphQLErrorPayload]) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubReadError.invalidPayload
        }
        let errors = try decodeErrors(object["errors"])
        guard let dataObject = object["data"] as? [String: Any],
              let nodes = dataObject["nodes"] as? [Any],
              nodes.count == expectedCount else {
            throw GitHubReadError.invalidPayload
        }
        return (nodes, errors)
    }

    private func isMissingNodeCandidate(
        _ node: Any,
        errors: [GitHubGraphQLErrorPayload],
        index: Int,
        includesForbiddenNodes: Bool
    ) -> Bool {
        guard node is NSNull, !errors.isEmpty else { return false }
        let missingTypes: Set<String> = includesForbiddenNodes ? ["NOT_FOUND", "FORBIDDEN"] : ["NOT_FOUND"]
        return errors.allSatisfy { error in
            missingTypes.contains(error.type?.uppercased() ?? "")
                && error.path == [.field("nodes"), .index(index)]
        }
    }

    private func decodeHydrationNode(_ value: Any) throws -> GitHubCompletePullRequestPayload? {
        if value is NSNull { return nil }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try decoder.decode(GitHubCompletePullRequestPayload.self, from: data)
    }

    private func decodeErrors(_ value: Any?) throws -> [GitHubGraphQLErrorPayload] {
        guard let value, !(value is NSNull) else { return [] }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try decoder.decode([GitHubGraphQLErrorPayload].self, from: data)
    }

    private func storeHydrationNode(
        _ node: GitHubCompletePullRequestPayload,
        expected: DiscoveredPullRequest,
        discoveredByID: [String: DiscoveredPullRequest],
        accumulators: inout [String: HydrationAccumulator],
        continuations: inout [Continuation]
    ) throws {
        guard node.id == expected.id, let discovery = discoveredByID[node.id] else {
            throw GitHubReadError.invalidPayload
        }
        guard accumulators[node.id] == nil else {
            throw GitHubReadError.incompleteCoverage("Duplicate hydration node \(node.id)")
        }
        accumulators[node.id] = HydrationAccumulator(payload: node, discovery: discovery)
        continuations.append(contentsOf: try initialContinuations(for: node))
    }

    func repositoryTeamRequestedPullRequestIDs(
        repository: String,
        login: String
    ) async throws -> Set<String> {
        let base = "is:open is:pr repo:\(repository) team-review-requested-user:\(login)"
        let oldestPage = try await fetchSearchPage(query: "\(base) sort:created-asc", cursor: nil)
        let newestPage = try await fetchSearchPage(query: "\(base) sort:created-desc", cursor: nil)
        guard let oldest = try requiredNodes(oldestPage.nodes).first,
              let newest = try requiredNodes(newestPage.nodes).first else {
            return []
        }
        let lower = Int(try parseDate(oldest.createdAt).timeIntervalSince1970)
        let upper = Int(try parseDate(newest.createdAt).timeIntervalSince1970)
        guard lower <= upper else { throw GitHubReadError.incompleteCoverage("Invalid repository team bounds") }

        var queue = [lower...upper]
        var ids = Set<String>()
        while let interval = queue.popLast() {
            let result = try await fetchRepositoryTeamLeaf(base: base, interval: interval, upper: upper)
            if result.exceededCap {
                guard interval.lowerBound < interval.upperBound else {
                    throw GitHubReadError.incompleteCoverage(
                        "More than 1,000 repository team PRs share one creation second"
                    )
                }
                let midpoint = interval.lowerBound + (interval.upperBound - interval.lowerBound) / 2
                queue.append((midpoint + 1)...interval.upperBound)
                queue.append(interval.lowerBound...midpoint)
                continue
            }
            if result.nodes.count < result.finalCount {
                let retry = try await fetchRepositoryTeamLeaf(base: base, interval: interval, upper: upper)
                guard !retry.exceededCap, retry.nodes.count >= retry.finalCount else {
                    throw GitHubReadError.incompleteCoverage("Incomplete repository team search")
                }
                retry.nodes.forEach { ids.insert($0.id) }
            } else {
                result.nodes.forEach { ids.insert($0.id) }
            }
        }
        return ids
    }

    private func fetchRepositoryTeamLeaf(
        base: String,
        interval: ClosedRange<Int>,
        upper: Int
    ) async throws -> (nodes: [GitHubDiscoveryNode], finalCount: Int, exceededCap: Bool) {
        try await fetchSearchLeaf(
            query: "\(base) \(createdQualifier(interval, laneUpper: upper))",
            initialPage: nil
        )
    }

    private func fetchSearchLeaf(
        query: String,
        initialPage: GitHubDiscoverySearchPayload?
    ) async throws -> (nodes: [GitHubDiscoveryNode], finalCount: Int, exceededCap: Bool) {
        var accumulator = LaneAccumulator()
        var pendingPage = initialPage
        repeat {
            let page: GitHubDiscoverySearchPayload
            if let firstPage = pendingPage {
                page = firstPage
                pendingPage = nil
            } else {
                page = try await fetchSearchPage(query: query, cursor: accumulator.cursor)
            }
            if page.issueCount > 1_000 { return ([], page.issueCount, true) }
            try requiredNodes(page.nodes).forEach { accumulator.nodesByID[$0.id] = $0 }
            accumulator.finalCount = page.issueCount
            if page.pageInfo.hasNextPage {
                guard let next = page.pageInfo.endCursor, next != accumulator.cursor else {
                    throw GitHubReadError.incompleteCoverage("Non-advancing search cursor")
                }
                accumulator.cursor = next
            }
            accumulator.hasNext = page.pageInfo.hasNextPage
        } while accumulator.hasNext
        return (Array(accumulator.nodesByID.values), accumulator.finalCount, false)
    }

    private func fetchSearchPage(
        query: String,
        cursor: String?
    ) async throws -> GitHubDiscoverySearchPayload {
        let data = try await read(
            GitHubPullRequestQueries.searchPage,
            [
                "query": .string(query),
                "cursor": cursor.map(GitHubQueryValue.string) ?? .null
            ]
        )
        let envelope = try decoder.decode(GitHubGraphQLPayload<SearchData>.self, from: data)
        try validate(errors: envelope.errors)
        guard let page = envelope.data?.search else { throw GitHubReadError.invalidPayload }
        return page
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
        attempt: Int = 0,
        to result: inout [Continuation]
    ) throws where Node: Decodable & Equatable & Sendable {
        guard connection.pageInfo.hasPreviousPage else {
            if let total = connection.totalCount, connection.nodes.count < total {
                throw GitHubReadError.incompleteCoverage("Connection omitted required items")
            }
            return
        }
        guard let cursor = connection.pageInfo.startCursor else { throw GitHubReadError.invalidPayload }
        result.append(Continuation(kind: kind, before: cursor, expectedTotal: connection.totalCount, attempt: attempt))
    }

    private func continuationQuery(_ batch: [Continuation]) -> String {
        let declarations = batch.indices.flatMap { index in
            ["$id\(index): ID!", "$cursor\(index): String"]
        }.joined(separator: ", ")
        let selections = batch.enumerated().map { index, continuation in
            "c\(index): node(id: $id\(index)) { \(continuationSelection(for: continuation.kind, cursor: "$cursor\(index)")) }"
        }.joined(separator: "\n")
        return "query ContinuePullRequestConnections(\(declarations)) {\n\(selections)\n}"
    }

    private func continuationSelection(for kind: ConnectionKind, cursor: String) -> String {
        let size = GitHubPullRequestQueries.continuationPageSize
        switch kind {
        case .comments:
            return "... on PullRequest { comments(last: \(size), before: \(cursor)) { \(GitHubPullRequestQueries.conversationCommentConnectionFields) } }"
        case .reviews:
            return "... on PullRequest { reviews(last: \(size), before: \(cursor)) { \(GitHubPullRequestQueries.fullReviewConnectionFields) } }"
        case .opinionatedReviews:
            return "... on PullRequest { latestOpinionatedReviews(last: \(size), before: \(cursor)) { \(GitHubPullRequestQueries.opinionatedReviewConnectionFields) } }"
        case .threads:
            return """
            ... on PullRequest { reviewThreads(last: \(size), before: \(cursor)) {
              totalCount \(GitHubPullRequestQueries.pageInfoFields)
              nodes { \(GitHubPullRequestQueries.reviewThreadNodeFields) }
            } }
            """
        case .assignees:
            return "... on PullRequest { assignees(last: \(size), before: \(cursor)) { totalCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage } nodes { id login avatarUrl(size: 64) } } }"
        case .reviewRequests:
            return """
            ... on PullRequest { reviewRequests(last: \(size), before: \(cursor)) {
              totalCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
              nodes { id requestedReviewer { __typename ... on User { id login } ... on Team { id slug organization { login } } } }
            } }
            """
        case .threadComments:
            return "... on PullRequestReviewThread { comments(last: \(size), before: \(cursor)) { \(GitHubPullRequestQueries.inlineCommentConnectionFields) } }"
        }
    }

    private func continuationVariables(_ batch: [Continuation]) -> [String: GitHubQueryValue] {
        var result: [String: GitHubQueryValue] = [:]
        for (index, continuation) in batch.enumerated() {
            result["id\(index)"] = .string(continuation.kind.parentID)
            result["cursor\(index)"] = continuation.before.map(GitHubQueryValue.string) ?? .null
        }
        return result
    }

    private func decodeContinuationPages(
        _ data: Data,
        batch: [Continuation],
        allowsScopedErrors: Bool
    ) throws -> (pages: [Int: ContinuationPage], failedIndices: Set<Int>) {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubReadError.invalidPayload
        }
        let errors = try decodeErrors(envelope["errors"])
        var failedIndices = Set<Int>()
        if !errors.isEmpty {
            guard allowsScopedErrors else {
                try validate(errors: errors)
                throw GitHubReadError.invalidPayload
            }
            for error in errors {
                guard let path = error.path,
                      let first = path.first,
                      case .field(let alias) = first,
                      alias.hasPrefix("c"),
                      let index = Int(alias.dropFirst()),
                      batch.indices.contains(index) else {
                    try validate(errors: errors)
                    throw GitHubReadError.invalidPayload
                }
                failedIndices.insert(index)
            }
        }
        guard let dataObject = envelope["data"] as? [String: Any] else {
            throw GitHubReadError.invalidPayload
        }
        var pages: [Int: ContinuationPage] = [:]
        for (index, continuation) in batch.enumerated() where !failedIndices.contains(index) {
            guard
                let node = dataObject["c\(index)"] as? [String: Any],
                let connection = node[continuation.kind.connectionName]
            else {
                throw GitHubReadError.invalidPayload
            }
            let connectionData = try JSONSerialization.data(withJSONObject: connection)
            switch continuation.kind {
            case .comments, .threadComments:
                pages[index] = .comments(try decoder.decode(GitHubStrictConnection<GitHubPayloadComment>.self, from: connectionData))
            case .reviews, .opinionatedReviews:
                pages[index] = .reviews(try decoder.decode(GitHubStrictConnection<GitHubPayloadReview>.self, from: connectionData))
            case .threads:
                pages[index] = .threads(try decoder.decode(GitHubStrictConnection<GitHubPayloadReviewThread>.self, from: connectionData))
            case .assignees:
                pages[index] = .users(try decoder.decode(GitHubStrictConnection<GitHubPayloadUser>.self, from: connectionData))
            case .reviewRequests:
                pages[index] = .requests(try decoder.decode(GitHubStrictConnection<GitHubPayloadReviewRequest>.self, from: connectionData))
            }
        }
        return (pages, failedIndices)
    }

    private func merge(
        page: ContinuationPage,
        for continuation: Continuation,
        into accumulators: inout [String: HydrationAccumulator],
        queue: inout [Continuation],
        restartedThreadPRs: inout Set<String>
    ) throws {
        let prID: String
        switch continuation.kind {
        case .comments(let id), .reviews(let id), .opinionatedReviews(let id), .threads(let id),
             .assignees(let id), .reviewRequests(let id), .threadComments(let id, _):
            prID = id
        }
        guard var accumulator = accumulators[prID] else { throw GitHubReadError.invalidPayload }
        if let expected = continuation.expectedTotal, let observed = page.totalCount, observed < expected {
            try retryIncompleteConnection(
                continuation,
                accumulator: &accumulator,
                queue: &queue,
                restartedThreadPRs: &restartedThreadPRs,
                message: "Connection total decreased during traversal"
            )
            accumulators[prID] = accumulator
            return
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
                    attempt: continuation.attempt,
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

        // A fresh re-read takes its expected total from its own newest page.
        let expectedTotal = continuation.before == nil ? page.totalCount : continuation.expectedTotal
        if page.pageInfo.hasPreviousPage {
            guard let cursor = page.pageInfo.startCursor else { throw GitHubReadError.invalidPayload }
            queue.append(Continuation(
                kind: continuation.kind,
                before: cursor,
                expectedTotal: expectedTotal,
                attempt: continuation.attempt
            ))
        } else if let expected = expectedTotal {
            let actual = accumulatedCount(for: continuation.kind, in: accumulator)
            if actual < expected {
                try retryIncompleteConnection(
                    continuation,
                    accumulator: &accumulator,
                    queue: &queue,
                    restartedThreadPRs: &restartedThreadPRs,
                    message: "Connection returned \(actual) of \(expected) items"
                )
            }
        }
        accumulators[prID] = accumulator
    }

    /// Retries a connection once by discarding everything read so far and re-reading it from its newest page,
    /// so items deleted since the first read cannot survive from cached pages.
    private func retryIncompleteConnection(
        _ continuation: Continuation,
        accumulator: inout HydrationAccumulator,
        queue: inout [Continuation],
        restartedThreadPRs: inout Set<String>,
        message: String
    ) throws {
        guard continuation.attempt == 0 else {
            throw GitHubReadError.incompleteCoverage(message)
        }
        switch continuation.kind {
        case .comments: accumulator.comments = [:]
        case .reviews: accumulator.reviews = [:]
        case .opinionatedReviews: accumulator.opinionatedReviews = [:]
        case .assignees: accumulator.assignees = [:]
        case .reviewRequests: accumulator.reviewRequests = [:]
        case .threadComments(_, let threadID): accumulator.threadComments[threadID] = [:]
        case .threads(let prID):
            // The re-read threads bring their own comments and thread-comment continuations.
            accumulator.threads = [:]
            accumulator.threadComments = [:]
            restartedThreadPRs.insert(prID)
            queue.removeAll { pending in
                guard case .threadComments(let pendingPR, _) = pending.kind else { return false }
                return pendingPR == prID
            }
        }
        queue.append(Continuation(kind: continuation.kind, before: nil, expectedTotal: nil, attempt: 1))
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
            try normalizeComment(comment, source: .pullRequest, threadID: nil, login: login)
        }
        let threadComments = try value.threadComments
            .filter { value.threads[$0.key] != nil }
            .flatMap { threadID, comments in
                try comments.values.map { comment in
                    try normalizeComment(comment, source: .reviewThread, threadID: threadID, login: login)
                }
            }
        let allComments = (topLevelComments + threadComments).reduce(into: [String: PullRequestCommentActivity]()) {
            $0[$1.id] = $1
        }.values.sorted { $0.createdAt < $1.createdAt }
        let reviews = try value.reviews.values.compactMap { review -> PullRequestReview? in
            let state: PullRequestReviewState?
            switch review.state.uppercased() {
            case "APPROVED": state = .approved
            case "CHANGES_REQUESTED": state = .changesRequested
            case "COMMENTED": state = .commented
            default: state = nil
            }
            guard let submittedAt = review.submittedAt, let state else { return nil }
            guard let bodyHTML = review.bodyHTML, let bodyText = review.bodyText, let updatedAt = review.updatedAt else {
                throw GitHubReadError.invalidPayload
            }
            return PullRequestReview(
                id: review.id,
                url: review.url,
                state: state,
                submittedAt: try parseDate(submittedAt),
                author: review.author?.login,
                authorIsBot: review.author?.isBot,
                viewerDidAuthor: review.viewerDidAuthor,
                updatedAt: try parseDate(updatedAt),
                hasSummaryText: !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                // A decision's summary belongs to the decision, so only comment-only summaries are classified.
                mentionsViewer: try state == .commented && mentions(login, in: bodyHTML)
            )
        }.sorted { $0.submittedAt < $1.submittedAt }
        let actionableThreads = value.threads.values.filter { thread in
            !thread.isResolved && thread.viewerCanResolve
                && (value.threadComments[thread.id]?.values.contains { !$0.viewerDidAuthor } ?? false)
        }.count
        let ciState: CIState = switch payload.statusCheckRollup?.state {
        case "SUCCESS": .passing
        case "FAILURE", "ERROR": .failing
        case "PENDING", "EXPECTED": .pending
        default: .unknown
        }
        let mergeable: MergeableState = switch payload.mergeable {
        case "MERGEABLE": .mergeable
        case "CONFLICTING": .conflicting
        default: .unknown
        }

        return PullRequest(
            id: payload.id,
            title: payload.title,
            number: payload.number,
            url: URL(string: payload.url)!,
            repo: payload.repository.nameWithOwner,
            repositoryIsArchived: payload.repository.isArchived,
            ciState: ciState,
            reviewDecision: normalizeReviewDecision(
                Array(value.opinionatedReviews.values),
                pullRequestAuthor: payload.author?.login,
                gitHubDecision: payload.reviewDecision
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
            requestedTeams: try requestedTeams(for: value),
            isAssignedToViewer: value.assignees.values.contains { $0.login.caseInsensitiveCompare(login) == .orderedSame },
            isMine: value.discovery.isAuthored || payload.author?.login.caseInsensitiveCompare(login) == .orderedSame,
            author: payload.author?.login ?? "unknown",
            authorAvatarURL: payload.author?.avatarUrl,
            headRefName: payload.headRefName,
            mergeable: mergeable,
            draft: payload.isDraft,
            createdAt: try parseDate(payload.createdAt),
            updatedAt: try parseDate(payload.updatedAt),
            stackID: payload.stack?.id
        )
    }

    /// An inline comment's state decides publication: a pending comment is unpublished whatever timestamp the
    /// provider sends. A published comment without a publication time counts as published at creation.
    private func normalizeComment(
        _ comment: GitHubPayloadComment,
        source: PullRequestCommentActivity.Source,
        threadID: String?,
        login: String
    ) throws -> PullRequestCommentActivity {
        guard let bodyHTML = comment.bodyHTML, let updatedAt = comment.updatedAt else {
            throw GitHubReadError.invalidPayload
        }
        let isPublished: Bool
        switch source {
        case .pullRequest:
            isPublished = true
        case .reviewThread:
            switch comment.state?.uppercased() {
            case "PENDING":
                isPublished = false
            case "SUBMITTED":
                isPublished = true
            default:
                throw GitHubReadError.invalidPayload
            }
        }
        let createdAt = try parseDate(comment.createdAt)
        return PullRequestCommentActivity(
            id: comment.id,
            url: comment.url,
            author: comment.author?.login,
            authorIsBot: comment.author?.isBot,
            viewerDidAuthor: comment.viewerDidAuthor,
            createdAt: createdAt,
            source: source,
            reviewId: source == .reviewThread ? comment.pullRequestReview?.id : nil,
            publishedAt: isPublished ? try comment.publishedAt.map(parseDate) ?? createdAt : nil,
            isPublished: isPublished,
            updatedAt: try parseDate(updatedAt),
            threadId: threadID,
            mentionsViewer: try mentions(login, in: bodyHTML)
        )
    }

    private func mentions(_ login: String, in bodyHTML: String) throws -> Bool {
        do {
            return try GitHubMentionParser.mentionsUser(login, inRenderedHTML: bodyHTML)
        } catch {
            throw GitHubReadError.invalidPayload
        }
    }

    private func normalizeReviewDecision(
        _ reviews: [GitHubPayloadReview],
        pullRequestAuthor: String?,
        gitHubDecision: String?
    ) -> ReviewDecision {
        var uncertain = false
        for review in reviews {
            let state = review.state.uppercased()
            if ["COMMENTED", "PENDING", "DISMISSED"].contains(state) { continue }
            guard let author = review.author?.login, let pullRequestAuthor else {
                uncertain = true
                continue
            }
            if author.caseInsensitiveCompare(pullRequestAuthor) == .orderedSame { continue }
            switch state {
            case "CHANGES_REQUESTED": return .changesRequested
            case "APPROVED": continue
            default: uncertain = true
            }
        }
        if uncertain { return .unknown }
        return gitHubDecision == "APPROVED" ? .approved : .reviewRequired
    }

    private func reviewRequestKind(for value: HydrationAccumulator, login: String) -> ReviewRequestKind {
        let direct = value.reviewRequests.values.contains { request in
            request.requestedReviewer?.typename == "User"
                && request.requestedReviewer?.login?.caseInsensitiveCompare(login) == .orderedSame
        }
        let team = value.discovery.isTeamRequested && value.reviewRequests.values.contains {
            $0.requestedReviewer?.typename == "Team"
        }
        return ReviewRequestKind(direct: direct, team: team)
    }

    private func requestedTeams(for value: HydrationAccumulator) throws -> [TeamReference] {
        let teams = try value.reviewRequests.values.compactMap { request -> TeamReference? in
            guard let reviewer = request.requestedReviewer, reviewer.typename == "Team" else { return nil }
            guard let id = reviewer.id, let slug = reviewer.slug, let organization = reviewer.organization else {
                throw GitHubReadError.invalidPayload
            }
            return TeamReference(id: id, organization: organization.login, slug: slug)
        }
        var seenIDs: Set<String> = []
        return teams
            .sorted { ($0.organization, $0.slug, $0.id) < ($1.organization, $1.slug, $1.id) }
            .filter { seenIDs.insert($0.id).inserted }
    }

    /// Reads every team the viewer belongs to in every org, plus each team's ancestors, which GitHub also
    /// treats as the viewer's teams for review requests.
    func fetchViewerTeams(login: String) async throws -> [ViewerTeam] {
        var directTeams: [(organization: String, organizationAvatarURL: URL?, team: GitHubPayloadViewerTeam)] = []
        var orgCursor: String?
        repeat {
            let page = try await readValidated(
                GitHubViewerTeamsPayload.self,
                query: GitHubPullRequestQueries.viewerTeams,
                variables: ["login": .string(login), "orgCursor": orgCursor.map(GitHubQueryValue.string) ?? .null]
            )
            let organizations = page.viewer.organizations
            for organization in organizations.nodes {
                var teams = organization.teams
                directTeams += teams.nodes.map { (organization.login, organization.avatarUrl, $0) }
                while teams.pageInfo.hasNextPage {
                    guard let cursor = teams.pageInfo.endCursor else { throw GitHubReadError.invalidPayload }
                    teams = try await readValidated(
                        GitHubOrganizationViewerTeamsPayload.self,
                        query: GitHubPullRequestQueries.organizationViewerTeams,
                        variables: [
                            "org": .string(organization.login),
                            "login": .string(login),
                            "cursor": .string(cursor)
                        ]
                    ).organization.teams
                    directTeams += teams.nodes.map { (organization.login, organization.avatarUrl, $0) }
                }
            }
            guard organizations.pageInfo.hasNextPage else { break }
            guard let cursor = organizations.pageInfo.endCursor else { throw GitHubReadError.invalidPayload }
            orgCursor = cursor
        } while true

        var teamsByID: [String: ViewerTeam] = [:]
        for direct in directTeams {
            let organization = direct.organization
            guard !direct.team.ancestors.pageInfo.hasNextPage else {
                throw GitHubReadError.incompleteCoverage(
                    "More than \(GitHubPullRequestQueries.teamAncestorsPageSize) ancestors of team @\(organization)/\(direct.team.slug)"
                )
            }
            let identities = [GitHubPayloadTeamIdentity(
                id: direct.team.id,
                slug: direct.team.slug,
                avatarUrl: direct.team.avatarUrl,
                parentTeam: direct.team.parentTeam
            )] + direct.team.ancestors.nodes
            for identity in identities {
                teamsByID[identity.id] = ViewerTeam(
                    team: TeamReference(id: identity.id, organization: organization, slug: identity.slug),
                    parentTeamID: identity.parentTeam?.id,
                    avatarURL: identity.avatarUrl,
                    organizationAvatarURL: direct.organizationAvatarURL
                )
            }
        }
        return teamsByID.values.sorted {
            ($0.team.organization, $0.team.slug, $0.team.id) < ($1.team.organization, $1.team.slug, $1.team.id)
        }
    }

    /// Reads each stack once with every page of its entries. A stack that went away since hydration is dropped,
    /// so its PRs keep standalone cards.
    func fetchStacks(ids: [String]) async throws -> [PullRequestStack] {
        var stacks: [PullRequestStack] = []
        for start in stride(from: 0, to: ids.count, by: GitHubPullRequestQueries.stackBatchSize) {
            let chunk = Array(ids[start..<min(start + GitHubPullRequestQueries.stackBatchSize, ids.count)])
            let data = try await read(GitHubPullRequestQueries.pullRequestStacks, ["ids": .strings(chunk)])
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GitHubReadError.invalidPayload
            }
            let errors = try decodeErrors(object["errors"])
            guard let dataObject = object["data"] as? [String: Any],
                  let nodes = dataObject["nodes"] as? [Any],
                  nodes.count == chunk.count else {
                try validate(errors: errors)
                throw GitHubReadError.invalidPayload
            }
            var goneIndices = Set<Int>()
            let remainingErrors = Self.withoutUnreadableEntryErrors(errors, data: dataObject).filter { error in
                guard error.type?.uppercased() == "NOT_FOUND",
                      let path = error.path, path.count == 2, path[0] == .field("nodes"),
                      case .index(let index) = path[1],
                      nodes.indices.contains(index), nodes[index] is NSNull else { return true }
                goneIndices.insert(index)
                return false
            }
            try validate(errors: remainingErrors)
            for (index, node) in nodes.enumerated() {
                if node is NSNull {
                    guard goneIndices.contains(index) else { throw GitHubReadError.invalidPayload }
                    continue
                }
                guard let payload = try? decoder.decode(
                    GitHubPayloadStack.self,
                    from: JSONSerialization.data(withJSONObject: node)
                ), payload.id == chunk[index] else { throw GitHubReadError.invalidPayload }
                stacks.append(try await completeStack(payload))
            }
        }
        return stacks
    }

    /// GitHub reports an entry whose PR the viewer can't read (deleted or inaccessible) as a null `pullRequest`
    /// with a NOT_FOUND or FORBIDDEN error at that entry. Such an entry is skipped like any entry without a PR;
    /// every other error still fails the read.
    private static func withoutUnreadableEntryErrors(
        _ errors: [GitHubGraphQLErrorPayload],
        data: Any?
    ) -> [GitHubGraphQLErrorPayload] {
        errors.filter { error in
            guard ["NOT_FOUND", "FORBIDDEN"].contains(error.type?.uppercased() ?? ""),
                  let path = error.path else { return true }
            let entrySuffix = Array(path.suffix(4))
            let prefix = Array(path.dropLast(4))
            guard entrySuffix.count == 4,
                  entrySuffix[0] == .field("entries"), entrySuffix[1] == .field("nodes"),
                  case .index = entrySuffix[2], entrySuffix[3] == .field("pullRequest") else { return true }
            let isStackPrefix: Bool = switch prefix.count {
            case 1: prefix[0] == .field("node")
            case 2: prefix[0] == .field("nodes") && { if case .index = prefix[1] { true } else { false } }()
            default: false
            }
            guard isStackPrefix else { return true }
            return !(value(at: path, in: data) is NSNull)
        }
    }

    private static func value(at path: [GitHubGraphQLPathComponent], in root: Any?) -> Any? {
        path.reduce(root) { current, component in
            switch component {
            case .field(let name):
                (current as? [String: Any])?[name]
            case .index(let index):
                (current as? [Any]).flatMap { $0.indices.contains(index) ? $0[index] : nil }
            }
        }
    }

    private func completeStack(_ payload: GitHubPayloadStack) async throws -> PullRequestStack {
        var connection = payload.entries
        var rawEntries = connection.nodes
        var seenCursors = Set<String>()
        while connection.pageInfo.hasNextPage {
            guard let cursor = connection.pageInfo.endCursor else { throw GitHubReadError.invalidPayload }
            guard seenCursors.insert(cursor).inserted else {
                throw GitHubReadError.incompleteCoverage("Repeated stack entries cursor")
            }
            let data = try await read(
                GitHubPullRequestQueries.pullRequestStackEntries,
                ["id": .string(payload.id), "cursor": .string(cursor)]
            )
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GitHubReadError.invalidPayload
            }
            try validate(errors: Self.withoutUnreadableEntryErrors(
                try decodeErrors(object["errors"]),
                data: object["data"]
            ))
            guard let page = try? decoder.decode(GitHubGraphQLPayload<GitHubStackEntriesPayload>.self, from: data).data,
                  let node = page.node else { throw GitHubReadError.invalidPayload }
            connection = node.entries
            rawEntries += connection.nodes
        }
        guard rawEntries.count == payload.entries.totalCount else {
            throw GitHubReadError.incompleteCoverage("Incomplete entries of stack \(payload.id)")
        }
        return PullRequestStack(
            id: payload.id,
            size: payload.size,
            entries: try rawEntries.compactMap { entry in
                guard let pullRequest = entry.pullRequest else { return nil }
                let state: PullRequestStackEntry.State = switch pullRequest.state {
                case "OPEN": .open
                case "MERGED": .merged
                case "CLOSED": .closed
                default: throw GitHubReadError.invalidPayload
                }
                return PullRequestStackEntry(
                    position: entry.position,
                    pullRequestID: pullRequest.id,
                    number: pullRequest.number,
                    title: pullRequest.title,
                    url: pullRequest.url,
                    state: state,
                    isDraft: pullRequest.isDraft,
                    author: pullRequest.author?.login ?? "unknown",
                    authorAvatarURL: pullRequest.author?.avatarUrl
                )
            }
        )
    }

    private func readValidated<Payload: Decodable>(
        _ type: Payload.Type,
        query: String,
        variables: [String: GitHubQueryValue]
    ) async throws -> Payload {
        let data = try await read(query, variables)
        try validate(errors: try decoder.decode(GitHubGraphQLErrorEnvelope.self, from: data).errors)
        guard let payload = try? decoder.decode(GitHubGraphQLPayload<Payload>.self, from: data).data else {
            throw GitHubReadError.invalidPayload
        }
        return payload
    }

    private struct LeafResult {
        let interval: ClosedRange<Int>
        let nodes: [GitHubDiscoveryNode]
    }

    private func discoverLane(
        _ lane: GitHubDiscoveryLane,
        login: String,
        bounds: Bounds,
        splitsInitialInterval: Bool
    ) async throws -> [LeafResult] {
        func split(_ interval: ClosedRange<Int>) throws -> [ClosedRange<Int>] {
            guard interval.lowerBound < interval.upperBound else {
                throw GitHubReadError.incompleteCoverage("More than 1,000 \(lane.rawValue) PRs share one creation second")
            }
            let midpoint = interval.lowerBound + (interval.upperBound - interval.lowerBound) / 2
            return [(midpoint + 1)...interval.upperBound, interval.lowerBound...midpoint]
        }
        let initial = bounds.lower...bounds.upper
        var queue = splitsInitialInterval ? try split(initial) : [initial]
        var complete: [LeafResult] = []
        while let interval = queue.popLast() {
            let pageResult = try await fetchLeaf(lane, login: login, interval: interval, laneUpper: bounds.upper)
            if pageResult.exceededCap {
                queue.append(contentsOf: try split(interval))
                continue
            }
            if pageResult.nodes.count < pageResult.finalCount {
                let retry = try await fetchLeaf(lane, login: login, interval: interval, laneUpper: bounds.upper)
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
        laneUpper: Int,
        initialPage: GitHubDiscoverySearchPayload? = nil
    ) async throws -> (nodes: [GitHubDiscoveryNode], finalCount: Int, exceededCap: Bool) {
        try await fetchSearchLeaf(
            query: "\(baseQuery(for: lane, login: login)) \(createdQualifier(interval, laneUpper: laneUpper))",
            initialPage: initialPage
        )
    }

    /// The interval reaching the lane's newest bound stays open-ended so PRs created after the bounds query are included.
    private func createdQualifier(_ interval: ClosedRange<Int>, laneUpper: Int?) -> String {
        if let laneUpper, interval.upperBound >= laneUpper {
            return "created:>=\(formatSecond(interval.lowerBound))"
        }
        return "created:\(formatSecond(interval.lowerBound))..\(formatSecond(interval.upperBound))"
    }

    private func discoveryVariables(
        login: String,
        bounds: [GitHubDiscoveryLane: Bounds]
    ) -> [String: GitHubQueryValue] {
        var result: [String: GitHubQueryValue] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            let base = baseQuery(for: lane, login: login)
            if let bounds = bounds[lane] {
                result["\(lane.rawValue)Query"] = .string(
                    "\(base) \(createdQualifier(bounds.lower...bounds.upper, laneUpper: bounds.upper))"
                )
            } else {
                result["\(lane.rawValue)Query"] = .string(base)
            }
            result["\(lane.rawValue)Cursor"] = .null
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
        if errors.contains(where: { error in
            ["UNAUTHORIZED", "UNAUTHENTICATED"].contains(error.type?.uppercased() ?? "")
        }) {
            throw GitHubReadError.authentication
        }
        if errors.contains(where: { $0.type?.uppercased() == "FORBIDDEN" }) {
            throw GitHubReadError.accessDenied
        }
        if errors.contains(where: { $0.type?.uppercased() == "RATE_LIMITED" }) {
            throw GitHubReadError.rateLimited(retryAt: nil)
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
