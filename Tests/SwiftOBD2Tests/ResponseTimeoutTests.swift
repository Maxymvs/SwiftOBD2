//
//  ResponseTimeoutTests.swift
//  SwiftOBD2Tests
//
//  Slow module exchanges (a long `19 02` list after "response pending") need a longer wait
//  than the 3 s default, and callers must be able to tell a timeout from `NO DATA`.
//

import Combine
import CoreBluetooth
@testable import SwiftOBD2
import XCTest

final class ResponseTimeoutTests: XCTestCase {
    func testLongerWaitReachesTheTransport() async throws {
        let comm = TimeoutRecordingComm()
        let sut = ELM327(comm: comm)

        _ = try await sut.sendCommand("1902FF", retries: 1, responseTimeout: 12)
        _ = try await sut.sendCommand("0100")

        XCTAssertEqual(comm.timeouts, [12, nil])
    }

    func testTransportsWithoutAPerCommandWaitIgnoreIt() async throws {
        let comm = PlainComm()
        let lines = try await comm.sendCommand("1902FF", retries: 1, responseTimeout: 12)
        XCTAssertEqual(lines, ["NO DATA"])
    }

    func testOnlyTimeoutsCountAsResponseTimeouts() {
        func failed(_ error: Error) -> OBDServiceError { .commandFailed(command: "1902FF", error: error) }
        XCTAssertTrue(failed(OBDMessageProcessorError.responseTimeout).isResponseTimeout)
        XCTAssertTrue(failed(BLEManagerError.sendMessageTimeout).isResponseTimeout)
        XCTAssertTrue(failed(CommunicationError.timeout).isResponseTimeout)
        XCTAssertFalse(failed(BLEManagerError.noData).isResponseTimeout)
        XCTAssertFalse(failed(BLEManagerError.peripheralNotConnected).isResponseTimeout)
        XCTAssertFalse(OBDServiceError.notConnectedToVehicle.isResponseTimeout)
    }
}

private final class TimeoutRecordingComm: CommProtocol {
    @Published var connectionState: ConnectionState = .connectedToVehicle
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?
    private(set) var timeouts: [TimeInterval?] = []

    func sendCommand(_: String, retries _: Int) async throws -> [String] {
        timeouts.append(nil)
        return ["OK"]
    }

    func sendCommand(_: String, retries _: Int, responseTimeout: TimeInterval) async throws -> [String] {
        timeouts.append(responseTimeout)
        return ["OK"]
    }

    func disconnectPeripheral() {}
    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral?) async throws {}
    func scanForPeripherals() async throws {}
}

private final class PlainComm: CommProtocol {
    @Published var connectionState: ConnectionState = .connectedToVehicle
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    func sendCommand(_: String, retries _: Int) async throws -> [String] { ["NO DATA"] }
    func disconnectPeripheral() {}
    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral?) async throws {}
    func scanForPeripherals() async throws {}
}
