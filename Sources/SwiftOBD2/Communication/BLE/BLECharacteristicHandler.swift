import Foundation
import OSLog
import CoreBluetooth

class BLECharacteristicHandler {
    private var ecuReadCharacteristic: CBCharacteristic?
    private var ecuWriteCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType?
    private let messageProcessor: BLEMessageProcessor
    private let adapterRegistry: BLEAdapterRegistry
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "BLECharacteristicHandler")

    var isReady: Bool {
        ecuReadCharacteristic != nil && ecuWriteCharacteristic != nil && writeType != nil
    }

    init(messageProcessor: BLEMessageProcessor, adapterRegistry: BLEAdapterRegistry = .standard) {
        self.messageProcessor = messageProcessor
        self.adapterRegistry = adapterRegistry
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
            guard let readCharacteristic = characteristics.first(where: {
                $0.uuid.uuidString.uppercased() == binding.readCharacteristicUUID
            }), let writeCharacteristic = characteristics.first(where: {
                $0.uuid.uuidString.uppercased() == binding.writeCharacteristicUUID
            }) else {
                return
            }

            ecuReadCharacteristic = readCharacteristic
            ecuWriteCharacteristic = writeCharacteristic
            writeType = binding.writeType.coreBluetoothType

            if readCharacteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: readCharacteristic)
            }

            logger.info("Configured adapter profile \(binding.profile.id, privacy: .public) - Read: \(binding.readCharacteristicUUID, privacy: .public), Write: \(binding.writeCharacteristicUUID, privacy: .public)")
        case let .failure(error):
            logger.debug("Adapter profile did not resolve for service \(service.uuid.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func discoverCharacteristics(for service: CBService, on peripheral: CBPeripheral) {
        guard let profile = adapterRegistry.profile(forServiceUUID: service.uuid.uuidString) else { return }
        peripheral.discoverCharacteristics(profile.characteristicUUIDs.map(CBUUID.init(string:)), for: service)
    }

    func writeCommand(_ command: String, to peripheral: CBPeripheral) throws {
        guard let characteristic = ecuWriteCharacteristic,
              let writeType,
              let data = "\(command)\r".data(using: .ascii) else {
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }

        peripheral.writeValue(data, for: characteristic, type: writeType)
        logger.info("Sent command: \(command)")
    }

    func handleUpdatedValue(_ data: Data, from characteristic: CBCharacteristic) {
        guard characteristic == ecuReadCharacteristic else {
            if let responseString = String(data: data, encoding: .utf8) {
                logger.info("Unknown characteristic: \(characteristic)\nResponse: \(responseString)")
            }
            return
        }

        messageProcessor.processReceivedData(data)
    }

    func reset(peripheral: CBPeripheral? = nil) {
        // Unsubscribe from notifications before clearing references
        // This prevents ghost notifications arriving after disconnect
        if let peripheral = peripheral {
            if let readChar = ecuReadCharacteristic, readChar.isNotifying {
                peripheral.setNotifyValue(false, for: readChar)
            }
            if let writeChar = ecuWriteCharacteristic, writeChar != ecuReadCharacteristic, writeChar.isNotifying {
                peripheral.setNotifyValue(false, for: writeChar)
            }
        }

        ecuReadCharacteristic = nil
        ecuWriteCharacteristic = nil
        writeType = nil
    }

    private static func capabilities(for characteristic: CBCharacteristic) -> BLECharacteristicCapabilities {
        var capabilities: BLECharacteristicCapabilities = []
        if characteristic.properties.contains(.read) { capabilities.insert(.read) }
        if characteristic.properties.contains(.notify) { capabilities.insert(.notify) }
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
