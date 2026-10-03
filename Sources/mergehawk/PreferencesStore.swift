import Foundation
import mergehawkcore

struct PreferencesStore {
    static let refreshIntervalMinuteOptions = [1, 2, 5, 10, 15]
    static let defaultRefreshIntervalMinutes = 2

    private let defaults: UserDefaults
    private let syncStateEncoder: (PullRequestSyncState) throws -> Data

    init(
        defaults: UserDefaults = .standard,
        syncStateEncoder: @escaping (PullRequestSyncState) throws -> Data = {
            try JSONEncoder().encode($0)
        }
    ) {
        self.defaults = defaults
        self.syncStateEncoder = syncStateEncoder
    }

    var notificationPreferences: NotificationPreferences {
        get {
            decoded(for: "notifications.prMatrix", fallback: .defaults)
        }
        set {
            encode(newValue, for: "notifications.prMatrix")
        }
    }

    /// Loads the saved notification matrix. On first launch, with nothing stored, the defaults are saved. A stored
    /// value that does not decode, such as one saved in an older format, is left untouched and the defaults are
    /// returned until a settings change saves the current format.
    func loadAndPersistNotificationPreferences() -> NotificationPreferences {
        let key = "notifications.prMatrix"
        guard defaults.object(forKey: key) != nil else {
            encode(NotificationPreferences.defaults, for: key)
            return .defaults
        }
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(NotificationPreferences.self, from: data)
        else {
            return .defaults
        }
        return value
    }

    var muteBotNotifications: Bool {
        get { value(for: "notifications.muteBotNotifications", fallback: false) }
        set { defaults.set(newValue, forKey: "notifications.muteBotNotifications") }
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

    var hideArchivedRepositories: Bool {
        get { value(for: "sources.hideArchivedRepositories", fallback: true) }
        set { defaults.set(newValue, forKey: "sources.hideArchivedRepositories") }
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

    var pullRequestSyncState: PullRequestSyncState? {
        guard let data = defaults.data(forKey: "pullRequests.syncState"),
              let value = try? JSONDecoder().decode(PullRequestSyncState.self, from: data),
              value.formatVersion == PullRequestSyncState.currentFormatVersion else {
            return nil
        }
        return value
    }

    /// Storing new state retires the legacy keys, so an unreadable state can never fall back to an old snapshot.
    func storePullRequestSyncState(_ value: PullRequestSyncState) throws {
        let data = try syncStateEncoder(value)
        defaults.set(data, forKey: "pullRequests.syncState")
        defaults.removeObject(forKey: "pullRequests.snapshotCache")
        defaults.removeObject(forKey: "notifications.prHistory")
    }

    func clearPullRequestSyncState() {
        defaults.removeObject(forKey: "pullRequests.syncState")
    }

    /// The legacy snapshot kept only recent comments and reviews, so its fetch time marks everything older
    /// as processed. Without a fetch time there is no safe baseline, and the first refresh starts a new one.
    func importedLegacySyncState() -> PullRequestSyncState? {
        let cache = pullRequestSnapshotCache
        guard let account = cache.account, cache.source == .github else { return nil }
        let processed = cache.fetchedAt.map { fetchedAt in
            Dictionary(cache.pullRequests.map { pr in
                (pr.id, ProcessedPullRequestActivity(
                    pullRequestID: pr.id,
                    commentIDs: Set(pr.recentCommentActivities.map(\.id)),
                    submittedReviewIDs: Set(pr.recentReviews.map(\.id)),
                    processedThrough: fetchedAt
                ))
            }, uniquingKeysWith: { first, _ in first })
        } ?? [:]
        return PullRequestSyncState(
            account: account,
            dashboard: DashboardState(
                pullRequests: cache.pullRequests,
                events: [],
                syncedAt: cache.fetchedAt,
                source: cache.source,
                account: account,
                authStatus: .signedIn
            ),
            processedActivityByPullRequestID: processed,
            notificationHistory: pullRequestNotificationHistory
        )
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

    /// Teams whose review requests the viewer turned off, kept even while the viewer is not in the team.
    var turnedOffReviewTeamIDs: Set<String> {
        get {
            normalizedPullRequestIds(for: "reviewTeams.turnedOffIds")
        }
        set {
            defaults.set(newValue.sorted(), forKey: "reviewTeams.turnedOffIds")
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
