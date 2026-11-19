@testable import mergehawk
import Foundation
@testable import mergehawkcore
import XCTest

private final class IgnoredAuthorListProvider: GitHubProviding {
    struct InstallationsUnavailable: Error {}

    let sourceKind: DashboardSource = .github
    let result: CompletePullRequestFetchResult
    private(set) var fetchCount = 0

    init(_ result: CompletePullRequestFetchResult) { self.result = result }

    func fetchViewer() async throws -> GitHubAccount { GitHubAccount(login: "rw") }

    func fetchCompletePullRequests(
        login: String,
        previousState: PullRequestSyncState?,
        reusableViewerTeams: [ViewerTeam]?
    ) async throws -> CompletePullRequestFetchResult {
        fetchCount += 1
        return result
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        SourceCatalog(repositories: [], accountLogin: accountLogin)
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        throw InstallationsUnavailable()
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval, condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
}

final class IgnoredAuthorListTests: XCTestCase {
    private static let reviewers = TeamReference(id: "T_REVIEWERS", organization: "acme", slug: "reviewers")

    private static func pr(
        _ id: String,
        author: String,
        isBot: Bool? = false,
        repo: String = "acme/app",
        isMine: Bool = false,
        request: ReviewRequestKind = .direct,
        requestedTeams: [TeamReference] = [],
        stackID: String? = nil
    ) -> PullRequest {
        PullRequest(
            id: id, title: id, number: 1, url: URL(string: "https://github.com/\(repo)/pull/1")!, repo: repo,
            ciState: .passing, reviewDecision: .reviewRequired, commentCount: 0, reviewCount: 0,
            reviewRequestKind: request, requestedTeams: requestedTeams, isMine: isMine,
            author: author, authorIsBot: isBot, mergeable: .mergeable, draft: false, stackID: stackID
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
    private func makeController(
        _ result: CompletePullRequestFetchResult,
        authMethod: GitHubAuthMethod = .pat,
        configure: (inout PreferencesStore) -> Void = { _ in }
    ) throws -> (DashboardController, IgnoredAuthorListProvider) {
        let suiteName = "ignored-author-lists-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        var store = PreferencesStore(defaults: defaults)
        store.authMethod = authMethod
        configure(&store)
        let provider = IgnoredAuthorListProvider(result)
        let tokenStore: InMemoryTokenStore
        if authMethod == .oauth {
            tokenStore = InMemoryTokenStore()
            try tokenStore.storeOAuthTokens(
                OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
            )
        } else {
            tokenStore = InMemoryTokenStore(token: "pat")
        }
        let controller = DashboardController(
            tokenStore: tokenStore,
            preferencesStore: store,
            launchConfiguration: LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true),
            notificationClient: RecordingNotificationClient(),
            automaticRefreshInterval: 0,
            patGitHubClientFactory: { _ in provider },
            oauthGitHubClientFactory: { _ in provider }
        )
        waitUntil(timeout: 1) { provider.fetchCount == 1 && !controller.isRefreshing }
        return (controller, provider)
    }

    /// Requested PRs across every section, so the tests don't depend on how sections are grouped.
    @MainActor
    private static func requestedCount(_ controller: DashboardController) -> Int {
        controller.requestedSections.map(\.count).reduce(0, +)
    }

    @MainActor
    private static func requestedIDs(_ controller: DashboardController) -> Set<String> {
        Set(controller.requestedSections.flatMap { $0.visible + $0.hidden }.map(\.id))
    }

    @MainActor
    func testBotsToggleRemovesBotRequestsFromSectionsCountsAndHiddenWithoutARefresh() throws {
        let bot = Self.pr("PR_BOT", author: "dependabot", isBot: true)
        let hiddenBot = Self.pr("PR_BOT_HIDDEN", author: "renovate", isBot: true)
        let human = Self.pr("PR_HUMAN", author: "teammate")
        let (controller, provider) = try makeController(CompletePullRequestFetchResult(
            activePullRequests: [bot, hiddenBot, human]
        ))
        controller.hiddenPullRequestIds = [hiddenBot.id]
        XCTAssertEqual(Self.requestedIDs(controller), [bot.id, hiddenBot.id, human.id])
        XCTAssertEqual(Self.requestedCount(controller), 3)
        XCTAssertEqual(controller.hiddenReviewRequests.map(\.id), [hiddenBot.id])

        controller.ignoresBotPullRequests = true

        XCTAssertEqual(Self.requestedIDs(controller), [human.id])
        XCTAssertEqual(Self.requestedCount(controller), 1)
        XCTAssertEqual(controller.hiddenReviewRequests, [])

        controller.ignoresBotPullRequests = false

        XCTAssertEqual(Self.requestedIDs(controller), [bot.id, hiddenBot.id, human.id])
        XCTAssertEqual(Self.requestedCount(controller), 3)
        XCTAssertEqual(provider.fetchCount, 1)
    }

    @MainActor
    func testIgnoredAccountOverridesARepositoryWithEveryCheckboxOn() throws {
        let nora = Self.pr("PR_NORA", author: "platform-nora", repo: "acme/infra")
        let human = Self.pr("PR_HUMAN", author: "teammate", repo: "acme/infra")
        let (controller, provider) = try makeController(
            CompletePullRequestFetchResult(activePullRequests: [nora, human])
        ) { store in
            store.sourcePreferences = SourcePreferences(owners: ["acme": OwnerSourcePreferences(notifications: false, myPullRequests: false, reviewRequests: false)], repositories: ["acme/infra": RepositorySourcePreferences(
                notifications: .enabled, myPullRequests: .enabled, reviewRequests: .enabled
            )])
        }
        XCTAssertEqual(Self.requestedIDs(controller), [nora.id, human.id])

        controller.addIgnoredAccount("@Platform-Nora")

        XCTAssertEqual(Self.requestedIDs(controller), [human.id])
        XCTAssertEqual(Self.requestedCount(controller), 1)

        controller.removeIgnoredAccount("platform-nora")

        XCTAssertEqual(Self.requestedIDs(controller), [nora.id, human.id])
        XCTAssertEqual(provider.fetchCount, 1)
    }

    @MainActor
    func testIgnoringTheViewersOwnLoginEmptiesAuthored() throws {
        let own = Self.pr("PR_OWN", author: "rw", isMine: true, request: .none)
        let (controller, _) = try makeController(CompletePullRequestFetchResult(activePullRequests: [own]))
        XCTAssertEqual(controller.authoredList.visible.map(\.id), [own.id])
        XCTAssertEqual(controller.authoredList.count, 1)

        controller.addIgnoredAccount("RW")

        XCTAssertEqual(controller.authoredList.visible, [])
        XCTAssertEqual(controller.authoredList.hidden, [])
        XCTAssertEqual(controller.authoredList.count, 0)
    }

    @MainActor
    func testIgnoringKeepsPinnedAndHiddenStateAndLiftingItRestoresBoth() throws {
        let pinned = Self.pr("PR_PINNED_BOT", author: "dependabot", isBot: true)
        let hidden = Self.pr("PR_HIDDEN_BOT", author: "dependabot", isBot: true)
        let human = Self.pr("PR_HUMAN", author: "teammate")
        let (controller, _) = try makeController(
            CompletePullRequestFetchResult(activePullRequests: [pinned, hidden, human])
        )
        controller.pinnedPullRequestIds = [pinned.id]
        controller.hiddenPullRequestIds = [hidden.id]

        controller.ignoresBotPullRequests = true

        XCTAssertEqual(Self.requestedIDs(controller), [human.id])
        XCTAssertEqual(controller.hiddenReviewRequests, [])
        XCTAssertEqual(controller.pinnedPullRequestIds, [pinned.id])
        XCTAssertEqual(controller.hiddenPullRequestIds, [hidden.id])

        controller.ignoresBotPullRequests = false

        let pinnedSection = try XCTUnwrap(controller.requestedSections.first { $0.visible.contains { $0.id == pinned.id } })
        XCTAssertEqual(pinnedSection.visible.first?.id, pinned.id)
        XCTAssertEqual(pinnedSection.visible.first?.isPinned, true)
        XCTAssertEqual(controller.requestedSections.flatMap(\.hidden).map(\.id), [hidden.id])
        XCTAssertEqual(controller.hiddenReviewRequests.map(\.id), [hidden.id])
    }

    @MainActor
    func testStacksDropIgnoredMembersBeforeGrouping() throws {
        let onlyBot = Self.pr("PR_SOLO_BOT", author: "dependabot", isBot: true, stackID: "S_SOLO")
        let botBase = Self.pr("PR_MIXED_BOT", author: "dependabot", isBot: true, stackID: "S_MIXED")
        let humanTop = Self.pr("PR_MIXED_HUMAN", author: "teammate", stackID: "S_MIXED")
        let (controller, _) = try makeController(CompletePullRequestFetchResult(
            activePullRequests: [onlyBot, botBase, humanTop],
            stacks: [Self.stack("S_SOLO", [onlyBot]), Self.stack("S_MIXED", [botBase, humanTop])]
        ))
        XCTAssertEqual(Self.requestedCount(controller), 3)

        controller.ignoresBotPullRequests = true

        let rows = controller.requestedSections.flatMap { $0.visible + $0.hidden }
        XCTAssertFalse(rows.contains { $0.stack?.stack.id == "S_SOLO" || $0.id == onlyBot.id })
        let mixed = try XCTUnwrap(rows.first { $0.stack?.stack.id == "S_MIXED" }?.stack)
        XCTAssertEqual(mixed.fullMemberIDs, [humanTop.id])
        guard case .context(let entry) = try XCTUnwrap(mixed.members.first { $0.pullRequestID == botBase.id }) else {
            return XCTFail("The ignored member should be a context member")
        }
        XCTAssertEqual(entry.pullRequestID, botBase.id)
        XCTAssertEqual(Self.requestedCount(controller), 1)
    }

    @MainActor
    func testTeamsSettingsCountsKeepIgnoredPullRequests() throws {
        let bot = Self.pr("PR_BOT", author: "dependabot", isBot: true, request: .team, requestedTeams: [Self.reviewers])
        let human = Self.pr("PR_HUMAN", author: "teammate", request: .team, requestedTeams: [Self.reviewers])
        let (controller, _) = try makeController(CompletePullRequestFetchResult(
            activePullRequests: [bot, human],
            viewerTeams: [ViewerTeam(team: Self.reviewers)]
        ))

        controller.ignoresBotPullRequests = true

        XCTAssertEqual(Self.requestedIDs(controller), [human.id])
        XCTAssertEqual(controller.reviewTeamRows.map(\.pullRequestCount), [2])
    }

    @MainActor
    func testGitHubAppAccessPromptStillSeesIgnoredPullRequests() throws {
        let bot = Self.pr("PR_BOT", author: "dependabot", isBot: true)
        let own = Self.pr("PR_OWN", author: "rw", isMine: true, request: .none)
        let (controller, _) = try makeController(
            CompletePullRequestFetchResult(activePullRequests: [bot, own]),
            authMethod: .oauth
        )
        waitUntil(timeout: 1) { controller.gitHubAppRepositoryAccessStatus == .unknown }
        XCTAssertEqual(controller.sourceCatalog.repositoryCount, 0)
        XCTAssertFalse(controller.showsGitHubAppRepositoryAccessPrompt)

        controller.ignoresBotPullRequests = true
        controller.addIgnoredAccount("rw")

        XCTAssertEqual(Self.requestedIDs(controller), [])
        XCTAssertEqual(controller.authoredList.count, 0)
        XCTAssertFalse(controller.showsGitHubAppRepositoryAccessPrompt)
    }
}
