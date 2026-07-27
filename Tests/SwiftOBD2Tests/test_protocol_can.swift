//
//  test_protocol_can.swift
//
//
//  Created by kemo konteh on 5/15/24.
//
@testable import SwiftOBD2
import XCTest

let CAN_11_PROTOCOLS: [CANProtocol] = [
    ISO_15765_4_11bit_500k(),
    ISO_15765_4_11bit_250K(),
]

let CAN_29_PROTOCOLS: [CANProtocol] = [
    ISO_15765_4_29bit_500k(),
    ISO_15765_4_29bit_250k(),
]

final class test_protocol_can: XCTestCase {
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func test_single_frame() {
        for canprotocol in CAN_11_PROTOCOLS {
            var data = try? canprotocol.parse(["7E8 06 41 00 00 01 02 03"]).first?.data
            XCTAssertNotNil(data)
            XCTAssertEqual(data, Data([0x00, 0x00, 0x01, 0x02, 0x03]))

            // minimum valid length
            data = try? canprotocol.parse(["7E8 01 41"]).first?.data
            XCTAssertNotNil(data)

            // to short
            data = try? canprotocol.parse(["7E8 01"]).first?.data

            XCTAssertNil(data)

            // to long
        }
    }

    /// The 29-bit classes used to pass `idBits: 11`, which shifted every byte boundary of a
    /// 4-byte header and made `Frame.init` throw — so *nothing* parsed on a 29-bit vehicle,
    /// including the `0100` response vehicle setup depends on.
    func test_single_frame_29bit() {
        for canprotocol in CAN_29_PROTOCOLS {
            var data = try? canprotocol.parse(["18 DA F1 10 06 41 00 00 01 02 03"]).first?.data
            XCTAssertNotNil(data)
            XCTAssertEqual(data, Data([0x00, 0x00, 0x01, 0x02, 0x03]))

            // Multi-frame ISO-TP assembles the same way as on 11-bit.
            data = try? canprotocol.parse([
                "18 DA F1 10 10 08 43 03 01 04",
                "18 DA F1 10 21 05 00 01 15 00",
            ]).first?.data
            XCTAssertNotNil(data)

            // NOTE: this generic parser still groups responders by the lossy `ECUID` (low three
            // address bits), so two 29-bit modules can collapse onto one key — the multi-ECU
            // collapse is fixed in the DTC report path, not here.

            // Too short to carry a 29-bit header plus a frame.
            data = try? canprotocol.parse(["18 DA F1 10"]).first?.data
            XCTAssertNil(data)
        }
    }
}
