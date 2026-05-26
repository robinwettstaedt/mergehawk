import Foundation

public struct DeviceFlowChallenge: Sendable {
    public let userCode: String
    public let deviceCode: String
    public let verificationURI: URL
    public let expiresAt: Date
    public let interval: TimeInterval

    public init(
        userCode: String,
        deviceCode: String,
        verificationURI: URL,
        expiresAt: Date,
        interval: TimeInterval
    ) {
        self.userCode = userCode
        self.deviceCode = deviceCode
        self.verificationURI = verificationURI
        self.expiresAt = expiresAt
        self.interval = interval
    }
}

public enum DeviceFlowError: LocalizedError {
    case deviceFlowDisabled
    case accessDenied
    case codeExpired
    case invalidResponse
    case requestFailed(status: Int)

    public var errorDescription: String? {
        switch self {
        case .deviceFlowDisabled:
            "Device flow is not enabled for this GitHub App."
        case .accessDenied:
            "GitHub sign-in was denied. Please try again."
        case .codeExpired:
            "The sign-in code expired. Please try again."
        case .invalidResponse:
            "GitHub returned an unexpected response. Please try again."
        case .requestFailed(let status):
            "GitHub sign-in failed with status \(status)."
        }
    }
}

public struct DeviceFlowLogin {
    private let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    public init(
        load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.load = load
        self.sleep = sleep
        self.now = now
    }

    public func requestCode(clientID: String, host: URL) async throws -> DeviceFlowChallenge {
        let base = host.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = URL(string: "\(base)/login/device/code")!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded(["client_id": clientID])

        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DeviceFlowError.requestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        do {
            let decoded = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
            guard let verificationURI = URL(string: decoded.verificationUri) else {
                throw DeviceFlowError.invalidResponse
            }
            return DeviceFlowChallenge(
                userCode: decoded.userCode,
                deviceCode: decoded.deviceCode,
                verificationURI: verificationURI,
                expiresAt: now().addingTimeInterval(TimeInterval(decoded.expiresIn)),
                interval: TimeInterval(decoded.interval)
            )
        } catch is DecodingError {
            throw DeviceFlowError.invalidResponse
        }
    }

    public func pollForTokens(
        clientID: String,
        challenge: DeviceFlowChallenge,
        tokenStore: TokenStore
    ) async throws -> OAuthTokens {
        let scheme = challenge.verificationURI.scheme ?? "https"
        let host = challenge.verificationURI.host ?? "github.com"
        let tokenEndpoint = URL(string: "\(scheme)://\(host)/login/oauth/access_token")!
        var pollInterval = challenge.interval

        while true {
            try Task.checkCancellation()
            if now() >= challenge.expiresAt {
                throw DeviceFlowError.codeExpired
            }
            try await sleep(pollInterval)
            try Task.checkCancellation()

            var request = URLRequest(url: tokenEndpoint)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Accept")
            request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formURLEncoded([
                "client_id": clientID,
                "device_code": challenge.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])

            let (data, response) = try await load(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw DeviceFlowError.requestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
            }

            if let tokenResponse = try? JSONDecoder().decode(DeviceTokenResponse.self, from: data),
               !tokenResponse.accessToken.isEmpty {
                let tokens = OAuthTokens(
                    accessToken: tokenResponse.accessToken,
                    refreshToken: tokenResponse.refreshToken ?? "",
                    expiresAt: tokenResponse.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) }
                )
                try tokenStore.storeOAuthTokens(tokens)
                return tokens
            }

            if let errorResponse = try? JSONDecoder().decode(DeviceFlowErrorResponse.self, from: data) {
                switch errorResponse.error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    pollInterval += 5
                    continue
                case "access_denied":
                    throw DeviceFlowError.accessDenied
                case "expired_token":
                    throw DeviceFlowError.codeExpired
                case "unsupported_grant_type", "incorrect_client_credentials", "incorrect_device_code":
                    throw DeviceFlowError.invalidResponse
                case "device_flow_disabled":
                    throw DeviceFlowError.deviceFlowDisabled
                default:
                    throw DeviceFlowError.invalidResponse
                }
            }

            throw DeviceFlowError.invalidResponse
        }
    }

    private func formURLEncoded(_ parameters: [String: String]) -> Data? {
        let encoded = parameters.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
        return encoded.data(using: .utf8)
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct DeviceTokenResponse: Decodable {
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

private struct DeviceFlowErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
