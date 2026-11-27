//
//  OBDSlotLifecycleTests.swift
//  SwiftOBD2Tests
//
//  Two details of the response slot's lifecycle:
//
//  - The instant a reply's prompt was consumed is sampled under the lock as the response is taken
//    off the buffer, before it is parsed and logged. Time spent logging can't turn a reply that
//    landed just inside its deadline into a timeout.
//  - `releaseUnwrittenRequest(_:)` gives up a slot for which nothing was written: the stream stays
//    clean unless bytes arrived while the slot was armed.
//

@testable import SwiftOBD2
import XCTest

final class OBDPromptTimestampTests: XCTestCase {
    private var clock: ManualClock!
    private var processor: OBDMessageProcessor!
    /// How long recording a parsed response "takes": the sink moves the clock on by this much.
    private let loggingCost: TimeInterval = 1.0
    private let deadline: TimeInterval = 1_010

    override func setUp() {
        super.setUp()
        let clock = ManualClock(1_000)
        let cost = loggingCost
        let sink = CapturingWireSink()
        let wireLog = OBDWireLog(sink: { record in
            sink.sink(record)
            if record.message.hasPrefix("Parsed response") { clock.advance(cost) }
        })
        self.clock = clock
        processor = OBDMessageProcessor(wireLog: wireLog, clock: clock.now)
    }

    /// The reply lands while nobody is waiting yet (the early path).
    func testAReplyJustInsideItsDeadlineIsDeliveredWhateverLoggingCosts() async throws {
        let token = try processor.beginRequest(command: "010C")
        clock.set(deadline - 0.001)
        processor.processReceivedData(Data("7E804410C1F40\r\r>".utf8))
        XCTAssertGreaterThan(clock.now(), deadline, "precondition: logging pushed the clock past the deadline")

        let lines = try await processor.awaitResponse(for: token, deadline: deadline)
        XCTAssertEqual(lines, ["7E804410C1F40"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// The reply lands while the caller is suspended on the slot.
    func testAReplyJustInsideItsDeadlineIsDeliveredToASuspendedCaller() async throws {
        // A far deadline for the real-time timer; the manual clock decides "in time".
        let farDeadline: TimeInterval = 1_000 + 30
        let token = try processor.beginRequest(command: "010C")
        let waiting = Task { [processor] in try await processor!.awaitResponse(for: token, deadline: farDeadline) }
        try await Task.sleep(nanoseconds: 50_000_000)

        clock.set(farDeadline - 0.001)
        processor.processReceivedData(Data("7E804410C1F40\r\r>".utf8))
        XCTAssertGreaterThan(clock.now(), farDeadline)

        let lines = try await waiting.value
        XCTAssertEqual(lines, ["7E804410C1F40"])
    }

    /// Control: a reply that lands after its deadline is still a timeout.
    func testAReplyThatLandsAfterItsDeadlineIsStillATimeout() async throws {
        let token = try processor.beginRequest(command: "010C")
        clock.set(deadline + 0.001)
        processor.processReceivedData(Data("7E804410C1F40\r\r>".utf8))
        do {
            let lines = try await processor.awaitResponse(for: token, deadline: deadline)
            XCTFail("a late reply was delivered: \(lines)")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout)
        }
    }
}

final class OBDReleaseUnwrittenRequestTests: XCTestCase {
    private var processor: OBDMessageProcessor!

    override func setUp() {
        super.setUp()
        processor = OBDMessageProcessor()
    }

    private func deliver(_ text: String) {
        processor.processReceivedData(Data(text.utf8))
    }

    private func assertTokenIsDead(_ token: RequestToken, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let lines = try await processor.awaitResponse(for: token, timeout: 0.05)
            XCTFail("a released slot answered: \(lines)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .staleRequestToken, "\(error)", file: file, line: line)
        }
    }

    func testReleasingOnACleanEmptyStreamKeepsItClean() async throws {
        let token = try processor.beginRequest(command: "04")
        processor.releaseUnwrittenRequest(token)

        XCTAssertFalse(processor.isStreamDirty, "nothing was written, so nothing is outstanding")
        XCTAssertEqual(processor.unansweredCount(of: "04"), 0)
        await assertTokenIsDead(token)

        let next = try processor.beginRequest(command: "0100")
        deliver("7E8064100BE3FA813\r\r>")
        let lines = try await processor.awaitResponse(for: next, timeout: 1)
        XCTAssertEqual(lines, ["7E8064100BE3FA813"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// The caller was already suspended on the slot when it learned it may not write.
    func testReleasingASuspendedSlotEndsTheWaitAndKeepsTheStreamClean() async throws {
        let token = try processor.beginRequest(command: "04")
        let waiting = Task { [processor] in try await processor!.awaitResponse(for: token, timeout: 30) }
        try await Task.sleep(nanoseconds: 50_000_000)
        processor.releaseUnwrittenRequest(token)

        do {
            let lines = try await waiting.value
            XCTFail("a released slot answered: \(lines)")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .staleRequestToken)
        }
        XCTAssertFalse(processor.isStreamDirty)
        XCTAssertNoThrow(try processor.beginRequest(command: "0100"))
    }

    func testIncompleteBytesThatArrivedWhileArmedMakeTheStreamDirty() async throws {
        let token = try processor.beginRequest(command: "04")
        deliver("7E80144") // nobody asked; no prompt yet
        processor.releaseUnwrittenRequest(token)

        XCTAssertTrue(processor.isStreamDirty)
        await assertTokenIsDead(token)
        XCTAssertThrowsError(try processor.beginRequest(command: "0100")) {
            XCTAssertEqual($0 as? OBDStreamError, .unsynchronized)
        }
    }

    func testACompleteResponseTheSlotConsumedMakesTheStreamDirty() async throws {
        let token = try processor.beginRequest(command: "04")
        deliver("7E80144\r\r>") // consumed by the armed slot, though nothing was written for it
        processor.releaseUnwrittenRequest(token)

        XCTAssertTrue(processor.isStreamDirty)
        await assertTokenIsDead(token)
        XCTAssertThrowsError(try processor.beginRequest(command: "0100"))
    }

    /// The adapter's separator after a prompt is nobody's, so it doesn't count as bytes that
    /// arrived for the released slot.
    func testASeparatorWhileArmedKeepsTheStreamClean() throws {
        let token = try processor.beginRequest(command: "04")
        deliver("\r\n")
        processor.releaseUnwrittenRequest(token)
        XCTAssertFalse(processor.isStreamDirty)
    }
}
