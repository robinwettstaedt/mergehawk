@testable import mergehawk
import AppKit
import Foundation
import mergehawkcore

@MainActor let mergehawkMenuViewTest: Void = {
    precondition(DashboardController.MenuTab.allCases.map(\.rawValue) == ["Notifications", "Authored", "Requested"])
    precondition(DashboardController.NotificationSubtab.allCases.map(\.rawValue) == ["PRs", "Other"])
    precondition(MenuTabShortcutHint.title(for: .notifications) == "⌘1")
    precondition(MenuTabShortcutHint.title(for: .myPRs) == "⌘2")
    precondition(MenuTabShortcutHint.title(for: .reviewRequests) == "⌘3")
    precondition(MenuNotificationTabPresentation.label(for: 0).isEmpty)
    precondition(MenuNotificationTabPresentation.label(for: 1) == "1")
    precondition(MenuNotificationTabPresentation.label(for: 3) == "3")
    precondition(MenuNotificationTabPresentation.help(for: 0) == "Notifications")
    precondition(MenuNotificationTabPresentation.help(for: 1) == "1 new PR update")
    precondition(MenuNotificationTabPresentation.help(for: 3) == "3 new PR updates")
    precondition(CIStatusIndicator.Kind(ciState: .failing) == .failing)
    precondition(CIStatusIndicator.Kind(ciState: .pending) == .running)
    precondition(CIStatusIndicator.Kind(ciState: .passing) == .successful)

    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .approved) == .approved)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .changesRequested) == .changesRequested)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .reviewRequired) == .reviewRequired)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .unknown) == .unknown)

    let prURL = URL(string: "https://github.com/acme/mergehawk/pull/12")!
    precondition(PullRequestLinkCopyButton.clipboardString(for: prURL) == "https://github.com/acme/mergehawk/pull/12")
    precondition(CommentCountIndicator.label(for: 3) == "3 unresolved comments")
    precondition(CommentCountIndicator.label(for: 1) == "1 unresolved comment")
    precondition(GitHubSignInView.Copy.title == "Connect GitHub")
    precondition(GitHubSignInView.Copy.buttonTitle == "Sign in with GitHub")
    precondition(GitHubSignInView.Copy.permissionText.contains("only reads GitHub data"))
    let templateStatusIcon = StatusIcon.make(attention: false)
    precondition(templateStatusIcon.isTemplate)
    precondition(templateStatusIcon.size == NSSize(width: 26.5, height: 16))
    let attentionStatusIcon = StatusIcon.make(attention: true)
    precondition(!attentionStatusIcon.isTemplate)
    precondition(attentionStatusIcon.size == NSSize(width: 29, height: 18))

    var dropdownState = PullRequestMenuDropdownState()
    precondition(dropdownState.openMenu == nil)
    dropdownState.toggle(.filter)
    precondition(dropdownState.openMenu == .filter)
    dropdownState.toggle(.sort)
    precondition(dropdownState.openMenu == .sort)
    dropdownState.dismiss()
    precondition(dropdownState.openMenu == nil)

    precondition(CountSearchPresentation.countLabel(for: 0, singular: "PR", plural: "PRs") == "0 PRs")
    precondition(CountSearchPresentation.countLabel(for: 1, singular: "PR", plural: "PRs") == "1 PR")
    precondition(CountSearchPresentation.countLabel(for: 9, singular: "PR", plural: "PRs") == "9 PRs")
    precondition(NotificationTimestampPresentation.label(
        for: Date(timeIntervalSince1970: 60 * 60),
        timeZone: TimeZone(secondsFromGMT: 0)!
    ) == "01:00")
    precondition(NotificationReadPresentation.symbolName == "envelope.open")
    precondition(NotificationReadPresentation.markAllTitle == "Mark all as read")
    precondition(NotificationReadPresentation.markAllHelp == "Mark all notifications as read")
    precondition(NotificationReadPresentation.markOneHelp == "Mark as read")
    precondition(NotificationReadPresentation.markPRAccessibilityLabel == "Mark PR notification as read")
    precondition(NotificationReadPresentation.markOtherAccessibilityLabel == "Mark other notification as read")
    precondition(PullRequestListCopy.emptyAuthored == "No authored PRs.")
    precondition(PullRequestListCopy.emptyReviewRequests == "No review requests.")
    precondition(PullRequestListCopy.noFilterMatches == "No PRs match these filters.")
    let otherCommitNotificationPullRequest = PullRequest(
        id: "other-commit",
        title: "Other commit notification",
        number: 13,
        url: URL(string: "https://github.com/acme/mergehawk/pull/13")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        isMine: true,
        author: "rw",
        mergeable: .mergeable,
        draft: false
    )
    precondition(PullRequestNotificationTitlePresentation.title(for: PullRequestNotification(
        event: PullRequestEvent(type: .otherCommitAdded, prId: "other-commit", count: 1, actorLogin: "frontend-sam"),
        pullRequest: otherCommitNotificationPullRequest
    )) == "New commit by @frontend-sam")
    precondition(PullRequestNotificationTitlePresentation.title(for: PullRequestNotification(
        event: PullRequestEvent(type: .otherCommitAdded, prId: "other-commit", count: 2),
        pullRequest: otherCommitNotificationPullRequest
    )) == "2 commits by others")
    let metadataPullRequest = PullRequest(
        id: "metadata",
        title: "Metadata presentation",
        number: 12,
        url: URL(string: "https://github.com/acme/mergehawk/pull/12")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        isMine: true,
        author: "rw",
        headRefName: "feature/metadata",
        mergeable: .mergeable,
        draft: false
    )
    precondition(PullRequestRowMetadataPresentation.text(
        for: metadataPullRequest,
        showsAuthor: false
    ) == "acme/mergehawk")
    precondition(PullRequestRowMetadataPresentation.text(
        for: metadataPullRequest,
        showsAuthor: true
    ) == "acme/mergehawk · @rw")
    precondition(PullRequestRowMetadataPresentation.branchText(
        for: metadataPullRequest
    ) == "feature/metadata")
    precondition(PullRequestPinPresentation.symbolName(isPinned: false) == "pin")
    precondition(PullRequestPinPresentation.symbolName(isPinned: true) == "pin.fill")
    precondition(PullRequestPinPresentation.label(isPinned: false) == "Pin PR")
    precondition(PullRequestPinPresentation.label(isPinned: true) == "Unpin PR")
    precondition(PullRequestPinPresentation.rotationDegrees == 35.0)

    var searchState = ExpandableSearchState()
    precondition(!searchState.isExpanded)
    searchState.expand()
    precondition(searchState.isExpanded)
    searchState.blur()
    precondition(!searchState.isExpanded)
    searchState.expand()
    searchState.query = "billing"
    searchState.blur()
    precondition(searchState.isExpanded)
    searchState.handleEscape()
    precondition(searchState.query.isEmpty)
    precondition(searchState.isExpanded)
    searchState.handleEscape()
    precondition(!searchState.isExpanded)

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
    precondition(menuTabShortcut(for: keyEvent(characters: "1", modifiers: .command)) == .notifications)
    precondition(menuTabShortcut(for: keyEvent(characters: "2", modifiers: .command)) == .myPRs)
    precondition(menuTabShortcut(for: keyEvent(characters: "3", modifiers: .command)) == .reviewRequests)
    precondition(menuTabShortcut(for: keyEvent(characters: "1", modifiers: [])) == nil)
    precondition(menuTabShortcut(for: keyEvent(characters: "1", modifiers: [.command, .shift])) == nil)
    precondition(menuTabShortcut(for: keyEvent(characters: "4", modifiers: .command)) == nil)
    precondition(menuTabShortcut(for: keyEvent(characters: "r", modifiers: .command)) == nil)
    precondition(!statusBarController.refreshMenuItemIsSelectedForTesting())
    precondition(statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: .command)))
    precondition(statusBarController.refreshMenuItemIsSelectedForTesting())
    precondition(!statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: [])))
    precondition(statusBarController.performRefreshMenuItemKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: .command)))
    precondition(!statusBarController.performRefreshMenuItemKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: [])))

    controller.selectedTab = .reviewRequests
    precondition(!statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "1", modifiers: .command)))
    precondition(controller.selectedTab == .reviewRequests)

    let signedInController = signedInMockController()
    let signedInStatusBarController = StatusBarController(controller: signedInController)
    _ = signedInStatusBarController.rebuildMenuForTesting()
    signedInController.selectedTab = .reviewRequests
    let revealedMenuItems = signedInStatusBarController.showMenuForTesting(selecting: .notifications)
    precondition(signedInController.selectedTab == .notifications)
    precondition(revealedMenuItems.count == 6)
    precondition(revealedMenuItems[0].view != nil)
    signedInController.selectedTab = .reviewRequests
    precondition(signedInStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "1", modifiers: .command)))
    precondition(signedInController.selectedTab == .notifications)
    precondition(signedInStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "2", modifiers: .command)))
    precondition(signedInController.selectedTab == .myPRs)
    precondition(signedInStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "3", modifiers: .command)))
    precondition(signedInController.selectedTab == .reviewRequests)
    precondition(!signedInStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "4", modifiers: .command)))
    precondition(signedInController.selectedTab == .reviewRequests)
    precondition(!signedInStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "1", modifiers: [.command, .shift])))
    precondition(signedInController.selectedTab == .reviewRequests)

    _ = signedInStatusBarController.showMenuForTesting(selecting: .myPRs)
    precondition(signedInController.selectedTab == .myPRs)
    _ = signedInStatusBarController.showMenuForTesting(selecting: .reviewRequests)
    precondition(signedInController.selectedTab == .reviewRequests)

    let markAllController = signedInMockController()
    let markAllStatusBarController = StatusBarController(controller: markAllController)
    precondition(!markAllStatusBarController.statusButtonHasAttentionForTesting())
    markAllController.refresh()
    waitUntil(timeout: 1.0) {
        markAllController.attentionCount == 2 && markAllStatusBarController.statusButtonHasAttentionForTesting()
    }
    markAllController.markAllNotificationsRead()
    waitUntil(timeout: 1.0) {
        markAllController.attentionCount == 0 && !markAllStatusBarController.statusButtonHasAttentionForTesting()
    }

    let markOneController = signedInMockController()
    let markOneStatusBarController = StatusBarController(controller: markOneController)
    markOneController.refresh()
    waitUntil(timeout: 1.0) {
        markOneController.attentionCount == 2 && markOneStatusBarController.statusButtonHasAttentionForTesting()
    }
    markOneController.markPullRequestNotificationRead(markOneController.visiblePullRequestNotifications[0])
    waitUntil(timeout: 1.0) {
        markOneController.attentionCount == 1 && markOneStatusBarController.statusButtonHasAttentionForTesting()
    }
    if let unreadNotification = markOneController.visiblePullRequestNotifications.first(where: { !$0.read }) {
        markOneController.markPullRequestNotificationRead(unreadNotification)
    }
    waitUntil(timeout: 1.0) {
        markOneController.attentionCount == 0 && !markOneStatusBarController.statusButtonHasAttentionForTesting()
    }

    let sourceFilteredController = signedInMockController()
    let sourceFilteredStatusBarController = StatusBarController(controller: sourceFilteredController)
    sourceFilteredController.refresh()
    waitUntil(timeout: 1.0) {
        sourceFilteredController.attentionCount == 2 && sourceFilteredStatusBarController.statusButtonHasAttentionForTesting()
    }
    sourceFilteredController.setOwnerPreferences(
        owner: "example",
        preferences: OwnerSourcePreferences(
            notifications: false,
            myPullRequests: true,
            reviewRequests: true
        )
    )
    waitUntil(timeout: 1.0) {
        sourceFilteredController.attentionCount == 0
            && !sourceFilteredStatusBarController.statusButtonHasAttentionForTesting()
    }

    let inboxOnlyController = signedInMockController()
    waitUntil(timeout: 1.0) {
        inboxOnlyController.visibleGitHubInboxNotifications.filter(\.unread).count == 1
    }
    let inboxOnlyStatusBarController = StatusBarController(controller: inboxOnlyController)
    precondition(inboxOnlyController.attentionCount == 0)
    precondition(!inboxOnlyStatusBarController.statusButtonHasAttentionForTesting())

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
        headRefName: "older-branch",
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
        headRefName: "feature/newer",
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
        headRefName: "draft-flow",
        mergeable: .unknown,
        draft: true,
        createdAt: Date(timeIntervalSince1970: 300),
        updatedAt: Date(timeIntervalSince1970: 500)
    )
    let event = PullRequestEvent(type: .ciFailed, prId: "newer")

    precondition(DashboardController.PullRequestSortOption.allCases.map(\.label) == ["Created", "Updated"])
    precondition(DashboardController.ReviewRequestFilterOption.allCases.map(\.label) == ["All", "Direct", "Team", "Assigned", "Draft", "Ready"])
    precondition(DashboardController.sorted([older, newer], by: .createdDate).map(\.id) == ["newer", "older"])
    precondition(DashboardController.sorted([older, newer], by: .updatedDate).map(\.id) == ["older", "newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: [], events: [event]).map(\.id) == ["older", "newer", "draft"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.all], events: [event]).map(\.id) == ["older", "newer", "draft"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.needsAttention], events: [event]).map(\.id) == ["newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.draft], events: [event]).map(\.id) == ["draft"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.ready], events: [event]).map(\.id) == ["older", "newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.changesRequested], events: [event]).map(\.id) == ["newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.reviewRequired], events: [event]).map(\.id) == ["draft"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.approved], events: [event]).map(\.id) == ["older"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.ciFailing], events: [event]).map(\.id) == ["newer"])
    precondition(DashboardController.filtered([older, newer, draft], by: [.changesRequested, .draft], events: [event]).map(\.id) == ["newer", "draft"])
    precondition(DashboardController.sortedWithPins([older, newer, draft], pinnedIds: ["older"], by: .createdDate).map(\.id) == ["older", "draft", "newer"])
    precondition(DashboardController.sortedWithPins([older, newer, draft], pinnedIds: ["draft", "older"], by: .updatedDate).map(\.id) == ["draft", "older", "newer"])
    precondition(DashboardController.sortedWithPins(
        DashboardController.filtered([older, newer, draft], by: [.ready], events: [event]),
        pinnedIds: ["draft"],
        by: .createdDate
    ).map(\.id) == ["newer", "older"])

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
    let assignedReview = PullRequest(
        id: "assigned",
        title: "Assigned review",
        number: 8,
        url: URL(string: "https://github.com/acme/mergehawk/pull/8")!,
        repo: "acme/mergehawk",
        ciState: .pending,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        isAssignedToViewer: true,
        isMine: false,
        author: "teammate",
        mergeable: .unknown,
        draft: false
    )
    let assignedDraftReview = PullRequest(
        id: "assigned-draft",
        title: "Assigned draft review",
        number: 9,
        url: URL(string: "https://github.com/acme/mergehawk/pull/9")!,
        repo: "acme/mergehawk",
        ciState: .pending,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        isAssignedToViewer: true,
        isMine: false,
        author: "teammate",
        mergeable: .unknown,
        draft: true
    )
    let directAssignedReview = PullRequest(
        id: "direct-assigned",
        title: "Direct assigned review",
        number: 10,
        url: URL(string: "https://github.com/acme/mergehawk/pull/10")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        reviewRequestKind: .direct,
        isAssignedToViewer: true,
        isMine: false,
        author: "teammate",
        mergeable: .mergeable,
        draft: false
    )
    let selfAssignedReview = PullRequest(
        id: "self-assigned",
        title: "Self assigned review",
        number: 11,
        url: URL(string: "https://github.com/acme/mergehawk/pull/11")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .reviewRequired,
        commentCount: 0,
        reviewCount: 0,
        reviewRequestKind: .directAndTeam,
        isAssignedToViewer: true,
        isMine: true,
        author: "rw",
        mergeable: .mergeable,
        draft: false
    )
    let reviewRequests = [
        older,
        directReview,
        teamReview,
        directAndTeamReview,
        draftDirectReview,
        assignedReview,
        assignedDraftReview,
        directAssignedReview,
        selfAssignedReview
    ]
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.direct]).map(\.id) == ["direct", "direct-team", "draft-direct", "direct-assigned"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.team]).map(\.id) == ["team", "direct-team"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.assigned]).map(\.id) == ["assigned", "assigned-draft", "direct-assigned"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: []).map(\.id) == ["direct", "team", "direct-team", "draft-direct", "assigned", "assigned-draft", "direct-assigned"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.all]).map(\.id) == ["direct", "team", "direct-team", "draft-direct", "assigned", "assigned-draft", "direct-assigned"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.draft]).map(\.id) == ["draft-direct", "assigned-draft"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.ready]).map(\.id) == ["direct", "team", "direct-team", "assigned", "direct-assigned"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.team, .draft]).map(\.id) == ["team", "direct-team", "draft-direct", "assigned-draft"])
    precondition(DashboardController.filteredReviewRequests(reviewRequests, by: [.assigned, .draft]).map(\.id) == ["draft-direct", "assigned", "assigned-draft", "direct-assigned"])
}()

@MainActor
private func signedInMockController() -> DashboardController {
    let controller = DashboardController(
        tokenStore: InMemoryTokenStore(),
        launchConfiguration: LaunchConfiguration(usesMockData: true, suppressesMacOSNotifications: true),
        automaticRefreshInterval: 0
    )
    waitUntil(timeout: 1.0) {
        controller.state.authStatus == .signedIn
    }
    return controller
}

@MainActor
private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    preconditionFailure("Timed out waiting for condition")
}

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
