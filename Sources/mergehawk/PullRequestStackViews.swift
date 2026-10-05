import mergehawkcore
import SwiftUI

/// The chip on a requested stack card: "‹position› of ‹size›" and "+N" other review requests in the stack.
struct StackChipPresentation: Equatable {
    static let stackSymbolName = "square.stack"

    let positionText: String
    /// "+N" when other open members also request the viewer's review; nil when N is 0.
    let additionalRequestsText: String?
    let chevronSymbolName: String
    let tooltip: String

    var accessibilityLabel: String { tooltip }

    init(group: StackGroup, isExpanded: Bool) {
        positionText = "\(group.representativePosition) of \(group.stack.size)"
        let additional = group.additionalRequestCount
        additionalRequestsText = additional > 0 ? "+\(additional)" : nil
        chevronSymbolName = isExpanded ? "chevron.down" : "chevron.right"
        var parts = ["Stack", positionText]
        if additional > 0 {
            parts.append("\(additional) more review \(additional == 1 ? "request" : "requests")")
        }
        let excluded = group.filterExcludedRequestCount
        if excluded > 0 {
            parts.append("\(excluded) outside the current filter")
        }
        tooltip = parts.joined(separator: " · ")
    }
}

struct StackChip: View {
    let presentation: StackChipPresentation
    let toggle: () -> Void

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: metrics.prRow.stackChipSpacing) {
                Image(systemName: StackChipPresentation.stackSymbolName)
                    .font(metrics.type.stackChipSymbol.font)
                Text(presentation.positionText)
                if let additional = presentation.additionalRequestsText {
                    Text(additional)
                        .foregroundStyle(Color.accentColor)
                }
                Image(systemName: presentation.chevronSymbolName)
                    .font(metrics.type.stackChipSymbol.font)
            }
            .font(metrics.type.cardMetadata.font)
            .lineLimit(1)
            .padding(.horizontal, metrics.prRow.stackChipHorizontalPadding)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .menuTooltip(presentation.tooltip, providesAccessibilityHint: false)
        .accessibilityLabel(presentation.accessibilityLabel)
        // The symbols are slightly taller than the metadata text; a zero layout height keeps the card height.
        .frame(height: 0)
    }
}

/// The badges before an expanded stack member's title, in display order.
enum StackMemberBadge: String, Equatable {
    case draft = "Draft"
    case reviewRequested = "Review requested"
    case merged = "Merged"
    case closed = "Closed"

    var title: String { rawValue }

    static func badges(for member: StackGroup.Member) -> [StackMemberBadge] {
        switch member {
        case .requested(let pullRequest):
            (pullRequest.draft ? [.draft] : []) + [.reviewRequested]
        case .context(let entry):
            (entry.isDraft ? [.draft] : []) + {
                switch entry.state {
                case .open: []
                case .merged: [.merged]
                case .closed: [.closed]
                }
            }()
        }
    }
}

/// An expanded stack group: one card per member, position 1 (closest to the base branch) first.
struct StackMemberList<Card: View>: View {
    let group: StackGroup
    @ViewBuilder let card: (_ member: StackGroup.Member, _ position: Int) -> Card

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.prColumns.rowSpacing) {
            ForEach(group.members, id: \.pullRequestID) { member in
                card(member, group.position(of: member) ?? 0)
            }
        }
        // A rail centered in the list's leading padding marks the group without moving the cards.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: metrics.prList.stackRailWidth)
                .alignmentGuide(.leading) { dimensions in
                    dimensions[.leading] + (metrics.prList.horizontalPadding + metrics.prList.stackRailWidth) / 2
                }
                .anchorPreference(key: StackMemberRailAnchorKey.self, value: .bounds) { $0 }
                .accessibilityHidden(true)
        }
        // A doubled row gap before and after separates the group from neighbouring cards.
        .padding(.vertical, metrics.prColumns.rowSpacing)
    }
}

/// The rail's frame, reported so tests can check that it spans the expanded group's member cards.
struct StackMemberRailAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// A dimmed card for a stack member MergeHawk only knows from the stack entry: no status and no actions.
struct StackContextCard: View {
    let entry: PullRequestStackEntry
    /// A stack lives in one repository, so its entries share the group's repository.
    let repo: String
    var chrome: PullRequestCardChrome = .card
    /// Shown directly before the changes column; it keeps full strength on the dimmed card.
    var stackControl: AnyView? = nil
    /// Shown at the end of the metadata line, after the PR number.
    var metadataAccessory: AnyView? = nil
    let action: () -> Void

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        PullRequestCardLayout(
            author: entry.author,
            authorAvatarURL: entry.authorAvatarURL,
            values: nil,
            isAttention: false,
            chrome: chrome,
            dimsAvatar: true,
            stackControl: stackControl,
            accessibilityLabel: "\(entry.title), \(entry.author), \(repo) #\(entry.number)",
            identity: { identity },
            actions: { EmptyView() },
            action: action
        )
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: metrics.prColumns.identityLineSpacing) {
            PullRequestTitleLine {
                ForEach(StackMemberBadge.badges(for: .context(entry)), id: \.self) { badge in
                    switch badge {
                    case .draft:
                        DraftPullRequestIndicator()
                    case .reviewRequested, .merged, .closed:
                        PullRequestTitleBadge(text: badge.title, accessibilityLabel: "\(badge.title) PR")
                    }
                }
                Text(entry.title)
                    .font(metrics.type.cardTitle.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .pullRequestCardPart(.title)
            }

            HStack(spacing: metrics.prRow.identityItemSpacing) {
                Text(entry.author)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text("·")
                    .fixedSize()
                    .accessibilityHidden(true)
                Text(repo)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("#\(entry.number)")
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                if let metadataAccessory {
                    metadataAccessory
                        .fixedSize()
                        .layoutPriority(2)
                }
            }
            .font(metrics.type.cardMetadata.font)
            .foregroundStyle(.tertiary)
            .pullRequestCardPart(.metadata)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
