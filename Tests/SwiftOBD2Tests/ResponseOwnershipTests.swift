//
//  ResponseOwnershipTests.swift
//  SwiftOBD2Tests
//
//  Defense in depth above the transport: a reply that landed in the wrong command's slot (a
//  late answer after a timeout) must never decode as that command's value. Each decode path
//  requires the positive response to the service it asked (`request + 0x40`) and, where the
//  service echoes one, the requested PID. All VINs here are synthetic (the documentation
//  example `1HGBH41JXMN109186`).
//

import Combine
import CoreBluetooth
@testable import SwiftOBD2
import XCTest

final class ResponseOwnershipTests: XCTestCase {
    private let can11 = ISO_15765_4_11bit_500k()
    private let can29 = ISO_15765_4_29bit_500k()
    private let legacy = ISO_9141_2()

    // Synthetic VIN 1HGBH41JXMN109186: 49 02 01 + 17 ASCII bytes, 20 bytes in three frames.
    private let canVIN = ["7E8 10 14 49 02 01 31 48 47", "7E8 21 42 48 34 31 4A 58 4D", "7E8 22 4E 31 30 39 31 38 36"]
    private let can29VIN = [
        "18DAF110 10 14 49 02 01 31 48 47", "18DAF110 21 42 48 34 31 4A 58 4D", "18DAF110 22 4E 31 30 39 31 38 36",
    ]
    // ISO 9141: header 48 6B 10, then 49 02 <order> and four data bytes, then a checksum.
    private let legacyVIN = [
        "48 6B 10 49 02 01 00 00 00 31 AA", "48 6B 10 49 02 02 48 47 42 48 AA", "48 6B 10 49 02 03 34 31 4A 58 AA",
        "48 6B 10 49 02 04 4D 4E 31 30 AA", "48 6B 10 49 02 05 39 31 38 36 AA",
    ]
    // A synthetic ASCII calibration id (49 04): printable text, but not a VIN.
    private let canCalibrationID = ["7E8 10 13 49 04 01 43 41 4C", "7E8 21 49 44 31 32 33 34 35", "7E8 22 36 37 38 39 30 31 00"]

    private func speed(_ results: [OBDCommand: MeasurementResult]?) -> Double? {
        results?[.mode1(.speed)]?.value
    }

    private func rpm(_ results: [OBDCommand: MeasurementResult]?) -> Double? {
        results?[.mode1(.rpm)]?.value
    }

    // MARK: - requestPIDs (batched Mode 01)

    /// The reviewer's example: both `010C` attempts time out, the late `41 0C 1F 40` lands in
    /// the `010D` slot. Before the fix it decoded as 31 km/h.
    func testLateRPMReplyGivesNoSpeed() throws {
        let results = try OBDService.decodePIDResponse(["7E804410C1F40"], commands: [.mode1(.speed)], parser: can11, unit: .metric)
        XCTAssertNil(speed(results), "a 41 0C reply must not decode as speed")
    }

    func testOwnSpeedReplyStillDecodes() throws {
        let results = try OBDService.decodePIDResponse(["7E803410D1F"], commands: [.mode1(.speed)], parser: can11, unit: .metric)
        XCTAssertEqual(speed(results), 31)
    }

    func testNegativeResponseGivesNoValue() throws {
        let results = try OBDService.decodePIDResponse(["7E8037F0112"], commands: [.mode1(.speed)], parser: can11, unit: .metric)
        XCTAssertNil(speed(results), "7F 01 12 is a refusal, not a speed")
    }

    func testOtherServiceReplyGivesNoValue() throws {
        // A late manufacturer `62 0D 1F` reply: the second byte even matches the PID.
        let results = try OBDService.decodePIDResponse(["7E804620D1F00"], commands: [.mode1(.speed)], parser: can11, unit: .metric)
        XCTAssertNil(speed(results))
    }

    func testBatchedReplyDecodesEveryEchoedPID() throws {
        let results = try OBDService.decodePIDResponse(
            ["7E806410C1F400D1F"], commands: [.mode1(.rpm), .mode1(.speed)], parser: can11, unit: .metric
        )
        XCTAssertEqual(rpm(results), 2000)
        XCTAssertEqual(speed(results), 31)
    }

    func testReorderedMode01ReplyKeepsEveryEchoedPID() throws {
        let results = try OBDService.decodePIDResponse(
            ["7E806410D280C1F40"], commands: [.mode1(.rpm), .mode1(.speed)], parser: can11, unit: .metric
        )
        XCTAssertEqual(rpm(results), 2000)
        XCTAssertEqual(speed(results), 40)
    }

    /// An ECU leaves unsupported PIDs out of a multi-PID answer: only the echoed one decodes.
    func testBatchedReplyDecodesOnlyEchoedPIDs() throws {
        let results = try OBDService.decodePIDResponse(
            ["7E804410C1F40"], commands: [.mode1(.speed), .mode1(.rpm)], parser: can11, unit: .metric
        )
        XCTAssertNil(speed(results), "0D was not echoed")
        XCTAssertEqual(rpm(results), 2000)
    }

    func testRequestPIDsReadsOptionalTrimBytesSeparatelyFromFixedWidthPIDs() async throws {
        let comm = OwnershipScriptedComm(responses: [
            "0100": ["7E8064100BE3FA813"],
            "01060D2F": ["7E810084106840D0D3E", "7E8212F80"], // The optional trim byte is itself 0D.
            "0106": ["7E8044106840D"],
            "010D2F": ["7E805410D3E2F80"],
        ], fallback: MOCKComm())
        let service = OBDService(comm: comm, connectionType: .demo)
        _ = try await service.startConnection(preferedProtocol: .protocol6)

        let trim = OBDCommand.mode1(.shortFuelTrim1)
        let speed = OBDCommand.mode1(.speed)
        let fuel = OBDCommand.mode1(.fuelLevel)
        let readings = try await service.requestPIDs([trim, speed, fuel], unit: .metric, retries: 1)
        XCTAssertEqual(readings[trim]?.value, 3.125)
        XCTAssertEqual(readings[speed]?.value, 62)
        XCTAssertEqual(try XCTUnwrap(readings[fuel]?.value), 100 * 128 / 255, accuracy: 0.001)
        XCTAssertEqual(Array(comm.sentCommands.suffix(2)), ["010D2F", "0106"])
    }

    func testSplitPollKeepsSpeedWhenAnotherGroupExplicitlyHasNoData() async throws {
        for noData: Error in [BLEManagerError.noData, CommunicationError.noData] {
            let comm = OwnershipScriptedComm(
                responses: ["0100": ["7E8064100BE3FA813"], "010D": ["7E803410D28"]],
                fallback: MOCKComm(), failures: ["0108": noData]
            )
            let service = OBDService(comm: comm, connectionType: .demo)
            _ = try await service.startConnection(preferedProtocol: .protocol6)

            let trim = OBDCommand.mode1(.shortFuelTrim2)
            let readings = try await service.requestPIDs([.mode1(.speed), trim], unit: .metric, retries: 1)
            XCTAssertEqual(speed(readings), 40)
            XCTAssertNil(readings[trim])
            XCTAssertEqual(Array(comm.sentCommands.suffix(2)), ["010D", "0108"])
        }
    }

    /// With every group saying NO DATA (ignition off), the split poll fails the way a
    /// single-group poll does instead of returning an empty success.
    func testSplitPollThrowsWhenEveryGroupHasNoData() async throws {
        let comm = OwnershipScriptedComm(
            responses: ["0100": ["7E8064100BE3FA813"]],
            fallback: MOCKComm(), failures: ["0106": CommunicationError.noData, "0108": CommunicationError.noData]
        )
        let service = OBDService(comm: comm, connectionType: .demo)
        _ = try await service.startConnection(preferedProtocol: .protocol6)
        do {
            _ = try await service.requestPIDs([.mode1(.shortFuelTrim1), .mode1(.shortFuelTrim2)], unit: .metric, retries: 1)
            XCTFail("Expected NO DATA to reach the poller")
        } catch OBDServiceError.commandFailed(_, let underlying) {
            guard case CommunicationError.noData = underlying else { return XCTFail("Expected noData, got \(underlying)") }
        }
    }

    func testSplitPollStillThrowsForCancellationAndLinkLoss() async throws {
        for failure: Error in [CancellationError(), CommunicationError.connectionLost] {
            let comm = OwnershipScriptedComm(
                responses: ["0100": ["7E8064100BE3FA813"], "010D": ["7E803410D28"]],
                fallback: MOCKComm(), failures: ["0108": failure]
            )
            let service = OBDService(comm: comm, connectionType: .demo)
            _ = try await service.startConnection(preferedProtocol: .protocol6)
            do {
                _ = try await service.requestPIDs([.mode1(.speed), .mode1(.shortFuelTrim2)], unit: .metric)
                XCTFail("Expected the transport failure to reach the poller")
            } catch OBDServiceError.commandFailed(let command, let underlying) {
                XCTAssertEqual(command, "0108")
                XCTAssertEqual(underlying is CancellationError, failure is CancellationError)
                if failure is CommunicationError {
                    guard case CommunicationError.connectionLost = underlying else {
                        return XCTFail("Expected connectionLost")
                    }
                }
            }
        }
    }

    func test29BitOwnershipChecks() throws {
        XCTAssertEqual(
            speed(try OBDService.decodePIDResponse(["18DAF11003410D1F"], commands: [.mode1(.speed)], parser: can29, unit: .metric)),
            31
        )
        XCTAssertNil(
            speed(try OBDService.decodePIDResponse(["18DAF11004410C1F40"], commands: [.mode1(.speed)], parser: can29, unit: .metric))
        )
    }

    func testLegacyOwnershipChecks() throws {
        XCTAssertEqual(
            speed(try OBDService.decodePIDResponse(["486B10410D1FAA"], commands: [.mode1(.speed)], parser: legacy, unit: .metric)),
            31
        )
        XCTAssertNil(
            speed(try OBDService.decodePIDResponse(["486B10410C1F40AA"], commands: [.mode1(.speed)], parser: legacy, unit: .metric))
        )
    }

    // MARK: - sendCommand(_:)

    func testSendCommandRejectsAnotherPIDsReply() throws {
        let result = try OBDService.decodeCommandResponse(["7E804410C1F40"], command: .mode1(.speed), parser: can11)
        guard case .failure(.noData) = result else {
            return XCTFail("a 41 0C reply must not decode for 010D: \(result)")
        }
    }

    func testSendCommandDecodesItsOwnVIN() throws {
        let result = try OBDService.decodeCommandResponse(canVIN, command: .mode9(.VIN), parser: can11)
        guard case let .success(.stringResult(text)) = result else {
            return XCTFail("expected the VIN string: \(result)")
        }
        XCTAssertTrue(text.contains("1HGBH41JXMN109186"), text)
    }

    func testSendCommandRejectsAnotherServicesReplyForVIN() throws {
        for lines in [["7E8064100BE3FA813"], ["7E8037F0912"], canCalibrationID] {
            let result = try OBDService.decodeCommandResponse(lines, command: .mode9(.VIN), parser: can11)
            guard case .failure(.noData) = result else {
                XCTFail("\(lines.count)-line reply must not decode as the VIN: \(result)")
                continue
            }
        }
    }

    // MARK: - ELM327.requestVin

    private func vin(_ lines: [String], parser: CANProtocol) async -> String? {
        let comm = OwnershipScriptedComm(responses: ["0902": lines])
        let sut = ELM327(comm: comm)
        sut.canProtocol = parser
        return await sut.requestVin()
    }

    func testVINStillReadsOnEveryAddressing() async {
        let expected = "1HGBH41JXMN109186"
        let can11VIN = await vin(canVIN, parser: can11)
        let can29Read = await vin(can29VIN, parser: can29)
        let legacyRead = await vin(legacyVIN, parser: legacy)
        XCTAssertEqual(can11VIN, expected)
        XCTAssertEqual(can29Read, expected)
        XCTAssertEqual(legacyRead, expected)
    }

    func testLateMode01ReplyIsNotAVIN() async {
        let read = await vin(["7E8064100BE3FA813"], parser: can11)
        XCTAssertNil(read)
    }

    func testNegativeResponseIsNotAVIN() async {
        let read = await vin(["7E8037F0912"], parser: can11)
        XCTAssertNil(read, "7F 09 12 is a refusal")
    }

    func testCalibrationIDIsNotAVIN() async {
        let read = await vin(canCalibrationID, parser: can11)
        XCTAssertNil(read, "49 04 is not 49 02")
    }

    // MARK: - ELM327.getSupportedPIDs

    private func supportedPIDs(_ reply0100: [String]) async -> [OBDCommand] {
        let comm = OwnershipScriptedComm(responses: ["0100": reply0100])
        let sut = ELM327(comm: comm)
        sut.canProtocol = can11
        return await sut.getSupportedPIDs()
    }

    func testSupportedPIDsFromOwnBitmap() async {
        let pids = await supportedPIDs(["7E8064100BE3FA813"])
        XCTAssertTrue(pids.contains(.mode1(.rpm)))
        XCTAssertTrue(pids.contains(.mode1(.speed)))
    }

    /// A late `0902` answer in the `0100` slot used to be read as the PID bitmap.
    func testLateVINReplyIsNotABitmap() async {
        let pids = await supportedPIDs(canVIN)
        XCTAssertEqual(pids, [], "a 49 02 reply must not produce supported PIDs")
    }

    func testOtherPIDsBitmapIsNotThe0100Bitmap() async {
        // `41 20 …` answers 0120, not 0100.
        let pids = await supportedPIDs(["7E8064120FFFFFFFF"])
        XCTAssertEqual(pids, [])
    }

    // MARK: - ELM327.getStatus

    private func status(_ lines: [String]) async throws -> Result<DecodeResult, DecodeError> {
        let comm = OwnershipScriptedComm(responses: ["0101": lines])
        let sut = ELM327(comm: comm)
        sut.canProtocol = can11
        return try await sut.getStatus()
    }

    func testStatusDecodesOwnReply() async throws {
        let result = try await status(["7E80641010007E100"])
        guard case .success(.statusResult) = result else {
            return XCTFail("expected a status: \(result)")
        }
    }

    func testStatusRejectsAnotherPIDsReply() async throws {
        let result = try await status(["7E804410C1F40"])
        guard case .failure(.noData) = result else {
            return XCTFail("a 41 0C reply must not decode as the monitor status: \(result)")
        }
    }
}

/// Replays scripted lines per command; anything unscripted is `NO DATA`.
final class OwnershipScriptedComm: CommProtocol {
    @Published var connectionState: ConnectionState = .connectedToVehicle
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?
    var redactionHeld = false
    var isWireRedactionHeld: Bool { redactionHeld }

    private let responses: [String: [String]]
    private let fallback: CommProtocol?
    private let failures: [String: Error]
    private(set) var sentCommands: [String] = []

    init(responses: [String: [String]], fallback: CommProtocol? = nil, failures: [String: Error] = [:]) {
        self.responses = responses
        self.fallback = fallback
        self.failures = failures
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        sentCommands.append(command)
        if let failure = failures[command] { throw failure }
        if let response = responses[command] { return response }
        return try await fallback?.sendCommand(command, retries: retries) ?? ["NO DATA"]
    }

    func disconnectPeripheral() {
        connectionState = .disconnected
    }

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral?) async throws {}

    func scanForPeripherals() async throws {}
}
