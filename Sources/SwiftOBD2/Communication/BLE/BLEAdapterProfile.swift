import Foundation

/// The write modes an adapter profile permits, in preference order.
enum BLEAdapterWriteType: String, Codable, Equatable, Sendable {
    case withResponse
    case withoutResponse
}

/// CoreBluetooth-independent characteristic capabilities used by profile resolution.
struct BLECharacteristicCapabilities: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let read = Self(rawValue: 1 << 0)
    static let notify = Self(rawValue: 1 << 1)
    static let writeWithResponse = Self(rawValue: 1 << 2)
    static let writeWithoutResponse = Self(rawValue: 1 << 3)
    static let indicate = Self(rawValue: 1 << 4)
}

/// Tracks the asynchronous notification subscription that must complete before
/// commands can safely be sent to an adapter.
struct BLENotificationReadiness: Equatable, Sendable {
    private(set) var isSubscriptionConfirmed = false

    var isReady: Bool {
        isSubscriptionConfirmed
    }

    mutating func begin(alreadySubscribed: Bool) {
        isSubscriptionConfirmed = alreadySubscribed
    }

    mutating func update(isNotifying: Bool) {
        isSubscriptionConfirmed = isNotifying
    }

    mutating func reset() {
        isSubscriptionConfirmed = false
    }
}

struct BLECharacteristicDescriptor: Equatable, Sendable {
    let uuid: String
    let capabilities: BLECharacteristicCapabilities

    init(uuid: String, capabilities: BLECharacteristicCapabilities) {
        self.uuid = Self.normalize(uuid)
        self.capabilities = capabilities
    }

    static func normalize(_ uuid: String) -> String {
        let normalized = uuid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let bluetoothBaseSuffix = "-0000-1000-8000-00805F9B34FB"
        if normalized.hasPrefix("0000"), normalized.hasSuffix(bluetoothBaseSuffix),
           normalized.count == 36 {
            return String(normalized.dropFirst(4).prefix(4))
        }
        return normalized
    }
}

/// A known adapter GATT layout. `displayName` is diagnostic metadata only;
/// compatibility is resolved exclusively from the service and characteristic UUIDs.
struct BLEAdapterProfile: Equatable, Sendable {
    static let inferredProfileID = "inferred-gatt"
    static let inferredProfileVersion = 1

    let id: String
    let version: Int
    let displayName: String
    let serviceUUID: String
    let readCharacteristicUUID: String
    let writeCharacteristicUUID: String
    let supportedWriteTypes: [BLEAdapterWriteType]
    let commandTerminator: String
    let maxWriteChunkBytes: Int?

    init(
        id: String,
        displayName: String,
        serviceUUID: String,
        readCharacteristicUUID: String,
        writeCharacteristicUUID: String,
        supportedWriteTypes: [BLEAdapterWriteType],
        version: Int = 1,
        commandTerminator: String = "\r",
        maxWriteChunkBytes: Int? = nil
    ) {
        self.id = id
        self.version = version
        self.displayName = displayName
        self.serviceUUID = BLECharacteristicDescriptor.normalize(serviceUUID)
        self.readCharacteristicUUID = BLECharacteristicDescriptor.normalize(readCharacteristicUUID)
        self.writeCharacteristicUUID = BLECharacteristicDescriptor.normalize(writeCharacteristicUUID)
        self.supportedWriteTypes = supportedWriteTypes
        self.commandTerminator = commandTerminator
        self.maxWriteChunkBytes = maxWriteChunkBytes
    }

    var characteristicUUIDs: [String] {
        if readCharacteristicUUID == writeCharacteristicUUID {
            return [readCharacteristicUUID]
        }
        return [readCharacteristicUUID, writeCharacteristicUUID]
    }
}

struct BLEAdapterBinding: Equatable, Sendable {
    let profile: BLEAdapterProfile
    let source: BLEAdapterProfileSource
    let readCharacteristicUUID: String
    let writeCharacteristicUUID: String
    let writeType: BLEAdapterWriteType
}

enum BLEAdapterProfileResolutionError: Error, Equatable, Sendable {
    case unsupportedService(String)
    case ambiguousProfiles(String)
    case missingCharacteristic(String)
    case ambiguousCharacteristic(String)
    case unsupportedReadProperties(String)
    case unsupportedWriteProperties(String)
    case ambiguousServices([String])
    case ambiguousInferredCharacteristics(String)
    case inferenceNotAuthorized
    case noCompatibleCharacteristics
}

/// The single source of truth for supported BLE adapter layouts.
struct BLEAdapterRegistry: Sendable {
    let profiles: [BLEAdapterProfile]

    static let standard = BLEAdapterRegistry(profiles: [
        BLEAdapterProfile(
            id: "ffe0-shared",
            displayName: "FFE0 shared characteristic adapter",
            serviceUUID: "FFE0",
            readCharacteristicUUID: "FFE1",
            writeCharacteristicUUID: "FFE1",
            supportedWriteTypes: [.withResponse, .withoutResponse]
        ),
        BLEAdapterProfile(
            id: "fff0-split",
            displayName: "FFF0 split characteristic adapter",
            serviceUUID: "FFF0",
            readCharacteristicUUID: "FFF1",
            writeCharacteristicUUID: "FFF2",
            supportedWriteTypes: [.withResponse, .withoutResponse]
        ),
        BLEAdapterProfile(
            id: "18f0-split",
            displayName: "18F0 split characteristic adapter",
            serviceUUID: "18F0",
            readCharacteristicUUID: "2AF0",
            writeCharacteristicUUID: "2AF1",
            supportedWriteTypes: [.withResponse, .withoutResponse]
        ),
    ])

    var serviceUUIDs: [String] {
        profiles.map(\.serviceUUID)
    }

    func profile(forServiceUUID serviceUUID: String) -> BLEAdapterProfile? {
        let matches = profiles.filter {
            $0.serviceUUID == BLECharacteristicDescriptor.normalize(serviceUUID)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func resolve(
        serviceUUID: String,
        characteristics: [BLECharacteristicDescriptor]
    ) -> Result<BLEAdapterBinding, BLEAdapterProfileResolutionError> {
        let normalizedServiceUUID = BLECharacteristicDescriptor.normalize(serviceUUID)
        let matchingProfiles = profiles.filter { $0.serviceUUID == normalizedServiceUUID }

        guard !matchingProfiles.isEmpty else {
            return .failure(.unsupportedService(normalizedServiceUUID))
        }
        guard matchingProfiles.count == 1, let profile = matchingProfiles.first else {
            return .failure(.ambiguousProfiles(normalizedServiceUUID))
        }

        let readMatches = characteristics.filter { $0.uuid == profile.readCharacteristicUUID }
        guard !readMatches.isEmpty else {
            return .failure(.missingCharacteristic(profile.readCharacteristicUUID))
        }
        guard readMatches.count == 1, let read = readMatches.first else {
            return .failure(.ambiguousCharacteristic(profile.readCharacteristicUUID))
        }
        guard read.capabilities.contains(.notify) || read.capabilities.contains(.indicate) else {
            return .failure(.unsupportedReadProperties(profile.readCharacteristicUUID))
        }

        let writeMatches = characteristics.filter { $0.uuid == profile.writeCharacteristicUUID }
        guard !writeMatches.isEmpty else {
            return .failure(.missingCharacteristic(profile.writeCharacteristicUUID))
        }
        guard writeMatches.count == 1, let write = writeMatches.first else {
            return .failure(.ambiguousCharacteristic(profile.writeCharacteristicUUID))
        }

        let selectedWriteType = profile.supportedWriteTypes.first { type in
            switch type {
            case .withResponse:
                return write.capabilities.contains(.writeWithResponse)
            case .withoutResponse:
                return write.capabilities.contains(.writeWithoutResponse)
            }
        }
        guard let selectedWriteType else {
            return .failure(.unsupportedWriteProperties(profile.writeCharacteristicUUID))
        }

        return .success(BLEAdapterBinding(
            profile: profile,
            source: .known,
            readCharacteristicUUID: read.uuid,
            writeCharacteristicUUID: write.uuid,
            writeType: selectedWriteType
        ))
    }
}
