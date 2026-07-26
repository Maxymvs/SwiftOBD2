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
}

enum CommunicationError: Error {
    case invalidData
    /// The adapter answered `NO DATA` — silence from the vehicle, not garbled bytes or a dead
    /// socket. Parity with `BLEManagerError.noData`, so a caller can tell the two apart.
    case noData
    case errorOccurred(Error)
}

class WifiManager: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "wifiManager")

    var obdDelegate: OBDServiceDelegate?

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    var tcp: NWConnection?

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        let host = NWEndpoint.Host("192.168.0.10")
        guard let port = NWEndpoint.Port("35000") else {
            throw CommunicationError.invalidData
        }
        tcp = NWConnection(host: host, port: port, using: .tcp)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tcp?.stateUpdateHandler = { [weak self] newState in
                guard let self = self else { return }
                switch newState {
                case .ready:
                    self.logger.info("Connected to \(host.debugDescription):\(port.debugDescription)")
                    self.connectionState = .connectedToAdapter
                    continuation.resume(returning: ())
                case let .waiting(error):
                    self.logger.warning("Connection waiting: \(error.localizedDescription)")
                case let .failed(error):
                    self.logger.error("Connection failed: \(error.localizedDescription)")
                    self.connectionState = .disconnected
                    continuation.resume(throwing: CommunicationError.errorOccurred(error))
                default:
                    break
                }
            }
            tcp?.start(queue: .main)
        }
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }
        logger.info("Sending: \(command)")
        return try await sendCommandInternal(data: data, retries: retries)
    }

    private func sendCommandInternal(data: Data, retries: Int) async throws -> [String] {
        var sawNoData = false
        for attempt in 1 ... retries {
            do {
                let response = try await sendAndReceiveData(data)
                switch processResponse(response) {
                case let .lines(lines):
                    return lines
                case .noData:
                    sawNoData = true
                case .empty:
                    break
                }
                if attempt < retries {
                    logger.info("No data received, retrying attempt \(attempt + 1) of \(retries)...")
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.5 seconds delay
                }
            } catch {
                if attempt == retries {
                    throw error
                }
                logger.warning("Attempt \(attempt) failed, retrying: \(error.localizedDescription)")
            }
        }
        // A `NO DATA` line is the vehicle answering with nothing; anything else that got here is
        // unusable output. Keeping them distinct lets the DTC layer avoid calling garbage silence.
        throw sawNoData ? CommunicationError.noData : CommunicationError.invalidData
    }

    private func sendAndReceiveData(_ data: Data) async throws -> String {
        guard let tcpConnection = tcp else {
             throw CommunicationError.invalidData
         }
        let logger = self.logger // Avoid capturing `self` directly

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            tcpConnection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    logger.error("Error sending data: \(error.localizedDescription)")
                    continuation.resume(throwing: CommunicationError.errorOccurred(error))
                    return
                }

                tcpConnection.receive(minimumIncompleteLength: 1, maximumLength: 500) { data, _, _, error in
                    if let error = error {
                        logger.error("Error receiving data: \(error.localizedDescription)")
                        continuation.resume(throwing: CommunicationError.errorOccurred(error))
                        return
                    }

                    guard let response = data, let responseString = String(data: response, encoding: .utf8) else {
                        logger.warning("Received invalid or empty data")
                        continuation.resume(throwing: CommunicationError.invalidData)
                        return
                    }

                    continuation.resume(returning: responseString)
                }
            })
        }
    }

    /// What one buffered read amounted to. `noData` and `empty` were both `nil` before; they are
    /// separated so the thrown error can say which happened.
    private enum ProcessedResponse {
        case lines([String])
        case noData
        case empty
    }

    private func processResponse(_ response: String) -> ProcessedResponse {
        logger.info("Processing response: \(response)")
        var lines = response.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !lines.isEmpty else {
            logger.warning("Empty response lines")
            return .empty
        }

        if lines.last?.contains(">") == true {
            lines.removeLast()
        }

        if lines.first?.lowercased() == "no data" {
            return .noData
        }

        return .lines(lines)
    }

    func disconnectPeripheral() {
        tcp?.cancel()
    }

    func scanForPeripherals() async throws {}
}
