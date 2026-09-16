@testable import mergehawk
import AppKit
import Foundation
import mergehawkcore
import XCTest

final class MenuViewTests: XCTestCase {
    func testPanelSizeUsesPreferredWidthAndFitsUsableScreen() {
        let large = MenuPanelSize.resolve(availableFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        XCTAssertEqual(large.width, 820)
        XCTAssertEqual(large.height, MenuRootView.Layout.height)

        let laptopUsableFrame = CGRect(x: 0, y: 28, width: 1280, height: 740)
        let laptop = MenuPanelSize.resolve(availableFrame: laptopUsableFrame)
        XCTAssertEqual(laptop.width, 820)
        XCTAssertLessThan(laptop.height, MenuRootView.Layout.height)
        XCTAssertLessThanOrEqual(laptop.height + MenuPanelSize.margin * 2, laptopUsableFrame.height)
        XCTAssertGreaterThan(laptop.height, MenuRootView.Layout.footerHeight + MenuRootView.Layout.topBarHeight)

        let narrow = MenuPanelSize.resolve(availableFrame: CGRect(x: 0, y: 0, width: 760, height: 600))
        XCTAssertLessThanOrEqual(narrow.width + MenuPanelSize.margin * 2, 760)
        XCTAssertLessThanOrEqual(narrow.height + MenuPanelSize.margin * 2, 600)
    }

    @MainActor
    func testNativeHostAndRootUseTheSameResolvedSize() throws {
        let controller = DashboardController(tokenStore: InMemoryTokenStore(), automaticRefreshInterval: 0)
        let statusBarController = StatusBarController(controller: controller)
        let frame = CGRect(x: 0, y: 28, width: 1280, height: 740)
        let hosted = try XCTUnwrap(statusBarController.makeMenuContentView(availableFrame: frame) as? MenuRootHostingView)
        let resolved = MenuPanelSize.resolve(availableFrame: frame)
        XCTAssertEqual(hosted.frame.size, resolved)
        XCTAssertEqual(hosted.rootView.resolvedSize, resolved)
    }

    func testIndependentStatusDescriptionsAndMixedSignals() {
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .approved).label, "Review approved")
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .noReviewYet).label, "No review yet")
        XCTAssertEqual(ReviewDecisionIndicator.Kind(reviewDecision: .unknown).label, "Review status unknown")
        XCTAssertEqual(CIStatusIndicator.Kind(ciState: .failing).label, "CI failing")
        XCTAssertEqual(CIStatusIndicator.Kind(ciState: .pending).label, "CI pending (waiting or running)")
        XCTAssertEqual(CIStatusIndicator.Kind(ciState: .passing).label, "CI successful")
        XCTAssertEqual(CIStatusIndicator.Kind(ciState: .unknown).label, "CI status unknown")
        XCTAssertEqual(MergeConflictIndicator.Kind(mergeable: .conflicting).label, "Merge conflicts")
        XCTAssertEqual(MergeConflictIndicator.Kind(mergeable: .unknown).label, "Mergeability unknown")
        XCTAssertTrue(MergeConflictIndicator.Kind(mergeable: .mergeable).label.contains("No merge conflicts"))
        XCTAssertTrue(MergeConflictIndicator.Kind(mergeable: .mergeable).label.contains("other requirements"))

        let blocked = (
            ReviewDecisionIndicator.Kind(reviewDecision: .approved).label,
            CIStatusIndicator.Kind(ciState: .failing).label,
            MergeConflictIndicator.Kind(mergeable: .conflicting).label
        )
        XCTAssertEqual(blocked.0, "Review approved")
        XCTAssertEqual(blocked.1, "CI failing")
        XCTAssertEqual(blocked.2, "Merge conflicts")
        let clear = (
            ReviewDecisionIndicator.Kind(reviewDecision: .noReviewYet).label,
            CIStatusIndicator.Kind(ciState: .passing).label,
            MergeConflictIndicator.Kind(mergeable: .mergeable).label
        )
        XCTAssertEqual(clear.0, "No review yet")
        XCTAssertEqual(clear.1, "CI successful")
        XCTAssertTrue(clear.2.contains("No merge conflicts"))
    }

    func testChangeCountPresentationKeepsExactAccessibleValues() {
        XCTAssertEqual(PullRequestChangesPresentation.text(additions: 0, deletions: 0), "+0 −0")
        XCTAssertEqual(PullRequestChangesPresentation.label(additions: 0, deletions: 0), "0 additions, 0 deletions")
        XCTAssertEqual(PullRequestChangesPresentation.text(additions: nil, deletions: 0), "—")
        XCTAssertEqual(PullRequestChangesPresentation.label(additions: nil, deletions: 0), "Change counts unavailable")
        XCTAssertEqual(PullRequestChangesPresentation.text(additions: 12_345, deletions: 6_789), "+12k −6.8k")
        XCTAssertEqual(PullRequestChangesPresentation.label(additions: 12_345, deletions: 6_789), "12,345 additions, 6,789 deletions")
    }

    @MainActor
    func testNoReviewFilterKeepsSavedTagAndExcludesUnknown() {
        XCTAssertEqual(ReviewDecision.noReviewYet.rawValue, "review_required")
        XCTAssertEqual(DashboardController.PullRequestFilterOption.noReviewYet.rawValue, "reviewRequired")
        XCTAssertEqual(DashboardController.PullRequestFilterOption.noReviewYet.label, "No review yet")
        let unknown = PullRequest(
            id: "unknown", title: "Unknown feedback", number: 1,
            url: URL(string: "https://github.com/acme/app/pull/1")!, repo: "acme/app",
            ciState: .unknown, reviewDecision: .unknown, commentCount: 0,
            reviewCount: 0, isMine: true, author: "rw", mergeable: .unknown,
            draft: false
        )
        XCTAssertTrue(DashboardController.filtered([unknown], by: [.noReviewYet], events: []).isEmpty)
        XCTAssertTrue(DashboardController.filtered([unknown], by: [.approved], events: []).isEmpty)
        XCTAssertEqual(DashboardController.filtered([unknown], by: [.ready], events: []).map(\.id), ["unknown"])
    }

    func testPullRequestListEmptyCopy() {
        XCTAssertEqual(PullRequestListCopy.emptyReviewRequests, "No review requests or assigned PRs.")
    }

    // MER-58 regression: during NSMenu tracking, key equivalents are matched against the open
    // menu's native items first and then the app's main menu — the hosted view hierarchy is never
    // consulted. Hidden native trap items are required so ⌘, and ⌘Q do not fall through to the
    // SwiftUI Settings scene's auto-generated main-menu items.
    @MainActor
    func testStatusMenuAddsHiddenKeyEquivalentTrapItems() {
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0
        )
        let statusBarController = StatusBarController(controller: controller)
        let items = statusBarController.rebuildMenuForTesting()
        XCTAssertEqual(items.count, 3)
        XCTAssertNotNil(items[0].view)

        let settingsTrapItem = items[1]
        XCTAssertEqual(settingsTrapItem.title, "Settings")
        XCTAssertEqual(settingsTrapItem.keyEquivalent, ",")
        XCTAssertTrue(settingsTrapItem.isHidden)
        XCTAssertTrue(settingsTrapItem.allowsKeyEquivalentWhenHidden)

        let quitTrapItem = items[2]
        XCTAssertEqual(quitTrapItem.title, "Quit")
        XCTAssertEqual(quitTrapItem.keyEquivalent, "q")
        XCTAssertTrue(quitTrapItem.isHidden)
        XCTAssertTrue(quitTrapItem.allowsKeyEquivalentWhenHidden)

        var settingsSelections: [SettingsTab] = []
        controller.openSettingsWindow = { selection in
            settingsSelections.append(selection)
        }
        var quitInvocationCount = 0
        statusBarController.setQuitActionForTesting {
            quitInvocationCount += 1
        }

        _ = settingsTrapItem.target?.perform(settingsTrapItem.action, with: settingsTrapItem)
        XCTAssertEqual(settingsSelections, [.general])
        _ = quitTrapItem.target?.perform(quitTrapItem.action, with: quitTrapItem)
        XCTAssertEqual(quitInvocationCount, 1)
    }

    @MainActor
    func testHostedMenuViewConsumesKeyEquivalents() throws {
        let controller = DashboardController(
            tokenStore: InMemoryTokenStore(),
            automaticRefreshInterval: 0
        )
        let statusBarController = StatusBarController(controller: controller)
        let items = statusBarController.rebuildMenuForTesting()
        let hostedView = try XCTUnwrap(items[0].view)

        XCTAssertEqual(statusBarController.refreshFlashCountForTesting(), 0)
        XCTAssertTrue(hostedView.performKeyEquivalent(with: keyEvent(characters: "r", modifiers: .command)))
        XCTAssertEqual(statusBarController.refreshFlashCountForTesting(), 1)
        XCTAssertFalse(hostedView.performKeyEquivalent(with: keyEvent(characters: "r", modifiers: [])))
        XCTAssertEqual(statusBarController.refreshFlashCountForTesting(), 1)

        var settingsSelections: [SettingsTab] = []
        controller.openSettingsWindow = { selection in
            settingsSelections.append(selection)
        }
        var quitInvocationCount = 0
        statusBarController.setQuitActionForTesting {
            quitInvocationCount += 1
        }
        XCTAssertFalse(hostedView.performKeyEquivalent(with: keyEvent(characters: ",", modifiers: [])))
        XCTAssertFalse(hostedView.performKeyEquivalent(with: keyEvent(characters: "q", modifiers: [])))
        XCTAssertEqual(settingsSelections, [])
        XCTAssertEqual(quitInvocationCount, 0)
        XCTAssertTrue(hostedView.performKeyEquivalent(with: keyEvent(characters: ",", modifiers: .command)))
        XCTAssertEqual(settingsSelections, [.general])
        XCTAssertTrue(hostedView.performKeyEquivalent(with: keyEvent(characters: "q", modifiers: .command)))
        XCTAssertEqual(quitInvocationCount, 1)
    }

    @MainActor
    func testMenuFooterClickFeedbackSuppressesSelectionAndIgnoresRepeatedClicks() async {
        let feedback = MenuFooterClickFeedback()
        var actionCount = 0
        var selectionWasSuppressedWhenActionRan: Bool?

        feedback.perform {
            actionCount += 1
            selectionWasSuppressedWhenActionRan = feedback.suppressesSelection
        }
        feedback.perform {
            actionCount += 1
        }

        XCTAssertTrue(feedback.suppressesSelection)
        XCTAssertTrue(feedback.isActive)
        XCTAssertEqual(actionCount, 0)

        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(feedback.suppressesSelection)
        XCTAssertFalse(feedback.isActive)
        XCTAssertEqual(actionCount, 1)
        XCTAssertEqual(selectionWasSuppressedWhenActionRan, false)
    }
}

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
    precondition(CIStatusIndicator.Kind(ciState: .pending) == .pending)
    precondition(CIStatusIndicator.Kind(ciState: .passing) == .successful)

    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .approved) == .approved)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .changesRequested) == .changesRequested)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .noReviewYet) == .noReviewYet)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .unknown) == .unknown)

    let prURL = URL(string: "https://github.com/acme/mergehawk/pull/12")!
    precondition(PullRequestLinkCopyButton.clipboardString(for: prURL) == "https://github.com/acme/mergehawk/pull/12")
    precondition(CommentCountIndicator.label(for: 3) == "3 unresolved comments")
    precondition(CommentCountIndicator.label(for: 1) == "1 unresolved comment")
    precondition(GitHubSignInView.Copy.title == "Connect GitHub")
    precondition(GitHubSignInView.Copy.buttonTitle == "Sign in with GitHub")
    precondition(GitHubSignInView.Copy.permissionText.contains("GitHub App"))
    precondition(GitHubSignInView.Copy.enterCodeTitle == "Enter code on GitHub")
    precondition(GitHubSignInView.Copy.copyCode == "Copy Code")
    precondition(GitHubSignInView.Copy.codeCopied == "Code copied to clipboard")
    precondition(GitHubSignInView.Copy.openGitHub == "Open GitHub")
    precondition(GitHubSignInView.Copy.loadingTitle == "Authorized")
    precondition(GitHubSignInView.Copy.loadingDetail == "Loading MergeHawk...")
    precondition(GitHubSignInView.Copy.patButtonTitle == "Open Settings")
    precondition(GitHubInboxUnavailableCopy.title == "GitHub Inbox unavailable")
    precondition(GitHubInboxUnavailableCopy.message.contains("classic personal access token"))
    precondition(GitHubAppRepositoryAccessCopy.buttonTitle == "Install or Manage Repository Access")
    precondition(GitHubAppRepositoryAccessCopy.title(for: .noInstallations) == "Repository access not configured")
    precondition(GitHubAppRepositoryAccessCopy.message(for: .noVisibleRepositories).contains("no accessible repositories"))
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
    precondition(PullRequestListCopy.emptyReviewRequests == "No review requests or assigned PRs.")
    precondition(PullRequestListCopy.noFilterMatches == "No PRs match these filters.")
    precondition(HiddenPullRequestsDisclosurePresentation.title(count: 3) == "Hidden (3)")
    precondition(HiddenPullRequestsDisclosurePresentation.accessibilityLabel(
        count: 3,
        isExpanded: false
    ) == "Hidden (3), collapsed")
    precondition(HiddenPullRequestsDisclosurePresentation.accessibilityLabel(
        count: 3,
        isExpanded: true
    ) == "Hidden (3), expanded")
    let otherCommitNotificationPullRequest = PullRequest(
        id: "other-commit",
        title: "Other commit notification",
        number: 13,
        url: URL(string: "https://github.com/acme/mergehawk/pull/13")!,
        repo: "acme/mergehawk",
        ciState: .passing,
        reviewDecision: .noReviewYet,
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
        reviewDecision: .noReviewYet,
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
    precondition(PullRequestHidePresentation.symbolName == "eye.slash")
    precondition(PullRequestHidePresentation.label(isHidden: false) == "Hide PR")
    precondition(PullRequestHidePresentation.label(isHidden: true) == "Unhide PR")

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
    precondition(statusMenuItems.count == 3)
    precondition(statusMenuItems[0].view != nil)
    // Hidden native key-equivalent trap items: during NSMenu tracking only native items of the
    // open menu outrank the app's main menu, so these keep ⌘, and ⌘Q from reaching the SwiftUI
    // Settings scene's auto-generated main-menu items (MER-58 regression).
    precondition(statusMenuItems[1].title == "Settings")
    precondition(statusMenuItems[1].keyEquivalent == ",")
    precondition(statusMenuItems[1].isHidden)
    precondition(statusMenuItems[1].allowsKeyEquivalentWhenHidden)
    precondition(statusMenuItems[2].title == "Quit")
    precondition(statusMenuItems[2].keyEquivalent == "q")
    precondition(statusMenuItems[2].isHidden)
    precondition(statusMenuItems[2].allowsKeyEquivalentWhenHidden)

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
    precondition(isSettingsKeyEvent(keyEvent(characters: ",", modifiers: .command)))
    precondition(!isSettingsKeyEvent(keyEvent(characters: ",", modifiers: [])))
    precondition(isQuitKeyEvent(keyEvent(characters: "q", modifiers: .command)))
    precondition(isQuitKeyEvent(keyEvent(characters: "Q", modifiers: .command)))
    precondition(!isQuitKeyEvent(keyEvent(characters: "q", modifiers: [])))

    precondition(statusBarController.refreshFlashCountForTesting() == 0)
    precondition(statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: .command)))
    precondition(statusBarController.refreshFlashCountForTesting() == 1)
    precondition(!statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: [])))
    precondition(statusBarController.refreshFlashCountForTesting() == 1)

    var quitInvocationCount = 0
    statusBarController.setQuitActionForTesting {
        quitInvocationCount += 1
    }
    precondition(!statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: ",", modifiers: [])))
    precondition(!statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "q", modifiers: [])))
    precondition(quitInvocationCount == 0)
    precondition(statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: ",", modifiers: .command)))
    precondition(statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "q", modifiers: .command)))
    precondition(quitInvocationCount == 1)

    let manualRefreshClient = MenuFakeGitHubProvider(
        sourceCatalogResult: .success(SourceCatalog(repositories: [
            RepositorySource(owner: "rw", name: "story-tales")
        ], accountLogin: "rw")),
        installationsResult: .success(GitHubAppInstallations(installations: [
            GitHubAppInstallation(
                id: 1002,
                accountLogin: "rw",
                accountType: "User",
                repositorySelection: .all
            )
        ]))
    )
    let manualRefreshController = DashboardController(
        tokenStore: InMemoryTokenStore(),
        automaticRefreshInterval: 0,
        oauthSignIn: MenuOAuthSignIn(),
        oauthGitHubClientFactory: { _ in manualRefreshClient },
        deviceFlowURLOpener: { _ in }
    )
    Task {
        await manualRefreshController.signInWithGitHub()
    }
    waitUntil(timeout: 1.0) {
        manualRefreshClient.fetchInstallationsCount == 1
    }
    manualRefreshClient.installationsResult = .success(GitHubAppInstallations(installations: []))
    let manualRefreshStatusBarController = StatusBarController(controller: manualRefreshController)
    _ = manualRefreshStatusBarController.showMenuForTesting(selecting: .myPRs)
    precondition(manualRefreshStatusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "r", modifiers: .command)))
    waitUntil(timeout: 1.0) {
        manualRefreshClient.fetchInstallationsCount == 2
            && manualRefreshController.gitHubAppRepositoryAccessStatus == .noInstallations
    }

    controller.selectedTab = .reviewRequests
    precondition(!statusBarController.performMenuKeyEquivalentForTesting(keyEvent(characters: "1", modifiers: .command)))
    precondition(controller.selectedTab == .reviewRequests)

    let signedInController = signedInMockController()
    let signedInStatusBarController = StatusBarController(controller: signedInController)
    _ = signedInStatusBarController.rebuildMenuForTesting()
    signedInController.selectedTab = .reviewRequests
    let revealedMenuItems = signedInStatusBarController.showMenuForTesting(selecting: .notifications)
    precondition(signedInController.selectedTab == .notifications)
    precondition(revealedMenuItems.count == 3)
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
        reviewDecision: .noReviewYet,
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
    precondition(DashboardController.filtered([older, newer, draft], by: [.noReviewYet], events: [event]).map(\.id) == ["draft"])
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
        reviewDecision: .noReviewYet,
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
        reviewDecision: .noReviewYet,
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
        reviewDecision: .noReviewYet,
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
        reviewDecision: .noReviewYet,
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
        reviewDecision: .noReviewYet,
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
        reviewDecision: .noReviewYet,
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
        reviewDecision: .noReviewYet,
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
private func waitUntil(
    timeout: TimeInterval,
    file: StaticString = #file,
    line: UInt = #line,
    condition: () -> Bool
) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    preconditionFailure("Timed out waiting for condition", file: file, line: line)
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

@MainActor
private struct MenuOAuthSignIn: GitHubOAuthSigningIn {
    func requestDeviceCode() async throws -> DeviceFlowChallenge {
        DeviceFlowChallenge(
            userCode: "ABCD-1234",
            deviceCode: "fake-device-code",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: .distantFuture,
            interval: 5
        )
    }

    func pollForTokens(challenge: DeviceFlowChallenge) async throws -> OAuthTokens {
        OAuthTokens(accessToken: "oauth-access", refreshToken: "oauth-refresh", expiresAt: .distantFuture)
    }
}

private final class MenuFakeGitHubProvider: GitHubProviding {
    let sourceKind: DashboardSource = .github
    var sourceCatalogResult: Result<SourceCatalog, Error>
    var installationsResult: Result<GitHubAppInstallations, Error>
    private(set) var fetchInstallationsCount = 0

    init(
        sourceCatalogResult: Result<SourceCatalog, Error>,
        installationsResult: Result<GitHubAppInstallations, Error>
    ) {
        self.sourceCatalogResult = sourceCatalogResult
        self.installationsResult = installationsResult
    }

    func fetchViewer() async throws -> GitHubAccount {
        GitHubAccount(login: "rw")
    }

    func fetchPullRequests(
        login: String,
        previousPullRequests: [PullRequest]
    ) async throws -> PullRequestFetchResult {
        PullRequestFetchResult(pullRequests: [])
    }

    func fetchSourceCatalog(accountLogin: String?) async throws -> SourceCatalog {
        try sourceCatalogResult.get()
    }

    func fetchGitHubAppInstallations() async throws -> GitHubAppInstallations {
        fetchInstallationsCount += 1
        return try installationsResult.get()
    }

    func fetchInboxNotifications(metadata: GitHubInboxSyncMetadata) async throws -> GitHubInboxFetchResult {
        GitHubInboxFetchResult(notifications: [], metadata: metadata)
    }

    func markInboxThreadRead(threadId: String) async throws {}
}
