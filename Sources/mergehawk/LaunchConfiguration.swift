import Foundation

struct LaunchConfiguration: Equatable {
    var usesMockData: Bool
    var suppressesMacOSNotifications: Bool
    var notificationLogPath: String? = nil

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

        return LaunchConfiguration(
            usesMockData: usesMockData,
            suppressesMacOSNotifications: suppressesMacOSNotifications,
            notificationLogPath: value(after: "--notification-log", in: arguments)
                ?? environment["MERGEHAWK_NOTIFICATION_LOG"]
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
}
