import AppKit
import Foundation
import mergehawkcore

enum GitHubAuthMethod: String {
    case oauth
    case pat

    var label: String {
        switch self {
        case .oauth:
            "GitHub App"
        case .pat:
            "Personal access token"
        }
    }
}

enum GitHubTokenCapabilities {
    static func supportsGitHubInboxNotifications(token: String) -> Bool {
        token.hasPrefix("ghp_")
    }
}

enum MergeHawkAuthDefaults {
    private static let productionAppID = "3854497"
    private static let productionClientID = "Iv23li2wX6d8bxiM2goo"
    private static let productionClientSecret = "508cfef8b6bd279aa3fd795cd5094a0fa83329ed"
    private static let productionInstallURL = "https://github.com/apps/mergehawk/installations/new"
    private static let productionManageURL = "https://github.com/settings/apps/authorizations"

    static let appID = ProcessInfo.processInfo.environment["MERGEHAWK_GITHUB_APP_ID"] ?? productionAppID
    static let clientID = ProcessInfo.processInfo.environment["MERGEHAWK_GITHUB_APP_CLIENT_ID"] ?? productionClientID
    static let clientSecret = ProcessInfo.processInfo.environment["MERGEHAWK_GITHUB_APP_CLIENT_SECRET"] ?? productionClientSecret
    static let loopbackPort = 53683
    static let githubHost = URL(string: "https://github.com")!
    static let installURL = URL(
        string: ProcessInfo.processInfo.environment["MERGEHAWK_GITHUB_APP_INSTALL_URL"] ?? productionInstallURL
    )!
    static var authorizedAppSettingsURL: URL {
        URL(string: ProcessInfo.processInfo.environment["MERGEHAWK_GITHUB_APP_MANAGE_URL"] ?? productionManageURL)!
    }

    static var clientCredentials: OAuthClientCredentials {
        OAuthClientCredentials(clientID: clientID, clientSecret: clientSecret)
    }
}

@MainActor
protocol GitHubOAuthSigningIn {
    func signIn() async throws -> OAuthTokens
}

@MainActor
struct BrowserGitHubOAuthSignIn: GitHubOAuthSigningIn {
    private let tokenStore: TokenStore

    init(tokenStore: TokenStore) {
        self.tokenStore = tokenStore
    }

    func signIn() async throws -> OAuthTokens {
        guard !MergeHawkAuthDefaults.clientID.isEmpty, !MergeHawkAuthDefaults.clientSecret.isEmpty else {
            throw GitHubOAuthError.missingClientCredentials
        }

        let flow = OAuthLoginFlow(tokenStore: tokenStore) { url in
            NSWorkspace.shared.open(url)
        }
        return try await flow.login(
            clientID: MergeHawkAuthDefaults.clientID,
            clientSecret: MergeHawkAuthDefaults.clientSecret,
            host: MergeHawkAuthDefaults.githubHost,
            loopbackPort: MergeHawkAuthDefaults.loopbackPort
        )
    }
}

@MainActor
final class OAuthAccessTokenCache {
    private let tokenStore: TokenStore
    private let refresher: OAuthTokenRefresher
    private let host: URL
    private var cachedTokens: OAuthTokens?
    private var loadedStoredTokens = false

    init(
        tokenStore: TokenStore,
        credentials: OAuthClientCredentials = MergeHawkAuthDefaults.clientCredentials,
        host: URL = MergeHawkAuthDefaults.githubHost
    ) {
        self.tokenStore = tokenStore
        self.refresher = OAuthTokenRefresher(
            tokenStore: tokenStore,
            defaultCredentials: credentials
        )
        self.host = host
    }

    func store(_ tokens: OAuthTokens) {
        cachedTokens = tokens
        loadedStoredTokens = true
    }

    func clear() {
        cachedTokens = nil
        loadedStoredTokens = false
    }

    func accessToken() async throws -> String {
        let tokens = try loadTokensIfNeeded()
        let refreshedTokens = try await refresher.refreshIfNeeded(tokens: tokens, host: host)
        cachedTokens = refreshedTokens
        loadedStoredTokens = true
        return refreshedTokens.accessToken
    }

    private func loadTokensIfNeeded() throws -> OAuthTokens {
        if let cachedTokens {
            return cachedTokens
        }
        guard !loadedStoredTokens else {
            throw GitHubOAuthError.missingStoredCredentials
        }
        loadedStoredTokens = true
        guard let tokens = try tokenStore.loadOAuthTokens() else {
            throw GitHubOAuthError.missingStoredCredentials
        }
        cachedTokens = tokens
        return tokens
    }
}

enum GitHubOAuthError: LocalizedError {
    case missingClientCredentials
    case missingStoredCredentials

    var errorDescription: String? {
        switch self {
        case .missingClientCredentials:
            "MergeHawk GitHub App auth is not configured. Add the MergeHawk GitHub App credentials."
        case .missingStoredCredentials:
            "GitHub App credentials are missing. Please sign in again."
        }
    }
}
