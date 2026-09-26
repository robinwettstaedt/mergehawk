@testable import mergehawk
import AppKit
import CoreServices
import Foundation
import XCTest

final class BrowserAppleEventsTests: XCTestCase {
    private let base = URL(string: "https://github.com/acme/app/pull/12")!
    private let target = BrowserTarget(bundleIdentifier: "com.apple.Safari", processIdentifier: 123)

    func testSharedBrowserEligibilityCoversFourIdentifiersAndRejectsOthers() throws {
        XCTAssertEqual(BrowserDialect(bundleIdentifier: "com.apple.Safari"), .safari)
        for bundle in ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser"] {
            XCTAssertEqual(BrowserDialect(bundleIdentifier: bundle), .chromium)
        }
        XCTAssertNil(BrowserDialect(bundleIdentifier: "com.apple.SafariTechnologyPreview"))

        let unsupported = BrowserTarget(bundleIdentifier: "com.apple.SafariTechnologyPreview", processIdentifier: 999)
        let transport = ScriptedBrowserTransport([])
        let backend = BrowserAppleEvents(transport: transport, permissionChecker: { _ in .approved })
        XCTAssertThrowsError(try offMain { try backend.windows(for: unsupported) }) { error in
            XCTAssertEqual(error as? BrowserAppleEventError, .unsupportedBrowser(unsupported.bundleIdentifier))
        }
        XCTAssertTrue(transport.events.isEmpty)
    }

    func testSafariDecodesWindowOrderAndSkipsZeroTabUtilityWindow() throws {
        let transport = ScriptedBrowserTransport([
            reply(list([.init(int32: 3), .init(int32: 7)])),
            reply(list([.init(int32: 2), .init(int32: 1)])),
            reply(list([.init(boolean: false), .init(boolean: true)])),
            reply(.init(int32: 0)),
            reply(.init(int32: 2)),
            reply(list([
                .init(string: "https://github.com/other/app/pull/12"),
                .init(string: "https://github.com/acme/app/pull/12/files")
            ])),
            reply(.init(int32: 2))
        ])
        let backend = BrowserAppleEvents(transport: transport, permissionChecker: { _ in .approved })
        let windows = try offMain { try backend.windows(for: self.target) }

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].locator, .safari(7))
        XCTAssertEqual(windows[0].frontToBackIndex, 1)
        XCTAssertTrue(windows[0].minimized)
        XCTAssertEqual(windows[0].activeTabIndex, 2)
        XCTAssertEqual(windows[0].tabs.map(\.locator), [.safari(index: 1), .safari(index: 2)])
        XCTAssertEqual(windows[0].tabs[1].url?.absoluteString, "https://github.com/acme/app/pull/12/files")
        XCTAssertEqual(transport.events.count, 7)
        XCTAssertEqual(transport.events.filter { propertyCode($0) == BrowserAppleEventCodec.code("pURL") }.count, 1)
        XCTAssertEqual(transport.events.filter { $0.eventID == OSType(kAECountElements) }.count, 2)
    }

    func testBlankAndUnparseableTabsKeepIndicesAndActiveMatchPriority() throws {
        let prURL = "https://github.com/acme/app/pull/12/files"
        let transport = ScriptedBrowserTransport([
            reply(list([.init(int32: 7)])),
            reply(list([.init(int32: 1)])),
            reply(list([.init(boolean: false)])),
            reply(.init(int32: 4)),
            reply(list([
                .null(), .init(string: prURL), .init(string: "http://["),
                .init(string: "https://github.com/acme/app/pull/12#issuecomment-9")
            ])),
            reply(.init(int32: 4))
        ])
        let backend = BrowserAppleEvents(transport: transport, permissionChecker: { _ in .approved })
        let windows = try offMain { try backend.windows(for: self.target) }
        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.tabs.map(\.locator), [
            .safari(index: 1), .safari(index: 2), .safari(index: 3), .safari(index: 4)
        ])
        XCTAssertNil(window.tabs[0].url)
        XCTAssertNil(window.tabs[2].url)

        let request = PullRequestOpenRequest(pullRequestURL: base)
        XCTAssertEqual(PullRequestTabSelector.select(for: request, from: windows)?.tab.locator, .safari(index: 4))
        let invalidActive = BrowserWindowSnapshot(
            locator: window.locator, frontToBackIndex: window.frontToBackIndex,
            minimized: false, activeTabIndex: 3, tabs: window.tabs
        )
        XCTAssertEqual(PullRequestTabSelector.select(for: request, from: [invalidActive])?.tab.locator, .safari(index: 2))
    }

    func testChromiumPreservesTextIDsAndWritesOneCompleteURLBeforeRaising() throws {
        let chrome = BrowserTarget(bundleIdentifier: "com.google.Chrome", processIdentifier: 456)
        let destination = URL(string: "https://github.com/acme/app/pull/12?view=é&quote=%22x%22#discussion_r7")!
        let transport = ScriptedBrowserTransport([
            reply(list([.init(string: "window-α")])),
            reply(list([.init(int32: 4)])),
            reply(list([.init(boolean: true)])),
            reply(.init(int32: 2)),
            reply(list([
                .init(string: "https://github.com/other/app/pull/1"),
                .init(string: "https://github.com/acme/app/pull/12/commits")
            ])),
            reply(list([.init(string: "tab-one"), .init(string: "tab-β")])),
            reply(.init(int32: 2)),
            reply(list([.init(string: "tab-one"), .init(string: "tab-β")])),
            reply(.init(string: "https://github.com/acme/app/pull/12/commits")),
            reply(.null()), reply(.null()), reply(.null()), reply(.null())
        ])
        let backend = BrowserAppleEvents(transport: transport, permissionChecker: { _ in .approved })
        let windows = try offMain { try backend.windows(for: chrome) }
        XCTAssertEqual(windows[0].locator, .chromium("window-α"))
        XCTAssertEqual(windows[0].tabs[1].locator, .chromium(id: "tab-β"))
        let selection = try XCTUnwrap(PullRequestTabSelector.select(
            for: PullRequestOpenRequest(pullRequestURL: base), from: windows
        ))
        try offMain {
            try backend.apply(PullRequestOpenRequest(pullRequestURL: self.base, destinationURL: destination), to: selection, in: chrome)
        }

        let writes = transport.events.filter { $0.eventID == OSType(kAESetData) }
        XCTAssertEqual(writes.count, 4)
        XCTAssertEqual(writes.map(propertyCode), [
            BrowserAppleEventCodec.code("URL "), BrowserAppleEventCodec.code("pmnd"),
            BrowserAppleEventCodec.code("acTI"), BrowserAppleEventCodec.code("pidx")
        ])
        XCTAssertEqual(writes[0].paramDescriptor(forKeyword: AEKeyword(keyAEData))?.stringValue, destination.absoluteString)
        XCTAssertEqual(writes[1].paramDescriptor(forKeyword: AEKeyword(keyAEData))?.booleanValue, false)
        XCTAssertEqual(writes[2].paramDescriptor(forKeyword: AEKeyword(keyAEData))?.int32Value, 2)
        XCTAssertFalse(transport.events.contains { $0.eventID == BrowserAppleEventCodec.code("Rlod") })
        XCTAssertFalse(transport.events.contains { propertyCode($0) == BrowserAppleEventCodec.code("ldng") })
    }

    func testSafariPRClickAlsoWritesBaseURLOnceAndRevalidatesSelectedIndex() throws {
        let selection = BrowserTabSelection(
            window: BrowserWindowSnapshot(
                locator: .safari(7), frontToBackIndex: 1, minimized: false, activeTabIndex: 1,
                tabs: [BrowserTabSnapshot(locator: .safari(index: 1), url: URL(string: "https://github.com/acme/app/pull/12/files")!)]
            ),
            tab: BrowserTabSnapshot(locator: .safari(index: 1), url: URL(string: "https://github.com/acme/app/pull/12/files")!)
        )
        let transport = ScriptedBrowserTransport([
            reply(.init(string: "https://github.com/acme/app/pull/12/files")),
            reply(.null()), reply(.null()), reply(.null())
        ])
        let backend = BrowserAppleEvents(transport: transport, permissionChecker: { _ in .approved })
        try offMain { try backend.apply(PullRequestOpenRequest(pullRequestURL: self.base), to: selection, in: self.target) }
        let writes = transport.events.filter { $0.eventID == OSType(kAESetData) }
        XCTAssertEqual(writes.map(propertyCode), [
            BrowserAppleEventCodec.code("pURL"), BrowserAppleEventCodec.code("cTab"), BrowserAppleEventCodec.code("pidx")
        ])
        XCTAssertEqual(writes[0].paramDescriptor(forKeyword: AEKeyword(keyAEData))?.stringValue, base.absoluteString)
    }

    func testChangedTabAndNativeErrorsStopBeforeURLMutation() throws {
        let selection = BrowserTabSelection(
            window: BrowserWindowSnapshot(
                locator: .safari(7), frontToBackIndex: 1, minimized: false, activeTabIndex: 1,
                tabs: [BrowserTabSnapshot(locator: .safari(index: 1), url: base)]
            ),
            tab: BrowserTabSnapshot(locator: .safari(index: 1), url: base)
        )
        let changed = ScriptedBrowserTransport([reply(.init(string: "https://github.com/acme/app/pull/123"))])
        let backend = BrowserAppleEvents(transport: changed, permissionChecker: { _ in .approved })
        XCTAssertThrowsError(try offMain { try backend.apply(PullRequestOpenRequest(pullRequestURL: self.base), to: selection, in: self.target) }) { error in
            XCTAssertEqual(error as? BrowserAppleEventError, .selectedTabChanged)
        }
        XCTAssertFalse(changed.events.contains { $0.eventID == OSType(kAESetData) })

        let deniedReply = ScriptedBrowserTransport([reply(.null(), error: -1744)])
        let deniedBackend = BrowserAppleEvents(transport: deniedReply, permissionChecker: { _ in .approved })
        XCTAssertThrowsError(try offMain { try deniedBackend.windows(for: self.target) }) { error in
            XCTAssertEqual(error as? BrowserAppleEventError, .replyError(-1744, nil))
        }
        let native = NSError(domain: NSOSStatusErrorDomain, code: -1712)
        let failedTransport = ScriptedBrowserTransport([], thrownError: native)
        let failedBackend = BrowserAppleEvents(transport: failedTransport, permissionChecker: { _ in .approved })
        XCTAssertThrowsError(try offMain { try failedBackend.windows(for: self.target) }) { error in
            XCTAssertEqual((error as NSError).code, native.code)
        }
    }

    func testEdgeAndBraveUseChromiumDialectWithTheirOwnPIDTargets() throws {
        for bundle in ["com.microsoft.edgemac", "com.brave.Browser"] {
            let browser = BrowserTarget(bundleIdentifier: bundle, processIdentifier: 600)
            let transport = ScriptedBrowserTransport([
                reply(list([.init(string: "window-text")])),
                reply(list([.init(int32: 1)])),
                reply(list([.init(boolean: false)])),
                reply(.init(int32: 1)),
                reply(list([.init(string: base.absoluteString)])),
                reply(list([.init(string: "tab-text")])),
                reply(.init(int32: 1))
            ])
            let backend = BrowserAppleEvents(transport: transport, permissionChecker: { _ in .approved })
            let windows = try offMain { try backend.windows(for: browser) }
            XCTAssertEqual(windows[0].locator, .chromium("window-text"))
            XCTAssertEqual(windows[0].tabs[0].locator, .chromium(id: "tab-text"))
            let address = try XCTUnwrap(transport.events[0].attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)))
            XCTAssertEqual(address.data, NSAppleEventDescriptor(processIdentifier: browser.processIdentifier).data)
        }
    }

    private func offMain<T>(_ body: @escaping () throws -> T) throws -> T {
        let completed = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        DispatchQueue(label: "browser-apple-event-test").async {
            result = Result(catching: body)
            completed.signal()
        }
        completed.wait()
        return try result.get()
    }

    private func propertyCode(_ event: NSAppleEventDescriptor) -> OSType? {
        event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?
            .forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue
    }

    private func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let result = NSAppleEventDescriptor.list()
        for (offset, value) in values.enumerated() { result.insert(value, at: offset + 1) }
        return result
    }

    private func reply(_ value: NSAppleEventDescriptor, error: Int32? = nil) -> NSAppleEventDescriptor {
        let result = NSAppleEventDescriptor(
            eventClass: BrowserAppleEventCodec.code("aevt"), eventID: BrowserAppleEventCodec.code("ansr"),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        result.setParam(value, forKeyword: AEKeyword(keyDirectObject))
        if let error { result.setParam(.init(int32: error), forKeyword: AEKeyword(keyErrorNumber)) }
        return result
    }
}

private final class ScriptedBrowserTransport: BrowserAppleEventTransport {
    private var replies: [NSAppleEventDescriptor]
    private let thrownError: Error?
    private(set) var events: [NSAppleEventDescriptor] = []

    init(_ replies: [NSAppleEventDescriptor], thrownError: Error? = nil) {
        self.replies = replies
        self.thrownError = thrownError
    }

    func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        events.append(event)
        if let thrownError { throw thrownError }
        return replies.removeFirst()
    }
}
