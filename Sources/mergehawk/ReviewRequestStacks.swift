import Foundation
import mergehawkcore

/// One card in a Review requests section: a standalone requested PR, or a stack group shown through its
/// representative.
struct ReviewRequestRow: Identifiable, Equatable {
    let representative: PullRequest
    let stack: StackGroup?
    let isPinned: Bool
    let isHidden: Bool
    let isUnread: Bool

    /// Unique because every PR is in at most one row.
    var id: String { representative.id }
}

/// A stack's group in Review requests.
struct StackGroup: Equatable {
    enum Member: Equatable {
        /// A requested member, whether or not it passes the Draft/Ready filter.
        case requested(PullRequest)
        /// Every other entry: open non-requested, the viewer's own, merged, and closed.
        case context(PullRequestStackEntry)

        var pullRequestID: String {
            switch self {
            case .requested(let pullRequest): pullRequest.id
            case .context(let entry): entry.pullRequestID
            }
        }
    }

    let stack: PullRequestStack
    let representativePosition: Int
    /// Ignores the Draft/Ready filter.
    let requestedMemberIDs: Set<String>
    let matchingMemberIDs: Set<String>
    /// As GitHub lists the stack: the top (highest position) first, position 1 (closest to the base branch) last.
    let members: [Member]

    var additionalRequestCount: Int { requestedMemberIDs.count - 1 }
    var filterExcludedRequestCount: Int { requestedMemberIDs.count - matchingMemberIDs.count }

    func position(of member: Member) -> Int? {
        stack.entries.first { $0.pullRequestID == member.pullRequestID }?.position
    }
}

struct ReviewRequestSectionContent: Equatable {
    let section: DashboardController.RequestedSection
    let visible: [ReviewRequestRow]
    let hidden: [ReviewRequestRow]
    /// Matching requested PRs across visible and hidden rows, including members folded into groups.
    let count: Int
    /// Matching requested PRs in hidden rows.
    let hiddenCount: Int
}

@MainActor
enum ReviewRequestStacks {
    private struct PlacedRow {
        let row: ReviewRequestRow
        let section: DashboardController.RequestedSection
        let matchingCount: Int
    }

    /// The stack read decides membership, because it comes after hydration: a requested PR joins a stack that
    /// lists it, whatever its hydrated stack ID says. When several stacks list it, the one matching its stack ID
    /// wins, otherwise the lowest stack ID.
    private static func memberships(of requested: [PullRequest], in stacks: [PullRequestStack]) -> [String: String] {
        let requestedByID = Dictionary(requested.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var candidates: [String: Set<String>] = [:]
        for stack in stacks {
            for entry in stack.entries where requestedByID[entry.pullRequestID] != nil {
                candidates[entry.pullRequestID, default: []].insert(stack.id)
            }
        }
        var membership: [String: String] = [:]
        for (pullRequestID, stackIDs) in candidates {
            if let hydrated = requestedByID[pullRequestID]?.stackID, stackIDs.contains(hydrated) {
                membership[pullRequestID] = hydrated
            } else {
                membership[pullRequestID] = stackIDs.min()
            }
        }
        return membership
    }

    /// `requested` is the counted requested PRs before the Draft/Ready filter; `matching` is the subset passing it.
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
        let matchingIDs = Set(matching.map(\.id))
        var consumedIDs = Set<String>()
        var placed: [PlacedRow] = []
        // A stack where a PR is the only member keeps the PR's unstacked presentation, whatever its entry says.
        let stacks = stacks.filter { $0.size > 1 }
        let stackIDByPullRequestID = memberships(of: requested, in: stacks)

        for stack in stacks {
            let entryByID = Dictionary(stack.entries.map { ($0.pullRequestID, $0) }, uniquingKeysWith: { first, _ in first })
            let members = requested.filter { stackIDByPullRequestID[$0.id] == stack.id }
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
            let memberSections = Set(matchingMembers.compactMap(DashboardController.RequestedSection.section(for:)))
            guard let section = DashboardController.RequestedSection.allCases.first(where: memberSections.contains) else {
                continue
            }
            let requestedByID = Dictionary(uniqueKeysWithValues: openMembers.map { ($0.id, $0) })
            let group = StackGroup(
                stack: stack,
                representativePosition: entryByID[representative.id]!.position,
                requestedMemberIDs: Set(requestedByID.keys),
                matchingMemberIDs: Set(matchingMembers.map(\.id)),
                // A requested PR that joined another stack's group is left out here, so it is never a context member.
                members: stack.entries.reversed().compactMap { entry in
                    if let member = requestedByID[entry.pullRequestID] { return .requested(member) }
                    if let other = stackIDByPullRequestID[entry.pullRequestID], other != stack.id { return nil }
                    return .context(entry)
                }
            )
            placed.append(PlacedRow(
                row: ReviewRequestRow(
                    representative: representative,
                    stack: group,
                    isPinned: !isHidden && openMembers.contains { pinnedIDs.contains($0.id) },
                    isHidden: isHidden,
                    isUnread: openMembers.contains { unreadIDs.contains($0.id) }
                ),
                section: section,
                matchingCount: matchingMembers.count
            ))
        }

        for pullRequest in matching where !consumedIDs.contains(pullRequest.id) {
            guard let section = DashboardController.RequestedSection.section(for: pullRequest) else { continue }
            placed.append(PlacedRow(
                row: ReviewRequestRow(
                    representative: pullRequest,
                    stack: nil,
                    isPinned: pinnedIDs.contains(pullRequest.id),
                    isHidden: hiddenIDs.contains(pullRequest.id),
                    isUnread: unreadIDs.contains(pullRequest.id)
                ),
                section: section,
                matchingCount: 1
            ))
        }

        func sortedRows(_ rows: [ReviewRequestRow]) -> [ReviewRequestRow] {
            let rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            return DashboardController.sorted(rows.map(\.representative), by: sortOption, direction: sortDirection)
                .compactMap { rowByID[$0.id] }
        }

        return DashboardController.RequestedSection.allCases.map { section in
            let inSection = placed.filter { $0.section == section }
            let visible = inSection.map(\.row).filter { !$0.isHidden }
            let hidden = inSection.filter(\.row.isHidden)
            return ReviewRequestSectionContent(
                section: section,
                visible: sortedRows(visible.filter(\.isPinned)) + sortedRows(visible.filter { !$0.isPinned }),
                hidden: sortedRows(hidden.map(\.row)),
                count: inSection.reduce(0) { $0 + $1.matchingCount },
                hiddenCount: hidden.reduce(0) { $0 + $1.matchingCount }
            )
        }
    }
}
