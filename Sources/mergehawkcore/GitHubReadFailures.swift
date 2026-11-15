import Foundation

/// An error the client's token provider threw during a refresh read. The client unwraps it before the refresh
/// ends, so the app sees the provider's own error.
struct GitHubTokenProviderError: Error {
    let underlying: Error
}

/// A read turned away because its refresh already failed. It ranks below every real error.
struct GitHubReadStopped: Error, Equatable {}

/// Where a read sits in a refresh's fixed order, which picks the error among failures of equal rank.
struct GitHubReadOrder: Comparable, Hashable, Sendable {
    enum Phase: Int, Comparable, Sendable {
        case viewerTeams
        case discovery
        case knownHydration
        case newHydration
        case continuation

        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let phase: Phase
    /// The batch index within the phase, or within its round for continuation.
    let index: Int

    init(_ phase: Phase, _ index: Int = 0) {
        self.phase = phase
        self.index = index
    }

    static func < (lhs: GitHubReadOrder, rhs: GitHubReadOrder) -> Bool {
        (lhs.phase, lhs.index) < (rhs.phase, rhs.index)
    }
}

/// The failures of one refresh's concurrent reads. `error()` picks the one that ends the refresh.
struct GitHubReadFailures {
    private var records: [(error: Error, order: GitHubReadOrder)] = []

    var isEmpty: Bool { records.isEmpty }

    mutating func record(_ error: Error, at order: GitHubReadOrder) {
        records.append((error, order))
    }

    /// Highest rank first: cancellation or a token provider error, then authentication, then a rate limit with
    /// the latest retry date, then any other error. Equal ranks take the earliest order. A stopped read is
    /// returned only when nothing else failed.
    func error() -> Error? {
        func earliest(_ matching: (Error) -> Bool) -> Error? {
            records.filter { matching($0.error) }.min { $0.order < $1.order }?.error
        }
        if let outside = earliest({ $0 is CancellationError || $0 is GitHubTokenProviderError }) {
            return outside
        }
        if let authentication = earliest({ ($0 as? GitHubReadError) == .authentication }) {
            return authentication
        }
        let rateLimits = records.compactMap { record -> Date?? in
            guard case .rateLimited(let retryAt) = record.error as? GitHubReadError else { return nil }
            return .some(retryAt)
        }
        if !rateLimits.isEmpty {
            return GitHubReadError.rateLimited(retryAt: rateLimits.compactMap { $0 }.max())
        }
        if let other = earliest({ !($0 is GitHubReadStopped) }) {
            return other
        }
        return records.first?.error
    }
}
