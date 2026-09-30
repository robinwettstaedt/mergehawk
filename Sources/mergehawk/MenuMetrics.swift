import AppKit
import SwiftUI

/// Every size used by the menu panel, grouped by component. Base values are stored;
/// values that follow from other values are computed, never repeated.
/// 1 pt hairlines, shape path geometry, ratios, opacities, counts and durations stay literal.
struct MenuMetrics: Equatable {
    /// A font built from an inspectable point size plus its weight and design.
    struct FontToken: Equatable {
        var size: CGFloat
        var weight: Font.Weight = .regular
        var design: Font.Design = .default
        var monospacedDigits = false

        var font: Font {
            let font = Font.system(size: size, weight: weight, design: design)
            return monospacedDigits ? font.monospacedDigit() : font
        }
    }

    /// The system menu font at an inspectable point size, used for native-looking menu rows.
    struct NativeMenuFontToken: Equatable {
        var size: CGFloat

        var font: Font { Font(NSFont.menuFont(ofSize: size)) }
    }

    /// Separators and borders: never a token, never scaled.
    static let hairline: CGFloat = 1

    struct TypeScale: Equatable {
        /// The "MergeHawk" title shown in the top bar while signed out.
        var panelTitle: FontToken
        /// Titles and symbols in bordered menu controls (filter, sort, mark all as read).
        var controlLabel: FontToken
        /// The small disclosure chevron inside a control.
        var controlChevron: FontToken
        var segmentLabel: FontToken
        var segmentIcon: FontToken
        var refreshSymbol: FontToken
        var refreshTimestamp: FontToken
        var bannerMessage: FontToken
        /// The banner's warning and dismiss symbols.
        var bannerSymbol: FontToken
        /// Chevron of the "Hidden (n)" disclosure rows.
        var disclosureChevron: FontToken
        var disclosureTitle: FontToken
        var dropdownItem: FontToken
        var dropdownCheckmark: FontToken
        var sectionChevron: FontToken
        var sectionHeading: FontToken
        var sectionCount: FontToken
        /// Titles of PR cards and in-app notification rows.
        var cardTitle: FontToken
        /// Author, repository and PR number lines under a card title.
        var cardMetadata: FontToken
        var notificationIcon: FontToken
        var notificationTimestamp: FontToken
        var markReadSymbol: FontToken
        var legendLabel: FontToken
        var legendIcon: FontToken
        var legendTooltip: FontToken
        var actionsSymbol: FontToken
        var ageValue: FontToken
        /// Comment counts, change counts and other numeric column values.
        var metricValue: FontToken
        var signalSymbol: FontToken
        var draftBadge: FontToken
        var actionsMenuItem: FontToken
    }

    struct Panel: Equatable {
        var width: CGFloat
        var contentHeight: CGFloat
    }

    struct TopBar: Equatable {
        var height: CGFloat
        var leadingInset: CGFloat
        var trailingInset: CGFloat
        var controlHeight: CGFloat
        /// Gap between the PR header controls and the refresh status control.
        var headerControlsTrailingSpacing: CGFloat
        var refreshStatusWidth: CGFloat
    }

    struct TabSwitcher: Equatable {
        var width: CGFloat
        var leadingInset: CGFloat
        var notificationSegmentWidth: CGFloat

        /// The two text tabs share the width the notification tab leaves.
        var textSegmentWidth: CGFloat { (width - notificationSegmentWidth) / 2 }
    }

    struct Controls: Equatable {
        var height: CGFloat
        var cornerRadius: CGFloat
        var contentSpacing: CGFloat
        var horizontalPadding: CGFloat
        var sortDirectionWidth: CGFloat
        var sortDividerVerticalInset: CGFloat
        var segmentedHeight: CGFloat
        var segmentedCornerRadius: CGFloat
        var segmentedContentSpacing: CGFloat
        var segmentSelectionInset: CGFloat
        var segmentSelectionCornerRadius: CGFloat
        var segmentDividerVerticalInset: CGFloat

        var sortDividerHeight: CGFloat { height - 2 * sortDividerVerticalInset }
        var segmentDividerHeight: CGFloat { segmentedHeight - 2 * segmentDividerVerticalInset }
    }

    /// Shared by the column header, the requested section headings and every PR row, so columns line up.
    struct PRColumns: Equatable {
        var spacing: CGFloat
        var rowSpacing: CGFloat
        var headerHeight: CGFloat
        var horizontalInset: CGFloat
        var verticalInset: CGFloat
        var avatarSize: CGFloat
        var identitySpacing: CGFloat
        var identityLineSpacing: CGFloat
        var commentsWidth: CGFloat
        var statusWidth: CGFloat
        var changesWidth: CGFloat
        var ageWidth: CGFloat
        var actionButtonHitSize: CGFloat

        var actionsWidth: CGFloat { actionButtonHitSize }
    }

    struct RefreshStatus: Equatable {
        var verticalWidth: CGFloat
        var verticalSpacing: CGFloat
        var indicatorSpacing: CGFloat
        var indicatorSize: CGFloat
        var iconFrame: CGFloat
        var horizontalIconFrame: CGFloat
        var horizontalSpacing: CGFloat
        var horizontalPadding: CGFloat
        var cornerRadius: CGFloat
    }

    struct Banner: Equatable {
        var spacing: CGFloat
        var horizontalPadding: CGFloat
        var verticalPadding: CGFloat
    }

    struct PRList: Equatable {
        var horizontalPadding: CGFloat
        var topPadding: CGFloat
        var bottomPadding: CGFloat
        var sectionSpacing: CGFloat
        var disclosureSpacing: CGFloat
        var disclosureHorizontalPadding: CGFloat
        var disclosureHeight: CGFloat
        var sectionHeadingSpacing: CGFloat
        var sectionChevronWidth: CGFloat
        var sectionCountHorizontalPadding: CGFloat
        var sectionCountVerticalPadding: CGFloat
    }

    /// The filter and sort dropdowns under the PR header controls.
    struct Dropdown: Equatable {
        var headerControlsSpacing: CGFloat
        /// Gap between a header control's bottom edge and its open dropdown.
        var gap: CGFloat
        var authoredFilterWidth: CGFloat
        var requestedFilterWidth: CGFloat
        var sortWidth: CGFloat
        var itemSpacing: CGFloat
        var verticalPadding: CGFloat
        var cornerRadius: CGFloat
        var shadowRadius: CGFloat
        var shadowOffsetY: CGFloat
        var itemContentSpacing: CGFloat
        var checkmarkWidth: CGFloat
        var itemHorizontalPadding: CGFloat
        var itemHeight: CGFloat
    }

    struct NotificationList: Equatable {
        var headerSpacing: CGFloat
        var headerHorizontalPadding: CGFloat
        var headerTopPadding: CGFloat
        var headerBottomPadding: CGFloat
        var rowSpacing: CGFloat
        var horizontalPadding: CGFloat
        var topPadding: CGFloat
        var bottomPadding: CGFloat
    }

    struct NotificationRow: Equatable {
        var titleSpacing: CGFloat
        var pullRequestLineSpacing: CGFloat
        var minimumPRTitleWidth: CGFloat
        var markReadButtonSize: CGFloat
        /// How far the mark-as-read button sits outside the card's top-leading corner.
        var markReadOffset: CGFloat
        var markReadShadowRadius: CGFloat
        var markReadShadowOffsetY: CGFloat
    }

    struct PRRow: Equatable {
        var identityItemSpacing: CGFloat
        /// Height of the stacked two-line value columns (changes, ages).
        var valueColumnHeight: CGFloat
        var draftBadgeHorizontalPadding: CGFloat
        var draftBadgeVerticalPadding: CGFloat
    }

    struct Card: Equatable {
        var cornerRadius: CGFloat
    }

    struct Legend: Equatable {
        var height: CGFloat
        var mergeStatusSymbolSize: CGFloat
        var mergeStatusStrokeWidth: CGFloat
        var tooltipHorizontalPadding: CGFloat
        var tooltipVerticalPadding: CGFloat
        var tooltipCornerRadius: CGFloat
        var tooltipShadowRadius: CGFloat
        var tooltipShadowOffsetY: CGFloat
        /// Gap between a column heading and its tooltip.
        var tooltipGap: CGFloat

        var tooltipOffset: CGFloat { height + tooltipGap }
    }

    struct ActionsMenu: Equatable {
        static let itemCount: CGFloat = 3

        var width: CGFloat
        var padding: CGFloat
        var itemSpacing: CGFloat
        var itemHeight: CGFloat
        var itemContentSpacing: CGFloat
        var itemIconWidth: CGFloat
        var itemHorizontalPadding: CGFloat
        var itemCornerRadius: CGFloat
        var cornerRadius: CGFloat
        var shadowRadius: CGFloat
        var shadowOffsetY: CGFloat
        /// Gap between the actions button and its open menu.
        var anchorGap: CGFloat

        var height: CGFloat {
            2 * padding + Self.itemCount * itemHeight + (Self.itemCount - 1) * itemSpacing
        }
    }

    struct Indicators: Equatable {
        var ciDotSize: CGFloat
        var signalSize: CGFloat
        var changesRequestedSymbolWidth: CGFloat
        var changesRequestedSymbolHeight: CGFloat
        var changesRequestedStrokeWidth: CGFloat
    }

    struct Footer: Equatable {
        static let rowCount: CGFloat = 4

        var itemFont: NativeMenuFontToken
        var separatorHorizontalPadding: CGFloat
        var separatorVerticalPadding: CGFloat
        var rowHeight: CGFloat
        var selectionInsetX: CGFloat
        var selectionInsetY: CGFloat
        var selectionCornerRadius: CGFloat
        var titleLeading: CGFloat
        var shortcutTrailing: CGFloat
        var shortcutColumnSpacing: CGFloat
        /// Reserve one key column so every shortcut has the same width and each ⌘ aligns.
        var shortcutKeyColumnWidth: CGFloat

        var separatorHeight: CGFloat { MenuMetrics.hairline + 2 * separatorVerticalPadding }
        /// Breathing room between the last footer row and the menu's bottom rounded corner,
        /// intentionally mirroring the separator gap above the first footer row.
        var bottomPadding: CGFloat { separatorVerticalPadding }
        var height: CGFloat { separatorHeight + Self.rowCount * rowHeight + bottomPadding }
    }

    var type: TypeScale
    var panel: Panel
    var topBar: TopBar
    var tabSwitcher: TabSwitcher
    var controls: Controls
    var prColumns: PRColumns
    var refreshStatus: RefreshStatus
    var banner: Banner
    var prList: PRList
    var dropdown: Dropdown
    var notificationList: NotificationList
    var notificationRow: NotificationRow
    var prRow: PRRow
    var card: Card
    var legend: Legend
    var actionsMenu: ActionsMenu
    var indicators: Indicators
    var footer: Footer

    /// A dropdown opens below its header control.
    var dropdownOffset: CGFloat { controls.height + dropdown.gap }

    var panelHeight: CGFloat { panel.contentHeight + footer.height }

    var panelSize: CGSize { CGSize(width: panel.width, height: panelHeight) }

    static let standard = MenuMetrics(
        type: TypeScale(
            panelTitle: FontToken(size: 13, weight: .bold),
            controlLabel: FontToken(size: 11, weight: .semibold),
            controlChevron: FontToken(size: 9, weight: .semibold),
            segmentLabel: FontToken(size: 13, weight: .medium),
            segmentIcon: FontToken(size: 12, weight: .semibold),
            refreshSymbol: FontToken(size: 13, weight: .semibold),
            refreshTimestamp: FontToken(size: 10, weight: .medium),
            bannerMessage: FontToken(size: 12),
            bannerSymbol: FontToken(size: 13),
            disclosureChevron: FontToken(size: 9, weight: .semibold),
            disclosureTitle: FontToken(size: 10, weight: .semibold),
            dropdownItem: FontToken(size: 11, weight: .semibold),
            dropdownCheckmark: FontToken(size: 11, weight: .semibold),
            sectionChevron: FontToken(size: 12, weight: .semibold),
            sectionHeading: FontToken(size: 13, weight: .semibold),
            sectionCount: FontToken(size: 10, weight: .semibold, monospacedDigits: true),
            cardTitle: FontToken(size: 11, weight: .semibold),
            cardMetadata: FontToken(size: 10, weight: .medium),
            notificationIcon: FontToken(size: 17, weight: .medium),
            notificationTimestamp: FontToken(size: 10, weight: .semibold, monospacedDigits: true),
            markReadSymbol: FontToken(size: 9, weight: .medium),
            legendLabel: FontToken(size: 10, weight: .semibold),
            legendIcon: FontToken(size: 13, weight: .semibold),
            legendTooltip: FontToken(size: 10, weight: .medium),
            actionsSymbol: FontToken(size: 12, weight: .semibold),
            ageValue: FontToken(size: 10, weight: .medium, monospacedDigits: true),
            metricValue: FontToken(size: 10, weight: .semibold, monospacedDigits: true),
            signalSymbol: FontToken(size: 12, weight: .semibold),
            draftBadge: FontToken(size: 9, weight: .semibold),
            actionsMenuItem: FontToken(size: 12)
        ),
        panel: Panel(width: 820, contentHeight: 650),
        topBar: TopBar(
            height: 45,
            leadingInset: 8,
            trailingInset: 12,
            controlHeight: 24,
            headerControlsTrailingSpacing: 8,
            refreshStatusWidth: 58
        ),
        tabSwitcher: TabSwitcher(width: 320, leadingInset: 5, notificationSegmentWidth: 64),
        controls: Controls(
            height: 24,
            cornerRadius: 6,
            contentSpacing: 6,
            horizontalPadding: 10,
            sortDirectionWidth: 26,
            sortDividerVerticalInset: 5,
            segmentedHeight: 28,
            segmentedCornerRadius: 6,
            segmentedContentSpacing: 5,
            segmentSelectionInset: 2,
            segmentSelectionCornerRadius: 5,
            segmentDividerVerticalInset: 7
        ),
        prColumns: PRColumns(
            spacing: 6,
            rowSpacing: 7,
            headerHeight: 32,
            horizontalInset: 10,
            verticalInset: 8,
            avatarSize: 22,
            identitySpacing: 7,
            identityLineSpacing: 4,
            commentsWidth: 30,
            statusWidth: 30,
            changesWidth: 49,
            ageWidth: 30,
            actionButtonHitSize: 28
        ),
        refreshStatus: RefreshStatus(
            verticalWidth: 82,
            verticalSpacing: 3,
            indicatorSpacing: 7,
            indicatorSize: 10,
            iconFrame: 22,
            horizontalIconFrame: 15,
            horizontalSpacing: 5,
            horizontalPadding: 3,
            cornerRadius: 6
        ),
        banner: Banner(spacing: 8, horizontalPadding: 12, verticalPadding: 8),
        prList: PRList(
            horizontalPadding: 12,
            topPadding: 5,
            bottomPadding: 12,
            sectionSpacing: 20,
            disclosureSpacing: 7,
            disclosureHorizontalPadding: 10,
            disclosureHeight: 30,
            sectionHeadingSpacing: 8,
            sectionChevronWidth: 12,
            sectionCountHorizontalPadding: 6,
            sectionCountVerticalPadding: 2
        ),
        dropdown: Dropdown(
            headerControlsSpacing: 8,
            gap: 10,
            authoredFilterWidth: 156,
            requestedFilterWidth: 112,
            sortWidth: 132,
            itemSpacing: 2,
            verticalPadding: 6,
            cornerRadius: 7,
            shadowRadius: 8,
            shadowOffsetY: 3,
            itemContentSpacing: 8,
            checkmarkWidth: 12,
            itemHorizontalPadding: 8,
            itemHeight: 24
        ),
        notificationList: NotificationList(
            headerSpacing: 8,
            headerHorizontalPadding: 12,
            headerTopPadding: 10,
            headerBottomPadding: 6,
            rowSpacing: 8,
            horizontalPadding: 12,
            topPadding: 5,
            bottomPadding: 12
        ),
        notificationRow: NotificationRow(
            titleSpacing: 8,
            pullRequestLineSpacing: 4,
            minimumPRTitleWidth: 40,
            markReadButtonSize: 22,
            markReadOffset: 6,
            markReadShadowRadius: 4,
            markReadShadowOffsetY: 1
        ),
        prRow: PRRow(
            identityItemSpacing: 4,
            valueColumnHeight: 30,
            draftBadgeHorizontalPadding: 6,
            draftBadgeVerticalPadding: 2
        ),
        card: Card(cornerRadius: 8),
        legend: Legend(
            height: 22,
            mergeStatusSymbolSize: 14,
            mergeStatusStrokeWidth: 1.4,
            tooltipHorizontalPadding: 8,
            tooltipVerticalPadding: 5,
            tooltipCornerRadius: 6,
            tooltipShadowRadius: 4,
            tooltipShadowOffsetY: 2,
            tooltipGap: 4
        ),
        actionsMenu: ActionsMenu(
            width: 156,
            padding: 6,
            itemSpacing: 2,
            itemHeight: 26,
            itemContentSpacing: 8,
            itemIconWidth: 16,
            itemHorizontalPadding: 6,
            itemCornerRadius: 4,
            cornerRadius: 7,
            shadowRadius: 8,
            shadowOffsetY: 3,
            anchorGap: 4
        ),
        indicators: Indicators(
            ciDotSize: 8,
            signalSize: 17,
            changesRequestedSymbolWidth: 13,
            changesRequestedSymbolHeight: 15,
            changesRequestedStrokeWidth: 1.3
        ),
        footer: Footer(
            itemFont: NativeMenuFontToken(size: NSFont.menuFont(ofSize: 0).pointSize),
            separatorHorizontalPadding: 10,
            separatorVerticalPadding: 6,
            rowHeight: 24,
            selectionInsetX: 5,
            selectionInsetY: 1,
            selectionCornerRadius: 5,
            titleLeading: 14,
            shortcutTrailing: 9,
            shortcutColumnSpacing: 2,
            shortcutKeyColumnWidth: 12
        )
    )
}

private struct MenuMetricsKey: EnvironmentKey {
    static let defaultValue = MenuMetrics.standard
}

extension EnvironmentValues {
    /// The menu panel's sizes. Views outside the menu root (such as menu views reused in Settings) get `.standard`.
    var menuMetrics: MenuMetrics {
        get { self[MenuMetricsKey.self] }
        set { self[MenuMetricsKey.self] = newValue }
    }
}
