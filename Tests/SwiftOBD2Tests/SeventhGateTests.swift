import XCTest
@testable import SwiftOBD2

final class SeventhGateTests: XCTestCase {
    private let dtcA = ["7E8100A430401230124", "7E82101250126AAAAAA"]
    private let dtcB = ["7E9100A430402230224", "7E92102250226AAAAAA"]
    private let vinA = ["7E81014490201000000", "7E821DEADBEEF010203", "7E82204050607080900"]
    private let vinB = ["7E91014490201000000", "7E92100112233010203", "7E92204050607080900"]
    private func receive(_ processor: OBDMessageProcessor, _ lines: [String]) {
        processor.processReceivedData(Data((lines.joined(separator: "\r") + "\r>").utf8))
    }
    private func send(_ processor: OBDMessageProcessor, _ command: String, _ lines: [String]) async throws -> [String] {
        let token = try processor.beginRequest(command: command)
        receive(processor, lines)
        return try await processor.awaitResponse(for: token, timeout: 0.3)
    }
    private func prove(_ processor: OBDMessageProcessor, after tail: [String] = []) async throws {
        processor.beginResynchronization()
        let probe = processor.beginProbeRequest(command: "ATRV")
        if !tail.isEmpty { receive(processor, tail + ["13.7V"]) }
        receive(processor, ["14.1V"])
        let lines = try await processor.awaitResponse(for: probe, timeout: 0.3)
        XCTAssertEqual(lines, ["14.1V"])
        XCTAssertTrue(processor.confirmSynchronized())
    }
    private func assertDTCs(_ lines: [String], _ expected: [UInt32: [String]]) {
        guard case let .answered(answer) = DTCResponseParser.parse(lines: lines, service: .stored, family: .can11)
        else { return XCTFail("Expected decoded stored codes") }
        XCTAssertEqual(answer.count, expected.count)
        for (id, codes) in expected {
            XCTAssertEqual(answer[ECUAddress(raw: id)]?.codes.map(\.code), codes)
        }
    }
    private func checkHealthyDTC(_ dual: Bool) async throws {
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: { _ in }))
        let frames = dual ? [dtcA[0], dtcB[0], dtcB[1], dtcA[1]] : dtcA
        let lines = try await send(processor, "03", frames)
        var expected: [UInt32: [String]] = [0x7E8: ["P0123", "P0124", "P0125", "P0126"]]
        if dual { expected[0x7E9] = ["P0223", "P0224", "P0225", "P0226"] }
        assertDTCs(lines, expected)
        XCTAssertFalse(processor.isStreamDirty)
        _ = try processor.beginRequest(command: "03")
    }
    func testHealthySingleDTC() async throws { try await checkHealthyDTC(false) }
    func testHealthyDualDTC() async throws { try await checkHealthyDTC(true) }
    private func checkHealthyVIN(_ dual: Bool) async throws {
        let sink = CapturingWireSink()
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink))
        let frames = dual ? [vinA[0], vinB[0], vinB[1], vinA[1], vinA[2], vinB[2]] : vinA
        let lines = try await send(processor, "0902", frames)
        XCTAssertTrue(lines == frames)
        XCTAssertFalse(processor.isStreamDirty)
        for line in frames { XCTAssertFalse(sink.text.contains(line)) }
        _ = try processor.beginRequest(command: "0902")
    }
    func testHealthySingleVIN() async throws { try await checkHealthyVIN(false) }
    func testHealthyDualVIN() async throws { try await checkHealthyVIN(true) }
    func testLateMonitorFromOtherECUAndFreshCodes() async throws {
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: { _ in }))
        _ = try await send(processor, "0601", ["7E9100A460101010002"])
        try await prove(processor)
        let lines = try await send(processor, "03", [dtcA[0], "7E92100010003AAAAAA", dtcA[1]])
        XCTAssertEqual(lines, dtcA)
        assertDTCs(lines, [0x7E8: ["P0123", "P0124", "P0125", "P0126"]])
        XCTAssertFalse(processor.isStreamDirty)
    }

    func testDamagedMonitorCannotEndVINPrivacy() async throws {
        let sink = CapturingWireSink()
        let clock = ManualClock()
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink), clock: clock.now)
        // Deliberately non-VIN marker data. Only sequence, size and positive service matter.
        _ = try await send(processor, "0902", ["7E81014490201000000"])
        try await prove(processor)
        clock.advance(6)
        // Two CFs from the same ECU but for a different positive service.
        let monitor = ["7E8101346010101000", "7E82100010003010201", "7E822000200010003AA"]
        await assertAmbiguous(processor, "0601", monitor)
        try await prove(processor)
        clock.advance(6) // The truncated monitor now also exceeded its debt window.
        let speed = try processor.beginRequest(command: "010D")
        let suffix = "7E821DEADBEEF010203"
        receive(processor, [suffix])
        receive(processor, ["7E803410D32"])
        let speedLines = try await processor.awaitResponse(for: speed, timeout: 0.2)
        XCTAssertTrue(speedLines == ["7E803410D32"], "VIN continuation took the speed slot")
        XCTAssertFalse(sink.text.contains(suffix), "Wire log contains synthetic continuation bytes")
    }

    func testInvalidPCIAndContinuationShapesLeaveTheFinalAnswerOwed() async throws {
        let damaged = [
            "7E83101250126AAAAAA", // Invalid PCI in an answer.
            "7E821012501", // Shorter than the four bytes still owed.
            "7E82201250126AAAAAA", // Skips the first consecutive frame.
        ]
        let replies = damaged.map { [dtcA[0], $0] } + [[dtcA.joined()]]
        for lines in replies {
            let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: { _ in }))
            await assertAmbiguous(processor, "03", ["7E8037F0378"] + lines)
            try await prove(processor)
            XCTAssertThrowsError(try processor.beginRequest(command: "03")) {
                XCTAssertEqual($0 as? OBDStreamError, .ecuResponsePending)
            }
        }
    }

    func testMergedVINFirstFramesKeepBothLateSuffixesPrivateUntilLinkReset() async throws {
        let sink = CapturingWireSink()
        let clock = ManualClock()
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink), clock: clock.now)
        let merged = [vinA[0] + vinB[0]]
        await assertAmbiguous(processor, "ATI", merged)
        try await prove(processor, after: merged)
        XCTAssertFalse(sink.text.contains("13.7V"), "The whole damaged probe reply must be withheld")
        clock.advance(6)

        let speed = try processor.beginRequest(command: "010D")
        receive(processor, [vinA[1], vinB[1]])
        receive(processor, ["7E803410D32"])
        let lines = try await processor.awaitResponse(for: speed, timeout: 0.3)
        XCTAssertEqual(lines, ["7E803410D32"])
        XCTAssertFalse(sink.text.contains(vinA[1]))
        XCTAssertFalse(sink.text.contains(vinB[1]))

        processor.reset()
        let codes = try await send(processor, "03", dtcA)
        assertDTCs(codes, [0x7E8: ["P0123", "P0124", "P0125", "P0126"]])
    }

    func testWireLogWithholdsDamagedMarkerReplyAndKeepsCleanFaultData() {
        let damagedReplies = [
            [vinA[0] + vinA[1], vinA[2]],
            ["7E8101449 ", " 02 01 00 00 00", vinA[1]],
            ["7E8101462 F1", "90 00 00 00", vinA[1]],
            ["7E8100A5902FF490200", "7E82201250126AAAAAA"],
        ]
        for lines in damagedReplies {
            let record = OBDWireLog.render(.answered(command: "1902FF", lines: lines, elapsed: 0), policy: .full)
            XCTAssertTrue(record?.message.contains("identifying reply withheld") == true)
        }
        for frame in ["7E8075902FF4902002F", "7E8075902FF62F1902F"] {
            let record = OBDWireLog.render(.answered(command: "1902FF", lines: [frame], elapsed: 0), policy: .full)
            XCTAssertTrue(record?.message.contains(frame) == true)
        }
        XCTAssertTrue(OBDWireLog.isIdentifying(command: nil, lines: ["486B1049020100000000AA"]))
    }

    private func assertAmbiguous(
        _ processor: OBDMessageProcessor, _ command: String, _ lines: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await send(processor, command, lines)
            XCTFail("Damaged frames resolved the exchange", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OBDStreamError, .ambiguousResponse, file: file, line: line)
            XCTAssertTrue(processor.isStreamDirty, file: file, line: line)
        }
    }
}
