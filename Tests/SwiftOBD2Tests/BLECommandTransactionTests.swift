//
//  BLECommandTransactionTests.swift
//  SwiftOBD2Tests
//
//  The Bluetooth send-and-listen transaction (`BLECommandExchange.transaction`, the body of
//  `BLEManager.sendCommandTransaction`) without CoreBluetooth. Whenever the transaction ends
//  still owing the final answer, the stream is left dirty, so that answer, arriving late, is
//  never credited to the next command. Synthetic data.
//

@testable import SwiftOBD2
import XCTest

final class BLECommandTransactionTests: XCTestCase {
    private let adapter = UUID()
    private var processor: OBDMessageProcessor!
    private var wire: FakeAdapterWire!
    private var exchange: BLECommandExchange!

    private static let ownAnswer = "7E8 06 41 00 BE 3F A8 13"

    override func setUp() {
        super.setUp()
        processor = OBDMessageProcessor()
        wire = FakeAdapterWire(processor: processor)
        exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
        exchange.listenWindowTimeout = 0.2
    }

    /// Keeps listening while any line is a `7F 03 78`, as the DTC layer's predicate does.
    private let awaitsPending: ([String]) -> Bool = { lines in
        DTCResponseParser.awaitsPendingResponse(lines: lines, service: .stored, family: .can11)
    }

    /// The module scan's read: still owed while the expected responder said only "pending".
    private let moduleReadOwed: ([String]) -> Bool = { lines in
        let compact = lines.map { $0.replacingOccurrences(of: " ", with: "").uppercased() }
        let pending = compact.contains { $0.hasPrefix("7E8") && $0.contains("7F1978") }
        let final = compact.contains { $0.hasPrefix("7E8") && $0.contains("5902") }
        return pending && !final
    }

    private func transaction(
        _ command: String,
        listenDeadline: TimeInterval,
        until shouldContinue: @escaping ([String]) -> Bool
    ) async throws -> [String] {
        try await exchange.transaction(
            command,
            retries: 1,
            responseTimeout: 1,
            shouldContinueListening: shouldContinue,
            listenDeadline: listenDeadline,
            checkAttempt: {},
            checkLink: {}
        ) { wire.target(adapter) }
    }

    /// The final answer the transaction stopped waiting for arrives as the next command goes
    /// out (ahead of whatever that command's write gets back). The next command must be
    /// preceded by a probe and get its own answer.
    private func assertLateAnswerIsNotCreditedToTheNextCommand(
        _ late: String,
        writtenBefore: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        wire.lateBytes = [late]
        wire.respond = { command in
            switch command {
            case "ATRV": return "14.1V\r\r>"
            case "0100": return Self.ownAnswer + "\r>"
            default: return nil
            }
        }
        let lines = try await exchange.send("0100", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertEqual(lines, [Self.ownAnswer], "the late answer was credited to the next command", file: file, line: line)
        XCTAssertEqual(wire.written, writtenBefore + ["ATRV", "0100"], "proven before the next write", file: file, line: line)
    }

    // MARK: Exits that still owe the final answer

    /// a. `7F 03 78`, then the adapter's own `NO DATA` in the listen window.
    func testNoDataInAListenWindowLeavesTheStreamDirty() async throws {
        wire.respond = { $0 == "03" ? "7E8 03 7F 03 78\r>NO DATA\r\r>" : nil }
        let lines = try await transaction("03", listenDeadline: 1, until: awaitsPending)
        XCTAssertEqual(lines, ["7E8 03 7F 03 78"])
        XCTAssertTrue(processor.isStreamDirty, "the module was told to wait and may still answer")

        try await assertLateAnswerIsNotCreditedToTheNextCommand("7E8 04 43 01 01 04\r>", writtenBefore: ["03"])
    }

    /// b. Cancelled between windows while the final answer is still owed.
    func testCancellationBetweenWindowsLeavesTheStreamDirty() async throws {
        wire.respond = { $0 == "03" ? "7E8 03 7F 03 78\r>" : nil }
        let awaitsPending = self.awaitsPending
        let cancelling: ([String]) -> Bool = { lines in
            // Called on the transaction's own task, right before the next window.
            withUnsafeCurrentTask { $0?.cancel() }
            return awaitsPending(lines)
        }
        let running = Task { try await self.transaction("03", listenDeadline: 5, until: cancelling) }
        do {
            _ = try await running.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(processor.isStreamDirty)

        try await assertLateAnswerIsNotCreditedToTheNextCommand("7E8 04 43 01 01 04\r>", writtenBefore: ["03"])
    }

    /// c. The listen budget runs out (on the processor's clock) while the answer is still owed.
    func testAnExhaustedBudgetLeavesTheStreamDirty() async throws {
        let clock = ManualClock()
        processor = OBDMessageProcessor(clock: clock.now)
        wire = FakeAdapterWire(processor: processor)
        exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
        exchange.listenWindowTimeout = 0.2

        wire.respond = { $0 == "03" ? "7E8 03 7F 03 78\r>" : nil }
        let awaitsPending = self.awaitsPending
        let lines = try await transaction("03", listenDeadline: 0.5, until: { lines in
            clock.advance(1) // more than the budget passes before the first window
            return awaitsPending(lines)
        })
        XCTAssertEqual(lines, ["7E8 03 7F 03 78"])
        XCTAssertTrue(processor.isStreamDirty)

        try await assertLateAnswerIsNotCreditedToTheNextCommand("7E8 04 43 01 01 04\r>", writtenBefore: ["03"])
    }

    /// d(i). The module scan's early prompt (a Veepeak v1.5 returns to its prompt right after the
    /// `78`): the final `59 02` list arriving in the next window is the transaction's.
    func testAModuleReadsFinalListInTheNextWindowIsReturned() async throws {
        wire.respond = { $0 == "1902FF" ? "7E8 03 7F 19 78\r>" : nil }
        let wire = self.wire!
        let final = Task.detached {
            try? await Task.sleep(nanoseconds: 50_000_000)
            wire.deliver("7E8 06 59 02 FF 01 23 45\r>")
        }
        let lines = try await transaction("1902FF", listenDeadline: 1, until: moduleReadOwed)
        await final.value
        XCTAssertEqual(lines, ["7E8 03 7F 19 78", "7E8 06 59 02 FF 01 23 45"])
        XCTAssertFalse(processor.isStreamDirty, "concluded: nothing is owed")
    }

    /// d(ii). The same read, but the list arrives only after the budget ran out: it is not
    /// credited to the next command.
    func testAModuleReadsListAfterTheBudgetIsNotTheNextCommandsAnswer() async throws {
        wire.respond = { $0 == "1902FF" ? "7E8 03 7F 19 78\r>" : nil }
        let lines = try await transaction("1902FF", listenDeadline: 0, until: moduleReadOwed)
        XCTAssertEqual(lines, ["7E8 03 7F 19 78"])
        XCTAssertTrue(processor.isStreamDirty)

        try await assertLateAnswerIsNotCreditedToTheNextCommand("7E8 06 59 02 FF 01 23 45\r>", writtenBefore: ["1902FF"])
    }

    // MARK: A concluded transaction stays cheap

    func testDroppedLeadingCANDigitCannotSupplyStoredCodes() async throws {
        wire.respond = { command in
            switch command {
            case "ATSP6": return "OK\r>"
            case "0601": return "E8100A460101010002\r>"
            case "ATRV": return "14.1V\r>"
            case "0101": return "7E80641018407E100\r>"
            case "03": return "7E8100A430401230124\r7E82100010003AAAAAA\r>"
            default: return nil
            }
        }

        _ = try await exchange.send("ATSP6", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        do {
            _ = try await exchange.send("0601", retries: 1, responseTimeout: 1) { wire.target(adapter) }
            XCTFail("Damaged monitor reply resolved the request")
        } catch OBDStreamError.ambiguousResponse {}
        let readiness = try await exchange.send("0101", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertEqual(readiness, ["7E80641018407E100"])

        do {
            _ = try await transaction("03", listenDeadline: 0.2, until: awaitsPending)
            XCTFail("A late monitor continuation resolved the stored-code request")
        } catch OBDStreamError.ambiguousResponse {}
        XCTAssertEqual(wire.written, ["ATSP6", "0601", "ATRV", "0101", "03"])
    }

    func testAConcludedTransactionLeavesTheStreamCleanAndTheNextCommandUnprobed() async throws {
        wire.respond = { $0 == "03" ? "7E8 03 7F 03 78\r>" : nil }
        let wire = self.wire!
        let final = Task.detached {
            try? await Task.sleep(nanoseconds: 50_000_000)
            wire.deliver("7E8 04 43 01 01 04\r>")
        }
        let lines = try await transaction("03", listenDeadline: 1, until: awaitsPending)
        await final.value
        XCTAssertEqual(lines, ["7E8 03 7F 03 78", "7E8 04 43 01 01 04"])
        XCTAssertFalse(processor.isStreamDirty)

        wire.respond = { $0 == "0100" ? Self.ownAnswer + "\r>" : nil }
        let next = try await exchange.send("0100", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertEqual(next, [Self.ownAnswer])
        XCTAssertEqual(wire.written, ["03", "0100"], "no probe on a clean stream")
    }

    /// The first send's response timeout is the caller's.
    func testTheFirstSendUsesTheGivenResponseTimeout() async throws {
        wire.respond = { _ in nil }
        let started = processor.clock()
        do {
            _ = try await exchange.transaction(
                "1902FF", retries: 1, responseTimeout: 0.1,
                shouldContinueListening: moduleReadOwed, listenDeadline: 1,
                checkAttempt: {}, checkLink: {}
            ) { wire.target(adapter) }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout)
        }
        XCTAssertLessThan(processor.clock() - started, 0.6)
    }
}
