import mergehawkcore
import SwiftUI

/// The stack control on a requested stack card: stack symbol, "‹position›/‹size›", and an expand or collapse
/// chevron. Other review requests and filter-excluded requests appear only in the tooltip.
struct StackControlPresentation: Equatable {
    static let stackSymbolName = "square.stack"
    static let collapsedChevronSymbolName = "chevron.down"
    static let expandedChevronSymbolName = "chevron.up"

    let stackID: String
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
        stackID = group.stack.id
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
        .anchorPreference(key: StackControlAnchorsKey.self, value: .bounds) {
            [presentation.stackID: StackControlAnchor(bounds: $0, fractionText: presentation.fractionText)]
        }
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

/// A stack control's frame and fraction, reported per stack so tests can check that it stays put on toggle.
struct StackControlAnchor {
    let bounds: Anchor<CGRect>
    let fractionText: String
}

struct StackControlAnchorsKey: PreferenceKey {
    static var defaultValue: [String: StackControlAnchor] { [:] }

    static func reduce(value: inout [String: StackControlAnchor], nextValue: () -> [String: StackControlAnchor]) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// "· ‹position›/‹size›" at the end of the metadata line of an expanded row below the top row.
struct StackPositionLabel: View {
    let position: Int
    let size: Int

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.prRow.identityItemSpacing) {
            Text("·")
                .accessibilityHidden(true)
            Text("\(position)/\(size)")
                .monospacedDigit()
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stack position \(position) of \(size)")
        .anchorPreference(key: StackPositionLabelAnchorsKey.self, value: .bounds) { ["\(position)/\(size)": $0] }
    }
}

/// Each metadata stack position's frame, by its "‹position›/‹size›" text.
struct StackPositionLabelAnchorsKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// The badges on an expanded stack member's title line: Draft before the title, and on a context member its
/// state after the title.
enum StackMemberBadge: String, Equatable {
    case draft = "Draft"
    case open = "Open"
    case merged = "Merged"
    case closed = "Closed"

    var title: String { rawValue }

    struct Placement: Equatable {
        var beforeTitle: [StackMemberBadge]
        var afterTitle: [StackMemberBadge]
    }

    static func badges(for member: StackGroup.Member) -> Placement {
        switch member {
        case .requested(let pullRequest):
            Placement(beforeTitle: pullRequest.draft ? [.draft] : [], afterTitle: [])
        case .context(let entry):
            Placement(
                beforeTitle: entry.isDraft ? [.draft] : [],
                afterTitle: [{
                    switch entry.state {
                    case .open: .open
                    case .merged: .merged
                    case .closed: .closed
                    }
                }()]
            )
        }
    }
}

/// A title-line badge for a stack member. The text names the state; the tint only supports it.
struct StackMemberBadgeView: View {
    let badge: StackMemberBadge

    var body: some View {
        switch badge {
        case .draft:
            DraftPullRequestIndicator()
        case .open:
            PullRequestTitleBadge(text: badge.title, accessibilityLabel: "Open PR")
        case .merged:
            PullRequestTitleBadge(text: badge.title, accessibilityLabel: "Merged PR", tint: .purple)
        case .closed:
            PullRequestTitleBadge(text: badge.title, accessibilityLabel: "Closed PR", tint: .red)
        }
    }
}

/// An expanded stack group: one rounded container of borderless rows, position 1 (closest to the base branch)
/// first, with a hairline between rows. Each row keeps an ordinary card's height, so the container is exactly
/// as tall as its rows, and its top edge is where the collapsed card's top edge was.
struct StackMemberContainer<Row: View>: View {
    let group: StackGroup
    /// The group unread rule, the same signal the collapsed card shows.
    let isUnread: Bool
    @ViewBuilder let row: (_ member: StackGroup.Member, _ position: Int) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(group.members.enumerated()), id: \.element.pullRequestID) { index, member in
                row(member, group.position(of: member) ?? 0)
                    // Overlaid, so the divider adds no height.
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(height: MenuMetrics.hairline)
                                .accessibilityHidden(true)
                        }
                    }
                    .anchorPreference(key: StackMemberRowAnchorsKey.self, value: .bounds) { [member.pullRequestID: $0] }
            }
        }
        .transparentCardStyle(accentColor: isUnread ? .accentColor : nil, isHovered: false)
    }
}

/// Each expanded row's frame, by the member's PR ID, reported so tests can check heights, actions, and clicks.
struct StackMemberRowAnchorsKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
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

    private var badges: StackMemberBadge.Placement {
        StackMemberBadge.badges(for: .context(entry))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: metrics.prColumns.identityLineSpacing) {
            PullRequestTitleLine {
                ForEach(badges.beforeTitle, id: \.self) { badge in
                    // Badges keep their full width; only the title truncates.
                    StackMemberBadgeView(badge: badge)
                        .layoutPriority(1)
                        .pullRequestCardPart(.draftBadge)
                }
                Text(entry.title)
                    .font(metrics.type.cardTitle.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .pullRequestCardPart(.title)
                ForEach(badges.afterTitle, id: \.self) { badge in
                    StackMemberBadgeView(badge: badge)
                        .layoutPriority(1)
                        .pullRequestCardPart(.stateBadge)
                }
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
