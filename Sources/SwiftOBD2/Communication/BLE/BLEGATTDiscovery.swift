import Foundation

/// Why a GATT layout was accepted. The value is safe to expose in diagnostics;
/// it contains no peripheral identifier or advertisement metadata.
public enum BLEAdapterProfileSource: String, Codable, Equatable, Sendable {
    case known
    case inferred
}

/// The complete characteristic graph for one service on a selected peripheral.
struct BLEGATTServiceDescriptor: Equatable, Sendable {
    let uuid: String
    let characteristics: [BLECharacteristicDescriptor]

    init(uuid: String, characteristics: [BLECharacteristicDescriptor]) {
        self.uuid = BLECharacteristicDescriptor.normalize(uuid)
        self.characteristics = characteristics
    }
}

/// Unknown layouts are considered only for a device the user selected or a
/// peripheral that previously completed ELM validation.
enum BLEUnknownProfileInferenceAuthorization: Equatable, Sendable {
    case denied
    case explicitPeripheralSelection
    case validatedCache

    var permitsInference: Bool {
        self != .denied
    }
}

extension BLEAdapterRegistry {
    /// Resolves once after the complete GATT graph has been collected. A known
    /// service always takes precedence. If a known UUID is present but its
    /// layout is invalid, the graph fails rather than falling back to inference.
    func resolve(
        services: [BLEGATTServiceDescriptor],
        inferenceAuthorization: BLEUnknownProfileInferenceAuthorization
    ) -> Result<BLEAdapterBinding, BLEAdapterProfileResolutionError> {
        let knownServices = services.filter { service in
            profiles.contains { $0.serviceUUID == service.uuid }
        }

        if !knownServices.isEmpty {
            var resolved: [BLEAdapterBinding] = []
            var failures: [BLEAdapterProfileResolutionError] = []

            for service in knownServices {
                switch resolve(serviceUUID: service.uuid, characteristics: service.characteristics) {
                case let .success(binding):
                    resolved.append(binding)
                case let .failure(error):
                    failures.append(error)
                }
            }

            if resolved.count > 1 || knownServices.count > 1 {
                return .failure(.ambiguousServices(knownServices.map(\.uuid).sorted()))
            }
            if resolved.count == 1, let binding = resolved.first {
                return .success(binding)
            }
            return .failure(failures[0])
        }

        guard inferenceAuthorization.permitsInference else {
            return .failure(.inferenceNotAuthorized)
        }

        var inferred: [BLEAdapterBinding] = []
        for service in services {
            let responseCharacteristics = service.characteristics.filter {
                $0.capabilities.contains(.notify) || $0.capabilities.contains(.indicate)
            }
            let writeCharacteristics = service.characteristics.filter {
                $0.capabilities.contains(.writeWithResponse)
                    || $0.capabilities.contains(.writeWithoutResponse)
            }

            guard !responseCharacteristics.isEmpty, !writeCharacteristics.isEmpty else {
                continue
            }
            guard responseCharacteristics.count == 1, writeCharacteristics.count == 1,
                  let responseCharacteristic = responseCharacteristics.first,
                  let writeCharacteristic = writeCharacteristics.first else {
                return .failure(.ambiguousInferredCharacteristics(service.uuid))
            }

            let writeType: BLEAdapterWriteType = writeCharacteristic.capabilities
                .contains(.writeWithResponse) ? .withResponse : .withoutResponse
            let profile = BLEAdapterProfile(
                id: BLEAdapterProfile.inferredProfileID,
                displayName: "Inferred BLE adapter",
                serviceUUID: service.uuid,
                readCharacteristicUUID: responseCharacteristic.uuid,
                writeCharacteristicUUID: writeCharacteristic.uuid,
                supportedWriteTypes: [.withResponse, .withoutResponse],
                version: BLEAdapterProfile.inferredProfileVersion
            )
            inferred.append(BLEAdapterBinding(
                profile: profile,
                source: .inferred,
                readCharacteristicUUID: responseCharacteristic.uuid,
                writeCharacteristicUUID: writeCharacteristic.uuid,
                writeType: writeType
            ))
        }

        guard !inferred.isEmpty else {
            return .failure(.noCompatibleCharacteristics)
        }
        guard inferred.count == 1, let binding = inferred.first else {
            return .failure(.ambiguousServices(inferred.map { $0.profile.serviceUUID }.sorted()))
        }
        return .success(binding)
    }
}

/// A canonical, privacy-safe representation of a selected peripheral's GATT
/// graph. It deliberately includes only normalized UUIDs and property bits.
struct BLEGATTFingerprint: Codable, Equatable, Hashable, Sendable {
    struct Service: Codable, Equatable, Hashable, Sendable {
        struct Characteristic: Codable, Equatable, Hashable, Sendable {
            let uuid: String
            let properties: UInt8
        }

        let uuid: String
        let characteristics: [Characteristic]
    }

    let services: [Service]

    init(services: [BLEGATTServiceDescriptor]) {
        self.services = services.map { service in
            Service(
                uuid: service.uuid,
                characteristics: service.characteristics.map {
                    Service.Characteristic(
                        uuid: $0.uuid,
                        properties: $0.capabilities.rawValue
                    )
                }.sorted {
                    if $0.uuid != $1.uuid { return $0.uuid < $1.uuid }
                    return $0.properties < $1.properties
                }
            )
        }.sorted {
            if $0.uuid != $1.uuid { return $0.uuid < $1.uuid }
            return Self.characteristicSortKey($0) < Self.characteristicSortKey($1)
        }
    }

    /// Stable diagnostic/test form. It is not intended as user-facing text.
    var canonicalValue: String {
        services.map { service in
            let characteristics = service.characteristics.map {
                "\($0.uuid):\($0.properties)"
            }.joined(separator: ",")
            return "\(service.uuid)[\(characteristics)]"
        }.joined(separator: "|")
    }

    private static func characteristicSortKey(_ service: Service) -> String {
        service.characteristics.map { "\($0.uuid):\($0.properties)" }.joined(separator: ",")
    }
}
