import Foundation
import ServiceManagement

@MainActor
protocol LaunchAtLoginServicing {
    var isEnabled: Bool { get }
    func setEnabled(_ isEnabled: Bool) throws
}

@MainActor
struct LaunchAtLoginService: LaunchAtLoginServicing {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
