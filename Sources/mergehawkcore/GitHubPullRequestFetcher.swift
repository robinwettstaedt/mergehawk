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

/// The GraphQL part of a complete PR refresh: viewer teams, discovery and every hydrated PR.
struct GitHubRefreshRead: Equatable, Sendable {
    /// The reused teams when the refresh was given them.
    let viewerTeams: [ViewerTeam]
    let discovery: GitHubDiscoveryResult
    /// Discovered PRs in discovery order, then known PRs discovery no longer finds in their given order.
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

    /// One position of a hydration batch after its retries, before it is stored.
    private enum HydrationOutcome: Sendable {
        case node(GitHubCompletePullRequestPayload)
        /// A null node without errors, or with only NOT_FOUND at it.
        case missing
        /// A node GitHub refuses, with only NOT_FOUND or FORBIDDEN at it.
        case refused([GitHubGraphQLErrorPayload])
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
            // Threads are recorded with `recordThread` as their reads queue first comment reads.
            threads = [:]
            threadComments = [:]
            assignees = Dictionary(uniqueKeysWithValues: payload.assignees.nodes.map { ($0.id ?? $0.login, $0) })
            reviewRequests = Dictionary(uniqueKeysWithValues: payload.reviewRequests.nodes.map { ($0.id, $0) })
        }

        /// Stores a thread from the PR read or a thread page. A later page's copy replaces a stored one.
        /// Returns whether the thread was new.
        mutating func recordThread(_ thread: GitHubPayloadReviewThread) -> Bool {
            threads.updateValue(thread, forKey: thread.id) == nil
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

    private let transport: Read
    private let decoder: JSONDecoder
    private let limiter: GitHubReadLimiter
    private var priority: GitHubReadPriority = .bulk

    /// `limiter` caps and stops every read this fetcher and its copies send. One limiter serves one refresh.
    init(read: @escaping Read, decoder: JSONDecoder = JSONDecoder(), limiter: GitHubReadLimiter = GitHubReadLimiter()) {
        self.transport = read
        self.decoder = decoder
        self.limiter = limiter
    }

    /// A copy whose reads wait in `priority`'s queue, sharing this fetcher's limiter, transport and decoder.
    func withPriority(_ priority: GitHubReadPriority) -> GitHubPullRequestFetcher {
        var copy = self
        copy.priority = priority
        return copy
    }

    /// Sends one read under a limiter permit and decodes and checks its response inside the permit, so a
    /// failed response stops the limiter before the permit frees.
    private func read<T: Sendable>(
        _ query: String,
        _ variables: [String: GitHubQueryValue],
        decode: (Data) throws -> T
    ) async throws -> T {
        try await limiter.withPermit(priority) {
            try decode(try await transport(query, variables))
        }
    }

    func discover(login: String) async throws -> GitHubDiscoveryResult {
        let bounds = try await fetchBounds(login: login)
        var identities: [String: DiscoveredPullRequest] = [:]
        var coverage: [GitHubDiscoveryLane: [ClosedRange<Int>]] = [:]
        let initial = try await read(
            GitHubPullRequestQueries.discoveryPage,
            discoveryVariables(login: login, bounds: bounds)
        ) { data in
            let payload = try decoder.decode(GitHubGraphQLPayload<DiscoveryData>.self, from: data)
            try validate(errors: payload.errors)
            guard let initial = payload.data else { throw GitHubReadError.invalidPayload }
            return initial
        }

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

    /// Hydrates every PR in `discovered`. A missing or refused PR fails the read.
    func hydrate(
        _ discovered: [DiscoveredPullRequest],
        login: String
    ) async throws -> [GitHubHydratedPullRequest] {
        try await unwrappingRecordedFailure {
            try await hydrateRecorded(discovered, login: login)
        }
    }

    private func hydrateRecorded(
        _ discovered: [DiscoveredPullRequest],
        login: String
    ) async throws -> [GitHubHydratedPullRequest] {
        var accumulators: [String: HydrationAccumulator] = [:]
        var continuations: [Continuation] = []
        var missingIDs = Set<String>()

        let chunks = Self.hydrationChunks(discovered)
        let outcomes = try await runConcurrently(chunks.enumerated().map { index, chunk in
            (GitHubReadOrder(.knownHydration, index), { @Sendable [self] in
                try await readHydrationBatch(chunk.map(\.id), mayBeRefused: false)
            })
        })
        try applyHydrationOutcomes(
            outcomes,
            chunks: chunks,
            into: &accumulators,
            queue: &continuations,
            missing: &missingIDs
        )

        try await runContinuationRounds(&accumulators, queue: continuations)
        // A missing PR has no accumulator, so it fails here.
        return try finishHydration(accumulators, order: discovered.map(\.id), missing: [], login: login)
    }

    /// Reads a complete PR refresh's GraphQL data. Discovery, the viewer teams read (unless `reusableViewerTeams`
    /// is given) and hydration of the `known` PRs run together, and newly discovered PRs hydrate as soon as
    /// discovery ends. Discovery results then apply to every hydrated PR in a fixed order, and continuation reads
    /// every hydrated PR's remaining pages.
    ///
    /// A PR discovery found takes its identity from discovery. A known PR discovery no longer finds keeps its
    /// `known` identity, and only for it does a refused node count as missing.
    func readRefresh(
        login: String,
        known: [DiscoveredPullRequest],
        reusableViewerTeams: [ViewerTeam]?
    ) async throws -> GitHubRefreshRead {
        try await unwrappingRecordedFailure {
            try await readRefreshRecorded(login: login, known: known, reusableViewerTeams: reusableViewerTeams)
        }
    }

    private enum RefreshJobResult: Sendable {
        case teams([ViewerTeam])
        case discovery(GitHubDiscoveryResult, newBatches: [[HydrationOutcome]])
        case hydration([HydrationOutcome])
    }

    private func readRefreshRecorded(
        login: String,
        known: [DiscoveredPullRequest],
        reusableViewerTeams: [ViewerTeam]?
    ) async throws -> GitHubRefreshRead {
        let knownIDs = Set(known.map(\.id))
        let knownChunks = Self.hydrationChunks(known)
        let chain = withPriority(.chain)

        // Phases 1 and 2.
        var jobs: [(GitHubReadOrder, @Sendable () async throws -> RefreshJobResult)] = []
        if reusableViewerTeams == nil {
            jobs.append((GitHubReadOrder(.viewerTeams), {
                .teams(try await chain.fetchViewerTeams(login: login))
            }))
        }
        jobs.append((GitHubReadOrder(.discovery), { [self] in
            let discovery = try await chain.discover(login: login)
            let newChunks = Self.hydrationChunks(discovery.pullRequests.filter { !knownIDs.contains($0.id) })
            let newBatches = try await runConcurrently(newChunks.enumerated().map { index, chunk in
                (GitHubReadOrder(.newHydration, index), { @Sendable [self] in
                    try await readHydrationBatch(chunk.map(\.id), mayBeRefused: false)
                })
            })
            return .discovery(discovery, newBatches: newBatches)
        }))
        for (index, chunk) in knownChunks.enumerated() {
            jobs.append((GitHubReadOrder(.knownHydration, index), { [self] in
                .hydration(try await readHydrationBatch(chunk.map(\.id), mayBeRefused: true))
            }))
        }
        var viewerTeams = reusableViewerTeams ?? []
        var discovery: GitHubDiscoveryResult?
        var newBatches: [[HydrationOutcome]] = []
        var knownBatches: [[HydrationOutcome]] = []
        for result in try await runConcurrently(jobs) {
            switch result {
            case .teams(let teams): viewerTeams = teams
            case .discovery(let value, let batches):
                discovery = value
                newBatches = batches
            case .hydration(let batch): knownBatches.append(batch)
            }
        }
        guard let discovery else { throw GitHubReadError.invalidPayload }

        // Phase 3: known batches by index, then new batches by index, positions in order.
        let discoveredByID = Dictionary(uniqueKeysWithValues: discovery.pullRequests.map { ($0.id, $0) })
        let newChunks = Self.hydrationChunks(discovery.pullRequests.filter { !knownIDs.contains($0.id) })
        var accumulators: [String: HydrationAccumulator] = [:]
        var continuations: [Continuation] = []
        var missingIDs = Set<String>()
        for (chunk, batch) in zip(knownChunks + newChunks, knownBatches + newBatches) {
            for (knownIdentity, outcome) in zip(chunk, batch) {
                let found = discoveredByID[knownIdentity.id]
                switch outcome {
                case .node(let node):
                    try storeHydrationNode(
                        node,
                        identity: found ?? knownIdentity,
                        accumulators: &accumulators,
                        continuations: &continuations
                    )
                case .missing:
                    missingIDs.insert(knownIdentity.id)
                case .refused(let errors):
                    // Lost access is expected only for a PR that dropped out of search.
                    guard found == nil else {
                        try validate(errors: errors)
                        throw GitHubReadError.invalidPayload
                    }
                    missingIDs.insert(knownIdentity.id)
                }
            }
        }

        // Phase 4.
        try await runContinuationRounds(&accumulators, queue: continuations)
        let order = discovery.pullRequests.map(\.id) + known.map(\.id).filter { discoveredByID[$0] == nil }
        return GitHubRefreshRead(
            viewerTeams: viewerTeams,
            discovery: discovery,
            pullRequests: try finishHydration(accumulators, order: order, missing: missingIDs, login: login),
            missingPullRequestIDs: missingIDs
        )
    }

    /// Checks that every listed thread had its comments read, then normalizes the hydrated PRs in `order`. Every
    /// PR in `order` must be hydrated or missing.
    private func finishHydration(
        _ accumulators: [String: HydrationAccumulator],
        order: [String],
        missing: Set<String>,
        login: String
    ) throws -> [GitHubHydratedPullRequest] {
        // Every listed thread must have had its comments read, or it would publish without its activity.
        for prID in accumulators.keys.sorted() {
            let accumulator = accumulators[prID]!
            if let threadID = accumulator.threads.keys.sorted().first(where: { accumulator.threadComments[$0] == nil }) {
                throw GitHubReadError.incompleteCoverage("Thread \(threadID) comments were not read")
            }
        }
        return try order.compactMap { id -> GitHubHydratedPullRequest? in
            guard let accumulator = accumulators[id] else {
                guard missing.contains(id) else { throw GitHubReadError.invalidPayload }
                return nil
            }
            return GitHubHydratedPullRequest(
                pullRequest: try normalize(accumulator, login: login),
                providerState: accumulator.payload.state,
                discovery: accumulator.discovery,
                hasTeamReviewRequest: accumulator.reviewRequests.values.contains {
                    $0.requestedReviewer?.typename == "Team"
                }
            )
        }
    }

    /// Reads every queued continuation in rounds of up to `continuationRoundWidth` batches sent together. A round
    /// behaves like one larger batch: its cursors are checked before any read is sent, its pages merge in batch
    /// order, then position order, and its failed entries retry after all its pages merged. Entries a round's
    /// merge queues run in a later round.
    private func runContinuationRounds(
        _ accumulators: inout [String: HydrationAccumulator],
        queue initial: [Continuation]
    ) async throws {
        var queue = initial
        var visitedCursors: [ContinuationVisit: Set<String?>] = [:]
        while !queue.isEmpty {
            var batches: [[Continuation]] = []
            while batches.count < GitHubPullRequestQueries.continuationRoundWidth, !queue.isEmpty {
                batches.append(nextContinuationBatch(from: &queue))
            }
            let entries = batches.flatMap { $0 }
            // At most one live entry per connection is queued or in flight.
            assert(Set(entries.map(\.kind)).count == entries.count, "Two continuation entries share a connection")
            for item in entries {
                let visit = ContinuationVisit(kind: item.kind, attempt: item.attempt)
                guard visitedCursors[visit, default: []].insert(item.before).inserted else {
                    throw GitHubReadError.incompleteCoverage("Repeated continuation cursor")
                }
            }
            let decodedBatches = try await runConcurrently(batches.enumerated().map { index, batch in
                (GitHubReadOrder(.continuation, index), { @Sendable [self] in
                    try await read(continuationQuery(batch), continuationVariables(batch)) { data in
                        try decodeContinuationPages(data, batch: batch, allowsScopedErrors: true)
                    }
                })
            })
            // Thread-comment results for a PR whose thread list restarts in this round belong to the discarded read.
            var restartedThreadPRs = Set<String>()
            func isSuperseded(_ item: Continuation) -> Bool {
                guard case .threadComments(let prID, _) = item.kind else { return false }
                return restartedThreadPRs.contains(prID)
            }
            for (batch, decoded) in zip(batches, decodedBatches) {
                for (index, page) in decoded.pages.sorted(by: { $0.key < $1.key }) where !isSuperseded(batch[index]) {
                    try merge(
                        page: page,
                        for: batch[index],
                        into: &accumulators,
                        queue: &queue,
                        restartedThreadPRs: &restartedThreadPRs
                    )
                }
            }
            for (batch, decoded) in zip(batches, decodedBatches) {
                for index in decoded.failedIndices.sorted() where !isSuperseded(batch[index]) {
                    let item = batch[index]
                    // A missing thread's retry also reads its PR, to tell a deleted thread from lost access.
                    let confirmingPRID: String? = if decoded.missingThreadIndices.contains(index),
                        case .threadComments(let prID, _) = item.kind { prID } else { nil }
                    let retried = try await read(
                        continuationQuery([item], pullRequestID: confirmingPRID),
                        continuationVariables([item], pullRequestID: confirmingPRID)
                    ) { data -> ContinuationPage? in
                        if confirmingPRID != nil, try isDeletedThreadOfReadablePullRequest(data) { return nil }
                        let retry = try decodeContinuationPages(data, batch: [item], allowsScopedErrors: false)
                        guard let page = retry.pages[0], retry.failedIndices.isEmpty else {
                            throw GitHubReadError.invalidPayload
                        }
                        return page
                    }
                    guard let page = retried else {
                        guard case .threadComments(let prID, let threadID) = item.kind else {
                            throw GitHubReadError.invalidPayload
                        }
                        accumulators[prID]?.threads.removeValue(forKey: threadID)
                        accumulators[prID]?.threadComments.removeValue(forKey: threadID)
                        queue.removeAll { $0.kind == item.kind }
                        // A later thread page may list the thread again, and its reads then start fresh.
                        visitedCursors = visitedCursors.filter { $0.key.kind != item.kind }
                        continue
                    }
                    try merge(
                        page: page,
                        for: item,
                        into: &accumulators,
                        queue: &queue,
                        restartedThreadPRs: &restartedThreadPRs
                    )
                }
            }
            // A restarted thread list re-reads every thread's comments from scratch, at cursors that may have
            // run before. The re-reads always run in later rounds.
            if !restartedThreadPRs.isEmpty {
                visitedCursors = visitedCursors.filter { visit, _ in
                    guard case .threadComments(let prID, _) = visit.kind else { return true }
                    return !restartedThreadPRs.contains(prID)
                }
            }
        }
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

    /// Runs `jobs` concurrently and returns their results in job order. A failing job records its error at its
    /// order in the limiter, which stops the refresh's other reads. The call then throws the limiter's chosen
    /// failure, which may come from a nested call sharing the limiter, wrapped as `RecordedReadFailure`.
    private func runConcurrently<T: Sendable>(
        _ jobs: [(GitHubReadOrder, @Sendable () async throws -> T)]
    ) async throws -> [T] {
        let results = await withTaskGroup(of: (Int, T?).self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask { [limiter] in
                    do {
                        return (index, try await job.1())
                    } catch is RecordedReadFailure {
                        // A nested call's failures are already recorded at their own order.
                        limiter.stop()
                        return (index, nil)
                    } catch {
                        limiter.fail(error, at: job.0)
                        return (index, nil)
                    }
                }
            }
            var results = [T?](repeating: nil, count: jobs.count)
            for await (index, value) in group {
                results[index] = value
            }
            return results
        }
        if let failure = limiter.failure() { throw RecordedReadFailure(error: failure) }
        return results.map { $0! }
    }

    /// The failure `runConcurrently` chose, already recorded in the limiter.
    private struct RecordedReadFailure: Error {
        let error: Error
    }

    /// Entry points that run reads concurrently throw the recorded failure itself.
    private func unwrappingRecordedFailure<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as RecordedReadFailure {
            throw failure.error
        }
    }

    private static func hydrationChunks(_ identities: [DiscoveredPullRequest]) -> [[DiscoveredPullRequest]] {
        stride(from: 0, to: identities.count, by: GitHubPullRequestQueries.hydrationBatchSize).map { start in
            Array(identities[start..<min(start + GitHubPullRequestQueries.hydrationBatchSize, identities.count)])
        }
    }

    /// Reads one hydration batch, then in index order the single-node retries of nodes with errors at their path.
    /// It checks every node it returns but touches no shared state. `mayBeRefused` reports a retry whose node
    /// GitHub refuses (only NOT_FOUND or FORBIDDEN at it, at least one FORBIDDEN) as `.refused`; otherwise that
    /// refusal throws at once.
    private func readHydrationBatch(_ ids: [String], mayBeRefused: Bool) async throws -> [HydrationOutcome] {
        let batch = try await read(GitHubPullRequestQueries.hydration, ["ids": .strings(ids)]) { data in
            let raw = try rawHydrationResponse(data, expectedCount: ids.count)
            var failedIndices = Set<Int>()
            for error in raw.errors {
                guard let path = error.path,
                      path.count >= 2,
                      path[0] == .field("nodes"),
                      case .index(let index) = path[1],
                      ids.indices.contains(index) else {
                    try validate(errors: raw.errors)
                    throw GitHubReadError.invalidPayload
                }
                failedIndices.insert(index)
            }
            return try raw.nodes.enumerated().map { index, rawNode -> HydrationOutcome? in
                if failedIndices.contains(index) { return nil }
                guard let node = try decodeHydrationNode(rawNode) else { return .missing }
                return .node(try checkedHydrationNode(node, id: ids[index]))
            }
        }
        var outcomes: [HydrationOutcome] = []
        for (index, outcome) in batch.enumerated() {
            if let outcome {
                outcomes.append(outcome)
                continue
            }
            outcomes.append(try await read(
                GitHubPullRequestQueries.hydration,
                ["ids": .strings([ids[index]])]
            ) { data -> HydrationOutcome in
                let retry = try rawHydrationResponse(data, expectedCount: 1)
                if retry.nodes[0] is NSNull, !retry.errors.isEmpty,
                   retry.errors.allSatisfy({ $0.path == [.field("nodes"), .index(0)] }) {
                    let types = Set(retry.errors.map { $0.type?.uppercased() ?? "" })
                    if types == ["NOT_FOUND"] { return .missing }
                    if mayBeRefused, types.isSubset(of: ["NOT_FOUND", "FORBIDDEN"]) { return .refused(retry.errors) }
                }
                try validate(errors: retry.errors)
                guard let node = try decodeHydrationNode(retry.nodes[0]) else { return .missing }
                return .node(try checkedHydrationNode(node, id: ids[index]))
            })
        }
        return outcomes
    }

    /// The node's ID and the completeness of its connections, checked where the node is read.
    private func checkedHydrationNode(
        _ node: GitHubCompletePullRequestPayload,
        id: String
    ) throws -> GitHubCompletePullRequestPayload {
        guard node.id == id else { throw GitHubReadError.invalidPayload }
        _ = try Self.olderPageCursor(of: node.comments)
        _ = try Self.olderPageCursor(of: node.reviews)
        _ = try Self.olderPageCursor(of: node.latestOpinionatedReviews)
        _ = try Self.olderPageCursor(of: node.reviewThreads)
        _ = try Self.olderPageCursor(of: node.assignees)
        _ = try Self.olderPageCursor(of: node.reviewRequests)
        return node
    }

    /// Stores hydration outcomes in batch order, then position order, with the identity each chunk supplies.
    private func applyHydrationOutcomes(
        _ outcomes: [[HydrationOutcome]],
        chunks: [[DiscoveredPullRequest]],
        into accumulators: inout [String: HydrationAccumulator],
        queue continuations: inout [Continuation],
        missing missingIDs: inout Set<String>
    ) throws {
        for (chunk, batch) in zip(chunks, outcomes) {
            for (identity, outcome) in zip(chunk, batch) {
                switch outcome {
                case .node(let node):
                    try storeHydrationNode(node, identity: identity, accumulators: &accumulators, continuations: &continuations)
                case .missing, .refused:
                    missingIDs.insert(identity.id)
                }
            }
        }
    }

    private func storeHydrationNode(
        _ node: GitHubCompletePullRequestPayload,
        identity: DiscoveredPullRequest,
        accumulators: inout [String: HydrationAccumulator],
        continuations: inout [Continuation]
    ) throws {
        guard accumulators[node.id] == nil else {
            throw GitHubReadError.incompleteCoverage("Duplicate hydration node \(node.id)")
        }
        var accumulator = HydrationAccumulator(payload: node, discovery: identity)
        continuations.append(contentsOf: try initialContinuations(for: node, accumulator: &accumulator))
        accumulators[node.id] = accumulator
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
        try await read(
            GitHubPullRequestQueries.searchPage,
            [
                "query": .string(query),
                "cursor": cursor.map(GitHubQueryValue.string) ?? .null
            ]
        ) { data in
            let envelope = try decoder.decode(GitHubGraphQLPayload<SearchData>.self, from: data)
            try validate(errors: envelope.errors)
            guard let page = envelope.data?.search else { throw GitHubReadError.invalidPayload }
            return page
        }
    }

    private func fetchBounds(login: String) async throws -> [GitHubDiscoveryLane: Bounds] {
        var variables: [String: GitHubQueryValue] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            let base = baseQuery(for: lane, login: login)
            variables["\(lane.rawValue)Oldest"] = .string("\(base) sort:created-asc")
            variables["\(lane.rawValue)Newest"] = .string("\(base) sort:created-desc")
        }
        return try await read(GitHubPullRequestQueries.discoveryBounds, variables) { data in
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

    private func initialContinuations(
        for payload: GitHubCompletePullRequestPayload,
        accumulator: inout HydrationAccumulator
    ) throws -> [Continuation] {
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
            queueFirstCommentRead(of: thread, prID: payload.id, attempt: 0, accumulator: &accumulator, queue: &result)
        }
        return result
    }

    /// Records a listed thread and, when it is new to the PR's hydration state, queues its first comment read.
    /// A thread repeated on the boundary between two thread pages is already recorded and queues nothing.
    private func queueFirstCommentRead(
        of thread: GitHubPayloadReviewThread,
        prID: String,
        attempt: Int,
        accumulator: inout HydrationAccumulator,
        queue: inout [Continuation]
    ) {
        guard accumulator.recordThread(thread) else { return }
        queue.append(Continuation(
            kind: .threadComments(prID: prID, threadID: thread.id),
            before: nil,
            expectedTotal: nil,
            attempt: attempt
        ))
    }

    private static func isFirstCommentRead(_ continuation: Continuation) -> Bool {
        guard case .threadComments = continuation.kind else { return false }
        return continuation.before == nil
    }

    /// Takes the next batch from one group only: thread-comment reads without a cursor, up to
    /// `threadCommentFirstReadBatchSize` from anywhere in the queue, or up to `continuationBatchSize` other
    /// entries. The group of the oldest queued entry goes next. Remaining entries keep their order.
    private func nextContinuationBatch(from queue: inout [Continuation]) -> [Continuation] {
        guard let oldest = queue.first else { return [] }
        let takesFirstReads = Self.isFirstCommentRead(oldest)
        let limit = takesFirstReads
            ? GitHubPullRequestQueries.threadCommentFirstReadBatchSize
            : GitHubPullRequestQueries.continuationBatchSize
        var batch: [Continuation] = []
        var remaining: [Continuation] = []
        for item in queue {
            if batch.count < limit, Self.isFirstCommentRead(item) == takesFirstReads {
                batch.append(item)
            } else {
                remaining.append(item)
            }
        }
        queue = remaining
        return batch
    }

    private func appendContinuation<Node>(
        kind: ConnectionKind,
        connection: GitHubStrictConnection<Node>,
        attempt: Int = 0,
        to result: inout [Continuation]
    ) throws where Node: Decodable & Equatable & Sendable {
        guard let cursor = try Self.olderPageCursor(of: connection) else { return }
        result.append(Continuation(kind: kind, before: cursor, expectedTotal: connection.totalCount, attempt: attempt))
    }

    /// The cursor of a connection's older page, or nil when the page holds all its items.
    private static func olderPageCursor<Node>(
        of connection: GitHubStrictConnection<Node>
    ) throws -> String? where Node: Decodable & Equatable & Sendable {
        guard connection.pageInfo.hasPreviousPage else {
            if let total = connection.totalCount, connection.nodes.count < total {
                throw GitHubReadError.incompleteCoverage("Connection omitted required items")
            }
            return nil
        }
        guard let cursor = connection.pageInfo.startCursor else { throw GitHubReadError.invalidPayload }
        return cursor
    }

    /// `pullRequestID` adds a `p` alias that reads only that PR's identity.
    private func continuationQuery(_ batch: [Continuation], pullRequestID: String? = nil) -> String {
        var declarations = batch.indices.flatMap { index in
            ["$id\(index): ID!", "$cursor\(index): String"]
        }
        var selections = batch.enumerated().map { index, continuation in
            "c\(index): node(id: $id\(index)) { \(continuationSelection(for: continuation, cursor: "$cursor\(index)")) }"
        }
        if pullRequestID != nil {
            declarations.append("$pr: ID!")
            selections.append("p: node(id: $pr) { id }")
        }
        return "query ContinuePullRequestConnections(\(declarations.joined(separator: ", "))) {\n\(selections.joined(separator: "\n"))\n}"
    }

    private func continuationSelection(for continuation: Continuation, cursor: String) -> String {
        let size = GitHubPullRequestQueries.continuationPageSize
        switch continuation.kind {
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
            let threadSize = continuation.before == nil ? GitHubPullRequestQueries.threadCommentFirstReadPageSize : size
            return "... on PullRequestReviewThread { comments(last: \(threadSize), before: \(cursor)) { \(GitHubPullRequestQueries.inlineCommentConnectionFields) } }"
        }
    }

    private func continuationVariables(
        _ batch: [Continuation],
        pullRequestID: String? = nil
    ) -> [String: GitHubQueryValue] {
        var result: [String: GitHubQueryValue] = [:]
        for (index, continuation) in batch.enumerated() {
            result["id\(index)"] = .string(continuation.kind.parentID)
            result["cursor\(index)"] = continuation.before.map(GitHubQueryValue.string) ?? .null
        }
        if let pullRequestID {
            result["pr"] = .string(pullRequestID)
        }
        return result
    }

    /// A single-entry retry whose thread is still NOT_FOUND at its alias while its PR, read as `p`, resolves.
    private func isDeletedThreadOfReadablePullRequest(_ data: Data) throws -> Bool {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObject = envelope["data"] as? [String: Any] else { return false }
        let errors = try decodeErrors(envelope["errors"])
        return !errors.isEmpty
            && errors.allSatisfy { $0.type?.uppercased() == "NOT_FOUND" && $0.path == [.field("c0")] }
            && dataObject["c0"] is NSNull
            && dataObject["p"] is [String: Any]
    }

    private func decodeContinuationPages(
        _ data: Data,
        batch: [Continuation],
        allowsScopedErrors: Bool
    ) throws -> (pages: [Int: ContinuationPage], failedIndices: Set<Int>, missingThreadIndices: Set<Int>) {
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
        // A thread deleted since it was listed reads as null at its alias with only NOT_FOUND at exactly that path.
        let missingThreadIndices = failedIndices.filter { index in
            guard case .threadComments = batch[index].kind, dataObject["c\(index)"] is NSNull else { return false }
            let alias = GitHubGraphQLPathComponent.field("c\(index)")
            return errors.filter { $0.path?.first == alias }.allSatisfy { error in
                error.type?.uppercased() == "NOT_FOUND" && error.path == [alias]
            }
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
        return (pages, failedIndices, missingThreadIndices)
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
        var listedThreads: [GitHubPayloadReviewThread] = []
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
            // The key records that the thread's comment read merged, even for a thread without comments.
            var comments = accumulator.threadComments[threadID] ?? [:]
            value.nodes.forEach { comments[$0.id] = $0 }
            accumulator.threadComments[threadID] = comments
        case (.reviews, .reviews(let value)):
            value.nodes.forEach { accumulator.reviews[$0.id] = $0 }
        case (.opinionatedReviews, .reviews(let value)):
            value.nodes.forEach { accumulator.opinionatedReviews[$0.id] = $0 }
        case (.threads, .threads(let value)):
            listedThreads = value.nodes
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
        }
        // A thread page's first comment reads queue after its own next page. A thread-list restart below
        // removes them again.
        for thread in listedThreads {
            queueFirstCommentRead(
                of: thread, prID: prID, attempt: continuation.attempt, accumulator: &accumulator, queue: &queue
            )
        }
        if !page.pageInfo.hasPreviousPage, let expected = expectedTotal {
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
            // Every re-read thread queues a fresh first comment read.
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
            let payloads = try await read(GitHubPullRequestQueries.pullRequestStacks, ["ids": .strings(chunk)]) { data in
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
                var payloads: [GitHubPayloadStack] = []
                for (index, node) in nodes.enumerated() {
                    if node is NSNull {
                        guard goneIndices.contains(index) else { throw GitHubReadError.invalidPayload }
                        continue
                    }
                    guard let payload = try? decoder.decode(
                        GitHubPayloadStack.self,
                        from: JSONSerialization.data(withJSONObject: node)
                    ), payload.id == chunk[index] else { throw GitHubReadError.invalidPayload }
                    payloads.append(payload)
                }
                return payloads
            }
            for payload in payloads {
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
            connection = try await read(
                GitHubPullRequestQueries.pullRequestStackEntries,
                ["id": .string(payload.id), "cursor": .string(cursor)]
            ) { data in
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw GitHubReadError.invalidPayload
                }
                try validate(errors: Self.withoutUnreadableEntryErrors(
                    try decodeErrors(object["errors"]),
                    data: object["data"]
                ))
                guard let page = try? decoder.decode(GitHubGraphQLPayload<GitHubStackEntriesPayload>.self, from: data).data,
                      let node = page.node else { throw GitHubReadError.invalidPayload }
                return node.entries
            }
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

    private func readValidated<Payload: Decodable & Sendable>(
        _ type: Payload.Type,
        query: String,
        variables: [String: GitHubQueryValue]
    ) async throws -> Payload {
        try await read(query, variables) { data in
            try validate(errors: try decoder.decode(GitHubGraphQLErrorEnvelope.self, from: data).errors)
            guard let payload = try? decoder.decode(GitHubGraphQLPayload<Payload>.self, from: data).data else {
                throw GitHubReadError.invalidPayload
            }
            return payload
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
            throw GitHubReadError.validation(GitHubReadError.sentences(errors.map(\.message)))
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
