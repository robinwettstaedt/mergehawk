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

    // MARK: Consolidated scales

    private typealias SizeToken = (name: String, keyPath: KeyPath<MenuMetrics, CGFloat>, mer86Value: CGFloat)

    private static let spacingScale: Set<CGFloat> = [0, 2, 4, 6, 8, 12, 16, 20, 24]

    /// Spacing kept off the scale on purpose: the footer imitates native menu rows, and the divider
    /// insets set divider length rather than spacing.
    private static let spacingOneOffs: Set<String> = [
        "footer.selectionInsetX", "footer.selectionInsetY", "footer.titleLeading", "footer.shortcutTrailing",
        "footer.separatorHorizontalPadding",
        "controls.sortDividerVerticalInset", "controls.segmentDividerVerticalInset",
    ]

    /// Every spacing and padding token with its value before the scales were consolidated (MER-86).
    private static let spacingTokens: [SizeToken] = [
        ("topBar.leadingInset", \.topBar.leadingInset, 8),
        ("topBar.trailingInset", \.topBar.trailingInset, 12),
        ("topBar.headerControlsTrailingSpacing", \.topBar.headerControlsTrailingSpacing, 8),
        ("tabSwitcher.leadingInset", \.tabSwitcher.leadingInset, 5),
        ("controls.contentSpacing", \.controls.contentSpacing, 6),
        ("controls.horizontalPadding", \.controls.horizontalPadding, 10),
        ("controls.sortDividerVerticalInset", \.controls.sortDividerVerticalInset, 5),
        ("controls.segmentedContentSpacing", \.controls.segmentedContentSpacing, 5),
        ("controls.segmentSelectionInset", \.controls.segmentSelectionInset, 2),
        ("controls.segmentDividerVerticalInset", \.controls.segmentDividerVerticalInset, 7),
        ("prColumns.spacing", \.prColumns.spacing, 6),
        ("prColumns.rowSpacing", \.prColumns.rowSpacing, 7),
        ("prColumns.horizontalInset", \.prColumns.horizontalInset, 10),
        ("prColumns.verticalInset", \.prColumns.verticalInset, 8),
        ("prColumns.identitySpacing", \.prColumns.identitySpacing, 7),
        ("prColumns.identityLineSpacing", \.prColumns.identityLineSpacing, 4),
        ("refreshStatus.verticalSpacing", \.refreshStatus.verticalSpacing, 3),
        ("refreshStatus.indicatorSpacing", \.refreshStatus.indicatorSpacing, 7),
        ("refreshStatus.horizontalSpacing", \.refreshStatus.horizontalSpacing, 5),
        ("refreshStatus.horizontalPadding", \.refreshStatus.horizontalPadding, 3),
        ("banner.spacing", \.banner.spacing, 8),
        ("banner.horizontalPadding", \.banner.horizontalPadding, 12),
        ("banner.verticalPadding", \.banner.verticalPadding, 8),
        ("prList.horizontalPadding", \.prList.horizontalPadding, 12),
        ("prList.topPadding", \.prList.topPadding, 5),
        ("prList.bottomPadding", \.prList.bottomPadding, 12),
        ("prList.sectionSpacing", \.prList.sectionSpacing, 20),
        ("prList.disclosureSpacing", \.prList.disclosureSpacing, 7),
        ("prList.disclosureHorizontalPadding", \.prList.disclosureHorizontalPadding, 10),
        ("prList.sectionHeadingSpacing", \.prList.sectionHeadingSpacing, 8),
        ("prList.sectionCountHorizontalPadding", \.prList.sectionCountHorizontalPadding, 6),
        ("prList.sectionCountVerticalPadding", \.prList.sectionCountVerticalPadding, 2),
        ("dropdown.headerControlsSpacing", \.dropdown.headerControlsSpacing, 8),
        ("dropdown.gap", \.dropdown.gap, 10),
        ("dropdown.itemSpacing", \.dropdown.itemSpacing, 2),
        ("dropdown.verticalPadding", \.dropdown.verticalPadding, 6),
        ("dropdown.itemContentSpacing", \.dropdown.itemContentSpacing, 8),
        ("dropdown.itemHorizontalPadding", \.dropdown.itemHorizontalPadding, 8),
        ("notificationList.headerSpacing", \.notificationList.headerSpacing, 8),
        ("notificationList.headerHorizontalPadding", \.notificationList.headerHorizontalPadding, 12),
        ("notificationList.headerTopPadding", \.notificationList.headerTopPadding, 10),
        ("notificationList.headerBottomPadding", \.notificationList.headerBottomPadding, 6),
        ("notificationList.rowSpacing", \.notificationList.rowSpacing, 8),
        ("notificationList.horizontalPadding", \.notificationList.horizontalPadding, 12),
        ("notificationList.topPadding", \.notificationList.topPadding, 5),
        ("notificationList.bottomPadding", \.notificationList.bottomPadding, 12),
        ("notificationRow.titleSpacing", \.notificationRow.titleSpacing, 8),
        ("notificationRow.pullRequestLineSpacing", \.notificationRow.pullRequestLineSpacing, 4),
        ("notificationRow.markReadOffset", \.notificationRow.markReadOffset, 6),
        ("prRow.identityItemSpacing", \.prRow.identityItemSpacing, 4),
        ("prRow.draftBadgeHorizontalPadding", \.prRow.draftBadgeHorizontalPadding, 6),
        ("prRow.draftBadgeVerticalPadding", \.prRow.draftBadgeVerticalPadding, 2),
        ("tooltip.horizontalPadding", \.tooltip.horizontalPadding, 8),
        ("tooltip.verticalPadding", \.tooltip.verticalPadding, 5),
        ("tooltip.gap", \.tooltip.gap, 4),
        ("actionsMenu.padding", \.actionsMenu.padding, 6),
        ("actionsMenu.itemSpacing", \.actionsMenu.itemSpacing, 2),
        ("actionsMenu.itemContentSpacing", \.actionsMenu.itemContentSpacing, 8),
        ("actionsMenu.itemHorizontalPadding", \.actionsMenu.itemHorizontalPadding, 6),
        ("actionsMenu.anchorGap", \.actionsMenu.anchorGap, 4),
        ("gitHubButton.contentSpacing", \.gitHubButton.contentSpacing, 6),
        ("gitHubButton.horizontalPadding", \.gitHubButton.horizontalPadding, 16),
        ("signIn.padding", \.signIn.padding, 24),
        ("signIn.contentSpacing", \.signIn.contentSpacing, 20),
        ("signIn.buttonRowSpacing", \.signIn.buttonRowSpacing, 8),
        ("signIn.pendingSpacing", \.signIn.pendingSpacing, 14),
        ("signIn.enterCodeSpacing", \.signIn.enterCodeSpacing, 16),
        ("signIn.linkSpacing", \.signIn.linkSpacing, 3),
        ("signIn.codeRowSpacing", \.signIn.codeRowSpacing, 8),
        ("signIn.codeHorizontalPadding", \.signIn.codeHorizontalPadding, 12),
        ("signIn.codeVerticalPadding", \.signIn.codeVerticalPadding, 10),
        ("signIn.expirySpacing", \.signIn.expirySpacing, 5),
        ("signIn.loadingSpacing", \.signIn.loadingSpacing, 10),
        ("emptyState.spacing", \.emptyState.spacing, 8),
        ("accessPrompt.contentSpacing", \.accessPrompt.contentSpacing, 20),
        ("accessPrompt.headerSpacing", \.accessPrompt.headerSpacing, 10),
        ("accessPrompt.actionsSpacing", \.accessPrompt.actionsSpacing, 12),
        ("accessPrompt.horizontalPadding", \.accessPrompt.horizontalPadding, 24),
        ("accessPrompt.noteSpacing", \.accessPrompt.noteSpacing, 10),
        ("accessPrompt.noteHorizontalPadding", \.accessPrompt.noteHorizontalPadding, 12),
        ("accessPrompt.noteVerticalPadding", \.accessPrompt.noteVerticalPadding, 10),
        ("footer.separatorHorizontalPadding", \.footer.separatorHorizontalPadding, 10),
        ("footer.separatorVerticalPadding", \.footer.separatorVerticalPadding, 6),
        ("footer.selectionInsetX", \.footer.selectionInsetX, 5),
        ("footer.selectionInsetY", \.footer.selectionInsetY, 1),
        ("footer.titleLeading", \.footer.titleLeading, 14),
        ("footer.shortcutTrailing", \.footer.shortcutTrailing, 9),
        ("footer.shortcutColumnSpacing", \.footer.shortcutColumnSpacing, 2),
    ]

    func testSpacingIsOnTheScaleOrADocumentedOneOff() {
        XCTAssertEqual(Self.spacingTokens.count, 88)
        for token in Self.spacingTokens {
            let value = metrics[keyPath: token.keyPath]
            if Self.spacingOneOffs.contains(token.name) {
                XCTAssertEqual(value, token.mer86Value, "one-off \(token.name) keeps its value")
            } else {
                XCTAssertTrue(Self.spacingScale.contains(value), "\(token.name) = \(value) is off the spacing scale")
            }
        }
    }

    func testSpacingMovedAtMostTwoPoints() {
        for token in Self.spacingTokens {
            XCTAssertLessThanOrEqual(abs(metrics[keyPath: token.keyPath] - token.mer86Value), 2, token.name)
        }
    }

    private static let cornerRadiusScale: Set<CGFloat> = [4, 6, 8]

    /// The footer selection keeps the native menu's radius.
    private static let cornerRadiusOneOffs: Set<String> = ["footer.selectionCornerRadius"]

    /// Every corner radius token with its value before the scales were consolidated (MER-86).
    private static let cornerRadiusTokens: [SizeToken] = [
        ("controls.cornerRadius", \.controls.cornerRadius, 6),
        ("controls.segmentedCornerRadius", \.controls.segmentedCornerRadius, 6),
        ("controls.segmentSelectionCornerRadius", \.controls.segmentSelectionCornerRadius, 5),
        ("refreshStatus.cornerRadius", \.refreshStatus.cornerRadius, 6),
        ("dropdown.cornerRadius", \.dropdown.cornerRadius, 7),
        ("card.cornerRadius", \.card.cornerRadius, 8),
        ("tooltip.cornerRadius", \.tooltip.cornerRadius, 6),
        ("actionsMenu.itemCornerRadius", \.actionsMenu.itemCornerRadius, 4),
        ("actionsMenu.cornerRadius", \.actionsMenu.cornerRadius, 7),
        ("gitHubButton.cornerRadius", \.gitHubButton.cornerRadius, 7),
        ("signIn.codeCornerRadius", \.signIn.codeCornerRadius, 8),
        ("accessPrompt.noteBoxCornerRadius", \.accessPrompt.noteBoxCornerRadius, 8),
        ("footer.selectionCornerRadius", \.footer.selectionCornerRadius, 5),
    ]

    func testCornerRadiiAreOnTheScaleOrADocumentedOneOff() {
        XCTAssertEqual(Self.cornerRadiusTokens.count, 13)
        for token in Self.cornerRadiusTokens {
            let value = metrics[keyPath: token.keyPath]
            if Self.cornerRadiusOneOffs.contains(token.name) {
                XCTAssertEqual(value, token.mer86Value, "one-off \(token.name) keeps its value")
            } else {
                XCTAssertTrue(Self.cornerRadiusScale.contains(value), "\(token.name) = \(value) is not 4, 6 or 8")
            }
        }
    }

    func testCornerRadiiMovedAtMostTwoPoints() {
        for token in Self.cornerRadiusTokens {
            XCTAssertLessThanOrEqual(abs(metrics[keyPath: token.keyPath] - token.mer86Value), 2, token.name)
        }
    }

    private struct FontExpectation {
        var name: String
        var keyPath: KeyPath<MenuMetrics, MenuMetrics.FontToken>
        var mer86Size: CGFloat
        var size: CGFloat
        var weight: Font.Weight = .regular
        var design: Font.Design = .default
        var monospacedDigits = false
    }

    /// Every font token: its size before the scales were consolidated (MER-86), its approved size,
    /// and its unchanged weight and design. The footer's native menu font is not listed: it comes from `NSFont.menuFont`.
    private static let fontExpectations: [FontExpectation] = [
        .init(name: "panelTitle", keyPath: \.type.panelTitle, mer86Size: 13, size: 13, weight: .bold),
        .init(name: "controlLabel", keyPath: \.type.controlLabel, mer86Size: 11, size: 11, weight: .semibold),
        .init(name: "controlChevron", keyPath: \.type.controlChevron, mer86Size: 9, size: 10, weight: .semibold),
        .init(name: "segmentLabel", keyPath: \.type.segmentLabel, mer86Size: 13, size: 13, weight: .medium),
        .init(name: "segmentIcon", keyPath: \.type.segmentIcon, mer86Size: 12, size: 11, weight: .semibold),
        .init(name: "refreshSymbol", keyPath: \.type.refreshSymbol, mer86Size: 13, size: 13, weight: .semibold),
        .init(name: "refreshTimestamp", keyPath: \.type.refreshTimestamp, mer86Size: 10, size: 10, weight: .medium),
        .init(name: "bannerMessage", keyPath: \.type.bannerMessage, mer86Size: 12, size: 11),
        .init(name: "bannerSymbol", keyPath: \.type.bannerSymbol, mer86Size: 13, size: 13),
        .init(name: "disclosureChevron", keyPath: \.type.disclosureChevron, mer86Size: 9, size: 10, weight: .semibold),
        .init(name: "disclosureTitle", keyPath: \.type.disclosureTitle, mer86Size: 10, size: 10, weight: .semibold),
        .init(name: "dropdownItem", keyPath: \.type.dropdownItem, mer86Size: 11, size: 11, weight: .semibold),
        .init(name: "dropdownCheckmark", keyPath: \.type.dropdownCheckmark, mer86Size: 11, size: 11, weight: .semibold),
        .init(name: "sectionChevron", keyPath: \.type.sectionChevron, mer86Size: 12, size: 11, weight: .semibold),
        .init(name: "sectionHeading", keyPath: \.type.sectionHeading, mer86Size: 13, size: 13, weight: .semibold),
        .init(name: "sectionCount", keyPath: \.type.sectionCount, mer86Size: 10, size: 10, weight: .semibold, monospacedDigits: true),
        .init(name: "cardTitle", keyPath: \.type.cardTitle, mer86Size: 11, size: 11, weight: .semibold),
        .init(name: "cardMetadata", keyPath: \.type.cardMetadata, mer86Size: 10, size: 10, weight: .medium),
        .init(name: "notificationIcon", keyPath: \.type.notificationIcon, mer86Size: 17, size: 17, weight: .medium),
        .init(name: "notificationTimestamp", keyPath: \.type.notificationTimestamp, mer86Size: 10, size: 10, weight: .semibold, monospacedDigits: true),
        .init(name: "markReadSymbol", keyPath: \.type.markReadSymbol, mer86Size: 9, size: 10, weight: .medium),
        .init(name: "legendLabel", keyPath: \.type.legendLabel, mer86Size: 10, size: 10, weight: .semibold),
        .init(name: "legendIcon", keyPath: \.type.legendIcon, mer86Size: 13, size: 13, weight: .semibold),
        .init(name: "tooltip", keyPath: \.type.tooltip, mer86Size: 10, size: 10, weight: .medium),
        .init(name: "actionsSymbol", keyPath: \.type.actionsSymbol, mer86Size: 12, size: 11, weight: .semibold),
        .init(name: "ageValue", keyPath: \.type.ageValue, mer86Size: 10, size: 10, weight: .medium, monospacedDigits: true),
        .init(name: "metricValue", keyPath: \.type.metricValue, mer86Size: 10, size: 10, weight: .semibold, monospacedDigits: true),
        .init(name: "signalSymbol", keyPath: \.type.signalSymbol, mer86Size: 12, size: 11, weight: .semibold),
        .init(name: "draftBadge", keyPath: \.type.draftBadge, mer86Size: 9, size: 10, weight: .semibold),
        .init(name: "actionsMenuItem", keyPath: \.type.actionsMenuItem, mer86Size: 12, size: 11),
        .init(name: "gitHubButtonTitle", keyPath: \.type.gitHubButtonTitle, mer86Size: 13, size: 13, weight: .semibold),
        .init(name: "signInTitle", keyPath: \.type.signInTitle, mer86Size: 13, size: 13, weight: .bold),
        .init(name: "signInDetail", keyPath: \.type.signInDetail, mer86Size: 11, size: 11),
        .init(name: "signInLink", keyPath: \.type.signInLink, mer86Size: 11, size: 11),
        .init(name: "signInLinkArrow", keyPath: \.type.signInLinkArrow, mer86Size: 10, size: 10, weight: .bold),
        .init(name: "signInError", keyPath: \.type.signInError, mer86Size: 10, size: 10),
        .init(name: "deviceCode", keyPath: \.type.deviceCode, mer86Size: 17, size: 17, weight: .semibold, design: .monospaced),
        .init(name: "copySymbol", keyPath: \.type.copySymbol, mer86Size: 13, size: 13, weight: .medium),
        .init(name: "expirySymbol", keyPath: \.type.expirySymbol, mer86Size: 11, size: 11),
        .init(name: "expiry", keyPath: \.type.expiry, mer86Size: 10, size: 10),
        .init(name: "emptyStateIcon", keyPath: \.type.emptyStateIcon, mer86Size: 17, size: 17),
        .init(name: "emptyStateText", keyPath: \.type.emptyStateText, mer86Size: 11, size: 11),
        .init(name: "accessPromptIcon", keyPath: \.type.accessPromptIcon, mer86Size: 34, size: 34, weight: .light),
        .init(name: "accessPromptTitle", keyPath: \.type.accessPromptTitle, mer86Size: 13, size: 13, weight: .bold),
        .init(name: "accessPromptNoteIcon", keyPath: \.type.accessPromptNoteIcon, mer86Size: 13, size: 13),
        .init(name: "accessPromptNote", keyPath: \.type.accessPromptNote, mer86Size: 12, size: 11),
    ]

    func testFontSizesFollowTheApprovedTypeScale() {
        XCTAssertEqual(Self.fontExpectations.count, Self.fontTokens(in: metrics).count)
        for expected in Self.fontExpectations {
            XCTAssertEqual(metrics[keyPath: expected.keyPath].size, expected.size, expected.name)
        }
    }

    func testFontWeightAndDesignAreUnchanged() {
        for expected in Self.fontExpectations {
            let token = metrics[keyPath: expected.keyPath]
            XCTAssertEqual(token.weight, expected.weight, expected.name)
            XCTAssertEqual(token.design, expected.design, expected.name)
            XCTAssertEqual(token.monospacedDigits, expected.monospacedDigits, expected.name)
        }
    }

    func testFontSizesMovedAtMostTwoPoints() {
        for expected in Self.fontExpectations {
            XCTAssertLessThanOrEqual(abs(metrics[keyPath: expected.keyPath].size - expected.mer86Size), 2, expected.name)
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
