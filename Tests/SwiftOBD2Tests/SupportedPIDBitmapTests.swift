//
//  SupportedPIDBitmapTests.swift
//  SwiftOBD2Tests
//
//  `ELM327.getSupportedPIDs()` turns the "PIDs supported" bitmaps (`0100`, `0120`, `0140`, the
//  Mode 06 `06xx` and Mode 09 `0900` getters) into the commands a vehicle answers. Each bitmap
//  covers the 32 PIDs after its request's own PID (`0120` → 21–40), marks only commands of its
//  own service, and is exactly the four declared bytes: padding is never read as bits.
//

@testable import SwiftOBD2
import XCTest

final class SupportedPIDBitmapTests: XCTestCase {
    private let can11 = ISO_15765_4_11bit_500k()
    private let can29 = ISO_15765_4_29bit_500k()

    /// `0100`: BE 3F A8 13.
    private static let pids01to20: Set<UInt8> = [
        0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15, 0x1C, 0x1F, 0x20,
    ]
    /// `0120`: 80 05 B0 15.
    private static let pids21to40: Set<UInt8> = [0x21, 0x2E, 0x30, 0x31, 0x33, 0x34, 0x3C, 0x3E, 0x40]
    /// `0140`: FE D0 04 00.
    private static let pids41to60: Set<UInt8> = [0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x49, 0x4A, 0x4C, 0x56]

    /// The commands a bitmap of these PIDs marks: Mode 01 commands only, without the getters.
    private static func mode01(_ pids: Set<UInt8>) -> Set<OBDCommand> {
        Set(OBDCommand.Mode1.allCases.map { OBDCommand.mode1($0) }.filter { command in
            guard let pid = UInt8(command.properties.command.suffix(2), radix: 16) else { return false }
            return pids.contains(pid) && !OBDCommand.pidGetters.contains(command)
        })
    }

    private func supported(_ responses: [String: [String]], parser: CANProtocol? = nil) async -> Set<OBDCommand> {
        let comm = OwnershipScriptedComm(responses: responses)
        let sut = ELM327(comm: comm)
        sut.canProtocol = parser ?? can11
        return Set(await sut.getSupportedPIDs())
    }

    private func describe(_ commands: Set<OBDCommand>) -> String {
        commands.map(\.properties.command).sorted().joined(separator: " ")
    }

    // MARK: - Each range from its own base

    func testEachBitmapCoversItsOwnRange() async {
        let pids = await supported([
            "0100": ["7E8064100BE3FA813"],
            "0120": ["7E80641208005B015"],
            "0140": ["7E8064140FED00400"],
        ])
        let expected = Self.mode01(Self.pids01to20.union(Self.pids21to40).union(Self.pids41to60))
        XCTAssertEqual(pids, expected, "got \(describe(pids)), expected \(describe(expected))")
    }

    func testTheSameRangesOn29BitCAN() async {
        let pids = await supported([
            "0100": ["18DAF110064100BE3FA813"],
            "0120": ["18DAF1100641208005B015"],
            "0140": ["18DAF110064140FED00400"],
        ], parser: can29)
        let expected = Self.mode01(Self.pids01to20.union(Self.pids21to40).union(Self.pids41to60))
        XCTAssertEqual(pids, expected, "got \(describe(pids)), expected \(describe(expected))")
    }

    /// A `0120` answer alone marks 21–40, never the PIDs 01–20 at the same bit positions.
    func testA0120BitmapNeverMarksPIDsOneToTwenty() async {
        let pids = await supported(["0120": ["7E8064120FFFFFFFF"]])
        XCTAssertEqual(pids, Self.mode01(Set(0x21 ... 0x40)), describe(pids))
        XCTAssertFalse(pids.contains(.mode1(.rpm)))
    }

    // MARK: - Fuel level (012F) is bit 0F of the 0120 answer

    func testFuelLevelIsSupportedWhenBitFifteenOfThe0120AnswerIsSet() async {
        // 80 07 B0 15: byte B 0000 0111 sets bits 0E, 0F and 10 → 2E, 2F, 30.
        let pids = await supported(["0100": ["7E8064100BE3FA813"], "0120": ["7E80641208007B015"]])
        XCTAssertTrue(pids.contains(.mode1(.fuelLevel)), describe(pids))
    }

    func testFuelLevelIsNotSupportedWhenBitFifteenIsClear() async {
        // 80 05 B0 15: byte B 0000 0101 sets 2E and 30, not 2F.
        let pids = await supported(["0100": ["7E8064100BE3FA813"], "0120": ["7E80641208005B015"]])
        XCTAssertFalse(pids.contains(.mode1(.fuelLevel)), describe(pids))
        XCTAssertTrue(pids.contains(.mode1(.distanceWMIL)))
    }

    // MARK: - A bitmap marks only its own service

    func testA0100BitmapNeverMarksAMode06OrMode09Command() async {
        let pids = await supported(["0100": ["7E8064100FFFFFFFF"]])
        let foreign = pids.filter {
            if case .mode1 = $0 { return false }
            return true
        }
        XCTAssertEqual(foreign, [], "a Mode 01 bitmap marked \(describe(foreign))")
        XCTAssertFalse(pids.contains(.mode9(.VIN)))
        XCTAssertFalse(pids.contains(.mode6(.MONITOR_O2_B1S1)))
    }

    func testA0900BitmapMarksOnlyMode09Commands() async {
        // 49 00 7C 00 00 00: info types 02–06.
        let pids = await supported(["0900": ["7E80649007C000000"]])
        XCTAssertEqual(pids, [
            .mode9(.VIN), .mode9(.CALIBRATION_ID_MESSAGE_COUNT), .mode9(.CALIBRATION_ID),
            .mode9(.CVN_MESSAGE_COUNT), .mode9(.CVN),
        ], describe(pids))
    }

    func testA0620BitmapMarksMode06MIDsFromItsOwnBase() async {
        // 46 20 80 00 00 00: MID 21 only.
        let pids = await supported(["0620": ["7E80646208000000000"]])
        XCTAssertEqual(pids.map(\.properties.command), ["0621"], describe(pids))
    }

    // MARK: - Only the four declared bytes

    /// The FF after the declared four bytes is padding: it must not mark 41–48.
    func testPaddingAfterTheDeclaredBitmapIsNeverRead() async {
        for padding in ["FF", "AA", "55", "00"] {
            let pids = await supported(["0120": ["7E80641208007B015" + padding]])
            XCTAssertEqual(pids, Self.mode01([0x21, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x3C, 0x3E, 0x40]),
                           "\(padding): \(describe(pids))")
        }
    }

    /// A reply declaring only three bitmap bytes is no bitmap, whatever follows it.
    func testABitmapShorterThanFourBytesMarksNothing() async {
        let pids = await supported(["0100": ["7E8054100BE3FA8FF"]])
        XCTAssertEqual(pids, [], describe(pids))
    }

    // MARK: - extractSupportedPIDs

    func testExtractSupportedPIDsNumbersFromItsBase() {
        let elm = ELM327(comm: OwnershipScriptedComm(responses: [:]))
        let bits = BitArray(data: Data([0x80, 0x00, 0x00, 0x01])).binaryArray
        XCTAssertEqual(elm.extractSupportedPIDs(bits), ["01", "20"])
        XCTAssertEqual(elm.extractSupportedPIDs(bits, base: 0x20), ["21", "40"])
        XCTAssertEqual(elm.extractSupportedPIDs(bits, base: 0xE0), ["E1"], "nothing past FF")
    }
}
