//
//  ISOTPDeclaredLengthTests.swift
//  SwiftOBD2Tests
//
//  A CAN frame is eight bytes on the bus whatever its payload; the ISO-TP PCI says how many of
//  them are the message. Everything after the declared length is padding, and padding must never
//  be read as a measurement: `7E8 02 41 0D 00 00 00 00 00` answers 010D with no value at all,
//  not 0 km/h.
//

@testable import SwiftOBD2
import XCTest

final class ISOTPDeclaredLengthTests: XCTestCase {
    private let can11 = ISO_15765_4_11bit_500k()
    private let can29 = ISO_15765_4_29bit_500k()

    private func speed(_ results: [OBDCommand: MeasurementResult]?) -> Double? {
        results?[.mode1(.speed)]?.value
    }

    private func rpm(_ results: [OBDCommand: MeasurementResult]?) -> Double? {
        results?[.mode1(.rpm)]?.value
    }

    private func data(_ line: String, parser: CANProtocol) throws -> [UInt8]? {
        try parser.parse([line]).first?.data.map { Array($0) }
    }

    // MARK: - The parser

    func testSingleFrameDataStopsAtTheDeclaredLength() throws {
        XCTAssertEqual(try data("7E8 02 41 0D 00 00 00 00 00", parser: can11), [0x0D])
        XCTAssertEqual(try data("7E8 03 41 0D 00 00 00 00 00", parser: can11), [0x0D, 0x00])
        XCTAssertEqual(try data("7E8 04 41 0C 1F 40 AA AA AA", parser: can11), [0x0C, 0x1F, 0x40])
        XCTAssertEqual(try data("18DAF110 02 41 0D 00 00 00 00 00", parser: can29), [0x0D])
    }

    /// The adapter's usual CAN auto-formatting drops the padding: same bytes either way.
    func testSingleFrameWithoutPaddingIsUnchanged() throws {
        XCTAssertEqual(try data("7E8 03 41 0D 1F", parser: can11), [0x0D, 0x1F])
        XCTAssertEqual(try data("7E8 06 41 00 BE 3F A8 13", parser: can11), [0x00, 0xBE, 0x3F, 0xA8, 0x13])
    }

    /// A single frame that declares only the service byte carries no data after it.
    func testSingleFrameDeclaringOnlyTheServiceHasNoData() throws {
        XCTAssertEqual(try data("7E8 01 44 00 00 00 00 00 00", parser: can11), [])
    }

    /// The multi-frame path already stops at the declared length: a padded last frame keeps
    /// exactly the declared bytes (18 = 49 02 01 + 15), never its padding.
    func testMultiFrameDataStopsAtTheDeclaredLength() throws {
        let lines = [
            "7E8 10 12 49 02 01 41 41 41",
            "7E8 21 41 41 41 41 41 41 41",
            "7E8 22 41 41 41 41 41 AA AA",
        ]
        let parsed = try can11.parse(lines).first?.data.map { Array($0) }
        // 18 declared bytes minus the service byte.
        XCTAssertEqual(parsed?.count, 17)
        XCTAssertEqual(parsed?.prefix(2), [0x02, 0x01])
        XCTAssertFalse(parsed?.contains(0xAA) ?? true)
    }

    // MARK: - (1) `41 0D` with no value byte

    /// A request for one PID: the padding byte after `41 0D` used to decode as 0 km/h.
    func testPaddedSpeedWithoutAValueGivesNoSpeedForOnePID() throws {
        let results = try OBDService.decodePIDResponse(
            ["7E8 02 41 0D 00 00 00 00 00"], commands: [.mode1(.speed)], parser: can11, unit: .metric
        )
        XCTAssertNotNil(results, "the reply is still a positive Mode 01 response")
        XCTAssertNil(speed(results), "padding is not a measurement")
    }

    /// The same reply to a batched request: nothing decodes for either PID.
    func testPaddedSpeedWithoutAValueGivesNoSpeedForABatch() throws {
        let results = try OBDService.decodePIDResponse(
            ["7E8 02 41 0D 00 00 00 00 00"], commands: [.mode1(.rpm), .mode1(.speed)], parser: can11, unit: .metric
        )
        XCTAssertNil(speed(results))
        XCTAssertNil(rpm(results))
    }

    func testPaddedSpeedWithoutAValueGivesNoSpeedOn29Bit() throws {
        let results = try OBDService.decodePIDResponse(
            ["18DAF110 02 41 0D 00 00 00 00 00"], commands: [.mode1(.speed)], parser: can29, unit: .metric
        )
        XCTAssertNil(speed(results))
    }

    // MARK: - (2) a real 0 km/h

    func testDeclaredZeroSpeedStillDecodesForOnePID() throws {
        let results = try OBDService.decodePIDResponse(
            ["7E8 03 41 0D 00 00 00 00 00"], commands: [.mode1(.speed)], parser: can11, unit: .metric
        )
        XCTAssertEqual(speed(results), 0)
    }

    func testDeclaredZeroSpeedStillDecodesInABatch() throws {
        let results = try OBDService.decodePIDResponse(
            ["7E8 06 41 0C 1F 40 0D 00 00"], commands: [.mode1(.rpm), .mode1(.speed)], parser: can11, unit: .metric
        )
        XCTAssertEqual(rpm(results), 2000)
        XCTAssertEqual(speed(results), 0)
    }

    // MARK: - (3) a batch cut short by its declared length

    /// `05` declares `41 0C 1F 40 0D`: the `1F` after it is padding-position garbage, so speed
    /// has no value while rpm, before it, decodes in full.
    func testBatchCutShortByTheDeclaredLengthDecodesOnlyWhatItDeclared() throws {
        let results = try OBDService.decodePIDResponse(
            ["7E8 05 41 0C 1F 40 0D 1F 00"], commands: [.mode1(.rpm), .mode1(.speed)], parser: can11, unit: .metric
        )
        XCTAssertEqual(rpm(results), 2000)
        XCTAssertNil(speed(results), "the speed byte is past the declared length")
    }

    /// A two-byte value cut to one: rpm needs `1F 40`, the frame declares only `1F`.
    func testBatchWhoseLastValueIsCutMidwayGivesNoValueForIt() throws {
        let results = try OBDService.decodePIDResponse(
            ["7E8 05 41 0D 1F 0C 1F 40 00"], commands: [.mode1(.speed), .mode1(.rpm)], parser: can11, unit: .metric
        )
        XCTAssertEqual(speed(results), 31)
        XCTAssertNil(rpm(results))
    }

    // MARK: - ELM327 single-PID consumers

    /// `41 01` with no status bytes: the padding used to decode as "MIL off, no codes".
    func testPaddedStatusWithoutBytesIsNoStatus() async throws {
        let comm = OwnershipScriptedComm(responses: ["0101": ["7E8 02 41 01 00 00 00 00 00"]])
        let sut = ELM327(comm: comm)
        sut.canProtocol = can11
        let result = try await sut.getStatus()
        if case .success = result {
            XCTFail("padding must not decode as a monitor status: \(result)")
        }
    }

    func testPaddedSupportedPIDBitmapReadsOnlyTheDeclaredBitmap() async {
        // Declared: 41 00 + 4 bitmap bytes. The trailing FF is past the declared length.
        let comm = OwnershipScriptedComm(responses: ["0100": ["7E8 06 41 00 00 00 00 01 FF"]])
        let sut = ELM327(comm: comm)
        sut.canProtocol = can11
        let pids = await sut.getSupportedPIDs()
        // Bit 32 (0120) is the only one set, and pid getters are filtered out.
        XCTAssertEqual(pids, [])
    }

    // MARK: - sendCommand(_:) (one command, decoded on its own)

    /// The single-command path used to drop the PID twice, so even a correct reply lost its
    /// value byte, and a padded one read padding. It now decodes exactly the declared value.
    func testSingleCommandDecodesItsDeclaredValue() throws {
        for line in ["7E8 03 41 0D 1F", "7E8 03 41 0D 1F AA AA AA AA"] {
            let result = try OBDService.decodeCommandResponse([line], command: .mode1(.speed), parser: can11)
            guard case let .success(.measurementResult(measurement)) = result else {
                XCTFail("expected a speed from \(line): \(result)")
                continue
            }
            XCTAssertEqual(measurement.value, 31, line)
        }
    }

    func testSingleCommandWithPaddingButNoValueIsNoData() throws {
        for line in ["7E8 02 41 0D 00 00 00 00 00", "7E8 02 41 0D", "7E8 03 41 0C 1F 00 00 00 00"] {
            let command: OBDCommand = line.contains("41 0C") ? .mode1(.rpm) : .mode1(.speed)
            let result = try OBDService.decodeCommandResponse([line], command: command, parser: can11)
            guard case .failure(.noData) = result else {
                XCTFail("a reply that declares no (whole) value must not decode: \(line) gave \(result)")
                continue
            }
        }
    }
}
