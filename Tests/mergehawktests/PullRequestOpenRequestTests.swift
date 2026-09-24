@testable import mergehawk
import Foundation
import XCTest

final class PullRequestOpenRequestTests: XCTestCase {
    func testPRIdentityMatchesPageAndNotificationVariants() {
        let base = URL(string: "https://GitHub.com/Acme/App/pull/12")!
        let identity = PullRequestIdentity(base)
        for path in [
            "https://github.com/acme/app/pull/12",
            "https://github.com/ACME/APP/pull/12/files?diff=split",
            "https://GITHUB.com/acme/app/pull/12/commits",
            "https://github.com/acme/app/pull/12?view=discussion#issuecomment-7",
            "https://github.com/acme/app/pull/12/files#discussion_r8",
            "https://github.com/acme/app/pull/12#pullrequestreview-9"
        ] {
            XCTAssertEqual(PullRequestIdentity(URL(string: path)!), identity, path)
        }
        for path in [
            "https://gitlab.com/acme/app/pull/12",
            "https://github.com/acme/other/pull/12",
            "https://github.com/other/app/pull/12",
            "https://github.com/acme/app/pull/123",
            "https://github.com/acme/app/pull/0",
            "https://github.com/acme/app/issues/12",
            "https://github.com/acme/app/pull/12abc",
            "file:///acme/app/pull/12"
        ] {
            XCTAssertNotEqual(PullRequestIdentity(URL(string: path)!), identity, path)
        }
        XCTAssertNil(PullRequestIdentity(URL(string: "not a valid URL")!))
    }

    func testSelectionPrefersFrontActiveThenOrderedMatches() throws {
        let request = PullRequestOpenRequest(pullRequestURL: URL(string: "https://github.com/acme/app/pull/12")!)
        let front = window(1, order: 1, active: 3, urls: [
            "https://github.com/acme/app/pull/12/files",
            "https://github.com/other/app/pull/12",
            "https://github.com/acme/app/pull/12/commits"
        ])
        let back = window(2, order: 2, active: 1, urls: ["https://github.com/acme/app/pull/12"])
        XCTAssertEqual(PullRequestTabSelector.select(for: request, from: [back, front])?.tab.locator, .safari(index: 3))

        let nonmatchingActive = window(1, order: 1, active: 2, urls: front.tabs.map { $0.url.absoluteString })
        XCTAssertEqual(PullRequestTabSelector.select(for: request, from: [back, nonmatchingActive])?.tab.locator, .safari(index: 1))

        let frontWithoutMatch = window(1, order: 1, active: 2, urls: ["https://github.com/acme/app/issues/12"])
        XCTAssertEqual(PullRequestTabSelector.select(for: request, from: [back, frontWithoutMatch])?.window.locator, .safari(2))
        XCTAssertNil(PullRequestTabSelector.select(for: request, from: [frontWithoutMatch]))
    }

    func testRequestUsesTheBaseOrExactDestinationURL() {
        let base = URL(string: "https://github.com/acme/app/pull/12")!
        let ordinary = PullRequestOpenRequest(pullRequestURL: base)
        XCTAssertEqual(ordinary.targetURL, base)
        let precise = PullRequestOpenRequest(pullRequestURL: base, destinationURL: base)
        XCTAssertEqual(precise.targetURL, base)
    }

    private func window(_ id: Int32, order: Int, active: Int?, urls: [String]) -> BrowserWindowSnapshot {
        BrowserWindowSnapshot(
            locator: .safari(id), frontToBackIndex: order, minimized: false,
            activeTabIndex: active,
            tabs: urls.enumerated().map { offset, value in
                BrowserTabSnapshot(locator: .safari(index: offset + 1), url: URL(string: value)!)
            }
        )
    }
}
