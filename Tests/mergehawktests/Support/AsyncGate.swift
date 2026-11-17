import Foundation
import XCTest

/// Holds async callers until a test opens it.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { lock.withLock { waiters.count } }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if isOpen { continuation.resume() } else { waiters.append(continuation) }
            }
        }
    }

    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        released.forEach { $0.resume() }
    }
}

/// Polls `condition` until it holds, failing after `timeout` seconds.
func waitForCondition(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("Condition not met within \(timeout) s", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
