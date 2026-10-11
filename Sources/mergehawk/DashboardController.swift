import AppKit
import Foundation
import mergehawkcore

@MainActor
final class DashboardController: ObservableObject {
    private struct PublishedPresentation: Equatable {
        var dashboard: DashboardState
        var notificationHistory: [PullRequestNotification]

        static let empty = PublishedPresentation(dashboard: .empty, notificationHistory: [])
    }
    enum MenuTab: String, CaseIterable, Identifiable {
        case notifications = "Notifications"
        case myPRs = "Authored"
        case reviewRequests = "Requested"

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
        case reviewRequired = "reviewRequired"
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

    struct ReviewTeamRow: Identifiable, Equatable {
        let team: TeamReference
        /// Nesting level under the team's top-level ancestor among the viewer's teams.
        let depth: Int
        let isCounting: Bool
        /// Fetched PRs requesting this team, whatever relationship brought them in.
        let pullRequestCount: Int
        var avatarURL: URL? = nil
        var organizationAvatarURL: URL? = nil

        var id: String { team.id }
    }

    typealias RequestedSectionContent = ReviewRequestSectionContent

    @Published private var presentation: PublishedPresentation
    var state: DashboardState { presentation.dashboard }
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    /// Set only by a failed complete PR refresh, so the refresh control never reports unrelated errors.
    @Published private(set) var refreshErrorMessage: String?
    /// Set when a local change (such as marking a notification read) could not be saved.
    @Published private(set) var saveErrorMessage: String?
    @Published private(set) var launchAtLoginErrorMessage: String?
    @Published var selectedTab: MenuTab = .notifications
    @Published var preferences: NotificationPreferences {
        didSet {
            preferencesStore.notificationPreferences = preferences
        }
    }
    @Published var muteBotNotifications: Bool {
        didSet { preferencesStore.muteBotNotifications = muteBotNotifications }
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
    @Published var menuSize: MenuSize {
        didSet {
            preferencesStore.menuSize = menuSize
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
    /// Expanded Review requests stack groups, in memory only like collapsed sections.
    @Published private(set) var expandedStackIDs: Set<String> = []
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
    @Published var turnedOffReviewTeamIDs: Set<String> {
        didSet {
            preferencesStore.turnedOffReviewTeamIDs = turnedOffReviewTeamIDs
        }
    }
    @Published var sourcePreferences: SourcePreferences {
        didSet {
            preferencesStore.sourcePreferences = sourcePreferences
        }
    }
    @Published var hideArchivedRepositories: Bool {
        didSet {
            preferencesStore.hideArchivedRepositories = hideArchivedRepositories
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
    private var sourceCatalogAccountLogin: String?
    @Published private(set) var sourceErrorMessage: String?
    @Published private(set) var gitHubAppRepositoryAccessStatus: GitHubAppRepositoryAccessStatus = .notApplicable
    private var gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
    @Published private(set) var startsAtLogin: Bool
    @Published private(set) var authMethod: GitHubAuthMethod = .oauth

    var openSettingsWindow: ((SettingsTab) -> Void)?
    var openSettingsWindowPreservingSelection: (() -> Void)?
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
    private let openURL: @MainActor (URL) -> Void
    private let openPullRequestRequest: @MainActor (PullRequestOpenRequest) -> Void
    private let openDeviceFlowURL: @MainActor (URL) -> Void
    private let copyStringToClipboard: @MainActor (String) -> Void
    private let now: () -> Date
    private var syncEngine: SyncEngine?
    private var account: GitHubAccount?
    private var automaticRefreshTask: Task<Void, Never>?
    private struct AutomaticRefreshDeferral {
        let generation: Int
        let accountLogin: String
        let retryAt: Date
    }
    private var automaticRefreshDeferral: AutomaticRefreshDeferral?
    private var refreshTask: Task<Void, Never>?
    /// Whether `refreshTask` forces a team read.
    private var refreshTaskForcesTeamRead = false
    private var refreshAttemptID = 0
    private var catalogTask: Task<Void, Never>?
    private var providerGeneration = 0
    private var refreshingGeneration: Int?
    private static let sourceCatalogFreshnessInterval: TimeInterval = 60 * 60
    private var committedSyncState: PullRequestSyncState?
    var pullRequestNotificationHistory: [PullRequestNotification] { presentation.notificationHistory }

    /// The presentation clock: views compute relative times and countdowns against it.
    func currentDate() -> Date {
        now()
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
        pullRequestOpener: (@MainActor (PullRequestOpenRequest) -> Void)? = nil,
        deviceFlowURLOpener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        clipboardWriter: @escaping @MainActor (String) -> Void = DashboardController.copyToPasteboard,
        now: @escaping () -> Date = Date.init
    ) {
        self.tokenStore = tokenStore
        self.oauthSignIn = oauthSignIn ?? GitHubDeviceFlowSignIn()
        self.oauthAccessTokenCache = OAuthAccessTokenCache(tokenStore: tokenStore)
        self.preferencesStore = preferencesStore
        let storedSyncState = preferencesStore.pullRequestSyncState ?? preferencesStore.importedLegacySyncState()
        self.committedSyncState = storedSyncState
        self.presentation = storedSyncState.map {
            PublishedPresentation(dashboard: $0.dashboard, notificationHistory: $0.notificationHistory)
        } ?? PublishedPresentation(
            dashboard: .empty,
            notificationHistory: preferencesStore.pullRequestNotificationHistory
        )
        self.launchConfiguration = launchConfiguration
        self.openURL = urlOpener
        self.openPullRequestRequest = pullRequestOpener ?? { urlOpener($0.targetURL) }
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
        self.muteBotNotifications = preferencesStore.muteBotNotifications
        self.preferences = preferencesStore.loadAndPersistNotificationPreferences()
        self.refreshIntervalMinutes = preferencesStore.refreshIntervalMinutes
        self.menuSize = preferencesStore.menuSize
        self.pullRequestSortOption = preferencesStore.pullRequestSortOption
        self.pullRequestSortDirection = preferencesStore.pullRequestSortDirection
        self.reviewRequestSortOption = preferencesStore.reviewRequestSortOption
        self.reviewRequestSortDirection = preferencesStore.reviewRequestSortDirection
        self.selectedPullRequestFilters = preferencesStore.selectedPullRequestFilters
        self.selectedReviewRequestFilters = preferencesStore.selectedReviewRequestFilters
        self.pinnedPullRequestIds = preferencesStore.pinnedPullRequestIds
        self.hiddenPullRequestIds = preferencesStore.hiddenPullRequestIds
        self.turnedOffReviewTeamIDs = preferencesStore.turnedOffReviewTeamIDs
        self.sourcePreferences = preferencesStore.sourcePreferences
        self.hideArchivedRepositories = preferencesStore.hideArchivedRepositories
        self.sourceCatalog = preferencesStore.sourceCatalog
        self.sourceCatalogSyncedAt = preferencesStore.sourceCatalogSyncedAt
        self.sourceCatalogAccountLogin = preferencesStore.sourceCatalogAccountLogin
        self.macOSLocalNotificationsEnabled = preferencesStore.macOSLocalNotificationsEnabled
        self.startsAtLogin = self.launchAtLoginService.isEnabled
        self.authMethod = preferencesStore.authMethod
        self.notificationClient.requestAuthorization()
        configureInitialSource()
        startAutomaticRefresh()
    }

    deinit {
        automaticRefreshTask?.cancel()
        catalogTask?.cancel()
    }

    var hasAttention: Bool {
        visiblePullRequestNotifications.contains { !$0.read }
    }

    var attentionCount: Int {
        visiblePullRequestNotifications.filter { !$0.read }.count
    }

    var visiblePullRequestNotifications: [PullRequestNotification] {
        let preferences = effectiveSourcePreferences
        return pullRequestNotificationHistory
            .filter { preferences.allowsNotifications(for: $0.repo) }
            .sorted(by: Self.compareNotifications)
    }

    private var effectiveSourcePreferences: SourcePreferences {
        guard hideArchivedRepositories else { return sourcePreferences }
        var effective = sourcePreferences
        for repository in Set(state.pullRequests.filter { $0.repositoryIsArchived == true }.map(\.repo)) {
            effective.repositories[repository] = RepositorySourcePreferences(
                notifications: .disabled,
                myPullRequests: .disabled,
                reviewRequests: .disabled
            )
        }
        return effective
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
        let preferences = effectiveSourcePreferences
        return state.pullRequests.filter { pr in
            pr.isMine && preferences.allowsMyPullRequests(for: pr.repo)
        }
    }

    /// Counted PRs: a team request only counts for one of the viewer's teams that is not turned off.
    var sourceFilteredReviewRequests: [PullRequest] {
        let preferences = effectiveSourcePreferences
        let counting = teamReviewCounting
        return state.pullRequests.map(counting.applied(to:)).filter { pr in
            preferences.allowsReviewRequests(for: pr.repo)
        }
    }

    var teamReviewCounting: TeamReviewCounting {
        TeamReviewCounting(viewerTeams: state.viewerTeams, turnedOffTeamIDs: turnedOffReviewTeamIDs)
    }

    /// The viewer's teams from the last complete PR refresh as a tree like GitHub's team list: organizations in
    /// order, each team followed by its child teams, siblings by slug. A team whose parent is not one of the
    /// viewer's teams is top level.
    var reviewTeamRows: [ReviewTeamRow] {
        let viewerTeams = state.viewerTeams
        let viewerTeamIDs = Set(viewerTeams.map(\.team.id))
        let bySlug: (ViewerTeam, ViewerTeam) -> Bool = {
            ($0.team.organization, $0.team.slug, $0.team.id) < ($1.team.organization, $1.team.slug, $1.team.id)
        }
        let childrenByParentID = Dictionary(grouping: viewerTeams.filter {
            $0.parentTeamID.map(viewerTeamIDs.contains) == true
        }) { $0.parentTeamID! }
        let roots = viewerTeams.filter { $0.parentTeamID.map(viewerTeamIDs.contains) != true }.sorted(by: bySlug)

        var rows: [ReviewTeamRow] = []
        func append(_ viewerTeam: ViewerTeam, depth: Int) {
            rows.append(ReviewTeamRow(
                team: viewerTeam.team,
                depth: depth,
                isCounting: !turnedOffReviewTeamIDs.contains(viewerTeam.team.id),
                pullRequestCount: state.pullRequests.filter { pr in
                    pr.requestedTeams.contains { $0.id == viewerTeam.team.id }
                }.count,
                avatarURL: viewerTeam.avatarURL,
                organizationAvatarURL: viewerTeam.organizationAvatarURL
            ))
            for child in (childrenByParentID[viewerTeam.team.id] ?? []).sorted(by: bySlug) {
                append(child, depth: depth + 1)
            }
        }
        roots.forEach { append($0, depth: 0) }
        return rows
    }

    func setReviewTeam(_ id: String, counting: Bool) {
        if counting {
            turnedOffReviewTeamIDs.remove(id)
        } else {
            turnedOffReviewTeamIDs.insert(id)
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
        ReviewRequestStacks.sections(
            requested: sourceFilteredReviewRequests.filter(Self.isRequestedPullRequest),
            matching: filteredReviewRequests,
            stacks: state.pullRequestStacks,
            hiddenIDs: hiddenPullRequestIds,
            pinnedIDs: pinnedPullRequestIds,
            unreadIDs: unreadPullRequestNotificationIds,
            sortOption: reviewRequestSortOption,
            sortDirection: reviewRequestSortDirection
        )
    }

    func isStackExpanded(_ stackID: String) -> Bool {
        expandedStackIDs.contains(stackID)
    }

    func toggleStackExpanded(_ stackID: String) {
        if expandedStackIDs.contains(stackID) {
            expandedStackIDs.remove(stackID)
        } else {
            expandedStackIDs.insert(stackID)
        }
    }

    /// Option-click on a stack control: as for the Requested sections, the clicked stack's state decides. Expanding
    /// opens every stack, including ones the filters hide, and collapsing closes them all.
    func toggleAllStacks(from stackID: String) {
        expandedStackIDs = isStackExpanded(stackID) ? [] : Set(state.pullRequestStacks.map(\.id))
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

    /// A refresh that reads the viewer's teams even when the stored teams are still fresh.
    func refreshTeams() {
        Task {
            await refreshDashboard(appliesMockRefreshDelay: true, forcesTeamRead: true)
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
            acceptVerifiedAccount(viewer)
            configureGitHubSource(
                client: client,
                authMethod: .pat,
                loginProvider: { viewer.login },
                accountProvider: { viewer }
            )
            // Teams stored under an earlier credential are not reused, even for the same account.
            await refreshDashboard(forcesTeamRead: true)
            startCatalogRefreshIfNeeded(force: true)
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
            acceptVerifiedAccount(viewer)
            configureGitHubSource(
                client: client,
                authMethod: .oauth,
                loginProvider: { viewer.login },
                accountProvider: { viewer }
            )
            // Teams stored under an earlier credential are not reused, even for the same account.
            await refreshDashboard(forcesTeamRead: true)
            guard shouldContinueSignIn(attemptID) else { return }
            startCatalogRefreshIfNeeded(force: true)
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
        beginProviderGeneration()
        do {
            oauthAccessTokenCache.clear()
            try tokenStore.clear()
        } catch {
            errorMessage = error.localizedDescription
        }
        account = nil
        preferencesStore.pullRequestSnapshotCache = .empty
        preferencesStore.clearPullRequestSyncState()
        committedSyncState = nil
        presentation = .empty
        setAuthMethod(.oauth)
        sourceCatalogProvider = nil
        gitHubAppInstallationProvider = nil
        gitHubAppRepositoryAccessStatus = .notApplicable
        gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
        sourceCatalog = .empty
        sourceCatalogSyncedAt = nil
        sourceCatalogAccountLogin = nil
        preferencesStore.sourceCatalogSyncedAt = nil
        preferencesStore.sourceCatalogAccountLogin = nil
        sourceErrorMessage = nil
        configureSignedOutSource()
        refresh()
    }

    func showSettings(selection: SettingsTab = .general) {
        openSettingsWindow?(selection)
    }

    func showSettingsPreservingSelection() {
        openSettingsWindowPreservingSelection?()
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
        launchAtLoginErrorMessage = nil
        do {
            try launchAtLoginService.setEnabled(startsAtLogin)
            self.startsAtLogin = launchAtLoginService.isEnabled
        } catch {
            self.startsAtLogin = launchAtLoginService.isEnabled
            launchAtLoginErrorMessage = error.localizedDescription
        }
    }

    func dismissSaveError() {
        saveErrorMessage = nil
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
        startCatalogRefreshIfNeeded(force: true, appliesMockRefreshDelay: true)
    }

    func refreshSourcesIfNeeded() {
        startCatalogRefreshIfNeeded()
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

    /// Group actions set state on every requested member of a stack group, or on the standalone PR.
    /// Hiding also unpins, and pinning also unhides.
    func setHidden(_ row: ReviewRequestRow, hidden: Bool) {
        let ids = Self.actionIDs(for: row)
        if hidden {
            pinnedPullRequestIds.subtract(ids)
            hiddenPullRequestIds.formUnion(ids)
        } else {
            hiddenPullRequestIds.subtract(ids)
        }
    }

    func setPinned(_ row: ReviewRequestRow, pinned: Bool) {
        let ids = Self.actionIDs(for: row)
        if pinned {
            hiddenPullRequestIds.subtract(ids)
            pinnedPullRequestIds.formUnion(ids)
        } else {
            pinnedPullRequestIds.subtract(ids)
        }
    }

    private static func actionIDs(for row: ReviewRequestRow) -> Set<String> {
        row.stack?.requestedMemberIDs ?? [row.representative.id]
    }

    /// A requested member opens like any PR; a context member only has its stack entry URL.
    func openStackMember(_ member: StackGroup.Member) {
        switch member {
        case .requested(let pullRequest):
            openPullRequest(pullRequest)
        case .context(let entry):
            openPullRequest(PullRequestOpenRequest(pullRequestURL: entry.url))
        }
    }

    func openPullRequest(_ pullRequest: PullRequest) {
        markPullRequestNotificationsRead(for: pullRequest)
        openPullRequest(PullRequestOpenRequest(pullRequestURL: pullRequest.url))
    }

    func openPullRequestNotification(_ notification: PullRequestNotification) {
        markPullRequestNotificationRead(notification)
        openPullRequest(PullRequestOpenRequest(
            pullRequestURL: notification.url,
            destinationURL: notification.destinationURL
        ))
    }

    func openPullRequest(_ request: PullRequestOpenRequest) {
        openPullRequestRequest(request)
    }

    func markPullRequestNotificationRead(_ notification: PullRequestNotification) {
        updatePullRequestNotification(notification.id) { $0.read = true }
    }

    private func markPullRequestNotificationsRead(for pullRequest: PullRequest) {
        updateNotificationHistory(pullRequestNotificationHistory.map { notification in
            guard notification.prId == pullRequest.id else {
                return notification
            }
            var copy = notification
            copy.read = true
            return copy
        })
    }

    func markAllNotificationsRead() {
        let visibleIds = Set(visiblePullRequestNotifications.map(\.id))
        updateNotificationHistory(pullRequestNotificationHistory.map { notification in
            var copy = notification
            if visibleIds.contains(copy.id) {
                copy.read = true
            }
            return copy
        })
    }

    private func trimVisibleEvents() {
        var dashboard = state
        let pullRequestsByID = Dictionary(uniqueKeysWithValues: dashboard.pullRequests.map { ($0.id, $0) })
        dashboard.events.removeAll { event in
            guard let pullRequest = pullRequestsByID[event.prId] else {
                return false
            }
            return !sourcePreferences.allowsNotifications(for: pullRequest.repo)
        }
        updateDashboard(dashboard)
    }

    private func configureInitialSource() {
        if launchConfiguration.usesMockData {
            configureMockSource()
            Task {
                await refreshDashboard()
            }
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
            authMethod: .oauth
        )
    }

    private func configureStoredPATSource(token: String) {
        configureStoredGitHubSource(
            client: patGitHubClientFactory(token),
            authMethod: .pat
        )
    }

    private func configureStoredGitHubSource(
        client: any GitHubProviding,
        authMethod: GitHubAuthMethod
    ) {
        restoreCachedGitHubDashboardIfAvailable()
        configureGitHubSource(
            client: client,
            authMethod: authMethod,
            loginProvider: { [weak self] in
                if let login = self?.account?.login {
                    return login
                }
                let viewer = try await client.fetchViewer()
                await MainActor.run {
                    self?.acceptVerifiedAccount(viewer)
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
        loginProvider: @escaping () async throws -> String,
        accountProvider: @escaping () async throws -> GitHubAccount?
    ) {
        beginProviderGeneration()
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
        setAuthMethod(authMethod)
        syncEngine = SyncEngine(
            source: client,
            loginProvider: loginProvider,
            accountProvider: accountProvider,
            now: now
        )
    }

    private func acceptVerifiedAccount(_ verifiedAccount: GitHubAccount) {
        let committedAccountChanged = committedSyncState.map {
            $0.account.login.caseInsensitiveCompare(verifiedAccount.login) != .orderedSame
        } == true
        if committedAccountChanged {
            preferencesStore.pullRequestSnapshotCache = .empty
            preferencesStore.pullRequestNotificationHistory = []
            preferencesStore.clearPullRequestSyncState()
            committedSyncState = nil
            presentation = .empty
        }
        let catalogAccountChanged = sourceCatalogAccountLogin.map {
            $0.caseInsensitiveCompare(verifiedAccount.login) != .orderedSame
        } == true
        if committedAccountChanged || catalogAccountChanged {
            sourceCatalog = .empty
            sourceCatalogSyncedAt = nil
            sourceCatalogAccountLogin = nil
            preferencesStore.sourceCatalogSyncedAt = nil
            preferencesStore.sourceCatalogAccountLogin = nil
            sourceErrorMessage = nil
        }
        account = verifiedAccount
        restoreCachedGitHubDashboardIfAvailable()
    }

    private func configureSignedOutSource() {
        beginProviderGeneration()
        let retainedHistory = presentation.notificationHistory
        presentation = PublishedPresentation(dashboard: .empty, notificationHistory: retainedHistory)
        setAuthMethod(.oauth)
        sourceCatalog = .empty
        sourceCatalogProvider = nil
        gitHubAppInstallationProvider = nil
        gitHubAppRepositoryAccessStatus = .notApplicable
        gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
        let source = EmptyPullRequestSource()
        syncEngine = SyncEngine(
            source: source,
            loginProvider: { "" },
            accountProvider: { nil },
            now: now
        )
    }

    private func configureMockSource() {
        beginProviderGeneration()
        let account = GitHubAccount(login: "agent-fixture")
        if committedSyncState.map({
            $0.account.login.caseInsensitiveCompare(account.login) != .orderedSame
        }) == true
            || committedSyncState?.dashboard.source != .mock {
            committedSyncState = nil
            presentation = .empty
        }
        self.account = account
        setAuthMethod(.oauth)
        let source = MockPullRequestSource(
            showsNotificationTypeFixtures: launchConfiguration.showsNotificationTypeFixtures,
            referenceDate: now(),
            scenario: launchConfiguration.mockPullRequestScenario,
            now: now
        )
        sourceCatalogProvider = source
        gitHubAppInstallationProvider = nil
        gitHubAppRepositoryAccessStatus = .notApplicable
        gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
        sourceCatalog = source.mockSourceCatalog(accountLogin: account.login)
        sourceCatalogSyncedAt = now()
        sourceCatalogAccountLogin = account.login
        if launchConfiguration.showsNotificationTypeFixtures {
            let history = MockPullRequestSource.notificationTypeFixturePullRequestNotifications
            // Already tracking the first refresh's PRs keeps that refresh from adding rows above the fixtures.
            let dashboard = committedSyncState?.dashboard ?? DashboardState(
                pullRequests: source.firstRefreshPullRequests.map(\.withoutActivityHistory),
                events: [],
                syncedAt: nil,
                source: .mock,
                account: account,
                authStatus: .signedIn,
                viewerTeams: source.viewerTeams,
                pullRequestStacks: source.stacks
            )
            committedSyncState = PullRequestSyncState(
                account: account,
                dashboard: dashboard,
                processedActivityByPullRequestID: committedSyncState?.processedActivityByPullRequestID ?? [:],
                notificationHistory: history
            )
            presentation = PublishedPresentation(dashboard: dashboard, notificationHistory: history)
        }
        syncEngine = SyncEngine(
            source: source,
            loginProvider: { account.login },
            accountProvider: { account },
            now: now
        )
    }

    private func makeOAuthGitHubClient() -> any GitHubProviding {
        oauthGitHubClientFactory(makeOAuthAccessTokenProvider())
    }

    private func beginProviderGeneration() {
        providerGeneration += 1
        automaticRefreshDeferral = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshAttemptID += 1
        catalogTask?.cancel()
        catalogTask = nil
        isRefreshingSources = false
        refreshingGeneration = nil
        isRefreshing = false
        refreshErrorMessage = nil
        saveErrorMessage = nil
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
        guard let committedSyncState else { return }
        presentation = PublishedPresentation(
            dashboard: committedSyncState.dashboard,
            notificationHistory: committedSyncState.notificationHistory
        )
    }

    private func startCatalogRefreshIfNeeded(
        force: Bool = false,
        appliesMockRefreshDelay: Bool = false
    ) {
        guard catalogTask == nil, sourceCatalogProvider != nil else {
            return
        }
        let expectedLogin = account?.login ?? state.account?.login
        guard let expectedLogin else {
            return
        }
        if sourceCatalogAccountLogin?.caseInsensitiveCompare(expectedLogin) != .orderedSame {
            sourceCatalog = .empty
            sourceCatalogSyncedAt = nil
            sourceCatalogAccountLogin = nil
            preferencesStore.sourceCatalogSyncedAt = nil
            preferencesStore.sourceCatalogAccountLogin = nil
        }
        if !force,
           let sourceCatalogSyncedAt,
           now() < sourceCatalogSyncedAt.addingTimeInterval(Self.sourceCatalogFreshnessInterval) {
            return
        }

        let generation = providerGeneration
        isRefreshingSources = true
        sourceErrorMessage = nil
        catalogTask = Task { [weak self] in
            await self?.performCatalogRefresh(
                expectedLogin: expectedLogin,
                generation: generation,
                appliesMockRefreshDelay: appliesMockRefreshDelay
            )
            guard let self, self.providerGeneration == generation else { return }
            self.isRefreshingSources = false
            self.catalogTask = nil
        }
    }

    private func performCatalogRefresh(
        expectedLogin: String,
        generation: Int,
        appliesMockRefreshDelay: Bool
    ) async {
        guard let sourceCatalogProvider else { return }
        let installations = await fetchGitHubAppInstallationsForAccessStatus(
            generation: generation,
            expectedLogin: expectedLogin
        )
        guard isCurrentProvider(generation, login: expectedLogin) else { return }
        await delayMockRefreshIfNeeded(applies: appliesMockRefreshDelay)
        guard isCurrentProvider(generation, login: expectedLogin) else { return }
        do {
            let fetchedCatalog = try await sourceCatalogProvider.fetchSourceCatalog(accountLogin: expectedLogin)
            guard isCurrentProvider(generation, login: expectedLogin) else { return }
            sourceCatalog = fetchedCatalog
            sourceCatalogSyncedAt = now()
            sourceCatalogAccountLogin = expectedLogin
            preferencesStore.sourceCatalogSyncedAt = sourceCatalogSyncedAt
            preferencesStore.sourceCatalogAccountLogin = expectedLogin
            updateGitHubAppRepositoryAccessStatus(
                installations: installations,
                sourceCatalog: fetchedCatalog
            )
        } catch {
            guard isCurrentProvider(generation, login: expectedLogin), !(error is CancellationError) else { return }
            updateGitHubAppRepositoryAccessStatus(
                installations: installations,
                sourceCatalog: nil
            )
            sourceErrorMessage = error.localizedDescription
        }
    }

    private func isCurrentProvider(_ generation: Int, login: String) -> Bool {
        providerGeneration == generation
            && !Task.isCancelled
            && (account?.login ?? state.account?.login)?.caseInsensitiveCompare(login) == .orderedSame
    }

    private var canCheckGitHubAppRepositoryAccess: Bool {
        (state.authStatus == .signedIn || account != nil)
            && authMethod == .oauth
            && !launchConfiguration.usesMockData
    }

    private func fetchGitHubAppInstallationsForAccessStatus(
        generation: Int,
        expectedLogin: String
    ) async -> GitHubAppInstallations? {
        guard isCurrentProvider(generation, login: expectedLogin) else { return nil }
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
            let installations = try await gitHubAppInstallationProvider.fetchGitHubAppInstallations()
            return isCurrentProvider(generation, login: expectedLogin) ? installations : nil
        } catch {
            guard isCurrentProvider(generation, login: expectedLogin) else { return nil }
            gitHubAppRepositoryAccessStatus = .unknown
            sourceErrorMessage = error.localizedDescription
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

    private func performSync(
        syncEngine: SyncEngine,
        generation: Int,
        appliesMockRefreshDelay: Bool,
        forcesTeamRead: Bool = false
    ) async {
        await delayMockRefreshIfNeeded(applies: appliesMockRefreshDelay)
        guard !Task.isCancelled else { return }
        do {
            let previousState = committedSyncState
            let fetched = try await syncEngine.fetchRefresh(
                previousState: previousState,
                forcesTeamRead: forcesTeamRead
            )
            guard !Task.isCancelled, providerGeneration == generation else { return }
            // Read after the fetch, so a team turned off or on during a suspended refresh applies to it.
            let prepared = try syncEngine.prepare(
                previousState: previousState,
                fetched: fetched,
                turnedOffTeamIDs: turnedOffReviewTeamIDs
            )

            let archivedRepositories = Set(
                (prepared.activePullRequests + prepared.retiringPullRequests)
                    .filter { $0.repositoryIsArchived == true }
                    .map(\.repo)
            )
            let allowed = prepared.events.filter { value in
                let mutedBotActivity = muteBotNotifications && value.event.actorIsBot == true
                return !mutedBotActivity && preferences.allows(event: value.event, for: value.filteringContext)
                    && sourcePreferences.allowsNotifications(for: value.filteringContext.repo)
                    && (!hideArchivedRepositories || !archivedRepositories.contains(value.filteringContext.repo))
            }
            let notifications = allowed.map { value in
                PullRequestNotification(
                    event: value.event,
                    pullRequest: value.filteringContext,
                    createdAt: value.event.happenedAt ?? prepared.syncedAt
                )
            }
            let isSignedOut = prepared.source == .none
            let retainedHistory = isSignedOut || committedSyncState?.trusted(for: prepared.account.login) != nil
                ? presentation.notificationHistory
                : []
            let history = Self.trimPullRequestNotifications(notifications + retainedHistory)
            // Detection reads processed IDs, so the stored dashboard omits per-PR comment and review lists.
            let dashboard = DashboardState(
                pullRequests: prepared.activePullRequests.map(\.withoutActivityHistory),
                events: allowed.map(\.event),
                syncedAt: prepared.syncedAt,
                source: prepared.source,
                account: isSignedOut ? nil : prepared.account,
                authStatus: isSignedOut ? .signedOut : .signedIn,
                viewerTeams: prepared.viewerTeams,
                pullRequestStacks: prepared.stacks,
                viewerTeamsReadAt: prepared.viewerTeamsReadAt
            )
            if isSignedOut {
                presentation = PublishedPresentation(dashboard: dashboard, notificationHistory: history)
                account = nil
                automaticRefreshDeferral = nil
                refreshErrorMessage = nil
                return
            }
            let nextState = PullRequestSyncState(
                account: prepared.account,
                dashboard: dashboard,
                processedActivityByPullRequestID: prepared.processedActivityByPullRequestID,
                notificationHistory: history
            )
            try preferencesStore.storePullRequestSyncState(nextState)
            guard !Task.isCancelled, providerGeneration == generation else { return }
            committedSyncState = nextState
            presentation = PublishedPresentation(dashboard: dashboard, notificationHistory: history)
            account = dashboard.account
            automaticRefreshDeferral = nil
            refreshErrorMessage = nil

            if authMethod == .oauth,
               !launchConfiguration.usesMockData,
               gitHubAppRepositoryAccessStatus != .noInstallations,
               !dashboard.pullRequests.isEmpty {
                gitHubAppRepositoryAccessStatus = .configured
                gitHubAppRepositoryAccessURL = MergeHawkAuthDefaults.installURL
            }
            if macOSLocalNotificationsEnabled {
                notificationClient.post(
                    events: allowed.map(\.event),
                    pullRequests: prepared.activePullRequests + prepared.retiringPullRequests
                )
            }
        } catch {
            guard !Task.isCancelled, providerGeneration == generation, !(error is CancellationError) else { return }
            if let retryAt = gitHubReadRateLimitRetryDate(error),
               retryAt > now(),
               let login = account?.login ?? committedSyncState?.account.login {
                automaticRefreshDeferral = AutomaticRefreshDeferral(
                    generation: generation,
                    accountLogin: login,
                    retryAt: retryAt
                )
            }
            if isAuthenticationFailure(error) {
                handleAuthenticationFailure(error)
            } else {
                refreshErrorMessage = error.localizedDescription
            }
        }
    }

    private func refreshDashboard(
        appliesMockRefreshDelay: Bool = false,
        isAutomatic: Bool = false,
        forcesTeamRead: Bool = false
    ) async {
        if isAutomatic, shouldDeferAutomaticRefresh() { return }
        if let running = refreshTask {
            let runningForcesTeamRead = refreshTaskForcesTeamRead
            await running.value
            // The running refresh may have reused teams, so a forced team read runs once more after it.
            guard forcesTeamRead, !runningForcesTeamRead else { return }
            // Its owner clears `refreshTask` when it resumes; rejoining the finished task would never start the read.
            while refreshTask == running {
                await Task.yield()
            }
            await refreshDashboard(appliesMockRefreshDelay: appliesMockRefreshDelay, forcesTeamRead: true)
            return
        }
        guard let syncEngine else { return }
        let generation = providerGeneration
        refreshAttemptID += 1
        let attemptID = refreshAttemptID
        refreshingGeneration = generation
        isRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSync(
                syncEngine: syncEngine,
                generation: generation,
                appliesMockRefreshDelay: appliesMockRefreshDelay,
                forcesTeamRead: forcesTeamRead
            )
        }
        refreshTask = task
        refreshTaskForcesTeamRead = forcesTeamRead
        await task.value
        guard refreshAttemptID == attemptID else { return }
        refreshTask = nil
        refreshingGeneration = nil
        isRefreshing = false
        startCatalogRefreshIfNeeded()
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
        if isGitHubReadAuthenticationError(error) {
            return true
        }
        if let error = error as? GitHubClientError, error.rejectsCredentials {
            return true
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

    /// Signs out without discarding the committed state: signing back in as the same account restores it,
    /// and `acceptVerifiedAccount` clears it if a different account signs in.
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
        automaticRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let sleepSeconds = self.automaticRefreshSleepDuration(
                    defaultInterval: automaticRefreshInterval
                )
                do {
                    try await Task.sleep(for: .seconds(sleepSeconds))
                } catch {
                    break
                }

                guard !Task.isCancelled else {
                    break
                }

                await self.refreshDashboard(isAutomatic: true)
            }
        }
    }

    private func shouldDeferAutomaticRefresh() -> Bool {
        guard let deferral = currentAutomaticRefreshDeferral() else { return false }
        if deferral.retryAt > now() { return true }
        automaticRefreshDeferral = nil
        return false
    }

    private func automaticRefreshSleepDuration(defaultInterval: TimeInterval) -> TimeInterval {
        guard let deferral = currentAutomaticRefreshDeferral() else { return defaultInterval }
        let remaining = deferral.retryAt.timeIntervalSince(now())
        if remaining > 0 { return remaining }
        automaticRefreshDeferral = nil
        return 0
    }

    private func currentAutomaticRefreshDeferral() -> AutomaticRefreshDeferral? {
        guard let deferral = automaticRefreshDeferral,
              deferral.generation == providerGeneration,
              let currentLogin = account?.login ?? committedSyncState?.account.login,
              deferral.accountLogin.caseInsensitiveCompare(currentLogin) == .orderedSame else {
            automaticRefreshDeferral = nil
            return nil
        }
        return deferral
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

    static let pullRequestNotificationHistoryLimit = 100

    private static func trimPullRequestNotifications(
        _ notifications: [PullRequestNotification]
    ) -> [PullRequestNotification] {
        Array(notifications.sorted(by: compareNotifications).prefix(pullRequestNotificationHistoryLimit))
    }

    private static func compareNotifications(
        _ lhs: PullRequestNotification,
        _ rhs: PullRequestNotification
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        if lhs.activityId != rhs.activityId {
            return (lhs.activityId ?? "") > (rhs.activityId ?? "")
        }
        if lhs.eventType.rawValue != rhs.eventType.rawValue {
            return lhs.eventType.rawValue < rhs.eventType.rawValue
        }
        if lhs.repo != rhs.repo {
            return lhs.repo < rhs.repo
        }
        if lhs.prNumber != rhs.prNumber {
            return lhs.prNumber > rhs.prNumber
        }
        return lhs.id < rhs.id
    }

    private func updatePullRequestNotification(
        _ id: PullRequestNotification.ID,
        update: (inout PullRequestNotification) -> Void
    ) {
        updateNotificationHistory(pullRequestNotificationHistory.map { notification in
            guard notification.id == id else {
                return notification
            }
            var copy = notification
            update(&copy)
            return copy
        })
    }

    private func updateNotificationHistory(_ history: [PullRequestNotification]) {
        var nextPresentation = presentation
        nextPresentation.notificationHistory = history
        guard var nextState = committedSyncState else {
            preferencesStore.pullRequestNotificationHistory = history
            presentation = nextPresentation
            return
        }
        nextState.notificationHistory = history
        do {
            try preferencesStore.storePullRequestSyncState(nextState)
            committedSyncState = nextState
            presentation = nextPresentation
            saveErrorMessage = nil
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func updateDashboard(_ dashboard: DashboardState) {
        var nextPresentation = presentation
        nextPresentation.dashboard = dashboard
        guard var nextState = committedSyncState else {
            presentation = nextPresentation
            return
        }
        nextState.dashboard = dashboard
        do {
            try preferencesStore.storePullRequestSyncState(nextState)
            committedSyncState = nextState
            presentation = nextPresentation
            saveErrorMessage = nil
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

}
