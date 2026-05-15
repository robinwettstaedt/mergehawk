import Foundation

public enum OAuthFlowError: LocalizedError {
    case invalidHost
    case stateMismatch
    case tokenRequestFailed(status: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidHost:
            "GitHub OAuth host must be a valid HTTPS URL."
        case .stateMismatch:
            "GitHub sign-in returned an invalid state. Please try again."
        case .tokenRequestFailed(let status):
            "GitHub sign-in token exchange failed with status \(status)."
        }
    }
}

@MainActor
public struct OAuthLoginFlow {
    private let tokenStore: TokenStore
    private let openURL: @Sendable (URL) throws -> Void
    private let dataProvider: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let makeLoopbackServer: (Int) -> LoopbackServing
    private let stateProvider: @Sendable () -> String

    public init(
        tokenStore: TokenStore,
        openURL: @escaping @Sendable (URL) throws -> Void,
        dataProvider: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.init(
            tokenStore: tokenStore,
            openURL: openURL,
            dataProvider: dataProvider,
            makeLoopbackServer: { port in LoopbackServer(port: port) },
            stateProvider: { UUID().uuidString }
        )
    }

    init(
        tokenStore: TokenStore,
        openURL: @escaping @Sendable (URL) throws -> Void,
        dataProvider: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        makeLoopbackServer: @escaping (Int) -> LoopbackServing,
        stateProvider: @escaping @Sendable () -> String
    ) {
        self.tokenStore = tokenStore
        self.openURL = openURL
        self.dataProvider = dataProvider
        self.makeLoopbackServer = makeLoopbackServer
        self.stateProvider = stateProvider
    }

    public func login(
        clientID: String,
        clientSecret: String,
        host: URL,
        loopbackPort: Int,
        scope: String,
        timeout: TimeInterval = 180
    ) async throws -> OAuthTokens {
        let normalizedHost = try Self.normalizeHost(host)
        let authBase = normalizedHost.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let authEndpoint = URL(string: "\(authBase)/login/oauth/authorize")!
        let tokenEndpoint = URL(string: "\(authBase)/login/oauth/access_token")!

        let pkce = PKCE.generate()
        let state = stateProvider()
        let server = makeLoopbackServer(loopbackPort)
        let redirectURL = try server.start()

        defer { server.stop() }

        var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let authorizeURL = components.url else {
            throw URLError(.badURL)
        }

        try openURL(authorizeURL)

        let callback = try await server.waitForCallback(timeout: timeout)
        guard callback.state == state else {
            throw OAuthFlowError.stateMismatch
        }

        var tokenRequest = URLRequest(url: tokenEndpoint)
        tokenRequest.httpMethod = "POST"
        tokenRequest.addValue("application/json", forHTTPHeaderField: "Accept")
        tokenRequest.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = Self.formURLEncoded([
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": callback.code,
            "redirect_uri": redirectURL.absoluteString,
            "grant_type": "authorization_code",
            "code_verifier": pkce.verifier
        ])

        let (data, response) = try await dataProvider(tokenRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthFlowError.tokenRequestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        let tokens = OAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? "",
            expiresAt: decoded.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
        try tokenStore.storeOAuthTokens(tokens)
        return tokens
    }

    public static func normalizeHost(_ host: URL) throws -> URL {
        guard var components = URLComponents(url: host, resolvingAgainstBaseURL: false) else {
            throw OAuthFlowError.invalidHost
        }
        if components.scheme == nil {
            components.scheme = "https"
        }
        guard components.scheme?.lowercased() == "https", components.host != nil else {
            throw OAuthFlowError.invalidHost
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let cleaned = components.url else {
            throw OAuthFlowError.invalidHost
        }
        return cleaned
    }

    private static func formURLEncoded(_ parameters: [String: String]) -> Data? {
        let encoded = parameters.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
        return encoded.data(using: .utf8)
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let scope: String?
    let expiresIn: Int?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}
