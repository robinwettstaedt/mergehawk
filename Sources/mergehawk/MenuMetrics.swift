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
        var tooltip: FontToken
        var actionsSymbol: FontToken
        var ageValue: FontToken
        /// Comment counts, change counts and other numeric column values.
        var metricValue: FontToken
        var signalSymbol: FontToken
        var draftBadge: FontToken
        /// The stack and chevron symbols in a requested stack card's chip.
        var stackChipSymbol: FontToken
        var actionsMenuItem: FontToken
        /// Title of the GitHub buttons in the sign-in view and the repository access prompt.
        var gitHubButtonTitle: FontToken
        var signInTitle: FontToken
        var signInDetail: FontToken
        /// Secondary text buttons: "Use a personal access token instead", "Cancel".
        var signInLink: FontToken
        var signInLinkArrow: FontToken
        var signInError: FontToken
        var deviceCode: FontToken
        var copySymbol: FontToken
        var expirySymbol: FontToken
        var expiry: FontToken
        var emptyStateIcon: FontToken
        var emptyStateText: FontToken
        var accessPromptIcon: FontToken
        var accessPromptTitle: FontToken
        var accessPromptNoteIcon: FontToken
        var accessPromptNote: FontToken
    }

    struct Panel: Equatable {
        var width: CGFloat
        var contentHeight: CGFloat
    }

    struct TopBar: Equatable {
        var height: CGFloat
        var leadingInset: CGFloat
        var trailingInset: CGFloat
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
        /// The stack chip has no vertical padding, so a stacked card keeps the standard height.
        var stackChipHorizontalPadding: CGFloat
        var stackChipSpacing: CGFloat
        /// The stack position column of an expanded stack member card; it takes width from the identity slot.
        var stackPositionWidth: CGFloat
    }

    struct Card: Equatable {
        var cornerRadius: CGFloat
    }

    struct Legend: Equatable {
        var height: CGFloat
        var mergeStatusSymbolSize: CGFloat
        var mergeStatusStrokeWidth: CGFloat
    }

    /// The single MergeHawk-drawn hover tooltip (`MenuTooltip.swift`).
    struct Tooltip: Equatable {
        var horizontalPadding: CGFloat
        var verticalPadding: CGFloat
        var cornerRadius: CGFloat
        var shadowRadius: CGFloat
        var shadowOffsetY: CGFloat
        /// Gap between the hovered element and its tooltip.
        var gap: CGFloat
        /// Closest the tooltip comes to the menu's edges.
        var edgeMargin: CGFloat
        /// Longer text wraps at this width.
        var maxWidth: CGFloat
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

    /// The accent "Sign in with GitHub" and "Install or Manage Repository Access" buttons.
    struct GitHubButton: Equatable {
        var contentSpacing: CGFloat
        var markSize: CGFloat
        var horizontalPadding: CGFloat
        var height: CGFloat
        var cornerRadius: CGFloat
    }

    struct SignIn: Equatable {
        var padding: CGFloat
        var contentSpacing: CGFloat
        var appIconSize: CGFloat
        var buttonRowSpacing: CGFloat
        var pendingSpacing: CGFloat
        var enterCodeSpacing: CGFloat
        var linkSpacing: CGFloat
        var codeRowSpacing: CGFloat
        var codeTracking: CGFloat
        var codeHorizontalPadding: CGFloat
        var codeVerticalPadding: CGFloat
        var codeCornerRadius: CGFloat
        var copyButtonSize: CGFloat
        var expirySpacing: CGFloat
        var loadingSpacing: CGFloat
    }

    struct EmptyState: Equatable {
        var spacing: CGFloat
    }

    struct AccessPrompt: Equatable {
        var contentSpacing: CGFloat
        var headerSpacing: CGFloat
        var actionsSpacing: CGFloat
        var maxContentWidth: CGFloat
        var horizontalPadding: CGFloat
        var noteBoxCornerRadius: CGFloat
        var noteSpacing: CGFloat
        var noteIconWidth: CGFloat
        var noteHorizontalPadding: CGFloat
        var noteVerticalPadding: CGFloat
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
    var tooltip: Tooltip
    var actionsMenu: ActionsMenu
    var indicators: Indicators
    var gitHubButton: GitHubButton
    var signIn: SignIn
    var emptyState: EmptyState
    var accessPrompt: AccessPrompt
    var footer: Footer

    /// A dropdown opens below its header control.
    var dropdownOffset: CGFloat { controls.height + dropdown.gap }

    var panelHeight: CGFloat { panel.contentHeight + footer.height }

    var panelSize: CGSize { CGSize(width: panel.width, height: panelHeight) }

    static let standard = MenuMetrics(scale: 1)

    /// The applied menu size factor. Every base measurement is its Default value times this;
    /// derived measurements follow from the scaled parts and hairlines stay 1 pt.
    let scale: CGFloat

    init(scale: CGFloat) {
        self.scale = scale
        func s(_ value: CGFloat) -> CGFloat { value * scale }

        // One type size per role; each font token picks its role, weight and design.
        let caption: CGFloat = 10
        let body: CGFloat = 11
        let title: CGFloat = 13
        let display: CGFloat = 17
        let displayLarge: CGFloat = 34

        type = TypeScale(
            panelTitle: FontToken(size: s(title), weight: .bold),
            controlLabel: FontToken(size: s(body), weight: .semibold),
            controlChevron: FontToken(size: s(caption), weight: .semibold),
            segmentLabel: FontToken(size: s(title), weight: .medium),
            segmentIcon: FontToken(size: s(body), weight: .semibold),
            refreshSymbol: FontToken(size: s(title), weight: .semibold),
            refreshTimestamp: FontToken(size: s(caption), weight: .medium),
            bannerMessage: FontToken(size: s(body)),
            bannerSymbol: FontToken(size: s(title)),
            disclosureChevron: FontToken(size: s(caption), weight: .semibold),
            disclosureTitle: FontToken(size: s(caption), weight: .semibold),
            dropdownItem: FontToken(size: s(body), weight: .semibold),
            dropdownCheckmark: FontToken(size: s(body), weight: .semibold),
            sectionChevron: FontToken(size: s(body), weight: .semibold),
            sectionHeading: FontToken(size: s(title), weight: .semibold),
            sectionCount: FontToken(size: s(caption), weight: .semibold, monospacedDigits: true),
            cardTitle: FontToken(size: s(body), weight: .semibold),
            cardMetadata: FontToken(size: s(caption), weight: .medium),
            notificationIcon: FontToken(size: s(display), weight: .medium),
            notificationTimestamp: FontToken(size: s(caption), weight: .semibold, monospacedDigits: true),
            markReadSymbol: FontToken(size: s(caption), weight: .medium),
            legendLabel: FontToken(size: s(caption), weight: .semibold),
            legendIcon: FontToken(size: s(title), weight: .semibold),
            tooltip: FontToken(size: s(caption), weight: .medium),
            actionsSymbol: FontToken(size: s(body), weight: .semibold),
            ageValue: FontToken(size: s(caption), weight: .medium, monospacedDigits: true),
            metricValue: FontToken(size: s(caption), weight: .semibold, monospacedDigits: true),
            signalSymbol: FontToken(size: s(body), weight: .semibold),
            draftBadge: FontToken(size: s(caption), weight: .semibold),
            stackChipSymbol: FontToken(size: s(caption), weight: .semibold),
            actionsMenuItem: FontToken(size: s(body)),
            gitHubButtonTitle: FontToken(size: s(title), weight: .semibold),
            signInTitle: FontToken(size: s(title), weight: .bold),
            signInDetail: FontToken(size: s(body)),
            signInLink: FontToken(size: s(body)),
            signInLinkArrow: FontToken(size: s(caption), weight: .bold),
            signInError: FontToken(size: s(caption)),
            deviceCode: FontToken(size: s(display), weight: .semibold, design: .monospaced),
            copySymbol: FontToken(size: s(title), weight: .medium),
            expirySymbol: FontToken(size: s(body)),
            expiry: FontToken(size: s(caption)),
            emptyStateIcon: FontToken(size: s(display)),
            emptyStateText: FontToken(size: s(body)),
            accessPromptIcon: FontToken(size: s(displayLarge), weight: .light),
            accessPromptTitle: FontToken(size: s(title), weight: .bold),
            accessPromptNoteIcon: FontToken(size: s(title)),
            accessPromptNote: FontToken(size: s(body))
        )
        panel = Panel(width: s(820), contentHeight: s(650))
        topBar = TopBar(
            height: s(45),
            leadingInset: s(8),
            trailingInset: s(12),
            headerControlsTrailingSpacing: s(8),
            refreshStatusWidth: s(58)
        )
        tabSwitcher = TabSwitcher(width: s(320), leadingInset: s(4), notificationSegmentWidth: s(64))
        controls = Controls(
            height: s(24),
            cornerRadius: s(6),
            contentSpacing: s(6),
            horizontalPadding: s(8),
            sortDirectionWidth: s(26),
            sortDividerVerticalInset: s(5),
            segmentedHeight: s(28),
            segmentedCornerRadius: s(6),
            segmentedContentSpacing: s(4),
            segmentSelectionInset: s(2),
            segmentSelectionCornerRadius: s(4),
            segmentDividerVerticalInset: s(7)
        )
        prColumns = PRColumns(
            spacing: s(6),
            rowSpacing: s(6),
            headerHeight: s(32),
            horizontalInset: s(8),
            verticalInset: s(8),
            avatarSize: s(22),
            identitySpacing: s(6),
            identityLineSpacing: s(4),
            commentsWidth: s(30),
            statusWidth: s(30),
            changesWidth: s(49),
            ageWidth: s(30),
            actionButtonHitSize: s(28)
        )
        refreshStatus = RefreshStatus(
            verticalWidth: s(82),
            verticalSpacing: s(2),
            indicatorSpacing: s(6),
            indicatorSize: s(10),
            iconFrame: s(22),
            horizontalIconFrame: s(15),
            horizontalSpacing: s(4),
            horizontalPadding: s(2),
            cornerRadius: s(6)
        )
        banner = Banner(spacing: s(8), horizontalPadding: s(12), verticalPadding: s(8))
        prList = PRList(
            horizontalPadding: s(12),
            topPadding: s(4),
            bottomPadding: s(12),
            sectionSpacing: s(20),
            disclosureSpacing: s(6),
            disclosureHorizontalPadding: s(8),
            disclosureHeight: s(30),
            sectionHeadingSpacing: s(8),
            sectionChevronWidth: s(12),
            sectionCountHorizontalPadding: s(6),
            sectionCountVerticalPadding: s(2)
        )
        dropdown = Dropdown(
            headerControlsSpacing: s(8),
            gap: s(8),
            authoredFilterWidth: s(156),
            requestedFilterWidth: s(112),
            sortWidth: s(132),
            itemSpacing: s(2),
            verticalPadding: s(6),
            cornerRadius: s(6),
            shadowRadius: s(8),
            shadowOffsetY: s(3),
            itemContentSpacing: s(8),
            checkmarkWidth: s(12),
            itemHorizontalPadding: s(8),
            itemHeight: s(24)
        )
        notificationList = NotificationList(
            headerSpacing: s(8),
            headerHorizontalPadding: s(12),
            headerTopPadding: s(8),
            headerBottomPadding: s(6),
            rowSpacing: s(8),
            horizontalPadding: s(12),
            topPadding: s(4),
            bottomPadding: s(12)
        )
        notificationRow = NotificationRow(
            titleSpacing: s(8),
            pullRequestLineSpacing: s(4),
            minimumPRTitleWidth: s(40),
            markReadButtonSize: s(22),
            markReadOffset: s(6),
            markReadShadowRadius: s(4),
            markReadShadowOffsetY: s(1)
        )
        prRow = PRRow(
            identityItemSpacing: s(4),
            valueColumnHeight: s(30),
            draftBadgeHorizontalPadding: s(6),
            draftBadgeVerticalPadding: s(2),
            stackChipHorizontalPadding: s(6),
            stackChipSpacing: s(2),
            stackPositionWidth: s(14)
        )
        card = Card(cornerRadius: s(8))
        legend = Legend(
            height: s(22),
            mergeStatusSymbolSize: s(14),
            mergeStatusStrokeWidth: s(1.4)
        )
        tooltip = Tooltip(
            horizontalPadding: s(8),
            verticalPadding: s(4),
            cornerRadius: s(6),
            shadowRadius: s(4),
            shadowOffsetY: s(2),
            gap: s(4),
            edgeMargin: s(4),
            maxWidth: s(320)
        )
        actionsMenu = ActionsMenu(
            width: s(156),
            padding: s(6),
            itemSpacing: s(2),
            itemHeight: s(26),
            itemContentSpacing: s(8),
            itemIconWidth: s(16),
            itemHorizontalPadding: s(6),
            itemCornerRadius: s(4),
            cornerRadius: s(6),
            shadowRadius: s(8),
            shadowOffsetY: s(3),
            anchorGap: s(4)
        )
        indicators = Indicators(
            ciDotSize: s(8),
            signalSize: s(17),
            changesRequestedSymbolWidth: s(13),
            changesRequestedSymbolHeight: s(15),
            changesRequestedStrokeWidth: s(1.3)
        )
        gitHubButton = GitHubButton(
            contentSpacing: s(6),
            markSize: s(14),
            horizontalPadding: s(16),
            height: s(30),
            cornerRadius: s(6)
        )
        signIn = SignIn(
            padding: s(24),
            contentSpacing: s(20),
            appIconSize: s(88),
            buttonRowSpacing: s(8),
            pendingSpacing: s(12),
            enterCodeSpacing: s(16),
            linkSpacing: s(2),
            codeRowSpacing: s(8),
            codeTracking: s(2),
            codeHorizontalPadding: s(12),
            codeVerticalPadding: s(8),
            codeCornerRadius: s(8),
            copyButtonSize: s(22),
            expirySpacing: s(4),
            loadingSpacing: s(8)
        )
        emptyState = EmptyState(spacing: s(8))
        accessPrompt = AccessPrompt(
            contentSpacing: s(20),
            headerSpacing: s(8),
            actionsSpacing: s(12),
            maxContentWidth: s(340),
            horizontalPadding: s(24),
            noteBoxCornerRadius: s(8),
            noteSpacing: s(8),
            noteIconWidth: s(22),
            noteHorizontalPadding: s(12),
            noteVerticalPadding: s(8)
        )
        footer = Footer(
            itemFont: NativeMenuFontToken(size: s(NSFont.menuFont(ofSize: 0).pointSize)),
            separatorHorizontalPadding: s(10),
            separatorVerticalPadding: s(6),
            rowHeight: s(24),
            selectionInsetX: s(5),
            selectionInsetY: s(1),
            selectionCornerRadius: s(5),
            titleLeading: s(14),
            shortcutTrailing: s(9),
            shortcutColumnSpacing: s(2),
            shortcutKeyColumnWidth: s(12)
        )
    }
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
