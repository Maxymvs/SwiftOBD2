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

    init(characteristicHandler: BLECharacteristicHandler) {
        self.characteristicHandler = characteristicHandler
        super.init()
    }

    /// Reset all state for clean reconnection - clears pending continuations
    func reset() {
        // Save pending completion before clearing
        let completion = connectionCompletion
        connectionCompletion = nil

        // Clear delegate before clearing peripheral reference
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil

        // Resume with error if completion was pending (prevents continuation leak)
        // This must happen BEFORE setting hasResumedConnection = true
        // The closure's guard checks hasResumedConnection == false
        completion?(nil, BLEManagerError.peripheralNotConnected)

        // Mark as handled for any future callbacks that might arrive
        hasResumedConnection = true
    }

    func setPeripheral(_ peripheral: CBPeripheral?) {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self

        if let peripheral = peripheral {
            peripheral.discoverServices(BLEPeripheralScanner.supportedServices)
        }
    }

    func waitForCharacteristicsSetup(timeout: TimeInterval) async throws {
        // Increment generation to invalidate any stale callbacks from previous connections
        connectionGeneration += 1
        let currentGeneration = connectionGeneration
        hasResumedConnection = false  // Reset flag for new request

        try await withTimeout(seconds: timeout, onTimeout: { [weak self] in
            // Only handle timeout if this is still the current generation
            guard self?.connectionGeneration == currentGeneration else { return }
            let completion = self?.connectionCompletion
            self?.connectionCompletion = nil
            // Resume the continuation with timeout error — prevents leak that hangs withThrowingTaskGroup
            completion?(nil, BLEManagerError.timeout)
        }) { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connectionCompletion = { [weak self] peripheral, error in
                    // Validate this callback is for the current connection generation
                    guard self?.connectionGeneration == currentGeneration else { return }
                    // Guard against double-resume
                    guard self?.hasResumedConnection == false else { return }
                    self?.hasResumedConnection = true

                    if peripheral != nil {
                        continuation.resume()
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: BLEManagerError.unknownError)
                    }
                }
            }
        }
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
            // NO hasResumedConnection guard here - the closure handles double-resume protection
            connectionCompletion?(nil, error)
            connectionCompletion = nil
            return
        }

        guard let characteristics = service.characteristics else { return }

        characteristicHandler.setupCharacteristics(characteristics, on: peripheral)

        // Check if all required characteristics are set up
        if characteristicHandler.isReady {
            // NO hasResumedConnection guard here - the closure handles double-resume protection
            connectionCompletion?(peripheral, nil)
            connectionCompletion = nil

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
