import Foundation

struct BLESetupToken: Equatable, Sendable {
    fileprivate let generation: UInt64
}

enum BLESetupGateError: Error, Equatable, LocalizedError {
    case staleToken
    case superseded
    case waiterAlreadyRegistered
    case invalidTimeout
    case timedOut

    var errorDescription: String? {
        switch self {
        case .staleToken: return "The BLE setup attempt is no longer current."
        case .superseded: return "A newer BLE setup attempt replaced this one."
        case .waiterAlreadyRegistered: return "This BLE setup attempt already has a waiter."
        case .invalidTimeout: return "The BLE setup timeout must be finite and greater than zero."
        case .timedOut: return "The BLE setup attempt timed out."
        }
    }
}

/// Owns one generation-scoped BLE setup result and at most one waiter.
///
/// A terminal result is retained even when it arrives before `wait`. Timeout
/// and cancellation close only the token their waiter owns, so late events from
/// an older connection cannot complete or cancel a newer attempt.
final class BLESetupGate: @unchecked Sendable {
    private typealias Completion = (Result<Void, Error>) -> Void

    private struct Waiter {
        let id: UInt64
        let completion: Completion
        var deadlineToken: (any BLEWriteDeadlineToken)?
    }

    private struct Attempt {
        let token: BLESetupToken
        var terminalResult: Result<Void, Error>?
        var waiter: Waiter?
    }

    private final class CancellationRegistration: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: (BLESetupToken, UInt64)?
        private var isCancelled = false

        func register(token: BLESetupToken, waiterID: UInt64) -> Bool {
            lock.withLock {
                owner = (token, waiterID)
                return isCancelled
            }
        }

        func cancel() -> (BLESetupToken, UInt64)? {
            lock.withLock {
                isCancelled = true
                return owner
            }
        }
    }

    private let lock = NSLock()
    private let deadlineScheduler: BLEWriteDeadlineScheduler
    private var nextGeneration: UInt64 = 0
    private var nextWaiterID: UInt64 = 0
    private var attempt: Attempt?

    init(deadlineScheduler: BLEWriteDeadlineScheduler = .live) {
        self.deadlineScheduler = deadlineScheduler
    }

    /// Starts a new setup generation and unblocks any waiter on the old one.
    func begin() -> BLESetupToken {
        let result = lock.withLock { () -> (BLESetupToken, Waiter?) in
            nextGeneration &+= 1
            let token = BLESetupToken(generation: nextGeneration)
            let displaced = attempt?.waiter
            attempt = Attempt(token: token)
            return (token, displaced)
        }
        complete(result.1, with: .failure(BLESetupGateError.superseded))
        return result.0
    }

    /// True only while this token is the current unfinished attempt.
    func isCurrent(_ token: BLESetupToken) -> Bool {
        lock.withLock {
            attempt?.token == token && attempt?.terminalResult == nil
        }
    }

    /// First terminal result wins. Duplicate and stale callbacks are ignored.
    @discardableResult
    func finish(token: BLESetupToken, result: Result<Void, Error>) -> Bool {
        let outcome = lock.withLock { () -> (Bool, Waiter?) in
            guard var current = attempt,
                  current.token == token,
                  current.terminalResult == nil else { return (false, nil) }
            current.terminalResult = result
            let waiter = current.waiter
            current.waiter = nil
            attempt = current
            return (true, waiter)
        }
        complete(outcome.1, with: result)
        return outcome.0
    }

    func wait(token: BLESetupToken, timeout: TimeInterval) async throws {
        // A pre-cancelled caller must not consume a retained success. This check
        // also avoids registering a waiter that its cancellation handler would
        // immediately have to tear down.
        try Task.checkCancellation()
        let cancellation = CancellationRegistration()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startWait(
                    token: token,
                    timeout: timeout,
                    cancellation: cancellation
                ) { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            guard let owner = cancellation.cancel() else { return }
            self.cancelWait(token: owner.0, waiterID: owner.1)
        }
    }

    /// Closes the current token with a retained failure.
    func close(token: BLESetupToken, with error: Error) {
        _ = finish(token: token, result: .failure(error))
    }

    /// Drops the current generation and terminates its pending waiter.
    func reset(with error: Error) {
        let waiter = lock.withLock { () -> Waiter? in
            nextGeneration &+= 1
            defer { attempt = nil }
            return attempt?.waiter
        }
        complete(waiter, with: .failure(error))
    }

    private func startWait(
        token: BLESetupToken,
        timeout: TimeInterval,
        cancellation: CancellationRegistration,
        completion: @escaping Completion
    ) {
        guard timeout.isFinite,
              timeout > 0,
              timeout <= BLEWriteCoordinator.maximumSupportedDeadline else {
            completion(.failure(BLESetupGateError.invalidTimeout))
            return
        }

        let registration: Result<UInt64, Error> = lock.withLock {
            guard var current = attempt, current.token == token else {
                return .failure(BLESetupGateError.staleToken)
            }
            if let terminal = current.terminalResult {
                return terminal.map { _ in 0 }
            }
            guard current.waiter == nil else {
                return .failure(BLESetupGateError.waiterAlreadyRegistered)
            }

            nextWaiterID &+= 1
            let waiterID = nextWaiterID
            current.waiter = Waiter(id: waiterID, completion: completion)
            attempt = current
            return .success(waiterID)
        }

        guard case let .success(waiterID) = registration else {
            if case let .failure(error) = registration { completion(.failure(error)) }
            return
        }
        // A retained success uses the sentinel zero and needs no waiter/deadline.
        if waiterID == 0 {
            completion(.success(()))
            return
        }

        if cancellation.register(token: token, waiterID: waiterID) {
            cancelWait(token: token, waiterID: waiterID)
            return
        }

        let deadlineToken = deadlineScheduler.schedule(timeout) { [weak self] in
            self?.timeoutWait(token: token, waiterID: waiterID)
        }
        let retained = lock.withLock { () -> Bool in
            guard var current = attempt,
                  current.token == token,
                  var waiter = current.waiter,
                  waiter.id == waiterID else { return false }
            waiter.deadlineToken = deadlineToken
            current.waiter = waiter
            attempt = current
            return true
        }
        if !retained { deadlineToken.cancel() }
    }

    private func timeoutWait(token: BLESetupToken, waiterID: UInt64) {
        finishWait(
            token: token,
            waiterID: waiterID,
            result: .failure(BLESetupGateError.timedOut)
        )
    }

    private func cancelWait(token: BLESetupToken, waiterID: UInt64) {
        finishWait(
            token: token,
            waiterID: waiterID,
            result: .failure(CancellationError())
        )
    }

    private func finishWait(
        token: BLESetupToken,
        waiterID: UInt64,
        result: Result<Void, Error>
    ) {
        let waiter = lock.withLock { () -> Waiter? in
            guard var current = attempt,
                  current.token == token,
                  current.terminalResult == nil,
                  let waiter = current.waiter,
                  waiter.id == waiterID else { return nil }
            current.terminalResult = result
            current.waiter = nil
            attempt = current
            return waiter
        }
        complete(waiter, with: result)
    }

    private func complete(_ waiter: Waiter?, with result: Result<Void, Error>) {
        guard let waiter else { return }
        waiter.deadlineToken?.cancel()
        waiter.completion(result)
    }
}
