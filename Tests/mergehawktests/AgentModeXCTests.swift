@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

final class AgentModeXCTests: XCTestCase {
    func testLaunchConfigurationAcceptsMockFlagAndEnvironment() {
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk", "--mock"],
                environment: [:]
            ),
            LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true)
        )
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk"],
                environment: ["MERGEHAWK_MOCK_MODE": "true"]
            ),
            LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true)
        )
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk", "--suppress-macos-notifications"],
                environment: [:]
            ),
            LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true)
        )
    }

    func testMockModeStartsSignedInWithoutToken() async {
        let notificationClient = RecordingNotificationClient()
        let controller = await MainActor.run {
            DashboardController(
                tokenStore: InMemoryTokenStore(),
                launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
                notificationClient: notificationClient,
                automaticRefreshInterval: 0
            )
        }

        await waitUntil(timeout: 1.0) {
            await MainActor.run {
                controller.state.syncedAt != nil
            }
        }

        await MainActor.run {
            XCTAssertEqual(controller.state.authStatus, .signedIn)
            XCTAssertEqual(controller.state.source, .mock)
            XCTAssertEqual(controller.state.account?.login, "agent-fixture")
            XCTAssertEqual(controller.state.pullRequests.map(\.id), ["PR_1", "PR_2"])
            XCTAssertFalse(controller.startsAtLogin)
        }

        await MainActor.run {
            controller.refresh()
        }
        await waitUntil(timeout: 1.0) {
            notificationClient.records.isEmpty == false
        }
        XCTAssertEqual(notificationClient.records.map(\.eventType), ["new_comment", "ci_failed"])
    }

    func testRecordingNotificationClientWritesJsonLines() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mergehawk-notifications-\(UUID().uuidString)")
        let logURL = directory.appendingPathComponent("notifications.jsonl")
        let client = RecordingNotificationClient(logPath: logURL.path)
        let pullRequest = PullRequest(
            id: "PR_1",
            title: "Make mock notifications testable",
            number: 42,
            url: URL(string: "https://github.com/example/mergehawk/pull/42")!,
            repo: "example/mergehawk",
            ciState: .failing,
            reviewDecision: .reviewRequired,
            commentCount: 3,
            reviewCount: 0,
            isMine: true,
            author: "agent",
            mergeable: .mergeable,
            draft: false
        )

        client.post(
            events: [PullRequestEvent(type: .ciFailed, prId: "PR_1")],
            pullRequests: [pullRequest]
        )

        let payload = try String(contentsOf: logURL)
        XCTAssertTrue(payload.contains(#""eventType":"ci_failed""#))
        XCTAssertTrue(payload.contains(#""repository":"example\/mergehawk""#))
    }

    private func waitUntil(timeout: TimeInterval, condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
