import AppKit
import SwiftUI
import VCDashCore

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

struct MenuRootView: View {
    enum Layout {
        static let width: CGFloat = 420
        static let height: CGFloat = 650
        static let topBarHeight: CGFloat = 45
    }

    @ObservedObject var controller: DashboardController

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.Layout.width, height: Self.Layout.height)
        .background(.regularMaterial)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            if controller.state.authStatus == .signedIn {
                tabSwitcher
            } else {
                Text("VC Dash")
                    .font(.headline)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(controller.hasAttention ? Color.red : Color.green)
                        .frame(width: 10, height: 10)
                    if controller.state.authStatus == .signedIn {
                        refreshControl
                    }
                }
                Text("updated \(syncText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: Self.Layout.topBarHeight)
    }

    private var tabSwitcher: some View {
        Picker("", selection: $controller.selectedTab) {
            ForEach(DashboardController.MenuTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 196)
    }

    @ViewBuilder
    private var refreshControl: some View {
        if controller.isRefreshing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        } else {
            Button {
                controller.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
            .accessibilityLabel("Refresh")
        }
    }

    @ViewBuilder
    private var content: some View {
        if controller.state.authStatus == .signedOut {
            GitHubTokenSignInView(controller: controller)
        } else {
            switch controller.selectedTab {
            case .notifications:
                NotificationListView(controller: controller)
            case .myPRs:
                PullRequestListView(
                    controller: controller,
                    pullRequests: controller.sortedMyPullRequests,
                    emptyText: "No authored PRs."
                )
            }
        }
    }

    private var syncText: String {
        guard let syncedAt = controller.state.syncedAt else {
            return "never"
        }
        return syncedAt.formatted(date: .omitted, time: .shortened)
    }
}

private struct NotificationListView: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        let events = controller.state.events
        if events.isEmpty {
            EmptyMenuState(text: "No new notifications.")
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(events) { event in
                        if let pr = controller.state.pullRequests.first(where: { $0.id == event.prId }) {
                            NotificationRow(event: event, pullRequest: pr) {
                                controller.open(pr.url)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }
}

struct GitHubTokenSignInView: View {
    enum Copy {
        static let title = "Connect GitHub"
        static let fieldPrompt = "github_pat_..."
        static let buttonTitle = "Connect"
        static let pasteHelp = "Paste token"
    }

    @ObservedObject var controller: DashboardController
    @State private var token = ""
    @FocusState private var tokenFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Text(Self.Copy.title)
                    .font(.headline)
                Text("Paste a fine-grained personal access token to start syncing pull requests.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                SecureField(Self.Copy.fieldPrompt, text: $token)
                    .textFieldStyle(.roundedBorder)
                    .focused($tokenFieldFocused)
                    .onSubmit {
                        connect()
                    }

                Button {
                    pasteToken()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Self.Copy.pasteHelp)
                .accessibilityLabel(Self.Copy.pasteHelp)
                .keyboardShortcut("v", modifiers: .command)
            }

            HStack(spacing: 10) {
                Button(Self.Copy.buttonTitle) {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isRefreshing)

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
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                tokenFieldFocused = true
            }
        }
    }

    private func connect() {
        Task {
            await controller.signInWithToken(token)
            if controller.state.authStatus == .signedIn {
                token = ""
            }
        }
    }

    private func pasteToken() {
        token = Self.tokenString(from: NSPasteboard.general) ?? token
        tokenFieldFocused = true
    }

    static func tokenString(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct PullRequestListView: View {
    enum Layout {
        static let controlsHeight: CGFloat = 40
    }

    @ObservedObject var controller: DashboardController
    let pullRequests: [PullRequest]
    let emptyText: String
    @State private var dropdownState = PullRequestMenuDropdownState()

    var body: some View {
        if !hasAuthoredPullRequests {
            EmptyMenuState(text: emptyText)
        } else {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Spacer()
                        filterButton
                        sortButton
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    ScrollView {
                        if pullRequests.isEmpty {
                            EmptyMenuState(text: "No matching PRs.")
                                .frame(minHeight: 520)
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(pullRequests) { pr in
                                    PullRequestRow(pullRequest: pr, isAttention: controller.state.events.contains { $0.prId == pr.id }) {
                                        controller.open(pr.url)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
                    }
                }

                if dropdownState.openMenu != nil {
                    outsideDropdownDismissArea
                }

                if dropdownState.openMenu == .filter {
                    filterMenu
                        .padding(.top, 38)
                        .padding(.trailing, 86)
                        .zIndex(3)
                }

                if dropdownState.openMenu == .sort {
                    sortMenu
                        .padding(.top, 38)
                        .padding(.trailing, 12)
                        .zIndex(3)
                }
            }
        }
    }

    private var hasAuthoredPullRequests: Bool {
        controller.state.pullRequests.contains(where: \.isMine)
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
            title: controller.pullRequestFilterOption.label,
            isOpen: dropdownState.openMenu == .filter,
            help: "Filter pull requests"
        ) {
            dropdownState.toggle(.filter)
        }
    }

    private var sortButton: some View {
        optionButton(
            symbolName: "arrow.up.arrow.down",
            title: controller.pullRequestSortOption.label,
            isOpen: dropdownState.openMenu == .sort,
            help: "Sort pull requests"
        ) {
            dropdownState.toggle(.sort)
        }
    }

    private func optionButton(
        symbolName: String,
        title: String,
        isOpen: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isOpen ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(help)
        .accessibilityLabel(help)
    }

    private var filterMenu: some View {
        optionMenu(width: 156) {
            ForEach(DashboardController.PullRequestFilterOption.allCases) { option in
                optionMenuButton(
                    title: option.label,
                    isSelected: controller.pullRequestFilterOption == option,
                    width: 156
                ) {
                    controller.pullRequestFilterOption = option
                    dropdownState.dismiss()
                }
            }
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
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
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
            .font(.caption)
            .padding(.horizontal, 8)
            .frame(width: width, height: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NotificationRow: View {
    let event: PullRequestEvent
    let pullRequest: PullRequest
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text("\(pullRequest.repo)#\(pullRequest.number) · \(pullRequest.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch event.type {
        case .newComment:
            "\(event.count ?? 1) new comment\(event.count == 1 ? "" : "s")"
        case .newReview:
            "\(event.count ?? 1) new review\(event.count == 1 ? "" : "s")"
        case .ciFailed:
            "CI failed"
        case .changesRequested:
            "Changes requested"
        }
    }

    private var iconName: String {
        switch event.type {
        case .newComment: "text.bubble"
        case .newReview: "checkmark.seal"
        case .ciFailed: "xmark.octagon"
        case .changesRequested: "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch event.type {
        case .newComment, .newReview: .blue
        case .ciFailed, .changesRequested: .red
        }
    }
}

private struct PullRequestRow: View {
    let pullRequest: PullRequest
    let isAttention: Bool
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
