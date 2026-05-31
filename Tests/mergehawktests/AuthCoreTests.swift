@testable import mergehawk
@testable import mergehawkcore
import Foundation
import XCTest

final class AuthCoreTests: XCTestCase {

    // MARK: - DeviceFlowLogin.requestCode

    func testDeviceFlowRequestCodeReturnsChallenge() async throws {
        let login = DeviceFlowLogin(
            load: { _ in
                let data = Data("""
                {"device_code":"dc1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
                """.utf8)
                let response = HTTPURLResponse(url: URL(string: "https://github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            },
            now: { Date(timeIntervalSince1970: 0) }
        )

        let challenge = try await login.requestCode(clientID: "cid", host: URL(string: "https://github.com")!)
        XCTAssertEqual(challenge.userCode, "ABCD-1234")
        XCTAssertEqual(challenge.deviceCode, "dc1")
        XCTAssertEqual(challenge.verificationURI.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(challenge.expiresAt.timeIntervalSince1970, 900)
        XCTAssertEqual(challenge.interval, 5)
    }

    func testDeviceFlowRequestCodeFailsOnNon200() async throws {
        let login = DeviceFlowLogin(
            load: { _ in
                let data = Data()
                let response = HTTPURLResponse(url: URL(string: "https://github.com")!, statusCode: 422, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
        )

        do {
            _ = try await login.requestCode(clientID: "cid", host: URL(string: "https://github.com")!)
            XCTFail("Expected error")
        } catch let error as DeviceFlowError {
            guard case .requestFailed(422) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testDeviceFlowRequestCodeMapsDeviceFlowDisabled() async throws {
        let login = DeviceFlowLogin(
            load: { _ in
                let data = Data("""
                {"error":"device_flow_disabled","error_description":"Device flow not enabled"}
                """.utf8)
                let response = HTTPURLResponse(url: URL(string: "https://github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
        )

        do {
            _ = try await login.requestCode(clientID: "cid", host: URL(string: "https://github.com")!)
            XCTFail("Expected deviceFlowDisabled error")
        } catch let error as DeviceFlowError {
            guard case .deviceFlowDisabled = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    // MARK: - DeviceFlowLogin.pollForTokens

    func testDeviceFlowPollSucceedsAfterAuthorizationPending() async throws {
        let callCount = SendableBox(0)
        let login = DeviceFlowLogin(
            load: { _ in
                callCount.value += 1
                let body: String
                if callCount.value == 1 {
                    body = """
                    {"error":"authorization_pending","error_description":"Still waiting"}
                    """
                } else {
                    body = """
                    {"access_token":"new-access","token_type":"bearer","scope":"","expires_in":28800,"refresh_token":"new-refresh"}
                    """
                }
                let data = Data(body.utf8)
                let response = HTTPURLResponse(url: URL(string: "https://github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            },
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 0) }
        )

        let challenge = DeviceFlowChallenge(
            userCode: "XXXX-YYYY",
            deviceCode: "dc1",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: Date(timeIntervalSince1970: 900),
            interval: 5
        )

        let tokens = try await login.pollForTokens(clientID: "cid", challenge: challenge)
        XCTAssertEqual(tokens.accessToken, "new-access")
        XCTAssertEqual(tokens.refreshToken, "new-refresh")
        XCTAssertEqual(callCount.value, 2)
    }

    func testDeviceFlowSlowDownIncreasesInterval() async throws {
        let callCount = SendableBox(0)
        let recordedSleeps = SendableBox<[TimeInterval]>([])
        let login = DeviceFlowLogin(
            load: { _ in
                callCount.value += 1
                let body: String
                if callCount.value == 1 {
                    body = """
                    {"error":"slow_down","error_description":"Too fast"}
                    """
                } else {
                    body = """
                    {"access_token":"tok","token_type":"bearer","scope":"","expires_in":28800,"refresh_token":"ref"}
                    """
                }
                let data = Data(body.utf8)
                let response = HTTPURLResponse(url: URL(string: "https://github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            },
            sleep: { interval in recordedSleeps.value.append(interval) },
            now: { Date(timeIntervalSince1970: 0) }
        )

        let challenge = DeviceFlowChallenge(
            userCode: "XXXX-YYYY",
            deviceCode: "dc1",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: Date(timeIntervalSince1970: 900),
            interval: 5
        )

        _ = try await login.pollForTokens(clientID: "cid", challenge: challenge)
        XCTAssertEqual(recordedSleeps.value, [5, 10])
    }

    func testDeviceFlowLocalExpiryThrowsBeforePoll() async throws {
        let login = DeviceFlowLogin(
            load: { _ in
                XCTFail("Should not poll after local expiry check")
                throw URLError(.unknown)
            },
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 1000) }
        )

        let challenge = DeviceFlowChallenge(
            userCode: "XXXX-YYYY",
            deviceCode: "dc1",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: Date(timeIntervalSince1970: 900),
            interval: 5
        )

        do {
            _ = try await login.pollForTokens(clientID: "cid", challenge: challenge)
            XCTFail("Expected codeExpired error")
        } catch let error as DeviceFlowError {
            guard case .codeExpired = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testDeviceFlowLocalExpiryThrowsAfterSleepBeforePoll() async throws {
        let now = SendableBox(Date(timeIntervalSince1970: 0))
        let login = DeviceFlowLogin(
            load: { _ in
                XCTFail("Should not poll after code expires during sleep")
                throw URLError(.unknown)
            },
            sleep: { _ in now.value = Date(timeIntervalSince1970: 901) },
            now: { now.value }
        )

        let challenge = DeviceFlowChallenge(
            userCode: "XXXX-YYYY",
            deviceCode: "dc1",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: Date(timeIntervalSince1970: 900),
            interval: 5
        )

        do {
            _ = try await login.pollForTokens(clientID: "cid", challenge: challenge)
            XCTFail("Expected codeExpired error")
        } catch let error as DeviceFlowError {
            guard case .codeExpired = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testDeviceFlowAccessDeniedThrows() async throws {
        let login = DeviceFlowLogin(
            load: { _ in
                let data = Data("""
                {"error":"access_denied","error_description":"Denied"}
                """.utf8)
                let response = HTTPURLResponse(url: URL(string: "https://github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            },
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 0) }
        )

        let challenge = DeviceFlowChallenge(
            userCode: "XXXX-YYYY",
            deviceCode: "dc1",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: Date(timeIntervalSince1970: 900),
            interval: 5
        )

        do {
            _ = try await login.pollForTokens(clientID: "cid", challenge: challenge)
            XCTFail("Expected accessDenied error")
        } catch let error as DeviceFlowError {
            guard case .accessDenied = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testDeviceFlowDisabledThrows() async throws {
        let login = DeviceFlowLogin(
            load: { _ in
                let data = Data("""
                {"error":"device_flow_disabled","error_description":"Device flow not enabled"}
                """.utf8)
                let response = HTTPURLResponse(url: URL(string: "https://github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            },
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 0) }
        )

        let challenge = DeviceFlowChallenge(
            userCode: "XXXX-YYYY",
            deviceCode: "dc1",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: Date(timeIntervalSince1970: 900),
            interval: 5
        )

        do {
            _ = try await login.pollForTokens(clientID: "cid", challenge: challenge)
            XCTFail("Expected deviceFlowDisabled error")
        } catch let error as DeviceFlowError {
            guard case .deviceFlowDisabled = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    // MARK: - OAuthTokenRefresher (device flow: no client_secret)

    func testOAuthRefresherDoesNotSendClientSecret() async throws {
        let store = InMemoryTokenStore()
        try store.storeOAuthTokens(OAuthTokens(accessToken: "old", refreshToken: "r1", expiresAt: .distantPast))

        let refresher = OAuthTokenRefresher(
            tokenStore: store,
            defaultCredentials: OAuthClientCredentials(clientID: "cid")
        ) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(Self.bodyString(from: request))
            XCTAssertTrue(body.contains("client_id=cid"))
            XCTAssertFalse(body.contains("client_secret"))
            XCTAssertTrue(body.contains("grant_type=refresh_token"))
            XCTAssertTrue(body.contains("refresh_token=r1"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data("""
            {"access_token":"new","token_type":"bearer","scope":"repo","expires_in":3600,"refresh_token":"r2"}
            """.utf8)
            return (data, response)
        }

        let tokens = try await refresher.refreshIfNeeded(host: URL(string: "https://github.com")!)
        XCTAssertEqual(tokens?.accessToken, "new")
        XCTAssertEqual(try store.loadOAuthTokens()?.refreshToken, "r2")
    }

    func testOAuthRefresherSkipsWhenRefreshTokenIsMissing() async throws {
        let store = InMemoryTokenStore()
        let tokens = OAuthTokens(accessToken: "access", refreshToken: "", expiresAt: nil)
        try store.storeOAuthTokens(tokens)

        let refresher = OAuthTokenRefresher(
            tokenStore: store,
            defaultCredentials: OAuthClientCredentials(clientID: "cid")
        ) { _ in
            throw URLError(.badServerResponse)
        }

        let refreshed = try await refresher.refreshIfNeeded(host: URL(string: "https://github.com")!)
        XCTAssertEqual(refreshed, tokens)
    }

    // MARK: - OAuthAccessTokenCache

    @MainActor
    func testOAuthAccessTokenCacheLoadsStoredTokensOnce() async throws {
        let store = CountingOAuthTokenStore()
        let tokens = OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
        try store.storeOAuthTokens(tokens)
        let cache = OAuthAccessTokenCache(
            tokenStore: store,
            credentials: OAuthClientCredentials(clientID: "cid")
        )

        let firstAccessToken = try await cache.accessToken()
        let secondAccessToken = try await cache.accessToken()
        XCTAssertEqual(firstAccessToken, "access")
        XCTAssertEqual(secondAccessToken, "access")
        XCTAssertEqual(store.loadOAuthTokensCallCount, 1)
    }

    @MainActor
    func testOAuthAccessTokenCacheUsesPrimedTokensWithoutLoadingStore() async throws {
        let store = CountingOAuthTokenStore()
        let tokens = OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
        let cache = OAuthAccessTokenCache(
            tokenStore: store,
            credentials: OAuthClientCredentials(clientID: "cid")
        )

        cache.store(tokens)

        let accessToken = try await cache.accessToken()
        XCTAssertEqual(accessToken, "access")
        XCTAssertEqual(store.loadOAuthTokensCallCount, 0)
    }

    private static func bodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        return nil
    }
}

private final class CountingOAuthTokenStore: TokenStore {
    private var pat: String?
    private var oauthTokens: OAuthTokens?
    private(set) var loadOAuthTokensCallCount = 0

    func load() throws -> String? {
        try loadPAT()
    }

    func store(_ token: String) throws {
        try storePAT(token)
    }

    func clear() throws {
        try clearPAT()
        try clearOAuthTokens()
    }

    func loadPAT() throws -> String? {
        pat
    }

    func storePAT(_ token: String) throws {
        pat = token
    }

    func clearPAT() throws {
        pat = nil
    }

    func loadOAuthTokens() throws -> OAuthTokens? {
        loadOAuthTokensCallCount += 1
        return oauthTokens
    }

    func storeOAuthTokens(_ tokens: OAuthTokens) throws {
        oauthTokens = tokens
    }

    func clearOAuthTokens() throws {
        oauthTokens = nil
    }
}

private final class SendableBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
