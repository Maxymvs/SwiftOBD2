import Foundation

/// A cancel-safe async semaphore for serializing access to a single-command BLE channel.
///
/// Uses `NSLock` to protect count and waiters array. Continuations are always
/// resumed **outside** the lock to avoid deadlocks.
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

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
        // Fast path: try to decrement under lock without suspending
        lock.lock()
        if count > 0 {
            count -= 1
            lock.unlock()
            return true
        }
        lock.unlock()

        // Slow path: suspend until a permit is available or cancellation
        let waiterId = UUID()
        // Track whether the waiter was cancelled before acquisition.
        // Uses a class box so the cancellation handler (Sendable closure) and
        // the continuation body can share mutable state under the same lock.
        let state = CancelState()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                // Re-check count — a signal may have arrived between the fast-path check and here
                if count > 0 {
                    count -= 1
                    lock.unlock()
                    continuation.resume()
                    return
                }
                // Check if task was already cancelled before we append.
                // If onCancel fired first, it found nothing in the array and returned.
                // Without this check the waiter would be queued with no cleanup path.
                if Task.isCancelled {
                    state.cancelledBeforeAcquire = true
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append((id: waiterId, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            // On cancel: remove waiter from queue if still there.
            // Do NOT increment count — a queued waiter never consumed a permit.
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == waiterId }) {
                let removed = waiters.remove(at: index)
                state.cancelledBeforeAcquire = true
                lock.unlock()
                // Resume the continuation so the suspended task can proceed.
                removed.continuation.resume()
            } else {
                // Already dequeued by signal() — signal() will resume it normally.
                // Permit was acquired via signal(), so cancelledBeforeAcquire stays false.
                lock.unlock()
            }
        }

        return !state.cancelledBeforeAcquire
    }

    /// Shared mutable flag between continuation body and cancellation handler.
    private final class CancelState: @unchecked Sendable {
        var cancelledBeforeAcquire = false
    }

    /// Release a permit. Resumes the next waiter if any, otherwise increments count.
    func signal() {
        lock.lock()
        if let first = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            first.continuation.resume()
        } else {
            count += 1
            lock.unlock()
        }
    }
}
