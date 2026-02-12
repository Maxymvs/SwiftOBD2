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
}

/// A single pending request slot (the sole source of truth for request lifecycle).
private struct PendingRequest {
    let generation: Int
    var state: RequestState
}

// MARK: - BLEMessageProcessor

class BLEMessageProcessor {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "BLEMessageProcessor")

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

    // MARK: - awaitResponse

    /// Wait for the BLE response associated with `token`.
    ///
    /// - If BLE data already arrived (early result), returns immediately.
    /// - Otherwise suspends until `processReceivedData` delivers the result or timeout fires.
    func awaitResponse(for token: RequestToken, timeout: TimeInterval) async throws -> [String] {
        try Task.checkCancellation()

        // Check for early result / validate token
        lock.lock()
        guard let req = pendingRequest, req.generation == token.generation else {
            lock.unlock()
            throw BLEMessageProcessorError.staleRequestToken
        }

        switch req.state {
        case .earlyResult(let lines):
            pendingRequest?.state = .completed
            lock.unlock()
            return lines

        case .earlyError(let error):
            pendingRequest?.state = .completed
            lock.unlock()
            throw error

        case .waitingForResponse:
            // Will suspend below
            lock.unlock()

        default:
            lock.unlock()
            throw BLEMessageProcessorError.staleRequestToken
        }

        // Suspend: wrap in timeout + cancellation handler
        return try await withTimeout(
            seconds: timeout,
            timeoutError: BLEMessageProcessorError.responseTimeout,
            onTimeout: { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard let req = self.pendingRequest,
                      req.generation == token.generation,
                      case .suspended(let cont) = req.state else {
                    self.lock.unlock()
                    return
                }
                self.pendingRequest?.state = .completed
                self.buffer.removeAll()
                self.lock.unlock()
                cont.resume(throwing: BLEMessageProcessorError.responseTimeout)
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
                lock.lock()
                guard let req = pendingRequest,
                      req.generation == token.generation,
                      case .suspended(let cont) = req.state else {
                    lock.unlock()
                    return
                }
                pendingRequest?.state = .completed
                lock.unlock()
                cont.resume(throwing: CancellationError())
            }
        }
    }

    // MARK: - processReceivedData

    /// Called from the BLE callback queue when data arrives from the adapter.
    func processReceivedData(_ data: Data) {
        lock.lock()
        buffer.append(data)

        guard let string = String(data: buffer, encoding: .utf8) else {
            // Only clear if buffer is getting too large
            if buffer.count > BLEConstants.maxBufferSize {
                logger.warning("Buffer exceeded max size, clearing")
                buffer.removeAll()
            }
            lock.unlock()
            return
        }

        // Check for end-of-response marker
        guard string.contains(">") else {
            lock.unlock()
            return
        }

        // Parse response and clear buffer
        let lines = parseResponse(from: string)
        buffer.removeAll()

        // Determine what to do with the result
        guard let req = pendingRequest else {
            lock.unlock()
            logger.warning("Received response with no pending request (nil slot)")
            return
        }

        let isNoData = lines.isEmpty || (lines.first?.uppercased().contains("NO DATA") == true)

        switch req.state {
        case .suspended(let continuation):
            pendingRequest?.state = .completed
            lock.unlock()
            if isNoData {
                continuation.resume(throwing: BLEManagerError.noData)
            } else {
                continuation.resume(returning: lines)
            }

        case .waitingForResponse:
            // BLE response arrived before awaitResponse was called — store as early result
            if isNoData {
                pendingRequest?.state = .earlyError(BLEManagerError.noData)
            } else {
                pendingRequest?.state = .earlyResult(lines)
            }
            lock.unlock()

        case .completed, .earlyResult, .earlyError:
            lock.unlock()
            logger.warning("Received response but slot already resolved (state: completed/early)")

        }
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

enum BLEMessageProcessorError: Error, Equatable, LocalizedError {
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
