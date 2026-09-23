@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubInboxTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchGitHubAppInstallationsParsesAccountsAndRepositorySelection() async throws {
        let session = Self.mockSession()
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data("""
            {
              "total_count": 2,
              "installations": [
                {
                  "id": 1001,
                  "account": { "login": "rw", "type": "User" },
                  "repository_selection": "all",
                  "html_url": "https://github.com/settings/installations/1001"
                },
                {
                  "id": 1002,
                  "account": { "login": "acme", "type": "Organization" },
                  "repository_selection": "selected",
                  "html_url": "https://github.com/organizations/acme/settings/installations/1002"
                }
              ]
            }
            """.utf8)
            return (data, response)
        }

        let client = GitHubClient(token: "token", session: session)
        let result = try await client.fetchGitHubAppInstallations()

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(
            capturedRequest?.url?.absoluteString,
            "https://api.github.com/user/installations?per_page=100&page=1"
        )
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(result.installations.map(\.accountLogin), ["rw", "acme"])
        XCTAssertEqual(result.installations.map(\.repositorySelection), [.all, .selected])
        XCTAssertEqual(result.installations.first?.htmlURL, URL(string: "https://github.com/settings/installations/1001"))
    }

    func testFetchGitHubAppInstallationsPaginatesToTotalCount() async throws {
        let session = Self.mockSession()
        var requestedPages: [String] = []
        MockURLProtocol.handler = { request in
            requestedPages.append(request.url!.absoluteString)
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "page" })?.value
            let range = page == "1" ? 1...100 : 101...101
            let installations = range.map { id in
                [
                    "id": id,
                    "account": ["login": "account-\(id)", "type": "Organization"],
                    "repository_selection": "selected",
                    "html_url": "https://github.com/settings/installations/\(id)"
                ] as [String: Any]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "total_count": 101,
                "installations": installations
            ])
            return (data, Self.okResponse(for: request))
        }

        let result = try await GitHubClient(token: "token", session: session).fetchGitHubAppInstallations()

        XCTAssertEqual(result.installations.count, 101)
        XCTAssertEqual(requestedPages, [
            "https://api.github.com/user/installations?per_page=100&page=1",
            "https://api.github.com/user/installations?per_page=100&page=2"
        ])
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func okResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
