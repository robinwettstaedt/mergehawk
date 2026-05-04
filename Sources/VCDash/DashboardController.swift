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

    var openSettingsWindow: (() -> Void)?

    private let tokenStore: TokenStore
    private var preferencesStore = PreferencesStore()
    private let notificationClient = NotificationCenterClient()
    private var syncEngine: SyncEngine?
    private var account: GitHubAccount?

    init(tokenStore: TokenStore = KeychainTokenStore()) {
        self.tokenStore = tokenStore
        self.preferences = preferencesStore.notificationPreferences
        notificationClient.requestAuthorization()
        configureInitialSource()
    }

    var hasAttention: Bool {
        !state.events.isEmpty
    }

    var attentionCount: Int {
        state.events.count
    }

    var accountLabel: String {
        state.account?.login ?? "Mock data"
    }

    var sourceLabel: String {
        state.source == .github ? "GitHub" : "Mock"
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
        configureMockSource()
        refresh()
    }

    func showSettings() {
        openSettingsWindow?()
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
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
                configureMockSource()
                refresh()
            }
        } catch {
            errorMessage = error.localizedDescription
            configureMockSource()
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

    private func configureMockSource() {
        let mock = MockPullRequestSource()
        syncEngine = SyncEngine(
            source: mock,
            preferences: preferences,
            loginProvider: { "rw" },
            accountProvider: { GitHubAccount(login: "rw") },
            authStatusProvider: { .signedOut }
        )
    }

    private func sync() async {
        guard let syncEngine else {
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
}
