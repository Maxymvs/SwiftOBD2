import Foundation

enum BLEWriteMode: Equatable, Sendable {
    case withResponse
    case withoutResponse
}

/// The small transport surface needed by ``BLEWriteCoordinator``.
/// Production wraps a `CBPeripheral`; tests inject a deterministic transport.
protocol BLEWriteTransport: AnyObject, Sendable {
    func maximumWriteValueLength(for mode: BLEWriteMode) -> Int
    var canSendWriteWithoutResponse: Bool { get }
    func write(_ data: Data, mode: BLEWriteMode) throws
}

enum BLECommandEncodingError: Error, Equatable, LocalizedError {
    case emptyCommand
    case emptyTerminator
    case controlCharacterInCommand
    case nonASCIICommand
    case nonASCIITerminator

    var errorDescription: String? {
        switch self {
        case .emptyCommand: return "The BLE command is empty."
        case .emptyTerminator: return "The adapter profile has an empty command terminator."
        case .controlCharacterInCommand: return "The command contains a control character."
        case .nonASCIICommand: return "The command is not ASCII encodable."
        case .nonASCIITerminator: return "The adapter command terminator is not ASCII encodable."
        }
    }
}

/// Builds one byte payload before MTU chunking, so the terminator is appended once.
enum BLECommandEncoder {
    static func encode(command: String, terminator: String) throws -> Data {
        // ELM327 treats a bare carriage return as "repeat the last command".
        // Reject blank input so an API mistake cannot replay a prior write.
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BLECommandEncodingError.emptyCommand
        }
        guard !terminator.isEmpty else { throw BLECommandEncodingError.emptyTerminator }
        guard !command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw BLECommandEncodingError.controlCharacterInCommand
        }
        guard let commandData = command.data(using: .ascii) else {
            throw BLECommandEncodingError.nonASCIICommand
        }
        guard let terminatorData = terminator.data(using: .ascii) else {
            throw BLECommandEncodingError.nonASCIITerminator
        }

        var payload = commandData
        payload.append(terminatorData)
        return payload
    }
}

enum BLEWriteCoordinatorError: Error, Equatable, LocalizedError {
    case noActiveSession
    case sessionChanged
    case writeInProgress
    case invalidMaximumWriteLength(Int)
    case invalidDeadline
    case emptyPayload
    case deadlineExceeded
    case channelPoisoned
    case acknowledgementFailed(String)
    case transportWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noActiveSession: return "The BLE write channel is not configured."
        case .sessionChanged: return "The BLE write channel changed before the command was sent."
        case .writeInProgress: return "Another BLE write is already in progress."
        case let .invalidMaximumWriteLength(length):
            return "The peripheral reported an invalid BLE write length (\(length))."
        case .invalidDeadline: return "The BLE write deadline must be finite and greater than zero."
        case .emptyPayload: return "The BLE write payload is empty."
        case .deadlineExceeded: return "The BLE write did not complete before its deadline."
        case .channelPoisoned: return "The BLE write channel must reconnect before another command can be sent."
        case let .acknowledgementFailed(message): return "The peripheral rejected a BLE write: \(message)"
        case let .transportWriteFailed(message): return "The BLE write failed: \(message)"
        }
    }
}

protocol BLEWriteDeadlineToken: AnyObject {
    func cancel()
}

/// Injectable so timeout behavior can be tested without sleeping.
struct BLEWriteDeadlineScheduler: @unchecked Sendable {
    let schedule: (TimeInterval, @escaping @Sendable () -> Void) -> any BLEWriteDeadlineToken

    static let live = BLEWriteDeadlineScheduler { interval, action in
        TaskDeadlineToken(interval: interval, action: action)
    }
}

private final class TaskDeadlineToken: BLEWriteDeadlineToken, @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(interval: TimeInterval, action: @escaping @Sendable () -> Void) {
        let nanoseconds = UInt64(interval * 1_000_000_000)
        task = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            defer { self.task = nil }
            return self.task
        }
        task?.cancel()
    }
}

/// Serializes and chunks one command payload at a time.
///
/// Every state decision and physical transport write runs on `executor`. This
/// prevents cancellation, reset, acknowledgements, and concurrent ready events
/// from reserving or sending chunks out of order. Transport callbacks enqueue a
/// later event, so a synchronous injected callback cannot re-enter the state
/// machine while `write` is executing.
final class BLEWriteCoordinator: @unchecked Sendable {
    typealias Completion = (Result<Void, Error>) -> Void
    static let maximumSupportedDeadline: TimeInterval = 3_600

    private struct Transfer {
        let id: UInt64
        let session: UInt64
        let mode: BLEWriteMode
        let chunks: [Data]
        let transport: any BLEWriteTransport
        let cancellation: CancellationRegistration
        let completion: Completion
        var nextChunkIndex = 0
        var waitingForAcknowledgement = false
        var waitingForFlowControl = false
        var submittedChunkCount = 0
        var deadlineToken: (any BLEWriteDeadlineToken)?
    }

    private final class CancellationRegistration: @unchecked Sendable {
        private let lock = NSLock()
        private var transferID: UInt64?
        private var isCancelled = false

        func register(transferID: UInt64) -> Bool {
            lock.withLock {
                self.transferID = transferID
                return isCancelled
            }
        }

        func cancel() -> UInt64? {
            lock.withLock {
                isCancelled = true
                return transferID
            }
        }

        var cancelled: Bool { lock.withLock { isCancelled } }
    }

    private let executor = DispatchQueue(label: "com.swiftobd2.ble-write-transport")
    private let executorKey = DispatchSpecificKey<UInt8>()
    private let deadlineScheduler: BLEWriteDeadlineScheduler

    // Access only on `executor`.
    private var activeSession: UInt64?
    private var nextSession: UInt64 = 0
    private var nextTransferID: UInt64 = 0
    private var activeTransfer: Transfer?
    private var poisonedSession: UInt64?

    init(deadlineScheduler: BLEWriteDeadlineScheduler = .live) {
        self.deadlineScheduler = deadlineScheduler
        executor.setSpecific(key: executorKey, value: 1)
    }

    @discardableResult
    func activateSession() -> UInt64 {
        let result: (UInt64, Transfer?) = serialized {
            nextSession &+= 1
            let session = nextSession
            let displaced = activeTransfer
            activeTransfer = nil
            activeSession = session
            poisonedSession = nil
            return (session, displaced)
        }
        finish(result.1, with: .failure(BLEWriteCoordinatorError.sessionChanged))
        return result.0
    }

    /// Invalidates only the expected session; a stale reset cannot kill a newer channel.
    func invalidateSession(_ expectedSession: UInt64, with error: Error) {
        let displaced: Transfer? = serialized {
            guard activeSession == expectedSession else { return nil }
            nextSession &+= 1
            let displaced = activeTransfer
            activeTransfer = nil
            activeSession = nil
            poisonedSession = nil
            return displaced
        }
        finish(displaced, with: .failure(error))
    }

    func write(
        _ payload: Data,
        mode: BLEWriteMode,
        session: UInt64,
        transport: any BLEWriteTransport,
        deadline: TimeInterval
    ) async throws {
        let cancellation = CancellationRegistration()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                executor.async { [self] in
                    start(
                        payload,
                        mode: mode,
                        session: session,
                        transport: transport,
                        deadline: deadline,
                        cancellation: cancellation
                    ) { result in
                        continuation.resume(with: result)
                    }
                }
            }
        } onCancel: {
            guard let transferID = cancellation.cancel() else { return }
            self.executor.async { [weak self] in self?.cancel(transferID: transferID) }
        }
    }

    func didReceiveAcknowledgement(session: UInt64, error: Error?) {
        executor.async { [weak self] in
            guard let self,
                  var transfer = self.activeTransfer,
                  transfer.session == session,
                  transfer.mode == .withResponse,
                  transfer.waitingForAcknowledgement else { return }

            if let error {
                self.activeTransfer = nil
                self.poisonedSession = session
                self.finish(
                    transfer,
                    with: .failure(BLEWriteCoordinatorError.acknowledgementFailed(error.localizedDescription))
                )
                return
            }

            transfer.waitingForAcknowledgement = false
            transfer.nextChunkIndex += 1
            let transferID = transfer.id
            self.activeTransfer = transfer
            self.pumpOneChunk(transferID: transferID)
        }
    }

    func peripheralIsReady(session: UInt64) {
        executor.async { [weak self] in
            guard let self,
                  var transfer = self.activeTransfer,
                  transfer.session == session,
                  transfer.mode == .withoutResponse,
                  transfer.waitingForFlowControl else { return }
            transfer.waitingForFlowControl = false
            let transferID = transfer.id
            self.activeTransfer = transfer
            self.pumpOneChunk(transferID: transferID)
        }
    }

    /// Test seam for proving that callback events queued before this call have
    /// been handled. It does not mutate transport state.
    func drainEvents() async {
        await withCheckedContinuation { continuation in
            executor.async { [executor] in
                // Events may enqueue one follow-up pump. A second barrier lands
                // behind that follow-up without relying on scheduler timing.
                executor.async { continuation.resume() }
            }
        }
    }

    private func start(
        _ payload: Data,
        mode: BLEWriteMode,
        session: UInt64,
        transport: any BLEWriteTransport,
        deadline: TimeInterval,
        cancellation: CancellationRegistration,
        completion: @escaping Completion
    ) {
        dispatchPrecondition(condition: .onQueue(executor))
        guard !payload.isEmpty else { completion(.failure(BLEWriteCoordinatorError.emptyPayload)); return }
        guard deadline.isFinite, deadline > 0, deadline <= Self.maximumSupportedDeadline else {
            completion(.failure(BLEWriteCoordinatorError.invalidDeadline)); return
        }

        let maximumLength = transport.maximumWriteValueLength(for: mode)
        guard maximumLength > 0 else {
            completion(.failure(BLEWriteCoordinatorError.invalidMaximumWriteLength(maximumLength))); return
        }
        guard activeSession != nil else { completion(.failure(BLEWriteCoordinatorError.noActiveSession)); return }
        guard activeSession == session else { completion(.failure(BLEWriteCoordinatorError.sessionChanged)); return }
        guard poisonedSession != session else { completion(.failure(BLEWriteCoordinatorError.channelPoisoned)); return }
        guard activeTransfer == nil else { completion(.failure(BLEWriteCoordinatorError.writeInProgress)); return }

        nextTransferID &+= 1
        let transferID = nextTransferID
        activeTransfer = Transfer(
            id: transferID,
            session: session,
            mode: mode,
            chunks: payload.chunked(maximumLength: maximumLength),
            transport: transport,
            cancellation: cancellation,
            completion: completion
        )

        if cancellation.register(transferID: transferID) {
            cancel(transferID: transferID)
            return
        }

        let deadlineToken = deadlineScheduler.schedule(deadline) { [weak self] in
            self?.executor.async { [weak self] in self?.deadlineExpired(transferID: transferID) }
        }
        guard var transfer = activeTransfer, transfer.id == transferID else {
            deadlineToken.cancel()
            return
        }
        transfer.deadlineToken = deadlineToken
        activeTransfer = transfer
        schedulePump(transferID: transferID)
    }

    /// One executor turn performs at most one physical write. Terminal events
    /// already queued ahead of the next turn therefore stop further chunks.
    private func schedulePump(transferID: UInt64) {
        executor.async { [weak self] in self?.pumpOneChunk(transferID: transferID) }
    }

    private func pumpOneChunk(transferID: UInt64) {
        dispatchPrecondition(condition: .onQueue(executor))
        guard var transfer = activeTransfer, transfer.id == transferID else { return }
        if transfer.cancellation.cancelled { cancel(transferID: transferID); return }

        guard transfer.nextChunkIndex < transfer.chunks.count else {
            activeTransfer = nil
            finish(transfer, with: .success(()))
            return
        }

        switch transfer.mode {
        case .withResponse:
            guard !transfer.waitingForAcknowledgement else { return }
            let chunk = transfer.chunks[transfer.nextChunkIndex]
            transfer.waitingForAcknowledgement = true
            transfer.submittedChunkCount += 1
            activeTransfer = transfer
            performPhysicalWrite(chunk, transferID: transferID)

        case .withoutResponse:
            guard transfer.transport.canSendWriteWithoutResponse else {
                transfer.waitingForFlowControl = true
                activeTransfer = transfer
                return
            }
            let chunk = transfer.chunks[transfer.nextChunkIndex]
            transfer.nextChunkIndex += 1
            transfer.submittedChunkCount += 1
            activeTransfer = transfer
            performPhysicalWrite(chunk, transferID: transferID)
            if activeTransfer?.id == transferID { schedulePump(transferID: transferID) }
        }
    }

    private func performPhysicalWrite(_ chunk: Data, transferID: UInt64) {
        dispatchPrecondition(condition: .onQueue(executor))
        guard let transfer = activeTransfer, transfer.id == transferID else { return }
        do {
            try transfer.transport.write(chunk, mode: transfer.mode)
        } catch {
            guard let latest = activeTransfer, latest.id == transferID else { return }
            activeTransfer = nil
            poisonedSession = latest.session
            finish(
                latest,
                with: .failure(BLEWriteCoordinatorError.transportWriteFailed(error.localizedDescription))
            )
        }
    }

    private func deadlineExpired(transferID: UInt64) {
        dispatchPrecondition(condition: .onQueue(executor))
        guard let transfer = activeTransfer, transfer.id == transferID else { return }
        activeTransfer = nil
        poisonedSession = transfer.session
        finish(transfer, with: .failure(BLEWriteCoordinatorError.deadlineExceeded))
    }

    private func cancel(transferID: UInt64) {
        dispatchPrecondition(condition: .onQueue(executor))
        guard let transfer = activeTransfer, transfer.id == transferID else { return }
        activeTransfer = nil
        poisonedSession = transfer.session
        finish(transfer, with: .failure(CancellationError()))
    }

    private func finish(_ transfer: Transfer?, with result: Result<Void, Error>) {
        guard let transfer else { return }
        transfer.deadlineToken?.cancel()
        transfer.completion(result)
    }

    private func serialized<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: executorKey) != nil { return body() }
        return executor.sync(execute: body)
    }
}

private extension Data {
    func chunked(maximumLength: Int) -> [Data] {
        var chunks: [Data] = []
        chunks.reserveCapacity(1 + (count - 1) / maximumLength)
        var offset = 0
        while offset < count {
            let end = Swift.min(offset + maximumLength, count)
            chunks.append(subdata(in: offset ..< end))
            offset = end
        }
        return chunks
    }
}
