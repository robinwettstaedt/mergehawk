import SwiftUI
import mergehawkcore

/// The pacing state Settings and the menu show, computed by the controller for one presentation date.
struct PacingDisplay: Equatable {
    let pacing: RefreshPacing
    /// Whether the whole remaining budget, reserve included, still covers one refresh.
    let canRefreshManually: Bool
    /// When GitHub permits automatic refreshes again after refusing one, while that is still ahead.
    let rateLimitRetryAt: Date?

    /// The dates after `date` where this display ends on its own: the reset, the moment automatic refresh
    /// resumes after it, and the end of a rate-limit deferral.
    func changeDates(after date: Date) -> [Date] {
        var dates: [Date] = []
        switch pacing {
        case .normal:
            break
        case .stretched(_, let until), .paused(let until):
            dates += [until, until.addingTimeInterval(RefreshPacingPolicy.resetMargin)]
        }
        if let rateLimitRetryAt {
            dates.append(rateLimitRetryAt)
        }
        return Array(Set(dates.filter { $0 > date })).sorted()
    }
}

enum GitHubBudgetCopy {
    static let title = "GitHub API budget"
    static let hint = "MergeHawk spaces out automatic refreshes to stay within this budget and stops them "
        + "when 20% is left, so gh and other tools keep working. The budget is shared by every tool that uses "
        + "your GitHub account."
    static let checking = "Checking budget"
    static let readFailed = "Couldn't read the budget"

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func minutes(_ interval: TimeInterval) -> Int {
        Int((interval / 60).rounded(.up))
    }

    static func numbers(remaining: Int, limit: Int) -> String {
        "\(remaining.formatted()) of \(limit.formatted()) left this hour"
    }

    static func reset(_ date: Date) -> String {
        "Resets at \(time(date))"
    }

    static func rateLimited(until date: Date) -> String {
        "GitHub rate limit reached. Automatic refresh paused until \(time(date))."
    }

    static func paused(until date: Date, canRefreshManually: Bool) -> String {
        let paused = "Automatic refresh paused until \(time(date))."
        return canRefreshManually ? "\(paused) Manual refresh still works." : paused
    }

    static func stretched(interval: TimeInterval, until date: Date) -> String {
        "Refreshing every \(minutes(interval)) min until \(time(date)) to stay within the budget"
    }
}

/// What the Settings budget readout shows at one date.
struct GitHubBudgetPresentation: Equatable {
    let title: String
    /// The share of the limit still left, 0 without a usable reading.
    let fillFraction: Double
    let reserveFraction: Double
    /// True at or below the reserve, or while automatic refresh is paused.
    let isWarning: Bool
    let numbersLine: String
    let resetLine: String?
    let hint: String
    let statusLine: String?

    init(budgetState: GitHubBudgetState, pacing: PacingDisplay, now: Date) {
        let reading = budgetState.usableReading(at: now)
        title = GitHubBudgetCopy.title
        reserveFraction = RefreshPacingPolicy.reserveFraction
        hint = GitHubBudgetCopy.hint
        if let reading, reading.limit > 0 {
            fillFraction = min(max(Double(reading.remaining) / Double(reading.limit), 0), 1)
        } else {
            fillFraction = 0
        }
        let atOrBelowReserve = reading.map { $0.remaining <= RefreshPacingPolicy.reserve(forLimit: $0.limit) } == true
        var pausedUntil: Date?
        if case .paused(let until) = pacing.pacing {
            pausedUntil = until
        }
        isWarning = atOrBelowReserve || pausedUntil != nil
        if let reading {
            numbersLine = GitHubBudgetCopy.numbers(remaining: reading.remaining, limit: reading.limit)
            resetLine = GitHubBudgetCopy.reset(reading.resetAt)
        } else {
            numbersLine = budgetState.lastReadFailed ? GitHubBudgetCopy.readFailed : GitHubBudgetCopy.checking
            resetLine = nil
        }
        if let retryAt = pacing.rateLimitRetryAt, retryAt > now {
            statusLine = GitHubBudgetCopy.rateLimited(until: max(retryAt, pausedUntil ?? retryAt))
        } else {
            switch pacing.pacing {
            case .paused(let until):
                statusLine = GitHubBudgetCopy.paused(until: until, canRefreshManually: pacing.canRefreshManually)
            case .stretched(let interval, let until):
                statusLine = GitHubBudgetCopy.stretched(interval: interval, until: until)
            case .normal:
                statusLine = nil
            }
        }
    }
}

/// The budget readout in Settings › General, shown only while signed in. It reads the budget while the
/// Settings window is open on General.
struct GitHubBudgetSection: View {
    @ObservedObject var controller: DashboardController
    @ObservedObject var settingsWindowState: SettingsWindowState

    var body: some View {
        if controller.state.authStatus == .signedIn {
            TimelineView(.explicit(scheduleDates)) { _ in
                GitHubBudgetReadout(presentation: controller.budgetPresentation(at: controller.currentDate()))
            }
            .task(id: settingsWindowState.isOpen) {
                guard settingsWindowState.isOpen else { return }
                await controller.runBudgetReadout()
            }
        }
    }

    /// Now, then every date where the readout changes without a new reading.
    private var scheduleDates: [Date] {
        let now = controller.currentDate()
        var dates = controller.pacingDisplay(at: now).changeDates(after: now)
        if let resetAt = controller.budgetState.reading?.resetAt, resetAt > now {
            dates.append(resetAt)
        }
        return [now] + Array(Set(dates)).sorted()
    }
}

private struct GitHubBudgetReadout: View {
    let presentation: GitHubBudgetPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.title)
            GitHubBudgetBar(presentation: presentation)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.title)
                .accessibilityValue(presentation.numbersLine)
            HStack(alignment: .firstTextBaseline) {
                Text(presentation.numbersLine)
                Spacer(minLength: 8)
                if let resetLine = presentation.resetLine {
                    Text(resetLine)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let statusLine = presentation.statusLine {
                Text(statusLine)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(presentation.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private struct GitHubBudgetBar: View {
    let presentation: GitHubBudgetPresentation

    private static let barHeight: CGFloat = 6
    private static let tickHeight: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: Self.barHeight)
                Capsule()
                    .fill(presentation.isWarning ? Color.orange : Color.accentColor)
                    .frame(width: width * presentation.fillFraction, height: Self.barHeight)
                Rectangle()
                    .fill(Color.secondary)
                    .frame(width: 1.5, height: Self.tickHeight)
                    .offset(x: width * presentation.reserveFraction - 0.75)
            }
            .frame(height: Self.tickHeight)
        }
        .frame(height: Self.tickHeight)
    }
}
