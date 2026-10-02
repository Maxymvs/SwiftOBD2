import CoreBluetooth
import XCTest
@testable import SwiftOBD2

final class BLEPeripheralDiscoveryTests: XCTestCase {
    func testServiceUUIDsMergeOverflowAndNormalizeToShortForm() {
        let advertisement: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")],
            CBAdvertisementDataOverflowServiceUUIDsKey: [CBUUID(string: "ffe0"), CBUUID(string: "FFF0")],
        ]

        XCTAssertEqual(BLEPeripheralDiscovery.serviceUUIDs(fromAdvertisement: advertisement), ["FFF0", "FFE0"])
    }

    func testServiceUUIDsAreEmptyWhenNotAdvertised() {
        XCTAssertEqual(BLEPeripheralDiscovery.serviceUUIDs(fromAdvertisement: [:]), [])
    }

    func testUnavailableRSSIBecomesUnknownSignalInsteadOfDroppingTheDiscovery() {
        XCTAssertNil(BLEPeripheralDiscovery.signalStrength(fromRSSI: 127))
        XCTAssertNil(BLEPeripheralDiscovery.signalStrength(fromRSSI: 0))
        XCTAssertEqual(BLEPeripheralDiscovery.signalStrength(fromRSSI: -67), -67)
    }

    func testSupportedServiceMatchesKnownAdapterProfiles() {
        XCTAssertTrue(BLEPeripheralDiscovery.containsSupportedService(["180A", "FFE0"], registry: .standard))
        XCTAssertTrue(BLEPeripheralDiscovery.containsSupportedService(["18F0"], registry: .standard))
        XCTAssertFalse(BLEPeripheralDiscovery.containsSupportedService(["180A", "180F"], registry: .standard))
        XCTAssertFalse(BLEPeripheralDiscovery.containsSupportedService([], registry: .standard))
    }
}
