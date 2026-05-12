import Foundation
import mergehawkcore

struct PreferencesStore {
    static let refreshIntervalMinuteOptions = [1, 2, 5, 10, 15]
    static let defaultRefreshIntervalMinutes = 2

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var notificationPreferences: NotificationPreferences {
        get {
            NotificationPreferences(
                newComment: value(for: "notifications.newComment", fallback: true),
                newReview: value(for: "notifications.newReview", fallback: true),
                ciFailed: value(for: "notifications.ciFailed", fallback: true),
                changesRequested: value(for: "notifications.changesRequested", fallback: true)
            )
        }
        set {
            defaults.set(newValue.newComment, forKey: "notifications.newComment")
            defaults.set(newValue.newReview, forKey: "notifications.newReview")
            defaults.set(newValue.ciFailed, forKey: "notifications.ciFailed")
            defaults.set(newValue.changesRequested, forKey: "notifications.changesRequested")
        }
    }

    var macOSLocalNotificationsEnabled: Bool {
        get {
            value(for: "notifications.macOSLocalNotificationsEnabled", fallback: true)
        }
        set {
            defaults.set(newValue, forKey: "notifications.macOSLocalNotificationsEnabled")
        }
    }

    var sourcePreferences: SourcePreferences {
        get {
            decoded(for: "sources.preferences", fallback: .defaults)
        }
        set {
            encode(newValue, for: "sources.preferences")
        }
    }

    var sourceCatalog: SourceCatalog {
        get {
            decoded(for: "sources.catalog", fallback: .empty)
        }
        set {
            encode(newValue, for: "sources.catalog")
        }
    }

    var refreshIntervalMinutes: Int {
        get {
            let stored = defaults.integer(forKey: "refresh.intervalMinutes")
            return Self.refreshIntervalMinuteOptions.contains(stored)
                ? stored
                : Self.defaultRefreshIntervalMinutes
        }
        set {
            guard Self.refreshIntervalMinuteOptions.contains(newValue) else {
                return
            }
            defaults.set(newValue, forKey: "refresh.intervalMinutes")
        }
    }

    var pullRequestSortOption: DashboardController.PullRequestSortOption {
        get {
            guard
                let rawValue = defaults.string(forKey: "pullRequests.sortOption"),
                let option = DashboardController.PullRequestSortOption(rawValue: rawValue)
            else {
                return .createdDate
            }
            return option
        }
        set {
            defaults.set(newValue.rawValue, forKey: "pullRequests.sortOption")
        }
    }

    var pullRequestFilterOption: DashboardController.PullRequestFilterOption {
        get {
            guard
                let rawValue = defaults.string(forKey: "pullRequests.filterOption"),
                let option = DashboardController.PullRequestFilterOption(rawValue: rawValue)
            else {
                return .all
            }
            return option
        }
        set {
            defaults.set(newValue.rawValue, forKey: "pullRequests.filterOption")
        }
    }

    var reviewRequestFilterOption: DashboardController.ReviewRequestFilterOption {
        get {
            guard
                let rawValue = defaults.string(forKey: "reviewRequests.filterOption"),
                let option = DashboardController.ReviewRequestFilterOption(rawValue: rawValue)
            else {
                return .direct
            }
            return option
        }
        set {
            defaults.set(newValue.rawValue, forKey: "reviewRequests.filterOption")
        }
    }

    private func value(for key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func decoded<Value: Decodable>(for key: String, fallback: Value) -> Value {
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(Value.self, from: data)
        else {
            return fallback
        }
        return value
    }

    private func encode<Value: Encodable>(_ value: Value, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
