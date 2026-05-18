import Foundation
import UserNotifications
import mergehawkcore

protocol NotificationPosting {
    func requestAuthorization()
    func post(events: [PullRequestEvent], pullRequests: [PullRequest])
}

enum NotificationContentBuilder {
    static func records(events: [PullRequestEvent], pullRequests: [PullRequest]) -> [NotificationRecord] {
        guard !events.isEmpty else {
            return []
        }

        let prsById = Dictionary(uniqueKeysWithValues: pullRequests.map { ($0.id, $0) })
        let clickRoute = NotificationClickRoute.route(events: events, pullRequests: pullRequests)
        return events.map { event in
            let pullRequest = prsById[event.prId]
            return NotificationRecord(
                title: title(for: event),
                body: body(for: [event], prsById: prsById),
                eventType: event.type.rawValue,
                pullRequestId: event.prId,
                pullRequestTitle: pullRequest?.title,
                repository: pullRequest?.repo,
                clickAction: clickRoute.action,
                clickPullRequestURL: clickRoute.pullRequestURLString
            )
        }
    }

    static func summaryTitle(for events: [PullRequestEvent]) -> String {
        events.count == 1 ? title(for: events[0]) : "\(events.count) MergeHawk updates"
    }

    static func summaryBody(for events: [PullRequestEvent], pullRequests: [PullRequest]) -> String {
        let prsById = Dictionary(uniqueKeysWithValues: pullRequests.map { ($0.id, $0) })
        return body(for: events, prsById: prsById)
    }

    private static func title(for event: PullRequestEvent) -> String {
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

    private static func body(for events: [PullRequestEvent], prsById: [String: PullRequest]) -> String {
        if events.count == 1, let pr = prsById[events[0].prId] {
            return "\(pr.repo)#\(pr.number): \(pr.title)"
        }
        let repos = events.compactMap { prsById[$0.prId]?.repo }
        return repos.isEmpty ? "Open MergeHawk for details." : repos.prefix(3).joined(separator: ", ")
    }
}

enum NotificationClickRoute: Equatable {
    static let actionKey = "mergehawk.notificationClickAction"
    static let pullRequestURLKey = "mergehawk.pullRequestURL"
    static let openPullRequestAction = "open_pull_request"
    static let openNotificationsAction = "open_notifications"

    case openPullRequest(URL)
    case openNotifications

    var action: String {
        switch self {
        case .openPullRequest:
            Self.openPullRequestAction
        case .openNotifications:
            Self.openNotificationsAction
        }
    }

    var pullRequestURLString: String? {
        switch self {
        case .openPullRequest(let url):
            url.absoluteString
        case .openNotifications:
            nil
        }
    }

    var userInfo: [String: String] {
        var userInfo = [Self.actionKey: action]
        if let pullRequestURLString {
            userInfo[Self.pullRequestURLKey] = pullRequestURLString
        }
        return userInfo
    }

    static func route(events: [PullRequestEvent], pullRequests: [PullRequest]) -> NotificationClickRoute {
        guard events.count == 1,
              let event = events.first,
              let pullRequest = pullRequests.first(where: { $0.id == event.prId })
        else {
            return .openNotifications
        }
        return .openPullRequest(pullRequest.url)
    }

    init(userInfo: [AnyHashable: Any]) {
        guard let action = userInfo[Self.actionKey] as? String else {
            self = .openNotifications
            return
        }

        switch action {
        case Self.openPullRequestAction:
            if let urlString = userInfo[Self.pullRequestURLKey] as? String,
               let url = URL(string: urlString),
               url.scheme != nil,
               url.host != nil {
                self = .openPullRequest(url)
            } else {
                self = .openNotifications
            }
        case Self.openNotificationsAction:
            self = .openNotifications
        default:
            self = .openNotifications
        }
    }
}

struct NotificationRecord: Codable, Equatable {
    let title: String
    let body: String
    let eventType: String
    let pullRequestId: String
    let pullRequestTitle: String?
    let repository: String?
    let clickAction: String
    let clickPullRequestURL: String?
}

final class NotificationCenterClient: NotificationPosting {
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

        let content = UNMutableNotificationContent()
        content.title = NotificationContentBuilder.summaryTitle(for: events)
        content.body = NotificationContentBuilder.summaryBody(for: events, pullRequests: pullRequests)
        content.sound = .default
        content.userInfo = NotificationClickRoute.route(events: events, pullRequests: pullRequests).userInfo

        let request = UNNotificationRequest(
            identifier: "mergehawk-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}

final class RecordingNotificationClient: NotificationPosting {
    private let logURL: URL?
    private(set) var records: [NotificationRecord] = []

    init(logPath: String? = nil) {
        if let logPath, !logPath.isEmpty {
            self.logURL = URL(fileURLWithPath: logPath)
        } else {
            self.logURL = nil
        }
    }

    func requestAuthorization() {}

    func post(events: [PullRequestEvent], pullRequests: [PullRequest]) {
        let nextRecords = NotificationContentBuilder.records(events: events, pullRequests: pullRequests)
        guard !nextRecords.isEmpty else {
            return
        }

        records.append(contentsOf: nextRecords)
        guard let logURL else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = try nextRecords
                .map { try String(decoding: encoder.encode($0), as: UTF8.self) }
                .joined(separator: "\n") + "\n"

            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(payload.utf8))
                try handle.close()
            } else {
                try payload.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            assertionFailure("Failed to record mock notifications: \(error)")
        }
    }
}

final class NoOpNotificationClient: NotificationPosting {
    func requestAuthorization() {}
    func post(events: [PullRequestEvent], pullRequests: [PullRequest]) {}
}
