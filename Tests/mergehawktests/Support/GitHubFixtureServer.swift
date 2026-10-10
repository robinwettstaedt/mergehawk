@testable import mergehawkcore
import Foundation
import XCTest

/// A test-only GitHub GraphQL server for the fetcher. It owns complete fixture data and answers hydration and
/// continuation queries in whatever page sizes and selections the query text asks for, so the same data serves
/// every query shape the fetcher sends.
///
/// Every connection pages as `last: N, before: cursor` with the newest item last. A cursor is
/// `"<connection>:<owner id>:<index>"` and means "items before index".
final class GitHubFixtureServer: @unchecked Sendable {
    struct Request {
        let query: String
        let variables: [String: GitHubQueryValue]
    }

    struct UnknownShape: Error {
        let description: String
    }

    private struct Thread {
        let id: String
        let isResolved: Bool
        let viewerCanResolve: Bool
        var comments: [[String: Any]]
    }

    private struct PullRequestData {
        let id: String
        var fields: [String: Any]
        var connections: [String: [[String: Any]]]
        var threads: [Thread]
    }

    private static let pullRequestConnections = [
        "comments", "reviews", "latestOpinionatedReviews", "assignees", "reviewRequests"
    ]

    private let lock = NSLock()
    private var pullRequests: [PullRequestData]
    private var storedRequests: [Request] = []
    private let beforeQuery: ((Int, GitHubFixtureServer) -> Void)?

    /// Takes PR dictionaries as `GitHubPaginationTests.pullRequest(...)` builds them. Each connection's `nodes`,
    /// and each thread's `comments.nodes`, is the complete list. Input `totalCount` and `pageInfo` are ignored.
    init(pullRequests: [[String: Any]], beforeQuery: ((Int, GitHubFixtureServer) -> Void)? = nil) {
        self.beforeQuery = beforeQuery
        self.pullRequests = pullRequests.map { input in
            var fields = input
            var connections: [String: [[String: Any]]] = [:]
            for name in Self.pullRequestConnections {
                connections[name] = Self.nodes(of: fields.removeValue(forKey: name))
            }
            let threads = Self.nodes(of: fields.removeValue(forKey: "reviewThreads")).map { thread in
                Thread(
                    id: thread["id"] as! String,
                    isResolved: thread["isResolved"] as! Bool,
                    viewerCanResolve: thread["viewerCanResolve"] as! Bool,
                    comments: Self.nodes(of: thread["comments"])
                )
            }
            return PullRequestData(id: input["id"] as! String, fields: fields, connections: connections, threads: threads)
        }
    }

    var requests: [Request] { lock.withLock { storedRequests } }
    var queries: [String] { requests.map(\.query) }

    var fetcher: GitHubPullRequestFetcher {
        GitHubPullRequestFetcher { query, variables in
            try await self.read(query: query, variables: variables)
        }
    }

    func deleteThread(prID: String, threadID: String) {
        lock.withLock {
            guard let index = pullRequests.firstIndex(where: { $0.id == prID }) else {
                return XCTFail("No fixture PR \(prID)")
            }
            pullRequests[index].threads.removeAll { $0.id == threadID }
        }
    }

    func deleteThreadComment(threadID: String, commentID: String) {
        lock.withLock {
            for prIndex in pullRequests.indices {
                for threadIndex in pullRequests[prIndex].threads.indices
                where pullRequests[prIndex].threads[threadIndex].id == threadID {
                    pullRequests[prIndex].threads[threadIndex].comments.removeAll { $0["id"] as? String == commentID }
                }
            }
        }
    }

    func removePullRequest(id: String) {
        lock.withLock { pullRequests.removeAll { $0.id == id } }
    }

    func read(query: String, variables: [String: GitHubQueryValue]) async throws -> Data {
        let index = lock.withLock {
            storedRequests.append(Request(query: query, variables: variables))
            return storedRequests.count - 1
        }
        beforeQuery?(index, self)
        do {
            let response = try lock.withLock { () throws -> [String: Any] in
                if query.contains("query CompletePullRequests") {
                    return try answerHydration(query: query, variables: variables)
                }
                if query.contains("query ContinuePullRequestConnections") {
                    return try answerContinuations(query: query, variables: variables)
                }
                throw UnknownShape(description: "query \(query)")
            }
            return try JSONSerialization.data(withJSONObject: response)
        } catch let error as UnknownShape {
            XCTFail("GitHubFixtureServer can't answer \(error.description)")
            throw error
        }
    }

    // MARK: Hydration

    private func answerHydration(query: String, variables: [String: GitHubQueryValue]) throws -> [String: Any] {
        guard case .strings(let ids) = variables["ids"] else { throw UnknownShape(description: "hydration ids") }
        var sizes: [String: Int] = [:]
        for name in Self.pullRequestConnections + ["reviewThreads"] {
            guard let size = Self.firstInteger(in: query, pattern: "(?<![A-Za-z])\(name)\\(last: (\\d+)\\)") else {
                throw UnknownShape(description: "hydration without \(name)")
            }
            sizes[name] = size
        }
        guard let threadsStart = query.range(of: "reviewThreads(last:"),
              let threadsEnd = query.range(of: "assignees(last:", range: threadsStart.upperBound..<query.endIndex) else {
            throw UnknownShape(description: "hydration thread selection")
        }
        let threadSelection = String(query[threadsStart.upperBound..<threadsEnd.lowerBound])
        let nestedCommentSize = try nestedCommentSize(in: threadSelection)

        var nodes: [Any] = []
        var errors: [[String: Any]] = []
        for (index, id) in ids.enumerated() {
            guard let pullRequest = pullRequests.first(where: { $0.id == id }) else {
                nodes.append(NSNull())
                errors.append(["type": "NOT_FOUND", "path": ["nodes", index], "message": "Not Found"])
                continue
            }
            var node = pullRequest.fields
            for name in Self.pullRequestConnections {
                node[name] = try page(
                    pullRequest.connections[name] ?? [],
                    name: name, owner: id, last: sizes[name]!, before: nil
                )
            }
            node["reviewThreads"] = try threadPage(
                pullRequest, last: sizes["reviewThreads"]!, before: nil, nestedCommentSize: nestedCommentSize
            )
            nodes.append(node)
        }
        var response: [String: Any] = ["data": ["nodes": nodes]]
        if !errors.isEmpty { response["errors"] = errors }
        return response
    }

    // MARK: Continuations

    private func answerContinuations(query: String, variables: [String: GitHubQueryValue]) throws -> [String: Any] {
        let aliasPattern = try NSRegularExpression(
            pattern: #"^(c\d+): node\(id: \$(\w+)\) \{"#,
            options: [.anchorsMatchLines]
        )
        let text = query as NSString
        let matches = aliasPattern.matches(in: query, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { throw UnknownShape(description: "continuation without aliases \(query)") }
        var data: [String: Any] = [:]
        var errors: [[String: Any]] = []
        for (position, match) in matches.enumerated() {
            let alias = text.substring(with: match.range(at: 1))
            let index = String(alias.dropFirst())
            guard text.substring(with: match.range(at: 2)) == "id\(index)" else {
                throw UnknownShape(description: "alias \(alias) id variable")
            }
            let selectionEnd = position + 1 < matches.count ? matches[position + 1].range.location : text.length
            let selectionStart = match.range.location + match.range.length
            let selection = text.substring(with: NSRange(location: selectionStart, length: selectionEnd - selectionStart))
            guard case .string(let ownerID) = variables["id\(index)"] else {
                throw UnknownShape(description: "alias \(alias) id value")
            }
            let before: String?
            switch variables["cursor\(index)"] {
            case .string(let value): before = value
            case .null: before = nil
            default: throw UnknownShape(description: "alias \(alias) cursor value")
            }
            if let value = try answerAlias(selection: selection, index: index, ownerID: ownerID, before: before) {
                data[alias] = value
            } else {
                data[alias] = NSNull()
                errors.append(["type": "NOT_FOUND", "path": [alias], "message": "Not Found"])
            }
        }
        var response: [String: Any] = ["data": data]
        if !errors.isEmpty { response["errors"] = errors }
        return response
    }

    /// Returns nil when the alias's node no longer exists.
    private func answerAlias(selection: String, index: String, ownerID: String, before: String?) throws -> [String: Any]? {
        let header = try NSRegularExpression(
            pattern: #"^\s*\.\.\. on (PullRequest|PullRequestReviewThread) \{ (\w+)\(last: (\d+), before: \$(\w+)\)"#
        )
        let text = selection as NSString
        guard let match = header.firstMatch(in: selection, range: NSRange(location: 0, length: text.length)),
              text.substring(with: match.range(at: 4)) == "cursor\(index)",
              let size = Int(text.substring(with: match.range(at: 3))) else {
            throw UnknownShape(description: "alias selection \(selection)")
        }
        let type = text.substring(with: match.range(at: 1))
        let name = text.substring(with: match.range(at: 2))
        let rest = text.substring(from: match.range.location + match.range.length)

        if type == "PullRequestReviewThread" {
            guard name == "comments" else { throw UnknownShape(description: "thread connection \(name)") }
            guard let thread = pullRequests.lazy.flatMap(\.threads).first(where: { $0.id == ownerID }) else {
                return nil
            }
            return [name: try page(thread.comments, name: name, owner: ownerID, last: size, before: before)]
        }
        guard let pullRequest = pullRequests.first(where: { $0.id == ownerID }) else { return nil }
        if name == "reviewThreads" {
            return [name: try threadPage(
                pullRequest, last: size, before: before, nestedCommentSize: try nestedCommentSize(in: rest)
            )]
        }
        guard let items = pullRequest.connections[name] else {
            throw UnknownShape(description: "PR connection \(name)")
        }
        return [name: try page(items, name: name, owner: ownerID, last: size, before: before)]
    }

    // MARK: Paging

    private func nestedCommentSize(in threadSelection: String) throws -> Int? {
        guard threadSelection.contains("comments(") else { return nil }
        guard let size = Self.firstInteger(in: threadSelection, pattern: #"comments\(last: (\d+)\)"#) else {
            throw UnknownShape(description: "nested thread comments \(threadSelection)")
        }
        return size
    }

    private func threadPage(
        _ pullRequest: PullRequestData,
        last: Int,
        before: String?,
        nestedCommentSize: Int?
    ) throws -> [String: Any] {
        let rendered = try pullRequest.threads.map { thread -> [String: Any] in
            var node: [String: Any] = [
                "id": thread.id, "isResolved": thread.isResolved, "viewerCanResolve": thread.viewerCanResolve
            ]
            if let nestedCommentSize {
                node["comments"] = try page(
                    thread.comments, name: "comments", owner: thread.id, last: nestedCommentSize, before: nil
                )
            }
            return node
        }
        return try page(rendered, name: "reviewThreads", owner: pullRequest.id, last: last, before: before)
    }

    private func page(
        _ items: [[String: Any]],
        name: String,
        owner: String,
        last: Int,
        before: String?
    ) throws -> [String: Any] {
        var end = items.count
        if let before {
            let parts = before.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == name, parts[1] == owner, let index = Int(parts[2]) else {
                throw UnknownShape(description: "cursor \(before) for \(name) of \(owner)")
            }
            end = min(index, items.count)
        }
        let start = max(0, end - last)
        let nodes = Array(items[start..<end])
        return [
            "totalCount": items.count,
            "nodes": nodes,
            "pageInfo": [
                "startCursor": nodes.isEmpty ? NSNull() : "\(name):\(owner):\(start)" as Any,
                "endCursor": nodes.isEmpty ? NSNull() : "\(name):\(owner):\(end)" as Any,
                "hasPreviousPage": start > 0,
                "hasNextPage": end < items.count
            ]
        ]
    }

    private static func nodes(of connection: Any?) -> [[String: Any]] {
        guard let connection = connection as? [String: Any] else { return [] }
        return connection["nodes"] as? [[String: Any]] ?? []
    }

    private static func firstInteger(in text: String, pattern: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        return Int((text as NSString).substring(with: match.range(at: 1)))
    }
}
