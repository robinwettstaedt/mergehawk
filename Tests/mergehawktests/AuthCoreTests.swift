@testable import mergehawkcore
import Foundation
import XCTest

final class AuthCoreTests: XCTestCase {
    func testPKCEGeneratesVerifierAndChallenge() {
        let pkce = PKCE.generate()
        XCTAssertFalse(pkce.verifier.isEmpty)
        XCTAssertFalse(pkce.challenge.isEmpty)
        XCTAssertNotEqual(pkce.verifier, pkce.challenge)
    }

    func testLoopbackParserExtractsCodeAndState() {
        let request = "GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let parsed = LoopbackServer.parse(request: request)
        XCTAssertEqual(parsed?.code, "abc")
        XCTAssertEqual(parsed?.state, "xyz")
    }

    @MainActor
    func testOAuthLoginPersistsTokens() async throws {
        let store = InMemoryTokenStore()
        let redirectURL = try XCTUnwrap(URL(string: "http://127.0.0.1:53683/callback"))
        let server = FakeLoopbackServer(
            redirectURL: redirectURL,
            callback: (code: "code-123", state: "state-123")
        )

        let flow = OAuthLoginFlow(
            tokenStore: store,
            openURL: { url in
                let queryItems = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                XCTAssertEqual(queryItems.first(where: { $0.name == "client_id" })?.value, "cid")
                XCTAssertEqual(queryItems.first(where: { $0.name == "redirect_uri" })?.value, redirectURL.absoluteString)
                XCTAssertEqual(queryItems.first(where: { $0.name == "scope" })?.value, "read:user read:org repo notifications")
                XCTAssertEqual(queryItems.first(where: { $0.name == "state" })?.value, "state-123")
                XCTAssertEqual(queryItems.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
            },
            dataProvider: { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                let body = try XCTUnwrap(Self.bodyString(from: request))
                XCTAssertTrue(body.contains("client_id=cid"))
                XCTAssertTrue(body.contains("client_secret=secret"))
                XCTAssertTrue(body.contains("grant_type=authorization_code"))
                XCTAssertTrue(body.contains("code=code-123"))
                XCTAssertTrue(body.contains("code_verifier="))
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let data = Data("""
                {"access_token":"access","token_type":"bearer","scope":"repo","expires_in":3600,"refresh_token":"refresh"}
                """.utf8)
                return (data, response)
            },
            makeLoopbackServer: { _ in server },
            stateProvider: { "state-123" }
        )

        let tokens = try await flow.login(
            clientID: "cid",
            clientSecret: "secret",
            host: URL(string: "https://github.com/path?ignored=true")!,
            loopbackPort: 53683,
            scope: "read:user read:org repo notifications",
            timeout: 1
        )

        XCTAssertEqual(tokens.accessToken, "access")
        XCTAssertEqual(tokens.refreshToken, "refresh")
        XCTAssertEqual(try store.loadOAuthTokens(), tokens)
    }

    func testOAuthRefresherUsesDefaultClientCredentials() async throws {
        let store = InMemoryTokenStore()
        try store.storeOAuthTokens(OAuthTokens(accessToken: "old", refreshToken: "r1", expiresAt: .distantPast))

        let refresher = OAuthTokenRefresher(
            tokenStore: store,
            defaultCredentials: OAuthClientCredentials(clientID: "cid", clientSecret: "secret")
        ) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(Self.bodyString(from: request))
            XCTAssertTrue(body.contains("client_id=cid"))
            XCTAssertTrue(body.contains("client_secret=secret"))
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
            defaultCredentials: OAuthClientCredentials(clientID: "cid", clientSecret: "secret")
        ) { _ in
            throw URLError(.badServerResponse)
        }

        let refreshed = try await refresher.refreshIfNeeded(host: URL(string: "https://github.com")!)
        XCTAssertEqual(refreshed, tokens)
    }

    private static func bodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        return nil
    }
}

@MainActor
private final class FakeLoopbackServer: LoopbackServing {
    private let redirectURL: URL
    private let callback: (code: String, state: String)

    init(redirectURL: URL, callback: (code: String, state: String)) {
        self.redirectURL = redirectURL
        self.callback = callback
    }

    func start() throws -> URL {
        redirectURL
    }

    func waitForCallback(timeout _: TimeInterval) async throws -> (code: String, state: String) {
        callback
    }

    func stop() {}
}
