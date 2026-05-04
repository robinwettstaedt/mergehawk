@testable import VCDash
import AppKit
import VCDashCore

private final class MenuActionTarget: NSObject {
    @objc func performAction() {}
}

@MainActor let vcDashMenuViewTest: Void = {
    precondition(CIStatusIndicator.Kind(ciState: .failing) == .failing)
    precondition(CIStatusIndicator.Kind(ciState: .pending) == .running)
    precondition(CIStatusIndicator.Kind(ciState: .passing) == .successful)

    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .approved) == .approved)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .changesRequested) == .changesRequested)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .reviewRequired) == .reviewRequired)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .unknown) == .unknown)

    let target = MenuActionTarget()
    let refreshItem = StatusBarController.makeRefreshItem(target: target, action: #selector(MenuActionTarget.performAction))
    precondition(refreshItem.title == "Refresh")
    precondition(refreshItem.action == #selector(MenuActionTarget.performAction))
    precondition(refreshItem.target === target)
    precondition(refreshItem.keyEquivalent == "r")
    precondition(refreshItem.view == nil)
}()
