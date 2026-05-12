@testable import mergehawk
import CoreGraphics

let mergehawkSettingsTabsTest: Void = {
    precondition(SettingsTab.allCases.map(\.title) == [
        "General",
        "GitHub",
        "Notifications",
        "About",
    ])
    precondition(SettingsTab.github.systemImage == "person.crop.circle.badge.checkmark")
    precondition(SettingsTab.notifications.systemImage == "bell")
    precondition(SettingsTab.defaultWindowSize == CGSize(width: 460, height: 560))
    precondition(SettingsTabLayout.topPadding == 8)
    precondition(SettingsTabLayout.titleSize == 14)
    precondition(SettingsTabLayout.iconSize == 18)
    precondition(SettingsTabLayout.labelSize == 11)
}()
