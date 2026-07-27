//
//  BLEMessageProcessorTests.swift
//
//  The BLE response slot, exercised directly — no CoreBluetooth needed. These cover the
//  buffer-retention rule the DTC response-pending transaction depends on: a final message that
//  arrives in the gap between one `>` and the next arm must survive, while nothing stale may ever
//  leak into an unrelated command.
//

@testable import SwiftOBD2
import XCTest

final class BLEMessageProcessorTests: XCTestCase {
    private func buffer(_ lines: String...) -> Data {
        Data((lines.joined(separator: "\r") + "\r\r>").utf8)
    }

    /// The gap race: the ECU's real answer lands after the interim `7F … 78` has been delivered
    /// and before the continuation window is armed. It used to be parsed and thrown away — the
    /// answer was lost for good — so the continuation must still find it.
    func testResponseArrivingBetweenWindowsIsRetainedForTheNextArm() async throws {
        let processor = BLEMessageProcessor()

        let first = processor.beginRequest()
        processor.processReceivedData(buffer("7E8 03 7F 03 78"))
        let interim = try await processor.awaitResponse(for: first, timeout: 1)
        XCTAssertEqual(interim, ["7E8 03 7F 03 78"])

        // No slot is armed at this instant — this is the gap.
        processor.processReceivedData(buffer("7E8 04 43 01 01 04"))

        let continuation = processor.beginContinuationRequest()
        let late = try await processor.awaitResponse(for: continuation, timeout: 1)
        XCTAssertEqual(late, ["7E8 04 43 01 01 04"])
    }

    /// A partial response spanning the gap is completed by later data, not lost.
    func testPartialResponseSpanningTheGapCompletesInTheContinuation() async throws {
        let processor = BLEMessageProcessor()

        let first = processor.beginRequest()
        processor.processReceivedData(buffer("7E8 03 7F 03 78"))
        _ = try await processor.awaitResponse(for: first, timeout: 1)

        processor.processReceivedData(Data("7E8 04 43 01".utf8)) // no prompt yet
        let continuation = processor.beginContinuationRequest()
        processor.processReceivedData(Data(" 01 04\r\r>".utf8))

        let late = try await processor.awaitResponse(for: continuation, timeout: 1)
        XCTAssertEqual(late, ["7E8 04 43 01 01 04"])
    }

    /// Retention must never become leakage: a *new* request clears whatever was left over, so an
    /// unrelated command can never be answered with the previous exchange's bytes.
    func testANewRequestDiscardsRetainedBytes() async throws {
        let processor = BLEMessageProcessor()

        let first = processor.beginRequest()
        processor.processReceivedData(buffer("7E8 03 7F 03 78"))
        _ = try await processor.awaitResponse(for: first, timeout: 1)
        processor.processReceivedData(buffer("7E8 04 43 01 01 04")) // unclaimed, retained

        let next = processor.beginRequest()
        processor.processReceivedData(buffer("7E8 06 41 00 BE 3F A8 13"))
        let lines = try await processor.awaitResponse(for: next, timeout: 1)

        XCTAssertEqual(lines, ["7E8 06 41 00 BE 3F A8 13"], "No stale line may ride along")
    }

    /// Retention is bounded: an unclaimed response bigger than the buffer cap is dropped rather
    /// than growing without limit.
    func testUnclaimedRetentionIsBounded() async {
        let processor = BLEMessageProcessor()

        let oversized = String(repeating: "7E8 02 43 00\r", count: 200)
        processor.processReceivedData(Data((oversized + "\r>").utf8))

        let token = processor.beginContinuationRequest()
        do {
            let lines = try await processor.awaitResponse(for: token, timeout: 0.3)
            XCTFail("Oversized unclaimed data must be cleared, got \(lines.count) lines")
        } catch {
            XCTAssertTrue(
                error as? BLEMessageProcessorError == .responseTimeout,
                "Unexpected error: \(error)"
            )
        }
    }

    /// `NO DATA` still reaches the caller as the distinct silence signal the DTC layer needs.
    func testNoDataIsDeliveredAsItsOwnError() async {
        let processor = BLEMessageProcessor()
        let token = processor.beginRequest()
        processor.processReceivedData(Data("NO DATA\r\r>".utf8))

        do {
            _ = try await processor.awaitResponse(for: token, timeout: 1)
            XCTFail("Expected the noData signal")
        } catch {
            XCTAssertTrue(error as? BLEManagerError == .noData, "Unexpected error: \(error)")
        }
    }
}
