@testable import mergehawk
import Foundation
import mergehawkcore

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

let mergehawkReviewRequestFilterPreferencesTest: Void = {
    let suiteName = "mergehawk-review-request-filter-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.reviewRequestFilterOption == .direct)

    store.reviewRequestFilterOption = .team
    precondition(store.reviewRequestFilterOption == .team)

    defaults.set("unsupported", forKey: "reviewRequests.filterOption")
    precondition(store.reviewRequestFilterOption == .direct)
}()

let mergehawkSourcePreferencesStoreTest: Void = {
    let suiteName = "mergehawk-source-preferences-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.sourcePreferences == .defaults)

    let preferences = SourcePreferences(
        owners: [
            "example": OwnerSourcePreferences(
                notifications: false,
                myPullRequests: true,
                reviewRequests: false
            )
        ],
        repositories: [
            "example/app": RepositorySourcePreferences(
                notifications: .enabled,
                myPullRequests: .disabled,
                reviewRequests: .inherit
            )
        ]
    )
    store.sourcePreferences = preferences
    precondition(store.sourcePreferences == preferences)
}()

let mergehawkSourceCatalogStoreTest: Void = {
    let suiteName = "mergehawk-source-catalog-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.sourceCatalog == .empty)

    let catalog = SourceCatalog(
        repositories: [
            RepositorySource(owner: "example", name: "app"),
            RepositorySource(owner: "example", name: "mergehawk")
        ],
        accountLogin: "rw"
    )
    store.sourceCatalog = catalog
    precondition(store.sourceCatalog == catalog)
}()

let mergehawkMacOSLocalNotificationPreferenceTest: Void = {
    let suiteName = "mergehawk-macos-local-notification-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.macOSLocalNotificationsEnabled == true)

    store.macOSLocalNotificationsEnabled = false
    precondition(store.macOSLocalNotificationsEnabled == false)
}()
