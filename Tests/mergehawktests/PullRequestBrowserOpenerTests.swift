@testable import mergehawk
import Foundation
import XCTest

final class PullRequestBrowserOpenerTests: XCTestCase {
    private let base = URL(string: "https://github.com/acme/app/pull/12")!
    private let destination = URL(string: "https://github.com/acme/app/pull/12?view=comment#discussion_r7")!
    private let target = BrowserTarget(bundleIdentifier: "com.apple.Safari", processIdentifier: 123)

    @MainActor
    func testClosedBrowserDenialAndMissingMatchOpenFullURLExactlyOnce() async {
        let backend = FakeBrowserBackend(windows: [Self.window(url: URL(string: "https://github.com/other/app/pull/12")!)])
        var selected: BrowserTarget?
        var normal: [URL] = []
        var yielded = 0
        let opener = PullRequestBrowserOpener(
            resolveBrowser: { _ in selected }, backend: backend,
            yieldActivation: { _ in yielded += 1 }, requestActivation: { _ in true },
            openNormally: { normal.append($0) }
        )
        let request = PullRequestOpenRequest(pullRequestURL: base, destinationURL: destination)
        opener.open(request)
        await waitUntil { normal.count == 1 }
        XCTAssertEqual(normal, [destination])
        XCTAssertEqual(backend.permissionCount, 0)

        selected = target
        backend.permissions = [.denied, .approved]
        opener.open(request)
        await waitUntil { normal.count == 2 }
        XCTAssertEqual(backend.permissionCount, 1)
        XCTAssertEqual(backend.windowCount, 0)
        opener.open(request)
        await waitUntil { normal.count == 3 }
        XCTAssertEqual(backend.permissionCount, 2)
        XCTAssertEqual(backend.windowCount, 1)
        XCTAssertEqual(backend.applyCount, 0)
        XCTAssertEqual(normal, [destination, destination, destination])
        XCTAssertEqual(yielded, 2)
    }

    @MainActor
    func testConsentWaitQueuesSecondRequestAndKeepsMainActorAvailable() async {
        let backend = FakeBrowserBackend(windows: [Self.window(url: base)])
        let gate = DispatchSemaphore(value: 0)
        backend.permissionGate = gate
        let permissionStarted = expectation(description: "permission started")
        backend.onPermissionStart = { permissionStarted.fulfill() }
        var activated: [BrowserTarget] = []
        var normal: [URL] = []
        let opener = PullRequestBrowserOpener(
            resolveBrowser: { _ in self.target }, backend: backend,
            yieldActivation: { _ in }, requestActivation: { target in activated.append(target); return true },
            openNormally: { normal.append($0) }
        )
        opener.open(PullRequestOpenRequest(pullRequestURL: base))
        await fulfillment(of: [permissionStarted], timeout: 2)
        opener.open(PullRequestOpenRequest(pullRequestURL: base, destinationURL: destination))
        await Task.yield()
        XCTAssertEqual(backend.permissionCount, 1)
        XCTAssertTrue(normal.isEmpty)
        XCTAssertTrue(activated.isEmpty)
        gate.signal()
        await waitUntil { activated.count == 2 }
        XCTAssertEqual(backend.permissionCount, 2)
        XCTAssertEqual(backend.applyCount, 2)
        XCTAssertEqual(backend.appliedRequests.map(\.targetURL), [base, destination])
        XCTAssertEqual(backend.appliedRequests.last?.targetURL, destination)
        XCTAssertTrue(normal.isEmpty)
    }

    @MainActor
    func testNativeFailureAndFailedActivationFallBackInRequestOrder() async {
        let backend = FakeBrowserBackend(windows: [Self.window(url: base)])
        backend.failApply = true
        var normal: [URL] = []
        var activationCount = 0
        let opener = PullRequestBrowserOpener(
            resolveBrowser: { _ in self.target }, backend: backend,
            yieldActivation: { _ in },
            requestActivation: { _ in activationCount += 1; return false },
            openNormally: { normal.append($0) }
        )
        opener.open(PullRequestOpenRequest(pullRequestURL: base, destinationURL: destination))
        await waitUntil { normal.count == 1 }
        XCTAssertEqual(normal, [destination])
        XCTAssertEqual(activationCount, 0)
        backend.failApply = false
        opener.open(PullRequestOpenRequest(pullRequestURL: base))
        await waitUntil { normal.count == 2 }
        XCTAssertEqual(normal, [destination, base])
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(backend.applyCount, 2)
    }

    @MainActor
    func testEachClickResolvesSelectedBrowserAndChecksPermissionAgain() async {
        let backend = FakeBrowserBackend(windows: [Self.window(url: base)])
        let second = BrowserTarget(bundleIdentifier: "com.google.Chrome", processIdentifier: 456)
        var selected = target
        var activations = 0
        let opener = PullRequestBrowserOpener(
            resolveBrowser: { _ in selected }, backend: backend,
            yieldActivation: { _ in }, requestActivation: { _ in activations += 1; return true },
            openNormally: { _ in XCTFail("Unexpected fallback") }
        )
        opener.open(PullRequestOpenRequest(pullRequestURL: base))
        await waitUntil { activations == 1 }
        selected = second
        opener.open(PullRequestOpenRequest(pullRequestURL: base))
        await waitUntil { activations == 2 }
        XCTAssertEqual(backend.permissionTargets, [target, second])
        XCTAssertEqual(backend.windowTargets, [target, second])
        XCTAssertEqual(backend.applyTargets, [target, second])
    }

    private static func window(url: URL) -> BrowserWindowSnapshot {
        BrowserWindowSnapshot(
            locator: .safari(7), frontToBackIndex: 1, minimized: false, activeTabIndex: 1,
            tabs: [BrowserTabSnapshot(locator: .safari(index: 1), url: url)]
        )
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for browser opener completion")
    }
}

private final class FakeBrowserBackend: PullRequestBrowserBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [BrowserWindowSnapshot]
    private var permissionIndex = 0
    private var recordedPermissionTargets: [BrowserTarget] = []
    private var recordedWindowTargets: [BrowserTarget] = []
    private var recordedApplyTargets: [BrowserTarget] = []
    private var recordedRequests: [PullRequestOpenRequest] = []
    var permissions: [BrowserAutomationPermission] = [.approved]
    var permissionGate: DispatchSemaphore?
    var onPermissionStart: (() -> Void)?
    var failApply = false

    init(windows: [BrowserWindowSnapshot]) { snapshots = windows }

    var permissionCount: Int { lock.withLock { recordedPermissionTargets.count } }
    var windowCount: Int { lock.withLock { recordedWindowTargets.count } }
    var applyCount: Int { lock.withLock { recordedApplyTargets.count } }
    var permissionTargets: [BrowserTarget] { lock.withLock { recordedPermissionTargets } }
    var windowTargets: [BrowserTarget] { lock.withLock { recordedWindowTargets } }
    var applyTargets: [BrowserTarget] { lock.withLock { recordedApplyTargets } }
    var appliedRequests: [PullRequestOpenRequest] { lock.withLock { recordedRequests } }

    func permission(for target: BrowserTarget) throws -> BrowserAutomationPermission {
        let (result, index) = lock.withLock { () -> (BrowserAutomationPermission, Int) in
            recordedPermissionTargets.append(target)
            let index = permissionIndex
            permissionIndex += 1
            return (permissions[min(index, permissions.count - 1)], index)
        }
        if index == 0 {
            onPermissionStart?()
            permissionGate?.wait()
        }
        return result
    }

    func windows(for target: BrowserTarget) throws -> [BrowserWindowSnapshot] {
        lock.withLock { recordedWindowTargets.append(target) }
        return snapshots
    }

    func apply(_ request: PullRequestOpenRequest, to selection: BrowserTabSelection, in target: BrowserTarget) throws {
        let shouldFail = lock.withLock { () -> Bool in
            recordedApplyTargets.append(target)
            recordedRequests.append(request)
            return failApply
        }
        if shouldFail { throw FakeError.native }
    }

    private enum FakeError: Error { case native }
}
