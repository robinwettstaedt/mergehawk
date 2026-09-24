import Foundation

struct PullRequestOpenRequest: Equatable, Sendable {
    let pullRequestURL: URL
    let destinationURL: URL?

    init(pullRequestURL: URL, destinationURL: URL? = nil) {
        self.pullRequestURL = pullRequestURL
        self.destinationURL = destinationURL
    }

    var targetURL: URL { destinationURL ?? pullRequestURL }
}

struct PullRequestIdentity: Equatable, Sendable {
    let host: String
    let owner: String
    let repository: String
    let number: Int

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 4,
              !segments[0].isEmpty, !segments[1].isEmpty,
              segments[2].lowercased() == "pull",
              let number = Int(segments[3]), number > 0 else { return nil }
        self.host = host
        self.owner = segments[0].lowercased()
        self.repository = segments[1].lowercased()
        self.number = number
    }
}

enum BrowserWindowLocator: Equatable, Sendable {
    case safari(Int32)
    case chromium(Int32)
}

enum BrowserTabLocator: Equatable, Sendable {
    case safari(index: Int)
    case chromium(id: String)
}

struct BrowserTabSnapshot: Equatable, Sendable {
    let locator: BrowserTabLocator
    let url: URL
}

struct BrowserWindowSnapshot: Equatable, Sendable {
    let locator: BrowserWindowLocator
    let frontToBackIndex: Int
    let minimized: Bool
    let activeTabIndex: Int?
    let tabs: [BrowserTabSnapshot]
}

struct BrowserTabSelection: Equatable, Sendable {
    let window: BrowserWindowSnapshot
    let tab: BrowserTabSnapshot
}

enum PullRequestTabSelector {
    static func select(
        for request: PullRequestOpenRequest,
        from windows: [BrowserWindowSnapshot]
    ) -> BrowserTabSelection? {
        guard let identity = PullRequestIdentity(request.pullRequestURL) else { return nil }
        let ordered = windows.sorted { $0.frontToBackIndex < $1.frontToBackIndex }
        for (windowOffset, window) in ordered.enumerated() {
            if windowOffset == 0, let active = window.activeTabIndex,
               window.tabs.indices.contains(active - 1) {
                let tab = window.tabs[active - 1]
                if PullRequestIdentity(tab.url) == identity {
                    return BrowserTabSelection(window: window, tab: tab)
                }
            }
            if let tab = window.tabs.first(where: { PullRequestIdentity($0.url) == identity }) {
                return BrowserTabSelection(window: window, tab: tab)
            }
        }
        return nil
    }
}
