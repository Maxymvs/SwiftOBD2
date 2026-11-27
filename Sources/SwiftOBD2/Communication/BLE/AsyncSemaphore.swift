import Foundation

/// A cancel-safe async semaphore for serializing access to a single-command BLE channel.
///
/// Uses `NSLock` to protect count and waiters array. Continuations are always
/// resumed **outside** the lock to avoid deadlocks.
///
/// Every queued waiter is resumed exactly once, by whichever of `signal()`, its task's
/// cancellation or (for `wait(until:)`) its deadline removes it from the queue first. Removal
/// and the decision what to resume it with happen under one lock acquisition, so a deadline or
/// a cancellation racing a `signal()` can neither lose the permit `signal()` handed over nor
/// grant one twice.
final class AsyncSemaphore: @unchecked Sendable {
    /// How a bounded wait ended.
    enum WaitOutcome: Equatable, Sendable {
        /// The permit is held; the caller must `signal()` exactly once.
        case acquired
        /// The task was cancelled first. No permit is held.
        case cancelled
        /// The deadline passed first. No permit is held.
        case timedOut
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<WaitOutcome, Never>
    }

    private let lock = NSLock()
    private var count: Int
    private var waiters: [Waiter] = []

    init(value: Int) {
        precondition(value >= 0)
        self.count = value
    }

    /// Wait to acquire a permit.
    ///
    /// - Returns: `true` if the permit was acquired, `false` if the task was cancelled
    ///   before acquisition (waiter removed from queue without consuming a permit).
    ///
    /// Callers **must** only call `signal()` when this returns `true`.
    func wait() async -> Bool {
        await acquire(deadline: nil, now: { 0 }) == .acquired
    }

    /// Waits for a permit until the absolute `deadline` (in `now()` seconds, by default
    /// `ProcessInfo.processInfo.systemUptime`).
    ///
    /// A free permit is taken even when the deadline has already passed: only a wait that would
    /// have to suspend can time out. Callers **must** call `signal()` exactly once when, and only
    /// when, this returns `.acquired`.
    func wait(
        until deadline: TimeInterval,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async -> WaitOutcome {
        await acquire(deadline: deadline, now: now)
    }

    /// Release a permit. Resumes the next waiter if any, otherwise increments count.
    func signal() {
        lock.lock()
        if !waiters.isEmpty {
            let first = waiters.removeFirst()
            lock.unlock()
            first.continuation.resume(returning: .acquired)
        } else {
            count += 1
            lock.unlock()
        }
    }

    /// Test seam: permits currently free and waiters currently queued.
    var snapshot: (available: Int, waiting: Int) {
        lock.withLock { (count, waiters.count) }
    }

    // MARK: - Implementation

    private func acquire(deadline: TimeInterval?, now: @escaping @Sendable () -> TimeInterval) async -> WaitOutcome {
        // Fast path: try to decrement under lock without suspending
        let acquiredWithoutSuspending = lock.withLock { () -> Bool in
            if count > 0 {
                count -= 1
                return true
            }
            return false
        }
        if acquiredWithoutSuspending {
            return .acquired
        }

        // Slow path: suspend until a permit, cancellation or the deadline.
        let waiterID = UUID()
        let timer = TimerBox()
        defer { timer.cancel() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WaitOutcome, Never>) in
                lock.lock()
                // Re-check count — a signal may have arrived between the fast-path check and here
                if count > 0 {
                    count -= 1
                    lock.unlock()
                    continuation.resume(returning: .acquired)
                    return
                }
                // Check if task was already cancelled before we append.
                // If onCancel fired first, it found nothing in the array and returned.
                // Without this check the waiter would be queued with no cleanup path.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: .cancelled)
                    return
                }
                var remaining: TimeInterval?
                if let deadline {
                    let left = deadline - now()
                    guard left > 0 else {
                        lock.unlock()
                        continuation.resume(returning: .timedOut)
                        return
                    }
                    remaining = left
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
                lock.unlock()

                if let remaining {
                    timer.start(after: remaining) { [weak self] in
                        self?.removeWaiter(waiterID, resumingWith: .timedOut)
                    }
                }
            }
        } onCancel: {
            // Do NOT increment count — a queued waiter never consumed a permit. If `signal()`
            // already dequeued it, it resumes it with `.acquired` and this does nothing.
            removeWaiter(waiterID, resumingWith: .cancelled)
        }
    }

    /// Resumes the waiter with `outcome` if it is still queued; otherwise whoever dequeued it
    /// first already resumed it.
    private func removeWaiter(_ id: UUID, resumingWith outcome: WaitOutcome) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let removed = waiters.remove(at: index)
        lock.unlock()
        removed.continuation.resume(returning: outcome)
    }

    /// The deadline timer of one waiter. Cancelled once the wait ends, whichever way.
    private final class TimerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var cancelled = false

        func start(after seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
            let nanoseconds = UInt64(min(seconds, 86_400) * 1_000_000_000)
            let task = Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                fire()
            }
            let alreadyCancelled = lock.withLock { () -> Bool in
                if cancelled { return true }
                self.task = task
                return false
            }
            if alreadyCancelled { task.cancel() }
        }

        func cancel() {
            let task = lock.withLock { () -> Task<Void, Never>? in
                cancelled = true
                defer { self.task = nil }
                return self.task
            }
            task?.cancel()
        }
    }
}
