import Foundation

/// Which queue a read waits in. Reads of the sequential chains (discovery, viewer teams) get the next free permit
/// ahead of hydration and continuation reads.
enum GitHubReadPriority: Sendable {
    case chain
    case bulk
}

/// Caps one refresh's GraphQL reads in flight and stops the refresh's reads at its first failure.
///
/// Permits go first come first served within a priority, `chain` before `bulk`, and none is reserved. Once
/// stopped, waiting and later callers throw `GitHubReadStopped` without running their operation, while operations
/// already holding a permit finish.
final class GitHubReadLimiter: @unchecked Sendable {
    static let defaultCapacity = 4

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private let capacity: Int
    private var inUse = 0
    private var stopped = false
    private var failures = GitHubReadFailures()
    private var nextWaiterID = 0
    private var chainWaiters: [Waiter] = []
    private var bulkWaiters: [Waiter] = []

    init(capacity: Int = GitHubReadLimiter.defaultCapacity) {
        self.capacity = capacity
    }

    var isStopped: Bool { lock.withLock { stopped } }

    /// Callers waiting for a permit.
    var waitingCount: Int { lock.withLock { chainWaiters.count + bulkWaiters.count } }

    /// Runs `operation` under a permit. An operation that fails with anything but a stop or a cancellation stops
    /// the limiter before its permit frees, so no waiter sends after the failure.
    func withPermit<T: Sendable>(
        _ priority: GitHubReadPriority,
        _ operation: () async throws -> T
    ) async throws -> T {
        try await acquire(priority)
        let value: T
        do {
            value = try await operation()
        } catch {
            lock.withLock {
                if !(error is GitHubReadStopped || error is CancellationError) { stopLocked() }
                releaseLocked()
            }
            throw error
        }
        lock.withLock { releaseLocked() }
        return value
    }

    /// Records a failure at its place in the refresh order and stops the limiter.
    func fail(_ error: Error, at order: GitHubReadOrder) {
        lock.withLock {
            failures.record(error, at: order)
            stopLocked()
        }
    }

    /// The failure that ends the refresh, chosen by precedence among the recorded ones.
    func failure() -> Error? {
        lock.withLock { failures.error() }
    }

    func stop() {
        lock.withLock { stopLocked() }
    }

    private func acquire(_ priority: GitHubReadPriority) async throws {
        try Task.checkCancellation()
        let id = lock.withLock { () -> Int in
            nextWaiterID += 1
            return nextWaiterID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if stopped {
                        continuation.resume(throwing: GitHubReadStopped())
                    } else if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if inUse < capacity {
                        inUse += 1
                        continuation.resume()
                    } else {
                        let waiter = Waiter(id: id, continuation: continuation)
                        switch priority {
                        case .chain: chainWaiters.append(waiter)
                        case .bulk: bulkWaiters.append(waiter)
                        }
                    }
                }
            }
        } onCancel: {
            lock.withLock {
                let waiter = removeWaiterLocked(id: id)
                waiter?.continuation.resume(throwing: CancellationError())
            }
        }
        // A cancellation that raced the grant hands the permit on.
        if Task.isCancelled {
            lock.withLock { releaseLocked() }
            throw CancellationError()
        }
    }

    private func removeWaiterLocked(id: Int) -> Waiter? {
        if let index = chainWaiters.firstIndex(where: { $0.id == id }) {
            return chainWaiters.remove(at: index)
        }
        if let index = bulkWaiters.firstIndex(where: { $0.id == id }) {
            return bulkWaiters.remove(at: index)
        }
        return nil
    }

    private func releaseLocked() {
        inUse -= 1
        guard !stopped else { return }
        while inUse < capacity {
            let waiter: Waiter
            if !chainWaiters.isEmpty {
                waiter = chainWaiters.removeFirst()
            } else if !bulkWaiters.isEmpty {
                waiter = bulkWaiters.removeFirst()
            } else {
                return
            }
            inUse += 1
            waiter.continuation.resume()
        }
    }

    private func stopLocked() {
        guard !stopped else { return }
        stopped = true
        let waiters = chainWaiters + bulkWaiters
        chainWaiters = []
        bulkWaiters = []
        waiters.forEach { $0.continuation.resume(throwing: GitHubReadStopped()) }
    }
}
