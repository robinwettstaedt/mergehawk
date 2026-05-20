@testable import mergehawk

let mergehawkLaunchConfigurationTest: Void = {
    precondition(
        LaunchConfiguration.current(
            arguments: ["mergehawk", "--mock"],
            environment: [:]
        ) == LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true)
    )
    precondition(
        LaunchConfiguration.current(
            arguments: ["mergehawk"],
            environment: ["MERGEHAWK_MOCK_MODE": "true"]
        ) == LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true)
    )
    precondition(
        LaunchConfiguration.current(
            arguments: ["mergehawk", "--suppress-macos-notifications"],
            environment: [:]
        ) == LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true)
    )
    precondition(
        LaunchConfiguration.current(
            arguments: ["mergehawk", "--mock", "--notification-type-fixtures"],
            environment: [:]
        ) == LaunchConfiguration(
            usesMockData: true,
            suppressesMacOSNotifications: true,
            showsNotificationTypeFixtures: true
        )
    )
}()
