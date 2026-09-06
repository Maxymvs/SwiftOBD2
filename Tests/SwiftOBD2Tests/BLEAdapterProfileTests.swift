@testable import SwiftOBD2
import XCTest

final class BLEAdapterProfileTests: XCTestCase {
    private let registry = BLEAdapterRegistry.standard

    func testStandardRegistryContainsAllExistingProfiles() {
        XCTAssertEqual(registry.serviceUUIDs, ["FFE0", "FFF0", "18F0"])
        XCTAssertEqual(registry.profile(forServiceUUID: "ffe0")?.characteristicUUIDs, ["FFE1"])
        XCTAssertEqual(registry.profile(forServiceUUID: "fff0")?.characteristicUUIDs, ["FFF1", "FFF2"])
        XCTAssertEqual(registry.profile(forServiceUUID: "18f0")?.characteristicUUIDs, ["2AF0", "2AF1"])
    }

    func testResolvesEachExistingProfileByExactGattLayout() throws {
        let fixtures: [(String, String, String)] = [
            ("FFE0", "FFE1", "FFE1"),
            ("FFF0", "FFF1", "FFF2"),
            ("18F0", "2AF0", "2AF1"),
        ]

        for (service, read, write) in fixtures {
            let characteristics: [BLECharacteristicDescriptor]
            if read == write {
                characteristics = [descriptor(read, [.notify, .writeWithResponse])]
            } else {
                characteristics = [
                    descriptor(read, [.notify]),
                    descriptor(write, [.writeWithResponse]),
                ]
            }

            let binding = try registry.resolve(
                serviceUUID: service,
                characteristics: characteristics
            ).get()
            XCTAssertEqual(binding.profile.serviceUUID, service)
            XCTAssertEqual(binding.readCharacteristicUUID, read)
            XCTAssertEqual(binding.writeCharacteristicUUID, write)
            XCTAssertEqual(binding.writeType, .withResponse)
        }
    }

    func testUnknownServiceDoesNotResolveFromMatchingPropertiesOrAdapterName() {
        let result = registry.resolve(
            serviceUUID: "ABCD",
            characteristics: [descriptor("FFE1", [.notify, .writeWithResponse])]
        )

        XCTAssertEqual(result.failure, .unsupportedService("ABCD"))
    }

    func testDisplayNameDoesNotParticipateInCompatibilityResolution() throws {
        let base = try XCTUnwrap(registry.profile(forServiceUUID: "FFE0"))
        let renamed = BLEAdapterProfile(
            id: base.id,
            displayName: "Any user-facing adapter name",
            serviceUUID: base.serviceUUID,
            readCharacteristicUUID: base.readCharacteristicUUID,
            writeCharacteristicUUID: base.writeCharacteristicUUID,
            supportedWriteTypes: base.supportedWriteTypes
        )
        let renamedRegistry = BLEAdapterRegistry(profiles: [renamed])

        let binding = try renamedRegistry.resolve(
            serviceUUID: "FFE0",
            characteristics: [descriptor("FFE1", [.notify, .writeWithResponse])]
        ).get()

        XCTAssertEqual(binding.profile.displayName, "Any user-facing adapter name")
    }

    func testMissingRequiredCharacteristicFailsResolution() {
        let result = registry.resolve(
            serviceUUID: "FFF0",
            characteristics: [descriptor("FFF1", [.notify])]
        )

        XCTAssertEqual(result.failure, .missingCharacteristic("FFF2"))
    }

    func testDuplicateRequiredCharacteristicIsAmbiguous() {
        let result = registry.resolve(
            serviceUUID: "FFF0",
            characteristics: [
                descriptor("FFF1", [.notify]),
                descriptor("FFF2", [.writeWithResponse]),
                descriptor("fff2", [.writeWithoutResponse]),
            ]
        )

        XCTAssertEqual(result.failure, .ambiguousCharacteristic("FFF2"))
    }

    func testDuplicateServiceProfilesAreAmbiguous() {
        let profile = try! XCTUnwrap(registry.profile(forServiceUUID: "FFE0"))
        let ambiguousRegistry = BLEAdapterRegistry(profiles: [profile, profile])

        let result = ambiguousRegistry.resolve(
            serviceUUID: "FFE0",
            characteristics: [descriptor("FFE1", [.notify, .writeWithResponse])]
        )

        XCTAssertEqual(result.failure, .ambiguousProfiles("FFE0"))
    }

    func testSharedCharacteristicBindsForReadAndWrite() throws {
        let binding = try registry.resolve(
            serviceUUID: "FFE0",
            characteristics: [descriptor("FFE1", [.notify, .writeWithResponse])]
        ).get()

        XCTAssertEqual(binding.readCharacteristicUUID, binding.writeCharacteristicUUID)
    }

    func testWriteWithoutResponseOnlyCharacteristicIsSupported() throws {
        let binding = try registry.resolve(
            serviceUUID: "18F0",
            characteristics: [
                descriptor("2AF0", [.notify]),
                descriptor("2AF1", [.writeWithoutResponse]),
            ]
        ).get()

        XCTAssertEqual(binding.writeType, .withoutResponse)
    }

    func testWriteWithResponseRemainsPreferredWhenBothAreAvailable() throws {
        let binding = try registry.resolve(
            serviceUUID: "FFF0",
            characteristics: [
                descriptor("FFF1", [.notify]),
                descriptor("FFF2", [.writeWithResponse, .writeWithoutResponse]),
            ]
        ).get()

        XCTAssertEqual(binding.writeType, .withResponse)
    }

    func testWriteTypeMustBeAllowedByProfileAndCharacteristic() throws {
        let standardProfile = try XCTUnwrap(registry.profile(forServiceUUID: "FFF0"))
        let responseOnlyProfile = BLEAdapterProfile(
            id: standardProfile.id,
            displayName: standardProfile.displayName,
            serviceUUID: standardProfile.serviceUUID,
            readCharacteristicUUID: standardProfile.readCharacteristicUUID,
            writeCharacteristicUUID: standardProfile.writeCharacteristicUUID,
            supportedWriteTypes: [.withResponse]
        )
        let responseOnlyRegistry = BLEAdapterRegistry(profiles: [responseOnlyProfile])

        let result = responseOnlyRegistry.resolve(
            serviceUUID: "FFF0",
            characteristics: [
                descriptor("FFF1", [.notify]),
                descriptor("FFF2", [.writeWithoutResponse]),
            ]
        )

        XCTAssertEqual(result.failure, .unsupportedWriteProperties("FFF2"))
    }

    func testRequiredReadAndWritePropertiesAreValidated() {
        XCTAssertEqual(
            registry.resolve(
                serviceUUID: "FFF0",
                characteristics: [
                    descriptor("FFF1", []),
                    descriptor("FFF2", [.writeWithResponse]),
                ]
            ).failure,
            .unsupportedReadProperties("FFF1")
        )

        XCTAssertEqual(
            registry.resolve(
                serviceUUID: "FFF0",
                characteristics: [
                    descriptor("FFF1", [.notify]),
                    descriptor("FFF2", [.read]),
                ]
            ).failure,
            .unsupportedWriteProperties("FFF2")
        )
    }

    func testReadOnlyCharacteristicDoesNotResolveWithoutAResponseDeliveryPath() {
        let result = registry.resolve(
            serviceUUID: "FFE0",
            characteristics: [descriptor("FFE1", [.read, .writeWithResponse])]
        )

        XCTAssertEqual(result.failure, .unsupportedReadProperties("FFE1"))
    }

    func testIndicationCharacteristicProvidesAResponseDeliveryPath() throws {
        let binding = try registry.resolve(
            serviceUUID: "FFE0",
            characteristics: [descriptor("FFE1", [.indicate, .writeWithResponse])]
        ).get()

        XCTAssertEqual(binding.readCharacteristicUUID, "FFE1")
    }

    func testNotificationReadinessWaitsForSubscriptionConfirmation() {
        var readiness = BLENotificationReadiness()

        readiness.begin(alreadySubscribed: false)
        XCTAssertFalse(readiness.isReady)

        readiness.update(isNotifying: true)
        XCTAssertTrue(readiness.isReady)

        readiness.reset()
        XCTAssertFalse(readiness.isReady)
    }

    func testNotificationReadinessAcceptsRestoredSubscription() {
        var readiness = BLENotificationReadiness()

        readiness.begin(alreadySubscribed: true)

        XCTAssertTrue(readiness.isReady)
    }

    private func descriptor(
        _ uuid: String,
        _ capabilities: BLECharacteristicCapabilities
    ) -> BLECharacteristicDescriptor {
        BLECharacteristicDescriptor(uuid: uuid, capabilities: capabilities)
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
