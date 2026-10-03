@testable import mergehawk
import AppKit
import SwiftUI
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

    func testActionsColumnIsExactlyTheActionButtonHitSize() {
        XCTAssertEqual(metrics.prColumns.actionsWidth, metrics.prColumns.actionButtonHitSize)
    }

    func testAvatarKeepsItsSize() {
        XCTAssertEqual(metrics.prColumns.avatarSize, 22)
    }

    func testActionsMenuHeightFollowsItsItemsAndKeepsItsSize() {
        // No capture opens the PR actions menu, so its derived height is checked here.
        XCTAssertEqual(metrics.actionsMenu.height, 94)
    }

    // MARK: Scaling

    private let factors = MenuSize.allCases.map(\.factor)

    func testEveryStoredMeasurementScalesByTheFactor() {
        let base = Self.storedMeasurements(in: metrics)
        XCTAssertTrue(base.unexpectedLeaves.isEmpty, "Unscaled stored values: \(base.unexpectedLeaves)")
        // Spot-check that the walk reaches every kind of stored token.
        let basePaths = Set(base.values.map(\.path))
        for path in [".panel.width", ".prColumns.avatarSize", ".type.cardTitle.size", ".footer.itemFont.size", ".legend.mergeStatusStrokeWidth"] {
            XCTAssertTrue(basePaths.contains(path), path)
        }
        for factor in factors {
            let scaled = MenuMetrics(scale: factor)
            XCTAssertEqual(scaled.scale, factor)
            let scaledValues = Self.storedMeasurements(in: scaled).values
            XCTAssertEqual(scaledValues.map(\.path), base.values.map(\.path))
            for (scaledValue, baseValue) in zip(scaledValues, base.values) {
                XCTAssertEqual(scaledValue.value, baseValue.value * factor, "\(baseValue.path) at \(factor)")
            }
            XCTAssertEqual(MenuMetrics.hairline, 1)
            XCTAssertEqual(scaled.footer.separatorHeight - 2 * scaled.footer.separatorVerticalPadding, 1, accuracy: 1e-9)
        }
    }

    func testDerivedMeasurementsFollowTheirScaledParts() {
        for factor in factors {
            let scaled = MenuMetrics(scale: factor)
            let footer = scaled.footer
            XCTAssertEqual(footer.separatorHeight, 1 + 2 * footer.separatorVerticalPadding, "at \(factor)")
            XCTAssertEqual(
                footer.height,
                footer.separatorHeight + 4 * footer.rowHeight + footer.bottomPadding,
                "at \(factor)"
            )
            XCTAssertEqual(footer.bottomPadding, footer.separatorVerticalPadding, "at \(factor)")
            XCTAssertEqual(scaled.panelHeight, scaled.panel.contentHeight + footer.height, "at \(factor)")
            XCTAssertEqual(scaled.panelSize, CGSize(width: scaled.panel.width, height: scaled.panelHeight))
            let switcher = scaled.tabSwitcher
            XCTAssertEqual(
                switcher.textSegmentWidth * 2 + switcher.notificationSegmentWidth,
                switcher.width,
                accuracy: 1e-9,
                "at \(factor)"
            )
            XCTAssertEqual(scaled.prColumns.actionsWidth, scaled.prColumns.actionButtonHitSize, "at \(factor)")
        }
    }

    func testFooterHairlineIsNotScaledAtLarger() {
        let larger = MenuMetrics(scale: MenuSize.larger.factor)
        XCTAssertEqual(larger.footer.height, 1 + (metrics.footer.height - 1) * 1.3, accuracy: 1e-9)
    }

    func testFontTokensScaleTheirSizeAndKeepTheirConstruction() {
        let baseTokens = Self.fontTokens(in: metrics)
        XCTAssertFalse(baseTokens.isEmpty)
        for factor in factors {
            let scaledTokens = Self.fontTokens(in: MenuMetrics(scale: factor))
            XCTAssertEqual(scaledTokens.map(\.path), baseTokens.map(\.path))
            for (scaled, base) in zip(scaledTokens, baseTokens) {
                let token = scaled.token
                let label = "\(base.path) at \(factor)"
                XCTAssertEqual(token.size, base.token.size * factor, label)
                XCTAssertEqual(token.weight, base.token.weight, label)
                XCTAssertEqual(token.design, base.token.design, label)
                XCTAssertEqual(token.monospacedDigits, base.token.monospacedDigits, label)
                let expectedFont = Font.system(size: base.token.size * factor, weight: base.token.weight, design: base.token.design)
                XCTAssertEqual(token.font, base.token.monospacedDigits ? expectedFont.monospacedDigit() : expectedFont, label)
            }
            XCTAssertEqual(MenuMetrics(scale: factor).footer.itemFont.size, NSFont.menuFont(ofSize: 0).pointSize * factor)
        }
    }

    // MARK: Mirror walk

    private struct StoredMeasurements {
        var values: [(path: String, value: CGFloat)] = []
        /// Stored leaves that are neither a CGFloat nor a font token, so the walk could not check them.
        var unexpectedLeaves: [String] = []
    }

    /// Every stored CGFloat and font token size, in declaration order. `scale` itself is skipped.
    private static func storedMeasurements(in metrics: MenuMetrics) -> StoredMeasurements {
        var result = StoredMeasurements()
        func walk(_ value: Any, path: String) {
            if let number = value as? CGFloat {
                result.values.append((path, number))
            } else if let token = value as? MenuMetrics.FontToken {
                result.values.append((path + ".size", token.size))
            } else if let token = value as? MenuMetrics.NativeMenuFontToken {
                result.values.append((path + ".size", token.size))
            } else {
                let children = Mirror(reflecting: value).children
                if children.isEmpty {
                    result.unexpectedLeaves.append(path)
                }
                for child in children {
                    walk(child.value, path: path + "." + (child.label ?? "?"))
                }
            }
        }
        for child in Mirror(reflecting: metrics).children where child.label != "scale" {
            walk(child.value, path: "." + (child.label ?? "?"))
        }
        return result
    }

    private static func fontTokens(in metrics: MenuMetrics) -> [(path: String, token: MenuMetrics.FontToken)] {
        var tokens: [(path: String, token: MenuMetrics.FontToken)] = []
        func walk(_ value: Any, path: String) {
            if let token = value as? MenuMetrics.FontToken {
                tokens.append((path, token))
                return
            }
            for child in Mirror(reflecting: value).children {
                walk(child.value, path: path + "." + (child.label ?? "?"))
            }
        }
        walk(metrics, path: "")
        return tokens
    }
}
