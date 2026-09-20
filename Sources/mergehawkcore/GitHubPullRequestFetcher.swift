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
