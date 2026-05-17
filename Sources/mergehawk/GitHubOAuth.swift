import AppKit
import Foundation
import mergehawkcore

enum GitHubAuthMethod: String {
    case oauth
    case pat

    var label: String {
        switch self {
        case .oauth:
            "GitHub OAuth"
        case .pat:
            "Personal access token"
        }
    }
}

enum MergeHawkAuthDefaults {
    static let appID = ProcessInfo.processInfo.environment["MERGEHAWK_GITHUB_OAUTH_APP_ID"] ?? ""
    static let clientID = ProcessInfo.processInfo.environment["MERGEHAWK_GITHUB_OAUTH_CLIENT_ID"] ?? ""
    static let clientSecret = ProcessInfo.processInfo.environment["MERGEHAWK_GITHUB_OAUTH_CLIENT_SECRET"] ?? ""
    static let loopbackPort = 53683
    static let githubHost = URL(string: "https://github.com")!
    static let scope = "read:user read:org repo notifications"
    static var authorizedAppSettingsURL: URL {
        if appID.isEmpty {
            URL(string: "https://github.com/settings/applications")!
        } else {
            URL(string: "https://github.com/settings/connections/applications/\(appID)")!
        }
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
            loopbackPort: MergeHawkAuthDefaults.loopbackPort,
            scope: MergeHawkAuthDefaults.scope
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
            "GitHub OAuth is not configured. Set MERGEHAWK_GITHUB_OAUTH_CLIENT_ID and MERGEHAWK_GITHUB_OAUTH_CLIENT_SECRET, or add the MergeHawk OAuth app credentials."
        case .missingStoredCredentials:
            "GitHub OAuth credentials are missing. Please sign in again."
        }
    }
}
