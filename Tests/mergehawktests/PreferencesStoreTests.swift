@testable import mergehawk
import Foundation

let mergehawkRefreshIntervalPreferencesTest: Void = {
    let suiteName = "mergehawk-refresh-interval-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.refreshIntervalMinutes == 2)

    store.refreshIntervalMinutes = 10
    precondition(store.refreshIntervalMinutes == 10)

    defaults.set(3, forKey: "refresh.intervalMinutes")
    precondition(store.refreshIntervalMinutes == 2)
}()

let mergehawkPullRequestSortPreferencesTest: Void = {
    let suiteName = "mergehawk-pr-sort-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.pullRequestSortOption == .createdDate)

    store.pullRequestSortOption = .updatedDate
    precondition(store.pullRequestSortOption == .updatedDate)

    defaults.set("unsupported", forKey: "pullRequests.sortOption")
    precondition(store.pullRequestSortOption == .createdDate)
}()

let mergehawkPullRequestFilterPreferencesTest: Void = {
    let suiteName = "mergehawk-pr-filter-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.pullRequestFilterOption == .all)

    store.pullRequestFilterOption = .needsAttention
    precondition(store.pullRequestFilterOption == .needsAttention)

    defaults.set("unsupported", forKey: "pullRequests.filterOption")
    precondition(store.pullRequestFilterOption == .all)
}()
