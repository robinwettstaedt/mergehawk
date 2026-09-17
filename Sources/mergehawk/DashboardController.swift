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

    enum NotificationSubtab: String, CaseIterable, Identifiable {
        case pullRequests = "PRs"
        case other = "Other"

        var id: String { rawValue }
    }

    enum GitHubAppRepositoryAccessStatus: Equatable {
        case notApplicable
        case unknown
        case checking
        case noInstallations
        case noVisibleRepositories
        case configured

        var needsUserAction: Bool {
            switch self {
            case .noInstallations, .noVisibleRepositories:
                true
            case .notApplicable, .unknown, .checking, .configured:
                false
            }
        }

        static func resolved(installations: GitHubAppInstallations, sourceCatalog: SourceCatalog) -> Self {
            guard !installations.installations.isEmpty else {
                return .noInstallations
            }
            guard sourceCatalog.repositoryCount > 0 else {
                return .noVisibleRepositories
            }
            return .configured
        }
    }

    enum DeviceFlowPhase {
        case enterCode
        case loadingApp
    }

    enum PullRequestSortOption: String, CaseIterable, Identifiable {
        case createdDate
        case updatedDate
        case changeSize

        var id: String { rawValue }

        var label: String {
            switch self {
            case .createdDate:
                "Created"
            case .updatedDate:
                "Updated"
            case .changeSize:
                "Change size"
            }
        }

        func directionHelp(for direction: PullRequestSortDirection) -> String {
            switch self {
            case .createdDate, .updatedDate:
                direction.isAscending ? "Sorted oldest first" : "Sorted newest first"
            case .changeSize:
                direction.isAscending ? "Sorted smallest first" : "Sorted largest first"
            }
        }
    }

    enum PullRequestSortDirection: String, CaseIterable, Identifiable {
        case descending
        case ascending

        var id: String { rawValue }

        var isAscending: Bool { self == .ascending }

        var toggled: PullRequestSortDirection {
            self == .ascending ? .descending : .ascending
        }
    }

    enum PullRequestFilterOption: String, CaseIterable, Identifiable {
        case all
        case needsAttention
        case draft
        case ready
        case changesRequested
        case noReviewYet = "reviewRequired"
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
            case .noReviewYet:
                "No review yet"
            case .approved:
                "Approved"
            case .ciFailing:
                "CI failing"
            }
        }
    }

    enum ReviewRequestFilterOption: String, CaseIterable, Identifiable {
        case all
        case draft
        case ready

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:
                "All"
            case .draft:
                "Draft"
            case .ready:
                "Ready"
            }
        }
    }

    enum RequestedSection: String, CaseIterable, Identifiable {
        case assigned
        case direct
        case team

        var id: String { rawValue }

        var title: String {
            switch self {
            case .assigned: "Assigned"
            case .direct: "Direct"
            case .team: "Team"
            }
        }

        static func section(for pullRequest: PullRequest) -> Self? {
            guard !pullRequest.isMine else { return nil }
            if pullRequest.isAssignedToViewer { return .assigned }
            if pullRequest.reviewRequestKind.includesDirect { return .direct }
            if pullRequest.reviewRequestKind.includesTeam { return .team }
            return nil
        }
    }

    struct RequestedSectionContent {
        let section: RequestedSection
        let visible: [PullRequest]
        let hidden: [PullRequest]

        var count: Int { visible.count + hidden.count }
    }

    @Published private(set) var state: DashboardState = .empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published var selectedTab: MenuTab = .notifications
    @Published var selectedNotificationSubtab: NotificationSubtab = .pullRequests
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
    @Published var pullRequestSortDirection: PullRequestSortDirection {
        didSet {
            preferencesStore.pullRequestSortDirection = pullRequestSortDirection
        }
    }
    @Published var reviewRequestSortOption: PullRequestSortOption {
        didSet {
            preferencesStore.reviewRequestSortOption = reviewRequestSortOption
        }
    }
    @Published var reviewRequestSortDirection: PullRequestSortDirection {
        didSet {
            preferencesStore.reviewRequestSortDirection = reviewRequestSortDirection
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
    @Published private(set) var collapsedRequestedSections: Set<RequestedSection> = []
    @Published var pinnedPullRequestIds: Set<String> {
        didSet {
            preferencesStore.pinnedPullRequestIds = pinnedPullRequestIds
        }
    }
    @Published var hiddenPullRequestIds: Set<String> {
        didSet {
            preferencesStore.hiddenPullRequestIds = hiddenPullRequestIds
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
    @Published private(set) var gitHubAppRepositoryAccessStatus: GitHubAppRepositoryAccessStatus = .notApplicable
    private var gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
    @Published private(set) var startsAtLogin: Bool
    @Published private(set) var authMethod: GitHubAuthMethod = .oauth

    var openSettingsWindow: ((SettingsTab) -> Void)?
    var openGitHubSettingsInPATMode = false
    var showDeviceFlowSignInMenu: (() -> Void)?

    @Published private(set) var deviceFlowChallenge: DeviceFlowChallenge?
    @Published private(set) var deviceFlowPhase: DeviceFlowPhase?
    @Published private(set) var deviceFlowCodeCopiedAt: Date?
    @Published private(set) var isRequestingDeviceCode = false
    @Published private(set) var isSigningInWithToken = false
    private var signInTask: Task<Void, Never>?
    private var deviceFlowCodeCopiedClearTask: Task<Void, Never>?
    private var signInAttemptID = 0

    private let tokenStore: TokenStore
    private let oauthSignIn: GitHubOAuthSigningIn
    private let oauthAccessTokenCache: OAuthAccessTokenCache
    private let patGitHubClientFactory: (String) -> any GitHubProviding
    private let oauthGitHubClientFactory: (@escaping @Sendable () async throws -> String) -> any GitHubProviding
    private let automaticRefreshIntervalOverride: TimeInterval?
    private let launchConfiguration: LaunchConfiguration
    private var preferencesStore: PreferencesStore
    private let launchAtLoginService: LaunchAtLoginServicing
    private let notificationClient: NotificationPosting
    private var sourceCatalogProvider: SourceCatalogProviding?
    private var gitHubAppInstallationProvider: GitHubAppInstallationProviding?
    private var gitHubInboxProvider: GitHubInboxProviding?
    private let openURL: @MainActor (URL) -> Void
    private let openDeviceFlowURL: @MainActor (URL) -> Void
    private let copyStringToClipboard: @MainActor (String) -> Void
    private let now: @MainActor () -> Date
    private var syncEngine: SyncEngine?
    private var account: GitHubAccount?
    private var automaticRefreshTask: Task<Void, Never>?
    private var isRefreshingInbox = false
    @Published private(set) var pullRequestNotificationHistory: [PullRequestNotification] {
        didSet {
            preferencesStore.pullRequestNotificationHistory = pullRequestNotificationHistory
        }
    }
    @Published private(set) var gitHubInboxNotifications: [GitHubInboxNotification] {
        didSet {
            preferencesStore.gitHubInboxNotifications = gitHubInboxNotifications
        }
    }
    private var gitHubInboxSyncMetadata: GitHubInboxSyncMetadata {
        didSet {
            preferencesStore.gitHubInboxSyncMetadata = gitHubInboxSyncMetadata
        }
    }

    init(
        tokenStore: TokenStore = KeychainTokenStore(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        launchAtLoginService: LaunchAtLoginServicing? = nil,
        launchConfiguration: LaunchConfiguration = LaunchConfiguration.current(),
        notificationClient: NotificationPosting? = nil,
        automaticRefreshInterval: TimeInterval? = nil,
        oauthSignIn: GitHubOAuthSigningIn? = nil,
        patGitHubClientFactory: @escaping (String) -> any GitHubProviding = { GitHubClient(token: $0) },
        oauthGitHubClientFactory: @escaping (@escaping @Sendable () async throws -> String) -> any GitHubProviding = {
            GitHubClient(tokenProvider: $0)
        },
        urlOpener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        deviceFlowURLOpener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        clipboardWriter: @escaping @MainActor (String) -> Void = DashboardController.copyToPasteboard,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.tokenStore = tokenStore
        self.oauthSignIn = oauthSignIn ?? GitHubDeviceFlowSignIn()
        self.oauthAccessTokenCache = OAuthAccessTokenCache(tokenStore: tokenStore)
        self.preferencesStore = preferencesStore
        self.launchConfiguration = launchConfiguration
        self.openURL = urlOpener
        self.openDeviceFlowURL = deviceFlowURLOpener
        self.copyStringToClipboard = clipboardWriter
        self.now = now
        self.patGitHubClientFactory = patGitHubClientFactory
        self.oauthGitHubClientFactory = oauthGitHubClientFactory
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
        self.pullRequestSortDirection = preferencesStore.pullRequestSortDirection
        self.reviewRequestSortOption = preferencesStore.reviewRequestSortOption
        self.reviewRequestSortDirection = preferencesStore.reviewRequestSortDirection
        self.selectedPullRequestFilters = preferencesStore.selectedPullRequestFilters
        self.selectedReviewRequestFilters = preferencesStore.selectedReviewRequestFilters
        self.pinnedPullRequestIds = preferencesStore.pinnedPullRequestIds
        self.hiddenPullRequestIds = preferencesStore.hiddenPullRequestIds
        self.sourcePreferences = preferencesStore.sourcePreferences
        self.sourceCatalog = preferencesStore.sourceCatalog
        self.macOSLocalNotificationsEnabled = preferencesStore.macOSLocalNotificationsEnabled
        self.startsAtLogin = self.launchAtLoginService.isEnabled
        self.authMethod = preferencesStore.authMethod
        self.pullRequestNotificationHistory = preferencesStore.pullRequestNotificationHistory
        self.gitHubInboxNotifications = preferencesStore.gitHubInboxNotifications
        self.gitHubInboxSyncMetadata = preferencesStore.gitHubInboxSyncMetadata
        self.notificationClient.requestAuthorization()
        configureInitialSource()
        startAutomaticRefresh()
    }

    deinit {
        automaticRefreshTask?.cancel()
    }

    var hasAttention: Bool {
        visiblePullRequestNotifications.contains { !$0.read }
    }

    var attentionCount: Int {
        visiblePullRequestNotifications.filter { !$0.read }.count
    }

    var visiblePullRequestNotifications: [PullRequestNotification] {
        pullRequestNotificationHistory
            .filter { sourcePreferences.allowsNotifications(for: $0.repo) }
            .sorted(by: Self.compareNotifications)
    }

    var visibleGitHubInboxNotifications: [GitHubInboxNotification] {
        gitHubInboxNotifications
            .filter { sourcePreferences.allowsNotifications(for: $0.repo) }
            .sorted(by: Self.compareInboxNotifications)
    }

    var showsGitHubInboxUnavailableHint: Bool {
        state.authStatus == .signedIn
            && gitHubInboxProvider == nil
            && !launchConfiguration.usesMockData
    }

    var showsGitHubAppRepositoryAccessPrompt: Bool {
        guard state.authStatus == .signedIn
            && authMethod == .oauth
            && !launchConfiguration.usesMockData
        else {
            return false
        }

        switch gitHubAppRepositoryAccessStatus {
        case .noInstallations:
            return true
        case .noVisibleRepositories, .unknown:
            return !hasGitHubAppVisiblePullRequestData && sourceCatalog.repositoryCount == 0
        case .notApplicable, .checking, .configured:
            return false
        }
    }

    private var hasGitHubAppVisiblePullRequestData: Bool {
        !sourceFilteredMyPullRequests.isEmpty
            || sourceFilteredReviewRequests.contains(where: Self.isRequestedPullRequest)
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

    var sourceFilteredMyPullRequests: [PullRequest] {
        state.pullRequests.filter { pr in
            pr.isMine && sourcePreferences.allowsMyPullRequests(for: pr.repo)
        }
    }

    var sourceFilteredReviewRequests: [PullRequest] {
        state.pullRequests.filter { pr in
            sourcePreferences.allowsReviewRequests(for: pr.repo)
        }
    }

    var sortedMyPullRequests: [PullRequest] {
        Self.sortedWithPins(
            filteredMyPullRequests.filter { !hiddenPullRequestIds.contains($0.id) },
            pinnedIds: pinnedPullRequestIds,
            by: pullRequestSortOption,
            direction: pullRequestSortDirection
        )
    }

    var hiddenMyPullRequests: [PullRequest] {
        Self.sorted(
            filteredMyPullRequests.filter { hiddenPullRequestIds.contains($0.id) },
            by: pullRequestSortOption,
            direction: pullRequestSortDirection
        )
    }

    var sortedReviewRequests: [PullRequest] {
        Self.sortedWithPins(
            filteredReviewRequests.filter { !hiddenPullRequestIds.contains($0.id) },
            pinnedIds: pinnedPullRequestIds,
            by: reviewRequestSortOption,
            direction: reviewRequestSortDirection
        )
    }

    var hiddenReviewRequests: [PullRequest] {
        Self.sorted(
            filteredReviewRequests.filter { hiddenPullRequestIds.contains($0.id) },
            by: reviewRequestSortOption,
            direction: reviewRequestSortDirection
        )
    }

    var requestedSections: [RequestedSectionContent] {
        let visible = sortedReviewRequests
        let hidden = hiddenReviewRequests
        return RequestedSection.allCases.map { section in
            RequestedSectionContent(
                section: section,
                visible: visible.filter { RequestedSection.section(for: $0) == section },
                hidden: hidden.filter { RequestedSection.section(for: $0) == section }
            )
        }
    }

    func isRequestedSectionExpanded(_ section: RequestedSection) -> Bool {
        !collapsedRequestedSections.contains(section)
    }

    func toggleRequestedSection(_ section: RequestedSection) {
        if collapsedRequestedSections.contains(section) {
            collapsedRequestedSections.remove(section)
        } else {
            collapsedRequestedSections.insert(section)
        }
    }

    func toggleAllRequestedSections(from section: RequestedSection) {
        collapsedRequestedSections = isRequestedSectionExpanded(section)
            ? Set(RequestedSection.allCases)
            : []
    }

    private var filteredMyPullRequests: [PullRequest] {
        Self.filtered(
            sourceFilteredMyPullRequests,
            by: selectedPullRequestFilters,
            attentionPullRequestIds: unreadPullRequestNotificationIds
        )
    }

    private var filteredReviewRequests: [PullRequest] {
        Self.filteredReviewRequests(
            sourceFilteredReviewRequests,
            by: selectedReviewRequestFilters
        )
    }

    private var unreadPullRequestNotificationIds: Set<String> {
        Set(visiblePullRequestNotifications.filter { !$0.read }.map(\.prId))
    }

    static func filtered(
        _ pullRequests: [PullRequest],
        by selectedFilters: Set<PullRequestFilterOption>,
        events: [PullRequestEvent]
    ) -> [PullRequest] {
        filtered(
            pullRequests,
            by: selectedFilters,
            attentionPullRequestIds: Set(events.map(\.prId))
        )
    }

    static func filtered(
        _ pullRequests: [PullRequest],
        by selectedFilters: Set<PullRequestFilterOption>,
        attentionPullRequestIds: Set<String>
    ) -> [PullRequest] {
        let selectedFilters = selectedFilters.subtracting([.all])
        guard !selectedFilters.isEmpty else {
            return pullRequests
        }
        return pullRequests.filter { pr in
            selectedFilters.contains { option in
                matches(pr, option: option, attentionIds: attentionPullRequestIds)
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
        case .noReviewYet:
            pr.reviewDecision == .noReviewYet
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
            guard isRequestedPullRequest(pr) else {
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

    static func isRequestedPullRequest(_ pr: PullRequest) -> Bool {
        RequestedSection.section(for: pr) != nil
    }

    private static func matchesReviewRequest(
        _ pr: PullRequest,
        option: ReviewRequestFilterOption
    ) -> Bool {
        switch option {
        case .all:
            true
        case .draft:
            pr.draft
        case .ready:
            !pr.draft
        }
    }

    static func sorted(
        _ pullRequests: [PullRequest],
        by option: PullRequestSortOption,
        direction: PullRequestSortDirection = .descending
    ) -> [PullRequest] {
        let ascending = direction.isAscending
        return pullRequests.sorted { lhs, rhs in
            switch option {
            case .createdDate:
                compare(lhs, rhs, by: \.createdAt, ascending: ascending)
            case .updatedDate:
                compare(lhs, rhs, by: \.updatedAt, ascending: ascending)
            case .changeSize:
                compare(lhs, rhs, by: changeSize, ascending: ascending)
            }
        }
    }

    static func sortedWithPins(
        _ pullRequests: [PullRequest],
        pinnedIds: Set<String>,
        by option: PullRequestSortOption,
        direction: PullRequestSortDirection = .descending
    ) -> [PullRequest] {
        let pinned = pullRequests.filter { pinnedIds.contains($0.id) }
        let unpinned = pullRequests.filter { !pinnedIds.contains($0.id) }
        return sorted(pinned, by: option, direction: direction)
            + sorted(unpinned, by: option, direction: direction)
    }

    func refresh() {
        Task {
            await refreshDashboard(appliesMockRefreshDelay: true)
        }
    }

    func signInWithToken(_ token: String) async {
        guard !isSigningInWithToken else { return }
        cancelDeviceFlowSignIn()
        errorMessage = nil
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Paste a GitHub personal access token."
            return
        }
        isSigningInWithToken = true
        defer { isSigningInWithToken = false }

        do {
            let client = patGitHubClientFactory(trimmed)
            let viewer = try await client.fetchViewer()
            oauthAccessTokenCache.clear()
            try tokenStore.clearOAuthTokens()
            try tokenStore.storePAT(trimmed)
            account = viewer
            configureGitHubSource(
                client: client,
                authMethod: .pat,
                allowsGitHubInboxNotifications: GitHubTokenCapabilities
                    .supportsGitHubInboxNotifications(token: trimmed),
                loginProvider: { viewer.login },
                accountProvider: { viewer }
            )
            await fetchSourceCatalog()
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signInWithGitHub(keepsMenuVisible: Bool = false) async {
        guard !isSigningInWithToken else { return }
        cancelDeviceFlowSignIn()
        let attemptID = signInAttemptID
        errorMessage = nil
        isRequestingDeviceCode = true

        let challenge: DeviceFlowChallenge
        do {
            challenge = try await oauthSignIn.requestDeviceCode()
        } catch {
            guard isCurrentSignInAttempt(attemptID) else { return }
            isRequestingDeviceCode = false
            errorMessage = error.localizedDescription
            return
        }
        guard isCurrentSignInAttempt(attemptID) else { return }

        deviceFlowChallenge = challenge
        deviceFlowPhase = .enterCode
        isRequestingDeviceCode = false
        openDeviceFlowURL(challenge.verificationURI)
        if keepsMenuVisible {
            showDeviceFlowSignInMenu?()
        }

        signInTask = Task { [weak self] in
            await self?.completeDeviceFlowSignIn(challenge: challenge, attemptID: attemptID)
        }
    }

    func copyDeviceFlowUserCode() {
        guard let code = deviceFlowChallenge?.userCode else {
            return
        }
        copyStringToClipboard(code)
        let copiedAt = now()
        deviceFlowCodeCopiedAt = copiedAt
        deviceFlowCodeCopiedClearTask?.cancel()
        deviceFlowCodeCopiedClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.deviceFlowCodeCopiedAt == copiedAt else {
                    return
                }
                self?.deviceFlowCodeCopiedAt = nil
                self?.deviceFlowCodeCopiedClearTask = nil
            }
        }
    }

    private func completeDeviceFlowSignIn(challenge: DeviceFlowChallenge, attemptID: Int) async {
        defer {
            if isCurrentSignInAttempt(attemptID) {
                signInTask = nil
            }
        }

        do {
            let tokens = try await oauthSignIn.pollForTokens(challenge: challenge)
            guard shouldContinueSignIn(attemptID) else { return }
            deviceFlowPhase = .loadingApp
            oauthAccessTokenCache.store(tokens)
            let client = makeOAuthGitHubClient()
            let viewer = try await client.fetchViewer()
            guard shouldContinueSignIn(attemptID) else { return }
            account = viewer
            configureGitHubSource(
                client: client,
                authMethod: .oauth,
                allowsGitHubInboxNotifications: false,
                loginProvider: { viewer.login },
                accountProvider: { viewer }
            )
            await fetchSourceCatalog()
            guard shouldContinueSignIn(attemptID) else { return }
            await sync()
            guard shouldContinueSignIn(attemptID) else { return }
            try tokenStore.storeOAuthTokens(tokens)
            try tokenStore.clearPAT()
            deviceFlowChallenge = nil
            deviceFlowPhase = nil
            clearDeviceFlowCodeCopiedState()
        } catch {
            guard isCurrentSignInAttempt(attemptID) else { return }
            deviceFlowChallenge = nil
            deviceFlowPhase = nil
            clearDeviceFlowCodeCopiedState()
            if Task.isCancelled || error is CancellationError { return }
            errorMessage = error.localizedDescription
        }
    }

    func cancelDeviceFlowSignIn() {
        signInAttemptID += 1
        signInTask?.cancel()
        signInTask = nil
        deviceFlowChallenge = nil
        deviceFlowPhase = nil
        clearDeviceFlowCodeCopiedState()
        isRequestingDeviceCode = false
    }

    private func clearDeviceFlowCodeCopiedState() {
        deviceFlowCodeCopiedClearTask?.cancel()
        deviceFlowCodeCopiedClearTask = nil
        deviceFlowCodeCopiedAt = nil
    }

    func signOut() {
        cancelDeviceFlowSignIn()
        do {
            oauthAccessTokenCache.clear()
            try tokenStore.clear()
        } catch {
            errorMessage = error.localizedDescription
        }
        account = nil
        preferencesStore.pullRequestSnapshotCache = .empty
        pullRequestNotificationHistory = []
        gitHubInboxNotifications = []
        gitHubInboxSyncMetadata = .empty
        setAuthMethod(.oauth)
        sourceCatalogProvider = nil
        gitHubAppInstallationProvider = nil
        gitHubAppRepositoryAccessStatus = .notApplicable
        gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
        sourceCatalog = .empty
        sourceErrorMessage = nil
        configureSignedOutSource()
        refresh()
    }

    func showSettings(selection: SettingsTab = .general) {
        openSettingsWindow?(selection)
    }

    func showGitHubSettings(patMode: Bool = false) {
        openGitHubSettingsInPATMode = patMode
        openSettingsWindow?(.github)
    }

    private func isCurrentSignInAttempt(_ attemptID: Int) -> Bool {
        signInAttemptID == attemptID
    }

    private func shouldContinueSignIn(_ attemptID: Int) -> Bool {
        isCurrentSignInAttempt(attemptID) && !Task.isCancelled
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
            await fetchSourceCatalog(appliesMockRefreshDelay: true)
        }
    }

    func open(_ url: URL) {
        openURL(url)
    }

    func openGitHubAppInstallation() {
        open(gitHubAppRepositoryAccessURL)
    }

    func isUnreadPullRequest(_ pullRequest: PullRequest) -> Bool {
        unreadPullRequestNotificationIds.contains(pullRequest.id)
    }

    func isPinned(_ pullRequest: PullRequest) -> Bool {
        pinnedPullRequestIds.contains(pullRequest.id)
    }

    func isHidden(_ pullRequest: PullRequest) -> Bool {
        hiddenPullRequestIds.contains(pullRequest.id)
    }

    func togglePin(_ pullRequest: PullRequest) {
        if pinnedPullRequestIds.contains(pullRequest.id) {
            pinnedPullRequestIds.remove(pullRequest.id)
        } else {
            hiddenPullRequestIds.remove(pullRequest.id)
            pinnedPullRequestIds.insert(pullRequest.id)
        }
    }

    func toggleHide(_ pullRequest: PullRequest) {
        if hiddenPullRequestIds.contains(pullRequest.id) {
            hiddenPullRequestIds.remove(pullRequest.id)
        } else {
            pinnedPullRequestIds.remove(pullRequest.id)
            hiddenPullRequestIds.insert(pullRequest.id)
        }
    }

    func openPullRequest(_ pullRequest: PullRequest) {
        markPullRequestNotificationsRead(for: pullRequest)
        open(pullRequest.url)
    }

    func openPullRequestNotification(_ notification: PullRequestNotification) {
        markPullRequestNotificationRead(notification)
        open(notification.url)
    }

    func openGitHubInboxNotification(_ notification: GitHubInboxNotification) {
        open(notification.webURL)
        markGitHubInboxNotificationRead(notification)
    }

    func markPullRequestNotificationRead(_ notification: PullRequestNotification) {
        updatePullRequestNotification(notification.id) { $0.read = true }
    }

    private func markPullRequestNotificationsRead(for pullRequest: PullRequest) {
        pullRequestNotificationHistory = pullRequestNotificationHistory.map { notification in
            guard notification.prId == pullRequest.id else {
                return notification
            }
            var copy = notification
            copy.read = true
            return copy
        }
    }

    func markGitHubInboxNotificationRead(_ notification: GitHubInboxNotification) {
        updateGitHubInboxNotification(notification.threadId) { $0.unread = false }
        Task {
            do {
                try await gitHubInboxProvider?.markInboxThreadRead(threadId: notification.threadId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func markAllNotificationsRead() {
        switch selectedNotificationSubtab {
        case .pullRequests:
            let visibleIds = Set(visiblePullRequestNotifications.map(\.id))
            pullRequestNotificationHistory = pullRequestNotificationHistory.map { notification in
                var copy = notification
                if visibleIds.contains(copy.id) {
                    copy.read = true
                }
                return copy
            }
        case .other:
            let unread = visibleGitHubInboxNotifications.filter(\.unread)
            let unreadIds = Set(unread.map(\.threadId))
            gitHubInboxNotifications = gitHubInboxNotifications.map { notification in
                var copy = notification
                if unreadIds.contains(copy.threadId) {
                    copy.unread = false
                }
                return copy
            }
            Task {
                do {
                    for notification in unread {
                        try await gitHubInboxProvider?.markInboxThreadRead(threadId: notification.threadId)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
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

    private static func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func configureStoredOAuthSource() {
        configureStoredGitHubSource(
            client: makeOAuthGitHubClient(),
            authMethod: .oauth,
            allowsGitHubInboxNotifications: false
        )
    }

    private func configureStoredPATSource(token: String) {
        configureStoredGitHubSource(
            client: patGitHubClientFactory(token),
            authMethod: .pat,
            allowsGitHubInboxNotifications: GitHubTokenCapabilities.supportsGitHubInboxNotifications(token: token)
        )
    }

    private func configureStoredGitHubSource(
        client: any GitHubProviding,
        authMethod: GitHubAuthMethod,
        allowsGitHubInboxNotifications: Bool
    ) {
        restoreCachedGitHubDashboardIfAvailable()
        configureGitHubSource(
            client: client,
            authMethod: authMethod,
            allowsGitHubInboxNotifications: allowsGitHubInboxNotifications,
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
            await refreshDashboard()
        }
    }

    private func configureGitHubSource(
        client: any GitHubProviding,
        authMethod: GitHubAuthMethod,
        allowsGitHubInboxNotifications: Bool,
        loginProvider: @escaping () async throws -> String,
        accountProvider: @escaping () async throws -> GitHubAccount?
    ) {
        sourceCatalogProvider = client
        if authMethod == .oauth {
            gitHubAppInstallationProvider = client
            gitHubAppRepositoryAccessStatus = .unknown
            gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
        } else {
            gitHubAppInstallationProvider = nil
            gitHubAppRepositoryAccessStatus = .notApplicable
            gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
        }
        if allowsGitHubInboxNotifications {
            gitHubInboxProvider = client
        } else {
            gitHubInboxProvider = nil
            gitHubInboxNotifications = []
            gitHubInboxSyncMetadata = .empty
        }
        setAuthMethod(authMethod)
        syncEngine = SyncEngine(
            source: client,
            preferences: preferences,
            loginProvider: loginProvider,
            accountProvider: accountProvider,
            authStatusProvider: { .signedIn },
            sourcePreferencesProvider: { [weak self] in self?.sourcePreferences ?? .defaults },
            snapshotSeedProvider: { [weak self] login in
                self?.cachedGitHubPullRequests(for: login) ?? []
            },
            snapshotCacheDidUpdate: { [weak self] cache in
                self?.storeGitHubSnapshotCache(cache)
            }
        )
    }

    private func configureSignedOutSource() {
        setAuthMethod(.oauth)
        sourceCatalog = .empty
        sourceCatalogProvider = nil
        gitHubAppInstallationProvider = nil
        gitHubAppRepositoryAccessStatus = .notApplicable
        gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
        gitHubInboxProvider = nil
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
        let source = MockPullRequestSource(
            showsNotificationTypeFixtures: launchConfiguration.showsNotificationTypeFixtures
        )
        sourceCatalogProvider = source
        gitHubAppInstallationProvider = nil
        gitHubAppRepositoryAccessStatus = .notApplicable
        gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
        gitHubInboxProvider = source
        sourceCatalog = source.mockSourceCatalog(accountLogin: account.login)
        sourceCatalogSyncedAt = Date()
        if launchConfiguration.showsNotificationTypeFixtures {
            pullRequestNotificationHistory = MockPullRequestSource.notificationTypeFixturePullRequestNotifications
            gitHubInboxNotifications = MockPullRequestSource.notificationTypeFixtureInboxNotifications
        }
        syncEngine = SyncEngine(
            source: source,
            preferences: preferences,
            loginProvider: { account.login },
            accountProvider: { account },
            authStatusProvider: { .signedIn },
            sourcePreferencesProvider: { [weak self] in self?.sourcePreferences ?? .defaults }
        )
    }

    private func makeOAuthGitHubClient() -> any GitHubProviding {
        oauthGitHubClientFactory(makeOAuthAccessTokenProvider())
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

    private func restoreCachedGitHubDashboardIfAvailable() {
        let cache = preferencesStore.pullRequestSnapshotCache
        guard cache.source == .github, !cache.pullRequests.isEmpty else {
            return
        }
        state = DashboardState(
            pullRequests: cache.pullRequests,
            events: [],
            syncedAt: cache.fetchedAt,
            source: .github,
            account: cache.account,
            authStatus: .signedIn
        )
    }

    private func cachedGitHubPullRequests(for login: String) -> [PullRequest] {
        let cache = preferencesStore.pullRequestSnapshotCache
        guard cache.source == .github, cache.account?.login == login else {
            return []
        }
        return cache.pullRequests
    }

    private func storeGitHubSnapshotCache(_ cache: PullRequestSnapshotCache) {
        guard cache.source == .github else {
            return
        }
        preferencesStore.pullRequestSnapshotCache = cache
    }

    private func fetchSourceCatalog(appliesMockRefreshDelay: Bool = false) async {
        guard let sourceCatalogProvider else {
            return
        }
        guard !isRefreshingSources else {
            return
        }
        isRefreshingSources = true
        defer { isRefreshingSources = false }
        sourceErrorMessage = nil
        let installations = await fetchGitHubAppInstallationsForAccessStatus()
        guard !Task.isCancelled else { return }
        await delayMockRefreshIfNeeded(applies: appliesMockRefreshDelay)
        guard !Task.isCancelled else { return }
        do {
            let fetchedCatalog = try await sourceCatalogProvider.fetchSourceCatalog(
                accountLogin: account?.login ?? state.account?.login
            )
            guard !Task.isCancelled else { return }
            sourceCatalog = fetchedCatalog
            sourceCatalogSyncedAt = Date()
            updateGitHubAppRepositoryAccessStatus(
                installations: installations,
                sourceCatalog: fetchedCatalog
            )
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            updateGitHubAppRepositoryAccessStatus(
                installations: installations,
                sourceCatalog: nil
            )
            if isAuthenticationFailure(error) {
                handleAuthenticationFailure(error)
            } else {
                sourceErrorMessage = error.localizedDescription
            }
        }
    }

    private var canCheckGitHubAppRepositoryAccess: Bool {
        (state.authStatus == .signedIn || account != nil)
            && authMethod == .oauth
            && !launchConfiguration.usesMockData
    }

    private func fetchGitHubAppInstallationsForAccessStatus() async -> GitHubAppInstallations? {
        guard canCheckGitHubAppRepositoryAccess else {
            gitHubAppRepositoryAccessStatus = .notApplicable
            gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
            return nil
        }
        guard let gitHubAppInstallationProvider else {
            gitHubAppRepositoryAccessStatus = .unknown
            gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
            return nil
        }

        gitHubAppRepositoryAccessStatus = .checking
        do {
            return try await gitHubAppInstallationProvider.fetchGitHubAppInstallations()
        } catch {
            if isAuthenticationFailure(error) {
                handleAuthenticationFailure(error)
            } else {
                gitHubAppRepositoryAccessStatus = .unknown
            }
            gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
            return nil
        }
    }

    private func updateGitHubAppRepositoryAccessStatus(
        installations: GitHubAppInstallations?,
        sourceCatalog: SourceCatalog?
    ) {
        guard canCheckGitHubAppRepositoryAccess else {
            gitHubAppRepositoryAccessStatus = .notApplicable
            gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
            return
        }
        guard let installations else {
            gitHubAppRepositoryAccessStatus = .unknown
            gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
            return
        }
        guard !installations.installations.isEmpty else {
            gitHubAppRepositoryAccessStatus = .noInstallations
            gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
            return
        }
        guard let sourceCatalog else {
            gitHubAppRepositoryAccessStatus = .unknown
            gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
            return
        }
        let status = GitHubAppRepositoryAccessStatus.resolved(
            installations: installations,
            sourceCatalog: sourceCatalog
        )
        gitHubAppRepositoryAccessStatus = status
        gitHubAppRepositoryAccessURL = status == .noVisibleRepositories
            ? installations.installations.first?.htmlURL ?? MergeHawkAuthDefaults.installURL
            : MergeHawkAuthDefaults.installURL
    }

    private func fetchGitHubInboxNotifications() async {
        guard let gitHubInboxProvider else {
            return
        }
        if let lastFetchedAt = gitHubInboxSyncMetadata.lastFetchedAt,
           let pollIntervalSeconds = gitHubInboxSyncMetadata.pollIntervalSeconds,
           Date() < lastFetchedAt.addingTimeInterval(TimeInterval(pollIntervalSeconds)) {
            return
        }
        guard !isRefreshingInbox else {
            return
        }
        isRefreshingInbox = true
        do {
            let result = try await gitHubInboxProvider.fetchInboxNotifications(metadata: gitHubInboxSyncMetadata)
            gitHubInboxSyncMetadata = result.metadata
            if !result.isNotModified {
                gitHubInboxNotifications = Self.mergeInboxNotifications(
                    existing: gitHubInboxNotifications,
                    fetched: result.notifications
                )
            }
        } catch {
            if isAuthenticationFailure(error) {
                handleAuthenticationFailure(error)
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isRefreshingInbox = false
    }

    private func recordPullRequestNotifications(events: [PullRequestEvent], pullRequests: [PullRequest]) {
        guard !events.isEmpty else {
            return
        }
        let pullRequestsById = Dictionary(uniqueKeysWithValues: pullRequests.map { ($0.id, $0) })
        let notifications = events.compactMap { event -> PullRequestNotification? in
            guard let pullRequest = pullRequestsById[event.prId] else {
                return nil
            }
            return PullRequestNotification(event: event, pullRequest: pullRequest)
        }
        guard !notifications.isEmpty else {
            return
        }
        pullRequestNotificationHistory = Self.trimPullRequestNotifications(
            notifications + pullRequestNotificationHistory
        )
    }

    private func sync(appliesMockRefreshDelay: Bool = false) async {
        guard let syncEngine else {
            return
        }
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        errorMessage = nil
        await delayMockRefreshIfNeeded(applies: appliesMockRefreshDelay)
        guard !Task.isCancelled else { return }
        do {
            let nextState = try await syncEngine.sync()
            guard !Task.isCancelled else { return }
            recordPullRequestNotifications(events: nextState.events, pullRequests: nextState.pullRequests)
            state = nextState
            if authMethod == .oauth,
               !launchConfiguration.usesMockData,
               gitHubAppRepositoryAccessStatus != .noInstallations,
               !nextState.pullRequests.isEmpty {
                gitHubAppRepositoryAccessStatus = .configured
                gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
            }
            errorMessage = syncEngine.lastRefreshWarning
            if macOSLocalNotificationsEnabled {
                notificationClient.post(events: nextState.events, pullRequests: nextState.pullRequests)
            }
            await fetchGitHubInboxNotifications()
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if isAuthenticationFailure(error) {
                handleAuthenticationFailure(error)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshDashboard(appliesMockRefreshDelay: Bool = false) async {
        if canCheckGitHubAppRepositoryAccess {
            await fetchSourceCatalog(appliesMockRefreshDelay: appliesMockRefreshDelay)
        }
        await sync(appliesMockRefreshDelay: appliesMockRefreshDelay)
        // sync() establishes authStatus — if the catalog check was skipped earlier
        // because auth wasn't ready yet, run it now that we know we're signed in.
        if canCheckGitHubAppRepositoryAccess && gitHubAppRepositoryAccessStatus == .unknown {
            await fetchSourceCatalog()
        }
    }

    private func delayMockRefreshIfNeeded(applies: Bool) async {
        guard applies,
              launchConfiguration.usesMockData,
              launchConfiguration.mockRefreshDelaySeconds > 0 else {
            return
        }

        let nanoseconds = UInt64(launchConfiguration.mockRefreshDelaySeconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        if let error = error as? GitHubClientError {
            switch error {
            case .authRefreshFailed:
                return true
            case .httpFailure(_, 401):
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
        preferencesStore.pullRequestSnapshotCache = .empty
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
                await self.refreshDashboard()
            }
        }
    }

    private static func compare<Value: Comparable>(
        _ lhs: PullRequest,
        _ rhs: PullRequest,
        by value: (PullRequest) -> Value,
        ascending: Bool = false
    ) -> Bool {
        let lhsValue = value(lhs)
        let rhsValue = value(rhs)
        if lhsValue != rhsValue {
            return ascending ? lhsValue < rhsValue : lhsValue > rhsValue
        }
        return compareTieBreak(lhs, rhs)
    }

    private static func changeSize(_ pullRequest: PullRequest) -> Int {
        // The sort value treats unavailable counts like zero; the row still displays them as unavailable.
        guard let additions = pullRequest.additions,
              let deletions = pullRequest.deletions else { return 0 }
        return additions + deletions
    }

    private static func compareTieBreak(_ lhs: PullRequest, _ rhs: PullRequest) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        if lhs.repo != rhs.repo {
            return lhs.repo < rhs.repo
        }
        return lhs.number > rhs.number
    }

    private static func trimPullRequestNotifications(
        _ notifications: [PullRequestNotification]
    ) -> [PullRequestNotification] {
        Array(notifications.sorted(by: compareNotifications).prefix(30))
    }

    private static func mergeInboxNotifications(
        existing: [GitHubInboxNotification],
        fetched: [GitHubInboxNotification]
    ) -> [GitHubInboxNotification] {
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.threadId, $0) })
        for notification in fetched {
            byId[notification.threadId] = notification
        }
        return Array(byId.values.sorted(by: compareInboxNotifications).prefix(30))
    }

    private static func compareNotifications(
        _ lhs: PullRequestNotification,
        _ rhs: PullRequestNotification
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        if lhs.repo != rhs.repo {
            return lhs.repo < rhs.repo
        }
        return lhs.prNumber > rhs.prNumber
    }

    private static func compareInboxNotifications(
        _ lhs: GitHubInboxNotification,
        _ rhs: GitHubInboxNotification
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        if lhs.repo != rhs.repo {
            return lhs.repo < rhs.repo
        }
        return lhs.subjectTitle < rhs.subjectTitle
    }

    private func updatePullRequestNotification(
        _ id: PullRequestNotification.ID,
        update: (inout PullRequestNotification) -> Void
    ) {
        pullRequestNotificationHistory = pullRequestNotificationHistory.map { notification in
            guard notification.id == id else {
                return notification
            }
            var copy = notification
            update(&copy)
            return copy
        }
    }

    private func updateGitHubInboxNotification(
        _ threadId: GitHubInboxNotification.ID,
        update: (inout GitHubInboxNotification) -> Void
    ) {
        gitHubInboxNotifications = gitHubInboxNotifications.map { notification in
            guard notification.threadId == threadId else {
                return notification
            }
            var copy = notification
            update(&copy)
            return copy
        }
    }

}
