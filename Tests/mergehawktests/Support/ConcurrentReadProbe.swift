@testable import mergehawkcore
import CryptoKit
import Foundation

/// Wraps a fetcher read handler for concurrency tests. Each request waits a delay fixed by the seed and the
/// request's content, so a seed reorders responses the same way in every process. Requests the gate selects wait
/// until a test releases them. The probe records requests in flight, their peak, and a start and end event log.
final class ConcurrentReadProbe: @unchecked Sendable {
    typealias Handler = @Sendable (_ query: String, _ variables: [String: GitHubQueryValue]) async throws -> Data

    struct Event: CustomStringConvertible {
        enum Kind { case start, end }

        let kind: Kind
        let request: GitHubFixtureServer.Request

        /// The query name and what the request reads: hydration IDs or continuation aliases.
        var key: String { ConcurrentReadProbe.key(request) }
        var description: String { "\(kind == .start ? "start" : "end") \(key)" }
    }

    private struct Gated {
        let request: GitHubFixtureServer.Request
        let continuation: CheckedContinuation<Void, Never>
    }

    private let seed: UInt64
    private let maxDelayMicroseconds: UInt64
    private let gate: (@Sendable (GitHubFixtureServer.Request) -> Bool)?
    private let handler: Handler
    private let state = LockedBox((inFlight: 0, peak: 0, events: [Event](), gated: [Gated](), gateOpen: false))

    init(
        seed: UInt64 = 0,
        maxDelayMilliseconds: Int = 0,
        gate: (@Sendable (GitHubFixtureServer.Request) -> Bool)? = nil,
        handler: @escaping Handler
    ) {
        self.seed = seed
        self.maxDelayMicroseconds = UInt64(maxDelayMilliseconds) * 1_000
        self.gate = gate
        self.handler = handler
    }

    convenience init(
        server: GitHubFixtureServer,
        seed: UInt64 = 0,
        maxDelayMilliseconds: Int = 0,
        gate: (@Sendable (GitHubFixtureServer.Request) -> Bool)? = nil
    ) {
        self.init(seed: seed, maxDelayMilliseconds: maxDelayMilliseconds, gate: gate) { query, variables in
            try await server.read(query: query, variables: variables)
        }
    }

    var peakInFlight: Int { state.value.peak }
    var inFlight: Int { state.value.inFlight }
    var events: [Event] { state.value.events }
    var gatedRequests: [GitHubFixtureServer.Request] { state.value.gated.map(\.request) }
    var startedRequests: [GitHubFixtureServer.Request] { events.filter { $0.kind == .start }.map(\.request) }

    func fetcher(capacity: Int = GitHubReadLimiter.defaultCapacity) -> GitHubPullRequestFetcher {
        fetcher(limiter: GitHubReadLimiter(capacity: capacity))
    }

    func fetcher(limiter: GitHubReadLimiter) -> GitHubPullRequestFetcher {
        GitHubPullRequestFetcher(read: { query, variables in
            try await self.read(query: query, variables: variables)
        }, limiter: limiter)
    }

    func read(query: String, variables: [String: GitHubQueryValue]) async throws -> Data {
        let request = GitHubFixtureServer.Request(query: query, variables: variables)
        state.withValue { value in
            value.inFlight += 1
            value.peak = max(value.peak, value.inFlight)
            value.events.append(Event(kind: .start, request: request))
        }
        defer {
            state.withValue { value in
                value.inFlight -= 1
                value.events.append(Event(kind: .end, request: request))
            }
        }
        if let gate, gate(request) {
            await withCheckedContinuation { continuation in
                let released = state.withValue { value -> Bool in
                    if value.gateOpen { return true }
                    value.gated.append(Gated(request: request, continuation: continuation))
                    return false
                }
                if released { continuation.resume() }
            }
        }
        let delay = delayMicroseconds(query: query, variables: variables)
        if delay > 0 {
            try? await Task.sleep(for: .microseconds(delay))
        }
        return try await handler(query, variables)
    }

    /// Releases the oldest gated request `matching` selects. Returns whether one was waiting.
    @discardableResult
    func release(where matching: (GitHubFixtureServer.Request) -> Bool = { _ in true }) -> Bool {
        let gated = state.withValue { value -> Gated? in
            guard let index = value.gated.firstIndex(where: { matching($0.request) }) else { return nil }
            return value.gated.remove(at: index)
        }
        gated?.continuation.resume()
        return gated != nil
    }

    /// Releases every gated request and lets later ones pass.
    func openGate() {
        let gated = state.withValue { value -> [Gated] in
            value.gateOpen = true
            defer { value.gated = [] }
            return value.gated
        }
        gated.forEach { $0.continuation.resume() }
    }

    private func delayMicroseconds(query: String, variables: [String: GitHubQueryValue]) -> UInt64 {
        guard maxDelayMicroseconds > 0 else { return 0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = withUnsafeBytes(of: seed.littleEndian) { Data($0) }
        data += Data(query.utf8)
        data += (try? encoder.encode(variables)) ?? Data()
        let digest = Array(SHA256.hash(data: data))
        let value = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return value % (maxDelayMicroseconds + 1)
    }

    static func key(_ request: GitHubFixtureServer.Request) -> String {
        let name = request.query.range(of: "query ").map { String(request.query[$0.upperBound...].prefix { $0.isLetter }) } ?? ""
        if case .strings(let ids) = request.variables["ids"] {
            return "\(name) \(ids.joined(separator: ","))"
        }
        let aliases = request.aliases.map { "\($0.id):\($0.connection):\($0.cursor ?? "nil")" }
        return aliases.isEmpty ? name : "\(name) \(aliases.joined(separator: " "))"
    }
}
