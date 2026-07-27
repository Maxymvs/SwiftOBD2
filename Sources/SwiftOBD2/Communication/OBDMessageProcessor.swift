//
//  OBDMessageProcessor.swift
//  SwiftOBD2
//
//  The request/response slot every stream transport shares: bytes in, `>`-terminated responses
//  out, one pending request at a time, with buffer retention across the gap between a delivered
//  response and the next arm.
//
//  It started life as `BLEMessageProcessor` and is substantively transport-neutral — nothing in
//  it knows about CoreBluetooth. WiFi now feeds it from a continuous receive pump, so both
//  transports get the same framing, the same timeout semantics (the timeout applies to the
//  *wait*, never to a socket read that would have to be abandoned) and the same gap retention,
//  instead of a second hand-rolled buffering implementation. `BLEMessageProcessor` remains as an
//  alias so the BLE call sites and their tests are untouched.
//
//  Two `BLEManagerError` values are used as the module's transport-neutral signals: `.noData` for
//  "the adapter answered nothing" and `.peripheralNotConnected` for "the slot died with the
//  link". They keep their exact meaning for BLE; the WiFi transport translates them into
//  `CommunicationError` at its own boundary.
//

import Foundation
import OSLog

// MARK: - Request Token & State Machine

/// Opaque token returned by `beginRequest()` to scope all subsequent operations
/// to the correct request generation.
struct RequestToken {
    let generation: Int
}

/// Internal state of a single pending BLE request.
private enum RequestState {
    case waitingForResponse
    case earlyResult([String])
    case earlyError(Error)
    case suspended(CheckedContinuation<[String], Error>)
    case completed

    /// Whether this slot can still take a completed response off the buffer.
    ///
    /// A slot that already resolved must not consume one: the bytes belong to whoever arms next.
    var canAcceptResponse: Bool {
        switch self {
        case .waitingForResponse, .suspended:
            return true
        case .earlyResult, .earlyError, .completed:
            return false
        }
    }
}

/// A single pending request slot (the sole source of truth for request lifecycle).
private struct PendingRequest {
    let generation: Int
    var state: RequestState
}

// MARK: - BLEMessageProcessor

class OBDMessageProcessor {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "OBDMessageProcessor")

    /// How much unclaimed data may be retained before it is dropped.
    private let maxBufferSize: Int

    init(maxBufferSize: Int = BLEConstants.maxBufferSize) {
        self.maxBufferSize = maxBufferSize
    }

    private let lock = NSLock()

    // All mutable state is protected by `lock`
    private var pendingRequest: PendingRequest?
    private var currentGeneration: Int = 0
    private var buffer = Data()

    // MARK: - beginRequest

    /// Create a new request slot. Any previous in-flight request is cancelled.
    /// **Must** be called before writing the BLE command.
    ///
    /// Returns a `RequestToken` that must be passed to `awaitResponse(for:timeout:)`.
    func beginRequest() -> RequestToken {
        var staleContToResume: CheckedContinuation<[String], Error>?

        lock.lock()
        // Cancel previous request if it has a suspended continuation
        if let prev = pendingRequest {
            if case .suspended(let cont) = prev.state {
                staleContToResume = cont
            }
        }
        currentGeneration += 1
        buffer.removeAll()
        pendingRequest = PendingRequest(generation: currentGeneration, state: .waitingForResponse)
        let token = RequestToken(generation: currentGeneration)
        lock.unlock()

        // Resume stale continuation outside lock
        if let cont = staleContToResume {
            cont.resume(throwing: BLEManagerError.sendingMessagesInProgress)
        }

        return token
    }

    // MARK: - beginContinuationRequest

    /// Arms a new request slot for an extra listen window **without clearing the buffer** and
    /// **without any write**.
    ///
    /// Used only for the DTC response-pending fallback: the ECU's final message may already be
    /// partially (or fully) buffered by the time we decide to keep listening, and
    /// `beginRequest()` would throw those bytes away. If the buffer already holds a complete
    /// `>`-terminated response it is delivered immediately as an early result.
    func beginContinuationRequest() -> RequestToken {
        var staleContToResume: CheckedContinuation<[String], Error>?

        lock.lock()
        if let prev = pendingRequest, case .suspended(let cont) = prev.state {
            staleContToResume = cont
        }
        currentGeneration += 1
        pendingRequest = PendingRequest(generation: currentGeneration, state: .waitingForResponse)
        let token = RequestToken(generation: currentGeneration)
        // Deliver whatever the buffer already completed, still under the lock.
        let delivery = drainCompletedResponseLocked()
        lock.unlock()

        deliver(delivery)

        if let cont = staleContToResume {
            cont.resume(throwing: BLEManagerError.sendingMessagesInProgress)
        }

        return token
    }

    // MARK: - awaitResponse

    /// Wait for the BLE response associated with `token`.
    ///
    /// - If BLE data already arrived (early result), returns immediately.
    /// - Otherwise suspends until `processReceivedData` delivers the result or timeout fires.
    func awaitResponse(for token: RequestToken, timeout: TimeInterval) async throws -> [String] {
        try Task.checkCancellation()

        // Check for early result / validate token.
        // Returns the early lines, throws on early error / stale token, or
        // returns nil when the request is still pending and we must suspend.
        let earlyLines: [String]? = try lock.withLock {
            guard let req = pendingRequest, req.generation == token.generation else {
                throw BLEMessageProcessorError.staleRequestToken
            }

            switch req.state {
            case .earlyResult(let lines):
                pendingRequest?.state = .completed
                return lines

            case .earlyError(let error):
                pendingRequest?.state = .completed
                throw error

            case .waitingForResponse:
                // Will suspend below
                return nil

            default:
                throw BLEMessageProcessorError.staleRequestToken
            }
        }
        if let earlyLines {
            return earlyLines
        }

        // Suspend: wrap in timeout + cancellation handler
        return try await withTimeout(
            seconds: timeout,
            timeoutError: BLEMessageProcessorError.responseTimeout,
            onTimeout: { [weak self] in
                guard let self else { return }
                self.clearBuffer(ifCurrent: token)
                self.fail(token, with: OBDMessageProcessorError.responseTimeout)
            }
        ) { [self] in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                    lock.lock()
                    // Re-validate: generation must still match and state must still be waitingForResponse
                    guard let req = pendingRequest,
                          req.generation == token.generation else {
                        lock.unlock()
                        continuation.resume(throwing: BLEMessageProcessorError.staleRequestToken)
                        return
                    }

                    switch req.state {
                    case .waitingForResponse:
                        pendingRequest?.state = .suspended(continuation)
                        lock.unlock()

                    case .earlyResult(let lines):
                        // Data arrived between the initial check and here
                        pendingRequest?.state = .completed
                        lock.unlock()
                        continuation.resume(returning: lines)

                    case .earlyError(let error):
                        pendingRequest?.state = .completed
                        lock.unlock()
                        continuation.resume(throwing: error)

                    default:
                        lock.unlock()
                        continuation.resume(throwing: BLEMessageProcessorError.staleRequestToken)
                    }
                }
            } onCancel: {
                fail(token, with: CancellationError())
            }
        }
    }

    /// Terminates the slot `token` owns with `error`, whether or not its awaiting task has
    /// actually suspended yet.
    ///
    /// The "not yet suspended" half is what makes it safe: a timeout or cancellation that fires
    /// between `beginRequest()` and the continuation body used to find the slot in
    /// `.waitingForResponse`, do nothing, and leave the body to suspend on a slot nobody would
    /// ever resume — and since `withTimeout`'s task group waits for its (already cancelled) child,
    /// the whole call hung past its own timeout. Recording the outcome as an early error means the
    /// body throws the instant it runs.
    ///
    /// Internal rather than private so the "fired before suspension" half can be tested directly:
    /// racing a real timeout against task scheduling is not reproducible.
    func fail(_ token: RequestToken, with error: Error) {
        var continuationToFail: CheckedContinuation<[String], Error>?

        lock.lock()
        if let req = pendingRequest, req.generation == token.generation {
            switch req.state {
            case let .suspended(continuation):
                pendingRequest?.state = .completed
                continuationToFail = continuation
            case .waitingForResponse:
                pendingRequest?.state = .earlyError(error)
            case .earlyResult, .earlyError, .completed:
                break // already resolved
            }
        }
        lock.unlock()

        continuationToFail?.resume(throwing: error)
    }

    // MARK: - processReceivedData

    /// Called from the transport's callback queue when data arrives from the adapter.
    ///
    /// A callback carries whatever the wire happened to deliver — it is not aligned to responses,
    /// so it may hold part of one, exactly one, or one and a bit. All of that is the buffer's
    /// problem; this just appends and lets the drain take at most one complete response.
    func processReceivedData(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let delivery = drainCompletedResponseLocked()
        lock.unlock()

        deliver(delivery)
    }

    /// A suspended continuation that must be resumed outside the lock.
    private enum Delivery {
        case none
        case lines(CheckedContinuation<[String], Error>, [String])
        case error(CheckedContinuation<[String], Error>, Error)
    }

    /// If the buffer holds a complete `>`-terminated response **and** a slot can take it,
    /// consumes it and routes it to that slot. **Must** be called with `lock` held; the returned
    /// delivery is resumed by the caller after unlocking.
    ///
    /// A response that nobody can accept is **retained**, not consumed. That is what closes the
    /// gap race in the DTC response-pending transaction: an ECU's final message landing between
    /// the `7F … 78` buffer and the continuation re-arm used to be parsed and thrown away, so the
    /// answer was lost for good. It now waits in the buffer for the next armed slot to drain —
    /// bounded by `maxBufferSize`, and cleared by `beginRequest()`/`reset()` so no stale bytes
    /// can ever leak into an unrelated command.
    private func drainCompletedResponseLocked() -> Delivery {
        // The prompt terminates exactly one response. Everything after it is the *next* response
        // and must survive — a single TCP callback can carry `…78\r>\r7E8 04 43 01`, and clearing
        // the whole buffer there used to destroy the beginning of the real answer, so the codes a
        // `0x78` was promising could never be reconstructed.
        guard let promptIndex = buffer.firstIndex(of: Self.promptByte) else {
            enforceBufferBoundLocked(reason: "Incomplete response")
            return .none
        }

        guard let req = pendingRequest, req.state.canAcceptResponse else {
            if buffer.count > maxBufferSize {
                logger.warning("Unclaimed response exceeded max buffer size, clearing")
                buffer.removeAll()
            } else {
                logger.debug("Response arrived with no slot able to accept it — retained for the next arm")
            }
            return .none
        }

        // Consume through the prompt, keep the remainder. Splitting on the prompt *byte* keeps a
        // partial multi-byte tail intact: a continuation byte is never `>`, so the prefix always
        // ends on a character boundary. Undecodable bytes inside it become replacement characters
        // rather than blocking the response forever.
        let response = String(decoding: buffer[buffer.startIndex ... promptIndex], as: UTF8.self)
        buffer = Data(buffer[buffer.index(after: promptIndex)...])
        let lines = parseResponse(from: response)

        let isNoData = lines.isEmpty || (lines.first?.uppercased().contains("NO DATA") == true)

        switch req.state {
        case .suspended(let continuation):
            pendingRequest?.state = .completed
            return isNoData ? .error(continuation, BLEManagerError.noData) : .lines(continuation, lines)

        case .waitingForResponse:
            // BLE response arrived before awaitResponse was called — store as early result
            if isNoData {
                pendingRequest?.state = .earlyError(BLEManagerError.noData)
            } else {
                pendingRequest?.state = .earlyResult(lines)
            }
            return .none

        case .earlyResult, .earlyError, .completed:
            return .none // unreachable: `canAcceptResponse` already excluded these
        }
    }

    private func deliver(_ delivery: Delivery) {
        switch delivery {
        case .none:
            break
        case let .lines(continuation, lines):
            continuation.resume(returning: lines)
        case let .error(continuation, error):
            continuation.resume(throwing: error)
        }
    }

    /// Clears the buffer, but only while `token` still owns the slot — so a timeout cannot wipe
    /// bytes that already belong to a newer request.
    private func clearBuffer(ifCurrent token: RequestToken) {
        lock.lock()
        if let req = pendingRequest, req.generation == token.generation {
            buffer.removeAll()
        }
        lock.unlock()
    }

    // MARK: - reset

    /// Full reset — called on disconnect. Bumps generation to invalidate all
    /// outstanding tokens, cancels any suspended continuation.
    func reset() {
        var contToResume: CheckedContinuation<[String], Error>?

        lock.lock()
        if let req = pendingRequest, case .suspended(let cont) = req.state {
            contToResume = cont
        }
        currentGeneration += 1
        pendingRequest = nil
        buffer.removeAll()
        lock.unlock()

        if let cont = contToResume {
            cont.resume(throwing: BLEManagerError.peripheralNotConnected)
        }
    }

    // MARK: - Private Helpers

    /// `>` — the ELM327 prompt that terminates one response.
    private static let promptByte: UInt8 = 0x3E

    /// Drops retained bytes once they exceed the cap, so retention can never grow without bound.
    private func enforceBufferBoundLocked(reason: String) {
        guard buffer.count > maxBufferSize else { return }
        logger.warning("\(reason) exceeded max buffer size, clearing")
        buffer.removeAll()
    }

    private func parseResponse(from string: String) -> [String] {
        let lines = string
            .replacingOccurrences(of: ">", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        logger.debug("Parsed response: \(lines)")
        return lines
    }
}

// MARK: - Error Types

enum OBDMessageProcessorError: Error, Equatable, LocalizedError {
    case characteristicNotWritable
    case writeOperationFailed
    case responseTimeout
    case invalidResponseData
    case staleRequestToken

    var errorDescription: String? {
        switch self {
        case .characteristicNotWritable:
            return "BLE characteristic does not support write operations"
        case .writeOperationFailed:
            return "Failed to write data to BLE characteristic"
        case .responseTimeout:
            return "Timeout waiting for BLE response"
        case .invalidResponseData:
            return "Received invalid response data from BLE device"
        case .staleRequestToken:
            return "Request token is stale (generation mismatch)"
        }
    }
}
