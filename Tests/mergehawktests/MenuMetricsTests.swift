@testable import mergehawk
import AppKit
import XCTest

final class MenuMetricsTests: XCTestCase {
    private let metrics = MenuMetrics.standard

    func testStandardPanelKeepsItsCurrentSize() {
        XCTAssertEqual(metrics.panel.width, 820)
        XCTAssertEqual(metrics.panel.contentHeight, 650)
        XCTAssertEqual(metrics.footer.height, 115)
        XCTAssertEqual(metrics.panelHeight, 765)
        XCTAssertEqual(metrics.panelSize, CGSize(width: 820, height: 765))
    }

    func testTabSwitcherSegmentsFillTheSwitcherWidth() {
        let switcher = metrics.tabSwitcher
        XCTAssertEqual(switcher.width, 320)
        XCTAssertEqual(switcher.textSegmentWidth * 2 + switcher.notificationSegmentWidth, 320)
    }

    func testFooterHeightFollowsItsSeparatorRowsAndBottomPadding() {
        let footer = metrics.footer
        XCTAssertEqual(footer.separatorHeight, 13)
        XCTAssertEqual(footer.separatorHeight, 1 + 2 * footer.separatorVerticalPadding)
        XCTAssertEqual(footer.height, footer.separatorHeight + 4 * footer.rowHeight + footer.bottomPadding)
        XCTAssertEqual(footer.bottomPadding, footer.separatorVerticalPadding)
    }

    func testFooterUsesTheSystemMenuFontSize() {
        XCTAssertEqual(metrics.footer.itemFont.size, NSFont.menuFont(ofSize: 0).pointSize)
    }

    func testFooterSeparatorLineStaysOnePoint() {
        XCTAssertEqual(MenuMetrics.hairline, 1)
    }
}
