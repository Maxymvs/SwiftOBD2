//
//  wifiManager.swift
//
//
//  Created by kemo konteh on 2/26/24.
//

import Combine
import CoreBluetooth
import Foundation
import Network
import OSLog

protocol CommProtocol {
    func sendCommand(_ command: String, retries: Int) async throws -> [String]
    /// `sendCommand` with a longer wait for slow exchanges. Transports without a per-command
    /// response timeout ignore it.
    func sendCommand(_ command: String, retries: Int, responseTimeout: TimeInterval) async throws -> [String]
    /// `sendCommand` for a request bound to something that must still hold when the bytes go
    /// out (a Mode 04 clear bound to one vehicle link). See `OBDWriteAuthorization`:
    /// `authorization.check` runs with the transport's command mutex held, when every attempt
    /// starts and again once the stream is proven; the hand-off of the command's first bytes
    /// runs inside `authorization.whileAuthorized`. When either throws, nothing is written for
    /// that attempt, nothing is retried, and the error escapes unchanged.
    func sendCommand(_ command: String, retries: Int, authorization: OBDWriteAuthorization) async throws -> [String]
    /// The adapter connection this transport is on now. Its `epoch` is the transport-owned
    /// identity of that connection (see `OBDAdapterConnectionSnapshot`). Transports with
    /// nothing to lose report `.none`.
    var adapterConnection: OBDAdapterConnectionSnapshot { get }
    /// Whether the stream can't be proven in sync again on this connection: it is dirty and
    /// every resynchronization probe has an earlier send still unanswered. Commands fail unsent
    /// until a reconnect. See `OBDStreamError.reconnectRequired`.
    var requiresReconnect: Bool { get }
    /// A single-attempt command whose silence is not a channel failure (optional adapter
    /// identity queries). Transports that publish compatibility state must not mark the
    /// connection failed when it times out.
    func sendOptionalCommand(_ command: String) async throws -> [String]
    func disconnectPeripheral()
    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?) async throws
    func scanForPeripherals() async throws
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
    var obdDelegate: OBDServiceDelegate? { get set }
    /// Whether the transport's wire log is holding redaction (a manufacturer batch's late answer
    /// may still be on the stream). Upper layers render reply text only when this is false.
    var isWireRedactionHeld: Bool { get }

    // MARK: - Peripheral Scanning (BLE-specific, no-op for WiFi/Mock)
    func startPeripheralScanning()
    func stopPeripheralScanning()
    var discoveredPeripheralPublisher: AnyPublisher<CBPeripheral, Never> { get }
    var peripheralDiscoveryPublisher: AnyPublisher<BLEPeripheralDiscovery, Never> { get }

    // MARK: - Bluetooth State
    var bluetoothState: CBManagerState { get }

    // MARK: - Peripheral Retrieval
    func retrievePeripheral(uuid: UUID) -> CBPeripheral?

    // MARK: - Auto-Reconnect
    var autoReconnectEnabled: Bool { get set }
    var lastConnectedPeripheralUUID: UUID? { get set }

    /// Leave an OS-level pending connection to the saved adapter (BLE only).
    /// Returns true if a connection is now pending or already established.
    @discardableResult
    func armStandingReconnect() -> Bool

    // MARK: - Exclusive send + listen transaction (opt-in, DTC requests only)

    /// Sends one command and keeps listening — **never sending again** — while
    /// `shouldContinueListening` says the exchange has not concluded, holding the transport's
    /// command mutex for the whole exchange.
    ///
    /// Strictly additive and opt-in: only the DTC request layer calls it, so no other caller's
    /// behaviour changes. It exists because a `7F … 78` response-pending must not be
    /// retransmitted, yet every processor publishes a response as soon as the `>` prompt
    /// arrives — and because releasing the mutex between windows would let another command
    /// (telemetry polling) interleave into the middle of the exchange.
    ///
    /// - Parameters:
    ///   - command: The request, sent exactly once (retries aside).
    ///   - retries: Attempts for the *initial* send only, exactly as `sendCommand`.
    ///   - shouldContinueListening: Given every line accumulated so far, whether to open another
    ///     listen window. Called after each window; must be pure.
    ///   - listenDeadline: Total wall-clock budget for the extra windows. Windows stop once it
    ///     elapses, even if the exchange has not concluded.
    /// - Returns: Every line accumulated across the initial response and any extra windows.
    /// - Throws: The initial send's errors as usual. During the extra windows **only** terminal
    ///   interruptions escape — `CancellationError` and link loss — so an interruption can never
    ///   be mistaken for "the ECU went quiet". A window that merely times out ends the
    ///   transaction and returns what arrived, leaving the caller's `0x78` evidence intact.
    func sendCommandTransaction(
        _ command: String,
        retries: Int,
        shouldContinueListening: @escaping @Sendable ([String]) -> Bool,
        listenDeadline: TimeInterval
    ) async throws -> [String]

    /// `sendCommandTransaction` with a caller-chosen wait for the first answer (nil: the
    /// transport's default), for a module read that may take longer than an ordinary command.
    ///
    /// Either form leaves the stream marked dirty, under the command mutex, whenever it exits
    /// while `shouldContinueListening` still says a final answer is owed.
    func sendCommandTransaction(
        _ command: String,
        retries: Int,
        responseTimeout: TimeInterval?,
        shouldContinueListening: @escaping @Sendable ([String]) -> Bool,
        listenDeadline: TimeInterval
    ) async throws -> [String]

    // MARK: - Exclusive command channel (opt-in, manufacturer batches only)

    /// Runs `body` with the transport's command mutex held for its whole duration, handing it a
    /// channel that sends one command at a time without re-acquiring the mutex.
    ///
    /// A manufacturer batch re-addresses the adapter (header, filter, flow control), reads, and
    /// restores functional addressing. Any other command interleaved into that window could go to
    /// the wrong module, so the batch must own the channel from first setup command to last
    /// restore command. Transports that can't promise that throw
    /// `OEMTransportError.unsupportedTransport` (the default).
    ///
    /// `deadline` is absolute, in `ProcessInfo.processInfo.systemUptime` seconds. A transport
    /// that hasn't acquired its mutex by then throws `OEMTransportError.deadlineExpired` without
    /// running `body`.
    func withExclusiveCommandChannel<T>(
        deadline: TimeInterval,
        _ body: @escaping (OEMCommandChannel) async throws -> T
    ) async throws -> T
}

// Default no-op implementations for non-BLE managers
extension CommProtocol {
    func sendCommand(_ command: String, retries: Int, responseTimeout _: TimeInterval) async throws -> [String] {
        try await sendCommand(command, retries: retries)
    }

    func sendOptionalCommand(_ command: String) async throws -> [String] {
        try await sendCommand(command, retries: 1)
    }

    /// Default for transports with no physical write to serialize (the demo transport, test
    /// doubles): the check runs immediately before the send, which makes no retries of its own.
    func sendCommand(_ command: String, retries: Int, authorization: OBDWriteAuthorization) async throws -> [String] {
        try authorization.check()
        return try await sendCommand(command, retries: retries)
    }

    /// A bound send whose binding nothing else can revoke concurrently (see
    /// `OBDWriteAuthorization.init(check:)`).
    func sendCommand(_ command: String, retries: Int, beforeEachWrite: @escaping () throws -> Void) async throws -> [String] {
        try await sendCommand(command, retries: retries, authorization: OBDWriteAuthorization(check: beforeEachWrite))
    }

    var adapterConnection: OBDAdapterConnectionSnapshot { .none }

    var requiresReconnect: Bool { false }

    var isWireRedactionHeld: Bool { false }
    func startPeripheralScanning() {}
    func stopPeripheralScanning() {}
    var discoveredPeripheralPublisher: AnyPublisher<CBPeripheral, Never> {
        Empty<CBPeripheral, Never>().eraseToAnyPublisher()
    }
    var peripheralDiscoveryPublisher: AnyPublisher<BLEPeripheralDiscovery, Never> {
        Empty<BLEPeripheralDiscovery, Never>().eraseToAnyPublisher()
    }
    var bluetoothState: CBManagerState { .unknown }
    func retrievePeripheral(uuid: UUID) -> CBPeripheral? { nil }
    var autoReconnectEnabled: Bool {
        get { false }
        set { }
    }
    var lastConnectedPeripheralUUID: UUID? {
        get { nil }
        set { }
    }
    @discardableResult
    func armStandingReconnect() -> Bool { false }

    /// Default: this transport cannot listen again without sending, so the transaction is a plain
    /// single-shot send. The caller sees no extra lines and keeps its `0x78` as the recorded
    /// evidence — nothing is invented.
    func sendCommandTransaction(
        _ command: String,
        retries: Int,
        shouldContinueListening _: @escaping @Sendable ([String]) -> Bool,
        listenDeadline _: TimeInterval
    ) async throws -> [String] {
        try await sendCommand(command, retries: retries)
    }

    /// Default: the transport has no per-command response timeout to apply.
    func sendCommandTransaction(
        _ command: String,
        retries: Int,
        responseTimeout _: TimeInterval?,
        shouldContinueListening: @escaping @Sendable ([String]) -> Bool,
        listenDeadline: TimeInterval
    ) async throws -> [String] {
        try await sendCommandTransaction(
            command,
            retries: retries,
            shouldContinueListening: shouldContinueListening,
            listenDeadline: listenDeadline
        )
    }

    /// Default: fail closed. WiFi and the demo transport don't implement manufacturer batches.
    func withExclusiveCommandChannel<T>(
        deadline _: TimeInterval,
        _: @escaping (OEMCommandChannel) async throws -> T
    ) async throws -> T {
        throw OEMTransportError.unsupportedTransport
    }
}

enum CommunicationError: Error {
    case invalidData
    /// The adapter answered `NO DATA` — silence from the vehicle, not garbled bytes or a dead
    /// socket. Parity with `BLEManagerError.noData`, so a caller can tell the two apart.
    case noData
    /// No bytes arrived inside the read window. Distinct from garbled output, so a DTC request can
    /// classify it as the recoverable timeout it is.
    case timeout
    /// The socket itself is gone (cancelled, failed, or never opened). **Terminal** — a caller
    /// must treat it as link loss, never as a quiet vehicle.
    case connectionLost
    case errorOccurred(Error)
}

// MARK: - Socket seam

/// Why a socket read ended without bytes.
enum WifiSocketError: Error, Equatable {
    /// The socket broke, was cancelled, or was never opened. Terminal.
    case failed
}

/// The slice of a stream socket the WiFi transport needs.
///
/// `receive` is **callback-driven on purpose**. An `async` read would have to be abandoned when a
/// caller times out or is cancelled, leaving a live read on the socket that then eats the *next*
/// command's response — and, worse, a checked continuation that only ever resumes when the
/// Network callback fires, so a dead socket would hang past any nominal timeout. Instead the
/// transport runs one continuous receive pump over this callback and applies timeouts to the
/// *wait for a response*, never to a read.
///
/// `send` is a **synchronous submission** for the same kind of reason: the transport must be able
/// to start a write in one step with checks that may not go stale before the bytes leave (the
/// socket is still the current one, the deadline has not passed, a bound request's link still
/// holds). An `async` send would put a suspension point between those checks and the write.
///
/// `NWConnection` cannot be exercised from a unit test, so `NWConnectionSocket` adapts the real
/// thing and a fake stands in for the wire.
///
/// The transport calls `send` and `cancel` while holding its socket lock (`NSRecursiveLock`), and
/// a conformer may call back into the transport synchronously from inside them (a `send` that
/// resolves the armed read before returning, a `cancel` that fails it). Conformers must not block
/// in any of these methods.
protocol WifiSocket: AnyObject {
    /// Hands `data` to the socket. By the time this returns the bytes have been submitted to the
    /// socket (or it has already failed). `completion` is called exactly once, when the socket
    /// reports the write processed or failed; it may be called before `send` returns. Must not block.
    func send(_ data: Data, completion: @escaping (Result<Void, WifiSocketError>) -> Void)
    /// Arms exactly one read. `completion` is called once, with bytes or a terminal failure; the
    /// pump re-arms from inside it, so there is never more than one outstanding read.
    func receive(_ completion: @escaping (Result<Data, WifiSocketError>) -> Void)
    /// Tears the socket down; safe to call more than once.
    func cancel()
}

/// `NWConnection` behind the ``WifiSocket`` seam.
final class NWConnectionSocket: WifiSocket {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ data: Data, completion: @escaping (Result<Void, WifiSocketError>) -> Void) {
        // `connection.send` enqueues the bytes and returns; `contentProcessed` is documented to
        // fire once (promptly, with an error, on a dead or cancelled connection). The latch is
        // belt-and-braces for "exactly once".
        let once = ResumeGuard()
        connection.send(content: data, completion: .contentProcessed { error in
            guard once.claim() else { return }
            completion(error == nil ? .success(()) : .failure(.failed))
        })
    }

    func receive(_ completion: @escaping (Result<Data, WifiSocketError>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 500) { data, _, isComplete, error in
            if error != nil || (isComplete && (data?.isEmpty ?? true)) {
                completion(.failure(.failed))
                return
            }
            guard let data, !data.isEmpty else {
                // A zero-length read on a live connection is not an answer and not a failure —
                // the pump simply re-arms.
                completion(.success(Data()))
                return
            }
            completion(.success(data))
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// A write refused before anything was submitted to the socket. **Nothing was written**, so no
/// answer to it can arrive. Internal (not private) so `OBDStreamResynchronizer.mayHaveWritten`
/// can tell that a refused probe is still usable.
enum WifiWriteRefusal: Error {
    case cancelled
    /// The write's absolute deadline had passed at the moment of submission.
    case deadlinePassed
    /// The socket the write was meant for is no longer the transport's current socket.
    case socketNotCurrent
    /// The bound request's authorization refused (its binding no longer holds). Carries the
    /// binding's own error, which the transport rethrows unchanged.
    case notAuthorized(Error)

    /// What a command or probe caller of this transport sees, translated at the transport's own
    /// boundary. A passed deadline is an ordinary timeout (retryable); a replaced socket is link
    /// loss; a refused binding is the binding's error, unchanged.
    var transportError: Error {
        switch self {
        case .cancelled:
            return CancellationError()
        case .deadlinePassed:
            return OBDMessageProcessorError.responseTimeout
        case .socketNotCurrent:
            return CommunicationError.connectionLost
        case let .notAuthorized(error):
            return error
        }
    }
}

/// The wait for one submitted write: exactly one of the socket's completion and the deadline
/// timer resolves it. Lock-guarded (`lock` protects `resolved` and `timer`), hence `@unchecked
/// Sendable`: the completion runs on the socket's queue, the timer on the cooperative pool, and
/// the completion may even run synchronously inside `send`, before the timer exists.
private final class WriteWait: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var timer: Task<Void, Never>?

    /// Claims the right to resolve the wait. Only the first caller gets true; the timer, if any,
    /// is cancelled.
    func claim() -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        return true
    }

    /// Starts the deadline timer, unless the wait was already resolved (a completion that fired
    /// synchronously inside `send`), in which case no timer is ever created.
    func armTimer(seconds: TimeInterval, onExpiry: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        let nanoseconds = UInt64(Swift.min(Swift.max(0, seconds), 86_400) * 1_000_000_000)
        timer = Task.detached {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            onExpiry()
        }
    }
}

/// One-shot latch, so a continuation can never be resumed twice. Lock-guarded, hence `@unchecked
/// Sendable`: it is shared with Network's callback queue.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

class WifiManager: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "wifiManager")

    var obdDelegate: OBDServiceDelegate?

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    /// The open socket, or `nil` once disconnected — the terminal guard every send checks.
    ///
    /// Setting a socket installs it (`attach(socket:)`); setting nil drops whichever socket is
    /// current, without cancelling it, and publishes the disconnect.
    var socket: WifiSocket? {
        get { socketLock.withLock { currentSocket } }
        set {
            if let newValue {
                attach(socket: newValue)
            } else {
                retireCurrentSocket(cancel: false)
            }
        }
    }

    // MARK: Socket ownership
    //
    // `socketLock` protects pending and current socket ownership and the epoch. Each of these
    // is one step
    // with the "which socket is current" decision it depends on:
    //
    // - installing a socket: reset the response slot, swap the reference, advance the epoch,
    //   publish the connected state (when the install has one);
    // - retiring a socket (compare-and-clear): only if it is still the current one, drop the
    //   reference, advance the epoch, reset the response slot, publish "disconnected". A socket
    //   that is no longer current is not touched at all, and neither is any state;
    // - feeding the response slot: a socket's bytes are handed to the slot only while it is the
    //   current one, so a replaced socket's late bytes never reach its successor's stream;
    // - submitting a write: the socket send is started only while the socket is current and
    //   the write's deadline has not passed (see `submit`).
    //
    // The lock is recursive because sockets may call back synchronously: a fake `send` may
    // resolve the armed read before returning, which re-enters the pump on the same thread.
    //
    // Lock order: the binding owner's lock (a bound write's `whileAuthorized`, e.g.
    // `OBDVehicleLinkRecord`) → `socketLock` → the response slot's lock / a socket's internals.
    // Never the reverse: nothing here calls into a link record or an authorization while holding
    // `socketLock`, except that `submit` itself is entered from inside `whileAuthorized`.
    //
    // Publication happens inside `socketLock` on purpose: the order of "connected" and
    // "disconnected" publications is then the order of the installs and retirements that caused
    // them, so a stale "disconnected" for a replaced socket can never follow its successor's
    // "connected". Publishing after unlocking would let a retirement decided before an install
    // publish after it. This is safe because every observer hops asynchronously: `ELM327`
    // subscribes to `connectionStatePublisher` with `.receive(on: DispatchQueue.main)`, and
    // `OBDService.connectionStateChanged` (the `obdDelegate`) dispatches to the main queue, both
    // FIFO, so publication order is delivery order and no observer runs (or touches the link
    // record) while the lock is held. A synchronous observer must not block or call into the
    // link record.

    private let socketLock = NSRecursiveLock()
    /// Protected by `socketLock`.
    private var currentSocket: WifiSocket?
    /// Only this connection attempt can become current when Network reports ready.
    private var pendingSocket: WifiSocket?
    /// Advanced, under `socketLock`, every time the socket is replaced or dropped: the identity
    /// of this transport's connection (see `OBDAdapterConnectionSnapshot`).
    private var socketEpoch: UInt64 = 0

    var adapterConnection: OBDAdapterConnectionSnapshot {
        socketLock.withLock { OBDAdapterConnectionSnapshot(attempt: nil, peripheralID: nil, epoch: socketEpoch) }
    }

    /// The shared request/response slot — the same component the BLE transport uses, fed here by
    /// the receive pump. It owns the buffering, the `>` framing and the gap retention, so a
    /// caller that times out or is cancelled never leaves a read behind for the next command to
    /// trip over.
    private let messageProcessor: OBDMessageProcessor
    var isWireRedactionHeld: Bool { messageProcessor.wireLog.isRedactionHeld }

    /// `clock` is the monotonic clock every deadline on this transport is measured on (tests
    /// substitute a manual one).
    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        messageProcessor = OBDMessageProcessor(clock: clock)
    }

    /// Test seam: called with the bytes of every write right before it is submitted to the
    /// socket, outside every lock. Nil in production.
    var willSubmitWrite: ((Data) -> Void)?

    /// Serializes every command, exactly like BLE's. Without it a DTC transaction's listen windows
    /// could be interleaved by telemetry polling, which would consume the ECU's final message.
    private let commandSemaphore = AsyncSemaphore(value: 1)

    /// Whether an earlier command's answer may still arrive. See `OBDMessageProcessor`.
    var isStreamDirty: Bool { messageProcessor.isStreamDirty }

    /// How long a caller waits for a response before the attempt counts as timed out.
    var readTimeout: TimeInterval = 5.0
    /// How long the socket may take to report an ordinary command's write processed. Past it,
    /// whether the command went out is unknown and the socket is retired.
    var writeTimeout: TimeInterval = BLEConstants.defaultTimeout
    /// How long a single *extra* listen window inside a transaction waits.
    var listenWindowTimeout: TimeInterval = 3.0

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        let host = NWEndpoint.Host("192.168.0.10")
        guard let port = NWEndpoint.Port("35000") else {
            throw CommunicationError.invalidData
        }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        // Created up front, so every state change of this connection acts on exactly this
        // socket: a `.failed`/`.cancelled` of an older connection retires only its own socket.
        let socket = NWConnectionSocket(connection: connection)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let hasResumed = ResumeGuard()
            connection.stateUpdateHandler = { [weak self] newState in
                if case .cancelled = newState {
                    // The last state: break the connection → handler → socket → connection cycle.
                    connection.stateUpdateHandler = nil
                }
                guard let self = self else { return }
                if let outcome = self.connectionStateDidChange(newState, socket: socket), hasResumed.claim() {
                    continuation.resume(with: outcome)
                }
            }
            beginConnectionAttempt(socket: socket) {
                connection.start(queue: .main)
            }
        }
    }

    /// Register the attempt before starting it so even its first callback has an owner.
    func beginConnectionAttempt(socket: WifiSocket, start: () -> Void = {}) {
        let superseded = socketLock.withLock {
            let superseded = pendingSocket
            pendingSocket = socket
            start()
            return superseded
        }
        if superseded !== socket { superseded?.cancel() }
    }

    /// What one connection's state change does to the transport, acting only on that
    /// connection's own `socket`. Returns the outcome for its `connectAsync` caller, or nil while
    /// it is still pending.
    ///
    /// Only the current attempt can install on ready. Only the installed socket can
    /// publish a disconnect.
    func connectionStateDidChange(_ newState: NWConnection.State, socket: WifiSocket) -> Result<Void, Error>? {
        switch newState {
        case .ready:
            let installation = socketLock.withLock { () -> (displaced: WifiSocket?, installed: Bool) in
                guard pendingSocket === socket else { return (nil, false) }
                pendingSocket = nil
                return (installLocked(socket, publishing: .connectedToAdapter), true)
            }
            guard installation.installed else { return .failure(CommunicationError.connectionLost) }
            installation.displaced?.cancel()
            logger.info("WiFi adapter connection ready")
            armReceive(on: socket)
            return .success(())
        case let .waiting(error):
            logger.warning("Connection waiting: \(error.localizedDescription)")
            return nil
        case let .failed(error):
            logger.error("Connection failed: \(error.localizedDescription)")
            retire(socket, cancel: false)
            // A failed connection must still be cancelled to release it. That touches only this
            // connection, whether or not it was ever current.
            socket.cancel()
            return .failure(CommunicationError.errorOccurred(error))
        case .cancelled:
            logger.info("Connection cancelled")
            retire(socket, cancel: false)
            // Resolves a `connectAsync` cancelled before it became ready (ignored otherwise).
            return .failure(CommunicationError.connectionLost)
        default:
            return nil
        }
    }

    // MARK: - Receive pump

    /// Takes ownership of a socket and starts the single, long-lived receive loop over it.
    func attach(socket: WifiSocket) {
        let (pending, displaced) = socketLock.withLock {
            let pending = pendingSocket
            pendingSocket = nil
            return (pending, installLocked(socket, publishing: nil))
        }
        if pending !== socket, pending !== displaced { pending?.cancel() }
        displaced?.cancel()
        armReceive(on: socket)
    }

    /// Must be called under `socketLock`, after claiming the current attempt.
    private func installLocked(_ socket: WifiSocket, publishing state: ConnectionState?) -> WifiSocket? {
        let displaced = currentSocket
        messageProcessor.reset()
        if displaced !== socket { socketEpoch &+= 1 }
        currentSocket = socket
        if let state, connectionState != state { connectionState = state }
        return displaced === socket ? nil : displaced
    }

    /// Arms exactly one read; the completion hands the bytes to the processor and re-arms.
    ///
    /// Nothing else on this transport ever reads the socket, so there is no caller-owned read to
    /// abandon: a timed-out or cancelled caller simply stops waiting, while late bytes still land
    /// in the processor's buffer under its gap-retention rules.
    private func armReceive(on socket: WifiSocket) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket else { return }
            switch result {
            case let .success(data):
                // The "is this socket current" check and the hand-off to the slot are one step:
                // a socket replaced in between would otherwise feed its successor's stream.
                let stillCurrent: Bool = self.socketLock.withLock {
                    guard self.currentSocket === socket else { return false }
                    if !data.isEmpty { self.messageProcessor.processReceivedData(data) }
                    return true
                }
                // Re-armed outside the lock: a read on a socket retired meanwhile is harmless,
                // its bytes fail the check above.
                if stillCurrent { self.armReceive(on: socket) }
            case .failure:
                // Fail the pending slot terminally *and* drop the socket, so the caller maps this
                // to link loss instead of waiting out a timeout on a dead connection. Only if this
                // socket is still the current one.
                if self.retire(socket, cancel: false) {
                    self.logger.error("WiFi receive pump failed — tore the socket down")
                }
            }
        }
    }

    private func isCurrent(_ socket: WifiSocket) -> Bool {
        socketLock.withLock { currentSocket === socket }
    }

    // MARK: - Sending

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        let acquired = await commandSemaphore.wait()
        guard acquired else { throw CancellationError() }
        defer { commandSemaphore.signal() }
        return try await sendCommandLocked(command, retries: retries)
    }

    func sendCommand(_ command: String, retries: Int, authorization: OBDWriteAuthorization) async throws -> [String] {
        let acquired = await commandSemaphore.wait()
        guard acquired else { throw CancellationError() }
        defer { commandSemaphore.signal() }
        return try await sendCommandLocked(command, retries: retries, authorization: authorization)
    }

    /// Send once, then keep waiting for further responses with no additional writes while the
    /// exchange is unresolved — all of it under a single hold of the command mutex.
    ///
    /// The pump keeps reading either way; a window is just another wait on the request slot. A
    /// window that times out ends the transaction with whatever arrived, while a broken socket or
    /// a cancellation is terminal and thrown, so the caller can never publish a result resting on
    /// stale interim evidence.
    func sendCommandTransaction(
        _ command: String,
        retries: Int,
        shouldContinueListening: @escaping @Sendable ([String]) -> Bool,
        listenDeadline: TimeInterval
    ) async throws -> [String] {
        try await sendCommandTransaction(
            command,
            retries: retries,
            responseTimeout: nil,
            shouldContinueListening: shouldContinueListening,
            listenDeadline: listenDeadline
        )
    }

    /// See `CommProtocol`. This transport has no per-command response timeout (`readTimeout`
    /// applies), so `responseTimeout` is not used.
    func sendCommandTransaction(
        _ command: String,
        retries: Int,
        responseTimeout _: TimeInterval?,
        shouldContinueListening: @escaping @Sendable ([String]) -> Bool,
        listenDeadline: TimeInterval
    ) async throws -> [String] {
        let acquired = await commandSemaphore.wait()
        guard acquired else { throw CancellationError() }
        defer { commandSemaphore.signal() }

        var accumulated = try await sendCommandLocked(command, retries: retries)
        // Every exit from here (a return, `NO DATA`, cancellation, the budget, a window timeout,
        // a dirty-stream window, link loss) that still owes the final answer leaves the stream
        // dirty, still under the mutex: that answer may arrive later and must not be credited
        // to the next command. After link loss this is harmless (a new socket resets).
        defer {
            if shouldContinueListening(accumulated) { messageProcessor.markStreamDirty() }
        }
        let clock = messageProcessor.clock
        let started = clock()

        listening: while shouldContinueListening(accumulated) {
            try Task.checkCancellation()
            let remaining = listenDeadline - (clock() - started)
            guard remaining > 0 else {
                logger.info("Extra listen budget exhausted for \(command)")
                break
            }
            guard socket != nil else { throw CommunicationError.connectionLost }

            do {
                // Throws on a dirty stream: a window there would be handed some earlier
                // command's late answer. Ends the transaction like a quiet window.
                let token = try messageProcessor.beginContinuationRequest()
                let lines = try await messageProcessor.awaitResponse(
                    for: token,
                    timeout: min(remaining, listenWindowTimeout)
                )
                accumulated.append(contentsOf: lines)
            } catch is CancellationError {
                throw CancellationError()
            } catch OBDStreamError.ecuResponsePending {
                throw CommunicationError.timeout
            } catch let error as OBDMessageProcessorError where error == .responseTimeout {
                logger.info("No further response in the extra listen window")
                break listening
            } catch OBDStreamError.unsynchronized {
                logger.info("Extra listen window skipped: the stream is not in sync")
                break listening
            } catch {
                // `noData` in a window means nothing more came; anything else is the slot dying
                // with the link.
                if case BLEManagerError.noData = error { break listening }
                throw translate(error)
            }
        }
        return accumulated
    }

    /// The write-and-await body of `sendCommand`, with the command mutex **already held**.
    ///
    /// Split out so a transaction can send and then keep waiting under a single acquisition;
    /// `AsyncSemaphore` is not reentrant, so a transaction must never call `sendCommand` itself.
    private func sendCommandLocked(
        _ command: String,
        retries: Int,
        authorization: OBDWriteAuthorization? = nil
    ) async throws -> [String] {
        // The shared encoder, before anything is armed: a blank command would write a bare CR,
        // which an ELM327 answers by repeating its previous command, and an embedded CR/LF would
        // write two commands.
        let data: Data
        do {
            data = try BLECommandEncoder.encode(command: command, terminator: Self.commandTerminator)
        } catch {
            throw CommunicationError.invalidData
        }
        logger.info("Sending: \(command)")

        var sawNoData = false
        var sawTimeout = false
        let attempts = max(1, retries)
        for attempt in 1 ... attempts {
            try Task.checkCancellation()
            guard let socket else { throw CommunicationError.connectionLost }
            try authorization?.check()

            do {
                // Arming *before* the write is what makes a response that arrives instantly still
                // land in this request's slot. It only arms on a stream proven in sync: after an
                // attempt that got no prompt, nothing but a probe is written until a probe's own
                // answer arrives (see `OBDMessageProcessor`).
                let token = try await armOnCleanStream(command, socket: socket)
                // A cheap pre-check once the stream is proven: the proof may have taken a while,
                // and the socket or the request's binding may have changed meanwhile. It is not
                // what makes the write safe; `write` re-decides both atomically with the start of
                // the send. Nothing was written for this slot, so giving it up leaves the stream
                // as it was.
                do {
                    guard isCurrent(socket) else { throw CommunicationError.connectionLost }
                    try authorization?.check()
                } catch {
                    messageProcessor.releaseUnwrittenRequest(token)
                    throw error
                }
                do {
                    try await write(
                        data, to: socket, deadline: messageProcessor.clock() + writeTimeout, authorization: authorization
                    )
                } catch let refusal as WifiWriteRefusal {
                    // Refused before submission: nothing was written, so the slot is released
                    // unwritten and the stream is left exactly as it was. A refused binding's
                    // error escapes unchanged and unretried, a replaced socket is link loss, and
                    // a passed deadline is an ordinary (retryable) timeout.
                    messageProcessor.releaseUnwrittenRequest(token)
                    throw refusal
                } catch {
                    // Some of the command may be on the wire.
                    messageProcessor.abandonRequest(token)
                    throw error
                }
                return try await messageProcessor.awaitResponse(for: token, timeout: readTimeout)
            } catch WifiWriteRefusal.deadlinePassed {
                sawTimeout = true
            } catch let refusal as WifiWriteRefusal {
                throw refusal.transportError
            } catch is CancellationError {
                throw CancellationError()
            } catch OBDStreamError.ecuResponsePending {
                throw CommunicationError.timeout
            } catch let error as OBDMessageProcessorError where error == .responseTimeout {
                sawTimeout = true
            } catch let error as BLEManagerError {
                switch error {
                case .noData:
                    sawNoData = true
                default:
                    throw translate(error)
                }
            } catch is WifiSocketError {
                // A failed write means a dead socket: no amount of retrying fixes that. Only this
                // socket is retired; one installed meanwhile is left alone.
                retire(socket, cancel: false)
                throw CommunicationError.connectionLost
            } catch {
                // Anything else — a stale slot after the pump tore the socket down, say — is
                // translated too: only `CommunicationError` may escape this transport.
                throw translate(error)
            }

            if attempt < attempts {
                logger.info("No usable response, retrying attempt \(attempt + 1) of \(attempts)...")
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        // `NO DATA` is the vehicle answering with nothing, a timeout is nothing arriving at all,
        // and anything else that got here is unusable output. The DTC layer maps all three
        // differently, so they must stay distinct.
        if sawNoData { throw CommunicationError.noData }
        throw sawTimeout ? CommunicationError.timeout : CommunicationError.invalidData
    }

    /// How long the proof of a dirty stream may take. See `OBDStreamResynchronizer`.
    var resynchronization = OBDStreamResynchronizer.Timing()

    /// Arms the response slot for `command`, resynchronizing first when the stream is dirty.
    /// Throws a timeout, with nothing written but probes, when the stream can't be proven. When
    /// no probe can prove it on this socket, the socket is retired and `connectionLost` thrown:
    /// on WiFi a new stream means a new connection.
    private func armOnCleanStream(_ command: String, socket: WifiSocket) async throws -> RequestToken {
        do {
            return try await messageProcessor.beginRequestWaitingForECU(command: command)
        } catch OBDStreamError.unsynchronized {
            // Fall through to the proof.
        }
        // Encoded before anything is armed, like every command.
        var encodedProbes: [String: Data] = [:]
        for probe in OEMAdapterCommand.syncProbes {
            do {
                encodedProbes[probe.command] = try BLECommandEncoder.encode(
                    command: probe.command, terminator: Self.commandTerminator
                )
            } catch {
                throw CommunicationError.invalidData
            }
        }
        let resynchronizer = OBDStreamResynchronizer(processor: messageProcessor, timing: resynchronization)
        let outcome: OBDStreamResynchronizer.Outcome
        do {
            outcome = try await resynchronizer.resynchronize(
                deadline: messageProcessor.clock() + resynchronization.worstCase
            ) { probe, writeDeadline in
                guard let data = encodedProbes[probe] else { throw CommunicationError.invalidData }
                // A refusal reaches the resynchronizer typed: it wrote nothing, so the probe is
                // not counted as unanswered and stays usable (`mayHaveWritten`).
                try await self.write(data, to: socket, deadline: writeDeadline)
            }
        } catch let refusal as WifiWriteRefusal {
            // Translated only here, after the resynchronizer has rethrown it.
            throw refusal.transportError
        }
        switch outcome {
        case .synchronized:
            break
        case .unproven:
            throw OBDMessageProcessorError.responseTimeout
        case .reconnectRequired:
            retire(socket, cancel: true)
            throw CommunicationError.connectionLost
        }
        do {
            return try await messageProcessor.beginRequestWaitingForECU(command: command)
        } catch OBDStreamError.unsynchronized {
            // Bytes arrived between the proof and the arm: still not this command's stream.
            throw OBDMessageProcessorError.responseTimeout
        }
    }

    /// Maps the processor's transport-neutral signals onto this transport's error contract.
    private func translate(_ error: Error) -> Error {
        if let error = error as? BLEManagerError {
            switch error {
            case .noData:
                return CommunicationError.noData
            case .peripheralNotConnected, .sendingMessagesInProgress:
                return CommunicationError.connectionLost
            default:
                return CommunicationError.errorOccurred(error)
            }
        }
        if let error = error as? OBDMessageProcessorError {
            switch error {
            case .responseTimeout:
                return CommunicationError.timeout
            case .staleRequestToken:
                return CommunicationError.connectionLost
            default:
                return CommunicationError.errorOccurred(error)
            }
        }
        return error
    }

    /// What an ELM327 reads as the end of a command.
    private static let commandTerminator = "\r"

    /// Writes `data` to `socket`, bounded by `deadline` (absolute, on the processor's clock).
    ///
    /// The send is started by `submit`, synchronously, in one step under `socketLock` that also
    /// confirms `socket` is still the current one and `deadline` has not passed. For a bound
    /// request that step runs inside `authorization.whileAuthorized`, so the binding is decided
    /// atomically with it too: there is no suspension point or task hop between those checks and
    /// the start of the send.
    ///
    /// - Throws: `WifiWriteRefusal` with **nothing written** when the write is refused before
    ///   submission (deadline passed, socket replaced, binding refused).
    ///   `CommunicationError.connectionLost` when the deadline passes before the socket reports
    ///   the write processed: whether the bytes went out is unknown, so the socket is retired
    ///   (cancelling it also completes the pending send). `WifiSocketError` when the socket
    ///   reports the write failed.
    private func write(
        _ data: Data,
        to socket: WifiSocket,
        deadline: TimeInterval,
        authorization: OBDWriteAuthorization? = nil
    ) async throws {
        willSubmitWrite?(data)
        let clock = messageProcessor.clock

        // Exactly one of the socket's completion and the timer resumes the continuation; the
        // other finds the wait claimed and does nothing. The completion may fire synchronously
        // inside `send`, before the timer exists: then no timer is ever created.
        let processedInTime: Bool = try await withCheckedThrowingContinuation { continuation in
            let wait = WriteWait()
            let completion: (Result<Void, WifiSocketError>) -> Void = { result in
                guard wait.claim() else { return }
                switch result {
                case .success:
                    // Processed, but after the instant: not a success.
                    continuation.resume(returning: clock() <= deadline)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }

            var submitted = false
            var refusal: WifiWriteRefusal?
            do {
                if let authorization {
                    try authorization.whileAuthorized {
                        try self.submit(data, to: socket, deadline: deadline, completion: completion)
                        submitted = true
                    }
                } else {
                    try submit(data, to: socket, deadline: deadline, completion: completion)
                    submitted = true
                }
            } catch let error as WifiWriteRefusal {
                refusal = error
            } catch {
                if submitted {
                    // `whileAuthorized` must rethrow only what `submit` throws. If it throws
                    // after the bytes were handed over anyway, the write stands: wait for it.
                    logger.error("Write authorization threw after the write was submitted; the write stands")
                } else {
                    refusal = .notAuthorized(error)
                }
            }
            if let refusal {
                // Nothing was submitted, so the completion will never be called.
                if wait.claim() { continuation.resume(throwing: refusal) }
                return
            }
            wait.armTimer(seconds: deadline - clock()) {
                if wait.claim() { continuation.resume(returning: false) }
            }
        }
        guard processedInTime else {
            retire(socket, cancel: true)
            throw CommunicationError.connectionLost
        }
    }

    /// The submission step: starts the socket send of `data` if, and only if, `socket` is still
    /// the current socket and `deadline` has not passed, all in one step under `socketLock`.
    /// Throws a `WifiWriteRefusal`, with nothing written, otherwise.
    ///
    /// For a bound request this runs inside `whileAuthorized`, under the binding owner's lock
    /// (lock order: binding owner → `socketLock` → the socket's internals and the response slot,
    /// which a fake socket may reach by resolving the armed read from inside `send`). Holding
    /// `socketLock` across `send` is what makes "still current" true when the send starts: a
    /// retirement of this socket waits until the send has been handed over.
    private func submit(
        _ data: Data,
        to socket: WifiSocket,
        deadline: TimeInterval,
        completion: @escaping (Result<Void, WifiSocketError>) -> Void
    ) throws {
        try socketLock.withLock {
            if Task.isCancelled { throw WifiWriteRefusal.cancelled }
            guard currentSocket === socket else { throw WifiWriteRefusal.socketNotCurrent }
            guard messageProcessor.clock() < deadline else { throw WifiWriteRefusal.deadlinePassed }
            socket.send(data, completion: completion)
        }
    }

    /// Retires `socket` if, and only if, it is still the current one. Decided and done in one
    /// step under `socketLock` (compare-and-clear): drops the reference, advances the epoch,
    /// resets the response slot and publishes the disconnect. Then, outside the lock, cancels it
    /// when `cancel` is set (a stream that can't be trusted any more: a write of unknown outcome,
    /// or no probe left that could prove it). A socket that is no longer current is not touched,
    /// and neither is any state.
    ///
    /// Clearing before cancelling matters: a `cancel()` that installs a new socket (a fake may)
    /// installs it after this socket was dropped, so nothing here can clear it.
    ///
    /// - Returns: Whether `socket` was the current one.
    @discardableResult
    private func retire(_ socket: WifiSocket, cancel: Bool) -> Bool {
        let wasCurrent: Bool = socketLock.withLock {
            if pendingSocket === socket { pendingSocket = nil }
            guard currentSocket === socket else { return false }
            dropCurrentSocketLocked()
            return true
        }
        if wasCurrent, cancel { socket.cancel() }
        return wasCurrent
    }

    /// Clears the pending attempt and current socket together. Pending attempts are cancelled
    /// so their callers can finish. The current socket is cancelled when `cancel` is set.
    private func retireCurrentSocket(cancel: Bool) {
        let (current, pending) = socketLock.withLock {
            let current = currentSocket
            let pending = pendingSocket
            pendingSocket = nil
            if current != nil {
                dropCurrentSocketLocked()
            } else {
                publishDisconnectedLocked()
            }
            return (current, pending)
        }
        pending?.cancel()
        if cancel { current?.cancel() }
    }

    /// Drops the current socket. **Must** be called with `socketLock` held, after deciding that
    /// the socket being retired is the current one.
    private func dropCurrentSocketLocked() {
        currentSocket = nil
        socketEpoch &+= 1
        // Fails the pending slot terminally, so its caller maps this to link loss.
        messageProcessor.reset()
        publishDisconnectedLocked()
    }

    /// Publishes "disconnected" (the published state and the delegate callback) unless it already
    /// is. **Must** be called with `socketLock` held; see "Socket ownership" for why.
    private func publishDisconnectedLocked() {
        guard connectionState != .disconnected else { return }
        connectionState = .disconnected
        obdDelegate?.connectionStateChanged(state: .disconnected)
    }

    /// Retires the current socket: taken atomically, then cancelled. Cancelling `NWConnection`
    /// alone used to leave the reference in place, so the `socket == nil` terminal guard never
    /// fired after a disconnect and the state stayed stale.
    func disconnectPeripheral() {
        retireCurrentSocket(cancel: true)
    }

    func scanForPeripherals() async throws {}
}
