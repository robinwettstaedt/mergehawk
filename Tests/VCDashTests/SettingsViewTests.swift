@testable import VCDash
import CoreGraphics

let vcDashSettingsTabsTest: Void = {
    precondition(SettingsTab.allCases.map(\.title) == [
        "General",
        "GitHub",
        "Notifications",
        "Display",
        "About",
    ])
    precondition(SettingsTab.github.systemImage == "person.crop.circle.badge.checkmark")
    precondition(SettingsTab.notifications.systemImage == "bell")
    precondition(SettingsTab.defaultWindowSize == CGSize(width: 600, height: 520))
}()
