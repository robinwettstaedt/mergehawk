import mergehawkcore
import SwiftUI

/// The stack control on a requested stack card: stack symbol, "‹position›/‹size›", and an expand or collapse
/// chevron. Other review requests and filter-excluded requests appear only in the tooltip.
struct StackControlPresentation: Equatable {
    static let stackSymbolName = "square.stack"
    static let collapsedChevronSymbolName = "chevron.down"
    static let expandedChevronSymbolName = "chevron.up"

    let fractionText: String
    /// Laid out hidden under the fraction, so every fraction of the stack takes the same width.
    let templateText: String
    let chevronSymbolName: String
    let tooltip: String

    var accessibilityLabel: String { tooltip }

    /// `displayedPosition` is the representative's position when collapsed, and the first displayed member's
    /// position when expanded.
    init(group: StackGroup, displayedPosition: Int, isExpanded: Bool) {
        let size = group.stack.size
        fractionText = "\(displayedPosition)/\(size)"
        let highest = max(size, group.stack.entries.map(\.position).max() ?? 0)
        let digits = String(repeating: "8", count: String(highest).count)
        templateText = "\(digits)/\(digits)"
        chevronSymbolName = isExpanded ? Self.expandedChevronSymbolName : Self.collapsedChevronSymbolName
        var parts = ["Stack", "position \(displayedPosition) of \(size)"]
        let additional = group.additionalRequestCount
        if additional > 0 {
            parts.append("\(additional) more review \(additional == 1 ? "request" : "requests")")
        }
        let excluded = group.filterExcludedRequestCount
        if excluded > 0 {
            parts.append("\(excluded) outside the current filter")
        }
        parts.append(isExpanded ? "Collapse stack" : "Expand stack")
        tooltip = parts.joined(separator: " · ")
    }
}

extension StackGroup {
    /// The position of the first displayed member of the expanded group, which is position 1 unless GitHub
    /// returned no readable entry there.
    var firstMemberPosition: Int {
        members.first.flatMap(position(of:)) ?? representativePosition
    }
}

/// A bordered button spanning the card's two identity lines. It keeps one size for its group in both states,
/// and it only toggles the group; it never opens a PR.
struct StackControl: View {
    let presentation: StackControlPresentation
    let toggle: () -> Void

    @State private var isHovered = false
    @Environment(\.menuMetrics) private var metrics
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let row = metrics.prRow
        let shape = RoundedRectangle(cornerRadius: row.stackControlCornerRadius, style: .continuous)
        Button(action: toggle) {
            HStack(spacing: row.stackControlSpacing) {
                Image(systemName: StackControlPresentation.stackSymbolName)
                    .font(metrics.type.stackControlSymbol.font)
                ZStack {
                    Text(presentation.templateText)
                        .hidden()
                    Text(presentation.fractionText)
                }
                .font(metrics.type.cardTitle.font.monospacedDigit())
                ZStack {
                    // Both chevrons, hidden, keep the width equal in both states.
                    Image(systemName: StackControlPresentation.collapsedChevronSymbolName)
                        .hidden()
                    Image(systemName: StackControlPresentation.expandedChevronSymbolName)
                        .hidden()
                    Image(systemName: presentation.chevronSymbolName)
                }
                .font(metrics.type.stackControlSymbol.font)
            }
            .lineLimit(1)
            .foregroundStyle(.primary)
            .padding(.horizontal, row.stackControlHorizontalPadding)
            .frame(height: row.stackControlHeight)
            .background {
                shape.fill(isHovered ? hoverFill : restFill)
            }
            .overlay {
                shape.strokeBorder(MenuControlBorderPresentation.color(colorScheme: colorScheme), lineWidth: 1)
            }
            // The whole bordered area, padding included, takes the click.
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .menuTooltip(presentation.tooltip, providesAccessibilityHint: false)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    // Stronger than a card's hover fill, so the control reads as its own target.
    private var restFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    }

    private var hoverFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.1)
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
