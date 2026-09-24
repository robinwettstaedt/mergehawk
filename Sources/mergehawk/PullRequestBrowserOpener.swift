import Foundation
import AppKit
import CoreServices

struct BrowserTarget: Equatable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
}

enum BrowserAutomationPermission: Equatable {
    case approved
    case denied
}

protocol PullRequestBrowserBackend: AnyObject, Sendable {
    func permission(for target: BrowserTarget) throws -> BrowserAutomationPermission
    func windows(for target: BrowserTarget) throws -> [BrowserWindowSnapshot]
    func apply(_ request: PullRequestOpenRequest, to selection: BrowserTabSelection, in target: BrowserTarget) throws
}

@MainActor
final class PullRequestBrowserOpener {
    typealias ResolveBrowser = @MainActor (URL) -> BrowserTarget?
    typealias YieldActivation = @MainActor (BrowserTarget) -> Void
    typealias RequestActivation = @MainActor (BrowserTarget) -> Bool
    typealias OpenNormally = @MainActor (URL) -> Void

    private let resolveBrowser: ResolveBrowser
    private let yieldActivation: YieldActivation
    private let requestActivation: RequestActivation
    private let openNormally: OpenNormally
    private let backend: PullRequestBrowserBackend
    private let worker = DispatchQueue(label: "com.mergehawk.pr-browser-opener")

    init(
        resolveBrowser: @escaping ResolveBrowser,
        backend: PullRequestBrowserBackend,
        yieldActivation: @escaping YieldActivation,
        requestActivation: @escaping RequestActivation,
        openNormally: @escaping OpenNormally
    ) {
        self.resolveBrowser = resolveBrowser
        self.backend = backend
        self.yieldActivation = yieldActivation
        self.requestActivation = requestActivation
        self.openNormally = openNormally
    }

    func open(_ request: PullRequestOpenRequest) {
        let target = resolveBrowser(request.pullRequestURL)
        if let target { yieldActivation(target) }
        let backend = backend
        worker.async { [weak self] in
            guard let target else {
                DispatchQueue.main.async { [weak self] in self?.openNormally(request.targetURL) }
                return
            }
            let succeeded: Bool
            do {
                guard try backend.permission(for: target) == .approved else {
                    throw BrowserOpeningError.permissionDenied
                }
                let windows = try backend.windows(for: target)
                guard let selection = PullRequestTabSelector.select(for: request, from: windows) else {
                    throw BrowserOpeningError.noMatchingTab
                }
                try backend.apply(request, to: selection, in: target)
                succeeded = true
            } catch {
                succeeded = false
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !succeeded || !self.requestActivation(target) {
                    self.openNormally(request.targetURL)
                }
            }
        }
    }
}

private enum BrowserOpeningError: Error {
    case permissionDenied
    case noMatchingTab
}
