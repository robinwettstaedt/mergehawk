import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One reading of the shared GitHub GraphQL budget, from a response's `x-ratelimit-*` headers.
public struct GitHubBudgetReading: Equatable, Sendable {
    public let limit: Int
    public let remaining: Int
    public let used: Int
    public let resetAt: Date
    public let receivedAt: Date

    public init(limit: Int, remaining: Int, used: Int, resetAt: Date, receivedAt: Date) {
        self.limit = limit
        self.remaining = remaining
        self.used = used
        self.resetAt = resetAt
        self.receivedAt = receivedAt
    }

    public init?(response: HTTPURLResponse, receivedAt: Date) {
        func header(_ name: String) -> Int? {
            response.value(forHTTPHeaderField: name)
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        guard let limit = header("x-ratelimit-limit"),
              let remaining = header("x-ratelimit-remaining"),
              let used = header("x-ratelimit-used"),
              let reset = header("x-ratelimit-reset")
        else {
            return nil
        }
        self.init(
            limit: limit,
            remaining: remaining,
            used: used,
            resetAt: Date(timeIntervalSince1970: TimeInterval(reset)),
            receivedAt: receivedAt
        )
    }

    /// Merges conservatively, because GitHub can alternate between two counters for one user: a main one and a
    /// stray one with a later reset and almost nothing used. A reading whose reset had passed, plus the 5 s reset
    /// margin for clock skew, when the other was received gives way to it, so a genuine new window takes over.
    /// Otherwise the higher `used` wins, so a stray low counter never hides spent points, then the later
    /// `receivedAt`. A full tie keeps the receiver. The precedence is the same from both sides, so the result
    /// never depends on arrival order.
    public func merged(with other: GitHubBudgetReading?) -> GitHubBudgetReading {
        guard let other else { return self }
        let selfEnded = other.receivedAt >= resetAt.addingTimeInterval(RefreshPacingPolicy.resetMargin)
        let otherEnded = receivedAt >= other.resetAt.addingTimeInterval(RefreshPacingPolicy.resetMargin)
        if selfEnded != otherEnded {
            return selfEnded ? other : self
        }
        if other.used != used {
            return other.used > used ? other : self
        }
        return other.receivedAt > receivedAt ? other : self
    }

    /// A reading received before its own reset counts as unknown once that reset passes.
    /// One received after its reset means GitHub has not reset yet, so it stays usable.
    public func isStale(at now: Date) -> Bool {
        resetAt <= now && receivedAt < resetAt
    }
}

/// Everything the controller remembers about the budget for one provider generation.
public struct GitHubBudgetState: Equatable, Sendable {
    public static let maximumCostSamples = 3

    public private(set) var reading: GitHubBudgetReading?
    /// The rise in `used` of recent complete PR refreshes, newest last.
    public private(set) var costSamples: [Int]
    public private(set) var lastReadFailed: Bool

    public init(reading: GitHubBudgetReading? = nil, costSamples: [Int] = [], lastReadFailed: Bool = false) {
        self.reading = reading
        self.costSamples = costSamples
        self.lastReadFailed = lastReadFailed
    }

    /// Records a budget read that succeeded. Nil means the response carried no budget headers.
    /// The reading merges with the current one, so a read that finishes after a newer refresh never rolls it back.
    public mutating func recordRead(_ reading: GitHubBudgetReading?) {
        guard let reading else {
            lastReadFailed = true
            return
        }
        self.reading = reading.merged(with: self.reading)
        lastReadFailed = false
    }

    public mutating func recordReadFailure() {
        lastReadFailed = true
    }

    /// Merges in the source's latest reading after a refresh, without touching the read failure.
    public mutating func recordLatest(_ reading: GitHubBudgetReading?) {
        guard let reading else { return }
        self.reading = reading.merged(with: self.reading)
    }

    /// Adds the refresh's cost when the baseline and the fetch share a window and `used` rose.
    public mutating func recordCompleteRefresh(baseline: GitHubBudgetReading?, fetched: GitHubBudgetReading?) {
        guard let baseline, let fetched, baseline.resetAt == fetched.resetAt else { return }
        let rise = fetched.used - baseline.used
        guard rise >= 1 else { return }
        costSamples.append(rise)
        if costSamples.count > Self.maximumCostSamples {
            costSamples.removeFirst(costSamples.count - Self.maximumCostSamples)
        }
    }

    /// The highest recent sample, so one expensive refresh keeps the estimate high for a few more.
    public var estimatedCost: Int? {
        costSamples.max()
    }

    public func usableReading(at now: Date) -> GitHubBudgetReading? {
        guard let reading, !reading.isStale(at: now) else { return nil }
        return reading
    }
}
