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
    var footer: Footer

    var panelHeight: CGFloat { panel.contentHeight + footer.height }

    var panelSize: CGSize { CGSize(width: panel.width, height: panelHeight) }

    static let standard = MenuMetrics(
        type: TypeScale(
            panelTitle: FontToken(size: 13, weight: .bold),
            controlLabel: FontToken(size: 11, weight: .semibold),
            controlChevron: FontToken(size: 9, weight: .semibold),
            segmentLabel: FontToken(size: 13, weight: .medium),
            segmentIcon: FontToken(size: 12, weight: .semibold)
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
