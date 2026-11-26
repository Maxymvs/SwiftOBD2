//
//  OEMSignalDecoderTests.swift
//  SwiftOBD2Tests
//
//  One focused test per OBDb `fmt` field and per decoded-value case. Expected values are worked
//  out by hand from OBDb's reference decoder (`Scaling.decode_value`, `Enumeration.decode_value`).
//

@testable import SwiftOBD2
import XCTest

final class OEMSignalDecoderTests: XCTestCase {
    private func format(
        bix: Int = 0, len: Int = 8, blsb: Bool = false, sign: Bool = false,
        mul: Double = 1, div: Double = 1, add: Double = 0, min: Double = 0, max: Double = 255,
        nullmin: Double? = nil, nullmax: Double? = nil, map: [UInt64: String]? = nil
    ) -> OEMSignalFormat {
        OEMSignalFormat(
            bitOffset: bix, bitLength: len, isLittleEndian: blsb, isSigned: sign,
            multiplier: mul, divisor: div, offset: add, minimum: min, maximum: max, unit: "scalar",
            nullMinimum: nullmin, nullMaximum: nullmax,
            enumeration: map.map { $0.mapValues { OEMEnumerationValue(value: $0, description: nil) } }
        )
    }

    // MARK: Fields

    func testLenReadsThatManyBitsMSBFirst() throws {
        XCTAssertEqual(try format(len: 16, max: 65535).decode([0x0C, 0xE2]), .number(0x0CE2))
        XCTAssertEqual(try format(len: 4, max: 15).decode([0xAB]), .number(0xA))
        XCTAssertEqual(try format(len: 1, max: 1).decode([0x80]), .number(1))
    }

    func testBixStartsAtThatBit() throws {
        XCTAssertEqual(try format(bix: 8, len: 8).decode([0xFF, 0x2A]), .number(0x2A))
        // Not byte-aligned: bits 4...11 of 0x12 0x34 are 0x23.
        XCTAssertEqual(try format(bix: 4, len: 8).decode([0x12, 0x34]), .number(0x23))
    }

    func testBlsbReversesTheValueBytesOnlyWhenLongerThanOneByte() throws {
        XCTAssertEqual(try format(len: 16, blsb: true, max: 65535).decode([0x34, 0x12]), .number(0x1234))
        XCTAssertEqual(try format(bix: 8, len: 16, blsb: true, max: 65535).decode([0xFF, 0x34, 0x12, 0xEE]), .number(0x1234))
        // len <= 8: no reversal.
        XCTAssertEqual(try format(len: 8, blsb: true).decode([0x34, 0x12]), .number(0x34))
        // Reference quirk: ceil(len/8) bytes from bix/8 are reversed even when bix is unaligned.
        // Bytes 00 AB CD → reversed first two → AB 00 CD; bits 4...19 = B00C.
        XCTAssertEqual(try format(bix: 4, len: 16, blsb: true, max: 65535).decode([0x00, 0xAB, 0xCD]), .number(0xB00C))
    }

    func testSignIsTwosComplement() throws {
        XCTAssertEqual(try format(sign: true, min: -128, max: 127).decode([0xFF]), .number(-1))
        XCTAssertEqual(try format(len: 16, sign: true, min: -32768, max: 32767).decode([0x80, 0x00]), .number(-32768))
        XCTAssertEqual(try format(len: 4, sign: true, min: -8, max: 7).decode([0x80]), .number(-8))
        XCTAssertEqual(try format(sign: true, min: -128, max: 127).decode([0x7F]), .number(127))
        XCTAssertEqual(
            try format(len: 64, sign: true, min: -10, max: 10).decode([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE]),
            .number(-2)
        )
    }

    func testMulDivAddScaleInOBDbOrder() throws {
        // raw * mul / div + add
        XCTAssertEqual(try format(mul: 3, max: 1000).decode([10]), .number(30))
        XCTAssertEqual(try format(div: 4, max: 1000).decode([10]), .number(2.5))
        XCTAssertEqual(try format(add: -40, min: -40, max: 215).decode([100]), .number(60))
        let scaled = try format(len: 16, div: 10, add: -273.1, min: -273.1, max: 6280.4).decode([0x0C, 0xE2])
        guard case let .number(value) = scaled else { return XCTFail("\(scaled)") }
        XCTAssertEqual(value, 3298.0 / 10 - 273.1, accuracy: 1e-9)
    }

    func testMinAndMaxClampWhenMaxAboveMin() throws {
        XCTAssertEqual(try format(min: 10, max: 100).decode([5]), .outOfRange(clamped: 10))
        XCTAssertEqual(try format(min: 10, max: 100).decode([200]), .outOfRange(clamped: 100))
        // max <= min: no clamping at all (reference behavior).
        XCTAssertEqual(try format(min: 0, max: 0).decode([200]), .number(200))
    }

    func testNullMinAndNullMaxAreSentinels() throws {
        XCTAssertEqual(try format(add: -40, min: -40, max: 215, nullmin: -40).decode([0]), .null)
        XCTAssertEqual(try format(max: 255, nullmax: 255).decode([0xFF]), .null)
        XCTAssertEqual(try format(max: 255, nullmax: 255).decode([0xFE]), .number(254))
        // Null bounds apply after clamping: a value clamped onto nullmin is null, not out of range.
        XCTAssertEqual(try format(add: -50, min: -40, max: 215, nullmin: -40).decode([0]), .null)
    }

    func testMapMakesAnEnumerationIgnoringSignAndBlsb() throws {
        let map: [UInt64: String] = [3: "DRIVE", 0x8001: "WIDE"]
        XCTAssertEqual(try format(map: map).decode([3]), .text("DRIVE"))
        XCTAssertEqual(try format(len: 16, blsb: true, sign: true, map: map).decode([0x80, 0x01]), .text("WIDE"))
    }

    // MARK: Cases

    func testNumberCase() throws {
        XCTAssertEqual(try format().decode([42]), .number(42))
    }

    func testTextCase() throws {
        XCTAssertEqual(try format(map: [1: "ON"]).decode([1]), .text("ON"))
    }

    func testNullCase() throws {
        XCTAssertEqual(try format(nullmin: 0).decode([0]), .null)
    }

    func testOutOfRangeCase() throws {
        XCTAssertEqual(try format(max: 100).decode([101]), .outOfRange(clamped: 100))
    }

    func testUnmappedCase() throws {
        XCTAssertEqual(try format(map: [1: "ON"]).decode([7]), .unmapped(raw: 7))
    }

    func testPayloadTooShortThrowsForScaledAndEnumeratedSignals() {
        XCTAssertThrowsError(try format(len: 16, max: 65535).decode([0x01])) { error in
            XCTAssertEqual(error as? OEMDecodeError, .payloadTooShort(neededBits: 16, haveBits: 8))
        }
        // The reference zero-fills enumerations; this decoder refuses.
        XCTAssertThrowsError(try format(bix: 8, len: 8, map: [0: "OFF"]).decode([0x01])) { error in
            XCTAssertEqual(error as? OEMDecodeError, .payloadTooShort(neededBits: 16, haveBits: 8))
        }
        XCTAssertThrowsError(try format().decode([]))
    }
}
