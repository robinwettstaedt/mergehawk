@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

private func archiveFixturePR(
    _ id: String,
    repo: String,
    archived: Bool? = nil,
    isMine: Bool = false,
    assigned: Bool = false,
    request: ReviewRequestKind = .none,
    requestedTeams: [TeamReference] = []
) -> PullRequest {
    PullRequest(
        id: id, title: id, number: 1,
        url: URL(string: "https://github.com/\(repo)/pull/1")!, repo: repo,
        repositoryIsArchived: archived, ciState: .passing, reviewDecision: .reviewRequired,
        commentCount: 0, reviewCount: 0, reviewRequestKind: request, requestedTeams: requestedTeams,
        isAssignedToViewer: assigned, isMine: isMine, author: isMine ? "rw" : "teammate",
        mergeable: .mergeable, draft: false
    )
}

private final class ReviewTeamGitHubProvider: GitHubProviding {
    enum OfflineError: Error, LocalizedError {
        case offline

        var errorDescription: String? { "Offline" }
    }

    let sourceKind: DashboardSource = .github
    /// Nil fails every complete PR refresh, like a machine without network.
    var result: CompletePullRequestFetchResult?
    var viewerLogin = "rw"
    private(set) var fetchCount = 0
    /// The reusable teams each complete PR refresh was handed, nil when it was asked to read teams.
    private(set) var reusableViewerTeams: [[ViewerTeam]?] = []

    init(result: CompletePullRequestFetchResult?) { self.result = result }

    func fetchViewer() async throws -> GitHubAccount { GitHubAccount(login: viewerLogin) }

    func fetchCompletePullRequests(login: String, previousState: PullRequestSyncState?, reusableViewerTeams: [ViewerTeam]?) async throws -> CompletePullRequestFetchResult {
        fetchCount += 1
        self.reusableViewerTeams.append(reusableViewerTeams)
        guard let result else { throw OfflineError.offline }
        return result
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: accountLogin)
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }
}

private final class ControllerTestClock {
    var now: Date

    init(_ now: Date) { self.now = now }
}

private final class ArchiveFixtureGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    let pullRequests: [PullRequest]
    let viewerTeams: [ViewerTeam]
    private(set) var fetchCount = 0

    init(pullRequests: [PullRequest], viewerTeams: [ViewerTeam] = []) {
        self.pullRequests = pullRequests
        self.viewerTeams = viewerTeams
    }

    func fetchViewer() async throws -> GitHubAccount { GitHubAccount(login: "rw") }

    func fetchCompletePullRequests(login: String, previousState: PullRequestSyncState?, reusableViewerTeams: [ViewerTeam]?) async throws -> CompletePullRequestFetchResult {
        fetchCount += 1
        return CompletePullRequestFetchResult(activePullRequests: pullRequests, viewerTeams: viewerTeams)
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: accountLogin)
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }
}

final class DashboardControllerXCTests: XCTestCase {
    @MainActor
    func testArchivedRepositoriesFilterCachedListsHistoryAndCountsWithoutChangingSavedState() throws {
        let suiteName = "archived-filter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var store = PreferencesStore(defaults: defaults)
        store.authMethod = .pat
        let archivedRepo = "archive/app"
        let authored = archiveFixturePR("A", repo: archivedRepo, archived: true, isMine: true)
        let assigned = archiveFixturePR("R1", repo: archivedRepo, archived: true, assigned: true)
        let direct = archiveFixturePR("R2", repo: archivedRepo, archived: true, request: .direct)
        let reviewers = TeamReference(id: "T_REVIEWERS", organization: "archive", slug: "reviewers")
        let viewerTeams = [ViewerTeam(team: reviewers)]
        let team = archiveFixturePR(
            "R3", repo: archivedRepo, archived: true, request: .team, requestedTeams: [reviewers]
        )
        let active = archiveFixturePR("B", repo: "active/app", archived: false, isMine: true)
        let unknown = archiveFixturePR("U", repo: "unknown/app", request: .direct)
        let pullRequests = [authored, assigned, direct, team, active, unknown]
        let preferences = SourcePreferences(
            owners: ["archive": OwnerSourcePreferences(notifications: false, myPullRequests: false, reviewRequests: false)],
            repositories: [archivedRepo: RepositorySourcePreferences(
                notifications: .enabled, myPullRequests: .enabled, reviewRequests: .enabled
            )]
        )
        store.sourcePreferences = preferences
        var archivedHistory = PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: authored.id, activityId: "ARCHIVED"),
            pullRequest: authored
        )
        archivedHistory.read = false
        var activeHistory = PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: active.id, activityId: "ACTIVE"),
            pullRequest: active
        )
        activeHistory.read = true
        let orphan = archiveFixturePR("OLD", repo: "old/app", archived: true)
        let orphanHistory = PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: orphan.id, activityId: "OLD"),
            pullRequest: orphan
        )
        let account = GitHubAccount(login: "rw")
        let state = PullRequestSyncState(
            account: account,
            dashboard: DashboardState(
                pullRequests: pullRequests, events: [], syncedAt: Date(timeIntervalSince1970: 10),
                source: .github, account: account, authStatus: .signedIn, viewerTeams: viewerTeams
            ),
            processedActivityByPullRequestID: [:],
            notificationHistory: [archivedHistory, activeHistory, orphanHistory]
        )
        try store.storePullRequestSyncState(state)
        let provider = ArchiveFixtureGitHubProvider(pullRequests: pullRequests, viewerTeams: viewerTeams)
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in provider }
        )
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }
        controller.pinnedPullRequestIds = [authored.id]
        controller.hiddenPullRequestIds = [direct.id]

        XCTAssertTrue(controller.hideArchivedRepositories)
        XCTAssertEqual(controller.sourceFilteredMyPullRequests.map(\.id), [active.id])
        XCTAssertEqual(controller.requestedSections.map(\.count), [0, 1, 0])
        XCTAssertTrue(controller.hiddenReviewRequests.isEmpty)
        XCTAssertEqual(Set(controller.visiblePullRequestNotifications.map(\.activityId)), ["ACTIVE", "OLD"])
        XCTAssertEqual(controller.attentionCount, 1)
        XCTAssertEqual(controller.pullRequestNotificationHistory.count, 3)

        let committed = try XCTUnwrap(store.pullRequestSyncState)
        controller.hideArchivedRepositories = false
        XCTAssertEqual(Set(controller.sourceFilteredMyPullRequests.map(\.id)), [authored.id, active.id])
        XCTAssertEqual(controller.requestedSections.map(\.count), [1, 2, 1])
        XCTAssertEqual(controller.hiddenReviewRequests.map(\.id), [direct.id])
        XCTAssertEqual(Set(controller.visiblePullRequestNotifications.map(\.activityId)), ["ARCHIVED", "ACTIVE", "OLD"])
        XCTAssertEqual(controller.attentionCount, 2)
        XCTAssertEqual(controller.sortedMyPullRequests.first?.id, authored.id)
        XCTAssertEqual(PreferencesStore(defaults: defaults).sourcePreferences, preferences)
        XCTAssertEqual(store.pullRequestSyncState, committed)
        XCTAssertEqual(provider.fetchCount, 1)

        controller.hideArchivedRepositories = true
        XCTAssertEqual(controller.sourceFilteredMyPullRequests.map(\.id), [active.id])
        XCTAssertEqual(store.pullRequestSyncState, committed)
        XCTAssertEqual(provider.fetchCount, 1)
    }
    func testEveryMockScenarioReturnsViewerTeamsNamedByItsTeamRequestedPRs() async throws {
        for scenario in MockPullRequestScenario.allCases {
            let source = MockPullRequestSource(scenario: scenario)
            var fetchedPullRequests = source.firstRefreshPullRequests
            for _ in 0..<3 {
                guard let result = try? await source.fetchCompletePullRequests(
                    login: "agent-fixture",
                    previousState: nil,
                    reusableViewerTeams: nil
                ) else { break }
                XCTAssertFalse(result.viewerTeams.isEmpty, scenario.rawValue)
                XCTAssertEqual(result.viewerTeams, source.viewerTeams, scenario.rawValue)
                fetchedPullRequests += result.activePullRequests + result.retiringPullRequests
            }
            let viewerTeamIDs = Set(source.viewerTeams.map(\.team.id))
            for pullRequest in fetchedPullRequests where pullRequest.reviewRequestKind.includesTeam {
                XCTAssertTrue(
                    pullRequest.requestedTeams.contains { viewerTeamIDs.contains($0.id) },
                    "\(scenario.rawValue) \(pullRequest.id)"
                )
            }
        }
    }

    func testReviewTeamsScenarioHasNestedTeamsAndSecondRefreshAddsPlmTeam() async throws {
        let source = MockPullRequestSource(scenario: .reviewTeams)

        let first = try await source.fetchCompletePullRequests(login: "agent-fixture", previousState: nil, reusableViewerTeams: nil)
        let second = try await source.fetchCompletePullRequests(login: "agent-fixture", previousState: nil, reusableViewerTeams: nil)

        XCTAssertEqual(first.viewerTeams.filter { $0.team.organization == "mergehawk-labs" }.map(\.team.displayName), [
            "@mergehawk-labs/developers", "@mergehawk-labs/engineering", "@mergehawk-labs/plm-team",
            "@mergehawk-labs/secret-squad"
        ])
        // Two more organizations show sibling and deep nesting; no PR requests their teams.
        let otherTeams = first.viewerTeams.filter { $0.team.organization != "mergehawk-labs" }
        XCTAssertEqual(otherTeams.map(\.team.displayName), [
            "@northwind-apps/frontend", "@northwind-apps/design-system", "@northwind-apps/mobile",
            "@northwind-apps/web", "@northwind-apps/qa", "@northwind-apps/release-checks",
            "@zenith-infra/platform", "@zenith-infra/runtime", "@zenith-infra/scheduler",
            "@zenith-infra/queue-workers", "@zenith-infra/observability",
        ])
        XCTAssertEqual(otherTeams.map(\.parentTeamID), [
            nil, "T_MOCK_NW_FRONTEND", "T_MOCK_NW_FRONTEND", "T_MOCK_NW_FRONTEND", nil, "T_MOCK_NW_QA",
            nil, "T_MOCK_ZI_PLATFORM", "T_MOCK_ZI_RUNTIME", "T_MOCK_ZI_SCHEDULER", "T_MOCK_ZI_PLATFORM",
        ])
        XCTAssertEqual(otherTeams.map(\.team.id), [
            "T_MOCK_NW_FRONTEND", "T_MOCK_NW_DESIGN_SYSTEM", "T_MOCK_NW_MOBILE", "T_MOCK_NW_WEB", "T_MOCK_NW_QA",
            "T_MOCK_NW_RELEASE_CHECKS", "T_MOCK_ZI_PLATFORM", "T_MOCK_ZI_RUNTIME", "T_MOCK_ZI_SCHEDULER",
            "T_MOCK_ZI_QUEUE_WORKERS", "T_MOCK_ZI_OBSERVABILITY",
        ])
        XCTAssertEqual(first.viewerTeams.first { $0.team.slug == "developers" }?.parentTeamID, "T_MOCK_ENGINEERING")
        XCTAssertEqual(first.viewerTeams.first { $0.team.slug == "plm-team" }?.parentTeamID, "T_MOCK_DEVELOPERS")
        XCTAssertNil(first.viewerTeams.first { $0.team.slug == "engineering" }?.parentTeamID)
        XCTAssertNil(first.viewerTeams.first { $0.team.slug == "secret-squad" }?.parentTeamID)
        XCTAssertFalse(first.viewerTeams.contains { $0.team.slug == "security" })
        let firstTeams = Dictionary(uniqueKeysWithValues: first.activePullRequests.map { ($0.id, $0.requestedTeams.map(\.slug)) })
        XCTAssertEqual(firstTeams["PR_TEAMS_DEVELOPERS"], ["developers"])
        XCTAssertEqual(firstTeams["PR_TEAMS_SECURITY"], ["security"])
        XCTAssertEqual(firstTeams["PR_TEAMS_DEVELOPERS_SECURITY"], ["developers", "security"])
        XCTAssertEqual(firstTeams["PR_TEAMS_DEVELOPERS_PLM"], ["developers", "plm-team"])
        XCTAssertEqual(
            first.activePullRequests.first { $0.id == "PR_TEAMS_DIRECT_DEVELOPERS" }?.reviewRequestKind,
            .directAndTeam
        )
        let secondTeams = Dictionary(uniqueKeysWithValues: second.activePullRequests.map { ($0.id, $0.requestedTeams.map(\.slug)) })
        XCTAssertEqual(secondTeams["PR_TEAMS_DEVELOPERS"], ["developers", "plm-team"])
        XCTAssertEqual(
            secondTeams.filter { $0.key != "PR_TEAMS_DEVELOPERS" },
            firstTeams.filter { $0.key != "PR_TEAMS_DEVELOPERS" }
        )
    }

    // MARK: Review teams

    private static let engineering = TeamReference(id: "T_ENG", organization: "acme", slug: "engineering")
    private static let developers = TeamReference(id: "T_DEV", organization: "acme", slug: "developers")
    private static let plmTeam = TeamReference(id: "T_PLM", organization: "acme", slug: "plm-team")
    private static let nestedViewerTeams = [
        ViewerTeam(team: developers, parentTeamID: engineering.id),
        ViewerTeam(team: engineering),
        ViewerTeam(team: plmTeam, parentTeamID: developers.id)
    ]

    private static func teamPR(
        _ id: String,
        _ teams: [TeamReference],
        direct: Bool = false,
        assigned: Bool = false,
        isMine: Bool = false
    ) -> PullRequest {
        archiveFixturePR(
            id, repo: "acme/app", isMine: isMine, assigned: assigned,
            request: ReviewRequestKind(direct: direct, team: !teams.isEmpty), requestedTeams: teams
        )
    }

    @MainActor
    private static func requestedIDs(
        _ controller: DashboardController
    ) -> [DashboardController.RequestedSection: [String]] {
        Dictionary(uniqueKeysWithValues: controller.requestedSections.map {
            ($0.section, ($0.visible + $0.hidden).map(\.id).sorted())
        })
    }

    @MainActor
    private static func makeReviewTeamController(
        defaults: UserDefaults,
        provider: ReviewTeamGitHubProvider,
        notifications: RecordingNotificationClient = RecordingNotificationClient(),
        automaticRefreshInterval: TimeInterval = 0,
        now: @escaping () -> Date = Date.init
    ) -> DashboardController {
        var store = PreferencesStore(defaults: defaults)
        store.authMethod = .pat
        return DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: store,
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            notificationClient: notifications,
            automaticRefreshInterval: automaticRefreshInterval,
            patGitHubClientFactory: { _ in provider },
            now: now
        )
    }

    @MainActor
    private static func refreshAndWait(_ controller: DashboardController, _ provider: ReviewTeamGitHubProvider) {
        let count = provider.fetchCount
        controller.refresh()
        waitUntil(timeout: 1) { provider.fetchCount == count + 1 && !controller.isRefreshing }
    }

    @MainActor
    func testTurningATeamOffAndOnChangesRequestedImmediatelyWithoutNotifications() throws {
        let suiteName = "review-teams-toggle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notifications = RecordingNotificationClient()
        let provider = ReviewTeamGitHubProvider(result: CompletePullRequestFetchResult(
            activePullRequests: [Self.teamPR("PR_DEV", [Self.developers]), Self.teamPR("PR_PLM", [Self.plmTeam])],
            viewerTeams: Self.nestedViewerTeams
        ))
        let controller = Self.makeReviewTeamController(defaults: defaults, provider: provider, notifications: notifications)
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }
        let storedState = PreferencesStore(defaults: defaults).pullRequestSyncState
        XCTAssertEqual(Self.requestedIDs(controller)[.team], ["PR_DEV", "PR_PLM"])

        controller.setReviewTeam(Self.developers.id, counting: false)
        XCTAssertEqual(Self.requestedIDs(controller)[.team], ["PR_PLM"])

        controller.setReviewTeam(Self.developers.id, counting: true)
        XCTAssertEqual(Self.requestedIDs(controller)[.team], ["PR_DEV", "PR_PLM"])
        XCTAssertTrue(controller.pullRequestNotificationHistory.isEmpty)
        XCTAssertTrue(notifications.records.isEmpty)
        XCTAssertEqual(PreferencesStore(defaults: defaults).pullRequestSyncState, storedState)
    }

    @MainActor
    func testDirectRequestWithTurnedOffTeamStaysUnderDirect() throws {
        let suiteName = "review-teams-direct-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = ReviewTeamGitHubProvider(result: CompletePullRequestFetchResult(
            activePullRequests: [Self.teamPR("PR_DIRECT_DEV", [Self.developers], direct: true)],
            viewerTeams: Self.nestedViewerTeams
        ))
        let controller = Self.makeReviewTeamController(defaults: defaults, provider: provider)
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }

        controller.setReviewTeam(Self.developers.id, counting: false)

        XCTAssertEqual(Self.requestedIDs(controller)[.direct], ["PR_DIRECT_DEV"])
        XCTAssertEqual(Self.requestedIDs(controller)[.team], [])
    }

    @MainActor
    func testRelaunchedControllerWithoutNetworkShowsStoredRequestedSectionsAndTeamRows() throws {
        let suiteName = "review-teams-relaunch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = ReviewTeamGitHubProvider(result: CompletePullRequestFetchResult(
            activePullRequests: [
                Self.teamPR("PR_DEV", [Self.developers]),
                Self.teamPR("PR_ENG", [Self.engineering]),
                Self.teamPR("PR_DIRECT_DEV", [Self.developers], direct: true)
            ],
            viewerTeams: Self.nestedViewerTeams
        ))
        let controller = Self.makeReviewTeamController(defaults: defaults, provider: provider)
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }
        controller.setReviewTeam(Self.developers.id, counting: false)
        let sections = Self.requestedIDs(controller)
        let rows = controller.reviewTeamRows

        let offline = ReviewTeamGitHubProvider(result: nil)
        let relaunched = Self.makeReviewTeamController(defaults: defaults, provider: offline)
        waitUntil(timeout: 1) { relaunched.refreshErrorMessage != nil }

        XCTAssertEqual(sections, [.assigned: [], .direct: ["PR_DIRECT_DEV"], .team: ["PR_ENG"]])
        XCTAssertEqual(Self.requestedIDs(relaunched), sections)
        XCTAssertEqual(relaunched.reviewTeamRows, rows)
        XCTAssertEqual(relaunched.state.viewerTeams, Self.nestedViewerTeams)
    }

    @MainActor
    func testTeamRowsFormATreeWithCountingStateAndPRCountsAcrossAllFetchedPRs() throws {
        let api = TeamReference(id: "T_API", organization: "acme", slug: "api")
        let secret = TeamReference(id: "T_SECRET", organization: "acme", slug: "secret-squad")
        let ops = TeamReference(id: "T_OPS", organization: "zeta", slug: "ops")
        let suiteName = "review-teams-rows-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = ReviewTeamGitHubProvider(result: CompletePullRequestFetchResult(
            activePullRequests: [
                Self.teamPR("PR_AUTHORED", [Self.developers], isMine: true),
                Self.teamPR("PR_ASSIGNED", [Self.developers, Self.plmTeam], assigned: true),
                Self.teamPR("PR_DIRECT", [Self.plmTeam], direct: true),
                Self.teamPR("PR_TEAM", [Self.developers])
            ],
            viewerTeams: Self.nestedViewerTeams + [
                // Its parent is not one of the viewer's teams, so it is top level.
                ViewerTeam(team: secret, parentTeamID: "T_NOT_A_VIEWER_TEAM"),
                ViewerTeam(team: api, parentTeamID: Self.engineering.id),
                ViewerTeam(
                    team: ops,
                    avatarURL: URL(string: "https://avatars.githubusercontent.com/t/7?s=64&v=4"),
                    organizationAvatarURL: URL(string: "https://avatars.githubusercontent.com/u/8?v=4")
                )
            ]
        ))
        let controller = Self.makeReviewTeamController(defaults: defaults, provider: provider)
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }

        controller.setReviewTeam(Self.developers.id, counting: false)

        typealias Row = DashboardController.ReviewTeamRow
        XCTAssertEqual(controller.reviewTeamRows, [
            Row(team: Self.engineering, depth: 0, isCounting: true, pullRequestCount: 0),
            Row(team: api, depth: 1, isCounting: true, pullRequestCount: 0),
            Row(team: Self.developers, depth: 1, isCounting: false, pullRequestCount: 3),
            Row(team: Self.plmTeam, depth: 2, isCounting: true, pullRequestCount: 2),
            Row(team: secret, depth: 0, isCounting: true, pullRequestCount: 0),
            Row(
                team: ops, depth: 0, isCounting: true, pullRequestCount: 0,
                avatarURL: URL(string: "https://avatars.githubusercontent.com/t/7?s=64&v=4"),
                organizationAvatarURL: URL(string: "https://avatars.githubusercontent.com/u/8?v=4")
            ),
        ])
    }

    @MainActor
    func testTurnedOffTeamSurvivesRenameLeavingAndRejoining() throws {
        let suiteName = "review-teams-membership-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = ReviewTeamGitHubProvider(result: CompletePullRequestFetchResult(
            activePullRequests: [],
            viewerTeams: Self.nestedViewerTeams
        ))
        let controller = Self.makeReviewTeamController(defaults: defaults, provider: provider)
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }
        controller.setReviewTeam(Self.developers.id, counting: false)
        controller.setReviewTeam("T_FORMER", counting: false)
        XCTAssertFalse(controller.reviewTeamRows.contains { $0.id == "T_FORMER" })

        let renamed = TeamReference(id: Self.developers.id, organization: "acme", slug: "all-developers")
        provider.result = CompletePullRequestFetchResult(
            activePullRequests: [],
            viewerTeams: [ViewerTeam(team: renamed), ViewerTeam(team: Self.plmTeam, parentTeamID: renamed.id)]
        )
        Self.refreshAndWait(controller, provider)
        let renamedRow = try XCTUnwrap(controller.reviewTeamRows.first { $0.id == Self.developers.id })
        XCTAssertEqual(renamedRow.team.slug, "all-developers")
        XCTAssertFalse(renamedRow.isCounting)

        provider.result = CompletePullRequestFetchResult(activePullRequests: [], viewerTeams: [])
        Self.refreshAndWait(controller, provider)
        XCTAssertTrue(controller.reviewTeamRows.isEmpty)
        XCTAssertEqual(controller.turnedOffReviewTeamIDs, [Self.developers.id, "T_FORMER"])

        provider.result = CompletePullRequestFetchResult(activePullRequests: [], viewerTeams: Self.nestedViewerTeams)
        Self.refreshAndWait(controller, provider)
        XCTAssertEqual(controller.reviewTeamRows.first { $0.id == Self.developers.id }?.isCounting, false)
        XCTAssertEqual(PreferencesStore(defaults: defaults).turnedOffReviewTeamIDs, [Self.developers.id, "T_FORMER"])
    }

    @MainActor
    func testSuccessfulRefreshCommitsAndStoresTheTeamReadTime() throws {
        let suiteName = "review-teams-read-time-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let readAt = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = ReviewTeamGitHubProvider(result: CompletePullRequestFetchResult(
            activePullRequests: [],
            viewerTeams: Self.nestedViewerTeams
        ))
        let controller = Self.makeReviewTeamController(defaults: defaults, provider: provider, now: { readAt })
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }

        XCTAssertEqual(provider.reusableViewerTeams, [nil])
        XCTAssertEqual(controller.state.viewerTeamsReadAt, readAt)
        XCTAssertEqual(PreferencesStore(defaults: defaults).pullRequestSyncState?.dashboard.viewerTeamsReadAt, readAt)
    }

    @MainActor
    func testAutomaticRefreshWithinHalfAnHourHandsTheStoredTeamsToTheSource() throws {
        let suiteName = "review-teams-reuse-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let clock = ControllerTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = ReviewTeamGitHubProvider(result: CompletePullRequestFetchResult(
            activePullRequests: [],
            viewerTeams: Self.nestedViewerTeams
        ))
        let controller = Self.makeReviewTeamController(
            defaults: defaults,
            provider: provider,
            automaticRefreshInterval: 0.05,
            now: { clock.now }
        )
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }
        clock.now += 10 * 60

        waitUntil(timeout: 1) { provider.fetchCount >= 2 && !controller.isRefreshing }

        XCTAssertEqual(Array(provider.reusableViewerTeams.prefix(2)), [nil, Self.nestedViewerTeams])
        XCTAssertEqual(controller.state.viewerTeamsReadAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    @MainActor
    func testRefreshTeamsReadsTeamsDespiteFreshStoredTeamsAndPublishesThem() throws {
        let suiteName = "review-teams-forced-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let clock = ControllerTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = ReviewTeamGitHubProvider(result: CompletePullRequestFetchResult(
            activePullRequests: [],
            viewerTeams: [ViewerTeam(team: Self.engineering)]
        ))
        let controller = Self.makeReviewTeamController(defaults: defaults, provider: provider, now: { clock.now })
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }
        provider.result = CompletePullRequestFetchResult(activePullRequests: [], viewerTeams: Self.nestedViewerTeams)
        clock.now += 60

        controller.refreshTeams()
        waitUntil(timeout: 1) { provider.fetchCount == 2 && !controller.isRefreshing }

        XCTAssertEqual(provider.reusableViewerTeams, [nil, nil])
        XCTAssertEqual(
            controller.reviewTeamRows.map(\.id),
            [Self.engineering.id, Self.developers.id, Self.plmTeam.id]
        )
        XCTAssertEqual(controller.state.viewerTeamsReadAt, clock.now)
    }

    @MainActor
    func testFirstRefreshAfterSwitchingAccountsReadsTeams() async throws {
        let suiteName = "review-teams-switch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = ReviewTeamGitHubProvider(result: CompletePullRequestFetchResult(
            activePullRequests: [],
            viewerTeams: Self.nestedViewerTeams
        ))
        let controller = Self.makeReviewTeamController(defaults: defaults, provider: provider)
        await Self.waitAsync { provider.fetchCount == 1 && !controller.isRefreshing }
        controller.refresh()
        await Self.waitAsync { provider.fetchCount == 2 && !controller.isRefreshing }

        controller.signOut()
        await Self.waitAsync { !controller.isRefreshing }
        provider.viewerLogin = "someone-else"
        await controller.signInWithToken("github_pat_other")

        XCTAssertEqual(controller.state.account?.login, "someone-else")
        XCTAssertEqual(provider.reusableViewerTeams, [nil, Self.nestedViewerTeams, nil])
    }

    @MainActor
    func testFailedRefreshTeamsKeepsTheCommittedTeamsAndShowsTheError() throws {
        let suiteName = "review-teams-forced-failure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let clock = ControllerTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = ReviewTeamGitHubProvider(result: CompletePullRequestFetchResult(
            activePullRequests: [Self.teamPR("PR_DEV", [Self.developers])],
            viewerTeams: Self.nestedViewerTeams
        ))
        let controller = Self.makeReviewTeamController(defaults: defaults, provider: provider, now: { clock.now })
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }
        let state = controller.state
        let rows = controller.reviewTeamRows
        let stored = PreferencesStore(defaults: defaults).pullRequestSyncState
        provider.result = nil
        clock.now += 60

        controller.refreshTeams()
        waitUntil(timeout: 1) { provider.fetchCount == 2 && !controller.isRefreshing }

        XCTAssertEqual(provider.reusableViewerTeams, [nil, nil])
        XCTAssertEqual(controller.refreshErrorMessage, "Offline")
        XCTAssertEqual(controller.state, state)
        XCTAssertEqual(controller.reviewTeamRows, rows)
        XCTAssertEqual(PreferencesStore(defaults: defaults).pullRequestSyncState, stored)
        XCTAssertEqual(stored?.dashboard.viewerTeamsReadAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    @MainActor
    private static func waitAsync(timeout: TimeInterval = 1, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testStandardMockScenarioRequestedSectionsAreUnchangedWithNoTeamsTurnedOff() async throws {
        let suiteName = "review-teams-standard-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0
        )
        try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }

        let rawSections = Dictionary(grouping: controller.state.pullRequests.filter {
            DashboardController.RequestedSection.section(for: $0) != nil
        }) { DashboardController.RequestedSection.section(for: $0)! }.mapValues { $0.map(\.id).sorted() }
        XCTAssertEqual(rawSections[.team]?.isEmpty, false)
        for section in DashboardController.RequestedSection.allCases {
            XCTAssertEqual(Self.requestedIDs(controller)[section], rawSections[section] ?? [], section.rawValue)
        }
    }

    @MainActor
    func testReviewTeamsMockScenarioNotifiesForGainedPlmTeamOnlyWhileDevelopersIsOff() async throws {
        for developersOff in [true, false] {
            let suiteName = "review-teams-mock-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let notifications = RecordingNotificationClient()
            let controller = DashboardController(
                tokenStore: InMemoryTokenStore(),
                preferencesStore: PreferencesStore(defaults: defaults),
                launchConfiguration: LaunchConfiguration(
                    usesMockData: true,
                    suppressesMacOSNotifications: true,
                    mockPullRequestScenario: .reviewTeams
                ),
                notificationClient: notifications,
                automaticRefreshInterval: 0
            )
            try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }
            let firstSyncedAt = controller.state.syncedAt
            XCTAssertTrue(controller.pullRequestNotificationHistory.isEmpty)
            controller.setReviewTeam("T_MOCK_DEVELOPERS", counting: !developersOff)

            controller.refresh()
            try await waitUntilAsync { controller.state.syncedAt != firstSyncedAt && !controller.isRefreshing }

            let history = controller.pullRequestNotificationHistory
            if developersOff {
                XCTAssertEqual(history.map(\.prId), ["PR_TEAMS_DEVELOPERS"])
                XCTAssertEqual(history.first?.eventType, .relationshipAdded)
                XCTAssertEqual(history.first?.relationshipChanges, [.teamReviewRequest])
                XCTAssertEqual(notifications.records.map(\.pullRequestId), ["PR_TEAMS_DEVELOPERS"])
            } else {
                XCTAssertTrue(history.isEmpty)
                XCTAssertTrue(notifications.records.isEmpty)
            }
        }
    }

    @MainActor
    func testChangeSizeSortUsesTotalCountsAndTreatsUnknownAsZeroWithinPins() {
        func pullRequest(
            _ id: String,
            number: Int,
            repo: String = "acme/app",
            additions: Int?,
            deletions: Int?,
            createdAt: TimeInterval
        ) -> PullRequest {
            PullRequest(
                id: id,
                title: id,
                number: number,
                url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
                repo: repo,
                ciState: .unknown,
                reviewDecision: .unknown,
                additions: additions,
                deletions: deletions,
                commentCount: 0,
                reviewCount: 0,
                isMine: true,
                author: "rw",
                mergeable: .unknown,
                draft: false,
                createdAt: Date(timeIntervalSince1970: createdAt)
            )
        }

        let balanced = pullRequest("balanced", number: 1, additions: 90, deletions: 90, createdAt: 100)
        let highNet = pullRequest("high-net", number: 2, repo: "zeta/app", additions: 100, deletions: 0, createdAt: 200)
        let tied = pullRequest("tied", number: 3, repo: "alpha/app", additions: 20, deletions: 80, createdAt: 200)
        let zero = pullRequest("zero", number: 4, additions: 0, deletions: 0, createdAt: 50)
        let missingAdditions = pullRequest("missing-additions", number: 5, additions: nil, deletions: 2, createdAt: 300)
        let unknown = pullRequest("unknown", number: 6, additions: nil, deletions: nil, createdAt: 400)
        let missingDeletions = pullRequest("missing-deletions", number: 7, additions: 2, deletions: nil, createdAt: 350)
        let pullRequests = [missingAdditions, highNet, zero, balanced, unknown, tied, missingDeletions]

        XCTAssertEqual(
            DashboardController.sorted(pullRequests, by: .changeSize, direction: .descending).map(\.id),
            ["balanced", "tied", "high-net", "unknown", "missing-deletions", "missing-additions", "zero"]
        )
        XCTAssertEqual(
            DashboardController.sorted(pullRequests, by: .changeSize, direction: .ascending).map(\.id),
            ["unknown", "missing-deletions", "missing-additions", "zero", "tied", "high-net", "balanced"]
        )
        XCTAssertEqual(
            DashboardController.sortedWithPins(
                pullRequests,
                pinnedIds: ["zero", "unknown", "missing-deletions"],
                by: .changeSize,
                direction: .descending
            ).map(\.id),
            ["unknown", "missing-deletions", "zero", "balanced", "tied", "high-net", "missing-additions"]
        )
        XCTAssertEqual(
            DashboardController.sortedWithPins(
                pullRequests,
                pinnedIds: ["zero", "unknown", "missing-deletions"],
                by: .changeSize,
                direction: .ascending
            ).map(\.id),
            ["unknown", "missing-deletions", "zero", "missing-additions", "tied", "high-net", "balanced"]
        )
    }

    @MainActor
    func testChangeSizeSortAppliesToAuthoredRequestedSectionsAndHiddenRows() {
        let suiteName = "change-size-sort-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0
        )
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil }

        controller.pullRequestSortOption = .changeSize
        controller.reviewRequestSortOption = .changeSize
        XCTAssertEqual(controller.sortedMyPullRequests.map(\.id), ["PR_4", "PR_6", "PR_1"])
        XCTAssertEqual(controller.requestedSections[1].visible.map(\.id), ["PR_5", "PR_2"])

        controller.pullRequestSortDirection = .ascending
        controller.reviewRequestSortDirection = .ascending
        XCTAssertEqual(controller.sortedMyPullRequests.map(\.id), ["PR_6", "PR_1", "PR_4"])
        XCTAssertEqual(controller.requestedSections[1].visible.map(\.id), ["PR_2", "PR_5"])

        controller.pinnedPullRequestIds = ["PR_5"]
        XCTAssertEqual(controller.requestedSections[1].visible.map(\.id), ["PR_5", "PR_2"])

        controller.hiddenPullRequestIds = ["PR_2", "PR_5"]
        XCTAssertEqual(controller.requestedSections[1].hidden.map(\.id), ["PR_2", "PR_5"])
        controller.reviewRequestSortDirection = .descending
        XCTAssertEqual(controller.requestedSections[1].hidden.map(\.id), ["PR_5", "PR_2"])

        controller.hiddenPullRequestIds = []
        controller.pinnedPullRequestIds = []
        controller.refresh()
        waitUntil(timeout: 1.0) {
            controller.state.pullRequests.first(where: { $0.id == "PR_2" })?.isAssignedToViewer == true
        }
        XCTAssertEqual(controller.requestedSections[0].visible.map(\.id), ["PR_2", "PR_7"])
        controller.reviewRequestSortDirection = .ascending
        XCTAssertEqual(controller.requestedSections[0].visible.map(\.id), ["PR_7", "PR_2"])
    }

    @MainActor
    func testAuthoredAndRequestedSortSettingsStayIndependentAcrossTabsAndHiddenRows() {
        let suiteName = "independent-pr-sorts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0
        )
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil }

        controller.pullRequestSortOption = .changeSize
        controller.pullRequestSortDirection = .ascending
        XCTAssertEqual(controller.sortedMyPullRequests.map(\.id), ["PR_6", "PR_1", "PR_4"])
        XCTAssertEqual(controller.requestedSections[1].visible.map(\.id), ["PR_5", "PR_2"])

        controller.selectedTab = .reviewRequests
        controller.reviewRequestSortOption = .changeSize
        controller.reviewRequestSortDirection = .ascending
        XCTAssertEqual(controller.requestedSections[1].visible.map(\.id), ["PR_2", "PR_5"])
        controller.hiddenPullRequestIds = ["PR_2", "PR_5"]
        XCTAssertEqual(controller.requestedSections[1].hidden.map(\.id), ["PR_2", "PR_5"])
        controller.reviewRequestSortDirection = .descending
        XCTAssertEqual(controller.requestedSections[1].hidden.map(\.id), ["PR_5", "PR_2"])

        controller.selectedTab = .myPRs
        XCTAssertEqual(controller.pullRequestSortOption, .changeSize)
        XCTAssertEqual(controller.pullRequestSortDirection, .ascending)
        XCTAssertEqual(controller.sortedMyPullRequests.map(\.id), ["PR_6", "PR_1", "PR_4"])
        let reopened = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reopened.pullRequestSortOption, .changeSize)
        XCTAssertEqual(reopened.pullRequestSortDirection, .ascending)
        XCTAssertEqual(reopened.reviewRequestSortOption, .changeSize)
        XCTAssertEqual(reopened.reviewRequestSortDirection, .descending)
    }

    @MainActor
    func testOptionDisclosureUsesClickedSectionStateForAllSections() {
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0
        )

        controller.toggleRequestedSection(.direct)
        XCTAssertEqual(controller.collapsedRequestedSections, [.direct])
        controller.toggleAllRequestedSections(from: .direct)
        XCTAssertTrue(controller.collapsedRequestedSections.isEmpty)

        controller.toggleRequestedSection(.assigned)
        controller.toggleRequestedSection(.team)
        XCTAssertEqual(controller.collapsedRequestedSections, [.assigned, .team])
        controller.toggleAllRequestedSections(from: .direct)
        XCTAssertEqual(controller.collapsedRequestedSections, Set(DashboardController.RequestedSection.allCases))

        controller.toggleAllRequestedSections(from: .assigned)
        XCTAssertTrue(controller.collapsedRequestedSections.isEmpty)
    }

    @MainActor
    func testRequestedSectionsKeepPrioritySortPinsAndSessionCollapse() {
        let suiteName = "requested-sections-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0
        )
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil }

        XCTAssertEqual(controller.requestedSections.map(\.section), [.assigned, .direct, .team])
        XCTAssertEqual(controller.requestedSections.map { $0.visible.map(\.id) }, [["PR_7"], ["PR_5", "PR_2"], ["PR_3"]])
        XCTAssertEqual(controller.requestedSections.map(\.count), [1, 2, 1])

        controller.pinnedPullRequestIds = ["PR_2"]
        XCTAssertEqual(controller.requestedSections[1].visible.map(\.id), ["PR_2", "PR_5"])
        controller.reviewRequestSortDirection = .ascending
        XCTAssertEqual(controller.requestedSections[1].visible.map(\.id), ["PR_2", "PR_5"])

        controller.toggleRequestedSection(.direct)
        XCTAssertFalse(controller.isRequestedSectionExpanded(.direct))
        XCTAssertTrue(controller.isRequestedSectionExpanded(.assigned))
        controller.selectedTab = .myPRs
        controller.selectedTab = .reviewRequests
        controller.refresh()
        waitUntil(timeout: 1.0) {
            controller.state.pullRequests.first(where: { $0.id == "PR_2" })?.isAssignedToViewer == true
        }
        XCTAssertFalse(controller.isRequestedSectionExpanded(.direct))
        XCTAssertEqual(controller.requestedSections.map { $0.visible.map(\.id) }, [["PR_2", "PR_7"], ["PR_5"], ["PR_3"]])
        let visibleIds = controller.requestedSections.flatMap { $0.visible.map(\.id) }
        XCTAssertEqual(visibleIds.count, Set(visibleIds).count)
        controller.toggleRequestedSection(.direct)
        XCTAssertTrue(controller.isRequestedSectionExpanded(.direct))
    }

    @MainActor
    func testRequestedSectionsKeepHiddenCountsAndShowEmptyAfterFiltersAndSources() {
        let suiteName = "requested-sections-hidden-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0
        )
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil }

        controller.selectedReviewRequestFilters = [.draft]
        XCTAssertEqual(controller.requestedSections.map(\.count), [0, 0, 1])
        controller.hiddenPullRequestIds = ["PR_3"]
        XCTAssertEqual(controller.requestedSections[2].visible.count, 0)
        XCTAssertEqual(controller.requestedSections[2].hidden.map(\.id), ["PR_3"])
        XCTAssertEqual(controller.requestedSections.map(\.count), [0, 0, 1])

        controller.selectedReviewRequestFilters = [.ready]
        XCTAssertEqual(controller.requestedSections.map(\.count), [1, 2, 0])
        controller.selectedReviewRequestFilters = [.draft]
        controller.setRepositoryPreferences(
            repo: "billing-platform-experiments/customer-subscription-dashboard",
            preferences: RepositorySourcePreferences(
                notifications: .inherit,
                myPullRequests: .inherit,
                reviewRequests: .disabled
            )
        )
        XCTAssertEqual(controller.requestedSections.map(\.section), [.assigned, .direct, .team])
        XCTAssertEqual(controller.requestedSections.map(\.count), [0, 0, 0])
    }

    @MainActor
    func testPATSignInTracksLoadingAndPreventsConcurrentAttempts() async throws {
        let client = DelayedViewerGitHubProvider()
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in client }
        )

        let firstSignIn = Task { await controller.signInWithToken("github_pat_token") }
        try await waitUntilAsync { client.viewerContinuation != nil }

        XCTAssertTrue(controller.isSigningInWithToken)

        await controller.signInWithToken("github_pat_second_token")
        XCTAssertEqual(client.fetchViewerCount, 1)

        client.finishViewerFetch()
        await firstSignIn.value

        XCTAssertFalse(controller.isSigningInWithToken)
        XCTAssertEqual(controller.state.authStatus, .signedIn)
    }

    @MainActor
    func testGitHubAppSignInDoesNotBeginDuringPATSignIn() async throws {
        let client = DelayedViewerGitHubProvider()
        let oauthSignIn = RecordingOAuthSignIn()
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0,
            oauthSignIn: oauthSignIn,
            patGitHubClientFactory: { _ in client }
        )

        let patSignIn = Task { await controller.signInWithToken("github_pat_token") }
        try await waitUntilAsync { client.viewerContinuation != nil }

        await controller.signInWithGitHub()

        XCTAssertEqual(oauthSignIn.requestDeviceCodeCount, 0)
        XCTAssertNil(controller.deviceFlowChallenge)
        XCTAssertTrue(controller.isSigningInWithToken)

        client.finishViewerFetch()
        await patSignIn.value
    }

    @MainActor
    func testLaunchAtLoginFailureIsShownSeparatelyAndClearedBySuccess() {
        let service = FailingLaunchAtLoginService()
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            launchAtLoginService: service,
            automaticRefreshInterval: 0
        )

        controller.setStartsAtLogin(true)

        XCTAssertFalse(controller.startsAtLogin)
        XCTAssertEqual(controller.launchAtLoginErrorMessage, FailingLaunchAtLoginService.TestError.failed.localizedDescription)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.refreshErrorMessage)

        service.fails = false
        controller.setStartsAtLogin(true)

        XCTAssertTrue(controller.startsAtLogin)
        XCTAssertNil(controller.launchAtLoginErrorMessage)
    }

    @MainActor
    func testPATSignInClearsLoadingAfterFailure() async {
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in FailingViewerGitHubProvider() }
        )

        await controller.signInWithToken("github_pat_token")

        XCTAssertFalse(controller.isSigningInWithToken)
        XCTAssertEqual(controller.errorMessage, FailingViewerGitHubProvider.TestError.failed.localizedDescription)
        XCTAssertNil(controller.refreshErrorMessage)
        XCTAssertEqual(controller.state.authStatus, .signedOut)
    }

    @MainActor
    func testDeviceFlowCopyConfirmationClearsAfterFirstCopy() {
        let oauthSignIn = WaitingOAuthSignIn()
        let copyDate = Date(timeIntervalSince1970: 1_777_800_000)
        var copiedCodes: [String] = []
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0,
            oauthSignIn: oauthSignIn,
            deviceFlowURLOpener: { _ in },
            clipboardWriter: { copiedCodes.append($0) },
            now: { copyDate }
        )

        Task {
            await controller.signInWithGitHub()
        }
        waitUntil(timeout: 1.0) {
            controller.deviceFlowChallenge != nil && oauthSignIn.pollStarted
        }

        controller.copyDeviceFlowUserCode()
        XCTAssertEqual(controller.deviceFlowCodeCopiedAt, copyDate)
        XCTAssertEqual(copiedCodes, ["ABCD-1234"])

        waitUntil(timeout: 2.5) {
            controller.deviceFlowCodeCopiedAt == nil
        }

        controller.cancelDeviceFlowSignIn()
    }

    @MainActor
    func testDeviceFlowCopyConfirmationRestartsAfterRepeatedCopy() {
        let oauthSignIn = WaitingOAuthSignIn()
        let firstCopyDate = Date(timeIntervalSince1970: 1_777_800_000)
        let secondCopyDate = Date(timeIntervalSince1970: 1_777_800_001)
        var currentDate = firstCopyDate
        var copiedCodes: [String] = []
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0,
            oauthSignIn: oauthSignIn,
            deviceFlowURLOpener: { _ in },
            clipboardWriter: { copiedCodes.append($0) },
            now: { currentDate }
        )

        Task {
            await controller.signInWithGitHub()
        }
        waitUntil(timeout: 1.0) {
            controller.deviceFlowChallenge != nil && oauthSignIn.pollStarted
        }

        controller.copyDeviceFlowUserCode()
        XCTAssertEqual(controller.deviceFlowCodeCopiedAt, firstCopyDate)
        XCTAssertEqual(copiedCodes, ["ABCD-1234"])

        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.2))
        currentDate = secondCopyDate
        controller.copyDeviceFlowUserCode()
        XCTAssertEqual(controller.deviceFlowCodeCopiedAt, secondCopyDate)
        XCTAssertEqual(copiedCodes, ["ABCD-1234", "ABCD-1234"])

        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.1))
        XCTAssertEqual(controller.deviceFlowCodeCopiedAt, secondCopyDate)

        waitUntil(timeout: 2.5) {
            controller.deviceFlowCodeCopiedAt == nil
        }

        controller.cancelDeviceFlowSignIn()
    }

    @MainActor
    func testMockRefreshRecordsTheInjectedClockAsSyncTime() {
        let clock = Date(timeIntervalSince1970: 1_790_000_000)
        let controller = makeMockController(suiteName: "mock-clock-sync", now: { clock })
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil && !controller.isRefreshing }
        XCTAssertEqual(controller.state.syncedAt, clock)

        controller.refresh()
        waitUntil(timeout: 1.0) { !controller.state.events.isEmpty && !controller.isRefreshing }
        XCTAssertEqual(controller.state.syncedAt, clock)
    }

    @MainActor
    func testMockSourceCatalogSyncTimeUsesTheInjectedClock() {
        let clock = Date(timeIntervalSince1970: 1_790_000_000)
        let controller = makeMockController(suiteName: "mock-clock-catalog", now: { clock })
        XCTAssertEqual(controller.sourceCatalogSyncedAt, clock)
    }

    @MainActor
    func testMockFixtureDatesAreRelativeToTheInjectedClock() throws {
        let clock = Date(timeIntervalSince1970: 1_790_000_000)
        let controller = makeMockController(suiteName: "mock-clock-fixtures", now: { clock })
        waitUntil(timeout: 1.0) { controller.state.syncedAt != nil && !controller.isRefreshing }
        let draft = try XCTUnwrap(controller.state.pullRequests.first { $0.id == "PR_1" })
        XCTAssertEqual(draft.updatedAt, clock.addingTimeInterval(-3 * 3_600))
        XCTAssertEqual(draft.createdAt, clock.addingTimeInterval(-150 * 86_400))
    }

    @MainActor
    func testPRStacksScenarioFirstRefreshCommitsItsStacks() async throws {
        let controller = makePRStacksController()
        try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }

        let expected = MockPullRequestSource(scenario: .prStacks).stacks
        XCTAssertEqual(expected.count, 9)
        XCTAssertEqual(controller.state.pullRequestStacks, expected)
    }

    func testEveryOtherMockScenarioReturnsNoStacks() async throws {
        for scenario in MockPullRequestScenario.allCases where scenario != .prStacks {
            let source = MockPullRequestSource(scenario: scenario)
            XCTAssertEqual(source.stacks, [], scenario.rawValue)
            let result = try await source.fetchCompletePullRequests(login: "agent-fixture", previousState: nil, reusableViewerTeams: nil)
            XCTAssertEqual(result.stacks, [], scenario.rawValue)
        }
    }

    @MainActor
    func testEveryRequestedPRStacksMemberNamesAStackThatListsIt() async throws {
        let source = MockPullRequestSource(scenario: .prStacks)
        let result = try await source.fetchCompletePullRequests(login: "agent-fixture", previousState: nil, reusableViewerTeams: nil)
        let stacksByID = Dictionary(uniqueKeysWithValues: result.stacks.map { ($0.id, $0) })
        let stacked = result.activePullRequests.filter { $0.stackID != nil }

        XCTAssertFalse(stacked.isEmpty)
        for pullRequest in stacked {
            let stack = try XCTUnwrap(stacksByID[pullRequest.stackID!], pullRequest.id)
            XCTAssertTrue(stack.entries.contains { $0.pullRequestID == pullRequest.id }, pullRequest.id)
        }
        XCTAssertTrue(result.activePullRequests.contains {
            $0.stackID == nil && DashboardController.isRequestedPullRequest($0)
        })
    }

    func testPRStacksUnreadableEntryStackKeepsItsSizeAndGitHubPositions() throws {
        let stack = try XCTUnwrap(MockPullRequestSource(scenario: .prStacks).stacks.first { $0.id == "STACK_MOCK_UNREADABLE" })

        XCTAssertEqual(stack.size, 4)
        XCTAssertEqual(stack.entries.map(\.position), [1, 2, 4])
    }

    private static let spreadRepresentative = "PR_STACK_MOCK_SPREAD_2"
    private static let spreadTeamMember = "PR_STACK_MOCK_SPREAD_3"
    private static let spreadOwnMember = "PR_STACK_MOCK_SPREAD_4"
    private static let assignedStackTeamMember = "PR_STACK_MOCK_ASSIGNED_2"
    private static let filterDraftMember = "PR_STACK_MOCK_FILTER_1"
    private static let filterReadyMember = "PR_STACK_MOCK_FILTER_2"
    /// The position-2 members of the all-open, closed-dependency, and partially merged stacks, sorted.
    private static let acceptanceRepresentatives = [
        "PR_STACK_MOCK_ALL_OPEN_2", "PR_STACK_MOCK_CLOSED_DEPENDENCY_2", "PR_STACK_MOCK_PARTIALLY_MERGED_2"
    ]
    private static let positionThreeRepresentative = "PR_STACK_MOCK_POSITION_3_3"

    @MainActor
    private static func rowIDs(_ controller: DashboardController) -> [DashboardController.RequestedSection: [String]] {
        Dictionary(uniqueKeysWithValues: controller.requestedSections.map {
            ($0.section, ($0.visible + $0.hidden).map(\.id).sorted())
        })
    }

    @MainActor
    private static func row(_ id: String, in controller: DashboardController) throws -> ReviewRequestRow {
        try XCTUnwrap(controller.requestedSections.flatMap { $0.visible + $0.hidden }.first { $0.id == id }, id)
    }

    @MainActor
    func testPRStacksShowEachStackAsOneRowInItsSectionWithMatchingRequestCounts() async throws {
        let controller = makePRStacksController()
        try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }

        XCTAssertEqual(Self.rowIDs(controller), [
            .assigned: ([Self.assignedStackTeamMember, "PR_STACKS_UNSTACKED_ASSIGNED"] + Self.acceptanceRepresentatives).sorted(),
            .direct: [
                Self.filterDraftMember, "PR_STACKS_UNSTACKED_DIRECT", "PR_STACK_MOCK_LAST_OPEN_2",
                Self.spreadRepresentative, "PR_STACK_MOCK_UNREADABLE_2", Self.positionThreeRepresentative
            ].sorted(),
            .team: ["PR_STACKS_UNSTACKED_TEAM"]
        ])
        XCTAssertEqual(controller.requestedSections.map(\.count), [6, 8, 1])
        let stackIDs = controller.requestedSections.flatMap { $0.visible + $0.hidden }.compactMap(\.stack?.stack.id)
        XCTAssertEqual(stackIDs.sorted(), controller.state.pullRequestStacks.map(\.id).sorted())
    }

    @MainActor
    func testOptionClickingAStackUsesItsStateForEveryStack() async throws {
        let controller = makePRStacksController()
        try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }
        let allStackIDs = Set(controller.state.pullRequestStacks.map(\.id))
        let clicked = "STACK_MOCK_SPREAD"
        let other = "STACK_MOCK_ASSIGNED"

        controller.toggleAllStacks(from: clicked)
        XCTAssertEqual(controller.expandedStackIDs, allStackIDs)
        controller.toggleAllStacks(from: clicked)
        XCTAssertTrue(controller.expandedStackIDs.isEmpty)

        controller.toggleStackExpanded(other)
        controller.toggleAllStacks(from: clicked)
        XCTAssertEqual(controller.expandedStackIDs, allStackIDs, "a collapsed stack expands every stack")

        controller.toggleStackExpanded(other)
        controller.toggleAllStacks(from: clicked)
        XCTAssertTrue(controller.expandedStackIDs.isEmpty, "an expanded stack collapses every stack")

        // Stacks the filters hide expand too, so they are still expanded when the filter is cleared.
        controller.selectedReviewRequestFilters = [.draft]
        let shownStackIDs = Set(controller.requestedSections.flatMap { $0.visible + $0.hidden }.compactMap(\.stack?.stack.id))
        let shown = try XCTUnwrap(shownStackIDs.first)
        XCTAssertNotEqual(shownStackIDs, allStackIDs, "the Draft filter hides some stacks")
        controller.toggleAllStacks(from: shown)
        XCTAssertEqual(controller.expandedStackIDs, allStackIDs)
    }

    @MainActor
    func testReadyFilterMovesTheAssignedAboveTeamGroupFromAssignedToTeam() async throws {
        let controller = makePRStacksController()
        try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }

        controller.selectedReviewRequestFilters = [.ready]

        let ids = Self.rowIDs(controller)
        XCTAssertEqual(ids[.assigned], ["PR_STACKS_UNSTACKED_ASSIGNED"] + Self.acceptanceRepresentatives)
        XCTAssertEqual(ids[.team], [Self.assignedStackTeamMember, "PR_STACKS_UNSTACKED_TEAM"].sorted())
        XCTAssertTrue(ids[.direct]?.contains(Self.filterReadyMember) == true)
        XCTAssertEqual(controller.requestedSections.map(\.count), [4, 7, 2])
    }

    @MainActor
    func testHidingAGroupHidesAndUnpinsEveryRequestedMemberAndUnhidingClearsIt() async throws {
        let controller = makePRStacksController()
        try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }
        controller.pinnedPullRequestIds = [Self.spreadTeamMember]

        controller.setHidden(try Self.row(Self.spreadRepresentative, in: controller), hidden: true)

        XCTAssertTrue(controller.hiddenPullRequestIds.isSuperset(of: [Self.spreadRepresentative, Self.spreadTeamMember]))
        XCTAssertTrue(controller.pinnedPullRequestIds.isDisjoint(with: [Self.spreadRepresentative, Self.spreadTeamMember]))
        let direct = try XCTUnwrap(controller.requestedSections.first { $0.section == .direct })
        XCTAssertEqual(direct.hidden.map(\.id), [Self.spreadRepresentative])
        XCTAssertFalse(direct.visible.contains { $0.id == Self.spreadRepresentative })
        XCTAssertEqual(direct.hiddenCount, 2)
        XCTAssertEqual(direct.count, 8)

        controller.setHidden(try Self.row(Self.spreadRepresentative, in: controller), hidden: false)

        XCTAssertTrue(controller.hiddenPullRequestIds.isDisjoint(with: [Self.spreadRepresentative, Self.spreadTeamMember]))
        XCTAssertTrue(controller.requestedSections.first { $0.section == .direct }?.visible.contains {
            $0.id == Self.spreadRepresentative
        } == true)
    }

    @MainActor
    func testPinningAGroupPinsAndUnhidesEveryRequestedMemberAndSortsItWithPinnedRows() async throws {
        let controller = makePRStacksController()
        try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }
        controller.hiddenPullRequestIds = [Self.spreadTeamMember]

        controller.setPinned(try Self.row(Self.spreadRepresentative, in: controller), pinned: true)

        XCTAssertTrue(controller.pinnedPullRequestIds.isSuperset(of: [Self.spreadRepresentative, Self.spreadTeamMember]))
        XCTAssertTrue(controller.hiddenPullRequestIds.isDisjoint(with: [Self.spreadRepresentative, Self.spreadTeamMember]))
        let direct = try XCTUnwrap(controller.requestedSections.first { $0.section == .direct })
        XCTAssertEqual(direct.visible.first?.id, Self.spreadRepresentative)
        XCTAssertEqual(direct.visible.first?.isPinned, true)
        XCTAssertEqual(direct.visible.dropFirst().map(\.isPinned), Array(repeating: false, count: direct.visible.count - 1))
    }

    @MainActor
    func testGroupActionsSetEveryRequestedMemberIncludingFilterExcludedOnesAndRepeatHarmlessly() async throws {
        let controller = makePRStacksController()
        try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }
        controller.selectedReviewRequestFilters = [.ready]
        let members: Set<String> = [Self.filterDraftMember, Self.filterReadyMember]
        typealias Expected = (pinned: Set<String>, hidden: Set<String>)
        let actions: [(String, (DashboardController, ReviewRequestRow) -> Void, Expected)] = [
            ("Hide", { $0.setHidden($1, hidden: true) }, ([], members)),
            ("Unhide", { $0.setHidden($1, hidden: false) }, ([Self.filterDraftMember], [])),
            ("Pin", { $0.setPinned($1, pinned: true) }, (members, [])),
            ("Unpin", { $0.setPinned($1, pinned: false) }, ([], [Self.filterReadyMember]))
        ]

        for (name, action, expected) in actions {
            // Mixed states: the filter-excluded Draft is pinned, the only matching member is hidden.
            controller.pinnedPullRequestIds = [Self.filterDraftMember, Self.spreadOwnMember]
            controller.hiddenPullRequestIds = [Self.filterReadyMember]
            let row = try Self.row(Self.filterReadyMember, in: controller)
            XCTAssertEqual(row.stack?.requestedMemberIDs, members, name)

            for attempt in 1...2 {
                action(controller, row)
                XCTAssertEqual(controller.pinnedPullRequestIds.intersection(members), expected.pinned, "\(name) \(attempt)")
                XCTAssertEqual(controller.hiddenPullRequestIds.intersection(members), expected.hidden, "\(name) \(attempt)")
                XCTAssertTrue(controller.pinnedPullRequestIds.contains(Self.spreadOwnMember), "\(name) \(attempt)")
                XCTAssertFalse(controller.hiddenPullRequestIds.contains(Self.spreadOwnMember), "\(name) \(attempt)")
            }
        }
    }

    @MainActor
    func testTurningOffTheRequestingTeamRemovesItsMemberFromTheGroupAndTurningItOnRestoresIt() throws {
        let suiteName = "stack-team-toggle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let direct = Self.stackPR("PR_A", stack: "S", direct: true)
        let team = Self.stackPR("PR_B", stack: "S", teams: [Self.developers])
        let both = Self.stackPR("PR_C", stack: "S", direct: true, teams: [Self.developers])
        let provider = ReviewTeamGitHubProvider(result: CompletePullRequestFetchResult(
            activePullRequests: [direct, team, both],
            viewerTeams: Self.nestedViewerTeams,
            stacks: [Self.stack("S", [direct, team, both])]
        ))
        let controller = Self.makeReviewTeamController(defaults: defaults, provider: provider)
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }
        XCTAssertEqual(try Self.row("PR_A", in: controller).stack?.requestedMemberIDs, ["PR_A", "PR_B", "PR_C"])

        controller.setReviewTeam(Self.developers.id, counting: false)

        let reduced = try XCTUnwrap(try Self.row("PR_A", in: controller).stack)
        XCTAssertEqual(reduced.requestedMemberIDs, ["PR_A", "PR_C"])
        XCTAssertEqual(reduced.additionalRequestCount, 1)
        XCTAssertEqual(reduced.members.map { if case .requested = $0 { true } else { false } }, [true, false, true])
        XCTAssertEqual(controller.requestedSections.map(\.count), [0, 2, 0])

        controller.setReviewTeam(Self.developers.id, counting: true)

        XCTAssertEqual(try Self.row("PR_A", in: controller).stack?.requestedMemberIDs, ["PR_A", "PR_B", "PR_C"])
        XCTAssertEqual(controller.requestedSections.map(\.count), [0, 3, 0])
    }

    @MainActor
    func testExcludingTheStacksRepositoryThroughSourcesRemovesTheWholeGroup() async throws {
        let controller = makePRStacksController()
        try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }

        controller.setRepositoryPreferences(
            repo: "mergehawk-labs/desktop-app",
            preferences: RepositorySourcePreferences(notifications: .inherit, myPullRequests: .inherit, reviewRequests: .disabled)
        )

        let rows = controller.requestedSections.flatMap { $0.visible + $0.hidden }
        XCTAssertFalse(rows.contains { $0.representative.repo == "mergehawk-labs/desktop-app" })
        XCTAssertFalse(rows.contains { ["STACK_MOCK_ASSIGNED", "STACK_MOCK_FILTER"].contains($0.stack?.stack.id) })
        XCTAssertEqual(controller.requestedSections.map(\.count), [4, 6, 1])
    }

    @MainActor
    func testViewersOwnStackMemberIsAContextMemberAndStaysUnchangedInMyPRs() async throws {
        let controller = makePRStacksController()
        try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }

        let group = try XCTUnwrap(try Self.row(Self.spreadRepresentative, in: controller).stack)
        guard case .context(let entry) = try XCTUnwrap(group.members.first) else {
            return XCTFail("The viewer's own member should be a context member")
        }
        XCTAssertEqual(entry.pullRequestID, Self.spreadOwnMember)
        XCTAssertFalse(group.requestedMemberIDs.contains(Self.spreadOwnMember))
        let own = try XCTUnwrap(controller.state.pullRequests.first { $0.id == Self.spreadOwnMember })
        XCTAssertEqual(controller.sortedMyPullRequests.first { $0.id == own.id }, own)
    }

    @MainActor
    func testStackExpansionTogglesPerStackStartsCollapsedAndIsNotSaved() async throws {
        let suite = "pr-stacks-expansion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = makePRStacksController(defaults: defaults)
        try await waitUntilAsync { controller.state.syncedAt != nil && !controller.isRefreshing }
        XCTAssertTrue(controller.expandedStackIDs.isEmpty)
        let before = defaults.dictionaryRepresentation().keys.sorted()

        controller.toggleStackExpanded("STACK_MOCK_SPREAD")

        XCTAssertTrue(controller.isStackExpanded("STACK_MOCK_SPREAD"))
        XCTAssertFalse(controller.isStackExpanded("STACK_MOCK_FILTER"))
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.sorted(), before)
        XCTAssertFalse(makePRStacksController(defaults: defaults).isStackExpanded("STACK_MOCK_SPREAD"))

        controller.toggleStackExpanded("STACK_MOCK_SPREAD")

        XCTAssertFalse(controller.isStackExpanded("STACK_MOCK_SPREAD"))
    }

    @MainActor
    func testOpeningAContextMemberOpensItsURLWithoutMarkingNotificationsRead() throws {
        let suiteName = "stack-open-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let requested = Self.stackPR("PR_REQUESTED", stack: "S", direct: true)
        let stack = PullRequestStack(id: "S", size: 2, entries: [
            PullRequestStackEntry(
                position: 1, pullRequestID: "PR_CONTEXT", number: 900, title: "Context",
                url: URL(string: "https://github.com/acme/app/pull/900")!, state: .open, isDraft: false, author: "other"
            ),
            PullRequestStackEntry(
                position: 2, pullRequestID: requested.id, number: requested.number, title: requested.title,
                url: requested.url, state: .open, isDraft: false, author: requested.author
            )
        ])
        let account = GitHubAccount(login: "rw")
        let notification = PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: requested.id, activityId: "COMMENT_1"),
            pullRequest: requested
        )
        var store = PreferencesStore(defaults: defaults)
        store.authMethod = .pat
        try store.storePullRequestSyncState(PullRequestSyncState(
            account: account,
            dashboard: DashboardState(
                pullRequests: [requested], events: [], syncedAt: Date(timeIntervalSince1970: 10), source: .github,
                account: account, authStatus: .signedIn, pullRequestStacks: [stack]
            ),
            processedActivityByPullRequestID: [requested.id: ProcessedPullRequestActivity(pullRequestID: requested.id)],
            notificationHistory: [notification]
        ))
        var opened: [URL] = []
        let provider = ReviewTeamGitHubProvider(result: nil)
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(token: "pat"),
            preferencesStore: store,
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in provider },
            urlOpener: { opened.append($0) }
        )
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }
        let group = try XCTUnwrap(try Self.row(requested.id, in: controller).stack)

        controller.openStackMember(group.members[1])

        XCTAssertEqual(opened, [stack.entries[0].url])
        XCTAssertEqual(controller.pullRequestNotificationHistory.map(\.read), [false])

        controller.openStackMember(group.members[0])

        XCTAssertEqual(opened, [stack.entries[0].url, requested.url])
        XCTAssertEqual(controller.pullRequestNotificationHistory.map(\.read), [true])
    }

    private static func stackPR(
        _ id: String,
        stack: String,
        direct: Bool = false,
        teams: [TeamReference] = []
    ) -> PullRequest {
        let base = archiveFixturePR(
            id, repo: "acme/app", request: ReviewRequestKind(direct: direct, team: !teams.isEmpty), requestedTeams: teams
        )
        return PullRequest(
            id: base.id, title: base.title, number: base.number, url: base.url, repo: base.repo,
            ciState: base.ciState, reviewDecision: base.reviewDecision, commentCount: base.commentCount,
            reviewCount: base.reviewCount, reviewRequestKind: base.reviewRequestKind, requestedTeams: base.requestedTeams,
            isAssignedToViewer: base.isAssignedToViewer, isMine: base.isMine, author: base.author,
            mergeable: base.mergeable, draft: base.draft, createdAt: base.createdAt, updatedAt: base.updatedAt,
            stackID: stack
        )
    }

    private static func stack(_ id: String, _ members: [PullRequest]) -> PullRequestStack {
        PullRequestStack(id: id, size: members.count, entries: members.enumerated().map { index, pr in
            PullRequestStackEntry(
                position: index + 1, pullRequestID: pr.id, number: pr.number, title: pr.title, url: pr.url,
                state: .open, isDraft: pr.draft, author: pr.author
            )
        })
    }

    @MainActor
    private func makePRStacksController(defaults providedDefaults: UserDefaults? = nil) -> DashboardController {
        let defaults: UserDefaults
        if let providedDefaults {
            defaults = providedDefaults
        } else {
            let suite = "pr-stacks-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        }
        return DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(
                usesMockData: true,
                suppressesMacOSNotifications: true,
                mockPullRequestScenario: .prStacks
            ),
            automaticRefreshInterval: 0
        )
    }

    @MainActor
    private func makeMockController(suiteName: String, now: @escaping () -> Date) -> DashboardController {
        let suite = "\(suiteName)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return DashboardController(
            tokenStore: InMemoryTokenStore(),
            preferencesStore: PreferencesStore(defaults: defaults),
            launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
            automaticRefreshInterval: 0,
            now: now
        )
    }

    @MainActor
    private func waitUntilAsync(condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestTimeout.timedOut
    }
}

private enum TestTimeout: Error {
    case timedOut
}

@MainActor let mergehawkSignedOutStartsEmptyTest: Void = {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0
    )

    waitUntil(timeout: 1.0) {
        controller.state.syncedAt != nil
    }

    precondition(controller.state.authStatus == .signedOut)
    precondition(controller.state.pullRequests.isEmpty)
    precondition(controller.state.events.isEmpty)
}()

@MainActor let mergehawkSignOutClearsCachedNotificationsTest: Void = {
    let suiteName = "mergehawk-signout-clears-notifications-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var preferencesStore = PreferencesStore(defaults: defaults)
    preferencesStore.pullRequestSnapshotCache = signedInSnapshotCache()
    preferencesStore.pullRequestNotificationHistory = [
        PullRequestNotification(
            event: PullRequestEvent(type: .newComment, prId: "PR_1"),
            pullRequest: signedInSnapshotCache().pullRequests[0]
        )
    ]
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        preferencesStore: preferencesStore,
        automaticRefreshInterval: 0
    )

    precondition(!controller.pullRequestNotificationHistory.isEmpty)
    controller.signOut()
    precondition(controller.pullRequestNotificationHistory.isEmpty)
    precondition(preferencesStore.pullRequestNotificationHistory.isEmpty)
}()

@MainActor let mergehawkGitHubAppRepositoryAccessStatusTest: Void = {
    let installation = GitHubAppInstallation(
        id: 12,
        accountLogin: "acme",
        accountType: "Organization",
        repositorySelection: .selected
    )
    let repositoryCatalog = SourceCatalog(repositories: [
        RepositorySource(owner: "acme", name: "mergehawk")
    ])

    precondition(DashboardController.GitHubAppRepositoryAccessStatus.resolved(
        installations: GitHubAppInstallations(installations: []),
        sourceCatalog: repositoryCatalog
    ) == .noInstallations)
    precondition(DashboardController.GitHubAppRepositoryAccessStatus.resolved(
        installations: GitHubAppInstallations(installations: [installation]),
        sourceCatalog: SourceCatalog(repositories: [], accountLogin: "rw")
    ) == .noVisibleRepositories)
    precondition(DashboardController.GitHubAppRepositoryAccessStatus.resolved(
        installations: GitHubAppInstallations(installations: [installation]),
        sourceCatalog: repositoryCatalog
    ) == .configured)
}()

@MainActor let mergehawkGitHubAppRepositoryAccessPromptAfterSignInTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: []))
    )
    var openedURL: URL?
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        urlOpener: { openedURL = $0 },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.gitHubAppRepositoryAccessStatus == .noInstallations
    }

    precondition(fakeClient.fetchInstallationsCount == 1)
    precondition(controller.gitHubAppRepositoryAccessStatus == .noInstallations)
    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
    controller.openGitHubAppInstallation()
    precondition(openedURL == MergeHawkAuthDefaults.installURL)
}()

@MainActor let mergehawkNoInstallationsStillPromptsWhenPublicRepositoriesAreVisibleTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [
            RepositorySource(owner: "rw", name: "public-repo")
        ], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: []))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.gitHubAppRepositoryAccessStatus == .noInstallations
    }

    precondition(controller.sourceCatalog.repositoryCount == 1)
    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
}()

@MainActor let mergehawkNoInstallationsStillPromptsWhenPullRequestsAreVisibleTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [])),
        pullRequests: [
            PullRequest(
                id: "PR_PUBLIC",
                title: "Public authored PR",
                number: 7,
                url: URL(string: "https://github.com/rw/public-repo/pull/7")!,
                repo: "rw/public-repo",
                ciState: .passing,
                reviewDecision: .reviewRequired,
                commentCount: 0,
                reviewCount: 0,
                isMine: true,
                author: "rw",
                mergeable: .mergeable,
                draft: false
            )
        ]
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.state.pullRequests.count == 1
    }

    precondition(controller.gitHubAppRepositoryAccessStatus == .noInstallations)
    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
}()

@MainActor let mergehawkDeviceFlowPendingStateCanCancelTest: Void = {
    let oauthSignIn = WaitingOAuthSignIn()
    let firstCopyDate = Date(timeIntervalSince1970: 1_777_800_000)
    let secondCopyDate = Date(timeIntervalSince1970: 1_777_800_001)
    var currentDate = firstCopyDate
    var foregroundOpenedURL: URL?
    var deviceFlowOpenedURL: URL?
    var copiedCodes: [String] = []
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: oauthSignIn,
        urlOpener: { foregroundOpenedURL = $0 },
        deviceFlowURLOpener: { deviceFlowOpenedURL = $0 },
        clipboardWriter: { copiedCodes.append($0) },
        now: { currentDate }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.deviceFlowChallenge != nil && oauthSignIn.pollStarted
    }

    precondition(controller.deviceFlowChallenge?.userCode == "ABCD-1234")
    precondition(controller.deviceFlowPhase == .enterCode)
    precondition(controller.deviceFlowCodeCopiedAt == nil)
    precondition(!controller.isRequestingDeviceCode)
    precondition(foregroundOpenedURL == nil)
    precondition(deviceFlowOpenedURL?.absoluteString == "https://github.com/login/device")
    precondition(copiedCodes.isEmpty)

    controller.copyDeviceFlowUserCode()
    precondition(controller.deviceFlowCodeCopiedAt == firstCopyDate)
    precondition(copiedCodes == ["ABCD-1234"])

    currentDate = secondCopyDate
    controller.copyDeviceFlowUserCode()
    precondition(controller.deviceFlowCodeCopiedAt == secondCopyDate)
    precondition(copiedCodes == ["ABCD-1234", "ABCD-1234"])

    controller.cancelDeviceFlowSignIn()

    precondition(controller.deviceFlowChallenge == nil)
    precondition(controller.deviceFlowPhase == nil)
    precondition(controller.deviceFlowCodeCopiedAt == nil)
    precondition(!controller.isRequestingDeviceCode)
    precondition(controller.state.authStatus == .signedOut)
}()

@MainActor let mergehawkMenuDeviceFlowSignInRequestsMenuRevealTest: Void = {
    let oauthSignIn = WaitingOAuthSignIn()
    var revealCount = 0
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: oauthSignIn,
        deviceFlowURLOpener: { _ in },
        clipboardWriter: { _ in }
    )
    controller.showDeviceFlowSignInMenu = {
        revealCount += 1
    }

    Task {
        await controller.signInWithGitHub(keepsMenuVisible: true)
    }
    waitUntil(timeout: 1.0) {
        controller.deviceFlowChallenge != nil && oauthSignIn.pollStarted
    }

    precondition(revealCount == 1)
    precondition(controller.deviceFlowPhase == .enterCode)

    controller.cancelDeviceFlowSignIn()
}()

@MainActor let mergehawkSignOutDuringDeviceFlowViewerFetchDoesNotRestoreSessionTest: Void = {
    let fakeClient = DelayedViewerGitHubProvider()
    let tokenStore = InMemoryTokenStore()
    let controller = DashboardController(
        tokenStore: tokenStore,
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        urlOpener: { _ in },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        fakeClient.viewerContinuation != nil
    }

    precondition(controller.deviceFlowPhase == .loadingApp)
    controller.signOut()
    fakeClient.finishViewerFetch()
    waitUntil(timeout: 1.0) {
        fakeClient.viewerFetchCompleted
    }
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))

    precondition(controller.state.authStatus == .signedOut)
    precondition(controller.deviceFlowChallenge == nil)
    precondition(controller.deviceFlowPhase == nil)
    precondition((try? tokenStore.loadOAuthTokens()) == nil)
    precondition(fakeClient.fetchSourceCatalogCount == 0)
    precondition(fakeClient.fetchPullRequestsCount == 0)
}()

@MainActor let mergehawkSignOutBeforeDeviceFlowPollReturnsDoesNotStoreTokensTest: Void = {
    let oauthSignIn = DelayedPollOAuthSignIn()
    let tokenStore = InMemoryTokenStore()
    let controller = DashboardController(
        tokenStore: tokenStore,
        automaticRefreshInterval: 0,
        oauthSignIn: oauthSignIn,
        urlOpener: { _ in },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.deviceFlowChallenge != nil && oauthSignIn.pollContinuation != nil
    }

    precondition(controller.deviceFlowPhase == .enterCode)
    controller.signOut()
    oauthSignIn.finishPolling()
    waitUntil(timeout: 1.0) {
        oauthSignIn.pollCompleted
    }
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))

    precondition(controller.state.authStatus == .signedOut)
    precondition(controller.deviceFlowChallenge == nil)
    precondition(controller.deviceFlowPhase == nil)
    precondition((try? tokenStore.loadOAuthTokens()) == nil)
}()

@MainActor let mergehawkDeviceFlowPollFailureClearsPhaseTest: Void = {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FailingPollOAuthSignIn(),
        urlOpener: { _ in },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.errorMessage != nil
    }

    precondition(controller.state.authStatus == .signedOut)
    precondition(controller.deviceFlowChallenge == nil)
    precondition(controller.deviceFlowPhase == nil)
}()

@MainActor let mergehawkDeviceFlowPendingStateStaysVisibleUntilDashboardReadyTest: Void = {
    let fakeClient = DelayedSyncGitHubProvider()
    let tokenStore = InMemoryTokenStore()
    let controller = DashboardController(
        tokenStore: tokenStore,
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        urlOpener: { _ in },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        fakeClient.pullRequestsContinuation != nil
    }

    precondition(controller.deviceFlowChallenge?.userCode == "ABCD-1234")
    precondition(controller.deviceFlowPhase == .loadingApp)
    precondition(controller.state.authStatus == .signedOut)
    precondition((try? tokenStore.loadOAuthTokens()) == nil)

    fakeClient.finishPullRequestFetch()
    waitUntil(timeout: 1.0) {
        controller.state.authStatus == .signedIn
    }

    precondition(controller.deviceFlowChallenge == nil)
    precondition(controller.deviceFlowPhase == nil)
    precondition((try? tokenStore.loadOAuthTokens()) != nil)
}()

@MainActor let mergehawkGitHubAppRepositoryAccessUsesInstallationManageURLTest: Void = {
    let manageURL = URL(string: "https://github.com/organizations/acme/settings/installations/1002")!
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "acme",
                accountType: "Organization",
                repositorySelection: .selected,
                htmlURL: manageURL
            )
        ]))
    )
    var openedURL: URL?
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        urlOpener: { openedURL = $0 },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.gitHubAppRepositoryAccessStatus == .noVisibleRepositories
    }

    precondition(controller.gitHubAppRepositoryAccessStatus == .noVisibleRepositories)
    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
    controller.openGitHubAppInstallation()
    precondition(openedURL == manageURL)
}()

@MainActor let mergehawkGitHubAppRepositoryAccessPromptHidesAfterInstallationTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "rw",
                accountType: "User",
                repositorySelection: .all
            )
        ])),
        pullRequests: [
            PullRequest(
                id: "PR_AUTHORED",
                title: "Ship story tales",
                number: 7,
                url: URL(string: "https://github.com/rw/story-tales/pull/7")!,
                repo: "rw/story-tales",
                ciState: .passing,
                reviewDecision: .reviewRequired,
                commentCount: 0,
                reviewCount: 0,
                isMine: true,
                author: "rw",
                mergeable: .mergeable,
                draft: false
            )
        ]
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.state.pullRequests.count == 1
    }

    precondition(controller.gitHubAppRepositoryAccessStatus == .configured)
    precondition(!controller.showsGitHubAppRepositoryAccessPrompt)
    precondition(controller.sortedReviewRequests.isEmpty)
}()

@MainActor let mergehawkConfiguredGitHubAppRepositoryAccessUsesInstallURLTest: Void = {
    let manageURL = URL(string: "https://github.com/settings/installations/1002")!
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [
            RepositorySource(owner: "rw", name: "mergehawk")
        ], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "rw",
                accountType: "User",
                repositorySelection: .all,
                htmlURL: manageURL
            )
        ]))
    )
    var openedURL: URL?
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        urlOpener: { openedURL = $0 },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.gitHubAppRepositoryAccessStatus == .configured
    }

    precondition(!controller.showsGitHubAppRepositoryAccessPrompt)
    controller.openGitHubAppInstallation()
    precondition(openedURL == MergeHawkAuthDefaults.installURL)
}()

@MainActor let mergehawkPATDoesNotShowGitHubAppRepositoryAccessPromptTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: []))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        patGitHubClientFactory: { _ in fakeClient }
    )

    Task {
        await controller.signInWithToken("github_pat_token")
    }
    waitUntil(timeout: 1.0) {
        controller.state.authStatus == .signedIn
    }

    precondition(fakeClient.fetchInstallationsCount == 0)
    precondition(controller.gitHubAppRepositoryAccessStatus == .notApplicable)
    precondition(!controller.showsGitHubAppRepositoryAccessPrompt)
}()

@MainActor let mergehawkGitHubAppInstallationCheckRunsWhenSourceCatalogFailsTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .failure(FakeGitHubProvider.TestError.sourceCatalogFailed),
        installationsResult: .success(GitHubAppInstallations(installations: []))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        controller.gitHubAppRepositoryAccessStatus == .noInstallations
            && controller.sourceErrorMessage != nil
    }

    precondition(fakeClient.fetchInstallationsCount == 1)
    precondition(controller.gitHubAppRepositoryAccessStatus == .noInstallations)
    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
    precondition(controller.sourceErrorMessage == FakeGitHubProvider.TestError.sourceCatalogFailed.localizedDescription)
}()

@MainActor let mergehawkGitHubAppRefreshChecksRepositoryAccessTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [
            RepositorySource(owner: "rw", name: "story-tales")
        ], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "rw",
                accountType: "User",
                repositorySelection: .all
            )
        ]))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        fakeClient.fetchInstallationsCount == 1
    }

    fakeClient.installationsResult = .success(GitHubAppInstallations(installations: []))
    controller.refresh()
    waitUntil(timeout: 1.0) {
        fakeClient.fetchInstallationsCount == 2
            && controller.gitHubAppRepositoryAccessStatus == .noInstallations
    }

    precondition(controller.showsGitHubAppRepositoryAccessPrompt)
}()

@MainActor let mergehawkPATRefreshDoesNotCheckGitHubAppInstallationsTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: []))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        patGitHubClientFactory: { _ in fakeClient }
    )

    Task {
        await controller.signInWithToken("github_pat_token")
    }
    waitUntil(timeout: 1.0) {
        controller.state.authStatus == .signedIn
    }

    controller.refresh()
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))

    precondition(fakeClient.fetchInstallationsCount == 0)
    precondition(controller.gitHubAppRepositoryAccessStatus == .notApplicable)
}()

@MainActor let mergehawkAutomaticRefreshTest: Void = {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0.05
    )

    waitUntil(timeout: 1.0) {
        controller.state.syncedAt != nil
    }

    guard let initialSyncDate = controller.state.syncedAt else {
        preconditionFailure("Initial sync did not complete")
    }

    waitUntil(timeout: 1.0) {
        guard let syncedAt = controller.state.syncedAt else {
            return false
        }
        return syncedAt > initialSyncDate
    }
}()

@MainActor let mergehawkAutomaticRefreshChecksGitHubAppInstallationsTest: Void = {
    let fakeClient = FakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [
            RepositorySource(owner: "rw", name: "story-tales")
        ], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "rw",
                accountType: "User",
                repositorySelection: .all
            )
        ]))
    )
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0.05,
        oauthSignIn: FakeOAuthSignIn(),
        oauthGitHubClientFactory: { _ in fakeClient },
        deviceFlowURLOpener: { _ in }
    )

    Task {
        await controller.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        fakeClient.fetchPullRequestsCount == 1
    }
    precondition(fakeClient.fetchInstallationsCount == 1)

    waitUntil(timeout: 1.0) {
        fakeClient.fetchPullRequestsCount > 1
    }

    waitUntil(timeout: 1.0) {
        fakeClient.fetchInstallationsCount > 1
    }
}()

@MainActor let mergehawkStartAtLoginTest: Void = {
    let launchAtLoginService = FakeLaunchAtLoginService(isEnabled: false)
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        launchAtLoginService: launchAtLoginService,
        automaticRefreshInterval: 0
    )

    precondition(controller.startsAtLogin == false)

    controller.setStartsAtLogin(true)
    precondition(controller.startsAtLogin == true)
    precondition(launchAtLoginService.requestedValues == [true])

    controller.setStartsAtLogin(false)
    precondition(controller.startsAtLogin == false)
    precondition(launchAtLoginService.requestedValues == [true, false])
}()

@MainActor let mergehawkMockModeStartsSignedInWithoutTokenTest: Void = {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
        automaticRefreshInterval: 0
    )

    waitUntil(timeout: 1.0) {
        controller.state.syncedAt != nil
    }

    precondition(controller.state.authStatus == .signedIn)
    precondition(controller.state.source == .mock)
    precondition(controller.state.account?.login == "agent-fixture")
    precondition(controller.state.pullRequests.map(\.id) == ["PR_1", "PR_4", "PR_6", "PR_2", "PR_3", "PR_7", "PR_5"])
    precondition(controller.sortedMyPullRequests.map(\.id) == ["PR_6", "PR_1", "PR_4"])
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_7", "PR_2", "PR_5", "PR_3"])

    precondition(controller.requestedSections.map(\.section) == [.assigned, .direct, .team])
    precondition(controller.requestedSections.map { $0.visible.map(\.id) } == [["PR_7", "PR_2"], ["PR_5"], ["PR_3"]])

    controller.selectedReviewRequestFilters = [.draft]
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_3"])

    controller.selectedReviewRequestFilters = []
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_7", "PR_2", "PR_5", "PR_3"])
}()

@MainActor let mergehawkHiddenPullRequestOrganizationTest: Void = {
    let suiteName = "mergehawk-hidden-organization-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        preferencesStore: PreferencesStore(defaults: defaults),
        launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
        automaticRefreshInterval: 0
    )

    waitUntil(timeout: 1.0) {
        controller.state.syncedAt != nil
    }

    let authored = controller.sourceFilteredMyPullRequests
    let firstAuthored = authored[0]
    controller.pinnedPullRequestIds = [firstAuthored.id]
    controller.toggleHide(firstAuthored)
    precondition(controller.isHidden(firstAuthored))
    precondition(!controller.isPinned(firstAuthored))
    precondition(PreferencesStore(defaults: defaults).hiddenPullRequestIds == [firstAuthored.id])

    controller.togglePin(firstAuthored)
    precondition(controller.isPinned(firstAuthored))
    precondition(!controller.isHidden(firstAuthored))
    precondition(PreferencesStore(defaults: defaults).pinnedPullRequestIds == [firstAuthored.id])
    precondition(PreferencesStore(defaults: defaults).hiddenPullRequestIds.isEmpty)

    controller.togglePin(firstAuthored)
    controller.toggleHide(firstAuthored)
    controller.toggleHide(firstAuthored)
    precondition(!controller.isHidden(firstAuthored))
    precondition(!controller.isPinned(firstAuthored))

    controller.hiddenPullRequestIds = ["PR_1", "PR_4", "PR_6"]
    controller.pullRequestSortOption = .createdDate
    controller.pullRequestSortDirection = .descending
    precondition(controller.sortedMyPullRequests.isEmpty)
    precondition(controller.hiddenMyPullRequests.map(\.id) == ["PR_6", "PR_1", "PR_4"])
    controller.pullRequestSortDirection = .ascending
    precondition(controller.hiddenMyPullRequests.map(\.id) == ["PR_4", "PR_1", "PR_6"])

    controller.hiddenPullRequestIds = ["PR_4"]
    controller.pullRequestSortDirection = .descending
    precondition(controller.sortedMyPullRequests.map(\.id) == ["PR_6", "PR_1"])
    controller.pullRequestSortDirection = .ascending
    precondition(controller.sortedMyPullRequests.map(\.id) == ["PR_1", "PR_6"])

    controller.selectedPullRequestFilters = [.draft]
    precondition(controller.hiddenMyPullRequests.isEmpty)
    precondition(controller.sortedMyPullRequests.map(\.id) == ["PR_1"])

    controller.selectedPullRequestFilters = []
    controller.hiddenPullRequestIds = ["PR_2", "PR_3", "PR_5", "PR_7"]
    controller.reviewRequestSortOption = .updatedDate
    controller.reviewRequestSortDirection = .descending
    precondition(controller.hiddenReviewRequests.map(\.id) == ["PR_7", "PR_2", "PR_5", "PR_3"])
    controller.reviewRequestSortDirection = .ascending
    precondition(controller.hiddenReviewRequests.map(\.id) == ["PR_3", "PR_5", "PR_2", "PR_7"])

    controller.hiddenPullRequestIds = ["PR_2", "PR_5"]
    controller.reviewRequestSortDirection = .descending
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_7", "PR_3"])
    controller.reviewRequestSortDirection = .ascending
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_3", "PR_7"])

    controller.hiddenPullRequestIds = ["PR_7"]
    controller.selectedReviewRequestFilters = [.ready]
    precondition(controller.hiddenReviewRequests.map(\.id) == ["PR_7"])
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_2", "PR_5"])

    controller.setRepositoryPreferences(
        repo: "mergehawk-labs/review-router",
        preferences: RepositorySourcePreferences(
            notifications: .inherit,
            myPullRequests: .inherit,
            reviewRequests: .disabled
        )
    )
    precondition(controller.hiddenReviewRequests.isEmpty)
}()

@MainActor let mergehawkSourcePreferencesFilterDashboardListsTest: Void = {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
        automaticRefreshInterval: 0
    )

    waitUntil(timeout: 1.0) {
        controller.state.syncedAt != nil
    }

    controller.setOwnerPreferences(
        owner: "mergehawk-labs",
        preferences: OwnerSourcePreferences(
            notifications: true,
            myPullRequests: false,
            reviewRequests: true
        )
    )
    controller.setOwnerPreferences(
        owner: "customer-success-platform",
        preferences: OwnerSourcePreferences(
            notifications: true,
            myPullRequests: false,
            reviewRequests: true
        )
    )
    precondition(controller.sortedMyPullRequests.isEmpty)
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_7", "PR_3", "PR_2"])

    controller.setRepositoryPreferences(
        repo: "mergehawk-labs/desktop-app",
        preferences: RepositorySourcePreferences(
            notifications: .inherit,
            myPullRequests: .inherit,
            reviewRequests: .disabled
        )
    )
    controller.selectedReviewRequestFilters = []
    precondition(controller.sortedReviewRequests.map(\.id) == ["PR_5", "PR_7", "PR_3"])
}()

@MainActor
private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    preconditionFailure("Timed out waiting for condition")
}

@MainActor
private struct FakeOAuthSignIn: GitHubOAuthSigningIn {
    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        DeviceFlowChallenge(
            userCode: "ABCD-1234",
            deviceCode: "fake-device-code",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: .distantFuture,
            interval: 5
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        OAuthTokens(accessToken: "oauth-access", refreshToken: "oauth-refresh", expiresAt: .distantFuture)
    }
}

@MainActor
private final class WaitingOAuthSignIn: GitHubOAuthSigningIn {
    private(set) var pollStarted = false

    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        DeviceFlowChallenge(
            userCode: "ABCD-1234",
            deviceCode: "fake-device-code",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: .distantFuture,
            interval: 5
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        pollStarted = true
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }
}

@MainActor
private final class DelayedPollOAuthSignIn: GitHubOAuthSigningIn {
    var pollContinuation: CheckedContinuation<OAuthTokens, Never>?
    private(set) var pollCompleted = false

    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        DeviceFlowChallenge(
            userCode: "ABCD-1234",
            deviceCode: "fake-device-code",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: .distantFuture,
            interval: 5
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        let tokens = await withCheckedContinuation { continuation in
            pollContinuation = continuation
        }
        pollCompleted = true
        return tokens
    }

    func finishPolling() {
        pollContinuation?.resume(
            returning: OAuthTokens(accessToken: "oauth-access", refreshToken: "oauth-refresh", expiresAt: .distantFuture)
        )
        pollContinuation = nil
    }
}

@MainActor
private struct FailingPollOAuthSignIn: GitHubOAuthSigningIn {
    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        DeviceFlowChallenge(
            userCode: "ABCD-1234",
            deviceCode: "fake-device-code",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: .distantFuture,
            interval: 5
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        throw DeviceFlowError.accessDenied
    }
}

private final class FakeGitHubProvider: GitHubProviding {
    enum TestError: Error, LocalizedError {
        case sourceCatalogFailed

        var errorDescription: String? {
            "Source catalog failed"
        }
    }

    let sourceKind: DashboardSource = .github
    var sourceCatalogResult: Result<SourceCatalog, Error>
    var installationsResult: Result<GitHubAppInstallations, Error>
    var pullRequests: [PullRequest]
    private(set) var fetchInstallationsCount = 0
    private(set) var fetchPullRequestsCount = 0

    init(
        sourceCatalogResult: Result<SourceCatalog, Error>,
        installationsResult: Result<GitHubAppInstallations, Error>,
        pullRequests: [PullRequest] = []
    ) {
        self.sourceCatalogResult = sourceCatalogResult
        self.installationsResult = installationsResult
        self.pullRequests = pullRequests
    }

    func fetchViewer() async throws -> GitHubAccount {
        GitHubAccount(login: "rw")
    }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?,
        reusableViewerTeams: [ViewerTeam]?
    ) async throws -> CompletePullRequestFetchResult {
        fetchPullRequestsCount += 1
        return CompletePullRequestFetchResult(activePullRequests: pullRequests)
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        try sourceCatalogResult.get()
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        fetchInstallationsCount += 1
        return try installationsResult.get()
    }

}

private final class DelayedViewerGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    var viewerContinuation: CheckedContinuation<GitHubAccount, Never>?
    private(set) var viewerFetchCompleted = false
    private(set) var fetchViewerCount = 0
    private(set) var fetchSourceCatalogCount = 0
    private(set) var fetchPullRequestsCount = 0

    func fetchViewer() async throws -> GitHubAccount {
        fetchViewerCount += 1
        let viewer = await withCheckedContinuation { continuation in
            viewerContinuation = continuation
        }
        viewerFetchCompleted = true
        return viewer
    }

    func finishViewerFetch() {
        viewerContinuation?.resume(returning: GitHubAccount(login: "rw"))
        viewerContinuation = nil
    }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?,
        reusableViewerTeams: [ViewerTeam]?
    ) async throws -> CompletePullRequestFetchResult {
        fetchPullRequestsCount += 1
        return CompletePullRequestFetchResult(activePullRequests: [])
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        fetchSourceCatalogCount += 1
        return SourceCatalog(repositories: [], accountLogin: "rw")
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }

}

private final class FailingViewerGitHubProvider: GitHubProviding {
    enum TestError: Error, LocalizedError {
        case failed

        var errorDescription: String? { "Viewer failed" }
    }

    let sourceKind: DashboardSource = .github

    func fetchViewer() async throws -> GitHubAccount {
        throw TestError.failed
    }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?,
        reusableViewerTeams: [ViewerTeam]?
    ) async throws -> CompletePullRequestFetchResult {
        CompletePullRequestFetchResult(activePullRequests: [])
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: accountLogin)
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }

}

@MainActor
private final class RecordingOAuthSignIn: GitHubOAuthSigningIn {
    private(set) var requestDeviceCodeCount = 0

    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        requestDeviceCodeCount += 1
        return DeviceFlowChallenge(
            userCode: "ABCD-1234",
            deviceCode: "fake-device-code",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: .distantFuture,
            interval: 5
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
    }
}

private final class DelayedSyncGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    var pullRequestsContinuation: CheckedContinuation<CompletePullRequestFetchResult, Never>?

    func fetchViewer() async throws -> GitHubAccount {
        GitHubAccount(login: "rw")
    }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?,
        reusableViewerTeams: [ViewerTeam]?
    ) async throws -> CompletePullRequestFetchResult {
        await withCheckedContinuation { continuation in
            pullRequestsContinuation = continuation
        }
    }

    func finishPullRequestFetch() {
        pullRequestsContinuation?.resume(returning: CompletePullRequestFetchResult(activePullRequests: []))
        pullRequestsContinuation = nil
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: "rw")
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        GitHubAppInstallations(installations: [])
    }

}

@MainActor
private final class FailingLaunchAtLoginService: LaunchAtLoginServicing {
    enum TestError: Error { case failed }

    private(set) var isEnabled = false
    var fails = true

    func setEnabled(_ isEnabled: Bool) throws {
        if fails { throw TestError.failed }
        self.isEnabled = isEnabled
    }
}

private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    private(set) var requestedValues: [Bool] = []
    var isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ isEnabled: Bool) throws {
        requestedValues.append(isEnabled)
        self.isEnabled = isEnabled
    }
}

private func signedInSnapshotCache() -> PullRequestSnapshotCache {
    PullRequestSnapshotCache(
        pullRequests: [
            PullRequest(
                id: "PR_1",
                title: "Cached PR",
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
        fetchedAt: Date(timeIntervalSince1970: 1_777_800_000),
        source: .github
    )
}
