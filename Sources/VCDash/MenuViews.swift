import AppKit
import SwiftUI
import VCDashCore

struct MenuRootView: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        VStack(spacing: 0) {
            header
            tabSwitcher
            Divider()
            content
                .frame(minHeight: 260, maxHeight: 340)
        }
        .frame(width: 420)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(controller.hasAttention ? Color.red : Color.green)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.accountLabel)
                    .font(.headline)
                Text("\(controller.sourceLabel) · \(syncText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isRefreshing {
                ProgressView()
                    .controlSize(.small)
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
        .padding(14)
    }

    private var tabSwitcher: some View {
        Picker("", selection: $controller.selectedTab) {
            ForEach(DashboardController.MenuTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.selectedTab {
        case .notifications:
            NotificationListView(controller: controller)
        case .myPRs:
            PullRequestListView(
                controller: controller,
                pullRequests: controller.state.pullRequests.filter(\.isMine),
                emptyText: "No authored PRs."
            )
        }
    }

    private var syncText: String {
        guard let syncedAt = controller.state.syncedAt else {
            return "Not synced"
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

private struct PullRequestListView: View {
    @ObservedObject var controller: DashboardController
    let pullRequests: [PullRequest]
    let emptyText: String

    var body: some View {
        if pullRequests.isEmpty {
            EmptyMenuState(text: emptyText)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(pullRequests) { pr in
                        PullRequestRow(pullRequest: pr, isAttention: controller.state.events.contains { $0.prId == pr.id }) {
                            controller.open(pr.url)
                        }
                    }
                }
                .padding(12)
            }
        }
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
