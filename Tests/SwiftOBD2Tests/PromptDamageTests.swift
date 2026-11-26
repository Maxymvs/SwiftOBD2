import XCTest
@testable import SwiftOBD2

final class PromptDamageTests: XCTestCase {
    private let speed = "7E803410D32"
    private let suffix = "7E821DEADBEEF010203"

    func testSearchMergedVINFirst() async throws {
        try await checkLateVIN("SEARCHING...7E81014490201000000")
    }

    func testDroppedHeaderDigitVIN() async throws {
        try await checkLateVIN("781014490201000000")
    }

    func testDroppedLeadingCANDigitVIN() async throws {
        try await checkLateVIN("E81014490201000000", reportedProtocol: "A6")
    }

    func testLegacyHeadersRequireLegacyProtocol() async throws {
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: { _ in }))
        let supportedPIDs = ["486B104100BE3FA813BC"]
        let legacyReplies = ["486B10410D3243", "486A10410D3242"]
        let discovered = try await send(processor, command: "0100", lines: supportedPIDs)
        XCTAssertEqual(discovered, supportedPIDs)
        let legacy = try await send(processor, command: "010D", lines: legacyReplies)
        XCTAssertEqual(legacy, legacyReplies)

        for number in ["6", "A7"] {
            _ = try await send(processor, command: "ATDPN", lines: [number])
            for reply in legacyReplies {
                await assertAmbiguous(processor, command: "010D", lines: [reply])
                try await prove(processor)
            }
        }
    }

    func testMiddleOfThreeMergedVINHeads() async throws {
        try await checkLateVIN("7E910144902010000007E810144902010000007EF1014490201000000")
    }

    func testMarkerOnlySingleFrameCannotClearVINQuarantine() async throws {
        for (command, markerOnly) in [("0902", "7E8024902"), ("22F190", "7E80362F190")] {
            let sink = CapturingWireSink()
            let clock = ManualClock()
            let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink), clock: clock.now)
            await assertAmbiguous(processor, command: "0902", lines: ["7E8101449020100000"])
            try await prove(processor)
            clock.advance(6)

            _ = try? await send(processor, command: command, lines: [markerOnly])
            if processor.isStreamDirty { try await prove(processor) }
            try await assertLateVINWasDiscarded(processor, sink: sink)
        }
    }

    func testDamagedPromptCannotSettleAnyResponderDebt() async throws {
        let clock = ManualClock()
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: { _ in }), clock: clock.now)
        _ = try await send(processor, command: "0601", lines: ["7E8037F0678"])
        try await prove(processor)
        _ = try await send(processor, command: "03", lines: ["7E9037F0378"])

        let listen = try processor.beginContinuationRequest()
        receive(processor, ["7E8037F0631", "7E9024300", "SEARCHING...7EF03410D32"])
        do {
            _ = try await processor.awaitResponse(for: listen, timeout: 0.2)
            XCTFail("Damaged prompt settled the active continuation")
        } catch {
            XCTAssertEqual(error as? OBDStreamError, .ambiguousResponse)
        }
        XCTAssertThrowsError(try processor.beginRequest(command: "010D")) {
            XCTAssertEqual($0 as? OBDStreamError, .unsynchronized)
        }
        try await prove(processor)
        for command in ["0601", "03"] {
            XCTAssertThrowsError(try processor.beginRequest(command: command)) {
                XCTAssertEqual($0 as? OBDStreamError, .ecuResponsePending)
            }
        }
    }

    func testOnlyCompleteFreshVINReleasesLinkWideRedaction() async throws {
        let sink = CapturingWireSink()
        let clock = ManualClock()
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink), clock: clock.now)
        // The VIN marker crosses the broken line boundary.
        await assertAmbiguous(processor, command: "ATI", lines: ["7E8101449 ", "02 01 00 00 00"])
        try await prove(processor)
        clock.advance(6)

        let otherResponder = ["7E9100A430402230224", "7E92102250226AAAAAA"]
        await assertAmbiguous(processor, command: "03", lines: otherResponder)
        XCTAssertFalse(sink.text.contains(otherResponder[1]))
        try await prove(processor)
        clock.advance(6)

        let fullVIN = ["7E8101462F190000000", "7E82100000000000000", "7E82200000000000000"]
        let shortVIN = ["7E8101362F190000000"] + Array(fullVIN.dropFirst())
        await assertAmbiguous(processor, command: "22F190", lines: shortVIN)
        try await prove(processor)
        clock.advance(6)

        let received = try await send(processor, command: "22F190", lines: fullVIN)
        XCTAssertTrue(received == fullVIN)
        XCTAssertFalse(sink.text.contains(fullVIN[1]))
        let restored = try await send(processor, command: "03", lines: otherResponder)
        XCTAssertEqual(restored, otherResponder)
        XCTAssertTrue(sink.text.contains(otherResponder[1]))
    }

    func testHealthyCaptureReplay() async throws {
        struct Reply: Decodable {
            let transcript: Int
            let command: String
            let lines: [String]
        }
        // Complete CAN replies from the OEM capture transcripts. VIN data bytes are zeroed.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "healthy-oem-prompts", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let replies = try JSONDecoder().decode([Reply].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(replies.map(\.transcript)).count, 21)
        XCTAssertEqual(replies.count, 396)
        XCTAssertEqual(replies.reduce(0) { $0 + $1.lines.count }, 2333)

        for (spaced, searching) in [(false, false), (true, false), (true, true)] {
            let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: { _ in }))
            _ = try await send(processor, command: "ATDPN", lines: ["A6"])
            for reply in replies {
                let frames = spaced ? reply.lines.map(spaceFrame) : reply.lines
                let lines = searching ? ["SEARCHING..."] + frames : frames
                let context = "Transcript \(reply.transcript), command \(reply.command), spaced \(spaced), searching \(searching)"
                do {
                    let received = try await send(processor, command: reply.command, lines: lines)
                    XCTAssertTrue(received == lines, context)
                    XCTAssertFalse(processor.isStreamDirty, context)
                } catch {
                    XCTFail("\(context): \(type(of: error))")
                    processor.reset()
                }
            }
        }
    }

    private func checkLateVIN(_ damaged: String, reportedProtocol: String? = nil) async throws {
        let sink = CapturingWireSink()
        let clock = ManualClock()
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink), clock: clock.now)
        if let reportedProtocol { _ = try await send(processor, command: "ATDPN", lines: [reportedProtocol]) }
        await assertAmbiguous(processor, command: "0902", lines: [damaged])
        if processor.isStreamDirty { try await prove(processor) }
        clock.advance(6)
        try await assertLateVINWasDiscarded(processor, sink: sink)
    }

    private func assertLateVINWasDiscarded(
        _ processor: OBDMessageProcessor, sink: CapturingWireSink,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let token = try processor.beginRequest(command: "010D")
        receive(processor, [suffix])
        receive(processor, [speed])
        let received = try await processor.awaitResponse(for: token, timeout: 0.2)
        XCTAssertTrue(received == [speed], "Synthetic VIN suffix took the speed slot", file: file, line: line)
        XCTAssertFalse(sink.text.contains(suffix), "Synthetic VIN suffix reached the wire log", file: file, line: line)
    }

    private func assertAmbiguous(
        _ processor: OBDMessageProcessor, command: String, lines: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await send(processor, command: command, lines: lines)
            XCTFail("Damaged prompt resolved the request", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OBDStreamError, .ambiguousResponse, file: file, line: line)
        }
    }

    private func prove(_ processor: OBDMessageProcessor) async throws {
        processor.beginResynchronization()
        let token = processor.beginProbeRequest(command: "ATRV")
        receive(processor, ["14.1V"])
        let received = try await processor.awaitResponse(for: token, timeout: 0.2)
        XCTAssertEqual(received, ["14.1V"])
        XCTAssertTrue(processor.confirmSynchronized())
    }

    private func send(_ processor: OBDMessageProcessor, command: String, lines: [String]) async throws -> [String] {
        let token = try processor.beginRequest(command: command)
        receive(processor, lines)
        return try await processor.awaitResponse(for: token, timeout: 0.2)
    }

    private func receive(_ processor: OBDMessageProcessor, _ lines: [String]) {
        processor.processReceivedData(Data((lines.joined(separator: "\r") + "\r>").utf8))
    }

    private func spaceFrame(_ frame: String) -> String {
        var parts = [String(frame.prefix(3))]
        var data = frame.dropFirst(3)
        while !data.isEmpty {
            parts.append(String(data.prefix(2)))
            data = data.dropFirst(2)
        }
        return parts.joined(separator: " ")
    }
}
