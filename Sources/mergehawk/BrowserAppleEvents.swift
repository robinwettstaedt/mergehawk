import Foundation
import AppKit
import CoreServices

enum BrowserAppleEventError: Error, Equatable {
    case malformedReply(String)
    case replyError(Int32, String?)
    case permissionError(OSStatus)
    case selectedTabChanged
    case unsupportedBrowser(String)
}

enum BrowserDialect: Equatable {
    case safari
    case chromium

    init?(bundleIdentifier: String) {
        switch bundleIdentifier {
        case "com.apple.Safari": self = .safari
        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser": self = .chromium
        default: return nil
        }
    }

    var tabClass: OSType {
        switch self {
        case .safari: BrowserAppleEventCodec.code("bTab")
        case .chromium: BrowserAppleEventCodec.code("CrTb")
        }
    }

    var urlProperty: OSType {
        switch self {
        case .safari: BrowserAppleEventCodec.code("pURL")
        case .chromium: BrowserAppleEventCodec.code("URL ")
        }
    }
}

protocol BrowserAppleEventTransport {
    func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor
}

struct NativeBrowserAppleEventTransport: BrowserAppleEventTransport {
    func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let options: NSAppleEventDescriptor.SendOptions = [
            .waitForReply,
            NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDoNotPromptForUserConsent))
        ]
        return try event.sendEvent(options: options, timeout: TimeInterval(kAEDefaultTimeout))
    }
}

enum BrowserAppleEventCodec {
    static func code(_ text: String) -> OSType {
        text.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    static func object(
        _ kind: OSType,
        in container: NSAppleEventDescriptor,
        form: OSType,
        key: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: kind), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))!
    }

    static func all(_ kind: OSType, in container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        var ordinal = OSType(kAEAll)
        let data = withUnsafeBytes(of: &ordinal) { Data($0) }
        let key = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal), data: data)!
        return object(kind, in: container, form: OSType(formAbsolutePosition), key: key)
    }

    static func property(_ kind: OSType, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        object(OSType(typeProperty), in: container, form: OSType(formPropertyID), key: NSAppleEventDescriptor(typeCode: kind))
    }

    static func window(_ locator: BrowserWindowLocator) -> NSAppleEventDescriptor {
        let key: NSAppleEventDescriptor = switch locator {
        case .safari(let id): NSAppleEventDescriptor(int32: id)
        case .chromium(let id): NSAppleEventDescriptor(string: id)
        }
        return object(code("cwin"), in: .null(), form: OSType(formUniqueID), key: key)
    }

    static func tab(_ locator: BrowserTabLocator, in window: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        switch locator {
        case .safari(let index):
            return object(code("bTab"), in: window, form: OSType(formAbsolutePosition), key: NSAppleEventDescriptor(int32: Int32(index)))
        case .chromium(let id):
            return object(code("CrTb"), in: window, form: OSType(formUniqueID), key: NSAppleEventDescriptor(string: id))
        }
    }

    static func event(
        _ eventClass: OSType,
        _ eventID: OSType,
        target: BrowserTarget,
        direct: NSAppleEventDescriptor,
        value: NSAppleEventDescriptor? = nil
    ) -> NSAppleEventDescriptor {
        let address = NSAppleEventDescriptor(processIdentifier: target.processIdentifier)
        let event = NSAppleEventDescriptor(
            eventClass: eventClass, eventID: eventID, targetDescriptor: address,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(direct, forKeyword: AEKeyword(keyDirectObject))
        if let value { event.setParam(value, forKeyword: AEKeyword(keyAEData)) }
        return event
    }
}

final class BrowserAppleEvents: PullRequestBrowserBackend, @unchecked Sendable {
    typealias PermissionChecker = @Sendable (BrowserTarget) throws -> BrowserAutomationPermission

    private let transport: BrowserAppleEventTransport
    private let permissionChecker: PermissionChecker

    init(
        transport: BrowserAppleEventTransport = NativeBrowserAppleEventTransport(),
        permissionChecker: @escaping PermissionChecker = { try BrowserAppleEvents.nativePermission($0) }
    ) {
        self.transport = transport
        self.permissionChecker = permissionChecker
    }

    func permission(for target: BrowserTarget) throws -> BrowserAutomationPermission {
        assert(!Thread.isMainThread)
        return try permissionChecker(target)
    }

    func windows(for target: BrowserTarget) throws -> [BrowserWindowSnapshot] {
        assert(!Thread.isMainThread)
        guard let dialect = BrowserDialect(bundleIdentifier: target.bundleIdentifier) else {
            throw BrowserAppleEventError.unsupportedBrowser(target.bundleIdentifier)
        }
        let allWindows = BrowserAppleEventCodec.all(BrowserAppleEventCodec.code("cwin"), in: .null())
        let ids = try list(get(BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("ID  "), of: allWindows), target: target), "window IDs")
        let indices = try list(get(BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("pidx"), of: allWindows), target: target), "window indices")
        let minimized = try list(get(BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("pmnd"), of: allWindows), target: target), "window minimized states")
        guard ids.count == indices.count, ids.count == minimized.count else {
            throw BrowserAppleEventError.malformedReply("window property counts")
        }

        return try ids.indices.compactMap { offset -> BrowserWindowSnapshot? in
            let locator: BrowserWindowLocator
            switch dialect {
            case .safari:
                locator = .safari(ids[offset].int32Value)
            case .chromium:
                locator = .chromium(try string(ids[offset], "window ID"))
            }
            let window = BrowserAppleEventCodec.window(locator)
            let tabCount = try count(dialect.tabClass, in: window, target: target)
            guard tabCount > 0 else { return nil }
            let allTabs = BrowserAppleEventCodec.all(dialect.tabClass, in: window)
            let urls = try list(get(BrowserAppleEventCodec.property(dialect.urlProperty, of: allTabs), target: target), "tab URLs")
            guard urls.count == tabCount else { throw BrowserAppleEventError.malformedReply("tab URL count") }
            let tabIDs: [NSAppleEventDescriptor]
            switch dialect {
            case .safari:
                tabIDs = []
            case .chromium:
                tabIDs = try list(get(BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("ID  "), of: allTabs), target: target), "tab IDs")
                guard tabIDs.count == tabCount else { throw BrowserAppleEventError.malformedReply("tab ID count") }
            }
            let tabs = try urls.indices.map { tabOffset -> BrowserTabSnapshot in
                let locator: BrowserTabLocator
                switch dialect {
                case .safari:
                    locator = .safari(index: tabOffset + 1)
                case .chromium:
                    locator = .chromium(id: try string(tabIDs[tabOffset], "tab ID"))
                }
                let rawURL = try string(urls[tabOffset], "tab URL")
                guard let url = URL(string: rawURL) else { throw BrowserAppleEventError.malformedReply("tab URL") }
                return BrowserTabSnapshot(locator: locator, url: url)
            }
            let activeIndex: Int
            switch dialect {
            case .safari:
                let current = BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("cTab"), of: window)
                activeIndex = Int(try get(BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("pidx"), of: current), target: target).int32Value)
            case .chromium:
                activeIndex = Int(try get(BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("acTI"), of: window), target: target).int32Value)
            }
            guard (1...tabCount).contains(activeIndex) else {
                throw BrowserAppleEventError.malformedReply("active tab index")
            }
            return BrowserWindowSnapshot(
                locator: locator,
                frontToBackIndex: Int(indices[offset].int32Value),
                minimized: minimized[offset].booleanValue,
                activeTabIndex: activeIndex,
                tabs: tabs
            )
        }
    }

    func apply(_ request: PullRequestOpenRequest, to selection: BrowserTabSelection, in target: BrowserTarget) throws {
        assert(!Thread.isMainThread)
        guard let dialect = BrowserDialect(bundleIdentifier: target.bundleIdentifier) else {
            throw BrowserAppleEventError.unsupportedBrowser(target.bundleIdentifier)
        }
        let window = BrowserAppleEventCodec.window(selection.window.locator)
        let tab = BrowserAppleEventCodec.tab(selection.tab.locator, in: window)
        let selectedIndex: Int
        switch selection.tab.locator {
        case .safari(let index):
            selectedIndex = index
        case .chromium(let id):
            let allTabs = BrowserAppleEventCodec.all(dialect.tabClass, in: window)
            let IDs = try list(get(BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("ID  "), of: allTabs), target: target), "tab IDs")
            guard let offset = try IDs.firstIndex(where: { try string($0, "tab ID") == id }) else {
                throw BrowserAppleEventError.selectedTabChanged
            }
            selectedIndex = offset + 1
        }
        let currentURL = try string(get(BrowserAppleEventCodec.property(dialect.urlProperty, of: tab), target: target), "selected tab URL")
        guard let current = URL(string: currentURL),
              let requestedIdentity = PullRequestIdentity(request.pullRequestURL),
              PullRequestIdentity(current) == requestedIdentity else {
            throw BrowserAppleEventError.selectedTabChanged
        }

        try set(BrowserAppleEventCodec.property(dialect.urlProperty, of: tab), to: NSAppleEventDescriptor(string: request.targetURL.absoluteString), target: target)
        if selection.window.minimized {
            try set(BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("pmnd"), of: window), to: NSAppleEventDescriptor(boolean: false), target: target)
        }
        switch dialect {
        case .safari:
            try set(BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("cTab"), of: window), to: tab, target: target)
        case .chromium:
            try set(BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("acTI"), of: window), to: NSAppleEventDescriptor(int32: Int32(selectedIndex)), target: target)
        }
        try set(BrowserAppleEventCodec.property(BrowserAppleEventCodec.code("pidx"), of: window), to: NSAppleEventDescriptor(int32: 1), target: target)
    }

    private func get(_ object: NSAppleEventDescriptor, target: BrowserTarget) throws -> NSAppleEventDescriptor {
        try send(BrowserAppleEventCodec.event(OSType(kAECoreSuite), OSType(kAEGetData), target: target, direct: object))
    }

    private func set(_ object: NSAppleEventDescriptor, to value: NSAppleEventDescriptor, target: BrowserTarget) throws {
        _ = try send(BrowserAppleEventCodec.event(OSType(kAECoreSuite), OSType(kAESetData), target: target, direct: object, value: value))
    }

    private func count(_ kind: OSType, in window: NSAppleEventDescriptor, target: BrowserTarget) throws -> Int {
        let event = BrowserAppleEventCodec.event(OSType(kAECoreSuite), OSType(kAECountElements), target: target, direct: window)
        event.setParam(NSAppleEventDescriptor(typeCode: kind), forKeyword: AEKeyword(keyAEObjectClass))
        let value = try send(event)
        let count = Int(value.int32Value)
        guard count >= 0 else { throw BrowserAppleEventError.malformedReply("tab count") }
        return count
    }

    private func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply = try transport.send(event)
        if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), number.int32Value != 0 {
            throw BrowserAppleEventError.replyError(
                number.int32Value,
                reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
            )
        }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
    }

    private func list(_ descriptor: NSAppleEventDescriptor, _ name: String) throws -> [NSAppleEventDescriptor] {
        guard descriptor.descriptorType == DescType(typeAEList) else {
            throw BrowserAppleEventError.malformedReply(name)
        }
        guard descriptor.numberOfItems > 0 else { return [] }
        return try (1...descriptor.numberOfItems).map { index in
            guard let item = descriptor.atIndex(index) else { throw BrowserAppleEventError.malformedReply(name) }
            return item
        }
    }

    private func string(_ descriptor: NSAppleEventDescriptor, _ name: String) throws -> String {
        guard let value = descriptor.stringValue else { throw BrowserAppleEventError.malformedReply(name) }
        return value
    }

    private static func nativePermission(_ target: BrowserTarget) throws -> BrowserAutomationPermission {
        let address = NSAppleEventDescriptor(processIdentifier: target.processIdentifier)
        let status = AEDeterminePermissionToAutomateTarget(
            address.aeDesc!, AEEventClass(typeWildCard), AEEventID(typeWildCard), true
        )
        let denied = OSStatus(errAEEventNotPermitted)
        switch status {
        case noErr: return .approved
        case denied: return .denied
        default: throw BrowserAppleEventError.permissionError(status)
        }
    }

}
