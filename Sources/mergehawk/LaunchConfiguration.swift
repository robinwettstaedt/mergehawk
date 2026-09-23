import Foundation
import mergehawkcore

struct LaunchConfiguration: Equatable {
    enum VerificationUI: String {
        case settings
        case menu
    }

    var usesMockData: Bool
    var suppressesMacOSNotifications: Bool
    var notificationLogPath: String? = nil
    var showsNotificationTypeFixtures: Bool = false
    var mockRefreshDelaySeconds: TimeInterval = 0
    var mockPullRequestScenario: MockPullRequestScenario = .standard
    var verificationUI: VerificationUI? = nil

    static func current(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchConfiguration {
        let usesMockData = arguments.contains("--mock")
            || truthy(environment["MERGEHAWK_MOCK_MODE"])
            || truthy(environment["MERGEHAWK_USE_MOCKS"])
        let suppressesMacOSNotifications = arguments.contains("--disable-notifications")
            || arguments.contains("--suppress-macos-notifications")
            || truthy(environment["MERGEHAWK_DISABLE_NOTIFICATIONS"])
            || truthy(environment["MERGEHAWK_SUPPRESS_MACOS_NOTIFICATIONS"])
            || usesMockData
        let showsNotificationTypeFixtures = arguments.contains("--notification-type-fixtures")
            || truthy(environment["MERGEHAWK_NOTIFICATION_TYPE_FIXTURES"])
        let mockScenario = usesMockData
            ? (value(after: "--mock-scenario", in: arguments)
                ?? environment["MERGEHAWK_MOCK_SCENARIO"])
                .flatMap(MockPullRequestScenario.init(rawValue:)) ?? .standard
            : .standard
        let configuredDelay = positiveTimeInterval(environment["MERGEHAWK_MOCK_REFRESH_DELAY_SECONDS"])

        return LaunchConfiguration(
            usesMockData: usesMockData,
            suppressesMacOSNotifications: suppressesMacOSNotifications,
            notificationLogPath: value(after: "--notification-log", in: arguments)
                ?? environment["MERGEHAWK_NOTIFICATION_LOG"],
            showsNotificationTypeFixtures: showsNotificationTypeFixtures,
            mockRefreshDelaySeconds: configuredDelay
                ?? (mockScenario == .delayedRefresh ? 3 : 0),
            mockPullRequestScenario: mockScenario,
            verificationUI: usesMockData
                ? value(after: "--verification-ui", in: arguments).flatMap(VerificationUI.init(rawValue:))
                : nil
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }
        return arguments[valueIndex]
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let value else {
            return false
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func positiveTimeInterval(_ value: String?) -> TimeInterval? {
        guard let value,
              let interval = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              interval > 0 else {
            return nil
        }
        return interval
    }
}
