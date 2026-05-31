import Foundation

public struct OAuthTokenRefresher {
    private let tokenStore: TokenStore
    private let defaultCredentials: OAuthClientCredentials
    private let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(
        tokenStore: TokenStore,
        defaultCredentials: OAuthClientCredentials,
        load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.tokenStore = tokenStore
        self.defaultCredentials = defaultCredentials
        self.load = load
    }

    public func refreshIfNeeded(host: URL, force: Bool = false) async throws -> OAuthTokens? {
        guard let tokens = try tokenStore.loadOAuthTokens() else {
            return nil
        }
        return try await refreshIfNeeded(tokens: tokens, host: host, force: force)
    }

    public func refreshIfNeeded(tokens storedTokens: OAuthTokens, host: URL, force: Bool = false) async throws -> OAuthTokens {
        var tokens = storedTokens
        if tokens.refreshToken.isEmpty {
            return tokens
        }
        if !force, let expiresAt = tokens.expiresAt, expiresAt > Date().addingTimeInterval(60) {
            return tokens
        }

        let base = host.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let refreshURL = URL(string: "\(base)/login/oauth/access_token")!

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncoded([
            "client_id": defaultCredentials.clientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken
        ])

        let (data, responseAny) = try await load(request)
        guard let response = responseAny as? HTTPURLResponse else {
            throw GitHubClientError.httpFailure(endpoint: "GitHub auth refresh", status: -1)
        }
        guard response.statusCode == 200 else {
            throw GitHubClientError.authRefreshFailed(
                status: response.statusCode,
                detail: Self.refreshErrorDetail(from: data)
            )
        }

        do {
            let decoded = try JSONDecoder().decode(OAuthRefreshResponse.self, from: data)
            tokens = OAuthTokens(
                accessToken: decoded.accessToken,
                refreshToken: decoded.refreshToken ?? tokens.refreshToken,
                expiresAt: decoded.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            )
            try tokenStore.storeOAuthTokens(tokens)
            return tokens
        } catch {
            throw GitHubClientError.authRefreshFailed(status: response.statusCode, detail: Self.refreshErrorDetail(from: data))
        }
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

    private static func refreshErrorDetail(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) {
            return cleaned(decoded.errorDescription ?? decoded.message ?? decoded.error ?? "")
        }
        return String(data: data, encoding: .utf8).map(cleaned)
    }

    private static func cleaned(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

private struct OAuthRefreshResponse: Decodable {
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

private struct OAuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case message
    }
}
