import Foundation

/// How automatic refreshes run against the GitHub API budget.
public enum RefreshPacing: Equatable, Sendable {
    /// Refresh at the user's interval.
    case normal
    /// Refresh at a longer interval until the reset.
    case stretched(interval: TimeInterval, until: Date)
    /// No automatic refresh until the reset.
    case paused(until: Date)
}

public enum RefreshPacingPolicy {
    /// The share of the limit automatic refreshes leave alone.
    public static let reserveFraction = 0.2
    /// Absorbs small clock skew between the Mac and GitHub around the reset.
    public static let resetMargin: TimeInterval = 5
    /// The next check when GitHub has not reset although the Mac's clock says it should have.
    public static let minimumRecheck: TimeInterval = 60

    public static func reserve(forLimit limit: Int) -> Int {
        Int((Double(limit) * reserveFraction).rounded(.up))
    }

    public static func decide(
        reading: GitHubBudgetReading?,
        estimatedCost: Int?,
        userInterval: TimeInterval,
        now: Date
    ) -> RefreshPacing {
        guard let reading, !reading.isStale(at: now) else { return .normal }
        let reserve = reserve(forLimit: reading.limit)
        guard reading.remaining > reserve else { return .paused(until: reading.resetAt) }
        guard let estimatedCost, estimatedCost > 0 else { return .normal }
        let available = reading.remaining - reserve
        guard available >= estimatedCost else { return .paused(until: reading.resetAt) }
        let affordable = available / estimatedCost
        let timeUntilReset = reading.resetAt.timeIntervalSince(now)
        if timeUntilReset <= 0 || Double(affordable) * userInterval >= timeUntilReset {
            return .normal
        }
        let minutes = ((timeUntilReset / Double(affordable)) / 60).rounded(.up)
        return .stretched(interval: max(minutes * 60, userInterval), until: reading.resetAt)
    }

    /// Whether the whole remaining budget, reserve included, still covers one refresh.
    public static func canAffordOneRefresh(reading: GitHubBudgetReading?, estimatedCost: Int?) -> Bool {
        guard let reading, let estimatedCost else { return false }
        return reading.remaining >= estimatedCost
    }

    /// When the automatic loop next refreshes, measured from `anchor`, the start of the previous automatic refresh.
    public static func nextAutomaticRefreshDate(
        pacing: RefreshPacing,
        anchor: Date,
        userInterval: TimeInterval,
        deferralRetryAt: Date?,
        now: Date
    ) -> Date {
        let paced: Date
        switch pacing {
        case .normal:
            paced = anchor.addingTimeInterval(userInterval)
        case .stretched(let interval, let until):
            paced = min(anchor.addingTimeInterval(interval), until.addingTimeInterval(resetMargin))
        case .paused(let until):
            let resume = until.addingTimeInterval(resetMargin)
            paced = resume <= now ? max(resume, now.addingTimeInterval(minimumRecheck)) : resume
        }
        guard let deferralRetryAt else { return paced }
        return max(paced, deferralRetryAt)
    }
}
