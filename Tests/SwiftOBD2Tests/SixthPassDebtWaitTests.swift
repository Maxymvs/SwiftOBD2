import XCTest
@testable import SwiftOBD2

final class SixthPassDebtWaitTests: XCTestCase {
    private func makeProvenProcessor() async throws -> OBDMessageProcessor {
        let p = OBDMessageProcessor(wireLog: OBDWireLog(sink: { _ in }))
        let slot = try p.beginRequest(command: "03")
        p.processReceivedData(Data("7E8037F0378\r>".utf8))
        _ = try await p.awaitResponse(for: slot, timeout: 0.3)
        p.beginResynchronization()
        let probe = p.beginProbeRequest(command: "ATRV")
        p.processReceivedData(Data("14.1V\r>".utf8))
        _ = try await p.awaitResponse(for: probe, timeout: 0.3)
        XCTAssertTrue(p.confirmSynchronized())
        return p
    }

    func testRepeatScanAndRenewedPendingUseOneWaitWindow() async throws {
        let a = try await makeProvenProcessor()
        let b = try await makeProvenProcessor()
        let start = a.clock()
        let allow = Task { try await a.beginRequestWaitingForECU(command: "03") }
        let refuse = Task { try await b.beginRequestWaitingForECU(command: "03") }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        b.processReceivedData(Data("7E8037F0378\r>".utf8))
        _ = try await allow.value
        do {
            _ = try await refuse.value
            XCTFail("Armed on renewed debt")
        } catch {
            XCTAssertEqual(error as? OBDStreamError, .ecuResponsePending)
        }
        XCTAssertTrue((4.7 ... 5.5).contains(a.clock() - start))
        let speed = try await b.beginRequestWaitingForECU(command: "010D")
        b.processReceivedData(Data("7E803410D32\r>".utf8))
        let lines = try await b.awaitResponse(for: speed, timeout: 0.2)
        XCTAssertTrue(lines == ["7E803410D32"])
    }

    func testResetInvalidatesAlreadyWaitingScan() async throws {
        let p = try await makeProvenProcessor()
        let scan = Task { try await p.beginRequestWaitingForECU(command: "03") }
        try await Task.sleep(nanoseconds: 100_000_000)
        p.reset()
        do {
            _ = try await scan.value
            XCTFail("Old scan armed on new link")
        } catch {
            XCTAssertEqual(error as? OBDMessageProcessorError, .staleRequestToken)
        }
        _ = try p.beginRequest(command: "03")
    }
}
