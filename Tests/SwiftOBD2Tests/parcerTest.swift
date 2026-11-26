//
//  parcerTest.swift
//  SMARTOBD2Tests
//
//  Created by kemo konteh on 2/8/24.
//

@testable import SwiftOBD2
import XCTest

final class OBDParcerTest: XCTestCase {
    // The `49 02` frames below encode the synthetic VIN 1N4SYNTH6D0000001 (check digit derived in
    // DTCScanPhase3Tests.testUnsupportedCacheIsPopulatedOnlyByServiceNotSupported).
//    func testOBDParcer() {
//        let responses: [[String]] = [["7E8 06 41 00 BE 3F A8 13 00"],
//                                     ["7E8 06 41 00 FF 00 00 00 00"],
//                                     ["7E8 10 14 49 02 01 31 4E 34 ", "7E8 21 53 59 4E 54 48 36 44 ", "7E8 22 30 30 30 30 30 30 31 "]]
//        measure {
//            for response in responses {
//                // Setup
//                let obdParcer = OBDParcer(response, idBits: 11)
//                // Verify
//                XCTAssertNotNil(obdParcer)
//                XCTAssertNotNil(obdParcer?.messages.first?.data)
//            }
//        }
//    }

    func testSingleFrameInitialization() {
        // Setup
        let rawFrameString = ["7E8 06 41 00 BE 3F A8 13 00"]
            .compactMap { $0.replacingOccurrences(of: " ", with: "") }
            .filter(\.isHex)
        let frameType = FrameType.singleFrame
        let frame = try? Frame(raw: rawFrameString[0], idBits: 11)

        // Verify
        XCTAssertEqual(frame?.type, frameType)
        // Add additional assertions based on your expected frame initialization
    }

    func testMultiFrameInitialization() {
        // Setup
        let rawFrameString = ["7E8 10 3E 00 00 00 00 00 00"]

            .compactMap { $0.replacingOccurrences(of: " ", with: "") }
            .filter(\.isHex)

        let frameType = FrameType.firstFrame
        let frame = try? Frame(raw: rawFrameString[0], idBits: 11)

        // Verify
        XCTAssertEqual(frame?.type, frameType)
    }

    func testMessageInitialization() {
        // Setup
        let rawFrameString = ["7E8 06 41 00 BE 3F A8 13 00"]
            .compactMap { $0.replacingOccurrences(of: " ", with: "") }
            .filter(\.isHex)
        guard let frame = try? Frame(raw: rawFrameString[0], idBits: 11) else {
            XCTFail("Failed to initialize frame")
            return
        }
        let message = try? Message(frames: [frame])

        // Verify
        XCTAssertNotNil(message)
        XCTAssertNotNil(message?.data)
    }
}
