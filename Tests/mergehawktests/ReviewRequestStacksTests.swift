@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

@MainActor
final class ReviewRequestStacksTests: XCTestCase {
    private typealias Section = DashboardController.RequestedSection
    private typealias PullRequestSortOption = DashboardController.PullRequestSortOption
    private typealias PullRequestSortDirection = DashboardController.PullRequestSortDirection
    private typealias ReviewRequestFilterOption = DashboardController.ReviewRequestFilterOption

    func testWithoutStacksSectionsMatchTodaysPartitionOrderingAndCounts() {
        let requested = MockPullRequestSource(scenario: .longLists).firstRefreshPullRequests
            .filter(DashboardController.isRequestedPullRequest)
        XCTAssertGreaterThan(requested.count, 6)
        let hidden = Set(requested.prefix(3).map(\.id))
        let pinned = Set(requested.dropFirst(2).prefix(3).map(\.id))
        let unread = Set(requested.suffix(2).map(\.id))
        for option in [PullRequestSortOption.createdDate, .updatedDate, .changeSize] {
            for direction in [PullRequestSortDirection.ascending, .descending] {
                for filters in [Set<ReviewRequestFilterOption>(), [.draft], [.ready]] {
                    let matching = DashboardController.filteredReviewRequests(requested, by: filters)
                    let visible = DashboardController.sortedWithPins(
                        matching.filter { !hidden.contains($0.id) }, pinnedIds: pinned, by: option, direction: direction
                    )
                    let hiddenPRs = DashboardController.sorted(
                        matching.filter { hidden.contains($0.id) }, by: option, direction: direction
                    )

                    let sections = ReviewRequestStacks.sections(
                        requested: requested, matching: matching, stacks: [],
                        hiddenIDs: hidden, pinnedIDs: pinned, unreadIDs: unread,
                        sortOption: option, sortDirection: direction
                    )

                    XCTAssertEqual(sections.map(\.section), Section.allCases)
                    for content in sections {
                        let todayVisible = visible.filter { Section.section(for: $0) == content.section }
                        let todayHidden = hiddenPRs.filter { Section.section(for: $0) == content.section }
                        XCTAssertEqual(content.visible.map(\.id), todayVisible.map(\.id))
                        XCTAssertEqual(content.hidden.map(\.id), todayHidden.map(\.id))
                        XCTAssertEqual(content.count, todayVisible.count + todayHidden.count)
                        XCTAssertEqual(content.hiddenCount, todayHidden.count)
                        XCTAssertTrue(content.visible.allSatisfy { $0.stack == nil && !$0.isHidden })
                        XCTAssertEqual(content.visible.map(\.isPinned), todayVisible.map { pinned.contains($0.id) })
                        XCTAssertEqual(content.visible.map(\.isUnread), todayVisible.map { unread.contains($0.id) })
                    }
                }
            }
        }
    }

    func testTwoRequestedMembersFormOneRowRepresentedByTheLowerPosition() throws {
        let lower = Self.pr("PR_LOW", .direct, stack: "S")
        let upper = Self.pr("PR_HIGH", .team, stack: "S")
        let other = Self.pr("PR_OTHER", .team)
        let stack = Self.stack("S", size: 2, [(1, lower.id, .open), (2, upper.id, .open)])

        let sections = Self.sections([lower, upper, other], stacks: [stack])

        XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: ["PR_LOW"], .team: ["PR_OTHER"]])
        let row = try XCTUnwrap(Self.row(lower.id, in: sections))
        XCTAssertEqual(row.stack?.representativePosition, 1)
        XCTAssertEqual(row.stack?.requestedMemberIDs, [lower.id, upper.id])
    }

    func testRepresentativeIsTheLowestMatchingMemberWhenTheFilterExcludesTheBottomOne() throws {
        let draft = Self.pr("PR_DRAFT", .direct, draft: true, stack: "S")
        let ready = Self.pr("PR_READY", .direct, stack: "S")
        let stack = Self.stack("S", size: 3, [(1, draft.id, .open), (2, ready.id, .open), (3, "PR_CONTEXT", .open)])

        let sections = Self.sections([draft, ready], filters: [.ready], stacks: [stack])

        let row = try XCTUnwrap(Self.row(ready.id, in: sections))
        XCTAssertEqual(row.stack?.representativePosition, 2)
        XCTAssertEqual(row.stack?.additionalRequestCount, 1)
        XCTAssertNil(Self.row(draft.id, in: sections))
    }

    func testAssignedMemberAboveATeamRequestedBottomMemberPlacesTheGroupInAssigned() throws {
        let team = Self.pr("PR_TEAM", .team, stack: "S")
        let assigned = Self.pr("PR_ASSIGNED", .assigned, draft: true, stack: "S")
        let stack = Self.stack("S", size: 3, [(1, "PR_MERGED", .merged), (2, team.id, .open), (3, assigned.id, .open)])

        let sections = Self.sections([team, assigned], stacks: [stack])

        XCTAssertEqual(Self.ids(sections), [.assigned: ["PR_TEAM"], .direct: [], .team: []])
        XCTAssertEqual(sections.first { $0.section == .assigned }?.count, 2)
    }

    func testReadyFilterWithADraftAssignedMemberPlacesTheGroupInTeam() throws {
        let team = Self.pr("PR_TEAM", .team, stack: "S")
        let assigned = Self.pr("PR_ASSIGNED", .assigned, draft: true, stack: "S")
        let stack = Self.stack("S", size: 3, [(1, "PR_MERGED", .merged), (2, team.id, .open), (3, assigned.id, .open)])

        let sections = Self.sections([team, assigned], filters: [.ready], stacks: [stack])

        XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: [], .team: ["PR_TEAM"]])
        let group = try XCTUnwrap(Self.row(team.id, in: sections)?.stack)
        XCTAssertEqual(group.members.last, .requested(assigned))
        XCTAssertEqual(group.filterExcludedRequestCount, 1)
    }

    func testStackWithoutAMatchingRequestedMemberShowsNoRow() {
        let draft = Self.pr("PR_DRAFT", .direct, draft: true, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, draft.id, .open), (2, "PR_CONTEXT", .open)])

        let sections = Self.sections([draft], filters: [.ready], stacks: [stack])

        XCTAssertTrue(sections.allSatisfy { $0.visible.isEmpty && $0.hidden.isEmpty && $0.count == 0 })
    }

    func testStackWithOnlyOneReadableRequestedEntryStillFormsAGroup() throws {
        let top = Self.pr("PR_TOP", .direct, stack: "S")
        let stack = Self.stack("S", size: 3, [(3, top.id, .open)])

        let group = try XCTUnwrap(Self.row(top.id, in: Self.sections([top], stacks: [stack]))?.stack)

        XCTAssertEqual(group.representativePosition, 3)
        XCTAssertEqual(group.stack.size, 3)
        XCTAssertEqual(group.additionalRequestCount, 0)
    }

    func testRequestedPRWhoseEntryIsMergedOrClosedIsAContextMember() throws {
        for state in [PullRequestStackEntry.State.merged, .closed] {
            let stale = Self.pr("PR_STALE", .assigned, stack: "S")
            let open = Self.pr("PR_OPEN", .team, stack: "S")
            let stack = Self.stack("S", size: 2, [(1, stale.id, state), (2, open.id, .open)])

            let sections = Self.sections([stale, open], stacks: [stack])

            XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: [], .team: ["PR_OPEN"]], "\(state)")
            let group = try XCTUnwrap(Self.row(open.id, in: sections)?.stack)
            XCTAssertEqual(group.representativePosition, 2)
            XCTAssertEqual(group.requestedMemberIDs, [open.id])
            XCTAssertEqual(group.additionalRequestCount, 0)
            XCTAssertEqual(group.members.first, .context(stack.entries[0]))
            XCTAssertEqual(sections.map(\.count), [0, 0, 1])
        }
    }

    func testRequestedPRWhoseEntryIsMergedOrClosedInASizeOneStackKeepsItsStandaloneRow() throws {
        for state in [PullRequestStackEntry.State.open, .merged, .closed] {
            let single = Self.pr("PR_SINGLE", .direct, stack: "S")
            let stack = Self.stack("S", size: 1, [(1, single.id, state)])

            let stacked = Self.sections([single], stacks: [stack])
            let unstacked = Self.sections([single], stacks: [])

            XCTAssertEqual(stacked, unstacked, "\(state)")
            XCTAssertNil(try XCTUnwrap(Self.row(single.id, in: stacked), "\(state)").stack)
        }
    }

    func testRequestedPRWithoutAHydratedStackIDJoinsTheStackThatListsIt() throws {
        let unstamped = Self.pr("PR_UNSTAMPED", .team)
        let member = Self.pr("PR_MEMBER", .direct, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, unstamped.id, .open), (2, member.id, .open)])

        let sections = Self.sections([unstamped, member], stacks: [stack])

        XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: [unstamped.id], .team: []])
        let group = try XCTUnwrap(Self.row(unstamped.id, in: sections)?.stack)
        XCTAssertEqual(group.requestedMemberIDs, [unstamped.id, member.id])
        XCTAssertEqual(group.members, [.requested(unstamped), .requested(member)])
        XCTAssertEqual(sections.map(\.count), [0, 2, 0])
    }

    func testRequestedPRNamingAnotherStackJoinsTheStackThatListsIt() throws {
        let moved = Self.pr("PR_MOVED", .direct, stack: "OTHER")
        let member = Self.pr("PR_MEMBER", .direct, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, moved.id, .open), (2, member.id, .open)])

        let sections = Self.sections([moved, member], stacks: [stack])

        XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: [moved.id], .team: []])
        let group = try XCTUnwrap(Self.row(moved.id, in: sections)?.stack)
        XCTAssertEqual(group.members, [.requested(moved), .requested(member)])
    }

    func testPRListedByTwoStacksJoinsOneGroupAndIsNeverAContextMemberOfTheOther() throws {
        let shared = Self.pr("PR_SHARED", .direct, stack: "B")
        let inA = Self.pr("PR_A", .direct, stack: "A")
        let inB = Self.pr("PR_B", .team, stack: "B")
        let stackA = Self.stack("A", size: 2, [(1, inA.id, .open), (2, shared.id, .open)])
        let stackB = Self.stack("B", size: 2, [(1, shared.id, .open), (2, inB.id, .open)])

        // The stack matching the hydrated stack ID wins.
        let preferred = Self.sections([shared, inA, inB], stacks: [stackA, stackB])
        let groupB = try XCTUnwrap(Self.row(shared.id, in: preferred)?.stack)
        XCTAssertEqual(groupB.stack.id, "B")
        XCTAssertEqual(groupB.requestedMemberIDs, [shared.id, inB.id])
        let groupA = try XCTUnwrap(Self.row(inA.id, in: preferred)?.stack)
        XCTAssertEqual(groupA.requestedMemberIDs, [inA.id])
        XCTAssertEqual(groupA.members, [.requested(inA)])

        // Without a matching stack ID, the lowest stack ID wins.
        let unstamped = Self.pr("PR_SHARED", .direct)
        let lowest = Self.sections([unstamped, inA, inB], stacks: [stackB, stackA])
        let rows = lowest.flatMap { $0.visible + $0.hidden }
        XCTAssertEqual(rows.map(\.id).sorted(), [inA.id, inB.id])
        XCTAssertEqual(rows.first { $0.id == inA.id }?.stack?.requestedMemberIDs, [inA.id, unstamped.id])
        let other = try XCTUnwrap(rows.first { $0.id == inB.id }?.stack)
        XCTAssertEqual(other.members, [.requested(inB)])
        XCTAssertEqual(lowest.map(\.count), [0, 2, 1])
    }

    func testAdditionalRequestCountIgnoresTheFilterAndExcludedCountCountsFilteredMembers() throws {
        let one = Self.pr("PR_1", .direct, stack: "S")
        let two = Self.pr("PR_2", .direct, draft: true, stack: "S")
        let three = Self.pr("PR_3", .team, draft: true, stack: "S")
        let stack = Self.stack("S", size: 3, [(1, one.id, .open), (2, two.id, .open), (3, three.id, .open)])

        let unfiltered = try XCTUnwrap(Self.row(one.id, in: Self.sections([one, two, three], stacks: [stack]))?.stack)
        let ready = try XCTUnwrap(Self.row(one.id, in: Self.sections([one, two, three], filters: [.ready], stacks: [stack]))?.stack)

        XCTAssertEqual(unfiltered.additionalRequestCount, 2)
        XCTAssertEqual(unfiltered.filterExcludedRequestCount, 0)
        XCTAssertEqual(ready.additionalRequestCount, 2)
        XCTAssertEqual(ready.filterExcludedRequestCount, 2)
    }

    func testOneReadyAndOneDraftMemberWithReadySelectedCountsOneInTheSection() throws {
        let ready = Self.pr("PR_READY", .direct, stack: "S")
        let draft = Self.pr("PR_DRAFT", .direct, draft: true, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, ready.id, .open), (2, draft.id, .open)])

        let sections = Self.sections([ready, draft], filters: [.ready], stacks: [stack])

        let direct = try XCTUnwrap(sections.first { $0.section == .direct })
        XCTAssertEqual(direct.count, 1)
        XCTAssertEqual(direct.visible.first?.stack?.additionalRequestCount, 1)
        XCTAssertEqual(direct.visible.first?.stack?.filterExcludedRequestCount, 1)
    }

    func testFoldedInMembersCountInTheGroupsSectionAndNeverInTheirOwn() {
        let direct = Self.pr("PR_DIRECT", .direct, stack: "S")
        let team = Self.pr("PR_TEAM", .team, stack: "S")
        let teamToo = Self.pr("PR_TEAM_2", .team, stack: "S")
        let standalone = Self.pr("PR_STANDALONE", .team)
        let stack = Self.stack("S", size: 3, [(1, team.id, .open), (2, direct.id, .open), (3, teamToo.id, .open)])

        let sections = Self.sections([direct, team, teamToo, standalone], stacks: [stack])

        XCTAssertEqual(sections.map(\.count), [0, 3, 1])
        XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: ["PR_TEAM"], .team: ["PR_STANDALONE"]])
    }

    func testHiddenBottomMemberWithAVisibleMemberAboveGivesAVisibleGroup() throws {
        let bottom = Self.pr("PR_BOTTOM", .direct, stack: "S")
        let above = Self.pr("PR_ABOVE", .direct, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, bottom.id, .open), (2, above.id, .open)])

        let sections = Self.sections([bottom, above], stacks: [stack], hidden: [bottom.id])

        let direct = try XCTUnwrap(sections.first { $0.section == .direct })
        XCTAssertEqual(direct.visible.map(\.id), [above.id])
        XCTAssertTrue(direct.hidden.isEmpty)
        XCTAssertEqual(direct.visible.first?.stack?.representativePosition, 2)
        XCTAssertEqual(direct.count, 2)
        XCTAssertEqual(direct.hiddenCount, 0)
    }

    func testAllMatchingMembersHiddenMovesTheGroupUnderHiddenAndItIsNeverPinned() throws {
        let one = Self.pr("PR_1", .direct, stack: "S")
        let two = Self.pr("PR_2", .direct, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, one.id, .open), (2, two.id, .open)])

        let sections = Self.sections([one, two], stacks: [stack], hidden: [one.id, two.id], pinned: [two.id])

        let direct = try XCTUnwrap(sections.first { $0.section == .direct })
        XCTAssertTrue(direct.visible.isEmpty)
        XCTAssertEqual(direct.hidden.map(\.id), [one.id])
        XCTAssertEqual(direct.hiddenCount, 2)
        XCTAssertEqual(direct.count, 2)
        XCTAssertEqual(direct.hidden.first?.isHidden, true)
        XCTAssertEqual(direct.hidden.first?.isPinned, false)
    }

    func testHiddenReadyMemberAndPinnedDraftMemberWithReadySelectedIsHiddenAndNotPinned() throws {
        let ready = Self.pr("PR_READY", .direct, stack: "S")
        let draft = Self.pr("PR_DRAFT", .direct, draft: true, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, ready.id, .open), (2, draft.id, .open)])

        let sections = Self.sections(
            [ready, draft], filters: [.ready], stacks: [stack], hidden: [ready.id], pinned: [draft.id]
        )

        let row = try XCTUnwrap(sections.first { $0.section == .direct }?.hidden.first)
        XCTAssertEqual(row.id, ready.id)
        XCTAssertTrue(row.isHidden)
        XCTAssertFalse(row.isPinned)
    }

    func testPinnedMemberSortsTheVisibleGroupWithThePinnedRows() {
        let newest = Self.pr("PR_NEWEST", .direct, updated: 300)
        let pinnedStandalone = Self.pr("PR_PINNED", .direct, updated: 100)
        let representative = Self.pr("PR_REP", .direct, updated: 50, stack: "S")
        let pinnedMember = Self.pr("PR_MEMBER", .team, updated: 10, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, representative.id, .open), (2, pinnedMember.id, .open)])

        let sections = Self.sections(
            [newest, pinnedStandalone, representative, pinnedMember],
            stacks: [stack],
            pinned: [pinnedStandalone.id, pinnedMember.id]
        )

        let direct = sections.first { $0.section == .direct }
        XCTAssertEqual(direct?.visible.map(\.id), [pinnedStandalone.id, representative.id, newest.id])
        XCTAssertEqual(direct?.visible.map(\.isPinned), [true, true, false])
    }

    func testUnreadFoldedInMemberMarksTheGroupRowUnread() {
        let representative = Self.pr("PR_REP", .direct, stack: "S")
        let folded = Self.pr("PR_FOLDED", .team, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, representative.id, .open), (2, folded.id, .open)])

        let row = Self.row(representative.id, in: Self.sections([representative, folded], stacks: [stack], unread: [folded.id]))

        XCTAssertEqual(row?.isUnread, true)
    }

    func testNonRequestedEntriesBecomeContextMembersInPositionOrder() throws {
        let requested = Self.pr("PR_REQUESTED", .direct, stack: "S")
        let stack = Self.stack("S", size: 6, [
            (6, "PR_OWN", .open), (1, "PR_MERGED", .merged), (3, requested.id, .open),
            (2, "PR_CLOSED", .closed), (5, "PR_OTHER_OPEN", .open)
        ])

        let group = try XCTUnwrap(Self.row(requested.id, in: Self.sections([requested], stacks: [stack]))?.stack)

        XCTAssertEqual(group.members.map(\.pullRequestID), ["PR_MERGED", "PR_CLOSED", "PR_REQUESTED", "PR_OTHER_OPEN", "PR_OWN"])
        XCTAssertEqual(group.members.map { group.position(of: $0) }, [1, 2, 3, 5, 6])
        for member in group.members where member.pullRequestID != requested.id {
            guard case .context = member else { return XCTFail("\(member.pullRequestID) should be a context member") }
        }
        XCTAssertEqual(group.members[2], .requested(requested))
    }

    // MARK: - pr-stacks mock scenario

    private static func prStacksSections(filters: Set<ReviewRequestFilterOption> = []) -> [ReviewRequestSectionContent] {
        let source = MockPullRequestSource(scenario: .prStacks)
        let requested = source.firstRefreshPullRequests.filter(DashboardController.isRequestedPullRequest)
        return ReviewRequestStacks.sections(
            requested: requested,
            matching: DashboardController.filteredReviewRequests(requested, by: filters),
            stacks: source.stacks,
            hiddenIDs: [], pinnedIDs: [], unreadIDs: [],
            sortOption: .createdDate, sortDirection: .descending
        )
    }

    private static func prStacksGroup(_ stackID: String) throws -> (row: ReviewRequestRow, group: StackGroup) {
        let row = try XCTUnwrap(prStacksSections().flatMap(\.visible).first { $0.stack?.stack.id == stackID }, stackID)
        return (row, try XCTUnwrap(row.stack, stackID))
    }

    func testAcceptanceStacksGroupUnderTheirAssignedPositionTwoMember() throws {
        // The all-open stack's position-3 member is a draft, so it shows Draft before its state.
        let firstStates: [(String, StackMemberBadge, [StackMemberBadge])] = [
            ("STACK_MOCK_ALL_OPEN", .open, [.draft, .open]),
            ("STACK_MOCK_PARTIALLY_MERGED", .merged, [.open]),
            ("STACK_MOCK_CLOSED_DEPENDENCY", .closed, [.open])
        ]
        let assigned = try XCTUnwrap(Self.prStacksSections().first { $0.section == .assigned })
        for (stackID, firstState, lastBadges) in firstStates {
            let (row, group) = try Self.prStacksGroup(stackID)
            XCTAssertEqual(row.representative.id, "PR_\(stackID)_2", stackID)
            XCTAssertTrue(assigned.visible.contains(row), "assigned, \(stackID)")
            XCTAssertEqual(group.stack.size, 3, stackID)
            XCTAssertEqual(group.members.map { group.position(of: $0) }, [1, 2, 3], stackID)
            XCTAssertEqual(group.requestedMemberIDs, [row.representative.id], stackID)
            XCTAssertEqual(
                StackControlPresentation(group: group, displayedPosition: group.representativePosition, isExpanded: false).fractionText,
                "2/3", stackID
            )
            XCTAssertEqual(group.contextBadges, [[firstState], lastBadges], stackID)
        }
    }

    func testPositionThreeStackIsRepresentedByItsLastMember() throws {
        let (row, group) = try Self.prStacksGroup("STACK_MOCK_POSITION_3")

        XCTAssertEqual(row.representative.id, "PR_STACK_MOCK_POSITION_3_3")
        XCTAssertEqual(group.representativePosition, 3)
        XCTAssertEqual(
            StackControlPresentation(group: group, displayedPosition: group.representativePosition, isExpanded: false).fractionText,
            "3/3"
        )
        XCTAssertEqual(group.contextBadges, [[.merged], [.open]])
    }

    func testMergedAndClosedContextMembersNeverRepresentAGroupOrCountInASection() throws {
        let source = MockPullRequestSource(scenario: .prStacks)
        let entries = Dictionary(source.stacks.flatMap(\.entries).map { ($0.pullRequestID, $0) }, uniquingKeysWith: { first, _ in first })
        let sections = Self.prStacksSections()
        let rows = sections.flatMap { $0.visible + $0.hidden }

        let finished = Set(entries.values.filter { $0.state != .open }.map(\.pullRequestID))
        XCTAssertEqual(finished.count, 6)
        for row in rows {
            XCTAssertFalse(finished.contains(row.representative.id), row.id)
            XCTAssertTrue(row.stack?.requestedMemberIDs.isDisjoint(with: finished) ?? true, row.id)
        }
        // Each section counts only its matching requested PRs, folded-in members included.
        let requested = source.firstRefreshPullRequests.filter(DashboardController.isRequestedPullRequest)
        XCTAssertTrue(Set(requested.map(\.id)).isDisjoint(with: finished))
        XCTAssertEqual(sections.map(\.count).reduce(0, +), requested.count)
        XCTAssertEqual(sections.map(\.count), [6, 8, 1])
    }

    // MARK: - Fixtures

    private enum Role {
        case assigned, direct, team
    }

    private static func pr(
        _ id: String,
        _ role: Role,
        draft: Bool = false,
        updated: TimeInterval = 0,
        stack: String? = nil
    ) -> PullRequest {
        PullRequest(
            id: id, title: id, number: abs(id.hashValue % 1000),
            url: URL(string: "https://github.com/acme/app/pull/1")!, repo: "acme/app",
            ciState: .passing, reviewDecision: .reviewRequired, commentCount: 0, reviewCount: 0,
            reviewRequestKind: role == .direct ? .direct : role == .team ? .team : .none,
            isAssignedToViewer: role == .assigned, isMine: false, author: "author",
            mergeable: .mergeable, draft: draft,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: updated),
            stackID: stack
        )
    }

    private static func stack(
        _ id: String,
        size: Int,
        _ entries: [(position: Int, id: String, state: PullRequestStackEntry.State)]
    ) -> PullRequestStack {
        PullRequestStack(id: id, size: size, entries: entries.map { entry in
            PullRequestStackEntry(
                position: entry.position, pullRequestID: entry.id, number: entry.position, title: entry.id,
                url: URL(string: "https://github.com/acme/app/pull/\(entry.position)")!,
                state: entry.state, isDraft: false, author: "author"
            )
        })
    }

    private static func sections(
        _ requested: [PullRequest],
        filters: Set<ReviewRequestFilterOption> = [],
        stacks: [PullRequestStack],
        hidden: Set<String> = [],
        pinned: Set<String> = [],
        unread: Set<String> = []
    ) -> [ReviewRequestSectionContent] {
        ReviewRequestStacks.sections(
            requested: requested,
            matching: DashboardController.filteredReviewRequests(requested, by: filters),
            stacks: stacks,
            hiddenIDs: hidden,
            pinnedIDs: pinned,
            unreadIDs: unread,
            sortOption: .updatedDate,
            sortDirection: .descending
        )
    }

    private static func ids(_ sections: [ReviewRequestSectionContent]) -> [Section: [String]] {
        Dictionary(uniqueKeysWithValues: sections.map { ($0.section, ($0.visible + $0.hidden).map(\.id)) })
    }

    private static func row(_ id: String, in sections: [ReviewRequestSectionContent]) -> ReviewRequestRow? {
        sections.flatMap { $0.visible + $0.hidden }.first { $0.id == id }
    }
}
