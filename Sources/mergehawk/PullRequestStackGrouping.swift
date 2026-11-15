import Foundation
import mergehawkcore

/// One card in a PR list: a standalone PR, or a stack group shown through its representative.
struct PullRequestListItem: Identifiable, Equatable {
    let representative: PullRequest
    let stack: StackGroup?
    let isPinned: Bool
    let isHidden: Bool
    let isUnread: Bool

    /// Unique because every PR is in at most one row.
    var id: String { representative.id }
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

/// One PR list's cards, sorted, with its counts.
struct PullRequestListContent: Equatable {
    let visible: [PullRequestListItem]
    let hidden: [PullRequestListItem]
    /// Matching full members across visible and hidden items, including members folded into groups.
    let count: Int
    /// Matching full members in hidden items.
    let hiddenCount: Int
}

struct ReviewRequestSectionContent: Equatable {
    let section: DashboardController.RequestedSection
    let content: PullRequestListContent

    var visible: [PullRequestListItem] { content.visible }
    var hidden: [PullRequestListItem] { content.hidden }
    /// Matching requested PRs across visible and hidden rows, including members folded into groups.
    var count: Int { content.count }
    /// Matching requested PRs in hidden rows.
    var hiddenCount: Int { content.hiddenCount }
}

@MainActor
enum PullRequestStackGrouping {
    /// An unsorted list item with the matching full members it holds.
    private struct GroupedItem {
        let item: PullRequestListItem
        let matching: [PullRequest]
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

            let byPosition = openMembers.sorted { entryByID[$0.id]!.position < entryByID[$1.id]!.position }
            let matchingMembers = byPosition.filter { matchingIDs.contains($0.id) }
            guard let lowestMatching = matchingMembers.first else { continue }
            let unhiddenMatching = matchingMembers.first { !hiddenIDs.contains($0.id) }
            let isHidden = unhiddenMatching == nil
            let representative = unhiddenMatching ?? lowestMatching
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
            items.append(GroupedItem(
                item: PullRequestListItem(
                    representative: representative,
                    stack: group,
                    isPinned: !isHidden && openMembers.contains { pinnedIDs.contains($0.id) },
                    isHidden: isHidden,
                    isUnread: openMembers.contains { unreadIDs.contains($0.id) }
                ),
                matching: matchingMembers
            ))
        }

        for pullRequest in matching where !consumedIDs.contains(pullRequest.id) {
            items.append(GroupedItem(
                item: PullRequestListItem(
                    representative: pullRequest,
                    stack: nil,
                    isPinned: pinnedIDs.contains(pullRequest.id),
                    isHidden: hiddenIDs.contains(pullRequest.id),
                    isUnread: unreadIDs.contains(pullRequest.id)
                ),
                matching: [pullRequest]
            ))
        }
        return items
    }

    /// Pinned visible items sort first. A hidden item is never treated as pinned.
    private static func content(
        of items: [GroupedItem],
        sortOption: DashboardController.PullRequestSortOption,
        sortDirection: DashboardController.PullRequestSortDirection
    ) -> PullRequestListContent {
        func sortedItems(_ items: [PullRequestListItem]) -> [PullRequestListItem] {
            let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            return DashboardController.sorted(items.map(\.representative), by: sortOption, direction: sortDirection)
                .compactMap { itemByID[$0.id] }
        }

        let visible = items.map(\.item).filter { !$0.isHidden }
        let hidden = items.filter(\.item.isHidden)
        return PullRequestListContent(
            visible: sortedItems(visible.filter(\.isPinned)) + sortedItems(visible.filter { !$0.isPinned }),
            hidden: sortedItems(hidden.map(\.item)),
            count: items.reduce(0) { $0 + $1.matching.count },
            hiddenCount: hidden.reduce(0) { $0 + $1.matching.count }
        )
    }

    /// `requested` is the counted requested PRs before the Draft/Ready filter; `matching` is the subset passing it.
    /// An item sits in the first section that one of its matching members belongs to.
    static func sections(
        requested: [PullRequest],
        matching: [PullRequest],
        stacks: [PullRequestStack],
        hiddenIDs: Set<String>,
        pinnedIDs: Set<String>,
        unreadIDs: Set<String>,
        sortOption: DashboardController.PullRequestSortOption,
        sortDirection: DashboardController.PullRequestSortDirection
    ) -> [ReviewRequestSectionContent] {
        let items = items(
            members: requested,
            matching: matching,
            stacks: stacks,
            hiddenIDs: hiddenIDs,
            pinnedIDs: pinnedIDs,
            unreadIDs: unreadIDs
        )
        let sectionByItemID = Dictionary(uniqueKeysWithValues: items.map { item in
            let memberSections = Set(item.matching.compactMap(DashboardController.RequestedSection.section(for:)))
            return (item.item.id, DashboardController.RequestedSection.allCases.first(where: memberSections.contains))
        })
        return DashboardController.RequestedSection.allCases.map { section in
            ReviewRequestSectionContent(
                section: section,
                content: content(
                    of: items.filter { sectionByItemID[$0.item.id] == section },
                    sortOption: sortOption,
                    sortDirection: sortDirection
                )
            )
        }
    }

    /// One list without sections, as Authored shows it. `members` is the list's full members before its filter;
    /// `matching` is the subset passing it.
    static func list(
        members: [PullRequest],
        matching: [PullRequest],
        stacks: [PullRequestStack],
        hiddenIDs: Set<String>,
        pinnedIDs: Set<String>,
        unreadIDs: Set<String>,
        sortOption: DashboardController.PullRequestSortOption,
        sortDirection: DashboardController.PullRequestSortDirection
    ) -> PullRequestListContent {
        content(
            of: items(
                members: members,
                matching: matching,
                stacks: stacks,
                hiddenIDs: hiddenIDs,
                pinnedIDs: pinnedIDs,
                unreadIDs: unreadIDs
            ),
            sortOption: sortOption,
            sortDirection: sortDirection
        )
    }
}
