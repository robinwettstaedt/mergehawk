@testable import mergehawk
import CoreGraphics

let mergehawkSettingsTabsTest: Void = {
    precondition(SettingsTab.allCases.map(\.title) == [
        "General",
        "GitHub",
        "Notifications",
        "Sources",
    ])
    precondition(SettingsTab.github.systemImage == "person.crop.circle.badge.checkmark")
    precondition(SettingsTab.notifications.systemImage == "bell")
    precondition(SettingsTab.sources.systemImage == "tray.full")
    precondition(SettingsTab.defaultWindowSize == CGSize(width: 560, height: 580))
    precondition(SettingsTabLayout.topPadding == 8)
    precondition(SettingsTabLayout.titleSize == 14)
    precondition(SettingsTabLayout.iconSize == 18)
    precondition(SettingsTabLayout.labelSize == 11)
}()
