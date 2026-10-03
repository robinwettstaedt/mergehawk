import AppKit
import SwiftUI
import mergehawkcore

enum PullRequestMenuDropdown: Equatable {
    case filter
    case sort
    case actions(String)
}

struct PullRequestMenuDropdownState: Equatable {
    var openMenu: PullRequestMenuDropdown?

    mutating func toggle(_ menu: PullRequestMenuDropdown) {
        openMenu = openMenu == menu ? nil : menu
    }

    mutating func dismiss() {
        openMenu = nil
    }
}

struct NotificationTimestampPresentation {
    static func label(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct NotificationReadPresentation {
    static let symbolName = "envelope.open"
    static let markAllTitle = "Mark all as read"
    static let markAllHelp = "Mark all notifications as read"
    static let markOneHelp = "Mark as read"
    static let markPRAccessibilityLabel = "Mark PR notification as read"
}

enum GitHubAppRepositoryAccessCopy {
    static let buttonTitle = "Install or Manage Repository Access"

    static func title(for status: DashboardController.GitHubAppRepositoryAccessStatus) -> String {
        switch status {
        case .noInstallations, .unknown:
            "Repository access not configured"
        case .noVisibleRepositories:
            "No repositories visible to MergeHawk"
        case .notApplicable, .checking, .configured:
            "Repository access"
        }
    }

    static func message(for status: DashboardController.GitHubAppRepositoryAccessStatus) -> String {
        switch status {
        case .noInstallations:
            "Install the MergeHawk GitHub App on your account or organization, then choose all repositories or the specific repositories MergeHawk should monitor."
        case .noVisibleRepositories:
            "The MergeHawk GitHub App is installed, but no accessible repositories are selected. Manage repository access on GitHub, then refresh sources."
        case .notApplicable, .unknown, .checking, .configured:
            "Manage which repositories MergeHawk can read through the GitHub App installation."
        }
    }
}

enum PullRequestNotificationTitlePresentation {
    static func title(for notification: PullRequestNotification) -> String {
        if let reasonTitle = CommentNotificationTitlePresentation.title(
            reason: notification.commentReason,
            actorLogin: notification.actorLogin
        ) {
            return reasonTitle
        }
        return switch notification.eventType {
        case .newComment:
            actorText(for: notification).map { "New comment from \($0)" }
                ?? "\(notification.count ?? 1) new comment\(notification.count == 1 ? "" : "s")"
        case .reviewApproved:
            actorText(for: notification).map { "Approved by \($0)" } ?? "Approved"
        case .reviewCommented:
            actorText(for: notification).map { "Review comment from \($0)" } ?? "Review comment"
        case .newReview:
            actorText(for: notification).map { "New review from \($0)" }
                ?? "\(notification.count ?? 1) new review\(notification.count == 1 ? "" : "s")"
        case .ciFailed:
            "CI failed"
        case .changesRequested:
            actorText(for: notification).map { "Changes requested by \($0)" } ?? "Changes requested"
        case .relationshipAdded:
            RelationshipChangeTitlePresentation.title(for: notification.relationshipChanges)
        case .otherCommitAdded:
            otherCommitTitle(for: notification)
        }
    }

    private static func actorText(for notification: PullRequestNotification) -> String? {
        notification.actorLogin.map { "@\($0)" }
    }

    private static func otherCommitTitle(for notification: PullRequestNotification) -> String {
        if let actor = actorText(for: notification) {
            return "New commit by \(actor)"
        }
        if let count = notification.count, count > 1 {
            return "\(count) commits by others"
        }
        return "New commit by someone else"
    }
}

enum PullRequestNotificationIconPresentation {
    static func symbolName(for eventType: PullRequestEventType) -> String {
        switch eventType {
        case .newComment:
            "text.bubble"
        case .reviewApproved:
            "checkmark.seal"
        case .reviewCommented:
            "quote.bubble"
        case .newReview:
            "checkmark.seal"
        case .ciFailed:
            "xmark.octagon"
        case .changesRequested:
            "exclamationmark.triangle"
        case .relationshipAdded:
            "person.badge.plus"
        case .otherCommitAdded:
            "arrow.trianglehead.branch"
        }
    }

    static func color(for eventType: PullRequestEventType) -> Color {
        switch eventType {
        case .reviewApproved:
            .green
        case .changesRequested, .ciFailed:
            .red
        case .newComment, .reviewCommented, .newReview:
            .blue
        case .relationshipAdded:
            .purple
        case .otherCommitAdded:
            .orange
        }
    }
}

struct MenuControlButton: View {
    let symbolName: String
    let title: String
    let isOpen: Bool
    let help: String
    let action: () -> Void

    @Environment(\.menuMetrics) private var metrics
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let controls = metrics.controls
        let shape = RoundedRectangle(cornerRadius: controls.cornerRadius)

        Button {
            action()
        } label: {
            HStack(spacing: controls.contentSpacing) {
                Image(systemName: symbolName)
                    .font(metrics.type.controlLabel.font)
                if !title.isEmpty {
                    Text(title)
                        .lineLimit(1)
                }
            }
            .font(metrics.type.controlLabel.font)
            .foregroundStyle(isOpen ? Color.accentColor : Color.secondary)
            .padding(.horizontal, title.isEmpty ? 0 : controls.horizontalPadding)
            .frame(width: title.isEmpty ? controls.height : nil, height: controls.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(shape)
        .background {
            shape.fill(hoverFill)
        }
        .overlay(
            shape
                .stroke(MenuControlBorderPresentation.color(colorScheme: colorScheme), lineWidth: 1)
        )
        .clipShape(shape)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var hoverFill: Color {
        HoverFillPresentation.fill(isHovered: isHovered, colorScheme: colorScheme)
    }
}

struct SortControlButton: View {
    let directionSymbolName: String
    let title: String
    let isMenuOpen: Bool
    let directionHelp: String
    let menuHelp: String
    let toggleDirection: () -> Void
    let openMenu: () -> Void

    @Environment(\.menuMetrics) private var metrics
    @Environment(\.colorScheme) private var colorScheme
    @State private var directionHovered = false
    @State private var menuHovered = false

    var body: some View {
        let controls = metrics.controls
        let shape = RoundedRectangle(cornerRadius: controls.cornerRadius)

        HStack(spacing: 0) {
            Button(action: toggleDirection) {
                Image(systemName: directionSymbolName)
                    .font(metrics.type.controlLabel.font)
                    .foregroundStyle(Color.secondary)
                    .frame(width: controls.sortDirectionWidth, height: controls.height)
                    .background(HoverFillPresentation.fill(isHovered: directionHovered, colorScheme: colorScheme))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { directionHovered = $0 }
            .help(directionHelp)
            .accessibilityLabel(directionHelp)

            Rectangle()
                .fill(MenuControlBorderPresentation.color(colorScheme: colorScheme))
                .frame(width: 1, height: controls.sortDividerHeight)

            Button(action: openMenu) {
                HStack(spacing: controls.contentSpacing) {
                    Text(title)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(metrics.type.controlChevron.font)
                }
                .font(metrics.type.controlLabel.font)
                .foregroundStyle(isMenuOpen ? Color.accentColor : Color.secondary)
                .padding(.horizontal, controls.horizontalPadding)
                .frame(height: controls.height)
                .background(HoverFillPresentation.fill(isHovered: menuHovered, colorScheme: colorScheme))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { menuHovered = $0 }
            .help(menuHelp)
            .accessibilityLabel(menuHelp)
        }
        .overlay(
            shape
                .stroke(MenuControlBorderPresentation.color(colorScheme: colorScheme), lineWidth: 1)
        )
        .clipShape(shape)
    }
}

private enum MenuControlBorderPresentation {
    static func color(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.24)
            : Color.black.opacity(0.13)
    }
}

private enum HoverFillPresentation {
    static func fill(isHovered: Bool, colorScheme: ColorScheme) -> Color {
        guard isHovered else {
            return .clear
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.07)
            : Color.black.opacity(0.05)
    }
}

enum PullRequestListCopy {
    static let emptyAuthored = "No authored PRs."
    static let emptyReviewRequests = "No review requests or assigned PRs."
    static let noFilterMatches = "No PRs match these filters."
}

enum HiddenPullRequestsDisclosurePresentation {
    static func title(count: Int) -> String {
        "Hidden (\(count))"
    }

    static func accessibilityLabel(count: Int, isExpanded: Bool) -> String {
        "\(title(count: count)), \(isExpanded ? "expanded" : "collapsed")"
    }
}

enum PullRequestPinPresentation {
    static func symbolName(isPinned: Bool) -> String {
        isPinned ? "pin.fill" : "pin"
    }

    static func label(isPinned: Bool) -> String {
        isPinned ? "Unpin" : "Pin"
    }
}

enum PullRequestHidePresentation {
    static let symbolName = "eye.slash"

    static func label(isHidden: Bool) -> String {
        isHidden ? "Unhide" : "Hide"
    }
}

enum PullRequestAgePresentation {
    enum Field {
        case opened
        case updated

        var title: String {
            switch self {
            case .opened: "Opened"
            case .updated: "Updated"
            }
        }
    }

    static func shortText(for date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:
            return "now"
        case ..<3_600:
            return "\(Int(seconds / 60))m"
        case ..<86_400:
            return "\(Int(seconds / 3_600))h"
        case ..<604_800:
            return "\(Int(seconds / 86_400))d"
        case ..<2_592_000:
            return "\(Int(seconds / 604_800))w"
        case ..<31_536_000:
            return "\(Int(seconds / 2_592_000))mo"
        default:
            return "\(Int(seconds / 31_536_000))y"
        }
    }

    static func label(for date: Date, field: Field, now: Date) -> String {
        let text = shortText(for: date, now: now)
        return text == "now" ? "\(field.title) just now" : "\(field.title) \(text) ago"
    }
}

private struct MenuNowKey: EnvironmentKey {
    static var defaultValue: Date { Date() }
}

extension EnvironmentValues {
    /// The date relative times are shown against. The menu root sets it from the controller's clock;
    /// views outside the menu root use the current time.
    var menuNow: Date {
        get { self[MenuNowKey.self] }
        set { self[MenuNowKey.self] = newValue }
    }
}

struct MenuRootView: View {
    @ObservedObject var controller: DashboardController
    @ObservedObject var footerModel: MenuFooterModel
    let metrics: MenuMetrics
    let resolvedSize: CGSize
    let dismissMenu: () -> Void
    let showSettings: () -> Void
    let showAbout: () -> Void
    let quit: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var dropdownState: PullRequestMenuDropdownState

    init(
        controller: DashboardController,
        footerModel: MenuFooterModel,
        metrics: MenuMetrics = .standard,
        resolvedSize: CGSize = MenuMetrics.standard.panelSize,
        initialDropdown: PullRequestMenuDropdown? = nil,
        dismissMenu: @escaping () -> Void = {},
        showSettings: @escaping () -> Void = {},
        showAbout: @escaping () -> Void = {},
        quit: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.footerModel = footerModel
        self.metrics = metrics
        self.resolvedSize = resolvedSize
        self.dismissMenu = dismissMenu
        self.showSettings = showSettings
        self.showAbout = showAbout
        self.quit = quit
        _dropdownState = State(initialValue: PullRequestMenuDropdownState(openMenu: initialDropdown))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .zIndex(2)
            Divider()
            if let error = controller.saveErrorMessage {
                SaveErrorBanner(message: error, dismiss: controller.dismissSaveError)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlayPreferenceValue(PullRequestActionsAnchorKey.self) { anchors in
                    GeometryReader { geometry in
                        DropdownOutsideClickView(
                            isActive: dropdownState.openMenu != nil,
                            excludedBounds: anchors.buttons.map { geometry[$0] },
                            dismiss: { dropdownState.dismiss() }
                        )
                    }
                }
            footer
        }
        .environment(\.menuNow, controller.currentDate())
        .frame(width: resolvedSize.width, height: resolvedSize.height)
        .background(menuSurface)
        .overlayPreferenceValue(PullRequestActionsAnchorKey.self) { anchors in
            if let menu = anchors.openMenu {
                GeometryReader { geometry in
                    let anchor = geometry[menu.bounds]
                    let actionsMenu = metrics.actionsMenu
                    PullRequestActionsMenu(
                        url: menu.url,
                        isHidden: menu.isHidden,
                        isPinned: menu.isPinned,
                        toggleHide: menu.toggleHide,
                        togglePin: menu.togglePin,
                        dismiss: { dropdownState.dismiss() }
                    )
                    .offset(
                        x: max(0, anchor.maxX - actionsMenu.width),
                        y: anchor.maxY + actionsMenu.height + actionsMenu.anchorGap <= geometry.size.height
                            ? anchor.maxY + actionsMenu.anchorGap
                            : max(0, anchor.minY - actionsMenu.height - actionsMenu.anchorGap)
                    )
                }
            }
        }
        .onExitCommand {
            if dropdownState.openMenu != nil {
                dropdownState.dismiss()
            } else {
                dismissMenu()
            }
        }
        .onChange(of: controller.selectedTab) { _, _ in
            dropdownState.dismiss()
        }
        .environment(\.menuMetrics, metrics)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            FooterSeparatorView()
            MenuFooterActionRow(
                title: "Refresh",
                shortcutKey: "R",
                isFlashed: footerModel.isFlashing,
                action: {
                    dropdownState.dismiss()
                    controller.refresh()
                }
            )
            MenuFooterActionRow(title: "Settings", shortcutKey: ",") {
                dismissMenu()
                showSettings()
            }
            MenuFooterActionRow(title: "About MergeHawk", shortcutKey: nil) {
                dismissMenu()
                showAbout()
            }
            MenuFooterActionRow(title: "Quit", shortcutKey: "Q") {
                dismissMenu()
                quit()
            }
        }
        .padding(.bottom, metrics.footer.bottomPadding)
    }

    private var menuSurface: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.55)
            if colorScheme == .light {
                Color.black.opacity(0.03)
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 0) {
            if controller.state.authStatus == .signedIn {
                tabSwitcher
            } else {
                Text("MergeHawk")
                    .font(metrics.type.panelTitle.font)
            }
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture { dropdownState.dismiss() }
            if let mode = activePullRequestMode, controller.state.authStatus == .signedIn {
                PullRequestHeaderControls(controller: controller, mode: mode, dropdownState: $dropdownState)
                    .padding(.trailing, metrics.topBar.headerControlsTrailingSpacing)
            }
            RefreshStatusControl(
                indicatorColor: controller.hasAttention ? .red : .green,
                isRefreshing: controller.isRefreshing,
                updatedAt: controller.state.syncedAt,
                errorMessage: controller.refreshErrorMessage,
                action: {
                    dropdownState.dismiss()
                    controller.refresh()
                },
                isRefreshEnabled: controller.state.authStatus == .signedIn,
                help: "Refresh",
                accessibilityLabel: "Refresh",
                timestampPrefix: "",
                width: metrics.topBar.refreshStatusWidth,
                // Same height as the filter and sort controls beside it, so the top bar lines up.
                displayMode: .horizontalButton(height: metrics.controls.height),
                showsIndicator: false
            )
        }
        .padding(.leading, metrics.topBar.leadingInset)
        .padding(.trailing, metrics.topBar.trailingInset)
        .frame(height: metrics.topBar.height)
    }

    private var activePullRequestMode: PullRequestListView.Mode? {
        switch controller.selectedTab {
        case .notifications: nil
        case .myPRs: .authored
        case .reviewRequests: .reviewRequests
        }
    }

    private var tabSwitcher: some View {
        MenuTabSegmentedControl(
            selection: $controller.selectedTab,
            attentionCount: controller.attentionCount
        )
        .frame(width: metrics.tabSwitcher.width)
        .padding(.leading, metrics.tabSwitcher.leadingInset)
    }

    @ViewBuilder
    private var content: some View {
        if controller.state.authStatus == .signedOut {
            GitHubSignInView(controller: controller)
        } else {
            switch controller.selectedTab {
            case .notifications:
                NotificationListView(controller: controller)
            case .myPRs:
                PullRequestListView(controller: controller, mode: .authored, dropdownState: $dropdownState)
            case .reviewRequests:
                PullRequestListView(controller: controller, mode: .reviewRequests, dropdownState: $dropdownState)
            }
        }
    }
}

/// The metrics the menu panel is built with and the size it is shown at.
struct MenuPanelLayout: Equatable {
    var metrics: MenuMetrics
    var size: CGSize
}

enum MenuPanelSize {
    /// Screen-space gap between the panel and the usable screen edges; not a panel size, so it never scales.
    static let margin: CGFloat = 12

    /// macOS limits a menu's width to 60% of the screen width (observed on macOS 27.0: 907 pt on a
    /// 1512 pt screen, 1536 pt on a 2560 pt screen); wider custom menu views are clipped.
    static let menuWidthShare: CGFloat = 0.6

    static func resolve(availableFrame: CGRect, menuSize: MenuSize) -> MenuPanelLayout {
        let budget = widthBudget(for: availableFrame)
        let metrics = MenuMetrics(scale: appliedFactor(widthBudget: budget, menuSize: menuSize))
        return MenuPanelLayout(
            metrics: metrics,
            size: CGSize(
                width: min(metrics.panel.width, budget),
                height: min(metrics.panelHeight, max(0, availableFrame.height - margin * 2))
            )
        )
    }

    /// The widest panel that macOS shows unclipped and that keeps the margins on the usable screen.
    static func widthBudget(for availableFrame: CGRect) -> CGFloat {
        max(0, min((availableFrame.width * menuWidthShare).rounded(.down), availableFrame.width - margin * 2))
    }

    /// Every size uses its own factor when its panel fits the width budget; otherwise it shrinks
    /// uniformly to the factor whose panel width equals the budget.
    private static func appliedFactor(widthBudget: CGFloat, menuSize: MenuSize) -> CGFloat {
        min(menuSize.factor, widthBudget / MenuMetrics.standard.panel.width)
    }
}

@MainActor
final class MenuFooterModel: ObservableObject {
    @Published private(set) var refreshFlashCount: Int = 0
    @Published fileprivate var isFlashing: Bool = false

    private static let keyboardSelectionDuration: TimeInterval = 0.1
    private var flashResetWorkItem: DispatchWorkItem?

    func flashRefresh() {
        refreshFlashCount += 1
        flashResetWorkItem?.cancel()
        isFlashing = true
        let resetWorkItem = DispatchWorkItem { [weak self] in
            self?.isFlashing = false
        }
        flashResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.keyboardSelectionDuration,
            execute: resetWorkItem
        )
    }
}

struct FooterSeparatorView: View {
    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: MenuMetrics.hairline)
            .padding(.horizontal, metrics.footer.separatorHorizontalPadding)
            .padding(.vertical, metrics.footer.separatorVerticalPadding)
    }
}

struct MenuFooterActionRow: View {
    let title: String
    let shortcutKey: String?
    var isFlashed = false
    let action: () -> Void

    @Environment(\.menuMetrics) private var metrics
    @State private var isHovering = false
    @StateObject private var clickFeedback = MenuFooterClickFeedback()

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(metrics.footer.itemFont.font)
                .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : Color(nsColor: .labelColor))
                .padding(.leading, metrics.footer.titleLeading)
            Spacer(minLength: 0)
            if let shortcutKey {
                HStack(spacing: metrics.footer.shortcutColumnSpacing) {
                    Text("⌘")
                    Text(shortcutKey)
                        .frame(width: metrics.footer.shortcutKeyColumnWidth, alignment: .leading)
                }
                .font(metrics.footer.itemFont.font)
                .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : Color(nsColor: .tertiaryLabelColor))
                .padding(.trailing, metrics.footer.shortcutTrailing)
            }
        }
        .frame(height: metrics.footer.rowHeight)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: metrics.footer.selectionCornerRadius)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
                    .padding(.horizontal, metrics.footer.selectionInsetX)
                    .padding(.vertical, metrics.footer.selectionInsetY)
            }
        }
        .onHover { isHovering = $0 }
        .onTapGesture {
            clickFeedback.perform(action)
        }
    }

    private var isSelected: Bool {
        (isHovering || isFlashed) && !clickFeedback.suppressesSelection
    }
}

@MainActor
final class MenuFooterClickFeedback: ObservableObject {
    private static let mouseClickFeedbackDuration: TimeInterval = 0.12
    @Published private(set) var suppressesSelection = false
    private(set) var isActive = false

    func perform(_ action: @escaping () -> Void) {
        guard !isActive else {
            return
        }

        isActive = true
        suppressesSelection = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.mouseClickFeedbackDuration) {
            self.suppressesSelection = false
            DispatchQueue.main.async {
                self.isActive = false
                action()
            }
        }
    }
}

struct RefreshStatusControl: View {
    enum DisplayMode {
        case vertical
        case horizontalButton(height: CGFloat)
    }

    let indicatorColor: Color
    let isRefreshing: Bool
    let updatedAt: Date?
    var errorMessage: String? = nil
    let action: () -> Void
    let isRefreshEnabled: Bool
    let help: String
    let accessibilityLabel: String
    var keyboardShortcut: KeyboardShortcut?
    var timestampPrefix = "updated "
    /// Defaults to the vertical layout's width.
    var width: CGFloat?
    var displayMode = DisplayMode.vertical
    var showsIndicator = true

    @Environment(\.menuMetrics) private var metrics
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        switch displayMode {
        case .vertical:
            verticalBody
        case .horizontalButton(let height):
            horizontalButton(height: height)
        }
    }

    private var verticalBody: some View {
        VStack(alignment: .center, spacing: metrics.refreshStatus.verticalSpacing) {
            HStack(spacing: metrics.refreshStatus.indicatorSpacing) {
                if showsIndicator {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: metrics.refreshStatus.indicatorSize, height: metrics.refreshStatus.indicatorSize)
                }
                refreshControl
            }
            Text("\(timestampPrefix)\(updatedText)")
                .font(metrics.type.refreshTimestamp.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(width: resolvedWidth, alignment: .center)
    }

    private var resolvedWidth: CGFloat {
        width ?? metrics.refreshStatus.verticalWidth
    }

    @ViewBuilder
    private func horizontalButton(height: CGFloat) -> some View {
        let presentation = statusPresentation
        let refreshStatus = metrics.refreshStatus
        let shape = RoundedRectangle(cornerRadius: refreshStatus.cornerRadius)
        let button = Button(action: action) {
            HStack(spacing: refreshStatus.horizontalSpacing) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: refreshStatus.horizontalIconFrame, height: refreshStatus.horizontalIconFrame)
                } else {
                    Image(systemName: presentation.symbolName)
                        .font(metrics.type.refreshSymbol.font)
                        .foregroundStyle(presentation.state == .failed ? Color.red : Color.secondary)
                        .frame(width: refreshStatus.horizontalIconFrame, height: refreshStatus.horizontalIconFrame)
                }
                Text("\(timestampPrefix)\(compactUpdatedText)")
                    .font(metrics.type.refreshTimestamp.font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, refreshStatus.horizontalPadding)
            .frame(width: resolvedWidth, height: height)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background {
            shape.fill(horizontalHoverFill)
        }
        .overlay(
            shape
                .stroke(MenuControlBorderPresentation.color(colorScheme: colorScheme), lineWidth: 1)
        )
        .clipShape(shape)
        .onHover { isHovered = $0 }
        .disabled(!isRefreshEnabled)
        .help(presentation.help)
        .accessibilityLabel(presentation.accessibilityLabel)

        if let keyboardShortcut {
            button.keyboardShortcut(keyboardShortcut)
        } else {
            button
        }
    }

    private var horizontalHoverFill: Color {
        HoverFillPresentation.fill(isHovered: isHovered, colorScheme: colorScheme)
    }

    @ViewBuilder
    private var refreshControl: some View {
        if isRefreshing {
            ProgressView()
                .controlSize(.small)
                .frame(width: metrics.refreshStatus.iconFrame, height: metrics.refreshStatus.iconFrame)
        } else {
            let presentation = statusPresentation
            let button = Button(action: action) {
                Image(systemName: presentation.symbolName)
                    .font(metrics.type.refreshSymbol.font)
                    .foregroundStyle(presentation.state == .failed ? Color.red : Color.secondary)
                    .frame(width: metrics.refreshStatus.iconFrame, height: metrics.refreshStatus.iconFrame)
            }
            .buttonStyle(.plain)
            .disabled(!isRefreshEnabled)
            .help(presentation.help)
            .accessibilityLabel(presentation.accessibilityLabel)

            if let keyboardShortcut {
                button.keyboardShortcut(keyboardShortcut)
            } else {
                button
            }
        }
    }

    private var updatedText: String {
        guard let updatedAt else {
            return "never"
        }
        return updatedAt.formatted(date: .omitted, time: .shortened)
    }

    private var compactUpdatedText: String {
        guard let updatedAt else {
            return "never"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "H:mm"
        return formatter.string(from: updatedAt)
    }

    private var statusPresentation: RefreshStatusPresentation {
        RefreshStatusPresentation(
            isRefreshing: isRefreshing,
            errorMessage: errorMessage,
            lastUpdatedText: compactUpdatedText,
            help: help,
            accessibilityLabel: accessibilityLabel
        )
    }
}

struct SaveErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.banner.spacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(metrics.type.bannerSymbol.font)
                .foregroundStyle(.red)
            Text("Couldn't save your changes: \(message)")
                .font(metrics.type.bannerMessage.font)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(metrics.type.bannerSymbol.font)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss save error")
        }
        .padding(.horizontal, metrics.banner.horizontalPadding)
        .padding(.vertical, metrics.banner.verticalPadding)
    }
}

struct RefreshStatusPresentation: Equatable {
    enum State: Equatable {
        case idle
        case refreshing
        case failed
    }

    let state: State
    let symbolName: String
    let help: String
    let accessibilityLabel: String

    init(
        isRefreshing: Bool,
        errorMessage: String?,
        lastUpdatedText: String,
        help: String,
        accessibilityLabel: String
    ) {
        let failure = errorMessage.flatMap { $0.isEmpty ? nil : $0 }
        if isRefreshing {
            state = .refreshing
            symbolName = "arrow.clockwise"
            self.help = help
            self.accessibilityLabel = "\(accessibilityLabel), refreshing"
        } else if let failure {
            state = .failed
            symbolName = "exclamationmark.triangle.fill"
            self.help = "Refresh failed: \(failure) Click to retry."
            let lastSuccess = lastUpdatedText == "never"
                ? "No successful refresh yet."
                : "Last successful refresh at \(lastUpdatedText)."
            self.accessibilityLabel = "\(accessibilityLabel) failed. \(failure) \(lastSuccess) Activate to retry."
        } else {
            state = .idle
            symbolName = "arrow.clockwise"
            self.help = help
            self.accessibilityLabel = accessibilityLabel
        }
    }
}

struct MenuSegmentedControl<Value: Hashable>: View {
    struct Segment {
        let value: Value
        var title: String = ""
        var systemImageName: String?
        let width: CGFloat
        var help: String?
    }

    @Binding var selection: Value
    let segments: [Segment]

    @Environment(\.menuMetrics) private var metrics
    @Environment(\.colorScheme) private var colorScheme

    private var height: CGFloat { metrics.controls.segmentedHeight }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.controls.segmentedCornerRadius, style: .continuous)

        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                segmentButton(segment, index: index)
            }
        }
        .frame(height: height)
        .background(shape.fill(containerFill))
        .overlay(shape.stroke(MenuControlBorderPresentation.color(colorScheme: colorScheme), lineWidth: 1))
        .clipShape(shape)
    }

    @ViewBuilder
    private func segmentButton(_ segment: Segment, index: Int) -> some View {
        let isSelected = segment.value == selection
        let showsDivider = index > 0 && !isSelected && segments[index - 1].value != selection

        Button {
            if selection != segment.value {
                selection = segment.value
            }
        } label: {
            HStack(spacing: metrics.controls.segmentedContentSpacing) {
                if let name = segment.systemImageName {
                    Image(systemName: name)
                        .font(metrics.type.segmentIcon.font)
                }
                if !segment.title.isEmpty {
                    Text(segment.title)
                        .font(metrics.type.segmentLabel.font)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(width: segment.width, height: height)
            .background {
                if isSelected {
                    let selectedShape = RoundedRectangle(
                        cornerRadius: metrics.controls.segmentSelectionCornerRadius,
                        style: .continuous
                    )
                    selectedShape
                        .fill(selectedFill)
                        .overlay(
                            selectedShape
                                .stroke(MenuControlBorderPresentation.color(colorScheme: colorScheme), lineWidth: 1)
                        )
                        .padding(metrics.controls.segmentSelectionInset)
                }
            }
            .overlay(alignment: .leading) {
                if showsDivider {
                    Rectangle()
                        .fill(MenuControlBorderPresentation.color(colorScheme: colorScheme))
                        .frame(width: 1, height: metrics.controls.segmentDividerHeight)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(segment.help ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var containerFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035)
    }

    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.95)
    }
}

private struct MenuTabSegmentedControl: View {
    @Binding var selection: DashboardController.MenuTab
    let attentionCount: Int
    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        MenuSegmentedControl(selection: $selection, segments: segments)
    }

    private var segments: [MenuSegmentedControl<DashboardController.MenuTab>.Segment] {
        DashboardController.MenuTab.allCases.map { tab in
            switch tab {
            case .notifications:
                MenuSegmentedControl.Segment(
                    value: tab,
                    title: MenuNotificationTabPresentation.label(for: attentionCount),
                    systemImageName: "bell",
                    width: metrics.tabSwitcher.notificationSegmentWidth,
                    help: MenuTabShortcutHint.title(for: tab)
                )
            case .myPRs, .reviewRequests:
                MenuSegmentedControl.Segment(
                    value: tab,
                    title: tab.rawValue,
                    width: metrics.tabSwitcher.textSegmentWidth,
                    help: MenuTabShortcutHint.title(for: tab)
                )
            }
        }
    }
}

enum MenuTabShortcutHint {
    static func title(for tab: DashboardController.MenuTab) -> String {
        let shortcutNumber = DashboardController.MenuTab.allCases.firstIndex(of: tab)! + 1
        return "⌘\(shortcutNumber)"
    }
}

enum MenuNotificationTabPresentation {
    static func label(for attentionCount: Int) -> String {
        attentionCount > 0 ? "\(attentionCount)" : ""
    }

    static func help(for attentionCount: Int) -> String {
        switch attentionCount {
        case 0:
            "Notifications"
        case 1:
            "1 new PR update"
        default:
            "\(attentionCount) new PR updates"
        }
    }
}

private struct NotificationListView: View {
    @ObservedObject var controller: DashboardController

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        let list = metrics.notificationList
        VStack(spacing: 0) {
            HStack(spacing: list.headerSpacing) {
                Spacer()

                if !controller.visiblePullRequestNotifications.isEmpty {
                    MenuControlButton(
                        symbolName: NotificationReadPresentation.symbolName,
                        title: NotificationReadPresentation.markAllTitle,
                        isOpen: false,
                        help: NotificationReadPresentation.markAllHelp
                    ) {
                        controller.markAllNotificationsRead()
                    }
                }
            }
            .padding(.horizontal, list.headerHorizontalPadding)
            .padding(.top, list.headerTopPadding)
            .padding(.bottom, list.headerBottomPadding)

            if controller.showsGitHubAppRepositoryAccessPrompt {
                GitHubAppRepositoryAccessPrompt(controller: controller)
            } else if controller.visiblePullRequestNotifications.isEmpty {
                EmptyMenuState(text: "No PR notifications.")
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: list.rowSpacing) {
                        ForEach(controller.visiblePullRequestNotifications) { notification in
                            PullRequestNotificationRow(notification: notification) {
                                controller.openPullRequestNotification(notification)
                            } onMarkRead: {
                                controller.markPullRequestNotificationRead(notification)
                            }
                        }
                    }
                    .padding(.horizontal, list.horizontalPadding)
                    .padding(.top, list.topPadding)
                    .padding(.bottom, list.bottomPadding)
                }
            }
        }
    }
}

struct GitHubSignInView: View {
    enum Copy {
        static let title = "Connect GitHub"
        static let buttonTitle = "Sign in with GitHub"
        static let permissionText = "MergeHawk uses its GitHub App to read PR data from repositories where the app is installed."
        static let enterCodeTitle = "Enter code on GitHub"
        static let enterCodeDetail = "Open GitHub and enter the code below to complete sign-in."
        static let copyCode = "Copy Code"
        static let codeCopied = "Code copied to clipboard"
        static let openGitHub = "Open GitHub"
        static let loadingTitle = "Authorized"
        static let loadingDetail = "Loading MergeHawk..."
        static let cancelSignIn = "Cancel"
        static let patHint = "Using a personal access token?"
        static let patButtonTitle = "Open Settings"
    }

    @ObservedObject var controller: DashboardController
    @Environment(\.menuMetrics) private var metrics
    @State private var isHoveringSignIn: Bool = false
    @State private var isHoveringPAT: Bool = false

    var body: some View {
        if let challenge = controller.deviceFlowChallenge {
            DeviceFlowPendingSignInView(controller: controller, challenge: challenge)
        } else {
            idleView
        }
    }

    private var idleView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: metrics.signIn.contentSpacing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: metrics.signIn.appIconSize, height: metrics.signIn.appIconSize)

                HStack(spacing: metrics.signIn.buttonRowSpacing) {
                    Button {
                        connect()
                    } label: {
                        HStack(spacing: metrics.gitHubButton.contentSpacing) {
                            if let mark = Self.gitHubMarkImage {
                                Image(nsImage: mark)
                                    .resizable()
                                    .renderingMode(.template)
                                    .frame(width: metrics.gitHubButton.markSize, height: metrics.gitHubButton.markSize)
                            }
                            Text(Self.Copy.buttonTitle)
                                .font(metrics.type.gitHubButtonTitle.font)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, metrics.gitHubButton.horizontalPadding)
                        .frame(height: metrics.gitHubButton.height)
                        .background(
                            Color.accentColor.opacity(isHoveringSignIn ? 0.8 : 1.0),
                            in: RoundedRectangle(cornerRadius: metrics.gitHubButton.cornerRadius, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.isRequestingDeviceCode)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.12)) { isHoveringSignIn = hovering }
                    }

                    if controller.isRequestingDeviceCode {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let error = controller.errorMessage {
                    Text(error)
                        .font(metrics.type.signInError.font)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Use a personal access token instead") {
                    controller.showGitHubSettings(patMode: true)
                }
                .buttonStyle(.plain)
                .font(metrics.type.signInLink.font)
                .foregroundStyle(isHoveringPAT ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
                .underline(isHoveringPAT)
                .onHover { hovering in
                    isHoveringPAT = hovering
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 0)
        }
        .padding(metrics.signIn.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    static var gitHubMarkImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "GitHubMark", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }

    private func connect() {
        Task {
            await controller.signInWithGitHub(keepsMenuVisible: true)
        }
    }
}

struct DeviceFlowPendingSignInView: View {
    @ObservedObject var controller: DashboardController
    let challenge: DeviceFlowChallenge
    @Environment(\.menuMetrics) private var metrics
    @State private var expiryTimeRemaining: String = ""
    @State private var justCopied: Bool = false
    @State private var isHoveringCopy: Bool = false
    private let expiryTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.signIn.pendingSpacing) {
            Spacer(minLength: 0)

            if controller.deviceFlowPhase == .loadingApp {
                loadingAppContent
            } else {
                enterCodeContent
            }

            Spacer(minLength: 0)
        }
        .padding(metrics.signIn.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear { updateExpiryLabel(challenge: challenge) }
        .onReceive(expiryTimer) { _ in updateExpiryLabel(challenge: challenge) }
    }

    private var enterCodeContent: some View {
        VStack(alignment: .leading, spacing: metrics.signIn.enterCodeSpacing) {
            HStack(spacing: 0) {
                Text("Enter code on ")
                    .font(metrics.type.signInTitle.font)
                Link(destination: challenge.verificationURI) {
                    HStack(spacing: metrics.signIn.linkSpacing) {
                        Text("GitHub")
                        Image(systemName: "arrow.up.right")
                            .font(metrics.type.signInLinkArrow.font)
                    }
                    .font(metrics.type.signInTitle.font)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: metrics.signIn.codeRowSpacing) {
                Text(challenge.userCode)
                    .font(metrics.type.deviceCode.font)
                    .tracking(metrics.signIn.codeTracking)
                    .padding(.horizontal, metrics.signIn.codeHorizontalPadding)
                    .padding(.vertical, metrics.signIn.codeVerticalPadding)
                    .background(
                        .quaternary,
                        in: RoundedRectangle(cornerRadius: metrics.signIn.codeCornerRadius, style: .continuous)
                    )

                Button {
                    controller.copyDeviceFlowUserCode()
                    withAnimation(.easeInOut(duration: 0.15)) { justCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeInOut(duration: 0.15)) { justCopied = false }
                    }
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(metrics.type.copySymbol.font)
                        .foregroundStyle(justCopied ? Color.green : (isHoveringCopy ? Color.primary : Color.secondary))
                        .frame(width: metrics.signIn.copyButtonSize, height: metrics.signIn.copyButtonSize)
                        .scaleEffect(isHoveringCopy && !justCopied ? 1.2 : 1.0)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) { isHoveringCopy = hovering }
                }
            }

            HStack(spacing: metrics.signIn.expirySpacing) {
                Image(systemName: "clock")
                    .font(metrics.type.expirySymbol.font)
                    .foregroundStyle(.tertiary)
                if !expiryTimeRemaining.isEmpty {
                    Text(expiryTimeRemaining)
                        .font(metrics.type.expiry.font)
                        .foregroundStyle(.tertiary)
                }
            }

            Button(GitHubSignInView.Copy.cancelSignIn) {
                controller.cancelDeviceFlowSignIn()
            }
            .buttonStyle(.plain)
            .font(metrics.type.signInLink.font)
            .foregroundStyle(.tertiary)
        }
    }

    private var loadingAppContent: some View {
        VStack(spacing: metrics.signIn.loadingSpacing) {
            ProgressView()
                .controlSize(.regular)
            Text(GitHubSignInView.Copy.loadingTitle)
                .font(metrics.type.signInTitle.font)
            Text(GitHubSignInView.Copy.loadingDetail)
                .font(metrics.type.signInDetail.font)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func updateExpiryLabel(challenge: DeviceFlowChallenge) {
        let remaining = challenge.expiresAt.timeIntervalSince(controller.currentDate())
        if remaining <= 0 {
            expiryTimeRemaining = ""
        } else {
            let minutes = Int(remaining) / 60
            let seconds = Int(remaining) % 60
            expiryTimeRemaining = String(format: "Expires in %d:%02d", minutes, seconds)
        }
    }
}


private extension RunLoop.Mode {
    static let eventTracking = RunLoop.Mode("NSEventTrackingRunLoopMode")
}

struct PullRequestListView: View {
    enum Mode {
        case authored
        case reviewRequests
    }

    @ObservedObject var controller: DashboardController
    let mode: Mode
    @Binding var dropdownState: PullRequestMenuDropdownState
    @State private var isHiddenExpanded: Bool
    @State private var expandedRequestedHiddenSections: Set<DashboardController.RequestedSection>
    @Environment(\.menuMetrics) private var metrics

    init(
        controller: DashboardController,
        mode: Mode,
        dropdownState: Binding<PullRequestMenuDropdownState> = .constant(PullRequestMenuDropdownState()),
        hiddenPullRequestsExpanded: Bool = false
    ) {
        self.controller = controller
        self.mode = mode
        _dropdownState = dropdownState
        _isHiddenExpanded = State(initialValue: hiddenPullRequestsExpanded)
        _expandedRequestedHiddenSections = State(
            initialValue: hiddenPullRequestsExpanded ? Set(DashboardController.RequestedSection.allCases) : []
        )
    }

    var body: some View {
        content
    }

    private var visiblePullRequests: [PullRequest] {
        switch mode {
        case .authored:
            controller.sortedMyPullRequests
        case .reviewRequests:
            controller.sortedReviewRequests
        }
    }

    private var hiddenPullRequests: [PullRequest] {
        switch mode {
        case .authored:
            controller.hiddenMyPullRequests
        case .reviewRequests:
            controller.hiddenReviewRequests
        }
    }

    private var matchingPullRequestCount: Int {
        visiblePullRequests.count + hiddenPullRequests.count
    }

    @ViewBuilder
    private var content: some View {
        if controller.showsGitHubAppRepositoryAccessPrompt {
            GitHubAppRepositoryAccessPrompt(controller: controller)
        } else {
            switch mode {
            case .authored:
                authoredContent
            case .reviewRequests:
                requestedContent
            }
        }
    }

    @ViewBuilder
    private var authoredContent: some View {
        if !hasSourcePullRequests {
            EmptyMenuState(text: emptyText)
        } else if matchingPullRequestCount == 0 {
            EmptyMenuState(text: PullRequestListCopy.noFilterMatches)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: metrics.prColumns.rowSpacing) {
                    PullRequestColumnHeader()

                    ForEach(visiblePullRequests) { pr in
                        pullRequestRow(pr)
                            .id("visible-\(pr.id)")
                    }

                    if !hiddenPullRequests.isEmpty {
                        hiddenDisclosure

                        if isHiddenExpanded {
                            ForEach(hiddenPullRequests) { pr in
                                pullRequestRow(pr)
                                    .id("hidden-\(pr.id)")
                            }
                        }
                    }
                }
                .padding(.horizontal, metrics.prList.horizontalPadding)
                .padding(.top, metrics.prList.topPadding)
                .padding(.bottom, metrics.prList.bottomPadding)
            }
        }
    }

    private var requestedContent: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: metrics.prList.sectionSpacing) {
                ForEach(controller.requestedSections, id: \.section) { content in
                    requestedSection(content)
                }
            }
            .padding(.horizontal, metrics.prList.horizontalPadding)
            .padding(.top, metrics.prList.topPadding)
            .padding(.bottom, metrics.prList.bottomPadding)
        }
    }

    private func requestedSection(_ content: DashboardController.RequestedSectionContent) -> some View {
        VStack(spacing: metrics.prColumns.rowSpacing) {
            requestedSectionDisclosure(content)

            if controller.isRequestedSectionExpanded(content.section), content.count > 0 {
                ForEach(content.visible) { pr in
                    pullRequestRow(pr)
                        .id("visible-\(pr.id)")
                }

                if !content.hidden.isEmpty {
                    requestedHiddenDisclosure(content)

                    if expandedRequestedHiddenSections.contains(content.section) {
                        ForEach(content.hidden) { pr in
                            pullRequestRow(pr)
                                .id("hidden-\(pr.id)")
                        }
                    }
                }
            }
        }
    }

    private func requestedSectionDisclosure(_ content: DashboardController.RequestedSectionContent) -> some View {
        RequestedSectionHeading(
            section: content.section,
            count: content.count,
            isExpanded: controller.isRequestedSectionExpanded(content.section)
        ) {
            if NSEvent.modifierFlags.contains(.option) {
                controller.toggleAllRequestedSections(from: content.section)
            } else {
                controller.toggleRequestedSection(content.section)
            }
        }
    }

    private func requestedHiddenDisclosure(_ content: DashboardController.RequestedSectionContent) -> some View {
        let isExpanded = expandedRequestedHiddenSections.contains(content.section)
        return Button {
            if isExpanded {
                expandedRequestedHiddenSections.remove(content.section)
            } else {
                expandedRequestedHiddenSections.insert(content.section)
            }
        } label: {
            HStack(spacing: metrics.prList.disclosureSpacing) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(metrics.type.disclosureChevron.font)
                Text(HiddenPullRequestsDisclosurePresentation.title(count: content.hidden.count))
                    .font(metrics.type.disclosureTitle.font)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, metrics.prList.disclosureHorizontalPadding)
            .frame(height: metrics.prList.disclosureHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(HiddenPullRequestsDisclosurePresentation.title(count: content.hidden.count))
        .accessibilityLabel(HiddenPullRequestsDisclosurePresentation.accessibilityLabel(
            count: content.hidden.count,
            isExpanded: isExpanded
        ))
    }

    private func pullRequestRow(_ pullRequest: PullRequest) -> some View {
        PullRequestRow(
            pullRequest: pullRequest,
            isAttention: controller.isUnreadPullRequest(pullRequest),
            isPinned: controller.isPinned(pullRequest),
            isHidden: controller.isHidden(pullRequest),
            isActionsOpen: dropdownState.openMenu == .actions(pullRequest.id),
            toggleActions: { dropdownState.toggle(.actions(pullRequest.id)) },
            toggleHide: {
                controller.toggleHide(pullRequest)
            },
            togglePin: {
                controller.togglePin(pullRequest)
            }
        ) {
            controller.openPullRequest(pullRequest)
        }
    }

    private var hiddenDisclosure: some View {
        Button {
            isHiddenExpanded.toggle()
        } label: {
            HStack(spacing: metrics.prList.disclosureSpacing) {
                Image(systemName: isHiddenExpanded ? "chevron.down" : "chevron.right")
                    .font(metrics.type.disclosureChevron.font)
                Text(HiddenPullRequestsDisclosurePresentation.title(count: hiddenPullRequests.count))
                    .font(metrics.type.disclosureTitle.font)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, metrics.prList.disclosureHorizontalPadding)
            .frame(height: metrics.prList.disclosureHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(HiddenPullRequestsDisclosurePresentation.title(count: hiddenPullRequests.count))
        .accessibilityLabel(HiddenPullRequestsDisclosurePresentation.accessibilityLabel(
            count: hiddenPullRequests.count,
            isExpanded: isHiddenExpanded
        ))
    }

    private var hasSourcePullRequests: Bool {
        switch mode {
        case .authored:
            !controller.sourceFilteredMyPullRequests.isEmpty
        case .reviewRequests:
            controller.sourceFilteredReviewRequests.contains(where: DashboardController.isRequestedPullRequest)
        }
    }

    private var emptyText: String {
        switch mode {
        case .authored:
            PullRequestListCopy.emptyAuthored
        case .reviewRequests:
            PullRequestListCopy.emptyReviewRequests
        }
    }
}

struct PullRequestHeaderControls: View {
    @ObservedObject var controller: DashboardController
    let mode: PullRequestListView.Mode
    @Binding var dropdownState: PullRequestMenuDropdownState

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.dropdown.headerControlsSpacing) {
            filterButton
                .overlay(alignment: .topTrailing) {
                    if dropdownState.openMenu == .filter {
                        filterMenu.offset(y: metrics.dropdownOffset)
                    }
                }
                .zIndex(dropdownState.openMenu == .filter ? 1 : 0)
            sortButton
                .overlay(alignment: .topTrailing) {
                    if dropdownState.openMenu == .sort {
                        sortMenu.offset(y: metrics.dropdownOffset)
                    }
                }
                .zIndex(dropdownState.openMenu == .sort ? 1 : 0)
        }
    }

    private var sortOption: DashboardController.PullRequestSortOption {
        switch mode {
        case .authored: controller.pullRequestSortOption
        case .reviewRequests: controller.reviewRequestSortOption
        }
    }

    private var sortDirection: DashboardController.PullRequestSortDirection {
        switch mode {
        case .authored: controller.pullRequestSortDirection
        case .reviewRequests: controller.reviewRequestSortDirection
        }
    }

    private func setSortOption(_ option: DashboardController.PullRequestSortOption) {
        switch mode {
        case .authored: controller.pullRequestSortOption = option
        case .reviewRequests: controller.reviewRequestSortOption = option
        }
    }

    private func toggleSortDirection() {
        switch mode {
        case .authored: controller.pullRequestSortDirection = controller.pullRequestSortDirection.toggled
        case .reviewRequests: controller.reviewRequestSortDirection = controller.reviewRequestSortDirection.toggled
        }
    }

    private var filterButton: some View {
        MenuControlButton(
            symbolName: "line.3.horizontal.decrease",
            title: filterButtonTitle,
            isOpen: dropdownState.openMenu == .filter,
            help: "Filter pull requests",
            action: { dropdownState.toggle(.filter) }
        )
    }

    private var filterButtonTitle: String {
        switch mode {
        case .authored:
            pullRequestFilterButtonTitle
        case .reviewRequests:
            reviewRequestFilterButtonTitle
        }
    }

    private var pullRequestFilterButtonTitle: String {
        let filters = controller.selectedPullRequestFilters.subtracting([.all])
        if filters.isEmpty {
            return DashboardController.PullRequestFilterOption.all.label
        }
        if filters.count == 1, let filter = filters.first {
            return filter.label
        }
        return "\(filters.count) filters"
    }

    private var reviewRequestFilterButtonTitle: String {
        let filters = controller.selectedReviewRequestFilters.subtracting([.all])
        if filters.isEmpty {
            return DashboardController.ReviewRequestFilterOption.all.label
        }
        if filters.count == 1, let filter = filters.first {
            return filter.label
        }
        return "\(filters.count) filters"
    }

    private var sortButton: some View {
        SortControlButton(
            directionSymbolName: sortDirection.isAscending ? "arrow.up" : "arrow.down",
            title: sortOption.label,
            isMenuOpen: dropdownState.openMenu == .sort,
            directionHelp: sortOption.directionHelp(for: sortDirection),
            menuHelp: "Sort pull requests",
            toggleDirection: {
                toggleSortDirection()
            },
            openMenu: {
                dropdownState.toggle(.sort)
            }
        )
    }

    @ViewBuilder
    private var filterMenu: some View {
        switch mode {
        case .authored:
            optionMenu(width: metrics.dropdown.authoredFilterWidth) {
                ForEach(DashboardController.PullRequestFilterOption.allCases) { option in
                    optionMenuButton(
                        title: option.label,
                        isSelected: pullRequestFilterIsSelected(option),
                        width: metrics.dropdown.authoredFilterWidth
                    ) {
                        togglePullRequestFilter(option)
                    }
                }
            }
        case .reviewRequests:
            optionMenu(width: metrics.dropdown.requestedFilterWidth) {
                ForEach(DashboardController.ReviewRequestFilterOption.allCases) { option in
                    optionMenuButton(
                        title: option.label,
                        isSelected: reviewRequestFilterIsSelected(option),
                        width: metrics.dropdown.requestedFilterWidth
                    ) {
                        toggleReviewRequestFilter(option)
                    }
                }
            }
        }
    }

    private func pullRequestFilterIsSelected(_ option: DashboardController.PullRequestFilterOption) -> Bool {
        option == .all
            ? controller.selectedPullRequestFilters.subtracting([.all]).isEmpty
            : controller.selectedPullRequestFilters.contains(option)
    }

    private func reviewRequestFilterIsSelected(_ option: DashboardController.ReviewRequestFilterOption) -> Bool {
        option == .all
            ? controller.selectedReviewRequestFilters.subtracting([.all]).isEmpty
            : controller.selectedReviewRequestFilters.contains(option)
    }

    private func togglePullRequestFilter(_ option: DashboardController.PullRequestFilterOption) {
        guard option != .all else {
            controller.selectedPullRequestFilters = []
            return
        }

        if controller.selectedPullRequestFilters.contains(option) {
            controller.selectedPullRequestFilters.remove(option)
        } else {
            controller.selectedPullRequestFilters.insert(option)
        }
    }

    private func toggleReviewRequestFilter(_ option: DashboardController.ReviewRequestFilterOption) {
        guard option != .all else {
            controller.selectedReviewRequestFilters = []
            return
        }

        if controller.selectedReviewRequestFilters.contains(option) {
            controller.selectedReviewRequestFilters.remove(option)
        } else {
            controller.selectedReviewRequestFilters.insert(option)
        }
    }

    private var sortMenu: some View {
        optionMenu(width: metrics.dropdown.sortWidth) {
            ForEach(DashboardController.PullRequestSortOption.allCases) { option in
                optionMenuButton(
                    title: option.label,
                    isSelected: sortOption == option,
                    width: metrics.dropdown.sortWidth
                ) {
                    setSortOption(option)
                    dropdownState.dismiss()
                }
            }
        }
    }

    private func optionMenu<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        let dropdown = metrics.dropdown
        return VStack(alignment: .leading, spacing: dropdown.itemSpacing) {
            content()
        }
        .padding(.vertical, dropdown.verticalPadding)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: dropdown.cornerRadius)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: dropdown.cornerRadius))
        .shadow(radius: dropdown.shadowRadius, y: dropdown.shadowOffsetY)
        .zIndex(1)
    }

    private func optionMenuButton(
        title: String,
        isSelected: Bool,
        width: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: metrics.dropdown.itemContentSpacing) {
                Image(systemName: isSelected ? "checkmark" : "")
                    .font(metrics.type.dropdownCheckmark.font)
                    .frame(width: metrics.dropdown.checkmarkWidth)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(metrics.type.dropdownItem.font)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, metrics.dropdown.itemHorizontalPadding)
            .frame(width: width, height: metrics.dropdown.itemHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PullRequestNotificationRow: View {
    let notification: PullRequestNotification
    let action: () -> Void
    let onMarkRead: () -> Void

    @State private var isHovered = false
    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: action) {
                HStack(alignment: .center, spacing: metrics.prColumns.identitySpacing) {
                    Image(systemName: PullRequestNotificationIconPresentation.symbolName(for: notification.eventType))
                        .font(metrics.type.notificationIcon.font)
                        .foregroundStyle(PullRequestNotificationIconPresentation.color(for: notification.eventType))
                        .frame(width: metrics.prColumns.avatarSize, height: metrics.prColumns.avatarSize)
                    VStack(alignment: .leading, spacing: metrics.prColumns.identityLineSpacing) {
                        HStack(alignment: .firstTextBaseline, spacing: metrics.notificationRow.titleSpacing) {
                            Text(title)
                                .font(metrics.type.cardTitle.font)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(NotificationTimestampPresentation.label(for: notification.prUpdatedAt))
                                .font(metrics.type.notificationTimestamp.font)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        pullRequestLine
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, metrics.prColumns.horizontalInset)
                .padding(.vertical, metrics.prColumns.verticalInset)
                .transparentCardStyle(
                    accentColor: notification.read ? nil : .accentColor,
                    isHovered: isHovered
                )
            }
            .buttonStyle(.plain)

            if isHovered && !notification.read {
                Button(action: onMarkRead) {
                    Image(systemName: NotificationReadPresentation.symbolName)
                        .font(metrics.type.markReadSymbol.font)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: row.markReadButtonSize, height: row.markReadButtonSize)
                        .background(.regularMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.16), radius: row.markReadShadowRadius, y: row.markReadShadowOffsetY)
                }
                .buttonStyle(.plain)
                .offset(x: -row.markReadOffset, y: -row.markReadOffset)
                .help(NotificationReadPresentation.markOneHelp)
                .accessibilityLabel(NotificationReadPresentation.markPRAccessibilityLabel)
            }
        }
        .onHover { isHovered = $0 }
    }

    private var title: String {
        PullRequestNotificationTitlePresentation.title(for: notification)
    }

    private var row: MenuMetrics.NotificationRow { metrics.notificationRow }

    private var pullRequestLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: row.pullRequestLineSpacing) {
                Text(notification.repo)
                    .fixedSize(horizontal: true, vertical: false)
                Text(verbatim: "#\(notification.prNumber)")
                    .fixedSize(horizontal: true, vertical: false)
                Text("·")
                    .fixedSize()
                Text(verbatim: notification.prTitle)
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(spacing: row.pullRequestLineSpacing) {
                Text(notification.repo)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(verbatim: "#\(notification.prNumber)")
                    .fixedSize(horizontal: true, vertical: false)
                Text("·")
                    .fixedSize()
                Text(verbatim: notification.prTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(
                        minWidth: row.minimumPRTitleWidth,
                        idealWidth: row.minimumPRTitleWidth,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            }
            HStack(spacing: row.pullRequestLineSpacing) {
                Text(notification.repo)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(verbatim: "#\(notification.prNumber)")
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
            }
        }
        .font(metrics.type.cardMetadata.font)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(pullRequestHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pullRequestAccessibilityLabel)
    }

    private var pullRequestHelp: String {
        "\(notification.repo)#\(notification.prNumber) · \(notification.prTitle)"
    }

    private var pullRequestAccessibilityLabel: String {
        "\(notification.repo)#\(notification.prNumber), \(notification.prTitle)"
    }
}

struct RequestedSectionHeading: View {
    let section: DashboardController.RequestedSection
    let count: Int
    let isExpanded: Bool
    var previewHoveredColumn: PullRequestColumnLegend.Column? = nil
    let action: () -> Void

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.prColumns.spacing) {
            Button(action: action) {
                HStack(spacing: metrics.prList.sectionHeadingSpacing) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(metrics.type.sectionChevron.font)
                        .frame(width: metrics.prList.sectionChevronWidth, alignment: .leading)
                    Text(section.title)
                        .font(metrics.type.sectionHeading.font)
                    Text("\(count)")
                        .font(metrics.type.sectionCount.font)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, metrics.prList.sectionCountHorizontalPadding)
                        .padding(.vertical, metrics.prList.sectionCountVerticalPadding)
                        .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
                    Spacer(minLength: 0)
                }
                .frame(height: metrics.prColumns.headerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(section.title): \(count) PRs")
            .accessibilityLabel("\(section.title), \(count) PRs, \(isExpanded ? "expanded" : "collapsed")")

            if isExpanded {
                PullRequestColumnLegend(previewHoveredColumn: previewHoveredColumn)
            }
        }
        .padding(.trailing, metrics.prColumns.horizontalInset)
        .frame(height: metrics.prColumns.headerHeight)
        .zIndex(1)
    }
}

struct PullRequestColumnHeader: View {
    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.prColumns.spacing) {
            Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
            PullRequestColumnLegend()
        }
        .padding(.horizontal, metrics.prColumns.horizontalInset)
        .frame(height: metrics.prColumns.headerHeight)
        .zIndex(1)
    }
}

struct PullRequestColumnLegend: View {
    enum Column: CaseIterable, Identifiable {
        case changes
        case comments
        case ci
        case mergeStatus
        case review
        case time

        var id: Self { self }

        @ViewBuilder
        func icon(in legend: MenuMetrics.Legend) -> some View {
            switch self {
            case .comments: Image(systemName: "bubble.left")
            case .review: Image(systemName: "person.crop.circle.badge.checkmark")
            case .ci: Image(systemName: "checkmark.circle")
            case .mergeStatus:
                MergeStatusSymbol()
                    .stroke(style: StrokeStyle(lineWidth: legend.mergeStatusStrokeWidth, lineCap: .round, lineJoin: .round))
                    .frame(width: legend.mergeStatusSymbolSize, height: legend.mergeStatusSymbolSize)
            case .changes: Image(systemName: "plusminus")
            case .time: Image(systemName: "clock.arrow.circlepath")
            }
        }

        var label: String {
            switch self {
            case .comments: "Unresolved comments"
            case .review: "Review feedback"
            case .ci: "CI"
            case .mergeStatus: "Merge status"
            case .changes: "Changes"
            case .time: "Updated / Opened"
            }
        }

        func width(in columns: MenuMetrics.PRColumns) -> CGFloat {
            switch self {
            case .comments: columns.commentsWidth
            case .review, .ci, .mergeStatus: columns.statusWidth
            case .changes: columns.changesWidth
            case .time: columns.ageWidth
            }
        }
    }

    var previewHoveredColumn: Column? = nil
    @State private var hoveredColumn: Column?
    @Environment(\.menuMetrics) private var metrics

    private var activeColumn: Column? { previewHoveredColumn ?? hoveredColumn }

    var body: some View {
        HStack(spacing: metrics.prColumns.spacing) {
            ForEach(Column.allCases) { column in
                columnHeader(column)
            }
            Color.clear.frame(width: metrics.prColumns.actionsWidth, height: 1)
                .accessibilityHidden(true)
        }
        .font(metrics.type.legendLabel.font)
        .foregroundStyle(.secondary)
        .frame(height: metrics.legend.height)
    }

    private func columnHeader(_ column: Column) -> some View {
        let legend = metrics.legend
        return column.icon(in: legend)
            .font(metrics.type.legendIcon.font)
            .frame(width: column.width(in: metrics.prColumns), height: legend.height)
            .contentShape(Rectangle())
            .onHover { isHovered in
                if isHovered {
                    hoveredColumn = column
                } else if hoveredColumn == column {
                    hoveredColumn = nil
                }
            }
            .overlay(alignment: .top) {
                if activeColumn == column {
                    Text(column.label)
                        .font(metrics.type.legendTooltip.font)
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .fixedSize()
                        .padding(.horizontal, legend.tooltipHorizontalPadding)
                        .padding(.vertical, legend.tooltipVerticalPadding)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: legend.tooltipCornerRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: legend.tooltipCornerRadius)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.16), radius: legend.tooltipShadowRadius, y: legend.tooltipShadowOffsetY)
                        .offset(y: legend.tooltipOffset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(column.label)
    }
}

struct PullRequestRow: View {
    let pullRequest: PullRequest
    let isAttention: Bool
    let isPinned: Bool
    let isHidden: Bool
    var isActionsOpen = false
    var toggleActions: () -> Void = {}
    let toggleHide: () -> Void
    let togglePin: () -> Void
    let action: () -> Void

    @Environment(\.menuNow) private var menuNow
    @State private var isHovered = false
    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.prColumns.spacing) {
            Button(action: action) {
                HStack(spacing: metrics.prColumns.spacing) {
                    HStack(spacing: metrics.prColumns.identitySpacing) {
                        PullRequestAuthorAvatar(author: pullRequest.author, url: pullRequest.authorAvatarURL)
                        identity
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PullRequestChangesIndicator(additions: pullRequest.additions, deletions: pullRequest.deletions)
                        .frame(width: metrics.prColumns.changesWidth)
                    CommentCountIndicator(count: pullRequest.commentCount)
                        .frame(width: metrics.prColumns.commentsWidth)
                    CIStatusIndicator(ciState: pullRequest.ciState)
                        .frame(width: metrics.prColumns.statusWidth)
                    MergeConflictIndicator(mergeable: pullRequest.mergeable)
                        .frame(width: metrics.prColumns.statusWidth)
                    ReviewDecisionIndicator(reviewDecision: pullRequest.reviewDecision)
                        .frame(width: metrics.prColumns.statusWidth)
                    VStack(alignment: .trailing, spacing: 0) {
                        ageCell(pullRequest.updatedAt, field: .updated)
                        ageCell(pullRequest.createdAt, field: .opened)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: metrics.prColumns.ageWidth, height: metrics.prRow.valueColumnHeight)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: toggleActions) {
                Image(systemName: "ellipsis")
                    .font(metrics.type.actionsSymbol.font)
                    .rotationEffect(.degrees(90))
                    .frame(width: metrics.prColumns.actionButtonHitSize, height: metrics.prColumns.actionButtonHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isActionsOpen ? Color.accentColor : Color.secondary)
            .help("PR actions")
            .accessibilityLabel("PR actions")
            .anchorPreference(key: PullRequestActionsAnchorKey.self, value: .bounds) { bounds in
                PullRequestActionsAnchors(
                    buttons: [bounds],
                    openMenu: isActionsOpen ? PullRequestActionsAnchor(
                        bounds: bounds,
                        url: pullRequest.url,
                        isHidden: isHidden,
                        isPinned: isPinned,
                        toggleHide: toggleHide,
                        togglePin: togglePin
                    ) : nil
                )
            }
            .frame(width: metrics.prColumns.actionsWidth)
        }
        .padding(.horizontal, metrics.prColumns.horizontalInset)
        .padding(.vertical, metrics.prColumns.verticalInset)
        .transparentCardStyle(accentColor: isAttention ? .accentColor : nil, isHovered: isHovered)
        .onHover { isHovered = $0 }
    }

    private func ageCell(_ date: Date, field: PullRequestAgePresentation.Field) -> some View {
        Text(PullRequestAgePresentation.shortText(for: date, now: menuNow))
            .font(metrics.type.ageValue.font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(PullRequestAgePresentation.label(for: date, field: field, now: menuNow))
            .accessibilityLabel(PullRequestAgePresentation.label(for: date, field: field, now: menuNow))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: metrics.prColumns.identityLineSpacing) {
            HStack(spacing: metrics.prRow.identityItemSpacing) {
                if pullRequest.draft { DraftPullRequestIndicator() }
                Text(pullRequest.title)
                    .font(metrics.type.cardTitle.font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(pullRequest.title)
                    .accessibilityLabel(pullRequest.title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: metrics.prRow.identityItemSpacing) {
                Text(pullRequest.author)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .help("Author: \(pullRequest.author)")
                    .accessibilityLabel("Author: \(pullRequest.author)")
                Text("·")
                    .fixedSize()
                    .accessibilityHidden(true)
                Text(pullRequest.repo)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(pullRequest.repo)
                    .accessibilityLabel(pullRequest.repo)
                Text("#\(pullRequest.number)")
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .help("Pull request #\(pullRequest.number)")
                    .accessibilityLabel("Pull request number \(pullRequest.number)")
            }
            .font(metrics.type.cardMetadata.font)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PullRequestAuthorAvatar: View {
    let author: String
    let url: URL?

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: metrics.prColumns.avatarSize, height: metrics.prColumns.avatarSize)
        .clipShape(Circle())
        .help("Author: \(author)")
        .accessibilityLabel("Author: \(author)")
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.monochrome)
            .foregroundColor(Color.gray)
    }
}

private struct DraftPullRequestIndicator: View {
    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        Text("Draft")
            .font(metrics.type.draftBadge.font)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, metrics.prRow.draftBadgeHorizontalPadding)
            .padding(.vertical, metrics.prRow.draftBadgeVerticalPadding)
            .background(Color.secondary.opacity(0.2), in: Capsule())
            .help("Draft PR")
            .accessibilityLabel("Draft PR")
    }
}

private struct TransparentCardStyle: ViewModifier {
    let accentColor: Color?
    let isHovered: Bool

    @Environment(\.menuMetrics) private var metrics
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.card.cornerRadius, style: .continuous)
        return content
            .background {
                shape
                    .fill(restFill)
                shape
                    .fill(hoverFill)
            }
            .overlay {
                shape
                    .stroke(borderColor, lineWidth: 1)
            }
            .clipShape(shape)
            .contentShape(shape)
    }

    private var restFill: Color {
        colorScheme == .light
            ? Color.white.opacity(0.95)
            : Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }

    private var hoverFill: Color {
        HoverFillPresentation.fill(isHovered: isHovered, colorScheme: colorScheme)
    }

    private var borderColor: Color {
        if let accentColor {
            return accentColor
        }

        return colorScheme == .light
            ? Color.black.opacity(0.17)
            : MenuControlBorderPresentation.color(colorScheme: colorScheme)
    }
}

private extension View {
    func transparentCardStyle(accentColor: Color?, isHovered: Bool) -> some View {
        modifier(TransparentCardStyle(accentColor: accentColor, isHovered: isHovered))
    }
}

// This view stays attached across open/close cycles. Unlike a SwiftUI gesture
// overlay, it never participates in hover hit-testing over the PR list.
private struct DropdownOutsideClickView: NSViewRepresentable {
    let isActive: Bool
    let excludedBounds: [CGRect]
    let dismiss: () -> Void

    func makeNSView(context: Context) -> DropdownOutsideClickNSView {
        DropdownOutsideClickNSView()
    }

    func updateNSView(_ view: DropdownOutsideClickNSView, context: Context) {
        view.isActive = isActive
        view.excludedBounds = excludedBounds
        view.dismiss = dismiss
    }
}

final class DropdownOutsideClickNSView: NSView {
    var isActive = false
    var excludedBounds: [CGRect] = []
    var dismiss: () -> Void = {}

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        return capturesClick(at: localPoint, eventType: NSApp.currentEvent?.type) ? self : nil
    }

    func capturesClick(at point: NSPoint, eventType: NSEvent.EventType?) -> Bool {
        isActive
            && eventType == .leftMouseDown
            && bounds.contains(point)
            && !excludedBounds.contains(where: { $0.contains(point) })
    }

    override func mouseDown(with event: NSEvent) {
        // Disable synchronously: SwiftUI may update its binding on the next pass.
        isActive = false
        dismiss()
    }

    override func mouseUp(with event: NSEvent) {}
}

private struct PullRequestActionsAnchor {
    let bounds: Anchor<CGRect>
    let url: URL
    let isHidden: Bool
    let isPinned: Bool
    let toggleHide: () -> Void
    let togglePin: () -> Void
}

private struct PullRequestActionsAnchors {
    var buttons: [Anchor<CGRect>] = []
    var openMenu: PullRequestActionsAnchor?
}

private struct PullRequestActionsAnchorKey: PreferenceKey {
    static var defaultValue: PullRequestActionsAnchors { PullRequestActionsAnchors() }

    static func reduce(value: inout PullRequestActionsAnchors, nextValue: () -> PullRequestActionsAnchors) {
        let next = nextValue()
        value.buttons.append(contentsOf: next.buttons)
        value.openMenu = next.openMenu ?? value.openMenu
    }
}

struct PullRequestActionsMenu: View {
    let url: URL
    let isHidden: Bool
    let isPinned: Bool
    let toggleHide: () -> Void
    let togglePin: () -> Void
    let dismiss: () -> Void

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        let actionsMenu = metrics.actionsMenu
        VStack(spacing: actionsMenu.itemSpacing) {
            menuItem(PullRequestHidePresentation.label(isHidden: isHidden), symbol: PullRequestHidePresentation.symbolName, action: toggleHide)
            menuItem(PullRequestPinPresentation.label(isPinned: isPinned), symbol: PullRequestPinPresentation.symbolName(isPinned: isPinned), action: togglePin)
            menuItem("Copy link", symbol: "doc.on.doc") {
                copyToPasteboard(url)
            }
        }
        .padding(actionsMenu.padding)
        .frame(width: actionsMenu.width, height: actionsMenu.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: actionsMenu.cornerRadius))
        // Padding belongs to the open menu, not the outside-click dismiss area.
        .contentShape(Rectangle())
        .onTapGesture {}
        .overlay {
            RoundedRectangle(cornerRadius: actionsMenu.cornerRadius)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: actionsMenu.shadowRadius, y: actionsMenu.shadowOffsetY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PR actions")
    }

    private func menuItem(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        PullRequestActionMenuItem(title: title, symbol: symbol) {
            dismiss()
            action()
        }
    }

    static func clipboardString(for url: URL) -> String {
        url.absoluteString
    }

    private func copyToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.clipboardString(for: url), forType: .string)
    }
}

private struct PullRequestActionMenuItem: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.menuMetrics) private var metrics
    @State private var isHovered = false

    var body: some View {
        let actionsMenu = metrics.actionsMenu
        Button(action: action) {
            HStack(spacing: actionsMenu.itemContentSpacing) {
                Image(systemName: symbol)
                    .frame(width: actionsMenu.itemIconWidth)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(metrics.type.actionsMenuItem.font)
            .padding(.horizontal, actionsMenu.itemHorizontalPadding)
            .frame(height: actionsMenu.itemHeight)
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .background(
                isHovered ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: actionsMenu.itemCornerRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct CommentCountIndicator: View {
    let count: Int

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        Text("\(count)")
            .font(metrics.type.metricValue.font)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Self.label(for: count))
            .help(Self.label(for: count))
    }

    static func label(for count: Int) -> String {
        "\(count) unresolved comment\(count == 1 ? "" : "s")"
    }
}

struct CIStatusIndicator: View {
    enum Kind: Equatable {
        case failing
        case pending
        case successful
        case unknown

        init(ciState: CIState) {
            switch ciState {
            case .failing:
                self = .failing
            case .pending:
                self = .pending
            case .passing:
                self = .successful
            case .unknown:
                self = .unknown
            }
        }
    }

    let ciState: CIState

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        Circle()
            .fill(kind.color.opacity(0.65))
            .frame(width: metrics.indicators.ciDotSize, height: metrics.indicators.ciDotSize)
            .accessibilityLabel(kind.label)
            .help(kind.label)
    }

    private var kind: Kind {
        Kind(ciState: ciState)
    }
}

extension CIStatusIndicator.Kind {
    var color: Color {
        switch self {
        case .failing:
            .red
        case .pending:
            .orange
        case .successful:
            .green
        case .unknown:
            .secondary
        }
    }

    var label: String {
        switch self {
        case .failing:
            "CI failing"
        case .pending:
            "CI pending (waiting or running)"
        case .successful:
            "CI successful"
        case .unknown:
            "CI status unknown"
        }
    }
}

struct PullRequestSignalIndicator: View {
    enum Kind: Equatable {
        case positive
        case negative
        case unavailable
    }

    let kind: Kind
    let label: String

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        Group {
            switch kind {
            case .positive:
                Image(systemName: "checkmark.circle.fill")
                    .font(metrics.type.signalSymbol.font)
                    .foregroundStyle(.green)
            case .negative:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(metrics.type.signalSymbol.font)
                    .foregroundStyle(.red)
            case .unavailable:
                Text("—")
                    .font(metrics.type.metricValue.font)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: metrics.indicators.signalSize, height: metrics.indicators.signalSize)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct MergeConflictIndicator: View {
    enum Kind: Equatable {
        case none
        case conflicting
        case unknown

        init(mergeable: MergeableState) {
            switch mergeable {
            case .mergeable: self = .none
            case .conflicting: self = .conflicting
            case .unknown: self = .unknown
            }
        }

        var label: String {
            switch self {
            case .none: "No merge conflicts; other requirements may still block merging"
            case .conflicting: "Merge conflicts"
            case .unknown: "Mergeability unknown"
            }
        }

        var signal: PullRequestSignalIndicator.Kind {
            switch self {
            case .none: .positive
            case .conflicting: .negative
            case .unknown: .unavailable
            }
        }
    }

    let mergeable: MergeableState

    var body: some View {
        PullRequestSignalIndicator(kind: kind.signal, label: kind.label)
    }

    private var kind: Kind { Kind(mergeable: mergeable) }
}

enum PullRequestChangesPresentation {
    static func text(additions: Int?, deletions: Int?) -> String {
        guard let additions, let deletions else { return "—" }
        return "\(additionsText(additions)) \(deletionsText(deletions))"
    }

    static func additionsText(_ additions: Int) -> String {
        "+\(compact(additions))"
    }

    static func deletionsText(_ deletions: Int) -> String {
        "−\(compact(deletions))"
    }

    static func label(additions: Int?, deletions: Int?) -> String {
        guard let additions, let deletions else { return "Change counts unavailable" }
        return "\(exact(additions)) additions, \(exact(deletions)) deletions"
    }

    private static func compact(_ value: Int) -> String {
        let suffixes = ["", "k", "m", "b", "t", "q"]
        var scaled = Double(value)
        var unit = 0
        while scaled >= 1_000 && unit < suffixes.count - 1 {
            scaled /= 1_000
            unit += 1
        }
        if unit == 0 { return String(value) }
        if scaled.rounded() >= 1_000 && unit < suffixes.count - 1 {
            return "1.0\(suffixes[unit + 1])"
        }
        return scaled < 10
            ? String(format: "%.1f%@", scaled, suffixes[unit])
            : String(format: "%.0f%@", scaled, suffixes[unit])
    }

    private static func exact(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

struct PullRequestChangesIndicator: View {
    let additions: Int?
    let deletions: Int?

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        Group {
            if let additions, let deletions {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(PullRequestChangesPresentation.additionsText(additions))
                        .foregroundStyle(.green)
                    Text(PullRequestChangesPresentation.deletionsText(deletions))
                        .foregroundStyle(.red)
                }
                .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
        .font(metrics.type.metricValue.font)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: metrics.prColumns.changesWidth, height: metrics.prRow.valueColumnHeight)
        .contentShape(Rectangle())
        .help(PullRequestChangesPresentation.label(additions: additions, deletions: deletions))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PullRequestChangesPresentation.label(additions: additions, deletions: deletions))
    }
}

private struct MergeStatusSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 1, y: 1, width: 4, height: 4))
        path.addEllipse(in: CGRect(x: 1, y: 11, width: 4, height: 4))
        path.addEllipse(in: CGRect(x: 11, y: 11, width: 4, height: 4))
        path.move(to: CGPoint(x: 3, y: 5))
        path.addLine(to: CGPoint(x: 3, y: 11))
        path.move(to: CGPoint(x: 13, y: 11))
        path.addLine(to: CGPoint(x: 13, y: 7))
        path.addQuadCurve(to: CGPoint(x: 9, y: 3), control: CGPoint(x: 13, y: 3))
        path.addLine(to: CGPoint(x: 7, y: 3))
        path.move(to: CGPoint(x: 9, y: 1))
        path.addLine(to: CGPoint(x: 7, y: 3))
        path.addLine(to: CGPoint(x: 9, y: 5))
        return path.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16))
    }
}

private struct ChangesRequestedSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Folded document outline.
        path.move(to: CGPoint(x: 2, y: 1))
        path.addLine(to: CGPoint(x: 10, y: 1))
        path.addLine(to: CGPoint(x: 14, y: 5))
        path.addLine(to: CGPoint(x: 14, y: 15))
        path.addLine(to: CGPoint(x: 2, y: 15))
        path.closeSubpath()
        path.move(to: CGPoint(x: 10, y: 1))
        path.addLine(to: CGPoint(x: 10, y: 5))
        path.addLine(to: CGPoint(x: 14, y: 5))
        // Added and removed lines, matching the review-feedback meaning.
        path.move(to: CGPoint(x: 5, y: 8))
        path.addLine(to: CGPoint(x: 11, y: 8))
        path.move(to: CGPoint(x: 8, y: 5.5))
        path.addLine(to: CGPoint(x: 8, y: 10.5))
        path.move(to: CGPoint(x: 5, y: 12))
        path.addLine(to: CGPoint(x: 11, y: 12))
        return path.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16))
    }
}

struct ReviewDecisionIndicator: View {
    enum Kind: Equatable {
        case approved
        case changesRequested
        case noReviewYet
        case unknown

        init(reviewDecision: ReviewDecision) {
            switch reviewDecision {
            case .approved:
                self = .approved
            case .changesRequested:
                self = .changesRequested
            case .noReviewYet:
                self = .noReviewYet
            case .unknown:
                self = .unknown
            }
        }
    }

    let reviewDecision: ReviewDecision

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        let indicators = metrics.indicators
        if kind == .changesRequested {
            ChangesRequestedSymbol()
                .stroke(.red, style: StrokeStyle(lineWidth: indicators.changesRequestedStrokeWidth, lineCap: .round, lineJoin: .round))
                .frame(width: indicators.changesRequestedSymbolWidth, height: indicators.changesRequestedSymbolHeight)
                .frame(width: indicators.signalSize, height: indicators.signalSize)
                .help(kind.label)
                .accessibilityLabel(kind.label)
        } else {
            PullRequestSignalIndicator(kind: kind.signal, label: kind.label)
        }
    }

    private var kind: Kind {
        Kind(reviewDecision: reviewDecision)
    }
}

extension ReviewDecisionIndicator.Kind {
    var signal: PullRequestSignalIndicator.Kind {
        switch self {
        case .approved: .positive
        case .changesRequested: .negative
        case .noReviewYet, .unknown: .unavailable
        }
    }

    var label: String {
        switch self {
        case .approved:
            "Review approved"
        case .changesRequested:
            "Changes requested"
        case .noReviewYet:
            "No review yet"
        case .unknown:
            "Review status unknown"
        }
    }
}

private struct EmptyMenuState: View {
    let text: String

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.emptyState.spacing) {
            Image(systemName: "tray")
                .font(metrics.type.emptyStateIcon.font)
                .foregroundStyle(.secondary)
            Text(text)
                .font(metrics.type.emptyStateText.font)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GitHubAppRepositoryAccessPrompt: View {
    @ObservedObject var controller: DashboardController
    var minHeight: CGFloat? = nil

    @Environment(\.menuMetrics) private var metrics

    private struct ContextRow {
        let icon: String
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: metrics.accessPrompt.contentSpacing) {
                VStack(spacing: metrics.accessPrompt.headerSpacing) {
                    Image(systemName: headerIconName)
                        .font(metrics.type.accessPromptIcon.font)
                        .foregroundStyle(.secondary)
                    Text(GitHubAppRepositoryAccessCopy.title(for: controller.gitHubAppRepositoryAccessStatus))
                        .font(metrics.type.accessPromptTitle.font)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: metrics.accessPrompt.actionsSpacing) {
                    contextBox

                    Button { controller.openGitHubAppInstallation() } label: {
                        let button = metrics.gitHubButton
                        HStack(spacing: button.contentSpacing) {
                            if let mark = GitHubSignInView.gitHubMarkImage {
                                Image(nsImage: mark)
                                    .resizable()
                                    .renderingMode(.template)
                                    .frame(width: button.markSize, height: button.markSize)
                            }
                            Text(GitHubAppRepositoryAccessCopy.buttonTitle)
                                .font(metrics.type.gitHubButtonTitle.font)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, button.horizontalPadding)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: button.height)
                        .background(
                            Color.accentColor,
                            in: RoundedRectangle(cornerRadius: button.cornerRadius, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: metrics.accessPrompt.maxContentWidth)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, metrics.accessPrompt.horizontalPadding)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity)
    }

    private var headerIconName: String {
        switch controller.gitHubAppRepositoryAccessStatus {
        case .noVisibleRepositories: "folder.badge.minus"
        default: "folder.badge.plus"
        }
    }

    private var contextRows: [ContextRow] {
        switch controller.gitHubAppRepositoryAccessStatus {
        case .noInstallations:
            [
                ContextRow(icon: "building.2", text: "Install MergeHawk GitHub App on your account or organization."),
                ContextRow(icon: "folder", text: "Choose all repositories or specific ones for MergeHawk to monitor.")
            ]
        case .noVisibleRepositories:
            [
                ContextRow(icon: "checkmark.circle", text: "The MergeHawk GitHub App is installed."),
                ContextRow(icon: "folder", text: "No repositories are selected — manage access on GitHub, then refresh sources.")
            ]
        default:
            [
                ContextRow(icon: "building.2", text: "Install MergeHawk GitHub App on your account or organization."),
                ContextRow(icon: "folder", text: "Choose all repositories or specific ones for MergeHawk to monitor.")
            ]
        }
    }

    private var contextBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(contextRows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                noteRow(icon: row.icon, text: row.text)
            }
        }
        .background(
            Color.gray.opacity(0.14),
            in: RoundedRectangle(cornerRadius: metrics.accessPrompt.noteBoxCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.accessPrompt.noteBoxCornerRadius, style: .continuous)
                .stroke(Color.gray.opacity(0.22), lineWidth: 1)
        )
    }

    private func noteRow(icon: String, text: String) -> some View {
        HStack(alignment: .center, spacing: metrics.accessPrompt.noteSpacing) {
            Image(systemName: icon)
                .font(metrics.type.accessPromptNoteIcon.font)
                .foregroundStyle(.secondary)
                .frame(width: metrics.accessPrompt.noteIconWidth, alignment: .center)
            Text(text)
                .font(metrics.type.accessPromptNote.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, metrics.accessPrompt.noteHorizontalPadding)
        .padding(.vertical, metrics.accessPrompt.noteVerticalPadding)
    }
}
