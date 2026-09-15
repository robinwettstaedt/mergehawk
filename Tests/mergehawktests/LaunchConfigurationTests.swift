@testable import mergehawk
import XCTest

final class LaunchConfigurationTests: XCTestCase {
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
}
