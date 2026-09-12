@testable import SwiftOBD2
import XCTest

final class BLEGATTDiscoveryTests: XCTestCase {
    private let registry = BLEAdapterRegistry.standard

    func testProfileDefaultsPreserveExistingCommandBehavior() throws {
        let profile = try XCTUnwrap(registry.profile(forServiceUUID: "FFE0"))

        XCTAssertEqual(profile.version, 1)
        XCTAssertEqual(profile.commandTerminator, "\r")
        XCTAssertNil(profile.maxWriteChunkBytes)
    }

    func testKnownProfileWinsBeforeUnknownInference() throws {
        let binding = try registry.resolve(
            services: [
                service("ABCD", [characteristic("A001", [.notify, .writeWithResponse])]),
                service("FFE0", [characteristic("FFE1", [.notify, .writeWithResponse])]),
            ],
            inferenceAuthorization: .explicitPeripheralSelection
        ).get()

        XCTAssertEqual(binding.profile.id, "ffe0-shared")
        XCTAssertEqual(binding.source, .known)
    }

    func testMalformedKnownProfileNeverFallsBackToUnknownService() {
        let result = registry.resolve(
            services: [
                service("FFE0", [characteristic("FFE1", [.writeWithResponse])]),
                service("ABCD", [characteristic("A001", [.notify, .writeWithResponse])]),
            ],
            inferenceAuthorization: .explicitPeripheralSelection
        )

        XCTAssertEqual(result.discoveryFailure, .unsupportedReadProperties("FFE1"))
    }

    func testDuplicateKnownServiceFailsEvenWhenOneInstanceIsValid() {
        let result = registry.resolve(
            services: [
                service("FFE0", [characteristic("FFE1", [.notify, .writeWithResponse])]),
                service("ffe0", [characteristic("FFE1", [.writeWithResponse])]),
            ],
            inferenceAuthorization: .explicitPeripheralSelection
        )

        XCTAssertEqual(result.discoveryFailure, .ambiguousServices(["FFE0", "FFE0"]))
    }

    func testUnknownInferenceRequiresExplicitOrValidatedSelection() {
        let graph = [service("ABCD", [characteristic("A001", [.notify, .writeWithResponse])])]

        XCTAssertEqual(
            registry.resolve(services: graph, inferenceAuthorization: .denied).discoveryFailure,
            .inferenceNotAuthorized
        )
    }

    func testInfersOneUnambiguousSharedCharacteristic() throws {
        let binding = try registry.resolve(
            services: [
                service("ABCD", [characteristic("A001", [.indicate, .writeWithoutResponse])]),
            ],
            inferenceAuthorization: .explicitPeripheralSelection
        ).get()

        XCTAssertEqual(binding.profile.id, BLEAdapterProfile.inferredProfileID)
        XCTAssertEqual(binding.profile.version, BLEAdapterProfile.inferredProfileVersion)
        XCTAssertEqual(binding.source, .inferred)
        XCTAssertEqual(binding.readCharacteristicUUID, "A001")
        XCTAssertEqual(binding.writeCharacteristicUUID, "A001")
        XCTAssertEqual(binding.writeType, .withoutResponse)
    }

    func testAmbiguousCharacteristicsFailClosed() {
        let result = registry.resolve(
            services: [
                service("ABCD", [
                    characteristic("A001", [.notify]),
                    characteristic("A002", [.indicate]),
                    characteristic("A003", [.writeWithResponse]),
                ]),
            ],
            inferenceAuthorization: .explicitPeripheralSelection
        )

        XCTAssertEqual(result.discoveryFailure, .ambiguousInferredCharacteristics("ABCD"))
    }

    func testCandidatesAcrossMultipleServicesFailClosed() {
        let result = registry.resolve(
            services: [
                service("ABCD", [characteristic("A001", [.notify, .writeWithResponse])]),
                service("DCBA", [characteristic("D001", [.indicate, .writeWithoutResponse])]),
            ],
            inferenceAuthorization: .validatedCache
        )

        XCTAssertEqual(result.discoveryFailure, .ambiguousServices(["ABCD", "DCBA"]))
    }

    func testFingerprintIsCanonicalAcrossOrderingAndBluetoothUUIDForms() {
        let first = BLEGATTFingerprint(services: [
            service("0000FFE0-0000-1000-8000-00805F9B34FB", [
                characteristic("FFE2", [.writeWithoutResponse]),
                characteristic("ffe1", [.notify]),
            ]),
            service("ABCD", [characteristic("B001", [.read])]),
        ])
        let reordered = BLEGATTFingerprint(services: [
            service("abcd", [characteristic("b001", [.read])]),
            service("FFE0", [
                characteristic("FFE1", [.notify]),
                characteristic("FFE2", [.writeWithoutResponse]),
            ]),
        ])

        XCTAssertEqual(first, reordered)
        XCTAssertEqual(first.canonicalValue, "ABCD[B001:1]|FFE0[FFE1:2,FFE2:8]")
    }

    private func service(
        _ uuid: String,
        _ characteristics: [BLECharacteristicDescriptor]
    ) -> BLEGATTServiceDescriptor {
        BLEGATTServiceDescriptor(uuid: uuid, characteristics: characteristics)
    }

    private func characteristic(
        _ uuid: String,
        _ capabilities: BLECharacteristicCapabilities
    ) -> BLECharacteristicDescriptor {
        BLECharacteristicDescriptor(uuid: uuid, capabilities: capabilities)
    }
}

private extension Result {
    var discoveryFailure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
