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

    func testEveryBaseMeasurementScalesByTheFactor() {
        for factor in factors {
            let scaled = MenuMetrics(scale: factor)
            XCTAssertEqual(scaled.scale, factor)
            for keyPath in Self.baseMeasurements {
                XCTAssertEqual(
                    scaled[keyPath: keyPath],
                    metrics[keyPath: keyPath] * factor,
                    "\(keyPath) at \(factor)"
                )
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
        for factor in factors {
            let scaled = MenuMetrics(scale: factor)
            for keyPath in Self.fontTokens {
                let base = metrics[keyPath: keyPath]
                let token = scaled[keyPath: keyPath]
                XCTAssertEqual(token.size, base.size * factor, "\(keyPath) at \(factor)")
                XCTAssertEqual(token.weight, base.weight, "\(keyPath) at \(factor)")
                XCTAssertEqual(token.design, base.design, "\(keyPath) at \(factor)")
                XCTAssertEqual(token.monospacedDigits, base.monospacedDigits, "\(keyPath) at \(factor)")
                XCTAssertEqual(
                    token.font,
                    base.monospacedDigits
                        ? Font.system(size: base.size * factor, weight: base.weight, design: base.design).monospacedDigit()
                        : Font.system(size: base.size * factor, weight: base.weight, design: base.design),
                    "\(keyPath) at \(factor)"
                )
            }
            XCTAssertEqual(scaled.footer.itemFont.size, NSFont.menuFont(ofSize: 0).pointSize * factor)
        }
    }

    /// Every stored base measurement, group by group. Derived (computed) measurements are not listed.
    private static let baseMeasurements: [KeyPath<MenuMetrics, CGFloat>] = [
        \.type.panelTitle.size,
        \.type.controlLabel.size,
        \.type.controlChevron.size,
        \.type.segmentLabel.size,
        \.type.segmentIcon.size,
        \.type.refreshSymbol.size,
        \.type.refreshTimestamp.size,
        \.type.bannerMessage.size,
        \.type.bannerSymbol.size,
        \.type.disclosureChevron.size,
        \.type.disclosureTitle.size,
        \.type.dropdownItem.size,
        \.type.dropdownCheckmark.size,
        \.type.sectionChevron.size,
        \.type.sectionHeading.size,
        \.type.sectionCount.size,
        \.type.cardTitle.size,
        \.type.cardMetadata.size,
        \.type.notificationIcon.size,
        \.type.notificationTimestamp.size,
        \.type.markReadSymbol.size,
        \.type.legendLabel.size,
        \.type.legendIcon.size,
        \.type.legendTooltip.size,
        \.type.actionsSymbol.size,
        \.type.ageValue.size,
        \.type.metricValue.size,
        \.type.signalSymbol.size,
        \.type.draftBadge.size,
        \.type.actionsMenuItem.size,
        \.type.gitHubButtonTitle.size,
        \.type.signInTitle.size,
        \.type.signInDetail.size,
        \.type.signInLink.size,
        \.type.signInLinkArrow.size,
        \.type.signInError.size,
        \.type.deviceCode.size,
        \.type.copySymbol.size,
        \.type.expirySymbol.size,
        \.type.expiry.size,
        \.type.emptyStateIcon.size,
        \.type.emptyStateText.size,
        \.type.accessPromptIcon.size,
        \.type.accessPromptTitle.size,
        \.type.accessPromptNoteIcon.size,
        \.type.accessPromptNote.size,
        \.panel.width,
        \.panel.contentHeight,
        \.topBar.height,
        \.topBar.leadingInset,
        \.topBar.trailingInset,
        \.topBar.headerControlsTrailingSpacing,
        \.topBar.refreshStatusWidth,
        \.tabSwitcher.width,
        \.tabSwitcher.leadingInset,
        \.tabSwitcher.notificationSegmentWidth,
        \.controls.height,
        \.controls.cornerRadius,
        \.controls.contentSpacing,
        \.controls.horizontalPadding,
        \.controls.sortDirectionWidth,
        \.controls.sortDividerVerticalInset,
        \.controls.segmentedHeight,
        \.controls.segmentedCornerRadius,
        \.controls.segmentedContentSpacing,
        \.controls.segmentSelectionInset,
        \.controls.segmentSelectionCornerRadius,
        \.controls.segmentDividerVerticalInset,
        \.prColumns.spacing,
        \.prColumns.rowSpacing,
        \.prColumns.headerHeight,
        \.prColumns.horizontalInset,
        \.prColumns.verticalInset,
        \.prColumns.avatarSize,
        \.prColumns.identitySpacing,
        \.prColumns.identityLineSpacing,
        \.prColumns.commentsWidth,
        \.prColumns.statusWidth,
        \.prColumns.changesWidth,
        \.prColumns.ageWidth,
        \.prColumns.actionButtonHitSize,
        \.refreshStatus.verticalWidth,
        \.refreshStatus.verticalSpacing,
        \.refreshStatus.indicatorSpacing,
        \.refreshStatus.indicatorSize,
        \.refreshStatus.iconFrame,
        \.refreshStatus.horizontalIconFrame,
        \.refreshStatus.horizontalSpacing,
        \.refreshStatus.horizontalPadding,
        \.refreshStatus.cornerRadius,
        \.banner.spacing,
        \.banner.horizontalPadding,
        \.banner.verticalPadding,
        \.prList.horizontalPadding,
        \.prList.topPadding,
        \.prList.bottomPadding,
        \.prList.sectionSpacing,
        \.prList.disclosureSpacing,
        \.prList.disclosureHorizontalPadding,
        \.prList.disclosureHeight,
        \.prList.sectionHeadingSpacing,
        \.prList.sectionChevronWidth,
        \.prList.sectionCountHorizontalPadding,
        \.prList.sectionCountVerticalPadding,
        \.dropdown.headerControlsSpacing,
        \.dropdown.gap,
        \.dropdown.authoredFilterWidth,
        \.dropdown.requestedFilterWidth,
        \.dropdown.sortWidth,
        \.dropdown.itemSpacing,
        \.dropdown.verticalPadding,
        \.dropdown.cornerRadius,
        \.dropdown.shadowRadius,
        \.dropdown.shadowOffsetY,
        \.dropdown.itemContentSpacing,
        \.dropdown.checkmarkWidth,
        \.dropdown.itemHorizontalPadding,
        \.dropdown.itemHeight,
        \.notificationList.headerSpacing,
        \.notificationList.headerHorizontalPadding,
        \.notificationList.headerTopPadding,
        \.notificationList.headerBottomPadding,
        \.notificationList.rowSpacing,
        \.notificationList.horizontalPadding,
        \.notificationList.topPadding,
        \.notificationList.bottomPadding,
        \.notificationRow.titleSpacing,
        \.notificationRow.pullRequestLineSpacing,
        \.notificationRow.minimumPRTitleWidth,
        \.notificationRow.markReadButtonSize,
        \.notificationRow.markReadOffset,
        \.notificationRow.markReadShadowRadius,
        \.notificationRow.markReadShadowOffsetY,
        \.prRow.identityItemSpacing,
        \.prRow.valueColumnHeight,
        \.prRow.draftBadgeHorizontalPadding,
        \.prRow.draftBadgeVerticalPadding,
        \.card.cornerRadius,
        \.legend.height,
        \.legend.mergeStatusSymbolSize,
        \.legend.mergeStatusStrokeWidth,
        \.legend.tooltipHorizontalPadding,
        \.legend.tooltipVerticalPadding,
        \.legend.tooltipCornerRadius,
        \.legend.tooltipShadowRadius,
        \.legend.tooltipShadowOffsetY,
        \.legend.tooltipGap,
        \.actionsMenu.width,
        \.actionsMenu.padding,
        \.actionsMenu.itemSpacing,
        \.actionsMenu.itemHeight,
        \.actionsMenu.itemContentSpacing,
        \.actionsMenu.itemIconWidth,
        \.actionsMenu.itemHorizontalPadding,
        \.actionsMenu.itemCornerRadius,
        \.actionsMenu.cornerRadius,
        \.actionsMenu.shadowRadius,
        \.actionsMenu.shadowOffsetY,
        \.actionsMenu.anchorGap,
        \.indicators.ciDotSize,
        \.indicators.signalSize,
        \.indicators.changesRequestedSymbolWidth,
        \.indicators.changesRequestedSymbolHeight,
        \.indicators.changesRequestedStrokeWidth,
        \.gitHubButton.contentSpacing,
        \.gitHubButton.markSize,
        \.gitHubButton.horizontalPadding,
        \.gitHubButton.height,
        \.gitHubButton.cornerRadius,
        \.signIn.padding,
        \.signIn.contentSpacing,
        \.signIn.appIconSize,
        \.signIn.buttonRowSpacing,
        \.signIn.pendingSpacing,
        \.signIn.enterCodeSpacing,
        \.signIn.linkSpacing,
        \.signIn.codeRowSpacing,
        \.signIn.codeTracking,
        \.signIn.codeHorizontalPadding,
        \.signIn.codeVerticalPadding,
        \.signIn.codeCornerRadius,
        \.signIn.copyButtonSize,
        \.signIn.expirySpacing,
        \.signIn.loadingSpacing,
        \.emptyState.spacing,
        \.accessPrompt.contentSpacing,
        \.accessPrompt.headerSpacing,
        \.accessPrompt.actionsSpacing,
        \.accessPrompt.maxContentWidth,
        \.accessPrompt.horizontalPadding,
        \.accessPrompt.noteBoxCornerRadius,
        \.accessPrompt.noteSpacing,
        \.accessPrompt.noteIconWidth,
        \.accessPrompt.noteHorizontalPadding,
        \.accessPrompt.noteVerticalPadding,
        \.footer.itemFont.size,
        \.footer.separatorHorizontalPadding,
        \.footer.separatorVerticalPadding,
        \.footer.rowHeight,
        \.footer.selectionInsetX,
        \.footer.selectionInsetY,
        \.footer.selectionCornerRadius,
        \.footer.titleLeading,
        \.footer.shortcutTrailing,
        \.footer.shortcutColumnSpacing,
        \.footer.shortcutKeyColumnWidth,
    ]

    private static let fontTokens: [KeyPath<MenuMetrics, MenuMetrics.FontToken>] = [
        \.type.panelTitle,
        \.type.controlLabel,
        \.type.controlChevron,
        \.type.segmentLabel,
        \.type.segmentIcon,
        \.type.refreshSymbol,
        \.type.refreshTimestamp,
        \.type.bannerMessage,
        \.type.bannerSymbol,
        \.type.disclosureChevron,
        \.type.disclosureTitle,
        \.type.dropdownItem,
        \.type.dropdownCheckmark,
        \.type.sectionChevron,
        \.type.sectionHeading,
        \.type.sectionCount,
        \.type.cardTitle,
        \.type.cardMetadata,
        \.type.notificationIcon,
        \.type.notificationTimestamp,
        \.type.markReadSymbol,
        \.type.legendLabel,
        \.type.legendIcon,
        \.type.legendTooltip,
        \.type.actionsSymbol,
        \.type.ageValue,
        \.type.metricValue,
        \.type.signalSymbol,
        \.type.draftBadge,
        \.type.actionsMenuItem,
        \.type.gitHubButtonTitle,
        \.type.signInTitle,
        \.type.signInDetail,
        \.type.signInLink,
        \.type.signInLinkArrow,
        \.type.signInError,
        \.type.deviceCode,
        \.type.copySymbol,
        \.type.expirySymbol,
        \.type.expiry,
        \.type.emptyStateIcon,
        \.type.emptyStateText,
        \.type.accessPromptIcon,
        \.type.accessPromptTitle,
        \.type.accessPromptNoteIcon,
        \.type.accessPromptNote,
    ]
}
