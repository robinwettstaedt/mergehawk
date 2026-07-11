import AppKit
import SwiftUI
import mergehawkcore

enum PullRequestMenuDropdown: Equatable {
    case filter
    case sort
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

struct CountSearchPresentation {
    static func countLabel(for count: Int, singular: String, plural: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural)"
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
    static let markOtherAccessibilityLabel = "Mark other notification as read"
}

enum GitHubInboxUnavailableCopy {
    static let title = "GitHub Inbox unavailable"
    static let message = "Other GitHub notifications require signing in with a classic personal access token."
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
        switch notification.eventType {
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

struct ExpandableSearchState: Equatable {
    var isExpanded = false
    var query = ""

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasActiveQuery: Bool {
        !trimmedQuery.isEmpty
    }

    mutating func expand() {
        isExpanded = true
    }

    mutating func blur() {
        if !hasActiveQuery {
            isExpanded = false
        }
    }

    mutating func handleEscape() {
        if hasActiveQuery {
            query = ""
        } else {
            isExpanded = false
        }
    }
}

struct CountSearchControl: View {
    @Binding var searchState: ExpandableSearchState
    let countLabel: String
    let placeholder: String
    let help: String
    var isAlwaysExpanded = false
    var showsInlineCount = true
    var expandedWidth: CGFloat?
    @State private var searchFieldFocused = false
    @State private var searchFocusRequest = 0

    var body: some View {
        HStack(spacing: 7) {
            if isSearchExpanded {
                expandedSearchControls
            } else {
                MenuControlButton(
                    symbolName: "magnifyingglass",
                    title: countLabel,
                    isOpen: false,
                    help: help
                ) {
                    searchState.expand()
                    DispatchQueue.main.async {
                        searchFocusRequest += 1
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isSearchExpanded)
        .onExitCommand {
            searchState.handleEscape()
            if !isSearchExpanded {
                searchFieldFocused = false
            }
        }
    }

    private var isSearchExpanded: Bool {
        isAlwaysExpanded || searchState.isExpanded
    }

    private var expandedSearchControls: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TransparentSearchTextField(
                text: $searchState.query,
                placeholder: placeholder,
                isFocused: $searchFieldFocused,
                focusRequest: searchFocusRequest
            ) {
                if !isAlwaysExpanded {
                    searchState.blur()
                }
            }
            .accessibilityLabel(help)
            .frame(height: 16)
            .onChange(of: searchState.isExpanded) { _, isExpanded in
                if !isExpanded && !isAlwaysExpanded {
                    searchFieldFocused = false
                }
            }
            if searchState.hasActiveQuery, showsInlineCount {
                Text(countLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if searchState.hasActiveQuery {
                clearSearchButton
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(width: expandedWidth)
        .frame(maxWidth: expandedWidth == nil ? .infinity : nil)
        .background(.ultraThinMaterial)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            searchState.expand()
            searchFocusRequest += 1
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    searchFieldFocused ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor).opacity(0.55),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var clearSearchButton: some View {
        Button {
            searchState.query = ""
            searchState.expand()
            DispatchQueue.main.async {
                searchFieldFocused = false
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Clear search")
        .accessibilityLabel("Clear search")
    }
}

private struct TransparentSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let focusRequest: Int
    let onBlur: () -> Void

    init(
        text: Binding<String>,
        placeholder: String,
        isFocused: Binding<Bool>,
        focusRequest: Int,
        onBlur: @escaping () -> Void
    ) {
        _text = text
        _isFocused = isFocused
        self.placeholder = placeholder
        self.focusRequest = focusRequest
        self.onBlur = onBlur
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = SearchTextField()
        field.delegate = context.coordinator
        Self.configure(field)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        Self.configure(field)
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        context.coordinator.onBlur = onBlur
        let shouldRequestFocus = context.coordinator.focusRequest != focusRequest
        context.coordinator.focusRequest = focusRequest

        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }

        if shouldRequestFocus || (isFocused && field.window?.firstResponder !== field.currentEditor()) {
            Self.focus(field)
        } else if !isFocused, field.window?.firstResponder === field.currentEditor() {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(nil)
            }
        } else {
            Self.configureEditor(for: field)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onBlur: onBlur)
    }

    private static func configure(_ field: NSTextField) {
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.clear.cgColor
        if let cell = field.cell as? NSTextFieldCell {
            cell.drawsBackground = false
            cell.backgroundColor = .clear
            cell.focusRingType = .none
        }
    }

    private static func focus(_ field: NSTextField, attemptsRemaining: Int = 3) {
        DispatchQueue.main.async {
            guard field.window != nil else {
                if attemptsRemaining > 0 {
                    focus(field, attemptsRemaining: attemptsRemaining - 1)
                }
                return
            }
            field.window?.makeFirstResponder(field)
            configureEditor(for: field)
        }
    }

    private static func configureEditor(for field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else {
            return
        }
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.insertionPointColor = .controlAccentColor
        editor.enclosingScrollView?.drawsBackground = false
        editor.superview?.wantsLayer = true
        editor.superview?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private final class SearchTextField: NSTextField {
        override func becomeFirstResponder() -> Bool {
            let becameFirstResponder = super.becomeFirstResponder()
            if becameFirstResponder {
                TransparentSearchTextField.configure(self)
                DispatchQueue.main.async {
                    TransparentSearchTextField.configureEditor(for: self)
                }
            }
            return becameFirstResponder
        }

        override func draw(_ dirtyRect: NSRect) {
            TransparentSearchTextField.configure(self)
            super.draw(dirtyRect)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var onBlur: () -> Void
        var focusRequest = 0

        init(text: Binding<String>, isFocused: Binding<Bool>, onBlur: @escaping () -> Void) {
            self.text = text
            self.isFocused = isFocused
            self.onBlur = onBlur
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                TransparentSearchTextField.configureEditor(for: field)
                DispatchQueue.main.async {
                    TransparentSearchTextField.configureEditor(for: field)
                }
            }
            isFocused.wrappedValue = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
            onBlur()
        }
    }
}

struct MenuControlButton: View {
    enum Layout {
        static let height: CGFloat = 24
    }

    let symbolName: String
    let title: String
    let isOpen: Bool
    let help: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)

        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .semibold))
                if !title.isEmpty {
                    Text(title)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isOpen ? Color.accentColor : Color.secondary)
            .padding(.horizontal, title.isEmpty ? 0 : 10)
            .frame(width: title.isEmpty ? Self.Layout.height : nil, height: Self.Layout.height)
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

    @Environment(\.colorScheme) private var colorScheme
    @State private var directionHovered = false
    @State private var menuHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)

        HStack(spacing: 0) {
            Button(action: toggleDirection) {
                Image(systemName: directionSymbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 26, height: MenuControlButton.Layout.height)
                    .background(HoverFillPresentation.fill(isHovered: directionHovered, colorScheme: colorScheme))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { directionHovered = $0 }
            .help(directionHelp)
            .accessibilityLabel(directionHelp)

            Rectangle()
                .fill(MenuControlBorderPresentation.color(colorScheme: colorScheme))
                .frame(width: 1, height: MenuControlButton.Layout.height - 10)

            Button(action: openMenu) {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isMenuOpen ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: MenuControlButton.Layout.height)
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

enum PullRequestRowMetadataPresentation {
    static func text(for pullRequest: PullRequest, showsAuthor: Bool) -> String {
        if showsAuthor {
            return "\(pullRequest.repo) · @\(pullRequest.author)"
        }
        return pullRequest.repo
    }

    static func branchText(for pullRequest: PullRequest) -> String {
        pullRequest.headRefName
    }
}

enum PullRequestPinPresentation {
    static let rotationDegrees = 35.0

    static func symbolName(isPinned: Bool) -> String {
        isPinned ? "pin.fill" : "pin"
    }

    static func label(isPinned: Bool) -> String {
        isPinned ? "Unpin PR" : "Pin PR"
    }
}

enum PullRequestAgePresentation {
    static func shortText(for date: Date, now: Date = Date()) -> String {
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
        case ..<31_536_000:
            return "\(Int(seconds / 604_800))w"
        default:
            return "\(Int(seconds / 31_536_000))y"
        }
    }

    static func label(for date: Date, now: Date = Date()) -> String {
        let text = shortText(for: date, now: now)
        return text == "now" ? "Updated just now" : "Updated \(text) ago"
    }
}

struct MenuRootView: View {
    enum Layout {
        static let width: CGFloat = 420
        static let contentHeight: CGFloat = 650
        static let footerRowCount: CGFloat = 4
        static let footerHeight: CGFloat = FooterSeparatorLayout.height + footerRowCount * FooterActionLayout.rowHeight
            + FooterActionLayout.footerBottomPadding
        static let height: CGFloat = contentHeight + footerHeight
        static let topBarHeight: CGFloat = 45
        static let tabSwitcherWidth: CGFloat = 320
        static let tabSwitcherLeadingInset: CGFloat = 5
        static let topBarTrailingInset: CGFloat = 12
        static let notificationTabSegmentWidth: CGFloat = 64
        static let topBarControlHeight: CGFloat = 24
        static let refreshStatusWidth: CGFloat = 58
        static let textTabSegmentWidth: CGFloat = (tabSwitcherWidth - notificationTabSegmentWidth) / 2
    }

    @ObservedObject var controller: DashboardController
    @ObservedObject var footerModel: MenuFooterModel
    let dismissMenu: () -> Void
    let showSettings: () -> Void
    let showAbout: () -> Void
    let quit: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var dismissTransientPRControlsSignal = 0

    init(
        controller: DashboardController,
        footerModel: MenuFooterModel,
        dismissMenu: @escaping () -> Void = {},
        showSettings: @escaping () -> Void = {},
        showAbout: @escaping () -> Void = {},
        quit: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.footerModel = footerModel
        self.dismissMenu = dismissMenu
        self.showSettings = showSettings
        self.showAbout = showAbout
        self.quit = quit
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: Self.Layout.width, height: Self.Layout.height)
        .background(scrim)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            FooterSeparatorView()
            MenuFooterActionRow(
                title: "Refresh",
                shortcut: "⌘R",
                isFlashed: footerModel.isFlashing,
                action: {
                    controller.refresh()
                }
            )
            MenuFooterActionRow(title: "Settings", shortcut: "⌘,") {
                dismissMenu()
                showSettings()
            }
            MenuFooterActionRow(title: "About MergeHawk", shortcut: nil) {
                dismissMenu()
                showAbout()
            }
            MenuFooterActionRow(title: "Quit", shortcut: "⌘Q") {
                dismissMenu()
                quit()
            }
        }
        .padding(.bottom, FooterActionLayout.footerBottomPadding)
    }

    @ViewBuilder
    private var scrim: some View {
        if colorScheme == .light {
            Color(nsColor: .windowBackgroundColor).opacity(0.55)
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 0) {
            if controller.state.authStatus == .signedIn {
                tabSwitcher
            } else {
                Text("MergeHawk")
                    .font(.headline)
            }
            Spacer(minLength: 0)
            RefreshStatusControl(
                indicatorColor: controller.hasAttention ? .red : .green,
                isRefreshing: controller.isRefreshing,
                updatedAt: controller.state.syncedAt,
                action: controller.refresh,
                isRefreshEnabled: controller.state.authStatus == .signedIn,
                help: "Refresh",
                accessibilityLabel: "Refresh",
                timestampPrefix: "",
                width: Self.Layout.refreshStatusWidth,
                displayMode: .horizontalButton(height: Self.Layout.topBarControlHeight),
                showsIndicator: false
            )
        }
        .padding(.leading, 8)
        .padding(.trailing, Self.Layout.topBarTrailingInset)
        .frame(height: Self.Layout.topBarHeight)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            dismissTransientPRControls()
        })
    }

    private var tabSwitcher: some View {
        MenuTabSegmentedControl(
            selection: $controller.selectedTab,
            attentionCount: controller.attentionCount
        )
        .frame(width: Self.Layout.tabSwitcherWidth)
        .padding(.leading, Self.Layout.tabSwitcherLeadingInset)
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
                PullRequestListView(
                    controller: controller,
                    mode: .authored,
                    dismissSignal: dismissTransientPRControlsSignal
                )
            case .reviewRequests:
                PullRequestListView(
                    controller: controller,
                    mode: .reviewRequests,
                    dismissSignal: dismissTransientPRControlsSignal
                )
            }
        }
    }

    private func dismissTransientPRControls() {
        dismissTransientPRControlsSignal += 1
    }

}

@MainActor
final class MenuFooterModel: ObservableObject {
    @Published private(set) var refreshFlashCount: Int = 0
    @Published fileprivate var isFlashing: Bool = false

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
            deadline: .now() + FooterActionLayout.keyboardSelectionDuration,
            execute: resetWorkItem
        )
    }
}

enum FooterSeparatorLayout {
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let height: CGFloat = 13
}

enum FooterActionLayout {
    static let rowHeight: CGFloat = 24
    // Breathing room between the last footer row and the menu's bottom rounded corner,
    // intentionally mirroring the separator gap above the first footer row.
    static let footerBottomPadding: CGFloat = FooterSeparatorLayout.verticalPadding
    static let selectionInsetX: CGFloat = 5
    static let selectionInsetY: CGFloat = 1
    static let selectionCornerRadius: CGFloat = 5
    static let titleLeading: CGFloat = 14
    static let shortcutTrailing: CGFloat = 9
    static let shortcutKern: CGFloat = 2
    static let keyboardSelectionDuration: TimeInterval = 0.1
}

struct FooterSeparatorView: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.horizontal, FooterSeparatorLayout.horizontalPadding)
            .padding(.vertical, FooterSeparatorLayout.verticalPadding)
    }
}

struct MenuFooterActionRow: View {
    let title: String
    let shortcut: String?
    var isFlashed = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.menuFont())
                .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : Color(nsColor: .labelColor))
                .padding(.leading, FooterActionLayout.titleLeading)
            Spacer(minLength: 0)
            if let shortcut {
                Text(shortcut)
                    .font(.menuFont())
                    .kerning(FooterActionLayout.shortcutKern)
                    .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : Color(nsColor: .tertiaryLabelColor))
                    .padding(.trailing, FooterActionLayout.shortcutTrailing)
            }
        }
        .frame(height: FooterActionLayout.rowHeight)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: FooterActionLayout.selectionCornerRadius)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
                    .padding(.horizontal, FooterActionLayout.selectionInsetX)
                    .padding(.vertical, FooterActionLayout.selectionInsetY)
            }
        }
        .onHover { isHovering = $0 }
        .onTapGesture {
            action()
        }
    }

    private var isSelected: Bool {
        isHovering || isFlashed
    }
}

private extension Font {
    static func menuFont() -> Font {
        Font(NSFont.menuFont(ofSize: 0))
    }
}

struct RefreshStatusControl: View {
    enum DisplayMode {
        case vertical
        case horizontalButton(height: CGFloat)
    }

    enum Layout {
        static let width: CGFloat = 82
        static let refreshIconSize: CGFloat = 22
        static let horizontalIconSize: CGFloat = 15
        static let horizontalSpacing: CGFloat = 5
        static let horizontalHorizontalPadding: CGFloat = 3
    }

    let indicatorColor: Color
    let isRefreshing: Bool
    let updatedAt: Date?
    let action: () -> Void
    let isRefreshEnabled: Bool
    let help: String
    let accessibilityLabel: String
    var keyboardShortcut: KeyboardShortcut?
    var timestampPrefix = "updated "
    var width = Layout.width
    var displayMode = DisplayMode.vertical
    var showsIndicator = true

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
        VStack(alignment: .center, spacing: 3) {
            HStack(spacing: 7) {
                if showsIndicator {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 10, height: 10)
                }
                refreshControl
            }
            Text("\(timestampPrefix)\(updatedText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(width: width, alignment: .center)
    }

    @ViewBuilder
    private func horizontalButton(height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let button = Button(action: action) {
            HStack(spacing: Layout.horizontalSpacing) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: Layout.horizontalIconSize, height: Layout.horizontalIconSize)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: Layout.horizontalIconSize, height: Layout.horizontalIconSize)
                }
                Text("\(timestampPrefix)\(compactUpdatedText)")
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, Layout.horizontalHorizontalPadding)
            .frame(width: width, height: height)
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
        .help(help)
        .accessibilityLabel(accessibilityLabel)

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
                .frame(width: Layout.refreshIconSize, height: Layout.refreshIconSize)
        } else {
            let button = Button(action: action) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: Layout.refreshIconSize, height: Layout.refreshIconSize)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!isRefreshEnabled)
            .help(help)
            .accessibilityLabel(accessibilityLabel)

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
    var height: CGFloat = 28
    var font: Font = .system(size: 13, weight: .medium)
    var iconPointSize: CGFloat = 12

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

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
            HStack(spacing: 5) {
                if let name = segment.systemImageName {
                    Image(systemName: name)
                        .font(.system(size: iconPointSize, weight: .semibold))
                }
                if !segment.title.isEmpty {
                    Text(segment.title)
                        .font(font)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(width: segment.width, height: height)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selectedFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(MenuControlBorderPresentation.color(colorScheme: colorScheme), lineWidth: 1)
                        )
                        .padding(2)
                }
            }
            .overlay(alignment: .leading) {
                if showsDivider {
                    Rectangle()
                        .fill(MenuControlBorderPresentation.color(colorScheme: colorScheme))
                        .frame(width: 1, height: height - 14)
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
                    width: MenuRootView.Layout.notificationTabSegmentWidth,
                    help: MenuTabShortcutHint.title(for: tab)
                )
            case .myPRs, .reviewRequests:
                MenuSegmentedControl.Segment(
                    value: tab,
                    title: tab.rawValue,
                    width: MenuRootView.Layout.textTabSegmentWidth,
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                NotificationSubtabSegmentedControl(selection: $controller.selectedNotificationSubtab)
                    .frame(width: 104, height: MenuControlButton.Layout.height)

                Spacer()

                if hasNotifications {
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
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            notificationContent
        }
    }

    private var hasNotifications: Bool {
        switch controller.selectedNotificationSubtab {
        case .pullRequests:
            !controller.visiblePullRequestNotifications.isEmpty
        case .other:
            !controller.visibleGitHubInboxNotifications.isEmpty
        }
    }

    @ViewBuilder
    private var notificationContent: some View {
        switch controller.selectedNotificationSubtab {
        case .pullRequests:
            if controller.showsGitHubAppRepositoryAccessPrompt {
                GitHubAppRepositoryAccessPrompt(controller: controller)
            } else if controller.visiblePullRequestNotifications.isEmpty {
                    EmptyMenuState(text: "No PR notifications.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(controller.visiblePullRequestNotifications) { notification in
                            PullRequestNotificationRow(notification: notification) {
                                controller.openPullRequestNotification(notification)
                            } onMarkRead: {
                                controller.markPullRequestNotificationRead(notification)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 5)
                    .padding(.bottom, 12)
                }
            }
        case .other:
            if controller.visibleGitHubInboxNotifications.isEmpty {
                if controller.showsGitHubInboxUnavailableHint {
                    GitHubInboxUnavailableState()
                } else {
                    EmptyMenuState(text: "No other GitHub notifications.")
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(controller.visibleGitHubInboxNotifications) { notification in
                            GitHubInboxNotificationRow(notification: notification) {
                                controller.openGitHubInboxNotification(notification)
                            } onMarkRead: {
                                controller.markGitHubInboxNotificationRead(notification)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 5)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

private struct NotificationSubtabSegmentedControl: View {
    @Binding var selection: DashboardController.NotificationSubtab

    var body: some View {
        MenuSegmentedControl(
            selection: $selection,
            segments: DashboardController.NotificationSubtab.allCases.map { subtab in
                MenuSegmentedControl.Segment(value: subtab, title: subtab.rawValue, width: 52)
            },
            height: MenuControlButton.Layout.height,
            font: .system(size: 11, weight: .medium),
            iconPointSize: 10
        )
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

            VStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 88, height: 88)

                HStack(spacing: 8) {
                    Button {
                        connect()
                    } label: {
                        HStack(spacing: 6) {
                            if let mark = Self.gitHubMarkImage {
                                Image(nsImage: mark)
                                    .resizable()
                                    .renderingMode(.template)
                                    .frame(width: 14, height: 14)
                            }
                            Text(Self.Copy.buttonTitle)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .background(
                            Color.accentColor.opacity(isHoveringSignIn ? 0.8 : 1.0),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Use a personal access token instead") {
                    controller.showGitHubSettings(patMode: true)
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(isHoveringPAT ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
                .underline(isHoveringPAT)
                .onHover { hovering in
                    isHoveringPAT = hovering
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 0)
        }
        .padding(24)
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
    @State private var expiryTimeRemaining: String = ""
    @State private var justCopied: Bool = false
    @State private var isHoveringCopy: Bool = false
    private let expiryTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)

            if controller.deviceFlowPhase == .loadingApp {
                loadingAppContent
            } else {
                enterCodeContent
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear { updateExpiryLabel(challenge: challenge) }
        .onReceive(expiryTimer) { _ in updateExpiryLabel(challenge: challenge) }
    }

    private var enterCodeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                Text("Enter code on ")
                    .font(.headline)
                Link(destination: challenge.verificationURI) {
                    HStack(spacing: 3) {
                        Text("GitHub")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.headline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: 8) {
                Text(challenge.userCode)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .tracking(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    controller.copyDeviceFlowUserCode()
                    withAnimation(.easeInOut(duration: 0.15)) { justCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeInOut(duration: 0.15)) { justCopied = false }
                    }
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(justCopied ? Color.green : (isHoveringCopy ? Color.primary : Color.secondary))
                        .frame(width: 22, height: 22)
                        .scaleEffect(isHoveringCopy && !justCopied ? 1.2 : 1.0)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) { isHoveringCopy = hovering }
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                if !expiryTimeRemaining.isEmpty {
                    Text(expiryTimeRemaining)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Button(GitHubSignInView.Copy.cancelSignIn) {
                controller.cancelDeviceFlowSignIn()
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.tertiary)
        }
    }

    private var loadingAppContent: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(GitHubSignInView.Copy.loadingTitle)
                .font(.headline)
            Text(GitHubSignInView.Copy.loadingDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func updateExpiryLabel(challenge: DeviceFlowChallenge) {
        let remaining = challenge.expiresAt.timeIntervalSinceNow
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

private struct PullRequestListView: View {
    enum Layout {
        static let controlsHeight: CGFloat = 40
    }

    enum Mode {
        case authored
        case reviewRequests
    }

    @ObservedObject var controller: DashboardController
    let mode: Mode
    let dismissSignal: Int
    @State private var dropdownState = PullRequestMenuDropdownState()

    init(
        controller: DashboardController,
        mode: Mode,
        dismissSignal: Int = 0
    ) {
        self.controller = controller
        self.mode = mode
        self.dismissSignal = dismissSignal
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                toolbarControls
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .background {
                        if dropdownState.openMenu != nil {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    dropdownState.dismiss()
                                }
                        }
                    }

                content
            }

            if dropdownState.openMenu != nil {
                outsideDropdownDismissArea
            }

            if dropdownState.openMenu == .filter {
                filterMenu
                    .padding(.top, 40)
                    .padding(.trailing, 110)
                    .zIndex(3)
            }

            if dropdownState.openMenu == .sort {
                sortMenu
                    .padding(.top, 40)
                    .padding(.trailing, 12)
                    .zIndex(3)
            }
        }
        .onChange(of: dismissSignal) { _, _ in
            dismissTransientControls()
        }
    }

    private var visiblePullRequests: [PullRequest] {
        switch mode {
        case .authored:
            controller.sortedMyPullRequests
        case .reviewRequests:
            controller.sortedReviewRequests
        }
    }

    @ViewBuilder
    private var content: some View {
        if controller.showsGitHubAppRepositoryAccessPrompt {
            GitHubAppRepositoryAccessPrompt(controller: controller)
        } else if !hasSourcePullRequests {
            EmptyMenuState(text: emptyText)
        } else if visiblePullRequests.isEmpty {
            EmptyMenuState(text: PullRequestListCopy.noFilterMatches)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(visiblePullRequests) { pr in
                        PullRequestRow(
                            pullRequest: pr,
                            isAttention: controller.isUnreadPullRequest(pr),
                            isPinned: controller.isPinned(pr),
                            showsReviewRequestKind: mode == .reviewRequests,
                            showsAuthor: mode == .reviewRequests,
                            togglePin: {
                                controller.togglePin(pr)
                            }
                        ) {
                            controller.openPullRequest(pr)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 5)
                .padding(.bottom, 12)
            }
            .simultaneousGesture(TapGesture().onEnded {
                dismissTransientControls()
            })
        }
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

    private var visibleCountLabel: String {
        CountSearchPresentation.countLabel(for: visiblePullRequests.count, singular: "PR", plural: "PRs")
    }

    private var visibleCount: some View {
        Text("\(visiblePullRequests.count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .accessibilityLabel(visibleCountLabel)
    }

    @ViewBuilder
    private var toolbarControls: some View {
        HStack(spacing: 8) {
            visibleCount
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissTransientControls()
                }
            filterButton
            sortButton
        }
    }

    private var outsideDropdownDismissArea: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: Layout.controlsHeight)
                .allowsHitTesting(false)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    dropdownState.dismiss()
                }
        }
    }

    private var filterButton: some View {
        optionButton(
            symbolName: "line.3.horizontal.decrease",
            title: filterButtonTitle,
            isOpen: dropdownState.openMenu == .filter,
            help: "Filter pull requests"
        ) {
            dropdownState.toggle(.filter)
        }
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
            directionSymbolName: controller.pullRequestSortDirection.isAscending ? "arrow.up" : "arrow.down",
            title: controller.pullRequestSortOption.label,
            isMenuOpen: dropdownState.openMenu == .sort,
            directionHelp: controller.pullRequestSortDirection.isAscending ? "Sorted oldest first" : "Sorted newest first",
            menuHelp: "Sort pull requests",
            toggleDirection: {
                controller.pullRequestSortDirection = controller.pullRequestSortDirection.toggled
            },
            openMenu: {
                dropdownState.toggle(.sort)
            }
        )
    }

    private func dismissTransientControls() {
        dropdownState.dismiss()
    }

    private func optionButton(
        symbolName: String,
        title: String,
        isOpen: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        MenuControlButton(
            symbolName: symbolName,
            title: title,
            isOpen: isOpen,
            help: help,
            action: action
        )
    }

    @ViewBuilder
    private var filterMenu: some View {
        switch mode {
        case .authored:
            optionMenu(width: 156) {
                ForEach(DashboardController.PullRequestFilterOption.allCases) { option in
                    optionMenuButton(
                        title: option.label,
                        isSelected: pullRequestFilterIsSelected(option),
                        width: 156
                    ) {
                        togglePullRequestFilter(option)
                    }
                }
            }
        case .reviewRequests:
            optionMenu(width: 112) {
                ForEach(DashboardController.ReviewRequestFilterOption.allCases) { option in
                    optionMenuButton(
                        title: option.label,
                        isSelected: reviewRequestFilterIsSelected(option),
                        width: 112
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
        optionMenu(width: 132) {
            ForEach(DashboardController.PullRequestSortOption.allCases) { option in
                optionMenuButton(
                    title: option.label,
                    isSelected: controller.pullRequestSortOption == option,
                    width: 132
                ) {
                    controller.pullRequestSortOption = option
                    dropdownState.dismiss()
                }
            }
        }
    }

    private func optionMenu<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
        }
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .shadow(radius: 8, y: 3)
        .zIndex(1)
    }

    private func optionMenuButton(
        title: String,
        isSelected: Bool,
        width: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark" : "")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 12)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .frame(width: width, height: 24, alignment: .leading)
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: action) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .center, spacing: 6) {
                            Image(systemName: iconName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 15)
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(notification.repo)#\(notification.prNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(notification.prTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    Text(NotificationTimestampPresentation.label(for: notification.prUpdatedAt))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(10)
                .transparentCardStyle(
                    accentColor: notification.read ? nil : .accentColor,
                    isHovered: isHovered
                )
            }
            .buttonStyle(.plain)

            if isHovered && !notification.read {
                Button(action: onMarkRead) {
                    Image(systemName: NotificationReadPresentation.symbolName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 22, height: 22)
                        .background(.regularMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .help(NotificationReadPresentation.markOneHelp)
                .accessibilityLabel(NotificationReadPresentation.markPRAccessibilityLabel)
            }
        }
        .onHover { isHovered = $0 }
    }

    private var title: String {
        PullRequestNotificationTitlePresentation.title(for: notification)
    }

    private var iconName: String {
        switch notification.eventType {
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

}

private struct GitHubInboxNotificationRow: View {
    let notification: GitHubInboxNotification
    let action: () -> Void
    let onMarkRead: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: action) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .center, spacing: 6) {
                            Image(systemName: iconName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 15)
                            Text(notification.subjectTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(notification.repo)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("\(notification.subjectType) · \(notification.reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    Text(NotificationTimestampPresentation.label(for: notification.updatedAt))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(10)
                .transparentCardStyle(
                    accentColor: notification.unread ? .accentColor : nil,
                    isHovered: isHovered
                )
            }
            .buttonStyle(.plain)

            if isHovered && notification.unread {
                Button(action: onMarkRead) {
                    Image(systemName: NotificationReadPresentation.symbolName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 22, height: 22)
                        .background(.regularMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .help(NotificationReadPresentation.markOneHelp)
                .accessibilityLabel(NotificationReadPresentation.markOtherAccessibilityLabel)
            }
        }
        .onHover { isHovered = $0 }
    }

    private var iconName: String {
        switch notification.subjectType {
        case "Issue":
            "record.circle"
        case "Discussion":
            "bubble.left.and.bubble.right"
        case "Release":
            "tag"
        case "Commit":
            "arrow.triangle.branch"
        case "CheckSuite":
            "checkmark.circle"
        case "RepositoryVulnerabilityAlert":
            "exclamationmark.shield"
        default:
            "tray"
        }
    }

}

private struct PullRequestRow: View {
    let pullRequest: PullRequest
    let isAttention: Bool
    let isPinned: Bool
    var showsReviewRequestKind = false
    var showsAuthor = false
    let togglePin: () -> Void
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            if pullRequest.draft {
                                DraftPullRequestIndicator()
                            }
                            Text(pullRequest.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        ReviewDecisionIndicator(reviewDecision: pullRequest.reviewDecision)
                            .alignmentGuide(.firstTextBaseline) { $0.height - 4 }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(pullRequest.repo)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("·")
                            .fixedSize()
                        Text("#\(pullRequest.number)")
                            .fixedSize()
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        Text(PullRequestAgePresentation.shortText(for: pullRequest.updatedAt))
                            .fixedSize()
                            .layoutPriority(1)
                            .help(PullRequestAgePresentation.label(for: pullRequest.updatedAt))
                    }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(PullRequestRowMetadataPresentation.branchText(for: pullRequest))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if showsAuthor {
                            Text("·")
                                .fixedSize()
                            Text("@\(pullRequest.author)")
                                .lineLimit(1)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                        Spacer(minLength: 0)
                    }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        CIStatusIndicator(ciState: pullRequest.ciState)
                        if pullRequest.commentCount > 0 {
                            CommentCountIndicator(count: pullRequest.commentCount)
                        }
                        if showsReviewRequestKind {
                            ReviewRequestKindPill(kind: pullRequest.reviewRequestKind)
                            if pullRequest.isAssignedToViewer {
                                AssignedPullRequestPill()
                            }
                        }
                        Spacer(minLength: 28)
                    }
                }
                .padding(10)
                .transparentCardStyle(
                    accentColor: isAttention ? .accentColor : nil,
                    isHovered: isHovered
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                PullRequestPinButton(isPinned: isPinned, isVisible: isPinned || isHovered, action: togglePin)
                PullRequestLinkCopyButton(url: pullRequest.url)
            }
                .padding(.trailing, 2)
                .padding(.bottom, 5)
        }
        .onHover { isHovered = $0 }
    }
}

private struct PullRequestPinButton: View {
    let isPinned: Bool
    let isVisible: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: PullRequestPinPresentation.symbolName(isPinned: isPinned || isHovered))
                .font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(PullRequestPinPresentation.rotationDegrees))
                .frame(width: PullRequestActionButtonLayout.iconSize, height: PullRequestActionButtonLayout.iconSize)
                .offset(x: PullRequestActionButtonLayout.pinGlyphOffsetX)
                .frame(width: PullRequestActionButtonLayout.hitSize, height: PullRequestActionButtonLayout.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .onHover { isHovered = $0 }
        .help(PullRequestPinPresentation.label(isPinned: isPinned))
        .accessibilityLabel(PullRequestPinPresentation.label(isPinned: isPinned))
        .accessibilityHidden(!isVisible)
    }
}

private enum PullRequestActionButtonLayout {
    static let iconSize: CGFloat = 22
    static let hitSize: CGFloat = 28
    static let pinGlyphOffsetX: CGFloat = 1
    static let copyGlyphOffsetX: CGFloat = -1
}

private struct DraftPullRequestIndicator: View {
    var body: some View {
        Image(systemName: "pencil")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .help("Draft PR")
            .accessibilityLabel("Draft PR")
    }
}

private struct TransparentCardStyle: ViewModifier {
    let accentColor: Color?
    let isHovered: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(restFill)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hoverFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var restFill: Color {
        colorScheme == .dark
            ? .clear
            : Color.white.opacity(0.5)
    }

    private var hoverFill: Color {
        HoverFillPresentation.fill(isHovered: isHovered, colorScheme: colorScheme)
    }

    private var borderColor: Color {
        if let accentColor {
            return accentColor
        }

        return MenuControlBorderPresentation.color(colorScheme: colorScheme)
    }
}

private extension View {
    func transparentCardStyle(accentColor: Color?, isHovered: Bool) -> some View {
        modifier(TransparentCardStyle(accentColor: accentColor, isHovered: isHovered))
    }
}

private struct ReviewRequestKindPill: View {
    let kind: ReviewRequestKind

    var body: some View {
        ForEach(presentations, id: \.text) { presentation in
            StatusPill(text: presentation.text, kind: .neutral)
                .help(presentation.accessibilityLabel)
                .accessibilityLabel(presentation.accessibilityLabel)
        }
    }

    private var presentations: [(text: String, accessibilityLabel: String)] {
        switch kind {
        case .none:
            []
        case .direct:
            [(text: "direct", accessibilityLabel: "Direct review request")]
        case .team:
            [(text: "team", accessibilityLabel: "Team review request")]
        case .directAndTeam:
            [
                (text: "direct", accessibilityLabel: "Direct review request"),
                (text: "team", accessibilityLabel: "Team review request")
            ]
        }
    }
}

private struct AssignedPullRequestPill: View {
    var body: some View {
        StatusPill(text: "assigned", kind: .neutral)
            .help("Assigned PR")
            .accessibilityLabel("Assigned PR")
    }
}

struct PullRequestLinkCopyButton: View {
    let url: URL

    @State private var isHovered = false

    var body: some View {
        Button {
            copyToPasteboard(url)
        } label: {
            Image(systemName: isHovered ? "doc.on.doc.fill" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: PullRequestActionButtonLayout.iconSize, height: PullRequestActionButtonLayout.iconSize)
                .offset(x: PullRequestActionButtonLayout.copyGlyphOffsetX)
                .frame(width: PullRequestActionButtonLayout.hitSize, height: PullRequestActionButtonLayout.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovered = $0 }
        .help("Copy PR link")
        .accessibilityLabel("Copy PR link")
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

struct CommentCountIndicator: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "bubble.left")
                .font(.system(size: 11, weight: .semibold))
            Text("\(count)")
                .font(.caption2.weight(.semibold))
        }
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
        case running
        case successful
        case unknown

        init(ciState: CIState) {
            switch ciState {
            case .failing:
                self = .failing
            case .pending:
                self = .running
            case .passing:
                self = .successful
            case .unknown:
                self = .unknown
            }
        }
    }

    let ciState: CIState

    var body: some View {
        Image(systemName: kind.symbolName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(kind.color)
            .font(.system(size: kind.pointSize, weight: .semibold))
            .frame(width: 17, height: 17)
            .accessibilityLabel(kind.label)
            .help(kind.label)
    }

    private var kind: Kind {
        Kind(ciState: ciState)
    }
}

private extension CIStatusIndicator.Kind {
    var symbolName: String {
        switch self {
        case .failing:
            "xmark.octagon.fill"
        case .running:
            "clock.fill"
        case .successful:
            "checkmark.circle.fill"
        case .unknown:
            "questionmark.circle"
        }
    }

    // clock.fill is a standalone symbol whose disc renders larger than the
    // enclosed .circle.fill/.octagon.fill glyphs at the same size, so nudge it
    // down to keep every CI indicator optically the same size.
    var pointSize: CGFloat {
        switch self {
        case .running:
            11
        case .failing, .successful, .unknown:
            13
        }
    }

    var color: Color {
        switch self {
        case .failing:
            .red
        case .running:
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
        case .running:
            "CI running"
        case .successful:
            "CI successful"
        case .unknown:
            "CI status unknown"
        }
    }
}

struct ReviewDecisionIndicator: View {
    enum Kind: Equatable {
        case approved
        case changesRequested
        case reviewRequired
        case unknown

        init(reviewDecision: ReviewDecision) {
            switch reviewDecision {
            case .approved:
                self = .approved
            case .changesRequested:
                self = .changesRequested
            case .reviewRequired:
                self = .reviewRequired
            case .unknown:
                self = .unknown
            }
        }
    }

    let reviewDecision: ReviewDecision

    var body: some View {
        Image(systemName: kind.symbolName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(kind.color)
            .font(.system(size: kind.pointSize, weight: .semibold))
            .frame(width: 17, height: 17)
            .accessibilityLabel(kind.label)
            .help(kind.label)
    }

    private var kind: Kind {
        Kind(reviewDecision: reviewDecision)
    }
}

private extension ReviewDecisionIndicator.Kind {
    var symbolName: String {
        switch self {
        case .approved:
            "checkmark.seal.fill"
        case .changesRequested:
            "exclamationmark.triangle.fill"
        case .reviewRequired:
            "eye.fill"
        case .unknown:
            "questionmark.diamond.fill"
        }
    }

    // eye.fill is a wide standalone symbol that reads larger than the enclosed
    // seal/triangle/diamond glyphs at the same size, so nudge it down to keep
    // every review-decision indicator optically the same size.
    var pointSize: CGFloat {
        switch self {
        case .reviewRequired:
            11
        case .approved, .changesRequested, .unknown:
            13
        }
    }

    var color: Color {
        switch self {
        case .approved:
            .green
        case .changesRequested:
            .red
        case .reviewRequired:
            .secondary
        case .unknown:
            .secondary
        }
    }

    var label: String {
        switch self {
        case .approved:
            "Review approved"
        case .changesRequested:
            "Changes requested"
        case .reviewRequired:
            "Review required"
        case .unknown:
            "Review status unknown"
        }
    }
}

private struct StatusPill: View {
    enum Kind {
        case neutral
        case attention
        case bad
    }

    let text: String
    let kind: Kind

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch kind {
        case .neutral: Color(nsColor: .quaternaryLabelColor)
        case .attention: Color.blue.opacity(0.14)
        case .bad: Color.red.opacity(0.14)
        }
    }

    private var foreground: Color {
        switch kind {
        case .neutral: .secondary
        case .attention: .blue
        case .bad: .red
        }
    }
}

private struct EmptyMenuState: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GitHubAppRepositoryAccessPrompt: View {
    @ObservedObject var controller: DashboardController
    var minHeight: CGFloat? = nil

    private struct ContextRow {
        let icon: String
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(systemName: headerIconName)
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(GitHubAppRepositoryAccessCopy.title(for: controller.gitHubAppRepositoryAccessStatus))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    contextBox

                    Button { controller.openGitHubAppInstallation() } label: {
                        HStack(spacing: 6) {
                            if let mark = GitHubSignInView.gitHubMarkImage {
                                Image(nsImage: mark)
                                    .resizable()
                                    .renderingMode(.template)
                                    .frame(width: 14, height: 14)
                            }
                            Text(GitHubAppRepositoryAccessCopy.buttonTitle)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 30)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 340)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)

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
        .background(Color.gray.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.gray.opacity(0.22), lineWidth: 1))
    }

    private func noteRow(icon: String, text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct GitHubInboxUnavailableState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(GitHubInboxUnavailableCopy.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(GitHubInboxUnavailableCopy.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}
