@testable import VCDash

let vcDashLaunchConfigurationTest: Void = {
    precondition(
        LaunchConfiguration.current(
            arguments: ["VCDash", "--mock"],
            environment: [:]
        ) == LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true)
    )
    precondition(
        LaunchConfiguration.current(
            arguments: ["VCDash"],
            environment: ["VC_DASH_MOCK_MODE": "true"]
        ) == LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true)
    )
    precondition(
        LaunchConfiguration.current(
            arguments: ["VCDash", "--suppress-macos-notifications"],
            environment: [:]
        ) == LaunchConfiguration(usesMockData: false, suppressesMacOSNotifications: true)
    )
}()
