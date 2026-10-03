@testable import mergehawk
import mergehawkcore
import XCTest

final class LaunchConfigurationTests: XCTestCase {
    func testVerificationUIRequiresMockModeAndRecognizesOnlySupportedSurfaces() {
        for surface in ["settings", "menu"] {
            XCTAssertEqual(
                LaunchConfiguration.current(
                    arguments: ["mergehawk", "--verification-ui", surface],
                    environment: ["MERGEHAWK_MOCK_MODE": "1"]
                ).verificationUI?.rawValue,
                surface
            )
            XCTAssertNil(LaunchConfiguration.current(
                arguments: ["mergehawk", "--verification-ui", surface], environment: [:]
            ).verificationUI)
        }
        for arguments in [["mergehawk", "--mock"],
                          ["mergehawk", "--mock", "--verification-ui"],
                          ["mergehawk", "--mock", "--verification-ui", "unknown"]] {
            XCTAssertNil(LaunchConfiguration.current(arguments: arguments, environment: [:]).verificationUI)
        }
    }

    func testMockArgumentsAndEnvironmentEnableMockModeAndSuppressNotifications() {
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
    }

    func testNotificationOptionsAndPathRoundTrip() {
        let logPath = "/tmp/Verification Runs/notifications.jsonl"

        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: [
                    "mergehawk",
                    "--mock",
                    "--notification-type-fixtures",
                    "--notification-log",
                    logPath,
                ],
                environment: [:]
            ),
            LaunchConfiguration(
                usesMockData: true,
                suppressesMacOSNotifications: true,
                notificationLogPath: logPath,
                showsNotificationTypeFixtures: true
            )
        )
    }

    func testEnvironmentParsesPositiveDelayAndExplicitSuppression() {
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk", "--suppress-macos-notifications"],
                environment: ["MERGEHAWK_MOCK_REFRESH_DELAY_SECONDS": "3"]
            ),
            LaunchConfiguration(
                usesMockData: false,
                suppressesMacOSNotifications: true,
                mockRefreshDelaySeconds: 3
            )
        )
    }

    func testBotNotificationScenarioUsesExistingMockArgumentsAndEnvironment() {
        XCTAssertEqual(LaunchConfiguration.current(arguments: ["mergehawk", "--mock", "--mock-scenario", "bot-notifications"], environment: [:]).mockPullRequestScenario, .botNotifications)
        XCTAssertEqual(LaunchConfiguration.current(arguments: ["mergehawk"], environment: ["MERGEHAWK_MOCK_MODE": "1", "MERGEHAWK_MOCK_SCENARIO": "bot-notifications"]).mockPullRequestScenario, .botNotifications)
        XCTAssertEqual(LaunchConfiguration.current(arguments: ["mergehawk", "--mock-scenario", "bot-notifications"], environment: [:]).mockPullRequestScenario, .standard)
    }

    func testCommentNotificationScenarioUsesExistingMockArgumentsAndEnvironment() {
        XCTAssertEqual(LaunchConfiguration.current(arguments: ["mergehawk", "--mock", "--mock-scenario", "comment-notifications"], environment: [:]).mockPullRequestScenario, .commentNotifications)
        XCTAssertEqual(LaunchConfiguration.current(arguments: ["mergehawk"], environment: ["MERGEHAWK_MOCK_MODE": "1", "MERGEHAWK_MOCK_SCENARIO": "comment-notifications"]).mockPullRequestScenario, .commentNotifications)
        XCTAssertEqual(LaunchConfiguration.current(arguments: ["mergehawk", "--mock-scenario", "comment-notifications"], environment: [:]).mockPullRequestScenario, .standard)
    }

    func testLongListsScenarioParsesFromMockArguments() {
        XCTAssertEqual(LaunchConfiguration.current(arguments: ["mergehawk", "--mock", "--mock-scenario", "long-lists"], environment: [:]).mockPullRequestScenario, .longLists)
    }

    func testNewReviewRequestScenarioParsesFromMockArguments() {
        XCTAssertEqual(LaunchConfiguration.current(arguments: ["mergehawk", "--mock", "--mock-scenario", "new-review-request"], environment: [:]).mockPullRequestScenario, .newReviewRequest)
    }

    func testDraftReadyForReviewScenarioParsesFromMockArguments() {
        XCTAssertEqual(LaunchConfiguration.current(arguments: ["mergehawk", "--mock", "--mock-scenario", "draft-ready-for-review"], environment: [:]).mockPullRequestScenario, .draftReadyForReview)
    }

    func testRunAgentAppScriptAcceptsEveryMockScenario() throws {
        let script = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("scripts/run-agent-app.sh"),
            encoding: .utf8
        )
        let allowList = try XCTUnwrap(script.split(separator: "\n").first { $0.contains("standard|delayed-refresh") })
        for scenario in MockPullRequestScenario.allCases {
            XCTAssertTrue(allowList.contains(scenario.rawValue), scenario.rawValue)
        }
    }

    func testMockScenariosParseFromArgumentsAndEnvironment() {
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk", "--mock", "--mock-scenario", "merged-final-activity"],
                environment: [:]
            ).mockPullRequestScenario,
            .mergedFinalActivity
        )
        let delayed = LaunchConfiguration.current(
            arguments: ["mergehawk"],
            environment: [
                "MERGEHAWK_MOCK_MODE": "1",
                "MERGEHAWK_MOCK_SCENARIO": "delayed-refresh"
            ]
        )
        XCTAssertEqual(delayed.mockPullRequestScenario, .delayedRefresh)
        XCTAssertEqual(delayed.mockRefreshDelaySeconds, 3)
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk", "--mock", "--mock-scenario", "unknown"],
                environment: [:]
            ).mockPullRequestScenario,
            .standard
        )
        XCTAssertEqual(
            LaunchConfiguration.current(
                arguments: ["mergehawk", "--mock-scenario", "refresh-failure"],
                environment: [:]
            ).mockPullRequestScenario,
            .standard
        )
    }
}
