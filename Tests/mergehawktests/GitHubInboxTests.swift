@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubInboxTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchInboxNotificationsFiltersPullRequestsAndPersistsMetadata() async throws {
        let session = Self.mockSession()
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "ETag": #""inbox-etag""#,
                    "X-Poll-Interval": "120"
                ]
            )!
            let data = Data("""
            [
              {
                "id": "issue-thread",
                "repository": { "full_name": "acme/app" },
                "subject": {
                  "title": "Broken save button",
                  "url": "https://api.github.com/repos/acme/app/issues/12",
                  "latest_comment_url": null,
                  "type": "Issue"
                },
                "reason": "mention",
                "unread": true,
                "updated_at": "2026-05-02T12:00:00Z",
                "url": "https://api.github.com/notifications/threads/issue-thread"
              },
              {
                "id": "pr-thread",
                "repository": { "full_name": "acme/app" },
                "subject": {
                  "title": "Ship dashboard",
                  "url": "https://api.github.com/repos/acme/app/pulls/13",
                  "latest_comment_url": null,
                  "type": "PullRequest"
                },
                "reason": "review_requested",
                "unread": true,
                "updated_at": "2026-05-02T13:00:00Z",
                "url": "https://api.github.com/notifications/threads/pr-thread"
              }
            ]
            """.utf8)
            return (data, response)
        }

        let client = GitHubClient(token: "token", session: session)
        let result = try await client.fetchInboxNotifications(
            metadata: GitHubInboxSyncMetadata(eTag: #""old-etag""#, lastFetchedAt: nil, pollIntervalSeconds: nil)
        )

        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.github.com/notifications?all=true&per_page=50")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "If-None-Match"), #""old-etag""#)
        XCTAssertEqual(result.notifications.map(\.threadId), ["issue-thread"])
        XCTAssertEqual(result.notifications.first?.webURL, URL(string: "https://github.com/acme/app/issues/12"))
        XCTAssertEqual(result.metadata.eTag, #""inbox-etag""#)
        XCTAssertEqual(result.metadata.pollIntervalSeconds, 120)
        XCTAssertFalse(result.isNotModified)
    }

    func testFetchInboxNotificationsHandlesNotModified() async throws {
        let session = Self.mockSession()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: nil,
                headerFields: ["X-Poll-Interval": "90"]
            )!
            return (Data(), response)
        }

        let client = GitHubClient(token: "token", session: session)
        let result = try await client.fetchInboxNotifications(metadata: .empty)

        XCTAssertTrue(result.isNotModified)
        XCTAssertEqual(result.notifications, [])
        XCTAssertEqual(result.metadata.pollIntervalSeconds, 90)
    }

    func testMarkInboxThreadReadUsesThreadEndpoint() async throws {
        let session = Self.mockSession()
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 205,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        let client = GitHubClient(token: "token", session: session)
        try await client.markInboxThreadRead(threadId: "123")

        XCTAssertEqual(capturedRequest?.httpMethod, "PATCH")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.github.com/notifications/threads/123")
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
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
