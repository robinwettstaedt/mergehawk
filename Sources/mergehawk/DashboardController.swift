import AppKit
import Foundation
import mergehawkcore

@MainActor
final class DashboardController: ObservableObject {
    enum MenuTab: String, CaseIterable, Identifiable {
        case notifications = "Notifications"
        case myPRs = "Authored"
        case reviewRequests = "Requested"

        var id: String { rawValue }
    }

    enum PullRequestSortOption: String, CaseIterable, Identifiable {
        case createdDate
        case updatedDate

        var id: String { rawValue }

        var label: String {
            switch self {
            case .createdDate:
                "Created"
            case .updatedDate:
                "Updated"
            }
        }
    }

    enum PullRequestFilterOption: String, CaseIterable, Identifiable {
        case all
        case needsAttention
        case draft
        case ready
        case changesRequested
        case reviewRequired
        case approved
        case ciFailing

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:
                "All"
            case .needsAttention:
                "Attention"
            case .draft:
                "Draft"
            case .ready:
                "Ready"
            case .changesRequested:
                "Changes requested"
            case .reviewRequired:
                "Review required"
            case .approved:
                "Approved"
            case .ciFailing:
                "CI failing"
            }
        }
    }

    enum ReviewRequestFilterOption: String, CaseIterable, Identifiable {
        case all
        case direct
        case team
        case draft
        case ready

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:
                "All"
            case .direct:
                "Direct"
            case .team:
                "Team"
            case .draft:
                "Draft"
            case .ready:
                "Ready"
            }
        }
    }

    @Published private(set) var state: DashboardState = .empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published var selectedTab: MenuTab = .notifications
    @Published var preferences: NotificationPreferences {
        didSet {
            preferencesStore.notificationPreferences = preferences
            syncEngine?.updatePreferences(preferences)
        }
    }
    @Published var refreshIntervalMinutes: Int {
        didSet {
            guard oldValue != refreshIntervalMinutes else {
                return
            }
            preferencesStore.refreshIntervalMinutes = refreshIntervalMinutes
            startAutomaticRefresh()
        }
    }
    @Published var pullRequestSortOption: PullRequestSortOption {
        didSet {
            preferencesStore.pullRequestSortOption = pullRequestSortOption
        }
    }
    @Published var selectedPullRequestFilters: Set<PullRequestFilterOption> {
        didSet {
            preferencesStore.selectedPullRequestFilters = selectedPullRequestFilters
        }
    }
    @Published var selectedReviewRequestFilters: Set<ReviewRequestFilterOption> {
        didSet {
            preferencesStore.selectedReviewRequestFilters = selectedReviewRequestFilters
        }
    }
    @Published var sourcePreferences: SourcePreferences {
        didSet {
            preferencesStore.sourcePreferences = sourcePreferences
        }
    }
    @Published var sourceCatalog: SourceCatalog {
        didSet {
            preferencesStore.sourceCatalog = sourceCatalog
        }
    }
    @Published var macOSLocalNotificationsEnabled: Bool {
        didSet {
            preferencesStore.macOSLocalNotificationsEnabled = macOSLocalNotificationsEnabled
        }
    }
    @Published private(set) var isRefreshingSources = false
    @Published private(set) var sourceCatalogSyncedAt: Date?
    @Published private(set) var sourceErrorMessage: String?
    @Published private(set) var startsAtLogin: Bool
    @Published private(set) var authMethod: GitHubAuthMethod = .oauth

    var openSettingsWindow: (() -> Void)?

    private let tokenStore: TokenStore
    private let oauthSignIn: GitHubOAuthSigningIn
    private let oauthAccessTokenCache: OAuthAccessTokenCache
    private let automaticRefreshIntervalOverride: TimeInterval?
    private let launchConfiguration: LaunchConfiguration
    private var preferencesStore: PreferencesStore
    private let launchAtLoginService: LaunchAtLoginServicing
    private let notificationClient: NotificationPosting
    private var sourceCatalogProvider: SourceCatalogProviding?
    private var syncEngine: SyncEngine?
    private var account: GitHubAccount?
    private var automaticRefreshTask: Task<Void, Never>?

    init(
        tokenStore: TokenStore = KeychainTokenStore(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        launchAtLoginService: LaunchAtLoginServicing? = nil,
        launchConfiguration: LaunchConfiguration = LaunchConfiguration.current(),
        notificationClient: NotificationPosting? = nil,
        automaticRefreshInterval: TimeInterval? = nil,
        oauthSignIn: GitHubOAuthSigningIn? = nil
    ) {
        self.tokenStore = tokenStore
        self.oauthSignIn = oauthSignIn ?? BrowserGitHubOAuthSignIn(tokenStore: tokenStore)
        self.oauthAccessTokenCache = OAuthAccessTokenCache(tokenStore: tokenStore)
        self.preferencesStore = preferencesStore
        self.launchConfiguration = launchConfiguration
        self.launchAtLoginService = launchAtLoginService
            ?? (launchConfiguration.usesMockData ? InMemoryLaunchAtLoginService() : LaunchAtLoginService())
        if let notificationClient {
            self.notificationClient = notificationClient
        } else if launchConfiguration.usesMockData || launchConfiguration.notificationLogPath != nil {
            self.notificationClient = RecordingNotificationClient(logPath: launchConfiguration.notificationLogPath)
        } else if launchConfiguration.suppressesMacOSNotifications {
            self.notificationClient = NoOpNotificationClient()
        } else {
            self.notificationClient = NotificationCenterClient()
        }
        self.automaticRefreshIntervalOverride = automaticRefreshInterval
        self.preferences = preferencesStore.notificationPreferences
        self.refreshIntervalMinutes = preferencesStore.refreshIntervalMinutes
        self.pullRequestSortOption = preferencesStore.pullRequestSortOption
        self.selectedPullRequestFilters = preferencesStore.selectedPullRequestFilters
        self.selectedReviewRequestFilters = preferencesStore.selectedReviewRequestFilters
        self.sourcePreferences = preferencesStore.sourcePreferences
        self.sourceCatalog = preferencesStore.sourceCatalog
        self.macOSLocalNotificationsEnabled = preferencesStore.macOSLocalNotificationsEnabled
        self.startsAtLogin = self.launchAtLoginService.isEnabled
        self.authMethod = preferencesStore.authMethod
        self.notificationClient.requestAuthorization()
        configureInitialSource()
        startAutomaticRefresh()
    }

    deinit {
        automaticRefreshTask?.cancel()
    }

    var hasAttention: Bool {
        !state.events.isEmpty
    }

    var attentionCount: Int {
        state.events.count
    }

    var accountLabel: String {
        state.account?.login ?? "Not signed in"
    }

    var sourceLabel: String {
        switch state.source {
        case .none:
            return "None"
        case .github:
            return "GitHub"
        case .mock:
            return "Mock"
        }
    }

    var refreshIntervalOptions: [Int] {
        PreferencesStore.refreshIntervalMinuteOptions
    }

    var sortedMyPullRequests: [PullRequest] {
        let mine = state.pullRequests.filter { pr in
            pr.isMine && sourcePreferences.allowsMyPullRequests(for: pr.repo)
        }
        return Self.sorted(
            Self.filtered(mine, by: selectedPullRequestFilters, events: state.events),
            by: pullRequestSortOption
        )
    }

    var sortedReviewRequests: [PullRequest] {
        Self.sorted(
            Self.filteredReviewRequests(
                state.pullRequests.filter { sourcePreferences.allowsReviewRequests(for: $0.repo) },
                by: selectedReviewRequestFilters
            ),
            by: pullRequestSortOption
        )
    }

    static func filtered(
        _ pullRequests: [PullRequest],
        by selectedFilters: Set<PullRequestFilterOption>,
        events: [PullRequestEvent]
    ) -> [PullRequest] {
        let selectedFilters = selectedFilters.subtracting([.all])
        guard !selectedFilters.isEmpty else {
            return pullRequests
        }
        let attentionIds = Set(events.map(\.prId))
        return pullRequests.filter { pr in
            selectedFilters.contains { option in
                matches(pr, option: option, attentionIds: attentionIds)
            }
        }
    }

    private static func matches(
        _ pr: PullRequest,
        option: PullRequestFilterOption,
        attentionIds: Set<String>
    ) -> Bool {
        switch option {
        case .all:
            true
        case .needsAttention:
            attentionIds.contains(pr.id)
        case .draft:
            pr.draft
        case .ready:
            !pr.draft
        case .changesRequested:
            pr.reviewDecision == .changesRequested
        case .reviewRequired:
            pr.reviewDecision == .reviewRequired
        case .approved:
            pr.reviewDecision == .approved
        case .ciFailing:
            pr.ciState == .failing
        }
    }

    static func filteredReviewRequests(
        _ pullRequests: [PullRequest],
        by selectedFilters: Set<ReviewRequestFilterOption>
    ) -> [PullRequest] {
        let selectedFilters = selectedFilters.subtracting([.all])
        return pullRequests.filter { pr in
            guard pr.reviewRequestKind != .none else {
                return false
            }
            guard !selectedFilters.isEmpty else {
                return true
            }
            return selectedFilters.contains { option in
                matchesReviewRequest(pr, option: option)
            }
        }
    }

    private static func matchesReviewRequest(
        _ pr: PullRequest,
        option: ReviewRequestFilterOption
    ) -> Bool {
        switch option {
        case .direct:
            pr.reviewRequestKind.includesDirect
        case .team:
            pr.reviewRequestKind.includesTeam
        case .all:
            true
        case .draft:
            pr.draft
        case .ready:
            !pr.draft
        }
    }

    static func sorted(_ pullRequests: [PullRequest], by option: PullRequestSortOption) -> [PullRequest] {
        pullRequests.sorted { lhs, rhs in
            switch option {
            case .createdDate:
                compare(lhs, rhs, by: \.createdAt)
            case .updatedDate:
                compare(lhs, rhs, by: \.updatedAt)
            }
        }
    }

    func refresh() {
        Task {
            await sync()
        }
    }

    func signInWithToken(_ token: String) async {
        errorMessage = nil
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Paste a GitHub personal access token."
            return
        }

        do {
            let client = GitHubClient(token: trimmed)
            let viewer = try await client.fetchViewer()
            oauthAccessTokenCache.clear()
            try tokenStore.clearOAuthTokens()
            try tokenStore.storePAT(trimmed)
            account = viewer
            configureGitHubSource(tokenProvider: { trimmed }, account: viewer, authMethod: .pat)
            await fetchSourceCatalog()
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signInWithGitHub() async {
        errorMessage = nil

        do {
            let tokens = try await oauthSignIn.signIn()
            oauthAccessTokenCache.store(tokens)
            try tokenStore.clearPAT()
            let client = makeOAuthGitHubClient()
            let viewer = try await client.fetchViewer()
            account = viewer
            configureGitHubSource(
                tokenProvider: makeOAuthAccessTokenProvider(),
                account: viewer,
                authMethod: .oauth
            )
            await fetchSourceCatalog()
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        do {
            oauthAccessTokenCache.clear()
            try tokenStore.clear()
        } catch {
            errorMessage = error.localizedDescription
        }
        account = nil
        setAuthMethod(.oauth)
        sourceCatalogProvider = nil
        sourceCatalog = .empty
        sourceErrorMessage = nil
        configureSignedOutSource()
        refresh()
    }

    func showSettings() {
        openSettingsWindow?()
    }

    func setStartsAtLogin(_ startsAtLogin: Bool) {
        errorMessage = nil
        do {
            try launchAtLoginService.setEnabled(startsAtLogin)
            self.startsAtLogin = launchAtLoginService.isEnabled
        } catch {
            self.startsAtLogin = launchAtLoginService.isEnabled
            errorMessage = error.localizedDescription
        }
    }

    func setOwnerPreferences(owner: String, preferences: OwnerSourcePreferences) {
        sourcePreferences.owners[owner] = preferences
        trimVisibleEvents()
    }

    func setRepositoryPreferences(repo: String, preferences: RepositorySourcePreferences) {
        sourcePreferences.repositories[repo] = preferences
        trimVisibleEvents()
    }

    func refreshSources() {
        Task {
            await fetchSourceCatalog()
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func dismissEvent(_ event: PullRequestEvent) {
        state.events.removeAll { $0.id == event.id }
    }

    func dismissAllEvents() {
        state.events.removeAll()
    }

    private func trimVisibleEvents() {
        state.events.removeAll { event in
            guard let pullRequest = state.pullRequests.first(where: { $0.id == event.prId }) else {
                return false
            }
            return !sourcePreferences.allowsNotifications(for: pullRequest.repo)
        }
    }

    private func configureInitialSource() {
        if launchConfiguration.usesMockData {
            configureMockSource()
            refresh()
            return
        }

        do {
            if let tokens = try tokenStore.loadOAuthTokens() {
                oauthAccessTokenCache.store(tokens)
                configureStoredOAuthSource()
            } else if preferencesStore.authMethod == .pat, let token = try tokenStore.loadPAT() {
                configureStoredPATSource(token: token)
            } else {
                configureSignedOutSource()
                refresh()
            }
        } catch {
            errorMessage = error.localizedDescription
            configureSignedOutSource()
            refresh()
        }
    }

    private func configureStoredOAuthSource() {
        configureStoredGitHubSource(client: makeOAuthGitHubClient(), authMethod: .oauth)
    }

    private func configureStoredPATSource(token: String) {
        configureStoredGitHubSource(client: GitHubClient(token: token), authMethod: .pat)
    }

    private func configureStoredGitHubSource(client: GitHubClient, authMethod: GitHubAuthMethod) {
        configureGitHubSource(
            client: client,
            authMethod: authMethod,
            loginProvider: { [weak self] in
                if let login = self?.account?.login {
                    return login
                }
                let viewer = try await client.fetchViewer()
                await MainActor.run {
                    self?.account = viewer
                }
                return viewer.login
            },
            accountProvider: { [weak self] in self?.account }
        )
        Task {
            await sync()
            await fetchSourceCatalog()
        }
    }

    private func configureGitHubSource(
        tokenProvider: @escaping @Sendable () async throws -> String,
        account: GitHubAccount,
        authMethod: GitHubAuthMethod
    ) {
        configureGitHubSource(
            client: GitHubClient(tokenProvider: tokenProvider),
            authMethod: authMethod,
            loginProvider: { account.login },
            accountProvider: { account }
        )
    }

    private func configureGitHubSource(
        client: GitHubClient,
        authMethod: GitHubAuthMethod,
        loginProvider: @escaping () async throws -> String,
        accountProvider: @escaping () async throws -> GitHubAccount?
    ) {
        sourceCatalogProvider = client
        setAuthMethod(authMethod)
        syncEngine = SyncEngine(
            source: client,
            preferences: preferences,
            loginProvider: loginProvider,
            accountProvider: accountProvider,
            authStatusProvider: { .signedIn },
            sourcePreferencesProvider: { [weak self] in self?.sourcePreferences ?? .defaults }
        )
    }

    private func configureSignedOutSource() {
        setAuthMethod(.oauth)
        sourceCatalog = .empty
        sourceCatalogProvider = nil
        let source = EmptyPullRequestSource()
        syncEngine = SyncEngine(
            source: source,
            preferences: preferences,
            loginProvider: { "rw" },
            accountProvider: { nil },
            authStatusProvider: { .signedOut },
            sourcePreferencesProvider: { [weak self] in self?.sourcePreferences ?? .defaults }
        )
    }

    private func configureMockSource() {
        let account = GitHubAccount(login: "agent-fixture")
        self.account = account
        setAuthMethod(.oauth)
        let source = MockPullRequestSource()
        sourceCatalogProvider = source
        sourceCatalog = source.mockSourceCatalog(accountLogin: account.login)
        sourceCatalogSyncedAt = Date()
        syncEngine = SyncEngine(
            source: source,
            preferences: preferences,
            loginProvider: { account.login },
            accountProvider: { account },
            authStatusProvider: { .signedIn },
            sourcePreferencesProvider: { [weak self] in self?.sourcePreferences ?? .defaults }
        )
    }

    private func makeOAuthGitHubClient() -> GitHubClient {
        GitHubClient(tokenProvider: makeOAuthAccessTokenProvider())
    }

    private func makeOAuthAccessTokenProvider() -> @Sendable () async throws -> String {
        let oauthAccessTokenCache = oauthAccessTokenCache
        return {
            try await oauthAccessTokenCache.accessToken()
        }
    }

    private func setAuthMethod(_ authMethod: GitHubAuthMethod) {
        self.authMethod = authMethod
        preferencesStore.authMethod = authMethod
    }

    private func fetchSourceCatalog() async {
        guard let sourceCatalogProvider else {
            return
        }
        guard !isRefreshingSources else {
            return
        }
        isRefreshingSources = true
        sourceErrorMessage = nil
        do {
            sourceCatalog = try await sourceCatalogProvider.fetchSourceCatalog(
                accountLogin: account?.login ?? state.account?.login
            )
            sourceCatalogSyncedAt = Date()
        } catch {
            if isAuthenticationFailure(error) {
                handleAuthenticationFailure(error)
            } else {
                sourceErrorMessage = error.localizedDescription
            }
        }
        isRefreshingSources = false
    }

    private func sync() async {
        guard let syncEngine else {
            return
        }
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        errorMessage = nil
        do {
            let nextState = try await syncEngine.sync()
            state = nextState
            if macOSLocalNotificationsEnabled {
                notificationClient.post(events: nextState.events, pullRequests: nextState.pullRequests)
            }
        } catch {
            if isAuthenticationFailure(error) {
                handleAuthenticationFailure(error)
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isRefreshing = false
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        if let error = error as? GitHubClientError {
            switch error {
            case .authRefreshFailed:
                return true
            case .httpFailure, .graphQLErrors:
                break
            }
        }
        if let error = error as? GitHubOAuthError {
            switch error {
            case .missingStoredCredentials:
                return true
            case .missingClientCredentials:
                break
            }
        }
        return false
    }

    private func handleAuthenticationFailure(_ error: Error) {
        oauthAccessTokenCache.clear()
        try? tokenStore.clearOAuthTokens()
        account = nil
        sourceCatalog = .empty
        sourceErrorMessage = nil
        configureSignedOutSource()
        errorMessage = error.localizedDescription
    }

    private func startAutomaticRefresh() {
        let automaticRefreshInterval = automaticRefreshIntervalOverride
            ?? TimeInterval(refreshIntervalMinutes * 60)
        guard automaticRefreshInterval > 0 else {
            return
        }

        automaticRefreshTask?.cancel()
        let intervalNanoseconds = UInt64(automaticRefreshInterval * 1_000_000_000)
        automaticRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    break
                }

                guard !Task.isCancelled else {
                    break
                }

                guard let self else {
                    break
                }
                await self.sync()
            }
        }
    }

    private static func compare<Value: Comparable>(
        _ lhs: PullRequest,
        _ rhs: PullRequest,
        by value: (PullRequest) -> Value
    ) -> Bool {
        let lhsValue = value(lhs)
        let rhsValue = value(rhs)
        if lhsValue != rhsValue {
            return lhsValue > rhsValue
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        if lhs.repo != rhs.repo {
            return lhs.repo < rhs.repo
        }
        return lhs.number > rhs.number
    }

}
