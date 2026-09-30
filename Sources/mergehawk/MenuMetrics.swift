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

    struct TypeScale: Equatable {
        /// The "MergeHawk" title shown in the top bar while signed out.
        var panelTitle: FontToken
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

    var type: TypeScale
    var panel: Panel
    var topBar: TopBar
    var tabSwitcher: TabSwitcher

    private static let footerRowCount: CGFloat = 4

    var footerHeight: CGFloat {
        FooterSeparatorLayout.height + Self.footerRowCount * FooterActionLayout.rowHeight
            + FooterActionLayout.footerBottomPadding
    }

    var panelHeight: CGFloat { panel.contentHeight + footerHeight }

    var panelSize: CGSize { CGSize(width: panel.width, height: panelHeight) }

    static let standard = MenuMetrics(
        type: TypeScale(
            panelTitle: FontToken(size: 13, weight: .bold)
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
        tabSwitcher: TabSwitcher(width: 320, leadingInset: 5, notificationSegmentWidth: 64)
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
