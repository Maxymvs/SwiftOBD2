import CoreBluetooth
import Foundation

/// One advertisement sighting from a user-facing adapter scan.
///
/// Carries what the bare `CBPeripheral` drops: signal strength and the
/// advertisement contents, so a picker can rank likely OBD adapters above
/// unrelated Bluetooth devices.
public struct BLEPeripheralDiscovery {
    public let peripheral: CBPeripheral
    /// Received signal strength in dBm, or nil when CoreBluetooth reports it as
    /// unavailable (127). The advertisement's name and services still count.
    public let rssi: Int?
    /// Name from the advertisement packet. Fresher than `peripheral.name`,
    /// which iOS may have cached from an earlier connection.
    public let advertisedName: String?
    /// Advertised service UUIDs, normalized to short form where possible.
    public let advertisedServiceUUIDs: [String]
    /// The advertisement includes a service UUID one of the known adapter
    /// profiles can talk to.
    public let advertisesSupportedAdapterService: Bool

    public var identifier: UUID { peripheral.identifier }

    /// Best available display name, or nil when the device has none.
    public var name: String? {
        Self.nonEmpty(advertisedName) ?? Self.nonEmpty(peripheral.name)
    }

    init(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber,
        registry: BLEAdapterRegistry = .standard
    ) {
        let serviceUUIDs = Self.serviceUUIDs(fromAdvertisement: advertisementData)
        self.peripheral = peripheral
        self.rssi = Self.signalStrength(fromRSSI: rssi)
        self.advertisedName = Self.nonEmpty(advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        self.advertisedServiceUUIDs = serviceUUIDs
        self.advertisesSupportedAdapterService = Self.containsSupportedService(serviceUUIDs, registry: registry)
    }

    /// CoreBluetooth reports 127 for "RSSI unavailable"; real readings are negative dBm.
    static func signalStrength(fromRSSI rssi: NSNumber) -> Int? {
        let value = rssi.intValue
        return value < 0 ? value : nil
    }

    static func serviceUUIDs(fromAdvertisement advertisementData: [String: Any]) -> [String] {
        let keys = [CBAdvertisementDataServiceUUIDsKey, CBAdvertisementDataOverflowServiceUUIDsKey]
        var uuids: [String] = []
        for key in keys {
            for uuid in advertisementData[key] as? [CBUUID] ?? [] {
                let normalized = BLECharacteristicDescriptor.normalize(uuid.uuidString)
                if !uuids.contains(normalized) {
                    uuids.append(normalized)
                }
            }
        }
        return uuids
    }

    static func containsSupportedService(_ serviceUUIDs: [String], registry: BLEAdapterRegistry) -> Bool {
        let supported = Set(registry.serviceUUIDs.map(BLECharacteristicDescriptor.normalize))
        return serviceUUIDs.contains { supported.contains(BLECharacteristicDescriptor.normalize($0)) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
