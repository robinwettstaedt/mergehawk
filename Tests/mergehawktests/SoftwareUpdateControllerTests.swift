@testable import mergehawk
import XCTest

@MainActor
final class SoftwareUpdateControllerTests: XCTestCase {
    func testDisabledUpdaterIsUnavailable() {
        let controller = SoftwareUpdateController.disabled()

        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
    }

    func testTestingUpdaterRunsManualChecks() {
        var manualCheckCount = 0
        let controller = SoftwareUpdateController.testing {
            manualCheckCount += 1
        }

        XCTAssertTrue(controller.isAvailable)
        XCTAssertTrue(controller.canCheckForUpdates)
        XCTAssertTrue(controller.automaticallyChecksForUpdates)

        controller.checkForUpdates()

        XCTAssertEqual(manualCheckCount, 1)
    }

    func testTestingUpdaterStoresAutomaticCheckPreference() {
        let controller = SoftwareUpdateController.testing(automaticallyChecksForUpdates: false)

        XCTAssertFalse(controller.automaticallyChecksForUpdates)

        controller.automaticallyChecksForUpdates = true

        XCTAssertTrue(controller.automaticallyChecksForUpdates)
    }

    func testDistributionDefaultsToDevelopment() {
        XCTAssertEqual(SoftwareUpdateDistribution(bundle: .main), .development)
    }
}
