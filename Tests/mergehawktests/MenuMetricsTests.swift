@testable import mergehawk
import AppKit
import XCTest

final class MenuMetricsTests: XCTestCase {
    private let metrics = MenuMetrics.standard

    func testStandardPanelKeepsItsCurrentSize() {
        XCTAssertEqual(metrics.panel.width, 820)
        XCTAssertEqual(metrics.panel.contentHeight, 650)
        XCTAssertEqual(metrics.footerHeight, 115)
        XCTAssertEqual(metrics.panelHeight, 765)
        XCTAssertEqual(metrics.panelSize, CGSize(width: 820, height: 765))
    }

    func testTabSwitcherSegmentsFillTheSwitcherWidth() {
        let switcher = metrics.tabSwitcher
        XCTAssertEqual(switcher.width, 320)
        XCTAssertEqual(switcher.textSegmentWidth * 2 + switcher.notificationSegmentWidth, 320)
    }
}
