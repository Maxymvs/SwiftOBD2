import XCTest
@testable import SwiftOBD2

final class SixthPassReviewTests: XCTestCase {
    private func input(_ lines: [String], into processor: OBDMessageProcessor) {
        processor.processReceivedData(Data((lines.joined(separator: "\r") + "\r>").utf8))
    }

    private func send(_ command: String, _ lines: [String], _ processor: OBDMessageProcessor) async throws -> [String] {
        let token = try processor.beginRequest(command: command)
        input(lines, into: processor)
        return try await processor.awaitResponse(for: token, timeout: 0.2)
    }

    private func prove(_ processor: OBDMessageProcessor) async throws {
        processor.beginResynchronization()
        let probe = processor.beginProbeRequest(command: "ATRV")
        input(["14.1V"], into: processor)
        _ = try await processor.awaitResponse(for: probe, timeout: 0.2)
        XCTAssertTrue(processor.confirmSynchronized())
    }

    func testCurrentMonitorCannotDischargeOldDTCFirstFrame() async throws {
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: { _ in }))
        _ = try await send("03", ["7E8037F0378"], processor)
        try await prove(processor)
        // The abandoned Mode 03 final starts between slots. Its last frame never arrives.
        input(["7E8100A430401230124"], into: processor)
        let monitor = ["7E8100A460101010002", "7E82100010003AAAAAA"]
        await assertAmbiguous("0601", monitor, processor)
        try await prove(processor)
        XCTAssertThrowsError(try processor.beginRequest(command: "03")) {
            XCTAssertEqual($0 as? OBDStreamError, .ecuResponsePending)
        }
    }

    func testLateMonitorAndFreshCodesBothStayIncompleteInSharedPrompt() async throws {
        let clock = ManualClock()
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: { _ in }), clock: clock.now)
        _ = try await send("0601", ["7E8100A460101010002"], processor)
        try await prove(processor)
        let fresh = ["7E8100A430401230124", "7E82101250126AAAAAA"]
        let oldMonitorTail = "7E82100010003AAAAAA"
        await assertAmbiguous("03", fresh + [oldMonitorTail], processor)
        try await prove(processor)
        for command in ["0601", "03"] {
            XCTAssertThrowsError(try processor.beginRequest(command: command)) {
                XCTAssertEqual($0 as? OBDStreamError, .ecuResponsePending)
            }
        }
        clock.advance(6)
        let valid = try await send("03", fresh, processor)
        XCTAssertEqual(valid, fresh)
    }

    private func assertAmbiguous(
        _ command: String, _ lines: [String], _ processor: OBDMessageProcessor,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await send(command, lines, processor)
            XCTFail("Ambiguous frames resolved the exchange", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OBDStreamError, .ambiguousResponse, file: file, line: line)
            XCTAssertTrue(processor.isStreamDirty, "Ambiguity must leave the stream dirty", file: file, line: line)
        }
    }

    func testNewMonitorCannotEndVINPrivacy() async throws {
        let sink = CapturingWireSink()
        let clock = ManualClock()
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink), clock: clock.now)
        // Deliberately non-VIN marker data. Only sequence, size and positive service matter.
        _ = try await send("0902", ["7E81014490201000000"], processor)
        try await prove(processor)
        clock.advance(6)
        // Two CFs from the same ECU but for a different positive service.
        let monitor = ["7E81013460101010002", "7E82100010003010201", "7E822000200010003AA"]
        await assertAmbiguous("0601", monitor, processor)
        try await prove(processor)
        clock.advance(6) // The truncated monitor now also exceeded its debt window.
        let speed = try processor.beginRequest(command: "010D")
        let suffix = "7E821DEADBEEF010203"
        input([suffix], into: processor)
        input(["7E803410D32"], into: processor)
        let speedLines = try await processor.awaitResponse(for: speed, timeout: 0.2)
        XCTAssertTrue(speedLines == ["7E803410D32"], "VIN continuation took the speed slot")
        XCTAssertFalse(sink.text.contains(suffix), "Wire log contains synthetic continuation bytes")
    }
}
