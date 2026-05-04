import Foundation
import UserNotifications
import VCDashCore

final class NotificationCenterClient {
    func requestAuthorization() {
        guard canUseUserNotifications else {
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(events: [PullRequestEvent], pullRequests: [PullRequest]) {
        guard canUseUserNotifications, !events.isEmpty else {
            return
        }

        let prsById = Dictionary(uniqueKeysWithValues: pullRequests.map { ($0.id, $0) })
        let content = UNMutableNotificationContent()
        content.title = events.count == 1 ? title(for: events[0]) : "\(events.count) VC Dash updates"
        content.body = body(for: events, prsById: prsById)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "vc-dash-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func title(for event: PullRequestEvent) -> String {
        switch event.type {
        case .newComment:
            event.count == 1 ? "New PR comment" : "\(event.count ?? 0) new PR comments"
        case .newReview:
            event.count == 1 ? "New PR review" : "\(event.count ?? 0) new PR reviews"
        case .ciFailed:
            "CI failed"
        case .changesRequested:
            "Changes requested"
        }
    }

    private func body(for events: [PullRequestEvent], prsById: [String: PullRequest]) -> String {
        if events.count == 1, let pr = prsById[events[0].prId] {
            return "\(pr.repo)#\(pr.number): \(pr.title)"
        }
        let repos = events.compactMap { prsById[$0.prId]?.repo }
        return repos.isEmpty ? "Open VC Dash for details." : repos.prefix(3).joined(separator: ", ")
    }
}
