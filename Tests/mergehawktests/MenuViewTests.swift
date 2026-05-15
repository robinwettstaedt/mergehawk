@testable import mergehawk
import AppKit
import Foundation
import mergehawkcore

@MainActor let mergehawkMenuViewTest: Void = {
    precondition(DashboardController.MenuTab.allCases.map(\.rawValue) == ["Notifications", "My PRs", "Review Requests"])
    precondition(CIStatusIndicator.Kind(ciState: .failing) == .failing)
    precondition(CIStatusIndicator.Kind(ciState: .pending) == .running)
    precondition(CIStatusIndicator.Kind(ciState: .passing) == .successful)

    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .approved) == .approved)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .changesRequested) == .changesRequested)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .reviewRequired) == .reviewRequired)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .unknown) == .unknown)

    let prURL = URL(string: "https://github.com/acme/mergehawk/pull/12")!
    precondition(PullRequestLinkCopyButton.clipboardString(for: prURL) == "https://github.com/acme/mergehawk/pull/12")
    precondition(CommentCountIndicator.label(for: 3) == "3 comments")
    precondition(CommentCountIndicator.label(for: 1) == "1 comment")
    precondition(GitHubTokenSignInView.Copy.title == "Connect GitHub")
    precondition(GitHubTokenSignInView.Copy.fieldPrompt == "github_pat_...")

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("mergehawk-menu-view-test"))
    pasteboard.clearContents()
    pasteboard.setString("  github_pat_test  ", forType: .string)
    precondition(GitHubTokenSignInView.tokenString(from: pasteboard) == "github_pat_test")

    var dropdownState = PullRequestMenuDropdownState()
    precondition(dropdownState.openMenu == nil)
    dropdownState.toggle(.filter)
    precondition(dropdownState.openMenu == .filter)
    dropdownState.toggle(.sort)
    precondition(dropdownState.openMenu == .sort)
    dropdownState.dismiss()
    precondition(dropdownState.openMenu == nil)

    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0
    )
    let statusBarController = StatusBarController(controller: controller)
    let statusMenuItems = statusBarController.rebuildMenuForTesting()
    precondition(statusMenuItems.count == 6)
    precondition(statusMenuItems[0].view != nil)
    precondition(statusMenuItems[1].view != nil)
    precondition(statusMenuItems[1].isSeparatorItem == false)
    precondition(statusMenuItems[2].title == "Refresh")
    precondition(statusMenuItems[2].keyEquivalent == "")
    precondition(statusMenuItems[2].action == NSSelectorFromString("refresh"))
    precondition(statusMenuItems[2].target as AnyObject? === statusBarController)
    precondition(statusMenuItems[2].view != nil)
    precondition(statusMenuItems[3].title == "Settings")
    precondition(statusMenuItems[3].keyEquivalent == ",")
    precondition(statusMenuItems[4].title == "About MergeHawk")
    precondition(statusMenuItems[4].isSeparatorItem == false)
    precondition(statusMenuItems[5].title == "Quit")
    precondition(statusMenuItems[5].keyEquivalent == "q")
    precondition(statusMenuItems.dropFirst(2).contains(where: \.isSeparatorItem) == false)

    precondition(isRefreshKeyEvent(keyEvent(characters: "r", modifiers: .command)))
    precondition(isRefreshKeyEvent(keyEvent(characters: "R", modifiers: .command)))
    precondition(!isRefreshKeyEvent(keyEvent(characters: "r", modifiers: [])))
    precondition(!isRefreshKeyEvent(keyEvent(characters: "q", modifiers: .command)))
    precondition(!isRefreshKeyEvent(keyEvent(characters: "r", modifiers: [.command, .shift])))
    precondition(statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: .command)))
    precondition(!statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: [])))

    let older = PullRequest(
        id: "older",
        title: "Older PR",
        number: 1,
        url: URL(string: "https://github.com/acme/mergehawk/pull/1")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .approved,
        commentCount: 0,
        reviewCount: 1,
        isMine: true,
        author: "rw",
        mergeable: .mergeable,
        draft: false,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 400)
    )
    let newer = PullRequest(
        id: "newer",
        title: "Newer PR",
        number: 2,
        url: URL(string: "https://github.com/acme/mergehawk/pull/2")!,
        repo: "acme/mergehawk",
        ciState: .failing,
        reviewDecision: .changesRequested,
        commentCount: 2,
        reviewCount: 0,
        isMine: true,
        author: "rw",
        mergeable: .conflicting,
        draft: false,
        createdAt: Date(timeIntervalSince1970: 200),
        updatedAt: Date(timeIntervalSince1970: 300)
    )
    let draft = PullRequest(
        id: "draft",
        title: "Draft PR",
        number: 3,
        url: URL(string: "https://github.com/acme/mergehawk/pull/3")!,
        repo: "acme/mergehawk",
        ciState: .pending,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        isMine: true,
        author: "rw",
        mergeable: .unknown,
        draft: true,
        createdAt: Date(timeIntervalSince1970: 300),
        updatedAt: Date(timeIntervalSince1970: 500)
    )
    let event = PullRequestEvent(type: .ciFailed, prId: "newer")

    precondition(DashboardController.PullRequestSortOption.allCases.map(\.label) == ["Created", "Updated"])
    precondition(DashboardController.ReviewRequestFilterOption.allCases.map(\.label) == ["Direct", "Team", "All", "Draft", "Ready"])
    precondition(DashboardController.sorted([older, newer], by: .createdDate).map(\.id) == ["newer", "older"])
    precondition(DashboardController.sorted([older, newer], by: .updatedDate).map(\.id) == ["older", "newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: .all, events: [event]).map(\.id) == ["older", "newer", "draft"])
    precondition(DashboardController.filtered([older, newer, draft], by: .needsAttention, events: [event]).map(\.id) == ["newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: .draft, events: [event]).map(\.id) == ["draft"])
    precondition(DashboardController.filtered([older, newer, draft], by: .ready, events: [event]).map(\.id) == ["older", "newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: .changesRequested, events: [event]).map(\.id) == ["newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: .reviewRequired, events: [event]).map(\.id) == ["draft"])
    precondition(DashboardController.filtered([older, newer, draft], by: .approved, events: [event]).map(\.id) == ["older"])
    precondition(DashboardController.filtered([older, newer, draft], by: .ciFailing, events: [event]).map(\.id) == ["newer"])

    let directReview = PullRequest(
        id: "direct",
        title: "Direct review",
        number: 4,
        url: URL(string: "https://github.com/acme/mergehawk/pull/4")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        reviewRequestKind: .direct,
        isMine: false,
        author: "teammate",
        mergeable: .mergeable,
        draft: false
    )
    let teamReview = PullRequest(
        id: "team",
        title: "Team review",
        number: 5,
        url: URL(string: "https://github.com/acme/mergehawk/pull/5")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        reviewRequestKind: .team,
        isMine: false,
        author: "teammate",
        mergeable: .mergeable,
        draft: false
    )
    let directAndTeamReview = PullRequest(
        id: "direct-team",
        title: "Direct and team review",
        number: 6,
        url: URL(string: "https://github.com/acme/mergehawk/pull/6")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        reviewRequestKind: .directAndTeam,
        isMine: false,
        author: "teammate",
        mergeable: .mergeable,
        draft: false
    )
    let draftDirectReview = PullRequest(
        id: "draft-direct",
        title: "Draft direct review",
        number: 7,
        url: URL(string: "https://github.com/acme/mergehawk/pull/7")!,
        repo: "acme/mergehawk",
        ciState: .failing,
        reviewDecision: .changesRequested,
        commentCount: 3,
        reviewCount: 1,
        reviewRequestKind: .direct,
        isMine: false,
        author: "teammate",
        mergeable: .unknown,
        draft: true
    )
    let reviewRequests = [older, directReview, teamReview, directAndTeamReview, draftDirectReview]
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: .direct).map(\.id) == ["direct", "direct-team", "draft-direct"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: .team).map(\.id) == ["team", "direct-team"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: .all).map(\.id) == ["direct", "team", "direct-team", "draft-direct"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: .draft).map(\.id) == ["draft-direct"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: .ready).map(\.id) == ["direct", "team", "direct-team"])
}()

private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    )!
}
