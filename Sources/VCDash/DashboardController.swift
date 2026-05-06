import AppKit
import Foundation
import VCDashCore

@MainActor
final class DashboardController: ObservableObject {
    enum MenuTab: String, CaseIterable, Identifiable {
        case notifications = "Notifications"
        case myPRs = "My PRs"

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
    @Published var pullRequestFilterOption: PullRequestFilterOption {
        didSet {
            preferencesStore.pullRequestFilterOption = pullRequestFilterOption
        }
    }
    @Published private(set) var startsAtLogin: Bool

    var openSettingsWindow: (() -> Void)?

    private let tokenStore: TokenStore
    private let automaticRefreshIntervalOverride: TimeInterval?
    private var preferencesStore: PreferencesStore
    private let launchAtLoginService: LaunchAtLoginServicing
    private let notificationClient = NotificationCenterClient()
    private var syncEngine: SyncEngine?
    private var account: GitHubAccount?
    private var automaticRefreshTask: Task<Void, Never>?

    init(
        tokenStore: TokenStore = KeychainTokenStore(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        launchAtLoginService: LaunchAtLoginServicing? = nil,
        automaticRefreshInterval: TimeInterval? = nil
    ) {
        self.tokenStore = tokenStore
        self.preferencesStore = preferencesStore
        self.launchAtLoginService = launchAtLoginService ?? LaunchAtLoginService()
        self.automaticRefreshIntervalOverride = automaticRefreshInterval
        self.preferences = preferencesStore.notificationPreferences
        self.refreshIntervalMinutes = preferencesStore.refreshIntervalMinutes
        self.pullRequestSortOption = preferencesStore.pullRequestSortOption
        self.pullRequestFilterOption = preferencesStore.pullRequestFilterOption
        self.startsAtLogin = self.launchAtLoginService.isEnabled
        notificationClient.requestAuthorization()
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
        let mine = state.pullRequests.filter(\.isMine)
        return Self.sorted(
            Self.filtered(mine, by: pullRequestFilterOption, events: state.events),
            by: pullRequestSortOption
        )
    }

    static func filtered(
        _ pullRequests: [PullRequest],
        by option: PullRequestFilterOption,
        events: [PullRequestEvent]
    ) -> [PullRequest] {
        let attentionIds = Set(events.map(\.prId))
        return pullRequests.filter { pr in
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
            try tokenStore.store(trimmed)
            account = viewer
            configureGitHubSource(token: trimmed, account: viewer)
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        do {
            try tokenStore.clear()
        } catch {
            errorMessage = error.localizedDescription
        }
        account = nil
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

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func dismissEvent(_ event: PullRequestEvent) {
        state.events.removeAll { $0.id == event.id }
    }

    func dismissAllEvents() {
        state.events.removeAll()
    }

    private func configureInitialSource() {
        do {
            if let token = try tokenStore.load() {
                let client = GitHubClient(token: token)
                syncEngine = SyncEngine(
                    source: client,
                    preferences: preferences,
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
                    accountProvider: { [weak self] in self?.account },
                    authStatusProvider: { .signedIn }
                )
                refresh()
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

    private func configureGitHubSource(token: String, account: GitHubAccount) {
        let client = GitHubClient(token: token)
        syncEngine = SyncEngine(
            source: client,
            preferences: preferences,
            loginProvider: { account.login },
            accountProvider: { account },
            authStatusProvider: { .signedIn }
        )
    }

    private func configureSignedOutSource() {
        let source = EmptyPullRequestSource()
        syncEngine = SyncEngine(
            source: source,
            preferences: preferences,
            loginProvider: { "rw" },
            accountProvider: { nil },
            authStatusProvider: { .signedOut }
        )
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
            notificationClient.post(events: nextState.events, pullRequests: nextState.pullRequests)
        } catch {
            errorMessage = error.localizedDescription
        }
        isRefreshing = false
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
