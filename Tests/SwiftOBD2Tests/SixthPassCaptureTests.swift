import XCTest
@testable import SwiftOBD2

final class SixthPassCaptureTests: XCTestCase {
    func testCompleteLateMode09UnderNonVINCommandStaysOutOfWireLog() async throws {
        let sink = CapturingWireSink()
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink))
        let old = try processor.beginRequest(command: "0902")
        processor.abandonRequest(old)
        processor.beginResynchronization()
        let probe = processor.beginProbeRequest(command: "ATRV")
        processor.processReceivedData(Data("14.1V\r>".utf8))
        _ = try await processor.awaitResponse(for: probe, timeout: 0.2)
        XCTAssertTrue(processor.confirmSynchronized())
        let capture = try processor.beginRequest(command: "ATI")
        let frames = ["7E81014490201000000", "7E821DEADBEEF010203", "7E82204050607080900"]
        processor.processReceivedData(Data((frames.joined(separator: "\r") + "\r>").utf8))
        let lines = try await processor.awaitResponse(for: capture, timeout: 0.2)
        XCTAssertFalse(sink.text.contains(frames[1]))
        XCTAssertEqual(lines, frames)
    }
}
