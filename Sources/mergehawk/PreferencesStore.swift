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
            decoded(for: "notifications.prMatrix", fallback: .defaults)
        }
        set {
            encode(newValue, for: "notifications.prMatrix")
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

    var authMethod: GitHubAuthMethod {
        get {
            guard
                let rawValue = defaults.string(forKey: "auth.method"),
                let method = GitHubAuthMethod(rawValue: rawValue)
            else {
                return .oauth
            }
            return method
        }
        set {
            defaults.set(newValue.rawValue, forKey: "auth.method")
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

    var sourceCatalogSyncedAt: Date? {
        get { defaults.object(forKey: "sources.catalogSyncedAt") as? Date }
        set { defaults.set(newValue, forKey: "sources.catalogSyncedAt") }
    }

    var sourceCatalogAccountLogin: String? {
        get { defaults.string(forKey: "sources.catalogAccountLogin") }
        set { defaults.set(newValue, forKey: "sources.catalogAccountLogin") }
    }

    var pullRequestSnapshotCache: PullRequestSnapshotCache {
        get {
            decoded(for: "pullRequests.snapshotCache", fallback: .empty)
        }
        set {
            encode(newValue, for: "pullRequests.snapshotCache")
        }
    }

    var pullRequestNotificationHistory: [PullRequestNotification] {
        get {
            decoded(for: "notifications.prHistory", fallback: [])
        }
        set {
            encode(newValue, for: "notifications.prHistory")
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

    var pullRequestSortDirection: DashboardController.PullRequestSortDirection {
        get {
            guard
                let rawValue = defaults.string(forKey: "pullRequests.sortDirection"),
                let direction = DashboardController.PullRequestSortDirection(rawValue: rawValue)
            else {
                return .descending
            }
            return direction
        }
        set {
            defaults.set(newValue.rawValue, forKey: "pullRequests.sortDirection")
        }
    }

    var reviewRequestSortOption: DashboardController.PullRequestSortOption {
        get {
            guard
                let rawValue = defaults.string(forKey: "reviewRequests.sortOption"),
                let option = DashboardController.PullRequestSortOption(rawValue: rawValue)
            else {
                return .createdDate
            }
            return option
        }
        set {
            defaults.set(newValue.rawValue, forKey: "reviewRequests.sortOption")
        }
    }

    var reviewRequestSortDirection: DashboardController.PullRequestSortDirection {
        get {
            guard
                let rawValue = defaults.string(forKey: "reviewRequests.sortDirection"),
                let direction = DashboardController.PullRequestSortDirection(rawValue: rawValue)
            else {
                return .descending
            }
            return direction
        }
        set {
            defaults.set(newValue.rawValue, forKey: "reviewRequests.sortDirection")
        }
    }

    var selectedPullRequestFilters: Set<DashboardController.PullRequestFilterOption> {
        get {
            if defaults.object(forKey: "pullRequests.filterOptions") != nil {
                return pullRequestFilters(from: defaults.stringArray(forKey: "pullRequests.filterOptions") ?? [])
            }
            return migratedPullRequestFilters()
        }
        set {
            defaults.set(
                orderedRawValues(from: newValue, options: DashboardController.PullRequestFilterOption.allCases),
                forKey: "pullRequests.filterOptions"
            )
        }
    }

    var selectedReviewRequestFilters: Set<DashboardController.ReviewRequestFilterOption> {
        get {
            if defaults.object(forKey: "reviewRequests.filterOptions") != nil {
                return reviewRequestFilters(from: defaults.stringArray(forKey: "reviewRequests.filterOptions") ?? [])
            }
            return migratedReviewRequestFilters()
        }
        set {
            defaults.set(
                orderedRawValues(from: newValue, options: DashboardController.ReviewRequestFilterOption.allCases),
                forKey: "reviewRequests.filterOptions"
            )
        }
    }

    var pinnedPullRequestIds: Set<String> {
        get {
            normalizedPullRequestIds(for: "pullRequests.pinnedIds")
        }
        set {
            defaults.set(newValue.sorted(), forKey: "pullRequests.pinnedIds")
        }
    }

    var hiddenPullRequestIds: Set<String> {
        get {
            normalizedPullRequestIds(for: "pullRequests.hiddenIds")
        }
        set {
            defaults.set(newValue.sorted(), forKey: "pullRequests.hiddenIds")
        }
    }

    private func migratedPullRequestFilters() -> Set<DashboardController.PullRequestFilterOption> {
        guard
            let rawValue = defaults.string(forKey: "pullRequests.filterOption"),
            let option = DashboardController.PullRequestFilterOption(rawValue: rawValue),
            option != .all
        else {
            return []
        }
        return [option]
    }

    private func migratedReviewRequestFilters() -> Set<DashboardController.ReviewRequestFilterOption> {
        guard
            let rawValue = defaults.string(forKey: "reviewRequests.filterOption"),
            let option = DashboardController.ReviewRequestFilterOption(rawValue: rawValue),
            option != .all
        else {
            return []
        }
        return [option]
    }

    private func pullRequestFilters(
        from rawValues: [String]
    ) -> Set<DashboardController.PullRequestFilterOption> {
        Set(rawValues.compactMap(DashboardController.PullRequestFilterOption.init(rawValue:))).subtracting([.all])
    }

    private func reviewRequestFilters(
        from rawValues: [String]
    ) -> Set<DashboardController.ReviewRequestFilterOption> {
        Set(rawValues.compactMap(DashboardController.ReviewRequestFilterOption.init(rawValue:))).subtracting([.all])
    }

    private func orderedRawValues<Option: RawRepresentable & Equatable & Hashable>(
        from selectedOptions: Set<Option>,
        options: [Option]
    ) -> [String] where Option.RawValue == String {
        options
            .filter { selectedOptions.contains($0) }
            .filter { $0.rawValue != "all" }
            .map(\.rawValue)
    }

    private func value(for key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func normalizedPullRequestIds(for key: String) -> Set<String> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap { rawValue in
            let id = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        })
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
