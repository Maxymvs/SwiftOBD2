//
//  ProtocolDetectionTests.swift
//  SwiftOBD2Tests
//
//  Automatic protocol detection must never report a connected vehicle it can't talk to: a CAN
//  car that refuses legacy Mode 01 (e.g. an OBDonUDS-only ECU) fails clearly, without a slow
//  manual sweep of every other protocol.
//

import Combine
import CoreBluetooth
@testable import SwiftOBD2
import XCTest

final class ProtocolDetectionTests: XCTestCase {
    func testLegacyCANVehicleConnectsOnProtocol6() async throws {
        let comm = DetectionScriptedComm(responses: [
            "ATSP0": ["OK"],
            "0100": ["7E8064100BE3FA813"],
            "ATDPN": ["A6"],
        ])
        let sut = ELM327(comm: comm)

        let info = try await sut.setupVehicle(preferredProtocol: nil)

        XCTAssertEqual(info.obdProtocol, .protocol6)
    }

    func testCANNegativeResponseTo0100FailsWithoutManualSweep() async {
        // 7F 01 11 = serviceNotSupported for Mode 01: the bus is up, legacy OBD-II is not.
        let comm = DetectionScriptedComm(responses: [
            "ATSP0": ["OK"],
            "0100": ["7E8037F0111"],
            "ATDPN": ["A6"],
        ])
        let sut = ELM327(comm: comm)

        do {
            _ = try await sut.setupVehicle(preferredProtocol: nil)
            XCTFail("Expected setup to fail")
        } catch ELM327Error.unsupportedDiagnosticDialect {
            // Expected.
        } catch {
            XCTFail("Expected unsupportedDiagnosticDialect, got \(error)")
        }
        XCTAssertFalse(
            comm.sentCommands.contains { $0.hasPrefix("ATSP") && $0 != "ATSP0" },
            "Must not fall through to the manual protocol sweep: \(comm.sentCommands)"
        )
    }

    func testNoDataOnAutomaticDetectionStillTriesManualSweep() async {
        let comm = DetectionScriptedComm(responses: [
            "ATSP0": ["OK"],
            "0100": ["NO DATA"],
            "ATDPN": ["A6"],
        ])
        let sut = ELM327(comm: comm)

        do {
            _ = try await sut.setupVehicle(preferredProtocol: nil)
            XCTFail("Expected setup to fail")
        } catch ELM327Error.noProtocolFound {
            // Expected: silence is not evidence of a different dialect.
        } catch {
            XCTFail("Expected noProtocolFound, got \(error)")
        }
        XCTAssertTrue(
            comm.sentCommands.contains { $0.hasPrefix("ATSP") && $0 != "ATSP0" },
            "Silence should keep the manual sweep: \(comm.sentCommands)"
        )
    }

    func testFrameDetectionIgnoresAdapterStatusText() {
        XCTAssertTrue(ELM327.containsFrame(["7E8037F0111"]))
        XCTAssertTrue(ELM327.containsFrame(["SEARCHING...", "7E8 03 7F 01 11"]))
        XCTAssertFalse(ELM327.containsFrame(["NO DATA"]))
        XCTAssertFalse(ELM327.containsFrame(["CAN ERROR"]))
        XCTAssertFalse(ELM327.containsFrame(["SEARCHING...", "UNABLE TO CONNECT"]))
        XCTAssertFalse(ELM327.containsFrame(["OK"]))
        XCTAssertFalse(ELM327.containsFrame([]))
    }
}

/// Replays scripted lines per command and records everything sent.
private final class DetectionScriptedComm: CommProtocol {
    @Published var connectionState: ConnectionState = .connectedToAdapter
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    private let responses: [String: [String]]
    private(set) var sentCommands: [String] = []

    init(responses: [String: [String]]) {
        self.responses = responses
    }

    func sendCommand(_ command: String, retries _: Int) async throws -> [String] {
        sentCommands.append(command)
        if let response = responses[command] { return response }
        // Manual-sweep protocol selection answers OK; anything else is silent.
        if command.hasPrefix("ATSP") { return ["OK"] }
        return ["NO DATA"]
    }

    func disconnectPeripheral() {
        connectionState = .disconnected
    }

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral?) async throws {}

    func scanForPeripherals() async throws {}
}
