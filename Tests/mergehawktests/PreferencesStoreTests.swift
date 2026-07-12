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
    precondition(store.selectedPullRequestFilters == [])

    store.selectedPullRequestFilters = [.needsAttention, .ciFailing]
    precondition(store.selectedPullRequestFilters == [.needsAttention, .ciFailing])
    precondition(defaults.stringArray(forKey: "pullRequests.filterOptions") == ["needsAttention", "ciFailing"])

    defaults.set(["unsupported", "all", "draft"], forKey: "pullRequests.filterOptions")
    precondition(store.selectedPullRequestFilters == [.draft])
}()

let mergehawkReviewRequestFilterPreferencesTest: Void = {
    let suiteName = "mergehawk-review-request-filter-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.selectedReviewRequestFilters == [])

    store.selectedReviewRequestFilters = [.direct, .assigned, .draft]
    precondition(store.selectedReviewRequestFilters == [.direct, .assigned, .draft])
    precondition(defaults.stringArray(forKey: "reviewRequests.filterOptions") == ["direct", "assigned", "draft"])

    defaults.set(["unsupported", "all", "assigned", "ready"], forKey: "reviewRequests.filterOptions")
    precondition(store.selectedReviewRequestFilters == [.assigned, .ready])
}()

let mergehawkPinnedPullRequestPreferencesTest: Void = {
    let suiteName = "mergehawk-pinned-pr-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.pinnedPullRequestIds == [])

    store.pinnedPullRequestIds = ["pr-3", "pr-1", "pr-2"]
    precondition(store.pinnedPullRequestIds == ["pr-1", "pr-2", "pr-3"])
    precondition(defaults.stringArray(forKey: "pullRequests.pinnedIds") == ["pr-1", "pr-2", "pr-3"])

    defaults.set(["pr-1", "", "  ", "pr-1", "pr-4"], forKey: "pullRequests.pinnedIds")
    precondition(store.pinnedPullRequestIds == ["pr-1", "pr-4"])

    defaults.set([], forKey: "pullRequests.pinnedIds")
    precondition(store.pinnedPullRequestIds == [])
}()

let mergehawkHiddenPullRequestPreferencesTest: Void = {
    let suiteName = "mergehawk-hidden-pr-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.hiddenPullRequestIds == [])

    store.hiddenPullRequestIds = ["pr-3", "pr-1", "pr-2"]
    precondition(store.hiddenPullRequestIds == ["pr-1", "pr-2", "pr-3"])
    precondition(defaults.stringArray(forKey: "pullRequests.hiddenIds") == ["pr-1", "pr-2", "pr-3"])

    defaults.set(["pr-1", "", "  ", "pr-1", "pr-4"], forKey: "pullRequests.hiddenIds")
    precondition(store.hiddenPullRequestIds == ["pr-1", "pr-4"])
}()

let mergehawkSingleSelectFilterPreferencesMigrationTest: Void = {
    let suiteName = "mergehawk-filter-migration-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)

    defaults.set("changesRequested", forKey: "pullRequests.filterOption")
    defaults.set("team", forKey: "reviewRequests.filterOption")
    precondition(store.selectedPullRequestFilters == [.changesRequested])
    precondition(store.selectedReviewRequestFilters == [.team])

    defaults.set("all", forKey: "pullRequests.filterOption")
    defaults.set("all", forKey: "reviewRequests.filterOption")
    precondition(store.selectedPullRequestFilters == [])
    precondition(store.selectedReviewRequestFilters == [])

    defaults.set("unsupported", forKey: "pullRequests.filterOption")
    defaults.set("unsupported", forKey: "reviewRequests.filterOption")
    precondition(store.selectedPullRequestFilters == [])
    precondition(store.selectedReviewRequestFilters == [])
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

let mergehawkPullRequestSnapshotCacheStoreTest: Void = {
    let suiteName = "mergehawk-pr-snapshot-cache-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.pullRequestSnapshotCache == .empty)

    let cache = PullRequestSnapshotCache(
        pullRequests: [
            PullRequest(
                id: "PR_1",
                title: "Persist PR snapshot",
                number: 12,
                url: URL(string: "https://github.com/example/mergehawk/pull/12")!,
                repo: "example/mergehawk",
                ciState: .passing,
                reviewDecision: .reviewRequired,
                commentCount: 0,
                reviewCount: 0,
                isMine: true,
                author: "rw",
                mergeable: .mergeable,
                draft: false
            )
        ],
        account: GitHubAccount(login: "rw"),
        fetchedAt: Date(timeIntervalSince1970: 40),
        source: .github
    )

    store.pullRequestSnapshotCache = cache
    precondition(store.pullRequestSnapshotCache == cache)
    precondition(defaults.data(forKey: "pullRequests.snapshotCache") != nil)
}()

let mergehawkNotificationHistoryStoreTest: Void = {
    let suiteName = "mergehawk-notification-history-store-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    let pullRequest = PullRequest(
        id: "PR_1",
        title: "Persist notification history",
        number: 9,
        url: URL(string: "https://github.com/example/mergehawk/pull/9")!,
        repo: "example/mergehawk",
        ciState: .passing,
        reviewDecision: .reviewRequired,
        commentCount: 1,
        reviewCount: 0,
        isMine: true,
        author: "rw",
        mergeable: .mergeable,
        draft: false
    )
    let prNotification = PullRequestNotification(
        id: "stored-pr",
        event: PullRequestEvent(type: .newComment, prId: "PR_1", count: 1),
        pullRequest: pullRequest,
        createdAt: Date(timeIntervalSince1970: 10)
    )
    let inboxNotification = GitHubInboxNotification(
        threadId: "thread-1",
        repo: "example/app",
        subjectTitle: "Question about sources",
        subjectType: "Issue",
        reason: "mention",
        unread: true,
        updatedAt: Date(timeIntervalSince1970: 20),
        threadURL: URL(string: "https://api.github.com/notifications/threads/1")!,
        webURL: URL(string: "https://github.com/example/app/issues/1")!
    )
    let metadata = GitHubInboxSyncMetadata(
        eTag: #""etag""#,
        lastFetchedAt: Date(timeIntervalSince1970: 30),
        pollIntervalSeconds: 60
    )

    store.pullRequestNotificationHistory = [prNotification]
    store.gitHubInboxNotifications = [inboxNotification]
    store.gitHubInboxSyncMetadata = metadata

    precondition(store.pullRequestNotificationHistory == [prNotification])
    precondition(store.gitHubInboxNotifications == [inboxNotification])
    precondition(store.gitHubInboxSyncMetadata == metadata)
}()

let mergehawkLegacyNotificationHistoryStoreTest: Void = {
    let suiteName = "mergehawk-legacy-notification-history-store-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let legacyPayload = """
    [
      {
        "id": "legacy-pr",
        "eventType": "new_comment",
        "count": 1,
        "prId": "PR_1",
        "prTitle": "Persist legacy notification history",
        "prNumber": 9,
        "repo": "example/mergehawk",
        "url": "https://github.com/example/mergehawk/pull/9",
        "createdAt": 10,
        "prUpdatedAt": 20,
        "read": false
      }
    ]
    """.data(using: .utf8)!
    defaults.set(legacyPayload, forKey: "notifications.prHistory")

    let store = PreferencesStore(defaults: defaults)
    let notifications = store.pullRequestNotificationHistory

    precondition(notifications.count == 1)
    precondition(notifications[0].id == "legacy-pr")
    precondition(notifications[0].actorLogin == nil)
    precondition(notifications[0].activityId == nil)
    precondition(notifications[0].relationshipChanges.isEmpty)
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

let mergehawkNotificationMatrixPreferenceTest: Void = {
    let suiteName = "mergehawk-notification-matrix-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.notificationPreferences == .defaults)
    precondition(defaults.data(forKey: "notifications.prMatrix") == nil)

    let preferences = NotificationPreferences(
        authored: PullRequestNotificationActivityPreferences(
            comments: true,
            reviewActivity: false,
            ciFailures: true
        ),
        assigned: PullRequestNotificationActivityPreferences(
            comments: false,
            reviewActivity: true,
            ciFailures: false
        ),
        directReviewRequests: PullRequestNotificationActivityPreferences(
            comments: true,
            reviewActivity: true,
            ciFailures: false
        ),
        teamReviewRequests: .disabled
    )
    store.notificationPreferences = preferences

    precondition(store.notificationPreferences == preferences)
    precondition(defaults.data(forKey: "notifications.prMatrix") != nil)
}()

let mergehawkLegacyNotificationMatrixPreferenceTest: Void = {
    let suiteName = "mergehawk-legacy-notification-matrix-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let legacyPayload = """
    {
      "authored": {
        "comments": true,
        "reviewActivity": true,
        "ciFailures": true
      },
      "assigned": {
        "comments": false,
        "reviewActivity": false,
        "ciFailures": false
      },
      "directReviewRequests": {
        "comments": false,
        "reviewActivity": false,
        "ciFailures": false
      },
      "teamReviewRequests": {
        "comments": false,
        "reviewActivity": false,
        "ciFailures": false
      }
    }
    """.data(using: .utf8)!
    defaults.set(legacyPayload, forKey: "notifications.prMatrix")

    let preferences = PreferencesStore(defaults: defaults).notificationPreferences

    precondition(preferences.authored.relationshipChanges == false)
    precondition(preferences.authored.otherCommits == false)
    precondition(preferences.assigned.relationshipChanges == false)
    precondition(preferences.assigned.otherCommits == false)
}()

let mergehawkAuthMethodPreferenceTest: Void = {
    let suiteName = "mergehawk-auth-method-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var store = PreferencesStore(defaults: defaults)
    precondition(store.authMethod == .oauth)

    store.authMethod = .pat
    precondition(store.authMethod == .pat)

    defaults.set("unsupported", forKey: "auth.method")
    precondition(store.authMethod == .oauth)
}()
