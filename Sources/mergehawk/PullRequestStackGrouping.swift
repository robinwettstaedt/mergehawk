import Foundation
import mergehawkcore

/// One card in a PR list: a standalone PR, or a stack group shown through its representative.
struct PullRequestListItem: Identifiable, Equatable {
    let representative: PullRequest
    let stack: StackGroup?
    let isPinned: Bool
    let isHidden: Bool
    let isUnread: Bool

    /// Stable while the representative changes: a stack card is identified by its stack, a standalone card by
    /// its PR. Unique because every PR is in at most one card and every stack in at most one card.
    var id: String {
        if let stack { "stack:\(stack.stack.id)" } else { representative.id }
    }
}

/// A stack's group in one PR list.
struct StackGroup: Equatable {
    enum Member: Equatable {
        /// A member shown as a full row in this list, whether or not it passes the list's filter.
        case full(PullRequest)
        /// Every other entry: open PRs that aren't members of this list, merged, and closed.
        case context(PullRequestStackEntry)

        var pullRequestID: String {
            switch self {
            case .full(let pullRequest): pullRequest.id
            case .context(let entry): entry.pullRequestID
            }
        }
    }

    let stack: PullRequestStack
    let representativePosition: Int
    /// Ignores the list's filter.
    let fullMemberIDs: Set<String>
    let matchingMemberIDs: Set<String>
    /// As GitHub lists the stack: the top (highest position) first, position 1 (closest to the base branch) last.
    let members: [Member]

    var additionalMemberCount: Int { fullMemberIDs.count - 1 }
    var filterExcludedMemberCount: Int { fullMemberIDs.count - matchingMemberIDs.count }

    func position(of member: Member) -> Int? {
        stack.entries.first { $0.pullRequestID == member.pullRequestID }?.position
    }
}

/// A section of a PR tab. A team section is identified by the team's node ID, so a renamed team keeps its section.
enum PullRequestSectionID: Hashable {
    case pinned
    case active
    case assigned
    case direct
    case team(id: String)
    case hidden

    /// Hidden starts collapsed, every other section expanded.
    var isExpandedByDefault: Bool { self != .hidden }
}

extension PullRequestSectionID: CustomStringConvertible {
    /// Used in row IDs, such as `heading:team:<team ID>`.
    var description: String {
        switch self {
        case .pinned: "pinned"
        case .active: "active"
        case .assigned: "assigned"
        case .direct: "direct"
        case .team(let id): "team:\(id)"
        case .hidden: "hidden"
        }
    }
}

/// A collapsible group of cards under a heading in a PR tab, sorted by the tab's sort option.
struct PullRequestListSection: Equatable {
    let id: PullRequestSectionID
    let title: String
    let accessibilityTitle: String
    let items: [PullRequestListItem]

    /// A stack card counts 1, however many PRs it holds.
    var count: Int { items.count }

    /// Team sections show the team slug, or `org/slug` when another counted team has the same slug. Accessibility
    /// always uses the full `@org/slug`.
    static func teamTitles(_ teams: [TeamReference]) -> [(title: String, accessibilityTitle: String)] {
        let slugCounts = Dictionary(teams.map { ($0.slug, 1) }, uniquingKeysWith: +)
        return teams.map { team in
            (slugCounts[team.slug, default: 0] > 1 ? "\(team.organization)/\(team.slug)" : team.slug, team.displayName)
        }
    }

    /// A tab shows headings unless its only section is Active.
    static func showsHeadings(_ sections: [PullRequestListSection]) -> Bool {
        sections.map(\.id) != [.active]
    }
}

@MainActor
enum PullRequestStackGrouping {
    /// An item's section flags and relationship come from all its open members, ignoring the filter, so the filter
    /// never moves an item to another section. `card` is nil when no member passes the filter.
    private struct GroupedItem {
        let openMembers: [PullRequest]
        let isPinned: Bool
        let isHidden: Bool
        let card: PullRequestListItem?
    }

    /// The stack read decides membership, because it comes after hydration: a member joins a stack that
    /// lists it, whatever its hydrated stack ID says. When several stacks list it, the one matching its stack ID
    /// wins, otherwise the lowest stack ID.
    private static func memberships(of members: [PullRequest], in stacks: [PullRequestStack]) -> [String: String] {
        let memberByID = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var candidates: [String: Set<String>] = [:]
        for stack in stacks {
            for entry in stack.entries where memberByID[entry.pullRequestID] != nil {
                candidates[entry.pullRequestID, default: []].insert(stack.id)
            }
        }
        var membership: [String: String] = [:]
        for (pullRequestID, stackIDs) in candidates {
            if let hydrated = memberByID[pullRequestID]?.stackID, stackIDs.contains(hydrated) {
                membership[pullRequestID] = hydrated
            } else {
                membership[pullRequestID] = stackIDs.min()
            }
        }
        return membership
    }

    /// `members` is the list's full members before its filter; `matching` is the subset passing it.
    /// A stack is hidden when every open member is hidden, and pinned when it is not hidden and any open member is
    /// pinned. Its card shows the lowest unhidden matching member, else the lowest matching member.
    private static func items(
        members allMembers: [PullRequest],
        matching: [PullRequest],
        stacks: [PullRequestStack],
        hiddenIDs: Set<String>,
        pinnedIDs: Set<String>,
        unreadIDs: Set<String>
    ) -> [GroupedItem] {
        let matchingIDs = Set(matching.map(\.id))
        var consumedIDs = Set<String>()
        var items: [GroupedItem] = []
        // A stack where a PR is the only member keeps the PR's unstacked presentation, whatever its entry says.
        let stacks = stacks.filter { $0.size > 1 }
        let stackIDByPullRequestID = memberships(of: allMembers, in: stacks)

        for stack in stacks {
            let entryByID = Dictionary(stack.entries.map { ($0.pullRequestID, $0) }, uniquingKeysWith: { first, _ in first })
            let members = allMembers.filter { stackIDByPullRequestID[$0.id] == stack.id }
            guard !members.isEmpty else { continue }
            // The stack read comes after hydration, so a member whose entry is merged or closed is context only.
            let openMembers = members.filter { entryByID[$0.id]?.state == .open }
            consumedIDs.formUnion(members.map(\.id))
            guard !openMembers.isEmpty else { continue }

            let isHidden = openMembers.allSatisfy { hiddenIDs.contains($0.id) }
            let isPinned = !isHidden && openMembers.contains { pinnedIDs.contains($0.id) }
            let byPosition = openMembers.sorted { entryByID[$0.id]!.position < entryByID[$1.id]!.position }
            let matchingMembers = byPosition.filter { matchingIDs.contains($0.id) }
            let card = matchingMembers.first.map { lowestMatching in
                let representative = matchingMembers.first { !hiddenIDs.contains($0.id) } ?? lowestMatching
                let fullMemberByID = Dictionary(uniqueKeysWithValues: openMembers.map { ($0.id, $0) })
                let group = StackGroup(
                    stack: stack,
                    representativePosition: entryByID[representative.id]!.position,
                    fullMemberIDs: Set(fullMemberByID.keys),
                    matchingMemberIDs: Set(matchingMembers.map(\.id)),
                    // A member that joined another stack's group is left out here, so it is never a context member.
                    members: stack.entries.reversed().compactMap { entry in
                        if let member = fullMemberByID[entry.pullRequestID] { return .full(member) }
                        if let other = stackIDByPullRequestID[entry.pullRequestID], other != stack.id { return nil }
                        return .context(entry)
                    }
                )
                return PullRequestListItem(
                    representative: representative,
                    stack: group,
                    isPinned: isPinned,
                    isHidden: isHidden,
                    isUnread: openMembers.contains { unreadIDs.contains($0.id) }
                )
            }
            items.append(GroupedItem(openMembers: openMembers, isPinned: isPinned, isHidden: isHidden, card: card))
        }

        for pullRequest in allMembers where !consumedIDs.contains(pullRequest.id) {
            let isHidden = hiddenIDs.contains(pullRequest.id)
            let isPinned = !isHidden && pinnedIDs.contains(pullRequest.id)
            items.append(GroupedItem(
                openMembers: [pullRequest],
                isPinned: isPinned,
                isHidden: isHidden,
                card: matchingIDs.contains(pullRequest.id)
                    ? PullRequestListItem(
                        representative: pullRequest,
                        stack: nil,
                        isPinned: isPinned,
                        isHidden: isHidden,
                        isUnread: unreadIDs.contains(pullRequest.id)
                    )
                    : nil
            ))
        }
        return items
    }

    private static func sorted(
        _ items: [PullRequestListItem],
        by sortOption: DashboardController.PullRequestSortOption,
        direction sortDirection: DashboardController.PullRequestSortDirection
    ) -> [PullRequestListItem] {
        let itemByRepresentativeID = Dictionary(uniqueKeysWithValues: items.map { ($0.representative.id, $0) })
        return DashboardController.sorted(items.map(\.representative), by: sortOption, direction: sortDirection)
            .compactMap { itemByRepresentativeID[$0.id] }
    }

    /// A pinned or hidden item sits only in Pinned or Hidden, otherwise in its relationship section.
    private static func sectionID(
        of item: GroupedItem,
        relationship: (GroupedItem) -> PullRequestSectionID?
    ) -> PullRequestSectionID? {
        if item.isHidden { return .hidden }
        if item.isPinned { return .pinned }
        return relationship(item)
    }

    /// Pinned and Hidden show only when an item belongs there, whatever the filter.
    private static func sections(
        of items: [GroupedItem],
        relationshipSections: [(id: PullRequestSectionID, title: String, accessibilityTitle: String)],
        relationship: (GroupedItem) -> PullRequestSectionID?,
        sortOption: DashboardController.PullRequestSortOption,
        sortDirection: DashboardController.PullRequestSortDirection
    ) -> [PullRequestListSection] {
        var itemsBySection: [PullRequestSectionID: [GroupedItem]] = [:]
        for item in items {
            if let id = sectionID(of: item, relationship: relationship) {
                itemsBySection[id, default: []].append(item)
            }
        }
        let shown = (itemsBySection[.pinned] != nil ? [(id: PullRequestSectionID.pinned, title: "Pinned", accessibilityTitle: "Pinned")] : [])
            + relationshipSections
            + (itemsBySection[.hidden] != nil ? [(id: PullRequestSectionID.hidden, title: "Hidden", accessibilityTitle: "Hidden")] : [])
        return shown.map { section in
            PullRequestListSection(
                id: section.id,
                title: section.title,
                accessibilityTitle: section.accessibilityTitle,
                items: sorted(
                    (itemsBySection[section.id] ?? []).compactMap(\.card),
                    by: sortOption,
                    direction: sortDirection
                )
            )
        }
    }

    /// Whether a list would show Pinned and Hidden, without building or sorting any card: with no member passing a
    /// filter, the grouping builds no cards. For pruning collapse state cheaply.
    static func pinnedAndHiddenPresence(
        members: [PullRequest],
        stacks: [PullRequestStack],
        hiddenIDs: Set<String>,
        pinnedIDs: Set<String>
    ) -> (hasPinned: Bool, hasHidden: Bool) {
        let items = items(
            members: members, matching: [], stacks: stacks, hiddenIDs: hiddenIDs, pinnedIDs: pinnedIDs, unreadIDs: []
        )
        let ids = items.compactMap { sectionID(of: $0, relationship: { _ in nil }) }
        return (ids.contains(.pinned), ids.contains(.hidden))
    }

    /// `requested` is the counted requested PRs before the Draft/Ready filter; `matching` is the subset passing it.
    /// Assigned, Direct and one section per counted team, in Settings order, always show. An item that is neither
    /// pinned nor hidden sits in the first of Assigned, Direct and Team that one of its open members belongs to. In
    /// Team, it goes under the most specific counted team its Team members request.
    static func requestedSections(
        requested: [PullRequest],
        matching: [PullRequest],
        stacks: [PullRequestStack],
        teamCounting: TeamReviewCounting,
        hiddenIDs: Set<String>,
        pinnedIDs: Set<String>,
        unreadIDs: Set<String>,
        sortOption: DashboardController.PullRequestSortOption,
        sortDirection: DashboardController.PullRequestSortDirection
    ) -> [PullRequestListSection] {
        typealias Relationship = DashboardController.RequestedSection
        let teams = teamCounting.sectionTeams
        let teamSections = zip(teams, PullRequestListSection.teamTitles(teams)).map { team, titles in
            (id: PullRequestSectionID.team(id: team.id), title: titles.title, accessibilityTitle: titles.accessibilityTitle)
        }
        return sections(
            of: items(
                members: requested,
                matching: matching,
                stacks: stacks,
                hiddenIDs: hiddenIDs,
                pinnedIDs: pinnedIDs,
                unreadIDs: unreadIDs
            ),
            relationshipSections: [
                (id: .assigned, title: Relationship.assigned.title, accessibilityTitle: Relationship.assigned.title),
                (id: .direct, title: Relationship.direct.title, accessibilityTitle: Relationship.direct.title)
            ] + teamSections,
            relationship: { item in
                let memberSections = Set(item.openMembers.compactMap(Relationship.section(for:)))
                switch Relationship.allCases.first(where: memberSections.contains) {
                case .assigned: return .assigned
                case .direct: return .direct
                case .team:
                    let teamMembers = item.openMembers.filter { Relationship.section(for: $0) == .team }
                    return teamCounting.sectionTeam(for: teamMembers.flatMap(\.requestedTeams)).map { .team(id: $0.id) }
                case nil: return nil
                }
            },
            sortOption: sortOption,
            sortDirection: sortDirection
        )
    }

    /// Authored is one Active section, shown without a heading, until an item is pinned or hidden. Then it is
    /// Pinned, Active and Hidden, each shown when it holds an item, Active always.
    static func authoredSections(
        members: [PullRequest],
        matching: [PullRequest],
        stacks: [PullRequestStack],
        hiddenIDs: Set<String>,
        pinnedIDs: Set<String>,
        unreadIDs: Set<String>,
        sortOption: DashboardController.PullRequestSortOption,
        sortDirection: DashboardController.PullRequestSortDirection
    ) -> [PullRequestListSection] {
        sections(
            of: items(
                members: members,
                matching: matching,
                stacks: stacks,
                hiddenIDs: hiddenIDs,
                pinnedIDs: pinnedIDs,
                unreadIDs: unreadIDs
            ),
            relationshipSections: [(.active, "Active", "Active")],
            relationship: { _ in .active },
            sortOption: sortOption,
            sortDirection: sortDirection
        )
    }
}
