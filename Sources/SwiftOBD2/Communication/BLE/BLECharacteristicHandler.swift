import Foundation
import OSLog
import CoreBluetooth

class BLECharacteristicHandler {
    private let stateLock = NSLock()
    private var ecuReadCharacteristic: CBCharacteristic?
    private var ecuWriteCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType?
    private weak var configuredPeripheral: CBPeripheral?
    private var commandTerminator = "\r"
    private var maximumProfileChunkLength: Int?
    private var configuredBinding: BLEAdapterBinding?
    private var configurationGeneration: UInt64 = 0
    private var writeSession: UInt64?
    private var notificationReadiness = BLENotificationReadiness()
    private let messageProcessor: BLEMessageProcessor
    private let adapterRegistry: BLEAdapterRegistry
    private let writeCoordinator: BLEWriteCoordinator
    private let acknowledgementLedger: BLEWriteAcknowledgementLedger
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "BLECharacteristicHandler")

    var isReady: Bool {
        stateLock.withLock {
            ecuReadCharacteristic != nil
                && ecuWriteCharacteristic != nil
                && writeType != nil
                && writeSession != nil
                && notificationReadiness.isReady
        }
    }

    var binding: BLEAdapterBinding? {
        stateLock.withLock { configuredBinding }
    }

    var configurationToken: UInt64 {
        stateLock.withLock { configurationGeneration }
    }

    init(
        messageProcessor: BLEMessageProcessor,
        adapterRegistry: BLEAdapterRegistry = .standard,
        writeCoordinator: BLEWriteCoordinator = BLEWriteCoordinator(),
        acknowledgementLedger: BLEWriteAcknowledgementLedger = BLEWriteAcknowledgementLedger()
    ) {
        self.messageProcessor = messageProcessor
        self.adapterRegistry = adapterRegistry
        self.writeCoordinator = writeCoordinator
        self.acknowledgementLedger = acknowledgementLedger
    }

    func setupCharacteristics(
        _ characteristics: [CBCharacteristic],
        for service: CBService,
        on peripheral: CBPeripheral
    ) {
        let descriptors = characteristics.map {
            BLECharacteristicDescriptor(uuid: $0.uuid.uuidString, capabilities: Self.capabilities(for: $0))
        }

        switch adapterRegistry.resolve(serviceUUID: service.uuid.uuidString, characteristics: descriptors) {
        case let .success(binding):
            setup(binding: binding, characteristics: characteristics, on: peripheral)
        case let .failure(error):
            logger.debug("Adapter profile did not resolve for service \(service.uuid.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    @discardableResult
    func setup(
        binding: BLEAdapterBinding,
        characteristics: [CBCharacteristic],
        on peripheral: CBPeripheral,
        expectedConfigurationToken: UInt64? = nil
    ) -> Bool {
        guard let readCharacteristic = characteristics.first(where: {
            BLECharacteristicDescriptor.normalize($0.uuid.uuidString) == binding.readCharacteristicUUID
        }), let writeCharacteristic = characteristics.first(where: {
            BLECharacteristicDescriptor.normalize($0.uuid.uuidString) == binding.writeCharacteristicUUID
        }) else {
            return false
        }

        let didConfigure = stateLock.withLock { () -> Bool in
            if let expectedConfigurationToken,
               configurationGeneration != expectedConfigurationToken {
                return false
            }
            ecuReadCharacteristic = readCharacteristic
            ecuWriteCharacteristic = writeCharacteristic
            writeType = binding.writeType.coreBluetoothType
            configuredPeripheral = peripheral
            configuredBinding = binding
            commandTerminator = binding.profile.commandTerminator
            maximumProfileChunkLength = binding.profile.maxWriteChunkBytes
            notificationReadiness.begin(alreadySubscribed: readCharacteristic.isNotifying)
            writeSession = writeCoordinator.activateSession()
            return true
        }
        guard didConfigure else { return false }

        if !readCharacteristic.isNotifying {
            peripheral.setNotifyValue(true, for: readCharacteristic)
        }

        logger.info("Configured adapter profile \(binding.profile.id, privacy: .public)")
        return true
    }

    func discoverCharacteristics(for service: CBService, on peripheral: CBPeripheral) {
        guard let profile = adapterRegistry.profile(forServiceUUID: service.uuid.uuidString) else { return }
        peripheral.discoverCharacteristics(profile.characteristicUUIDs.map(CBUUID.init(string:)), for: service)
    }

    func writeCommand(
        _ command: String,
        to peripheral: CBPeripheral,
        deadline: TimeInterval = BLEConstants.defaultTimeout
    ) async throws {
        let configuration = stateLock.withLock { () -> (
            CBCharacteristic,
            CBCharacteristicWriteType,
            UInt64,
            String,
            Int?
        )? in
            guard configuredPeripheral === peripheral,
                  let characteristic = ecuWriteCharacteristic,
                  let writeType,
                  let writeSession,
                  notificationReadiness.isReady else { return nil }
            return (
                characteristic,
                writeType,
                writeSession,
                commandTerminator,
                maximumProfileChunkLength
            )
        }
        guard let (characteristic, writeType, session, terminator, profileMaximum) = configuration else {
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }

        let payload = try BLECommandEncoder.encode(command: command, terminator: terminator)
        let transport = CoreBluetoothWriteTransport(
            peripheral: peripheral,
            characteristic: characteristic,
            writeType: writeType,
            maximumProfileChunkLength: profileMaximum,
            session: session,
            acknowledgementLedger: acknowledgementLedger
        )
        try await writeCoordinator.write(
            payload,
            mode: writeType.writeMode,
            session: session,
            transport: transport,
            deadline: deadline
        )
        logger.info("Sent command: \(command)")
    }

    func handleUpdatedValue(_ data: Data, from characteristic: CBCharacteristic) {
        let handled = stateLock.withLock { () -> Bool in
            guard characteristic === ecuReadCharacteristic,
                  writeSession != nil,
                  notificationReadiness.isReady else { return false }
            // Processing while holding the channel lock gives reset a strict
            // before/after relationship with this callback. Stale bytes cannot
            // pass the identity check and then land after the processor reset.
            messageProcessor.processReceivedData(data)
            return true
        }
        guard handled else {
            if let responseString = String(data: data, encoding: .utf8) {
                logger.info("Unknown characteristic: \(characteristic)\nResponse: \(responseString)")
            }
            return
        }
    }

    /// Records CoreBluetooth's asynchronous subscription result. The caller
    /// must not declare the adapter ready until this returns true.
    func handleNotificationStateUpdate(for characteristic: CBCharacteristic) -> Bool {
        let ready = stateLock.withLock { () -> Bool in
            guard characteristic === ecuReadCharacteristic else { return false }
            let wasReady = notificationReadiness.isReady
            notificationReadiness.update(isNotifying: characteristic.isNotifying)
            if wasReady && !notificationReadiness.isReady {
                if let session = writeSession {
                    writeCoordinator.invalidateSession(session, with: BLEManagerError.peripheralNotConnected)
                }
                writeSession = nil
            }
            return ecuWriteCharacteristic != nil
                && writeType != nil
                && writeSession != nil
                && notificationReadiness.isReady
        }
        return ready
    }

    func handlesNotificationState(for characteristic: CBCharacteristic) -> Bool {
        stateLock.withLock { characteristic === ecuReadCharacteristic }
    }

    func handleNotificationFailure(_ error: Error) {
        stateLock.withLock {
            notificationReadiness.update(isNotifying: false)
            if let session = writeSession {
                writeCoordinator.invalidateSession(session, with: error)
            }
            writeSession = nil
        }
    }

    func handleWriteAcknowledgement(
        on peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        let session = acknowledgementLedger.consumeAcknowledgement(
            peripheralID: peripheral.identifier,
            characteristicUUID: characteristic.uuid.uuidString
        )
        guard let session else { return }
        writeCoordinator.didReceiveAcknowledgement(session: session, error: error)
    }

    func confirmedDisconnect(_ peripheral: CBPeripheral) {
        acknowledgementLedger.confirmedDisconnect(peripheralID: peripheral.identifier)
    }

    func handleReadyToSendWriteWithoutResponse(on peripheral: CBPeripheral) {
        let session = stateLock.withLock { () -> UInt64? in
            guard configuredPeripheral === peripheral else { return nil }
            return writeSession
        }
        guard let session else { return }
        writeCoordinator.peripheralIsReady(session: session)
    }

    func reset(peripheral: CBPeripheral? = nil) {
        let characteristics = stateLock.withLock { () -> (CBCharacteristic?, CBCharacteristic?) in
            let values = (ecuReadCharacteristic, ecuWriteCharacteristic)
            if let session = writeSession {
                writeCoordinator.invalidateSession(session, with: BLEManagerError.peripheralNotConnected)
            }
            ecuReadCharacteristic = nil
            ecuWriteCharacteristic = nil
            writeType = nil
            configuredPeripheral = nil
            configuredBinding = nil
            commandTerminator = "\r"
            maximumProfileChunkLength = nil
            writeSession = nil
            notificationReadiness.reset()
            configurationGeneration &+= 1
            return values
        }

        // Unsubscribe from notifications before clearing references
        // This prevents ghost notifications arriving after disconnect
        if let peripheral = peripheral {
            if let readChar = characteristics.0, readChar.isNotifying {
                peripheral.setNotifyValue(false, for: readChar)
            }
            if let writeChar = characteristics.1, writeChar !== characteristics.0, writeChar.isNotifying {
                peripheral.setNotifyValue(false, for: writeChar)
            }
        }
    }

    static func capabilities(for characteristic: CBCharacteristic) -> BLECharacteristicCapabilities {
        var capabilities: BLECharacteristicCapabilities = []
        if characteristic.properties.contains(.read) { capabilities.insert(.read) }
        if characteristic.properties.contains(.notify) { capabilities.insert(.notify) }
        if characteristic.properties.contains(.indicate) { capabilities.insert(.indicate) }
        if characteristic.properties.contains(.write) { capabilities.insert(.writeWithResponse) }
        if characteristic.properties.contains(.writeWithoutResponse) { capabilities.insert(.writeWithoutResponse) }
        return capabilities
    }
}

private extension BLEAdapterWriteType {
    var coreBluetoothType: CBCharacteristicWriteType {
        switch self {
        case .withResponse: return .withResponse
        case .withoutResponse: return .withoutResponse
        }
    }
}

private extension CBCharacteristicWriteType {
    var writeMode: BLEWriteMode {
        switch self {
        case .withResponse: return .withResponse
        case .withoutResponse: return .withoutResponse
        @unknown default: return .withResponse
        }
    }
}

/// The references are immutable after initialization and every access is made
/// from `BLEWriteCoordinator`'s serial executor.
private final class CoreBluetoothWriteTransport: BLEWriteTransport, @unchecked Sendable {
    private weak var peripheral: CBPeripheral?
    private let characteristic: CBCharacteristic
    private let writeType: CBCharacteristicWriteType
    private let maximumProfileChunkLength: Int?
    private let session: UInt64
    private let acknowledgementLedger: BLEWriteAcknowledgementLedger

    init(
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        writeType: CBCharacteristicWriteType,
        maximumProfileChunkLength: Int?,
        session: UInt64,
        acknowledgementLedger: BLEWriteAcknowledgementLedger
    ) {
        self.peripheral = peripheral
        self.characteristic = characteristic
        self.writeType = writeType
        self.maximumProfileChunkLength = maximumProfileChunkLength
        self.session = session
        self.acknowledgementLedger = acknowledgementLedger
    }

    func maximumWriteValueLength(for mode: BLEWriteMode) -> Int {
        guard let peripheral else { return 0 }
        let maximum = peripheral.maximumWriteValueLength(for: mode.coreBluetoothType)
        guard let profileMaximum = maximumProfileChunkLength else { return maximum }
        return min(maximum, profileMaximum)
    }

    var canSendWriteWithoutResponse: Bool {
        peripheral?.canSendWriteWithoutResponse == true
    }

    func write(_ data: Data, mode: BLEWriteMode) throws {
        guard let peripheral, peripheral.state == .connected else {
            throw BLEManagerError.peripheralNotConnected
        }
        if mode == .withResponse {
            acknowledgementLedger.recordingSubmission(
                session: session,
                peripheralID: peripheral.identifier,
                characteristicUUID: characteristic.uuid.uuidString
            ) {
                peripheral.writeValue(data, for: characteristic, type: writeType)
            }
            return
        }
        peripheral.writeValue(data, for: characteristic, type: writeType)
    }
}

private extension BLEWriteMode {
    var coreBluetoothType: CBCharacteristicWriteType {
        switch self {
        case .withResponse: return .withResponse
        case .withoutResponse: return .withoutResponse
        }
    }
}
