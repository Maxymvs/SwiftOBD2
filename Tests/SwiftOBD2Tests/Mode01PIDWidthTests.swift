//
//  Mode01PIDWidthTests.swift
//  SwiftOBD2Tests
//
//  Every Mode 01 PID's response width, checked against SAE J1979 / ISO 15031-5 through the
//  same decode paths the app uses (`OBDService.requestPIDs` → `decodePIDResponse`, and the
//  single-command `sendCommand(_:)` → `decodeCommandResponse`).
//
//  Since the CAN parser stops a frame's data at its ISO-TP declared length, a table width
//  larger than J1979 leaves a valid reply with no value (`7E8 03 41 2F 80`, fuel level ≈ 50 %,
//  read as nothing while the table said 012F was four bytes), and a width smaller than J1979
//  hands the decoder too few bytes. The width table below is written from the spec, not
//  derived from `commands.swift`, so it is an independent statement of what each PID returns.
//

@testable import SwiftOBD2
import XCTest

final class Mode01PIDWidthTests: XCTestCase {
    private let can11 = ISO_15765_4_11bit_500k()
    private let can29 = ISO_15765_4_29bit_500k()

    // MARK: - SAE J1979 (ISO 15031-5) Mode 01 data bytes

    /// One PID's J1979 definition: the data bytes after `41 PP`, and, for a PID that reports a
    /// measurement, the J1979 formula over those bytes and its unit.
    private struct Spec {
        let dataBytes: Int
        let value: (([Double]) -> Double)?
        let unit: Unit?

        init(_ dataBytes: Int, _ unit: Unit? = nil, _ value: (([Double]) -> Double)? = nil) {
            self.dataBytes = dataBytes
            self.unit = unit
            self.value = value
        }
    }

    private static func word(_ d: [Double], _ high: Int = 0) -> Double { d[high] * 256 + d[high + 1] }
    private static let percent: ([Double]) -> Double = { $0[0] * 100 / 255 }
    private static let trim: ([Double]) -> Double = { ($0[0] - 128) * 100 / 128 }
    private static let temperature: ([Double]) -> Double = { $0[0] - 40 }

    /// PID → J1979 data bytes (A, B, C, D) and formula. PIDs 06–09 and 55–58 may carry a second
    /// byte (bank 3/4) only when that bank exists, so their minimum, one byte, is listed.
    private static let j1979: [UInt8: Spec] = [
        0x00: Spec(4), // PIDs supported 01–20 (bitmap)
        0x01: Spec(4), // monitor status since DTCs cleared
        0x02: Spec(2), // DTC that caused the freeze frame
        0x03: Spec(2), // fuel system status (system 1, system 2)
        0x04: Spec(1, Unit.percent, percent),
        0x05: Spec(1, UnitTemperature.celsius, temperature),
        0x06: Spec(1, Unit.percent, trim),
        0x07: Spec(1, Unit.percent, trim),
        0x08: Spec(1, Unit.percent, trim),
        0x09: Spec(1, Unit.percent, trim),
        0x0A: Spec(1, UnitPressure.kilopascals) { $0[0] * 3 },
        0x0B: Spec(1, UnitPressure.kilopascals) { $0[0] },
        0x0C: Spec(2, Unit.rpm) { word($0) / 4 },
        0x0D: Spec(1, UnitSpeed.kilometersPerHour) { $0[0] },
        0x0E: Spec(1, UnitAngle.degrees) { $0[0] / 2 - 64 },
        0x0F: Spec(1, UnitTemperature.celsius, temperature),
        0x10: Spec(2, Unit.gramsPerSecond) { word($0) / 100 },
        0x11: Spec(1, Unit.percent, percent),
        0x12: Spec(1), // commanded secondary air status (bit-encoded state)
        0x13: Spec(1), // oxygen sensors present, two banks
        0x14: Spec(2, UnitElectricPotentialDifference.volts) { $0[0] / 200 },
        0x15: Spec(2, UnitElectricPotentialDifference.volts) { $0[0] / 200 },
        0x16: Spec(2, UnitElectricPotentialDifference.volts) { $0[0] / 200 },
        0x17: Spec(2, UnitElectricPotentialDifference.volts) { $0[0] / 200 },
        0x18: Spec(2, UnitElectricPotentialDifference.volts) { $0[0] / 200 },
        0x19: Spec(2, UnitElectricPotentialDifference.volts) { $0[0] / 200 },
        0x1A: Spec(2, UnitElectricPotentialDifference.volts) { $0[0] / 200 },
        0x1B: Spec(2, UnitElectricPotentialDifference.volts) { $0[0] / 200 },
        0x1C: Spec(1), // OBD standards this vehicle conforms to
        0x1D: Spec(1), // oxygen sensors present, four banks
        0x1E: Spec(1), // auxiliary input status
        0x1F: Spec(2, UnitDuration.seconds) { word($0) },
        0x20: Spec(4), // PIDs supported 21–40
        0x21: Spec(2, UnitLength.kilometers) { word($0) },
        0x22: Spec(2, UnitPressure.kilopascals) { word($0) * 0.079 },
        0x23: Spec(2, UnitPressure.kilopascals) { word($0) * 10 },
        // Wide-range O2 sensors: AB equivalence ratio, CD voltage (8 / 65536 V per bit).
        0x24: Spec(4, UnitElectricPotentialDifference.volts) { word($0, 2) * 8 / 65536 },
        0x25: Spec(4, UnitElectricPotentialDifference.volts) { word($0, 2) * 8 / 65536 },
        0x26: Spec(4, UnitElectricPotentialDifference.volts) { word($0, 2) * 8 / 65536 },
        0x27: Spec(4, UnitElectricPotentialDifference.volts) { word($0, 2) * 8 / 65536 },
        0x28: Spec(4, UnitElectricPotentialDifference.volts) { word($0, 2) * 8 / 65536 },
        0x29: Spec(4, UnitElectricPotentialDifference.volts) { word($0, 2) * 8 / 65536 },
        0x2A: Spec(4, UnitElectricPotentialDifference.volts) { word($0, 2) * 8 / 65536 },
        0x2B: Spec(4, UnitElectricPotentialDifference.volts) { word($0, 2) * 8 / 65536 },
        0x2C: Spec(1, Unit.percent, percent),
        0x2D: Spec(1, Unit.percent, trim),
        0x2E: Spec(1, Unit.percent, percent),
        0x2F: Spec(1, Unit.percent, percent),
        0x30: Spec(1, Unit.count) { $0[0] },
        0x31: Spec(2, UnitLength.kilometers) { word($0) },
        // Signed two's complement, 0.25 Pa per bit.
        0x32: Spec(2, Unit.Pascal) { Double(Int16(bitPattern: UInt16($0[0]) << 8 | UInt16($0[1]))) / 4 },
        0x33: Spec(1, UnitPressure.kilopascals) { $0[0] },
        // Wide-range O2 sensors: AB equivalence ratio, CD current ((256C + D) / 256 − 128 mA).
        0x34: Spec(4, UnitElectricCurrent.milliamperes) { word($0, 2) / 256 - 128 },
        0x35: Spec(4, UnitElectricCurrent.milliamperes) { word($0, 2) / 256 - 128 },
        0x36: Spec(4, UnitElectricCurrent.milliamperes) { word($0, 2) / 256 - 128 },
        0x37: Spec(4, UnitElectricCurrent.milliamperes) { word($0, 2) / 256 - 128 },
        0x38: Spec(4, UnitElectricCurrent.milliamperes) { word($0, 2) / 256 - 128 },
        0x39: Spec(4, UnitElectricCurrent.milliamperes) { word($0, 2) / 256 - 128 },
        0x3A: Spec(4, UnitElectricCurrent.milliamperes) { word($0, 2) / 256 - 128 },
        0x3B: Spec(4, UnitElectricCurrent.milliamperes) { word($0, 2) / 256 - 128 },
        0x3C: Spec(2, UnitTemperature.celsius) { word($0) / 10 - 40 },
        0x3D: Spec(2, UnitTemperature.celsius) { word($0) / 10 - 40 },
        0x3E: Spec(2, UnitTemperature.celsius) { word($0) / 10 - 40 },
        0x3F: Spec(2, UnitTemperature.celsius) { word($0) / 10 - 40 },
        0x40: Spec(4), // PIDs supported 41–60
        0x41: Spec(4), // monitor status this drive cycle
        0x42: Spec(2, UnitElectricPotentialDifference.volts) { word($0) / 1000 },
        0x43: Spec(2, Unit.percent) { word($0) * 100 / 255 },
        0x44: Spec(2, Unit.ratio) { word($0) * 2 / 65536 },
        0x45: Spec(1, Unit.percent, percent),
        0x46: Spec(1, UnitTemperature.celsius, temperature),
        0x47: Spec(1, Unit.percent, percent),
        0x48: Spec(1, Unit.percent, percent),
        0x49: Spec(1, Unit.percent, percent),
        0x4A: Spec(1, Unit.percent, percent),
        0x4B: Spec(1, Unit.percent, percent),
        0x4C: Spec(1, Unit.percent, percent),
        0x4D: Spec(2, UnitDuration.minutes) { word($0) },
        0x4E: Spec(2, UnitDuration.minutes) { word($0) },
        0x4F: Spec(4), // maximum equivalence ratio, O2 voltage, O2 current, manifold pressure
        0x50: Spec(4, Unit.gramsPerSecond) { $0[0] * 10 }, // B, C, D reserved
        0x51: Spec(1), // fuel type
        0x52: Spec(1, Unit.percent, percent),
        0x53: Spec(2, UnitPressure.kilopascals) { word($0) / 200 },
        0x54: Spec(2, Unit.Pascal) { bytes in
            let unsigned = word(bytes)
            return unsigned < 32768 ? unsigned : unsigned - 65536
        },
        0x55: Spec(1, Unit.percent, trim),
        0x56: Spec(1, Unit.percent, trim),
        0x57: Spec(1, Unit.percent, trim),
        0x58: Spec(1, Unit.percent, trim),
        0x59: Spec(2, UnitPressure.kilopascals) { word($0) * 10 },
        0x5A: Spec(1, Unit.percent, percent),
        0x5B: Spec(1, Unit.percent, percent),
        0x5C: Spec(1, UnitTemperature.celsius, temperature),
        0x5D: Spec(2, UnitAngle.degrees) { word($0) / 128 - 210 },
        0x5E: Spec(2, Unit(symbol: "L/h")) { word($0) / 20 },
        0x5F: Spec(1), // emission requirements the vehicle is designed to
    ]

    /// Data bytes that are a defined value for every PID: one state bit for the bit-encoded
    /// states, a table index for the enumerations, a real code for the freeze-frame DTC.
    private static func sampleData(pid: UInt8, count: Int) -> [UInt8] {
        switch pid {
        case 0x02: return [0x01, 0x33] // P0133
        case 0x03: return [0x02, 0x00] // closed loop
        case 0x12: return [0x04]
        case 0x1C, 0x51: return [0x01]
        default: return Array([0x12, 0x34, 0x56, 0x78].prefix(count))
        }
    }

    // MARK: - Frames as the adapter prints them (headers on, spaces off)

    private static let paddings: [UInt8?] = [nil, 0xAA, 0x00, 0x55]

    /// `<header><PCI> 41 <pid> <data>`, padded to the full eight CAN bytes when asked.
    private func line(pid: UInt8, data: [UInt8], padding: UInt8? = nil, header: String = "7E8") -> String {
        var bytes: [UInt8] = [UInt8(2 + data.count), 0x41, pid] + data
        if let padding {
            while bytes.count < 8 { bytes.append(padding) }
        }
        return header + bytes.map { String(format: "%02X", $0) }.joined()
    }

    private func pid(of command: OBDCommand.Mode1) -> UInt8 {
        UInt8(command.properties.command.suffix(2), radix: 16)!
    }

    /// The requestPIDs path, asked for this one PID (the app's poll shape).
    private func polled(_ line: String, _ command: OBDCommand, parser: CANProtocol? = nil) throws -> MeasurementResult? {
        try OBDService.decodePIDResponse([line], commands: [command], parser: parser ?? can11, unit: .metric)?[command]
    }

    /// The single-command path.
    private func single(_ line: String, _ command: OBDCommand, parser: CANProtocol? = nil) throws -> Result<DecodeResult, DecodeError> {
        try OBDService.decodeCommandResponse([line], command: command, parser: parser ?? can11)
    }

    private func isNoData(_ result: Result<DecodeResult, DecodeError>) -> Bool {
        if case .failure(.noData) = result { return true }
        return false
    }

    private func accuracy(_ expected: Double) -> Double { max(0.001, abs(expected) * 1e-4) }

    // MARK: - The app's poll PIDs, one test each

    /// One poll PID: every padding, 11- and 29-bit, through both decode paths.
    private func assertPollPID(
        _ command: OBDCommand.Mode1, data: [UInt8], value expected: Double, unit: Unit,
        file: StaticString = #filePath, line testLine: UInt = #line
    ) throws {
        let pid = pid(of: command)
        for (header, parser) in [("7E8", can11 as CANProtocol), ("18DAF110", can29 as CANProtocol)] {
            for padding in Self.paddings {
                let frame = line(pid: pid, data: data, padding: padding, header: header)
                let polledValue = try polled(frame, .mode1(command), parser: parser)
                XCTAssertNotNil(polledValue, "\(frame) gave no reading", file: file, line: testLine)
                if let polledValue {
                    XCTAssertEqual(polledValue.value, expected, accuracy: 0.001, frame, file: file, line: testLine)
                    XCTAssertEqual(polledValue.unit.symbol, unit.symbol, frame, file: file, line: testLine)
                }
                guard case let .success(.measurementResult(singleValue)) = try single(frame, .mode1(command), parser: parser) else {
                    XCTFail("\(frame) gave no reading on the single-command path", file: file, line: testLine)
                    continue
                }
                XCTAssertEqual(singleValue.value, expected, accuracy: 0.001, frame, file: file, line: testLine)
                XCTAssertEqual(singleValue.unit.symbol, unit.symbol, frame, file: file, line: testLine)
            }
        }
    }

    /// The regression as reported: `7E8 03 41 2F 80` is a valid fuel level of 128 / 255.
    func testFuelLevelReplyAsReportedReadsFiftyPercent() throws {
        let reading = try polled("7E803412F80", .mode1(.fuelLevel))
        XCTAssertEqual(try XCTUnwrap(reading, "a valid 012F reply gave no reading").value, 50.196, accuracy: 0.001)
        XCTAssertEqual(reading?.unit.symbol, "%")
    }

    func testPollFuelLevel() throws {
        try assertPollPID(.fuelLevel, data: [0x80], value: 50.196, unit: Unit.percent)
    }

    func testPollEngineSpeed() throws {
        // 0x1AF8 / 4
        try assertPollPID(.rpm, data: [0x1A, 0xF8], value: 1726, unit: Unit.rpm)
    }

    func testPollVehicleSpeed() throws {
        try assertPollPID(.speed, data: [0x32], value: 50, unit: UnitSpeed.kilometersPerHour)
    }

    func testPollCoolantTemperature() throws {
        try assertPollPID(.coolantTemp, data: [0x7B], value: 83, unit: UnitTemperature.celsius)
    }

    func testPollEngineLoad() throws {
        try assertPollPID(.engineLoad, data: [0x80], value: 50.196, unit: Unit.percent)
    }

    func testPollThrottlePosition() throws {
        // 51 / 255
        try assertPollPID(.throttlePos, data: [0x33], value: 20, unit: Unit.percent)
    }

    /// Each poll PID one data byte short gives no reading, padded or not, on both paths.
    func testPollPIDsOneByteShortGiveNoReading() throws {
        let polls: [(OBDCommand.Mode1, [UInt8])] = [
            (.rpm, [0x1A]), (.speed, []), (.coolantTemp, []), (.engineLoad, []), (.throttlePos, []), (.fuelLevel, []),
        ]
        for (command, short) in polls {
            for padding in Self.paddings {
                let frame = line(pid: pid(of: command), data: short, padding: padding)
                XCTAssertNil(try polled(frame, .mode1(command)), frame)
                XCTAssertTrue(isNoData(try single(frame, .mode1(command))), frame)
            }
        }
    }

    // MARK: - Batched reply for the poll PIDs

    /// The app requests one PID at a time, but `requestPIDs` takes a batch: all six poll PIDs in
    /// one request come back as one multi-frame `41` reply, in request order.
    func testAllPollPIDsInOneBatchedMultiFrameReply() throws {
        let commands: [OBDCommand] = [
            .mode1(.rpm), .mode1(.speed), .mode1(.coolantTemp), .mode1(.engineLoad), .mode1(.throttlePos), .mode1(.fuelLevel),
        ]
        // 41 0C 1A F8 0D 32 05 7B 04 80 11 33 2F 80: 14 bytes.
        for padding in ["", "AAAAAAAAAAAA", "000000000000", "555555555555"] {
            let lines = ["7E8100E410C1AF80D32", "7E821057B048011332F", "7E82280" + padding]
            let results = try XCTUnwrap(
                OBDService.decodePIDResponse(lines, commands: commands, parser: can11, unit: .metric), "\(lines)"
            )
            XCTAssertEqual(results[.mode1(.rpm)]?.value ?? -1, 1726, accuracy: 0.001)
            XCTAssertEqual(results[.mode1(.speed)]?.value, 50)
            XCTAssertEqual(results[.mode1(.coolantTemp)]?.value, 83)
            XCTAssertEqual(results[.mode1(.engineLoad)]?.value ?? -1, 50.196, accuracy: 0.001)
            XCTAssertEqual(results[.mode1(.throttlePos)]?.value ?? -1, 20, accuracy: 0.001)
            XCTAssertEqual(results[.mode1(.fuelLevel)]?.value ?? -1, 50.196, accuracy: 0.001, "\(lines)")
        }
    }

    /// A single-frame batch whose declared length stops before the last value: the PIDs before
    /// it decode, the last gives no reading (the `80` after `2F` is past the declared length).
    func testBatchedSingleFrameStopsAtTheDeclaredLength() throws {
        // 06 declares 41 0D 32 05 7B 2F.
        let results = try XCTUnwrap(OBDService.decodePIDResponse(
            ["7E806410D32057B2F80"], commands: [.mode1(.speed), .mode1(.coolantTemp), .mode1(.fuelLevel)],
            parser: can11, unit: .metric
        ))
        XCTAssertEqual(results[.mode1(.speed)]?.value, 50)
        XCTAssertEqual(results[.mode1(.coolantTemp)]?.value, 83)
        XCTAssertNil(results[.mode1(.fuelLevel)], "the fuel level byte is past the declared length")
    }

    // MARK: - The whole Mode 01 table against J1979

    /// Every Mode 01 PID in the table has a J1979 entry, and its width is the echoed PID plus
    /// exactly the J1979 data bytes.
    func testEveryMode01WidthIsThePIDPlusItsJ1979DataBytes() {
        var mismatches: [String] = []
        for command in OBDCommand.Mode1.allCases {
            let pid = pid(of: command)
            guard let spec = Self.j1979[pid] else {
                mismatches.append("\(command.properties.command): no J1979 entry in this test")
                continue
            }
            if command.properties.bytes != 1 + spec.dataBytes {
                mismatches.append("\(command.properties.command) \(command.properties.description): "
                    + "table \(command.properties.bytes), J1979 1 + \(spec.dataBytes)")
            }
        }
        XCTAssertEqual(mismatches, [], mismatches.joined(separator: "\n"))
    }

    /// For every Mode 01 PID: a reply sized exactly per J1979 decodes (to the J1979 value and
    /// unit, for a measurement) and decodes the same with any padding after it; a reply that
    /// declares one data byte fewer gives none, padded or not, on both decode paths.
    func testEveryMode01PIDDecodesAtItsJ1979WidthAndNotOneByteShort() throws {
        for command in OBDCommand.Mode1.allCases {
            let pid = pid(of: command)
            let name = "\(command.properties.command) \(command.properties.description)"
            guard let spec = Self.j1979[pid] else {
                XCTFail("\(name): no J1979 entry in this test")
                continue
            }
            let data = Self.sampleData(pid: pid, count: spec.dataBytes)
            let hasDecoder = command.properties.decoder.getDecoder() != nil

            for padding in Self.paddings {
                let exact = line(pid: pid, data: data, padding: padding)
                let singleResult = try single(exact, .mode1(command))
                XCTAssertFalse(isNoData(singleResult), "\(name): \(exact) was refused as too short")

                if let formula = spec.value, let unit = spec.unit {
                    let expected = formula(data.map(Double.init))
                    let polledValue = try polled(exact, .mode1(command))
                    XCTAssertNotNil(polledValue, "\(name): \(exact) gave no reading")
                    if let polledValue {
                        XCTAssertEqual(polledValue.value, expected, accuracy: accuracy(expected), "\(name): \(exact)")
                        XCTAssertEqual(polledValue.unit.symbol, unit.symbol, "\(name): \(exact)")
                    }
                    if case let .success(.measurementResult(singleValue)) = singleResult {
                        XCTAssertEqual(singleValue.value, expected, accuracy: accuracy(expected), "\(name): \(exact)")
                    } else {
                        XCTFail("\(name): \(exact) gave \(singleResult) on the single-command path")
                    }
                } else if hasDecoder {
                    if case .failure = singleResult {
                        XCTFail("\(name): \(exact) gave \(singleResult)")
                    }
                }

                let short = line(pid: pid, data: Array(data.dropLast()), padding: padding)
                XCTAssertNil(try polled(short, .mode1(command)), "\(name): \(short) declares one byte too few")
                XCTAssertTrue(isNoData(try single(short, .mode1(command))), "\(name): \(short) declares one byte too few")
            }
        }
    }

    // MARK: - Decoders checked against J1979 where the table test can't show it

    /// 0132 is signed: 0xFFF0 is −16 × 0.25 Pa, not 16 380 kPa.
    func testAlternateEvapPressureUsesSignedBigEndianPascals() throws {
        let cases: [([UInt8], Double)] = [
            ([0x00, 0x00], 0), ([0xFF, 0xFF], -1), ([0x80, 0x00], -32768),
            ([0x7F, 0xFF], 32767), ([0x00, 0x01], 1), ([0xFF, 0xFE], -2),
        ]
        for (bytes, expected) in cases {
            try assertPollPID(.evapVaporPressureAlt, data: bytes, value: expected, unit: Unit.Pascal)
        }
    }

    func testOxygenPresenceBitOrderForBothBankLayouts() throws {
        let layouts: [(OBDCommand.Mode1, Int)] = [(.O2Sensor, 4), (.O2SensorsALT, 2)]
        for (command, sensorsPerBank) in layouts {
            for bit in 0 ..< 8 {
                var banks = Array(repeating: Array(repeating: 0, count: sensorsPerBank), count: 8 / sensorsPerBank)
                banks[bit / sensorsPerBank][bit % sensorsPerBank] = 1
                let expected = banks.map { String(describing: $0) }.joined(separator: ", ")
                let frame = line(pid: pid(of: command), data: [UInt8(1) << bit])
                guard case let .success(.stringResult(actual)) = try single(frame, .mode1(command)) else {
                    XCTFail("No sensor layout for \(frame)")
                    continue
                }
                XCTAssertEqual(actual, expected, frame)
            }
        }
    }

    func testEvapVaporPressureIsSignedPascals() throws {
        let reading = try XCTUnwrap(try polled(line(pid: 0x32, data: [0xFF, 0xF0]), .mode1(.evapVaporPressure)))
        XCTAssertEqual(reading.value, -4, accuracy: 0.001)
        XCTAssertEqual(reading.unit.symbol, "Pa")
    }

    /// 0150 byte A is the maximum air flow in 10 g/s steps; A ≥ 26 used to overflow a UInt8.
    func testMaximumAirFlowAboveTwoHundredFiftyFiveDoesNotOverflow() throws {
        guard case let .success(.measurementResult(reading)) = try single(line(pid: 0x50, data: [0x80, 0, 0, 0]), .mode1(.maxMAF)) else {
            return XCTFail("0150 gave no reading")
        }
        XCTAssertEqual(reading.value, 1280)
    }

    /// 011C is one byte: the conformance table index is byte A.
    func testOBDComplianceReadsByteA() throws {
        guard case let .success(.stringResult(text)) = try single(line(pid: 0x1C, data: [0x01]), .mode1(.obdcompliance)) else {
            return XCTFail("011C gave no reading")
        }
        XCTAssertEqual(text, "OBD-II as defined by the CARB")
    }

    /// 0102 is one DTC (two bytes).
    func testFreezeFrameDTCDecodesItsCode() throws {
        guard case let .success(.troubleCode(codes)) = try single(line(pid: 0x02, data: [0x01, 0x33]), .mode1(.freezeDTC)) else {
            return XCTFail("0102 gave no code")
        }
        XCTAssertEqual(codes.map(\.code), ["P0133"])
    }

    // MARK: - Mode 02: the width rule is Mode 01 only

    /// A freeze-frame reply echoes the PID and the frame number (`42 0C 00 1A F8`). The parser
    /// keeps both with the declared data and drops the padding; no Mode 01 width is applied to
    /// it, and it is never taken for a Mode 01 answer.
    func testFreezeFrameReplyKeepsPIDFrameAndDataAndIsNoMode01Answer() throws {
        for padding in ["", "AAAA", "0000", "5555"] {
            let frame = "7E805420C001AF8" + padding
            let message = try XCTUnwrap(can11.parse([frame]).first)
            XCTAssertEqual(message.data.map { Array($0) }, [0x0C, 0x00, 0x1A, 0xF8], frame)
            XCTAssertEqual(message.responseHead, OBDResponseHead(service: 0x42, echo: 0x0C), frame)
            XCTAssertNil(try OBDService.decodePIDResponse([frame], commands: [.mode1(.rpm)], parser: can11, unit: .metric), frame)
            XCTAssertTrue(isNoData(try single(frame, .mode1(.rpm))), frame)
        }
    }
}
