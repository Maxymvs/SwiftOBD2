import Foundation
import OSLog
import CoreBluetooth
import Combine

protocol BLEPeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: BLEPeripheralManager, didSetupCharacteristics peripheral: CBPeripheral)
}

class BLEPeripheralManager: NSObject, ObservableObject {
    func didWriteValue(_ peripheral: CBPeripheral, descriptor: CBDescriptor, error: (any Error)?) {

    }

    @Published var connectedPeripheral: CBPeripheral?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "BLEPeripheralManager")
    private let characteristicHandler: BLECharacteristicHandler

    weak var delegate: BLEPeripheralManagerDelegate?
    private var connectionCompletion: ((CBPeripheral?, Error?) -> Void)?
    private var hasResumedConnection = false

    /// Connection generation counter to invalidate stale callbacks from previous connections
    private var connectionGeneration: Int = 0

    /// Guards the single-resume bookkeeping (`connectionCompletion`,
    /// `hasResumedConnection`, `connectionGeneration`) so the setup continuation
    /// is resumed exactly once, even though the characteristics callback, the
    /// timeout, and cancellation can arrive on different threads.
    private let resumeLock = NSLock()

    /// Holds the per-wait timeout task so a normal completion can cancel it.
    private final class TimeoutTaskBox: @unchecked Sendable {
        var value: Task<Void, Never>?
    }

    init(characteristicHandler: BLECharacteristicHandler) {
        self.characteristicHandler = characteristicHandler
        super.init()
    }

    /// Reset all state for clean reconnection - resumes any pending continuation.
    func reset() {
        // Clear delegate before clearing peripheral reference.
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil

        // Resume any pending setup wait through the single, lock-guarded sink so
        // its continuation can't leak. No-op if nothing is waiting.
        fireConnectionCompletion(peripheral: nil, error: BLEManagerError.peripheralNotConnected)
    }

    func setPeripheral(_ peripheral: CBPeripheral?, discoverServices: Bool = true) {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self

        if discoverServices, let peripheral = peripheral, peripheral.state == .connected {
            peripheral.discoverServices(BLEPeripheralScanner.supportedServices)
        }
    }

    func waitForCharacteristicsSetup(timeout: TimeInterval) async throws {
        // If a previous wait is still in flight (e.g. overlapping reconnect
        // attempts), resume it before we take over the single completion slot —
        // otherwise its continuation would be orphaned and leak.
        fireConnectionCompletion(peripheral: nil, error: BLEManagerError.peripheralNotConnected)

        // Start a new generation so stale callbacks are ignored, and reset the
        // single-resume flag — all under the lock. Scoped `withLock` keeps this
        // safe to call from this async context.
        let currentGeneration = resumeLock.withLock { () -> Int in
            connectionGeneration += 1
            hasResumedConnection = false
            return connectionGeneration
        }

        // Owns this wait's timeout task so a normal completion can cancel it.
        let timeoutBox = TimeoutTaskBox()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                resumeLock.lock()

                // Caller was cancelled before we could register — resume now.
                if Task.isCancelled {
                    hasResumedConnection = true
                    resumeLock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }

                // The single resume sink. Whichever of {characteristics ready,
                // discovery error, timeout, cancellation, reset, supersede} fires
                // first wins; the rest are no-ops via the generation +
                // hasResumedConnection guard. This guarantees exactly-once resume,
                // so the continuation can never leak.
                connectionCompletion = { [weak self] peripheral, error in
                    guard let self else { return }
                    self.resumeLock.lock()
                    guard self.connectionGeneration == currentGeneration,
                          self.hasResumedConnection == false else {
                        self.resumeLock.unlock()
                        return
                    }
                    self.hasResumedConnection = true
                    self.connectionCompletion = nil
                    self.resumeLock.unlock()

                    // Stop the timeout; resume exactly once, outside the lock.
                    timeoutBox.value?.cancel()
                    if peripheral != nil {
                        continuation.resume()
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: BLEManagerError.unknownError)
                    }
                }
                resumeLock.unlock()

                // Self-contained timeout that drives the same single sink.
                if timeout > 0 {
                    timeoutBox.value = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        self?.fireConnectionCompletion(peripheral: nil, error: BLEManagerError.timeout)
                    }
                }
            }
        } onCancel: {
            // Caller cancelled the await — unblock through the same single sink.
            fireConnectionCompletion(peripheral: nil, error: CancellationError())
            timeoutBox.value?.cancel()
        }
    }

    /// Reads the pending completion under the lock and invokes it outside the
    /// lock (to avoid resuming while holding it). The stored closure performs the
    /// exactly-once / correct-generation guard, so this is safe to call from any
    /// thread, any number of times.
    private func fireConnectionCompletion(peripheral: CBPeripheral?, error: Error?) {
        resumeLock.lock()
        let completion = connectionCompletion
        resumeLock.unlock()
        completion?(peripheral, error)
    }

    func didDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        // Validate this is our connected peripheral (prevents ghost callbacks from old connections)
        guard peripheral.identifier == connectedPeripheral?.identifier else {
            logger.warning("Received services for unknown peripheral \(peripheral.identifier), ignoring")
            return
        }

        for service in peripheral.services ?? [] {
            logger.info("Discovered service: \(service.uuid.uuidString)")
            characteristicHandler.discoverCharacteristics(for: service, on: peripheral)
        }
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        // Validate this is our connected peripheral (prevents ghost callbacks from old connections)
        guard peripheral.identifier == connectedPeripheral?.identifier else {
            logger.warning("Received characteristics for unknown peripheral \(peripheral.identifier), ignoring")
            return
        }

        if let error = error {
            logger.error("Error discovering characteristics: \(error.localizedDescription)")
            // Routed through the lock-guarded sink, which handles exactly-once resume.
            fireConnectionCompletion(peripheral: nil, error: error)
            return
        }

        guard let characteristics = service.characteristics else { return }

        characteristicHandler.setupCharacteristics(characteristics, on: peripheral)

        // Check if all required characteristics are set up
        if characteristicHandler.isReady {
            // Routed through the lock-guarded sink, which handles exactly-once resume.
            fireConnectionCompletion(peripheral: peripheral, error: nil)

            // Notify delegate
            delegate?.peripheralManager(self, didSetupCharacteristics: peripheral)
        }
    }

    func didUpdateValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        // Validate this is our connected peripheral (prevents ghost callbacks from old connections)
        guard peripheral.identifier == connectedPeripheral?.identifier else {
            logger.warning("Received value update for unknown peripheral \(peripheral.identifier), ignoring")
            return
        }

        if let error = error {
            logger.error("Error reading characteristic value: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else { return }
        characteristicHandler.handleUpdatedValue(data, from: characteristic)
    }
}

extension BLEPeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        didDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        didDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateValue(peripheral, characteristic: characteristic, error: error)
    }
}
