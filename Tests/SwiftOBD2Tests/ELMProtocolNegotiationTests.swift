import Combine
import CoreBluetooth
import Foundation
@testable import SwiftOBD2
import XCTest

final class ELMProtocolNegotiationTests: XCTestCase {
    private let can11 = "7E8 06 41 00 00 00 00 00"
    private let can29 = "18 DA F1 10 06 41 00 00 00 00 00"
    private let legacy = "48 6B 10 41 00 00 00 00 00 04"

    func testAutomaticNegotiationUsesActualProtocolAndOnlyOneProbe() async throws {
        for number in 1...9 {
            let frame = number < 6 ? legacy : ([7, 9].contains(number) ? can29 : can11)
            let comm = SetupTranscript([
                .reply("ATSP0", ["OK"]),
                .reply("0100", ["SEARCHING...", frame]),
                .reply("ATDPN", ["A\(number)"]),
            ])
            let elm = ELM327(comm: comm)
            let detected = try await elm.detectProtocol()
            XCTAssertEqual(detected.rawValue, String(number))
            XCTAssertEqual(comm.commands, ["ATSP0", "0100", "ATDPN"])
            XCTAssertEqual(comm.timeouts[1], OBDConnectionTiming.protocolSearch)
            XCTAssertTrue(comm.steps.isEmpty)
        }
    }

    func testReconnectHintActuallySelectsProtocolAndReadsBackAutomaticFallback() async throws {
        let comm = SetupTranscript([
            .reply("ATTPA6", ["OK"]),
            .reply("0100", ["SEARCHING...", legacy]),
            .reply("ATDPN", ["A3"]),
        ])
        let detected = try await ELM327(comm: comm).detectProtocol(preferredProtocol: .protocol6)
        XCTAssertEqual(detected, .protocol3, "A moved adapter must not inherit the previous car's protocol")
        XCTAssertEqual(comm.commands, ["ATTPA6", "0100", "ATDPN"])
    }

    func testUnsupportedTryProtocolFallsBackOnlyAfterCompletedRejection() async throws {
        let comm = SetupTranscript([
            .reply("ATTPA3", ["?"]), .reply("ATSP0", ["OK"]),
            .reply("0100", [can29]), .reply("ATDPN", ["7"]),
        ])
        let detected = try await ELM327(comm: comm).detectProtocol(preferredProtocol: .protocol3)
        XCTAssertEqual(detected, .protocol7)
        XCTAssertEqual(comm.commands, ["ATTPA3", "ATSP0", "0100", "ATDPN"])
    }

    func testProtocolNumberGrammar() throws {
        for number in 1...9 {
            XCTAssertEqual(try ELM327.parseProtocolNumber(["A\(number)"]).rawValue, String(number))
            XCTAssertEqual(try ELM327.parseProtocolNumber(["\(number)"]).rawValue, String(number))
        }
        for invalid in [[], ["06"], ["A"], ["A0"], ["AB"], ["C"], ["?"], ["A6", "A3"]] {
            XCTAssertThrowsError(try ELM327.parseProtocolNumber(invalid))
        }
    }

    func testSearchTimeoutAndCancellationDoNotStartAnotherProbeOrProtocolScan() async {
        let errors: [Error] = [OBDMessageProcessorError.responseTimeout, CancellationError(), BLEManagerError.peripheralNotConnected]
        for error in errors {
            let comm = SetupTranscript([.reply("ATSP0", ["OK"]), .failure("0100", error)])
            do {
                _ = try await ELM327(comm: comm).detectProtocol()
                XCTFail("Expected terminal search failure")
            } catch { }
            XCTAssertEqual(comm.commands, ["ATSP0", "0100"])
        }
    }

    func testTimeoutSelectingPreferredProtocolDoesNotSendFallback() async {
        let comm = SetupTranscript([.failure("ATTPA3", OBDMessageProcessorError.responseTimeout)])
        do {
            _ = try await ELM327(comm: comm).detectProtocol(preferredProtocol: .protocol3)
            XCTFail("Expected timeout")
        } catch { }
        XCTAssertEqual(comm.commands, ["ATTPA3"])
    }

    func testMissingOrMalformedVehicleEvidenceCannotConnect() async {
        for response in [["NO DATA"], ["SEARCHING..."], ["7E8 02 41 00"], ["7E8 06 42 00 00 00 00 00"], []] {
            let comm = SetupTranscript([.reply("ATSP0", ["OK"]), .reply("0100", response)])
            let elm = ELM327(comm: comm)
            do {
                _ = try await elm.setupVehicle(preferredProtocol: nil)
                XCTFail("Invalid ECU evidence must fail")
            } catch { }
            XCTAssertNotEqual(elm.connectionState, .connectedToVehicle)
            XCTAssertEqual(comm.commands, ["ATSP0", "0100"])
        }
    }

    func testProtocolAndFrameMustAgree() async {
        let comm = SetupTranscript([
            .reply("ATSP0", ["OK"]), .reply("0100", [can29]), .reply("ATDPN", ["A6"]),
        ])
        do {
            _ = try await ELM327(comm: comm).detectProtocol()
            XCTFail("A 29-bit reply must not establish an 11-bit session")
        } catch { }
    }

    func testSetupReusesFirstBitmapAndToleratesExplicitNoDataForOptionalMetadata() async throws {
        var steps: [SetupTranscript.Step] = [
            .reply("ATSP0", ["OK"]), .reply("0100", ["SEARCHING...", legacy]),
            .reply("ATDPN", ["A3"]), .failure("0902", BLEManagerError.noData),
        ]
        steps += OBDCommand.pidGetters.filter { $0.properties.command != "0100" }.map {
            .failure($0.properties.command, BLEManagerError.noData)
        }
        let comm = SetupTranscript(steps)
        let elm = ELM327(comm: comm)
        let info = try await elm.setupVehicle(preferredProtocol: nil)
        XCTAssertEqual(info.obdProtocol, .protocol3)
        XCTAssertEqual(elm.connectionState, .connectedToVehicle)
        XCTAssertNotNil(info.ecuMap)
        XCTAssertEqual(comm.commands.filter { $0 == "0100" }.count, 1)
        XCTAssertTrue(comm.steps.isEmpty)
    }

    func testMetadataTimeoutDoesNotPublishConnectedOrContinueWriting() async {
        let comm = SetupTranscript([
            .reply("ATSP0", ["OK"]), .reply("0100", [can11]),
            .reply("ATDPN", ["A6"]), .failure("0902", OBDMessageProcessorError.responseTimeout),
        ])
        let elm = ELM327(comm: comm)
        do {
            _ = try await elm.setupVehicle(preferredProtocol: nil)
            XCTFail("An unfinished VIN request must terminate setup")
        } catch { }
        XCTAssertNotEqual(elm.connectionState, .connectedToVehicle)
        XCTAssertEqual(comm.commands, ["ATSP0", "0100", "ATDPN", "0902"])
    }

    func testResetEchoIsAcceptedAndSelectionHappensDuringNegotiation() async throws {
        let comm = SetupTranscript([
            .reply("ATZ", ["ATZ", "ELM327 v1.5"]), .reply("ATE0", ["ATE0", "OK"]),
            .reply("ATL0", ["OK"]), .reply("ATS0", ["OK"]), .reply("ATH1", ["OK"]),
        ])
        try await ELM327(comm: comm).adapterInitialization()
        XCTAssertTrue(comm.steps.isEmpty)
        XCTAssertFalse(comm.commands.contains("ATSP0"))
    }
}

private final class SetupTranscript: CommProtocol {
    struct Step {
        let command: String
        let result: Result<[String], Error>
        static func reply(_ command: String, _ lines: [String]) -> Self { .init(command: command, result: .success(lines)) }
        static func failure(_ command: String, _ error: Error) -> Self { .init(command: command, result: .failure(error)) }
    }
    var steps: [Step]
    var commands: [String] = []
    var timeouts: [TimeInterval] = []
    @Published var connectionState: ConnectionState = .connectedToAdapter
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    weak var obdDelegate: OBDServiceDelegate?
    init(_ steps: [Step]) { self.steps = steps }
    func sendSetupCommand(_ command: String, responseTimeout: TimeInterval) async throws -> [String] {
        try Task.checkCancellation()
        commands.append(command)
        timeouts.append(responseTimeout)
        guard !steps.isEmpty else { XCTFail("Unexpected command: \(command)"); throw ELM327Error.invalidProtocol }
        let next = steps.removeFirst()
        XCTAssertEqual(command, next.command)
        return try next.result.get()
    }
    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        XCTFail("Setup must use the deadline-aware, single-attempt transport")
        throw ELM327Error.invalidProtocol
    }
    func disconnectPeripheral() { connectionState = .disconnected }
    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?) async throws { }
    func scanForPeripherals() async throws { }
}
