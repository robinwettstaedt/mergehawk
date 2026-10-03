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

    func testSizeOneStackYieldsAStandaloneRow() {
        let single = Self.pr("PR_SINGLE", .direct, stack: "S")
        let stack = Self.stack("S", size: 1, [(1, single.id, .open)])

        let row = Self.row(single.id, in: Self.sections([single], stacks: [stack]))

        XCTAssertNotNil(row)
        XCTAssertNil(row?.stack)
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

    func testRequestedPRWhoseEntryIsMergedOrClosedInASizeOneStackGetsNoRow() {
        for state in [PullRequestStackEntry.State.merged, .closed] {
            let stale = Self.pr("PR_STALE", .direct, stack: "S")
            let stack = Self.stack("S", size: 1, [(1, stale.id, state)])

            let sections = Self.sections([stale], stacks: [stack])

            XCTAssertTrue(sections.allSatisfy { $0.visible.isEmpty && $0.hidden.isEmpty && $0.count == 0 }, "\(state)")
        }
    }

    func testRequestedPRNamingADifferentStackThanTheOneListingItStaysStandalone() throws {
        let moved = Self.pr("PR_MOVED", .direct, stack: "OTHER")
        let member = Self.pr("PR_MEMBER", .direct, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, moved.id, .open), (2, member.id, .open)])

        let sections = Self.sections([moved, member], stacks: [stack])

        XCTAssertNil(try XCTUnwrap(Self.row(moved.id, in: sections)).stack)
        let group = try XCTUnwrap(Self.row(member.id, in: sections)?.stack)
        XCTAssertEqual(group.requestedMemberIDs, [member.id])
        XCTAssertEqual(group.members.first, .context(stack.entries[0]))
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
