@testable import VCDash
import Foundation
import VCDashCore

@MainActor let vcDashMenuViewTest: Void = {
    precondition(CIStatusIndicator.Kind(ciState: .failing) == .failing)
    precondition(CIStatusIndicator.Kind(ciState: .pending) == .running)
    precondition(CIStatusIndicator.Kind(ciState: .passing) == .successful)

    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .approved) == .approved)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .changesRequested) == .changesRequested)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .reviewRequired) == .reviewRequired)
    precondition(ReviewDecisionIndicator.Kind(reviewDecision: .unknown) == .unknown)

    let prURL = URL(string: "https://github.com/acme/vc-dash/pull/12")!
    precondition(PullRequestLinkCopyButton.clipboardString(for: prURL) == "https://github.com/acme/vc-dash/pull/12")
    precondition(CommentCountIndicator.label(for: 3) == "3 comments")
    precondition(CommentCountIndicator.label(for: 1) == "1 comment")
}()
