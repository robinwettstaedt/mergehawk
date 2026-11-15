import Foundation

/// A lock-protected value that test stubs share across concurrent requests.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&stored) }
    }
}

extension LockedBox where Value == Int {
    /// Adds one and returns the new count.
    @discardableResult
    func increment() -> Int { withValue { $0 += 1; return $0 } }
}

extension LockedBox where Value == [String: Int] {
    /// Counts one more call for `key` and returns its 1-based count.
    @discardableResult
    func increment(_ key: String) -> Int { withValue { $0[key, default: 0] += 1; return $0[key]! } }
}
