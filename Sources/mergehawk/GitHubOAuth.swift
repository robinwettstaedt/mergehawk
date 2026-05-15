import AppKit
import Foundation
import mergehawkcore

enum GitHubAuthMethod: String {
    case oauth = "GitHub OAuth"
    case pat = "Personal access token"
}

enum MergeHawkAuthDefaults {
    static let clientID = ProcessInfo.processInfo.environment["MERGEHAWK_GITHUB_OAUTH_CLIENT_ID"] ?? ""
    static let clientSecret = ProcessInfo.processInfo.environment["MERGEHAWK_GITHUB_OAUTH_CLIENT_SECRET"] ?? ""
    static let loopbackPort = 53683
    static let githubHost = URL(string: "https://github.com")!
    static let scope = "read:user read:org repo notifications"

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
