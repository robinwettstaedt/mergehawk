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
    var expandedWidth: CGFloat?
    @State private var searchFieldFocused = false

    var body: some View {
        HStack(spacing: 7) {
            if searchState.isExpanded {
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
                        searchFieldFocused = true
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: searchState.isExpanded)
        .onExitCommand {
            searchState.handleEscape()
            if !searchState.isExpanded {
                searchFieldFocused = false
            }
        }
    }

    private var expandedSearchControls: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TransparentSearchTextField(
                text: $searchState.query,
                placeholder: placeholder,
                isFocused: $searchFieldFocused
            ) {
                searchState.blur()
            }
            .accessibilityLabel(help)
            .frame(height: 16)
            .onChange(of: searchState.isExpanded) { _, isExpanded in
                if !isExpanded {
                    searchFieldFocused = false
                }
            }
            if searchState.hasActiveQuery {
                Text(countLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(width: expandedWidth)
        .frame(maxWidth: expandedWidth == nil ? .infinity : nil)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    searchFieldFocused ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor).opacity(0.55),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct TransparentSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let onBlur: () -> Void

    init(
        text: Binding<String>,
        placeholder: String,
        isFocused: Binding<Bool>,
        onBlur: @escaping () -> Void
    ) {
        _text = text
        _isFocused = isFocused
        self.placeholder = placeholder
        self.onBlur = onBlur
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
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

        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }

        if isFocused, field.window?.firstResponder !== field.currentEditor() {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                Self.configureEditor(for: field)
            }
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
        }
    }

    private static func configureEditor(for field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else {
            return
        }
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.insertionPointColor = .controlAccentColor
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var onBlur: () -> Void

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

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isOpen ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: Self.Layout.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(help)
        .accessibilityLabel(help)
    }
}

enum PullRequestSearch {
    static func filtered(_ pullRequests: [PullRequest], query: String) -> [PullRequest] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return pullRequests
        }

        return pullRequests.filter { pr in
            matches(pr.title, query: query)
                || matches(pr.repo, query: query)
                || matches(pr.author, query: query)
                || matches(pr.headRefName, query: query)
        }
    }

    private static func matches(_ value: String, query: String) -> Bool {
        value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

enum PullRequestListCopy {
    static let emptyAuthored = "No authored PRs."
    static let emptyReviewRequests = "No review requests."
    static let noMatches = "No matching PRs."
}

struct MenuRootView: View {
    enum Layout {
        static let width: CGFloat = 420
        static let height: CGFloat = 650
        static let topBarHeight: CGFloat = 45
        static let tabSwitcherWidth: CGFloat = 324
        static let tabSwitcherLeadingInset: CGFloat = 5
        static let notificationTabSegmentWidth: CGFloat = 64
        static let textTabSegmentWidth: CGFloat = (tabSwitcherWidth - notificationTabSegmentWidth) / 2
    }

    @ObservedObject var controller: DashboardController
    var initialAuthoredSearchState = ExpandableSearchState()
    var initialReviewRequestSearchState = ExpandableSearchState()
    @State private var dismissTransientPRControlsSignal = 0

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.Layout.width, height: Self.Layout.height)
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
                width: 40,
                showsIndicator: false
            )
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
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
                    initialSearchState: initialAuthoredSearchState,
                    dismissSignal: dismissTransientPRControlsSignal
                )
            case .reviewRequests:
                PullRequestListView(
                    controller: controller,
                    mode: .reviewRequests,
                    initialSearchState: initialReviewRequestSearchState,
                    dismissSignal: dismissTransientPRControlsSignal
                )
            }
        }
    }

    private func dismissTransientPRControls() {
        dismissTransientPRControlsSignal += 1
    }

}

struct RefreshStatusControl: View {
    enum Layout {
        static let width: CGFloat = 82
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
    var showsIndicator = true

    var body: some View {
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
    private var refreshControl: some View {
        if isRefreshing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        } else {
            let button = Button(action: action) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
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
}

private struct MenuTabSegmentedControl: NSViewRepresentable {
    @Binding var selection: DashboardController.MenuTab
    let attentionCount: Int

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: Array(repeating: "", count: DashboardController.MenuTab.allCases.count),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectTab(_:))
        )
        control.segmentStyle = .rounded
        control.controlSize = .regular
        for (index, tab) in DashboardController.MenuTab.allCases.enumerated() {
            configure(control, segment: index, for: tab)
        }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = DashboardController.MenuTab.allCases.firstIndex(of: selection) ?? 0
        for (index, tab) in DashboardController.MenuTab.allCases.enumerated() {
            configure(control, segment: index, for: tab)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject {
        var selection: Binding<DashboardController.MenuTab>

        init(selection: Binding<DashboardController.MenuTab>) {
            self.selection = selection
        }

        @objc func selectTab(_ sender: NSSegmentedControl) {
            guard DashboardController.MenuTab.allCases.indices.contains(sender.selectedSegment) else {
                return
            }
            selection.wrappedValue = DashboardController.MenuTab.allCases[sender.selectedSegment]
        }
    }

    private func configure(
        _ control: NSSegmentedControl,
        segment index: Int,
        for tab: DashboardController.MenuTab
    ) {
        switch tab {
        case .notifications:
            control.setLabel(MenuNotificationTabPresentation.label(for: attentionCount), forSegment: index)
            control.setImage(MenuNotificationTabPresentation.image(for: attentionCount), forSegment: index)
            control.setWidth(MenuRootView.Layout.notificationTabSegmentWidth, forSegment: index)
            control.setToolTip(MenuTabShortcutHint.title(for: tab), forSegment: index)
        case .myPRs, .reviewRequests:
            control.setLabel(tab.rawValue, forSegment: index)
            control.setImage(nil, forSegment: index)
            control.setWidth(MenuRootView.Layout.textTabSegmentWidth, forSegment: index)
            control.setToolTip(MenuTabShortcutHint.title(for: tab), forSegment: index)
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

    static func image(for attentionCount: Int) -> NSImage? {
        let image = NSImage(
            systemSymbolName: "bell",
            accessibilityDescription: help(for: attentionCount)
        )
        image?.isTemplate = true
        return image
    }
}

private struct NotificationListView: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                NotificationSubtabSegmentedControl(selection: $controller.selectedNotificationSubtab)
                    .frame(width: 104, height: 18)

                Spacer()

                if hasNotifications {
                    MenuControlButton(
                        symbolName: "envelope.open",
                        title: "Mark all read",
                        isOpen: false,
                        help: "Mark all notifications read"
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
            if controller.visiblePullRequestNotifications.isEmpty {
                EmptyMenuState(text: "No PR notifications.")
            } else {
                ScrollView {
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
                EmptyMenuState(text: "No other GitHub notifications.")
            } else {
                ScrollView {
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

private struct NotificationSubtabSegmentedControl: NSViewRepresentable {
    @Binding var selection: DashboardController.NotificationSubtab

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: DashboardController.NotificationSubtab.allCases.map(\.rawValue),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectSubtab(_:))
        )
        control.segmentStyle = .rounded
        control.controlSize = .mini
        control.font = .systemFont(ofSize: 10.5, weight: .medium)
        for index in DashboardController.NotificationSubtab.allCases.indices {
            control.setWidth(52, forSegment: index)
        }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = DashboardController.NotificationSubtab.allCases.firstIndex(of: selection) ?? 0
        for index in DashboardController.NotificationSubtab.allCases.indices {
            control.setWidth(52, forSegment: index)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject {
        var selection: Binding<DashboardController.NotificationSubtab>

        init(selection: Binding<DashboardController.NotificationSubtab>) {
            self.selection = selection
        }

        @objc func selectSubtab(_ sender: NSSegmentedControl) {
            guard DashboardController.NotificationSubtab.allCases.indices.contains(sender.selectedSegment) else {
                return
            }
            selection.wrappedValue = DashboardController.NotificationSubtab.allCases[sender.selectedSegment]
        }
    }
}

struct GitHubSignInView: View {
    enum Copy {
        static let title = "Connect GitHub"
        static let buttonTitle = "Sign in with GitHub"
        static let permissionText = "MergeHawk requests GitHub OAuth access for PRs and notifications. It only reads GitHub data."
    }

    @ObservedObject var controller: DashboardController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Text(Self.Copy.title)
                    .font(.headline)
                Text(Self.Copy.permissionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(Self.Copy.buttonTitle) {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isRefreshing)

                if controller.isRefreshing {
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

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func connect() {
        Task {
            await controller.signInWithGitHub()
        }
    }
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
    @State private var searchState = ExpandableSearchState()

    init(
        controller: DashboardController,
        mode: Mode,
        initialSearchState: ExpandableSearchState = ExpandableSearchState(),
        dismissSignal: Int = 0
    ) {
        self.controller = controller
        self.mode = mode
        self.dismissSignal = dismissSignal
        _searchState = State(initialValue: initialSearchState)
    }

    var body: some View {
        if !hasSourcePullRequests {
            EmptyMenuState(text: emptyText)
        } else {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    toolbarControls
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    ScrollView {
                        if visiblePullRequests.isEmpty {
                            EmptyMenuState(text: PullRequestListCopy.noMatches)
                                .frame(minHeight: 520)
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(visiblePullRequests) { pr in
                                    PullRequestRow(
                                        pullRequest: pr,
                                        isAttention: controller.isUnreadPullRequest(pr),
                                        showsReviewRequestKind: mode == .reviewRequests
                                    ) {
                                        controller.open(pr.url)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 5)
                            .padding(.bottom, 12)
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        dismissTransientControls()
                    })
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
    }

    private var visiblePullRequests: [PullRequest] {
        PullRequestSearch.filtered(pullRequests, query: searchState.query)
    }

    private var pullRequests: [PullRequest] {
        switch mode {
        case .authored:
            controller.sortedMyPullRequests
        case .reviewRequests:
            controller.sortedReviewRequests
        }
    }

    private var hasSourcePullRequests: Bool {
        switch mode {
        case .authored:
            !controller.sourceFilteredMyPullRequests.isEmpty
        case .reviewRequests:
            controller.sourceFilteredReviewRequests.contains { $0.reviewRequestKind != .none }
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

    private var searchControls: some View {
        CountSearchControl(
            searchState: $searchState,
            countLabel: visibleCountLabel,
            placeholder: "Search PRs...",
            help: "Search PRs"
        )
        .simultaneousGesture(TapGesture().onEnded {
            dropdownState.dismiss()
        })
    }

    @ViewBuilder
    private var toolbarControls: some View {
        if searchState.isExpanded {
            HStack(spacing: 8) {
                searchControls
                filterButton
                sortButton
            }
        } else {
            HStack(spacing: 0) {
                searchControls
                Spacer(minLength: 0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissTransientControls()
                    }
                HStack(spacing: 8) {
                    filterButton
                    sortButton
                }
            }
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
            searchState.blur()
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
        optionButton(
            symbolName: "arrow.up.arrow.down",
            title: controller.pullRequestSortOption.label,
            isOpen: dropdownState.openMenu == .sort,
            help: "Sort pull requests"
        ) {
            searchState.blur()
            dropdownState.toggle(.sort)
        }
    }

    private func dismissTransientControls() {
        dropdownState.dismiss()
        searchState.blur()
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
                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Text("\(notification.repo)#\(notification.prNumber) · \(notification.prTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(notification.read ? Color.clear : Color.blue, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if isHovered && !notification.read {
                Button(action: onMarkRead) {
                    Image(systemName: "xmark")
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
                .help("Mark read")
                .accessibilityLabel("Mark PR notification read")
            }
        }
        .onHover { isHovered = $0 }
    }

    private var title: String {
        switch notification.eventType {
        case .newComment:
            "\(notification.count ?? 1) new comment\(notification.count == 1 ? "" : "s")"
        case .newReview:
            "\(notification.count ?? 1) new review\(notification.count == 1 ? "" : "s")"
        case .ciFailed:
            "CI failed"
        case .changesRequested:
            "Changes requested"
        }
    }

    private var iconName: String {
        switch notification.eventType {
        case .newComment: "text.bubble"
        case .newReview: "checkmark.seal"
        case .ciFailed: "xmark.octagon"
        case .changesRequested: "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch notification.eventType {
        case .newComment, .newReview: .blue
        case .ciFailed, .changesRequested: .red
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
                    Image(systemName: iconName)
                        .foregroundStyle(notification.unread ? Color.purple : Color.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notification.subjectTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text("\(notification.repo) · \(notification.subjectType) · \(notification.reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(notification.unread ? Color.purple : Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if isHovered && notification.unread {
                Button(action: onMarkRead) {
                    Image(systemName: "xmark")
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
                .help("Mark read")
                .accessibilityLabel("Mark other notification read")
            }
        }
        .onHover { isHovered = $0 }
    }

    private var iconName: String {
        switch notification.subjectType {
        case "Issue": "record.circle"
        case "Discussion": "bubble.left.and.bubble.right"
        case "Release": "tag"
        default: "tray"
        }
    }
}

private struct PullRequestRow: View {
    let pullRequest: PullRequest
    let isAttention: Bool
    var showsReviewRequestKind = false
    let action: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(pullRequest.repo)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("#\(pullRequest.number)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(pullRequest.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        CIStatusIndicator(ciState: pullRequest.ciState)
                        ReviewDecisionIndicator(reviewDecision: pullRequest.reviewDecision)
                        CommentCountIndicator(count: pullRequest.commentCount)
                        if pullRequest.draft {
                            StatusPill(text: "Draft", kind: .neutral)
                                .help("Draft PR")
                                .accessibilityLabel("Draft PR")
                        }
                        if showsReviewRequestKind {
                            ReviewRequestKindPill(kind: pullRequest.reviewRequestKind)
                        }
                        if isAttention {
                            StatusPill(text: "new", kind: .attention)
                        }
                        Spacer(minLength: 28)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isAttention ? Color.blue : Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            PullRequestLinkCopyButton(url: pullRequest.url)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
        }
    }
}

private struct ReviewRequestKindPill: View {
    let kind: ReviewRequestKind

    var body: some View {
        if kind != .none {
            StatusPill(text: label, kind: .neutral)
                .help(accessibilityLabel)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var label: String {
        switch kind {
        case .none:
            ""
        case .direct:
            "direct"
        case .team:
            "team"
        case .directAndTeam:
            "direct+team"
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .none:
            "No review request"
        case .direct:
            "Direct review request"
        case .team:
            "Team review request"
        case .directAndTeam:
            "Direct and team review request"
        }
    }
}

struct PullRequestLinkCopyButton: View {
    let url: URL

    var body: some View {
        Button {
            copyToPasteboard(url)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
        "\(count) comment\(count == 1 ? "" : "s")"
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
        Circle()
            .fill(kind.color)
            .frame(width: 10, height: 10)
            .accessibilityLabel(kind.label)
            .help(kind.label)
    }

    private var kind: Kind {
        Kind(ciState: ciState)
    }
}

private extension CIStatusIndicator.Kind {
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
            .font(.caption.weight(.semibold))
            .frame(width: 16, height: 16)
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

    var color: Color {
        switch self {
        case .approved:
            .green
        case .changesRequested:
            .red
        case .reviewRequired:
            .orange
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
