@testable import mergehawk
import Foundation
import mergehawkcore
import XCTest

@MainActor
final class PullRequestStackGroupingTests: XCTestCase {
    private typealias Section = DashboardController.RequestedSection
    private typealias PullRequestSortOption = DashboardController.PullRequestSortOption
    private typealias PullRequestSortDirection = DashboardController.PullRequestSortDirection
    private typealias ReviewRequestFilterOption = DashboardController.ReviewRequestFilterOption
    private typealias PullRequestFilterOption = DashboardController.PullRequestFilterOption

    func testWithoutStacksEachRequestedSectionHoldsItsPRsSortedWithoutPinnedFirst() {
        let source = MockPullRequestSource(scenario: .longLists)
        let counting = TeamReviewCounting(viewerTeams: source.viewerTeams, turnedOffTeamIDs: [])
        let requested = source.firstRefreshPullRequests.map(counting.applied(to:))
            .filter(DashboardController.isRequestedPullRequest)
        let teamSections = counting.sectionTeams.map { PullRequestSectionID.team(id: $0.id) }
        XCTAssertFalse(teamSections.isEmpty)
        XCTAssertGreaterThan(requested.count, 6)
        let hidden = Set(requested.prefix(3).map(\.id))
        let pinned = Set(requested.dropFirst(2).prefix(3).map(\.id))
        let unread = Set(requested.suffix(2).map(\.id))
        for option in [PullRequestSortOption.createdDate, .updatedDate, .changeSize] {
            for direction in [PullRequestSortDirection.ascending, .descending] {
                for filters in [Set<ReviewRequestFilterOption>(), [.draft], [.ready]] {
                    let matching = DashboardController.filteredReviewRequests(requested, by: filters)
                    func expected(_ id: PullRequestSectionID) -> [String] {
                        DashboardController.sorted(matching.filter { pr in
                            if hidden.contains(pr.id) { return id == .hidden }
                            if pinned.contains(pr.id) { return id == .pinned }
                            switch Section.section(for: pr) {
                            case .assigned: return id == .assigned
                            case .direct: return id == .direct
                            case .team: return counting.sectionTeam(for: pr.requestedTeams).map { .team(id: $0.id) } == id
                            case nil: return false
                            }
                        }, by: option, direction: direction).map(\.id)
                    }

                    let sections = PullRequestStackGrouping.requestedSections(
                        requested: requested, matching: matching, stacks: [], teamCounting: counting,
                        hiddenIDs: hidden, pinnedIDs: pinned, unreadIDs: unread,
                        sortOption: option, sortDirection: direction
                    )

                    let context = "\(option) \(direction) \(filters)"
                    XCTAssertEqual(sections.map(\.id), [.pinned, .assigned, .direct] + teamSections + [.hidden], context)
                    for section in sections {
                        XCTAssertEqual(section.items.map(\.representative.id), expected(section.id), context)
                        XCTAssertEqual(section.count, section.items.count, context)
                        XCTAssertTrue(section.items.allSatisfy { $0.stack == nil }, context)
                        XCTAssertTrue(section.items.allSatisfy { $0.isHidden == (section.id == .hidden) }, context)
                        XCTAssertTrue(section.items.allSatisfy { $0.isPinned == (section.id == .pinned) }, context)
                        XCTAssertEqual(section.items.map(\.isUnread), section.items.map { unread.contains($0.id) }, context)
                    }
                    XCTAssertEqual(sections.map(\.count).reduce(0, +), matching.count, context)
                }
            }
        }
    }

    func testWithoutStacksAuthoredSectionsHoldTheirPRsSortedWithoutPinnedFirst() {
        let own = MockPullRequestSource(scenario: .longLists).firstRefreshPullRequests.filter(\.isMine)
        XCTAssertGreaterThan(own.count, 6)
        let hidden = Set(own.prefix(3).map(\.id))
        let pinned = Set(own.dropFirst(3).prefix(3).map(\.id))
        let unread = Set(own.suffix(3).map(\.id) + own.prefix(1).map(\.id))
        let filterSets: [Set<PullRequestFilterOption>] = [[], [.needsAttention], [.draft], [.changesRequested, .ciFailing]]
        for option in [PullRequestSortOption.createdDate, .updatedDate, .changeSize] {
            for direction in [PullRequestSortDirection.ascending, .descending] {
                for filters in filterSets {
                    let matching = DashboardController.filtered(own, by: filters, attentionPullRequestIds: unread)
                    func expected(_ id: PullRequestSectionID) -> [String] {
                        DashboardController.sorted(matching.filter { pr in
                            if hidden.contains(pr.id) { return id == .hidden }
                            if pinned.contains(pr.id) { return id == .pinned }
                            return id == .active
                        }, by: option, direction: direction).map(\.id)
                    }

                    let sections = PullRequestStackGrouping.authoredSections(
                        members: own, matching: matching, stacks: [],
                        hiddenIDs: hidden, pinnedIDs: pinned, unreadIDs: unread,
                        sortOption: option, sortDirection: direction
                    )

                    let context = "\(option) \(direction) \(filters)"
                    XCTAssertEqual(sections.map(\.id), [.pinned, .active, .hidden], context)
                    for section in sections {
                        XCTAssertEqual(section.items.map(\.representative.id), expected(section.id), context)
                        XCTAssertTrue(section.items.allSatisfy { $0.isHidden == (section.id == .hidden) }, context)
                        XCTAssertTrue(section.items.allSatisfy { $0.isPinned == (section.id == .pinned) }, context)
                        XCTAssertEqual(section.items.map(\.isUnread), section.items.map { unread.contains($0.id) }, context)
                    }
                    XCTAssertEqual(sections.map(\.count).reduce(0, +), matching.count, context)
                }
            }
        }
    }

    // MARK: - Sections

    func testPinnedPRFromAssignedDirectOrTeamAppearsOnlyInPinned() {
        let assigned = Self.pr("PR_ASSIGNED", .assigned)
        let direct = Self.pr("PR_DIRECT", .direct)
        let team = Self.pr("PR_TEAM", .team)

        for pinned in [assigned, direct, team] {
            let sections = Self.sections([assigned, direct, team], stacks: [], pinned: [pinned.id])

            let holding = sections.filter { $0.items.contains { $0.id == pinned.id } }.map(\.id)
            XCTAssertEqual(holding, [.pinned], pinned.id)
        }
    }

    func testHiddenPRAppearsOnlyInHiddenEvenWhenItIsAlsoPinned() {
        let direct = Self.pr("PR_DIRECT", .direct)
        let team = Self.pr("PR_TEAM", .team)

        let hidden = Self.sections([direct, team], stacks: [], hidden: [direct.id])
        // Hiding a pinned PR unpins it, but even a PR that is both shows only under Hidden.
        let hiddenAndPinned = Self.sections([direct, team], stacks: [], hidden: [direct.id], pinned: [direct.id])

        XCTAssertEqual(Self.ids(hidden), [.assigned: [], .direct: [], Self.teamSection: [team.id], .hidden: [direct.id]])
        XCTAssertEqual(Self.ids(hiddenAndPinned), Self.ids(hidden))
        XCTAssertEqual(hiddenAndPinned.map(\.id), [.assigned, .direct, Self.teamSection, .hidden])
    }

    func testPinnedAndHiddenAreAbsentWhenNothingIsPinnedOrHiddenAndRelationshipSectionsAlwaysShow() {
        XCTAssertEqual(Self.sections([], stacks: []).map(\.id), [.assigned, .direct, Self.teamSection])
        XCTAssertEqual(Self.sections([Self.pr("PR_DIRECT", .direct)], stacks: []).map(\.id), [.assigned, .direct, Self.teamSection])
    }

    func testSectionOrderIsPinnedAssignedDirectTeamsHidden() {
        let pinned = Self.pr("PR_PINNED", .team)
        let hidden = Self.pr("PR_HIDDEN", .assigned)

        let sections = Self.sections([pinned, hidden], stacks: [], hidden: [hidden.id], pinned: [pinned.id])

        XCTAssertEqual(sections.map(\.id), [.pinned, .assigned, .direct, Self.teamSection, .hidden])
        XCTAssertEqual(sections.map(\.title), ["Pinned", "Assigned", "Direct", "dev", "Hidden"])
        XCTAssertEqual(sections.map(\.accessibilityTitle), ["Pinned", "Assigned", "Direct", "@acme/dev", "Hidden"])
    }

    func testStackWithAPinnedOpenMemberIsOneCardInPinned() throws {
        let bottom = Self.pr("PR_BOTTOM", .direct, stack: "S")
        let top = Self.pr("PR_TOP", .team, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, bottom.id, .open), (2, top.id, .open)])

        let sections = Self.sections([bottom, top], stacks: [stack], pinned: [top.id])

        XCTAssertEqual(Self.ids(sections), [.pinned: [bottom.id], .assigned: [], .direct: [], Self.teamSection: []])
        let card = try XCTUnwrap(sections.first?.items.first)
        XCTAssertTrue(card.isPinned)
        XCTAssertEqual(card.stack?.fullMemberIDs, [bottom.id, top.id])
    }

    func testStackPinnedThroughADraftMemberStaysInPinnedWithReadySelected() throws {
        let ready = Self.pr("PR_READY", .direct, stack: "S")
        let draft = Self.pr("PR_DRAFT", .direct, draft: true, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, ready.id, .open), (2, draft.id, .open)])

        let sections = Self.sections([ready, draft], filters: [.ready], stacks: [stack], pinned: [draft.id])

        XCTAssertEqual(Self.ids(sections), [.pinned: [ready.id], .assigned: [], .direct: [], Self.teamSection: []])
        XCTAssertEqual(sections.first?.items.first?.isPinned, true)
    }

    func testStackWithEveryOpenMemberHiddenIsOneCardInHiddenAndStaysThereWithDraftSelected() throws {
        let ready = Self.pr("PR_READY", .direct, stack: "S")
        let draft = Self.pr("PR_DRAFT", .direct, draft: true, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, ready.id, .open), (2, draft.id, .open)])

        let all = Self.sections([ready, draft], stacks: [stack], hidden: [ready.id, draft.id], pinned: [draft.id])
        let draftOnly = Self.sections([ready, draft], filters: [.draft], stacks: [stack], hidden: [ready.id, draft.id])

        XCTAssertEqual(Self.ids(all), [.assigned: [], .direct: [], Self.teamSection: [], .hidden: [ready.id]])
        XCTAssertEqual(all.last?.items.first?.isHidden, true)
        XCTAssertEqual(all.last?.items.first?.isPinned, false)
        XCTAssertEqual(Self.ids(draftOnly), [.assigned: [], .direct: [], Self.teamSection: [], .hidden: [draft.id]])
    }

    func testPartlyHiddenStackStaysInItsRelationshipSectionWithReadySelectedAndShowsOnlyTheHiddenReadyMember() throws {
        let draft = Self.pr("PR_A", .direct, draft: true, stack: "S")
        let ready = Self.pr("PR_B", .direct, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, draft.id, .open), (2, ready.id, .open)])

        let sections = Self.sections([draft, ready], filters: [.ready], stacks: [stack], hidden: [ready.id])

        XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: [ready.id], Self.teamSection: []])
        let card = try XCTUnwrap(sections.first { $0.id == .direct }?.items.first)
        XCTAssertFalse(card.isHidden)
        XCTAssertEqual(card.stack?.matchingMemberIDs, [ready.id])
    }

    func testStackWithAnAssignedDraftMemberAndATeamReadyMemberStaysInAssignedWithReadySelected() throws {
        let team = Self.pr("PR_TEAM", .team, stack: "S")
        let assigned = Self.pr("PR_ASSIGNED", .assigned, draft: true, stack: "S")
        let stack = Self.stack("S", size: 3, [(1, "PR_MERGED", .merged), (2, team.id, .open), (3, assigned.id, .open)])

        let sections = Self.sections([team, assigned], filters: [.ready], stacks: [stack])

        XCTAssertEqual(Self.ids(sections), [.assigned: ["PR_TEAM"], .direct: [], Self.teamSection: []])
        let group = try XCTUnwrap(Self.row(team.id, in: sections)?.stack)
        XCTAssertEqual(group.members.first, .full(assigned))
        XCTAssertEqual(group.filterExcludedMemberCount, 1)
    }

    func testFilterMatchingNoPinnedOrHiddenPRKeepsPinnedAndHiddenWithCountZero() {
        let pinned = Self.pr("PR_PINNED", .direct, draft: true)
        let hidden = Self.pr("PR_HIDDEN", .team, draft: true)
        let ready = Self.pr("PR_READY", .assigned)

        let sections = Self.sections(
            [pinned, hidden, ready], filters: [.ready], stacks: [], hidden: [hidden.id], pinned: [pinned.id]
        )

        XCTAssertEqual(sections.map(\.id), [.pinned, .assigned, .direct, Self.teamSection, .hidden])
        XCTAssertEqual(sections.map(\.count), [0, 1, 0, 0, 0])
    }

    func testSectionCountIsItsNumberOfCardsSoAThreeMemberStackCountsOne() {
        let one = Self.pr("PR_1", .direct, stack: "S")
        let two = Self.pr("PR_2", .direct, stack: "S")
        let three = Self.pr("PR_3", .team, stack: "S")
        let standalone = Self.pr("PR_STANDALONE", .direct)
        let stack = Self.stack("S", size: 3, [(1, one.id, .open), (2, two.id, .open), (3, three.id, .open)])

        let sections = Self.sections([one, two, three, standalone], stacks: [stack])

        XCTAssertEqual(sections.map(\.count), [0, 2, 0])
    }

    func testCountsAcrossSectionsAddUpToTheCardsInTheTab() {
        let stacked = (1...3).map { Self.pr("PR_S\($0)", $0 == 2 ? .team : .direct, stack: "S") }
        let stack = Self.stack("S", size: 3, stacked.enumerated().map { ($0.offset + 1, $0.element.id, .open) })
        let others = [
            Self.pr("PR_A", .assigned), Self.pr("PR_D", .direct), Self.pr("PR_T", .team),
            Self.pr("PR_P", .team), Self.pr("PR_H", .direct)
        ]

        let sections = Self.sections(stacked + others, stacks: [stack], hidden: ["PR_H"], pinned: ["PR_P", "PR_S2"])

        let cards = sections.flatMap(\.items)
        XCTAssertEqual(cards.count, 6)
        XCTAssertEqual(Set(cards.map(\.id)).count, cards.count)
        XCTAssertEqual(sections.map(\.count).reduce(0, +), cards.count)
        XCTAssertEqual(sections.map(\.count), [2, 1, 1, 1, 1])
    }

    func testEachSectionIsSortedByTheSortOptionWithoutPinnedFirst() {
        let newest = Self.pr("PR_NEWEST", .direct, updated: 300)
        let pinnedStandalone = Self.pr("PR_PINNED", .direct, updated: 100)
        let representative = Self.pr("PR_REP", .direct, updated: 50, stack: "S")
        let pinnedMember = Self.pr("PR_MEMBER", .team, updated: 10, stack: "S")
        let older = Self.pr("PR_OLDER", .direct, updated: 20)
        let stack = Self.stack("S", size: 2, [(1, representative.id, .open), (2, pinnedMember.id, .open)])

        let sections = Self.sections(
            [newest, pinnedStandalone, representative, pinnedMember, older],
            stacks: [stack],
            pinned: [pinnedStandalone.id, pinnedMember.id]
        )

        XCTAssertEqual(Self.ids(sections), [
            .pinned: [pinnedStandalone.id, representative.id], .assigned: [], .direct: [newest.id, older.id], Self.teamSection: []
        ])
    }

    func testAuthoredWithNothingPinnedOrHiddenIsOneActiveSectionWithoutHeadings() {
        let sections = Self.list([Self.pr("PR_1", .mine), Self.pr("PR_2", .mine)], stacks: [])

        XCTAssertEqual(sections.map(\.id), [.active])
        XCTAssertEqual(sections.first?.title, "Active")
        XCTAssertEqual(sections.first?.count, 2)
        XCTAssertFalse(PullRequestListSection.showsHeadings(sections))
    }

    func testAuthoredWithOnePinnedPRIsPinnedAndActiveWithoutHidden() {
        let pinned = Self.pr("PR_PINNED", .mine)
        let other = Self.pr("PR_OTHER", .mine)

        let sections = Self.list([pinned, other], stacks: [], pinned: [pinned.id])

        XCTAssertEqual(Self.ids(sections), [.pinned: [pinned.id], .active: [other.id]])
        XCTAssertEqual(sections.map(\.id), [.pinned, .active])
        XCTAssertTrue(PullRequestListSection.showsHeadings(sections))
    }

    func testAuthoredWithEverythingPinnedHasActiveWithCountZero() {
        let one = Self.pr("PR_1", .mine)
        let two = Self.pr("PR_2", .mine)

        let sections = Self.list([one, two], stacks: [], pinned: [one.id, two.id])

        XCTAssertEqual(sections.map(\.id), [.pinned, .active])
        XCTAssertEqual(sections.map(\.count), [2, 0])
    }

    // MARK: - Team sections

    private static let platform = TeamReference(id: "T_PLATFORM", organization: "acme", slug: "platform")
    private static let web = TeamReference(id: "T_WEB", organization: "acme", slug: "web")
    private static let otherPlatform = TeamReference(id: "T_OTHER_PLATFORM", organization: "zeta", slug: "platform")
    /// acme: dev › web, and platform.
    private static let viewerTeams = [
        ViewerTeam(team: web, parentTeamID: devTeam.id),
        ViewerTeam(team: platform),
        ViewerTeam(team: devTeam)
    ]

    /// The requested PRs as the controller counts them for these turned-off teams.
    private static func counted(_ prs: [PullRequest], turnedOff: Set<String> = []) -> [PullRequest] {
        let counting = TeamReviewCounting(viewerTeams: viewerTeams, turnedOffTeamIDs: turnedOff)
        return prs.map(counting.applied(to:)).filter(DashboardController.isRequestedPullRequest)
    }

    func testOneSectionPerCountedTeamInSettingsOrderBetweenDirectAndHidden() {
        let hidden = Self.pr("PR_HIDDEN", .direct)
        let prs = Self.counted([hidden], turnedOff: [Self.platform.id])

        let sections = Self.sections(
            prs, stacks: [], viewerTeams: Self.viewerTeams, turnedOffTeamIDs: [Self.platform.id], hidden: [hidden.id]
        )

        XCTAssertEqual(sections.map(\.id), [.assigned, .direct, .team(id: Self.devTeam.id), .team(id: Self.web.id), .hidden])
        XCTAssertEqual(sections.map(\.title), ["Assigned", "Direct", "dev", "web", "Hidden"])
    }

    func testATeamWithNoPRsStillHasASectionWithCountZero() {
        let sections = Self.sections([], stacks: [], viewerTeams: Self.viewerTeams)

        XCTAssertEqual(sections[.team(id: Self.platform.id)]?.count, 0)
    }

    func testWithoutViewerTeamsThereAreNoTeamSectionsAndAssignedAndDirectStillShow() {
        let sections = Self.sections([Self.pr("PR_DIRECT", .direct)], stacks: [], viewerTeams: [])

        XCTAssertEqual(sections.map(\.id), [.assigned, .direct])
        XCTAssertTrue(PullRequestListSection.showsHeadings(sections))
    }

    func testAMultiTeamPRLandsOnceUnderTheChildTeam() {
        let pr = Self.pr("PR_MULTI", .team, teams: [Self.devTeam, Self.web, Self.platform])

        let sections = Self.sections(Self.counted([pr]), stacks: [], viewerTeams: Self.viewerTeams)

        XCTAssertEqual(sections.cardIDsByKind["team"], [pr.id])
        XCTAssertEqual(sections[.team(id: Self.web.id)]?.items.map(\.id), [pr.id])
    }

    func testTurningATeamOffMovesItsPRsToTheirNextCountedTeamOrOutOfTheList() {
        let both = Self.pr("PR_BOTH", .team, teams: [Self.web, Self.platform])
        let webOnly = Self.pr("PR_WEB", .team, teams: [Self.web])
        let turnedOff: Set<String> = [Self.web.id]

        let sections = Self.sections(
            Self.counted([both, webOnly], turnedOff: turnedOff), stacks: [],
            viewerTeams: Self.viewerTeams, turnedOffTeamIDs: turnedOff
        )

        XCTAssertNil(sections[.team(id: Self.web.id)])
        XCTAssertEqual(sections[.team(id: Self.platform.id)]?.items.map(\.id), [both.id])
        XCTAssertFalse(sections.allItems.contains { $0.id == webOnly.id })
    }

    func testAStackWhoseMembersRequestDifferentTeamsGoesUnderTheTeamPickedFromTheUnion() {
        let parent = Self.pr("PR_PARENT", .team, stack: "S", teams: [Self.devTeam])
        let child = Self.pr("PR_CHILD", .team, stack: "S", teams: [Self.web])
        let stack = Self.stack("S", size: 2, [(1, parent.id, .open), (2, child.id, .open)])

        let sections = Self.sections(Self.counted([parent, child]), stacks: [stack], viewerTeams: Self.viewerTeams)

        XCTAssertEqual(sections[.team(id: Self.web.id)]?.items.map(\.id), ["stack:S"])
        XCTAssertEqual(sections[.team(id: Self.devTeam.id)]?.count, 0)
    }

    func testAPinnedOrHiddenTeamPRIsInPinnedOrHiddenNotItsTeamSection() {
        let pinned = Self.pr("PR_PINNED", .team, teams: [Self.platform])
        let hidden = Self.pr("PR_HIDDEN", .team, teams: [Self.platform])

        let sections = Self.sections(
            Self.counted([pinned, hidden]), stacks: [], viewerTeams: Self.viewerTeams,
            hidden: [hidden.id], pinned: [pinned.id]
        )

        XCTAssertEqual(sections[.pinned]?.items.map(\.id), [pinned.id])
        XCTAssertEqual(sections[.hidden]?.items.map(\.id), [hidden.id])
        XCTAssertEqual(sections[.team(id: Self.platform.id)]?.count, 0)
    }

    func testCountsAcrossSectionsTeamSectionsIncludedAddUpToTheCards() {
        let prs = [
            Self.pr("PR_A", .assigned), Self.pr("PR_D", .direct),
            Self.pr("PR_DEV", .team, teams: [Self.devTeam]), Self.pr("PR_WEB", .team, teams: [Self.web]),
            Self.pr("PR_PLATFORM", .team, teams: [Self.platform]), Self.pr("PR_H", .team, teams: [Self.web])
        ]

        let sections = Self.sections(Self.counted(prs), stacks: [], viewerTeams: Self.viewerTeams, hidden: ["PR_H"])

        XCTAssertEqual(sections.map(\.count), [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(sections.map(\.count).reduce(0, +), prs.count)
    }

    func testTwoCountedTeamsWithTheSameSlugAreTitledOrgSlugAndAUniqueSlugBySlugAlone() {
        let teams = [ViewerTeam(team: Self.platform), ViewerTeam(team: Self.otherPlatform), ViewerTeam(team: Self.devTeam)]

        let sections = Self.sections([], stacks: [], viewerTeams: teams)

        XCTAssertEqual(sections.map(\.title), ["Assigned", "Direct", "dev", "acme/platform", "zeta/platform"])
    }

    func testATeamSectionsAccessibilityTitleIsOrgSlug() {
        let sections = Self.sections([], stacks: [], viewerTeams: Self.viewerTeams)

        XCTAssertEqual(sections[.team(id: Self.web.id)]?.accessibilityTitle, "@acme/web")
        XCTAssertEqual(sections[.team(id: Self.web.id)]?.title, "web")
    }

    // MARK: - Stacks

    func testOtherAuthorsOpenPRsInAnOwnStackAreContextMembers() throws {
        let own = Self.pr("PR_OWN", .mine, stack: "S")
        let requesting = Self.pr("PR_REQUESTING", .direct, stack: "S")
        let stack = Self.stack("S", size: 3, [(1, own.id, .open), (2, requesting.id, .open), (3, "PR_OTHER", .open)])

        let sections = Self.list([own], stacks: [stack])

        XCTAssertEqual(Self.ids(sections), [.active: [own.id]])
        let group = try XCTUnwrap(sections.first?.items.first?.stack)
        XCTAssertEqual(group.fullMemberIDs, [own.id])
        XCTAssertEqual(group.members, [.context(stack.entries[2]), .context(stack.entries[1]), .full(own)])
    }

    func testOwnPRWhoseEntryIsMergedIsAConsumedContextMember() throws {
        let stale = Self.pr("PR_STALE", .mine, stack: "S")
        let open = Self.pr("PR_OPEN", .mine, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, stale.id, .merged), (2, open.id, .open)])

        let sections = Self.list([stale, open], stacks: [stack])

        XCTAssertEqual(Self.ids(sections), [.active: [open.id]])
        let group = try XCTUnwrap(sections.first?.items.first?.stack)
        XCTAssertEqual(group.members.last, .context(stack.entries[0]))

        let onlyStale = Self.stack("S", size: 2, [(1, stale.id, .merged), (2, "PR_OTHER", .open)])
        let empty = Self.list([stale], stacks: [onlyStale])
        XCTAssertEqual(empty.map(\.id), [.active])
        XCTAssertEqual(empty.first?.items, [])
    }

    func testAttentionFilterRepresentsTheLowestUnreadOwnMember() throws {
        let bottom = Self.pr("PR_BOTTOM", .mine, stack: "S")
        let middle = Self.pr("PR_MIDDLE", .mine, stack: "S")
        let top = Self.pr("PR_TOP", .mine, stack: "S")
        let stack = Self.stack("S", size: 3, [(1, bottom.id, .open), (2, middle.id, .open), (3, top.id, .open)])

        let sections = Self.list(
            [bottom, middle, top], filters: [.needsAttention], stacks: [stack], unread: [middle.id, top.id]
        )

        let item = try XCTUnwrap(sections.first?.items.first)
        XCTAssertEqual(sections.first?.count, 1)
        XCTAssertEqual(item.representative.id, middle.id)
        XCTAssertEqual(item.stack?.representativePosition, 2)
        XCTAssertEqual(item.stack?.filterExcludedMemberCount, 1)
        XCTAssertEqual(item.stack?.additionalMemberCount, 2)
    }

    func testTwoRequestedMembersFormOneRowRepresentedByTheLowerPosition() throws {
        let lower = Self.pr("PR_LOW", .direct, stack: "S")
        let upper = Self.pr("PR_HIGH", .team, stack: "S")
        let other = Self.pr("PR_OTHER", .team)
        let stack = Self.stack("S", size: 2, [(1, lower.id, .open), (2, upper.id, .open)])

        let sections = Self.sections([lower, upper, other], stacks: [stack])

        XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: ["PR_LOW"], Self.teamSection: ["PR_OTHER"]])
        let row = try XCTUnwrap(Self.row(lower.id, in: sections))
        XCTAssertEqual(row.stack?.representativePosition, 1)
        XCTAssertEqual(row.stack?.fullMemberIDs, [lower.id, upper.id])
    }

    func testRepresentativeIsTheLowestMatchingMemberWhenTheFilterExcludesTheBottomOne() throws {
        let draft = Self.pr("PR_DRAFT", .direct, draft: true, stack: "S")
        let ready = Self.pr("PR_READY", .direct, stack: "S")
        let stack = Self.stack("S", size: 3, [(1, draft.id, .open), (2, ready.id, .open), (3, "PR_CONTEXT", .open)])

        let sections = Self.sections([draft, ready], filters: [.ready], stacks: [stack])

        let row = try XCTUnwrap(Self.row(ready.id, in: sections))
        XCTAssertEqual(row.stack?.representativePosition, 2)
        XCTAssertEqual(row.stack?.additionalMemberCount, 1)
        XCTAssertNil(Self.row(draft.id, in: sections))
    }

    func testAssignedMemberAboveATeamRequestedBottomMemberPlacesTheGroupInAssigned() throws {
        let team = Self.pr("PR_TEAM", .team, stack: "S")
        let assigned = Self.pr("PR_ASSIGNED", .assigned, draft: true, stack: "S")
        let stack = Self.stack("S", size: 3, [(1, "PR_MERGED", .merged), (2, team.id, .open), (3, assigned.id, .open)])

        let sections = Self.sections([team, assigned], stacks: [stack])

        XCTAssertEqual(Self.ids(sections), [.assigned: ["PR_TEAM"], .direct: [], Self.teamSection: []])
        XCTAssertEqual(sections.first { $0.id == .assigned }?.count, 1)
    }

    func testStackWithoutAMatchingRequestedMemberShowsNoRow() {
        let draft = Self.pr("PR_DRAFT", .direct, draft: true, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, draft.id, .open), (2, "PR_CONTEXT", .open)])

        let sections = Self.sections([draft], filters: [.ready], stacks: [stack])

        XCTAssertEqual(sections.map(\.id), [.assigned, .direct, Self.teamSection])
        XCTAssertTrue(sections.allSatisfy { $0.items.isEmpty && $0.count == 0 })
    }

    func testStackWithOnlyOneReadableRequestedEntryStillFormsAGroup() throws {
        let top = Self.pr("PR_TOP", .direct, stack: "S")
        let stack = Self.stack("S", size: 3, [(3, top.id, .open)])

        let group = try XCTUnwrap(Self.row(top.id, in: Self.sections([top], stacks: [stack]))?.stack)

        XCTAssertEqual(group.representativePosition, 3)
        XCTAssertEqual(group.stack.size, 3)
        XCTAssertEqual(group.additionalMemberCount, 0)
    }

    func testRequestedPRWhoseEntryIsMergedOrClosedIsAContextMember() throws {
        for state in [PullRequestStackEntry.State.merged, .closed] {
            let stale = Self.pr("PR_STALE", .assigned, stack: "S")
            let open = Self.pr("PR_OPEN", .team, stack: "S")
            let stack = Self.stack("S", size: 2, [(1, stale.id, state), (2, open.id, .open)])

            let sections = Self.sections([stale, open], stacks: [stack])

            XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: [], Self.teamSection: ["PR_OPEN"]], "\(state)")
            let group = try XCTUnwrap(Self.row(open.id, in: sections)?.stack)
            XCTAssertEqual(group.representativePosition, 2)
            XCTAssertEqual(group.fullMemberIDs, [open.id])
            XCTAssertEqual(group.additionalMemberCount, 0)
            XCTAssertEqual(group.members.last, .context(stack.entries[0]))
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

        XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: [unstamped.id], Self.teamSection: []])
        let group = try XCTUnwrap(Self.row(unstamped.id, in: sections)?.stack)
        XCTAssertEqual(group.fullMemberIDs, [unstamped.id, member.id])
        XCTAssertEqual(group.members, [.full(member), .full(unstamped)])
        XCTAssertEqual(sections.map(\.count), [0, 1, 0])
    }

    func testRequestedPRNamingAnotherStackJoinsTheStackThatListsIt() throws {
        let moved = Self.pr("PR_MOVED", .direct, stack: "OTHER")
        let member = Self.pr("PR_MEMBER", .direct, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, moved.id, .open), (2, member.id, .open)])

        let sections = Self.sections([moved, member], stacks: [stack])

        XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: [moved.id], Self.teamSection: []])
        let group = try XCTUnwrap(Self.row(moved.id, in: sections)?.stack)
        XCTAssertEqual(group.members, [.full(member), .full(moved)])
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
        XCTAssertEqual(groupB.fullMemberIDs, [shared.id, inB.id])
        let groupA = try XCTUnwrap(Self.row(inA.id, in: preferred)?.stack)
        XCTAssertEqual(groupA.fullMemberIDs, [inA.id])
        XCTAssertEqual(groupA.members, [.full(inA)])

        // Without a matching stack ID, the lowest stack ID wins.
        let unstamped = Self.pr("PR_SHARED", .direct)
        let lowest = Self.sections([unstamped, inA, inB], stacks: [stackB, stackA])
        let rows = lowest.flatMap(\.items)
        XCTAssertEqual(rows.map(\.representative.id).sorted(), [inA.id, inB.id])
        XCTAssertEqual(rows.first { $0.representative.id == inA.id }?.stack?.fullMemberIDs, [inA.id, unstamped.id])
        let other = try XCTUnwrap(rows.first { $0.representative.id == inB.id }?.stack)
        XCTAssertEqual(other.members, [.full(inB)])
        XCTAssertEqual(lowest.map(\.count), [0, 1, 1])
    }

    func testAdditionalRequestCountIgnoresTheFilterAndExcludedCountCountsFilteredMembers() throws {
        let one = Self.pr("PR_1", .direct, stack: "S")
        let two = Self.pr("PR_2", .direct, draft: true, stack: "S")
        let three = Self.pr("PR_3", .team, draft: true, stack: "S")
        let stack = Self.stack("S", size: 3, [(1, one.id, .open), (2, two.id, .open), (3, three.id, .open)])

        let unfiltered = try XCTUnwrap(Self.row(one.id, in: Self.sections([one, two, three], stacks: [stack]))?.stack)
        let ready = try XCTUnwrap(Self.row(one.id, in: Self.sections([one, two, three], filters: [.ready], stacks: [stack]))?.stack)

        XCTAssertEqual(unfiltered.additionalMemberCount, 2)
        XCTAssertEqual(unfiltered.filterExcludedMemberCount, 0)
        XCTAssertEqual(ready.additionalMemberCount, 2)
        XCTAssertEqual(ready.filterExcludedMemberCount, 2)
    }

    func testOneReadyAndOneDraftMemberWithReadySelectedCountsOneInTheSection() throws {
        let ready = Self.pr("PR_READY", .direct, stack: "S")
        let draft = Self.pr("PR_DRAFT", .direct, draft: true, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, ready.id, .open), (2, draft.id, .open)])

        let sections = Self.sections([ready, draft], filters: [.ready], stacks: [stack])

        let direct = try XCTUnwrap(sections.first { $0.id == .direct })
        XCTAssertEqual(direct.count, 1)
        XCTAssertEqual(direct.items.first?.stack?.additionalMemberCount, 1)
        XCTAssertEqual(direct.items.first?.stack?.filterExcludedMemberCount, 1)
    }

    func testFoldedInMembersCountInTheGroupsSectionAndNeverInTheirOwn() {
        let direct = Self.pr("PR_DIRECT", .direct, stack: "S")
        let team = Self.pr("PR_TEAM", .team, stack: "S")
        let teamToo = Self.pr("PR_TEAM_2", .team, stack: "S")
        let standalone = Self.pr("PR_STANDALONE", .team)
        let stack = Self.stack("S", size: 3, [(1, team.id, .open), (2, direct.id, .open), (3, teamToo.id, .open)])

        let sections = Self.sections([direct, team, teamToo, standalone], stacks: [stack])

        XCTAssertEqual(sections.map(\.count), [0, 1, 1])
        XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: ["PR_TEAM"], Self.teamSection: ["PR_STANDALONE"]])
    }

    func testHiddenBottomMemberWithAVisibleMemberAboveGivesAVisibleGroup() throws {
        let bottom = Self.pr("PR_BOTTOM", .direct, stack: "S")
        let above = Self.pr("PR_ABOVE", .direct, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, bottom.id, .open), (2, above.id, .open)])

        let sections = Self.sections([bottom, above], stacks: [stack], hidden: [bottom.id])

        XCTAssertEqual(Self.ids(sections), [.assigned: [], .direct: [above.id], Self.teamSection: []])
        let direct = try XCTUnwrap(sections.first { $0.id == .direct })
        XCTAssertEqual(direct.items.first?.stack?.representativePosition, 2)
        XCTAssertEqual(direct.items.first?.isHidden, false)
    }

    func testUnreadFoldedInMemberMarksTheGroupRowUnread() {
        let representative = Self.pr("PR_REP", .direct, stack: "S")
        let folded = Self.pr("PR_FOLDED", .team, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, representative.id, .open), (2, folded.id, .open)])

        let row = Self.row(representative.id, in: Self.sections([representative, folded], stacks: [stack], unread: [folded.id]))

        XCTAssertEqual(row?.isUnread, true)
    }

    func testNonRequestedEntriesBecomeContextMembersTopOfTheStackFirst() throws {
        let requested = Self.pr("PR_REQUESTED", .direct, stack: "S")
        let stack = Self.stack("S", size: 6, [
            (6, "PR_OWN", .open), (1, "PR_MERGED", .merged), (3, requested.id, .open),
            (2, "PR_CLOSED", .closed), (5, "PR_OTHER_OPEN", .open)
        ])

        let group = try XCTUnwrap(Self.row(requested.id, in: Self.sections([requested], stacks: [stack]))?.stack)

        XCTAssertEqual(group.members.map(\.pullRequestID), ["PR_OWN", "PR_OTHER_OPEN", "PR_REQUESTED", "PR_CLOSED", "PR_MERGED"])
        XCTAssertEqual(group.members.map { group.position(of: $0) }, [6, 5, 3, 2, 1])
        for member in group.members where member.pullRequestID != requested.id {
            guard case .context = member else { return XCTFail("\(member.pullRequestID) should be a context member") }
        }
        XCTAssertEqual(group.members[2], .full(requested))
    }

    // MARK: - Card identity

    func testStackCardKeepsItsIDWhenHidingItsRepresentativeChangesTheRepresentative() throws {
        let bottom = Self.pr("PR_BOTTOM", .direct, stack: "S")
        let above = Self.pr("PR_ABOVE", .direct, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, bottom.id, .open), (2, above.id, .open)])

        let before = try XCTUnwrap(Self.sections([bottom, above], stacks: [stack]).flatMap(\.items).first)
        let after = try XCTUnwrap(Self.sections([bottom, above], stacks: [stack], hidden: [bottom.id]).flatMap(\.items).first)

        XCTAssertEqual(before.representative.id, bottom.id)
        XCTAssertEqual(after.representative.id, above.id)
        XCTAssertEqual(before.id, after.id)
    }

    func testStackCardKeepsItsIDWhenTheFilterChangesTheRepresentative() throws {
        let draft = Self.pr("PR_DRAFT", .direct, draft: true, stack: "S")
        let ready = Self.pr("PR_READY", .direct, stack: "S")
        let stack = Self.stack("S", size: 2, [(1, draft.id, .open), (2, ready.id, .open)])

        let all = try XCTUnwrap(Self.sections([draft, ready], stacks: [stack]).flatMap(\.items).first)
        let readyOnly = try XCTUnwrap(Self.sections([draft, ready], filters: [.ready], stacks: [stack]).flatMap(\.items).first)

        XCTAssertEqual(all.representative.id, draft.id)
        XCTAssertEqual(readyOnly.representative.id, ready.id)
        XCTAssertEqual(all.id, readyOnly.id)
    }

    func testStandaloneCardIDIsItsPRID() throws {
        let standalone = Self.pr("PR_STANDALONE", .direct)

        let item = try XCTUnwrap(Self.sections([standalone], stacks: []).flatMap(\.items).first)

        XCTAssertEqual(item.id, standalone.id)
    }

    // MARK: - pr-stacks mock scenario

    private static func prStacksSections(filters: Set<ReviewRequestFilterOption> = []) -> [PullRequestListSection] {
        let source = MockPullRequestSource(scenario: .prStacks)
        let counting = TeamReviewCounting(viewerTeams: source.viewerTeams, turnedOffTeamIDs: [])
        let requested = source.firstRefreshPullRequests.map(counting.applied(to:))
            .filter(DashboardController.isRequestedPullRequest)
        return PullRequestStackGrouping.requestedSections(
            requested: requested,
            matching: DashboardController.filteredReviewRequests(requested, by: filters),
            stacks: source.stacks,
            teamCounting: counting,
            hiddenIDs: [], pinnedIDs: [], unreadIDs: [],
            sortOption: .createdDate, sortDirection: .descending
        )
    }

    private static func prStacksGroup(_ stackID: String) throws -> (row: PullRequestListItem, group: StackGroup) {
        let row = try XCTUnwrap(prStacksSections().flatMap(\.items).first { $0.stack?.stack.id == stackID }, stackID)
        return (row, try XCTUnwrap(row.stack, stackID))
    }

    func testAcceptanceStacksGroupUnderTheirAssignedPositionTwoMember() throws {
        // The all-open stack's position-3 member is a draft, so it shows Draft before its state.
        let positionOneStates: [(String, StackMemberBadge, [StackMemberBadge])] = [
            ("STACK_MOCK_ALL_OPEN", .open, [.draft, .open]),
            ("STACK_MOCK_PARTIALLY_MERGED", .merged, [.open]),
            ("STACK_MOCK_CLOSED_DEPENDENCY", .closed, [.open])
        ]
        let assigned = try XCTUnwrap(Self.prStacksSections().first { $0.id == .assigned })
        for (stackID, positionOneState, positionThreeBadges) in positionOneStates {
            let (row, group) = try Self.prStacksGroup(stackID)
            XCTAssertEqual(row.representative.id, "PR_\(stackID)_2", stackID)
            XCTAssertTrue(assigned.items.contains(row), "assigned, \(stackID)")
            XCTAssertEqual(group.stack.size, 3, stackID)
            XCTAssertEqual(group.members.map { group.position(of: $0) }, [3, 2, 1], stackID)
            XCTAssertEqual(group.fullMemberIDs, [row.representative.id], stackID)
            XCTAssertEqual(
                StackControlPresentation(group: group, memberNoun: .reviewRequests, displayedPosition: group.representativePosition, isExpanded: false).fractionText,
                "2/3", stackID
            )
            XCTAssertEqual(group.contextBadges, [positionThreeBadges, [positionOneState]], stackID)
        }
    }

    func testPositionThreeStackIsRepresentedByItsTopMember() throws {
        let (row, group) = try Self.prStacksGroup("STACK_MOCK_POSITION_3")

        XCTAssertEqual(row.representative.id, "PR_STACK_MOCK_POSITION_3_3")
        XCTAssertEqual(group.representativePosition, 3)
        XCTAssertEqual(
            StackControlPresentation(group: group, memberNoun: .reviewRequests, displayedPosition: group.representativePosition, isExpanded: false).fractionText,
            "3/3"
        )
        XCTAssertEqual(group.contextBadges, [[.open], [.merged]])
    }

    func testMergedAndClosedContextMembersNeverRepresentAGroupOrCountInASection() throws {
        let source = MockPullRequestSource(scenario: .prStacks)
        let entries = Dictionary(source.stacks.flatMap(\.entries).map { ($0.pullRequestID, $0) }, uniquingKeysWith: { first, _ in first })
        let sections = Self.prStacksSections()
        let rows = sections.flatMap(\.items)

        let finished = Set(entries.values.filter { $0.state != .open }.map(\.pullRequestID))
        XCTAssertEqual(finished.count, 8)
        for row in rows {
            XCTAssertFalse(finished.contains(row.representative.id), row.id)
            XCTAssertTrue(row.stack?.fullMemberIDs.isDisjoint(with: finished) ?? true, row.id)
        }
        // Every requested PR is in exactly one card, and each section counts its cards.
        let requested = source.firstRefreshPullRequests.filter(DashboardController.isRequestedPullRequest)
        XCTAssertTrue(Set(requested.map(\.id)).isDisjoint(with: finished))
        XCTAssertEqual(rows.map { $0.stack?.matchingMemberIDs.count ?? 1 }.reduce(0, +), requested.count)
        XCTAssertEqual(sections.map(\.count), [5, 6, 0, 1])
    }

    // MARK: - Fixtures

    private enum Role {
        case assigned, direct, team, mine
    }

    private static func pr(
        _ id: String,
        _ role: Role,
        draft: Bool = false,
        updated: TimeInterval = 0,
        stack: String? = nil,
        teams: [TeamReference] = [devTeam]
    ) -> PullRequest {
        PullRequest(
            id: id, title: id, number: abs(id.hashValue % 1000),
            url: URL(string: "https://github.com/acme/app/pull/1")!, repo: "acme/app",
            ciState: .passing, reviewDecision: .reviewRequired, commentCount: 0, reviewCount: 0,
            reviewRequestKind: role == .direct ? .direct : role == .team ? .team : .none,
            requestedTeams: role == .team ? teams : [],
            isAssignedToViewer: role == .assigned, isMine: role == .mine, author: role == .mine ? "viewer" : "author",
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

    /// The one counted team that every `.team` fixture PR requests.
    private static let devTeam = TeamReference(id: "T_DEV", organization: "acme", slug: "dev")
    private static let teamSection = PullRequestSectionID.team(id: devTeam.id)

    private static func sections(
        _ requested: [PullRequest],
        filters: Set<ReviewRequestFilterOption> = [],
        stacks: [PullRequestStack],
        viewerTeams: [ViewerTeam] = [ViewerTeam(team: devTeam)],
        turnedOffTeamIDs: Set<String> = [],
        hidden: Set<String> = [],
        pinned: Set<String> = [],
        unread: Set<String> = []
    ) -> [PullRequestListSection] {
        PullRequestStackGrouping.requestedSections(
            requested: requested,
            matching: DashboardController.filteredReviewRequests(requested, by: filters),
            stacks: stacks,
            teamCounting: TeamReviewCounting(viewerTeams: viewerTeams, turnedOffTeamIDs: turnedOffTeamIDs),
            hiddenIDs: hidden,
            pinnedIDs: pinned,
            unreadIDs: unread,
            sortOption: .updatedDate,
            sortDirection: .descending
        )
    }

    private static func list(
        _ own: [PullRequest],
        filters: Set<PullRequestFilterOption> = [],
        stacks: [PullRequestStack],
        hidden: Set<String> = [],
        pinned: Set<String> = [],
        unread: Set<String> = []
    ) -> [PullRequestListSection] {
        PullRequestStackGrouping.authoredSections(
            members: own,
            matching: DashboardController.filtered(own, by: filters, attentionPullRequestIds: unread),
            stacks: stacks,
            hiddenIDs: hidden,
            pinnedIDs: pinned,
            unreadIDs: unread,
            sortOption: .createdDate,
            sortDirection: .descending
        )
    }

    /// Each section's cards by representative PR ID.
    private static func ids(_ sections: [PullRequestListSection]) -> [PullRequestSectionID: [String]] {
        Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.items.map(\.representative.id)) })
    }

    private static func row(_ id: String, in sections: [PullRequestListSection]) -> PullRequestListItem? {
        sections.flatMap(\.items).first { $0.representative.id == id }
    }
}

extension Array where Element == PullRequestListSection {
    subscript(_ id: PullRequestSectionID) -> PullRequestListSection? {
        first { $0.id == id }
    }

    var allItems: [PullRequestListItem] { flatMap(\.items) }
}

extension PullRequestSectionID {
    /// The section's kind, with every team section as "team".
    var kind: String {
        switch self {
        case .pinned: "pinned"
        case .active: "active"
        case .assigned: "assigned"
        case .direct: "direct"
        case .team: "team"
        case .hidden: "hidden"
        }
    }

    /// One team section per counted team, in Settings order.
    static func teamSections(_ viewerTeams: [ViewerTeam], turnedOff: Set<String> = []) -> [PullRequestSectionID] {
        TeamReviewCounting(viewerTeams: viewerTeams, turnedOffTeamIDs: turnedOff).sectionTeams.map { .team(id: $0.id) }
    }
}

extension Array where Element == PullRequestListSection {
    /// Each section kind's cards by representative PR ID, sorted, with every team section's cards under "team".
    var cardIDsByKind: [String: [String]] {
        Dictionary(map { ($0.id.kind, $0.items.map(\.representative.id)) }, uniquingKeysWith: +).mapValues { $0.sorted() }
    }
}
