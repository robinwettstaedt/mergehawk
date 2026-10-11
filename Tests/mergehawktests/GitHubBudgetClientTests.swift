@testable import mergehawkcore
import Foundation
import XCTest

final class GitHubBudgetClientTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let reset = now.addingTimeInterval(3_000)

    override func tearDown() {
        BudgetURLProtocol.handler = nil
        super.tearDown()
    }

    func testSuccessfulResponseHeadersBecomeTheLatestAndTheFetchResultReading() async throws {
        Self.serveFetch(used: { _ in 955 })
        let client = Self.client()

        let result = try await Self.fetch(client)

        XCTAssertEqual(result.budgetReading, Self.reading(used: 955))
        XCTAssertEqual(client.latestBudgetReading(), Self.reading(used: 955))
    }

    func testRateLimitedResponseThatThrowsStillUpdatesTheLatestReading() async throws {
        BudgetURLProtocol.handler = { request in
            Self.response(Data(), request, status: 403, headers: Self.budgetHeaders(used: 5_000))
        }
        let client = Self.client()

        do {
            _ = try await client.fetchBudgetReading()
            XCTFail("Expected the rate-limited budget read to throw")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .rateLimited(retryAt: Self.reset))
        }
        XCTAssertEqual(client.latestBudgetReading(), Self.reading(used: 5_000))
    }

    func testRetriedServerErrorKeepsTheHigherUsedOfBothAttempts() async throws {
        let recorder = BudgetRequestRecorder()
        BudgetURLProtocol.handler = { request in
            let attempt = recorder.record(request)
            return attempt == 1
                ? Self.response(Data(), request, status: 502, headers: Self.budgetHeaders(used: 920))
                : Self.response(Self.budgetReadBody(), request, headers: Self.budgetHeaders(used: 910))
        }
        let client = Self.client()

        let reading = try await client.fetchBudgetReading()

        XCTAssertEqual(recorder.count, 2)
        XCTAssertEqual(reading, Self.reading(used: 920))
        XCTAssertEqual(client.latestBudgetReading(), Self.reading(used: 920))
    }

    func testOutOfOrderResponsesKeepTheHigherUsed() async throws {
        Self.serveFetch(used: { query in query.contains("DiscoveryBounds") ? 960 : 950 })
        let client = Self.client()

        let result = try await Self.fetch(client)

        XCTAssertEqual(result.budgetReading?.used, 960)
        XCTAssertEqual(client.latestBudgetReading()?.used, 960)
    }

    func testFetchResultReadingExcludesABudgetReadSentBeforeTheFetch() async throws {
        Self.serveFetch(used: { query in query == GitHubClient.budgetReadQuery ? 990 : 950 })
        let client = Self.client()

        let baseline = try await client.fetchBudgetReading()
        let result = try await Self.fetch(client)

        XCTAssertEqual(baseline?.used, 990)
        XCTAssertEqual(result.budgetReading?.used, 950)
        XCTAssertEqual(client.latestBudgetReading()?.used, 990)
    }

    func testBudgetReadSendsTheFreeQueryAndReturnsTheReading() async throws {
        let recorder = BudgetRequestRecorder()
        BudgetURLProtocol.handler = { request in
            recorder.record(request)
            return Self.response(Self.budgetReadBody(), request, headers: Self.budgetHeaders(used: 1_868))
        }
        let client = Self.client()

        let reading = try await client.fetchBudgetReading()

        XCTAssertEqual(recorder.queries, ["query { rateLimit { limit } }"])
        XCTAssertEqual(reading, Self.reading(used: 1_868))
    }

    func testBudgetReadMapsAuthenticationAndRateLimitErrors() async throws {
        BudgetURLProtocol.handler = { request in Self.response(Data(), request, status: 401) }
        do {
            _ = try await Self.client().fetchBudgetReading()
            XCTFail("Expected 401 to throw")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .authentication)
        }

        BudgetURLProtocol.handler = { request in
            Self.response(Data(), request, status: 403, headers: [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "\(Int(Self.reset.timeIntervalSince1970))"
            ])
        }
        do {
            _ = try await Self.client().fetchBudgetReading()
            XCTFail("Expected the rate-limited read to throw")
        } catch {
            XCTAssertEqual(error as? GitHubReadError, .rateLimited(retryAt: Self.reset))
        }
    }

    func testResponseWithoutBudgetHeadersLeavesThePreviousReadingUnchanged() async throws {
        let recorder = BudgetRequestRecorder()
        BudgetURLProtocol.handler = { request in
            let attempt = recorder.record(request)
            return Self.response(
                Self.budgetReadBody(),
                request,
                headers: attempt == 1 ? Self.budgetHeaders(used: 800) : [:]
            )
        }
        let client = Self.client()

        _ = try await client.fetchBudgetReading()
        let second = try await client.fetchBudgetReading()

        XCTAssertNil(second)
        XCTAssertEqual(client.latestBudgetReading(), Self.reading(used: 800))
    }

    // MARK: - Fixtures

    private static func client() -> GitHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BudgetURLProtocol.self]
        return GitHubClient(token: "token", session: URLSession(configuration: configuration), now: { now })
    }

    private static func fetch(_ client: GitHubClient) async throws -> CompletePullRequestFetchResult {
        try await client.fetchCompletePullRequests(login: "rw", previousState: nil, reusableViewerTeams: [])
    }

    /// Serves an empty discovery and the budget read, each with the `used` the closure picks for its query.
    private static func serveFetch(used: @escaping (String) -> Int) {
        BudgetURLProtocol.handler = { request in
            let query = graphQLQuery(request)
            let headers = budgetHeaders(used: used(query))
            if query == GitHubClient.budgetReadQuery { return response(budgetReadBody(), request, headers: headers) }
            if query.contains("DiscoveryBounds") { return response(emptyBounds(), request, headers: headers) }
            if query.contains("DiscoverPullRequests") { return response(emptyDiscovery(), request, headers: headers) }
            XCTFail("Unexpected query \(query.prefix(80))")
            return response(Data(), request, status: 500)
        }
    }

    private static func reading(used: Int) -> GitHubBudgetReading {
        GitHubBudgetReading(limit: 5_000, remaining: 5_000 - used, used: used, resetAt: reset, receivedAt: now)
    }

    private static func budgetHeaders(used: Int) -> [String: String] {
        [
            "X-RateLimit-Limit": "5000",
            "X-RateLimit-Remaining": "\(5_000 - used)",
            "X-RateLimit-Used": "\(used)",
            "X-RateLimit-Reset": "\(Int(reset.timeIntervalSince1970))"
        ]
    }

    private static func budgetReadBody() -> Data {
        json(["data": ["rateLimit": ["limit": 5_000]]])
    }

    private static func emptyBounds() -> Data {
        var object: [String: Any] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            object["\(lane.rawValue)Oldest"] = ["nodes": []]
            object["\(lane.rawValue)Newest"] = ["nodes": []]
        }
        return json(["data": object])
    }

    private static func emptyDiscovery() -> Data {
        var object: [String: Any] = [:]
        for lane in GitHubDiscoveryLane.allCases {
            object[lane.rawValue] = [
                "issueCount": 0, "nodes": [],
                "pageInfo": ["startCursor": NSNull(), "endCursor": NSNull(), "hasPreviousPage": false, "hasNextPage": false]
            ]
        }
        return json(["data": object])
    }

    fileprivate static func graphQLQuery(_ request: URLRequest) -> String {
        guard request.url?.path == "/graphql", let body = requestBody(request),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return "" }
        return json["query"] as? String ?? ""
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func response(
        _ data: Data,
        _ request: URLRequest,
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    private static func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }
}

private final class BudgetURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let result = try Self.handler?(request) else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: result.1, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.0)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class BudgetRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var queries: [String] { lock.withLock { recorded } }
    var count: Int { lock.withLock { recorded.count } }

    /// Returns the request's 1-based position.
    @discardableResult
    func record(_ request: URLRequest) -> Int {
        let query = GitHubBudgetClientTests.graphQLQuery(request)
        return lock.withLock {
            recorded.append(query)
            return recorded.count
        }
    }
}
