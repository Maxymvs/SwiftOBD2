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
    func disconnectPeripheral()
    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?) async throws
    func scanForPeripherals() async throws
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
    var obdDelegate: OBDServiceDelegate? { get set }

    // MARK: - Peripheral Scanning (BLE-specific, no-op for WiFi/Mock)
    func startPeripheralScanning()
    func stopPeripheralScanning()
    var discoveredPeripheralPublisher: AnyPublisher<CBPeripheral, Never> { get }

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
}

// Default no-op implementations for non-BLE managers
extension CommProtocol {
    func startPeripheralScanning() {}
    func stopPeripheralScanning() {}
    var discoveredPeripheralPublisher: AnyPublisher<CBPeripheral, Never> {
        Empty<CBPeripheral, Never>().eraseToAnyPublisher()
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
/// `NWConnection` cannot be exercised from a unit test, so `NWConnectionSocket` adapts the real
/// thing and a fake stands in for the wire.
protocol WifiSocket: AnyObject {
    /// Writes the request. Throws ``WifiSocketError/failed`` when the socket is broken.
    func send(_ data: Data) async throws
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

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // `contentProcessed` is documented to fire once, and it fires promptly on a dead
            // socket — the guard is belt-and-braces against a double resume trapping the process.
            let hasResumed = ResumeGuard()
            connection.send(content: data, completion: .contentProcessed { error in
                guard hasResumed.claim() else { return }
                if error != nil {
                    continuation.resume(throwing: WifiSocketError.failed)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
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
    var socket: WifiSocket? {
        get { socketLock.lock(); defer { socketLock.unlock() }; return currentSocket }
        set { socketLock.lock(); currentSocket = newValue; socketLock.unlock() }
    }

    private let socketLock = NSLock()
    private var currentSocket: WifiSocket?

    /// The shared request/response slot — the same component the BLE transport uses, fed here by
    /// the receive pump. It owns the buffering, the `>` framing and the gap retention, so a
    /// caller that times out or is cancelled never leaves a read behind for the next command to
    /// trip over.
    private let messageProcessor = OBDMessageProcessor()

    /// Serializes every command, exactly like BLE's. Without it a DTC transaction's listen windows
    /// could be interleaved by telemetry polling, which would consume the ECU's final message.
    private let commandSemaphore = AsyncSemaphore(value: 1)

    /// How long a caller waits for a response before the attempt counts as timed out.
    var readTimeout: TimeInterval = 5.0
    /// How long a single *extra* listen window inside a transaction waits.
    var listenWindowTimeout: TimeInterval = 3.0

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        let host = NWEndpoint.Host("192.168.0.10")
        guard let port = NWEndpoint.Port("35000") else {
            throw CommunicationError.invalidData
        }
        let connection = NWConnection(host: host, port: port, using: .tcp)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let hasResumed = ResumeGuard()
            connection.stateUpdateHandler = { [weak self] newState in
                guard let self = self else { return }
                switch newState {
                case .ready:
                    self.logger.info("Connected to \(host.debugDescription):\(port.debugDescription)")
                    self.connectionState = .connectedToAdapter
                    self.attach(socket: NWConnectionSocket(connection: connection))
                    if hasResumed.claim() { continuation.resume(returning: ()) }
                case let .waiting(error):
                    self.logger.warning("Connection waiting: \(error.localizedDescription)")
                case let .failed(error):
                    self.logger.error("Connection failed: \(error.localizedDescription)")
                    self.clearSocket()
                    if hasResumed.claim() { continuation.resume(throwing: CommunicationError.errorOccurred(error)) }
                case .cancelled:
                    self.logger.info("Connection cancelled")
                    self.clearSocket()
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    // MARK: - Receive pump

    /// Takes ownership of a socket and starts the single, long-lived receive loop over it.
    func attach(socket: WifiSocket) {
        messageProcessor.reset()
        self.socket = socket
        armReceive(on: socket)
    }

    /// Arms exactly one read; the completion hands the bytes to the processor and re-arms.
    ///
    /// Nothing else on this transport ever reads the socket, so there is no caller-owned read to
    /// abandon: a timed-out or cancelled caller simply stops waiting, while late bytes still land
    /// in the processor's buffer under its gap-retention rules.
    private func armReceive(on socket: WifiSocket) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket, self.isCurrent(socket) else { return }
            switch result {
            case let .success(data):
                if !data.isEmpty {
                    self.messageProcessor.processReceivedData(data)
                }
                self.armReceive(on: socket)
            case .failure:
                self.logger.error("WiFi receive pump failed — tearing the socket down")
                // Fail the pending slot terminally *and* drop the socket, so the caller maps this
                // to link loss instead of waiting out a timeout on a dead connection.
                self.messageProcessor.reset()
                self.clearSocket()
            }
        }
    }

    private func isCurrent(_ socket: WifiSocket) -> Bool {
        socketLock.lock()
        defer { socketLock.unlock() }
        return currentSocket === socket
    }

    // MARK: - Sending

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        let acquired = await commandSemaphore.wait()
        guard acquired else { throw CancellationError() }
        defer { commandSemaphore.signal() }
        return try await sendCommandLocked(command, retries: retries)
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
        let acquired = await commandSemaphore.wait()
        guard acquired else { throw CancellationError() }
        defer { commandSemaphore.signal() }

        var accumulated = try await sendCommandLocked(command, retries: retries)
        let started = Date()

        listening: while shouldContinueListening(accumulated) {
            try Task.checkCancellation()
            let remaining = listenDeadline - Date().timeIntervalSince(started)
            guard remaining > 0 else {
                logger.info("Extra listen budget exhausted for \(command)")
                break
            }
            guard socket != nil else { throw CommunicationError.connectionLost }

            let token = messageProcessor.beginContinuationRequest()
            do {
                let lines = try await messageProcessor.awaitResponse(
                    for: token,
                    timeout: min(remaining, listenWindowTimeout)
                )
                accumulated.append(contentsOf: lines)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as OBDMessageProcessorError where error == .responseTimeout {
                logger.info("No further response in the extra listen window")
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
    private func sendCommandLocked(_ command: String, retries: Int) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }
        logger.info("Sending: \(command)")

        var sawNoData = false
        var sawTimeout = false
        let attempts = max(1, retries)
        for attempt in 1 ... attempts {
            try Task.checkCancellation()
            guard let socket else { throw CommunicationError.connectionLost }

            do {
                // Arming *before* the write is what makes a response that arrives instantly still
                // land in this request's slot; it also clears anything left over from before.
                let token = messageProcessor.beginRequest()
                try await socket.send(data)
                return try await messageProcessor.awaitResponse(for: token, timeout: readTimeout)
            } catch is CancellationError {
                throw CancellationError()
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
                // A failed write means a dead socket: no amount of retrying fixes that.
                socketFailed()
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

    private func socketFailed() {
        messageProcessor.reset()
        clearSocket()
    }

    func disconnectPeripheral() {
        socket?.cancel()
        clearSocket()
    }

    /// Drops the socket reference, stops the pump from re-arming, and publishes the disconnect.
    ///
    /// Cancelling `NWConnection` alone used to leave the reference in place, so the `socket == nil`
    /// terminal guard never fired after a disconnect and the state stayed stale.
    private func clearSocket() {
        socketLock.lock()
        let had = currentSocket != nil
        currentSocket = nil
        socketLock.unlock()

        if had { messageProcessor.reset() }
        guard connectionState != .disconnected else { return }
        connectionState = .disconnected
        obdDelegate?.connectionStateChanged(state: .disconnected)
    }

    func scanForPeripherals() async throws {}
}
