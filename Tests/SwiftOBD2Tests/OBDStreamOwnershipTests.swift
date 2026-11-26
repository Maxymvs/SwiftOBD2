//
//  OBDStreamOwnershipTests.swift
//  SwiftOBD2Tests
//
//  The transport-wide rule that an answer is only ever handed to the command it belongs to
//  (review findings P1-a, P1-c, P1-f, P2-g). Real processor and real exchange behind a scripted
//  wire: a command whose slot ended without its complete reply leaves the stream dirty, and
//  nothing is written or credited until a probe's own answer proves it clean. Synthetic data.
//

@testable import SwiftOBD2
import XCTest

final class OBDStreamOwnershipTests: XCTestCase {
    private let adapter = UUID()
    private var processor: OBDMessageProcessor!
    private var wire: FakeAdapterWire!
    private var exchange: BLECommandExchange!

    override func setUp() {
        super.setUp()
        processor = OBDMessageProcessor()
        wire = FakeAdapterWire(processor: processor)
        exchange = Self.fastExchange(processor: processor)
    }

    /// The real exchange with short windows, so a timeout costs milliseconds.
    static func fastExchange(processor: OBDMessageProcessor, gate: OEMAddressingGate = OEMAddressingGate()) -> BLECommandExchange {
        var exchange = BLECommandExchange(processor: processor, gate: gate)
        exchange.retryDelay = 0.01
        exchange.resynchronization = OBDStreamResynchronizer.Timing(quietWindow: 0.02, maximumDrain: 0.2, probeWindow: 0.15)
        return exchange
    }

    private func now() -> TimeInterval { processor.clock() }

    private func send(_ command: String, retries: Int = 1, timeout: TimeInterval = 0.05) async throws -> [String] {
        try await exchange.send(command, retries: retries, responseTimeout: timeout) { wire.target(adapter) }
    }

    /// An adapter that answers the two probes and whatever `answers` lists; silent otherwise.
    private func respond(_ answers: [String: String]) {
        wire.respond = { command in
            switch command {
            case "ATRV": return "12.4V\r\r>"
            case "ATDPN": return "A6\r\r>"
            default: return answers[command]
            }
        }
    }

    private func assertTimesOut(_ command: String, retries: Int = 1, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let lines = try await send(command, retries: retries)
            XCTFail("expected a timeout, got \(lines)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout, "\(error)", file: file, line: line)
        }
    }

    // MARK: P1-a: a late reply is never the next command's answer

    /// Both `010C` attempts time out. Its reply then arrives as the next command is written. It
    /// used to be handed to `010D` and shown as 31 km/h.
    func testALatePIDReplyIsNeverCreditedToTheNextCommand() async throws {
        respond(["010D": "7E803410D20\r\r>"])
        await assertTimesOut("010C", retries: 2)

        wire.lateBytes = ["7E804410C1F40\r\r>"]
        let speed = try await send("010D")

        XCTAssertEqual(speed, ["7E803410D20"], "010D gets its own reply, not the late 010C one")
        XCTAssertEqual(wire.written, ["010C", "ATRV", "010C", "ATRV", "010D"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// A late VIN reply (`0902`) arriving in the `0100` slot used to be read as the PID bitmap.
    func testALateVINReplyIsNeverCreditedToTheSupportedPIDsRequest() async throws {
        respond(["0100": "7E8064100BE3FA813\r\r>"])
        await assertTimesOut("0902")

        wire.lateBytes = ["7E81014490201544553\r7E8215456494E303030\r7E82230303030303031\r\r>"]
        let bitmap = try await send("0100")

        XCTAssertEqual(bitmap, ["7E8064100BE3FA813"])
        XCTAssertEqual(wire.written, ["0902", "ATRV", "0100"])
    }

    /// Module scan: the brakes module's late `59 02` reply arriving in the next module's slot
    /// used to be accepted as that module's answer.
    func testALateModuleReplyIsNeverCreditedToTheNextModule() async throws {
        var asked = 0
        wire.respond = { command in
            switch command {
            case "ATRV": return "12.4V\r\r>"
            case "ATSH 70E": return "OK\r\r>"
            case "1902AE":
                asked += 1
                return asked == 1 ? nil : "778035902FF\r\r>"
            default: return nil
            }
        }
        await assertTimesOut("1902AE") // brakes, asked first, never answered in time

        wire.lateBytes = ["77D0759020A123456AE\r\r>"]
        let replyATSH70E = try await send("ATSH 70E")
        XCTAssertEqual(replyATSH70E, ["OK"])
        let reply1902AE = try await send("1902AE")
        XCTAssertEqual(reply1902AE, ["778035902FF"], "central electrics answers for itself")
    }

    /// The late reply can also arrive while nothing is armed, between two commands.
    func testALateReplyBetweenCommandsIsDiscarded() async throws {
        respond(["010D": "7E803410D20\r\r>"])
        await assertTimesOut("010C")

        wire.deliver("7E804410C1F40\r\r>")
        let reply010D = try await send("010D")
        XCTAssertEqual(reply010D, ["7E803410D20"])
    }

    /// Part of the late reply was already buffered when the slot timed out. The rest arrives
    /// with the probe. Neither half may reach anyone.
    func testASplitLateReplyIsDiscardedWhole() async throws {
        respond(["010C": "7E80441", "010D": "7E803410D20\r\r>"])
        await assertTimesOut("010C")

        wire.lateBytes = ["0C1F40\r\r>"]
        let reply010D = try await send("010D")
        XCTAssertEqual(reply010D, ["7E803410D20"])
    }

    // MARK: Dirty survives timeouts and retries; nothing is written without a proof

    func testATimedOutSlotLeavesTheStreamDirtyUntilAProbeAnswers() async throws {
        wire.respond = { _ in nil } // a silent adapter: no command and no probe is answered
        await assertTimesOut("010C")
        XCTAssertTrue(processor.isStreamDirty)

        // The next command is not written: only the probes go out. With both of them unanswered
        // nothing can prove this stream any more, and that is reported as what it is (a reconnect
        // is required), not as one more timeout.
        do {
            let lines = try await send("010D")
            XCTFail("expected reconnect required, got \(lines)")
        } catch {
            XCTAssertEqual(error as? OBDStreamError, .reconnectRequired, "\(error)")
        }
        XCTAssertEqual(wire.written, ["010C", "ATRV", "ATDPN"])
        XCTAssertTrue(processor.isStreamDirty)
        XCTAssertThrowsError(try processor.beginRequest()) { XCTAssertEqual($0 as? OBDStreamError, .unsynchronized) }
    }

    func testARetryResynchronizesBeforeItWritesAgain() async throws {
        var attempts = 0
        wire.respond = { command in
            switch command {
            case "ATRV": return "12.4V\r\r>"
            case "010C":
                attempts += 1
                return attempts == 1 ? nil : "7E804410C1F40\r\r>"
            default: return nil
            }
        }
        let lines = try await send("010C", retries: 2)
        XCTAssertEqual(lines, ["7E804410C1F40"])
        XCTAssertEqual(wire.written, ["010C", "ATRV", "010C"], "the retry is written only after the probe answered")
    }

    func testACleanStreamCostsNoProbe() async throws {
        respond(["010C": "7E804410C1F40\r\r>", "010D": "7E803410D20\r\r>"])
        for _ in 0..<5 {
            _ = try await send("010C")
            _ = try await send("010D")
        }
        XCTAssertEqual(wire.written.filter { $0.hasPrefix("AT") }, [], "no probe while every command gets its prompt")
        XCTAssertFalse(processor.isStreamDirty)
    }

    func testNoDataIsACompleteReplyAndLeavesTheStreamClean() async throws {
        wire.respond = { _ in "NO DATA\r\r>" }
        do {
            _ = try await send("010C")
            XCTFail("expected NO DATA")
        } catch {
            XCTAssertEqual(error as? BLEManagerError, .noData)
        }
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// A prompt with no text says nothing about whose prompt it is.
    func testABarePromptToACommandIsNoDataAndLeavesTheStreamDirty() async throws {
        wire.respond = { _ in "\r>" }
        do {
            _ = try await send("010C")
            XCTFail("expected NO DATA")
        } catch {
            XCTAssertEqual(error as? BLEManagerError, .noData)
        }
        XCTAssertTrue(processor.isStreamDirty)
    }

    func testAFailedWriteLeavesTheStreamDirty() async throws {
        wire.writeError = BLEWriteCoordinatorError.transportWriteFailed("x")
        _ = try? await send("010C")
        XCTAssertTrue(processor.isStreamDirty, "part of the command may be on the wire")
    }

    func testACancelledWaitLeavesTheStreamDirty() async throws {
        wire.respond = { _ in nil }
        let sending = Task { try await self.send("010C", timeout: 30) }
        try await Task.sleep(nanoseconds: 50_000_000)
        sending.cancel()
        _ = try? await sending.value
        XCTAssertTrue(processor.isStreamDirty)
    }

    func testBytesWaitingWhenACommandIsArmedMakeTheStreamDirty() throws {
        processor.processReceivedData(Data("7E804410C1F40\r\r>".utf8)) // nobody asked
        XCTAssertFalse(processor.isStreamDirty, "retained for a continuation, which may still come")
        XCTAssertThrowsError(try processor.beginRequest()) { XCTAssertEqual($0 as? OBDStreamError, .unsynchronized) }
        XCTAssertTrue(processor.isStreamDirty)
    }

    func testANewLinkStartsClean() async throws {
        wire.respond = { _ in nil }
        await assertTimesOut("010C")
        XCTAssertTrue(processor.isStreamDirty)
        processor.reset()
        XCTAssertFalse(processor.isStreamDirty)
        XCTAssertNoThrow(try processor.beginRequest())
    }

    /// What is discarded is never logged with its content, whatever the logging policy.
    func testDiscardedLateRepliesAreLoggedBySizeOnly() async throws {
        let sink = CapturingWireSink()
        processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink))
        wire = FakeAdapterWire(processor: processor)
        exchange = Self.fastExchange(processor: processor)
        respond(["010D": "7E803410D20\r\r>"])
        await assertTimesOut("010C")

        wire.deliver("7E804410C1F40\r\r>") // nothing is armed: nobody owns it
        _ = try await send("010D")

        XCTAssertFalse(sink.text.contains("410C1F40"), sink.text)
        XCTAssertTrue(sink.text.contains("Discarded a late response nobody owned (16 bytes)"), sink.text)
        XCTAssertTrue(sink.text.contains("Stream resynchronized"), sink.text)
    }

    // MARK: P1-c: a bare prompt is not the end of a listen

    func testABarePromptDoesNotEndAListen() async throws {
        wire.respond = { _ in "7E8037F2278\r\r>" }
        let pending = try await exchange.send("22028D", retries: 1, responseTimeout: 0, deadline: now() + 1) { wire.target(adapter) }
        XCTAssertEqual(pending, ["7E8037F2278"])

        let listening = Task { try await self.exchange.listen(deadline: self.now() + 2, policy: .redacted) }
        try await Task.sleep(nanoseconds: 30_000_000)
        wire.deliver("\r>") // used to end the listen as NO DATA
        try await Task.sleep(nanoseconds: 30_000_000)
        wire.deliver("7E8037F2231\r\r>")

        let final = try await listening.value
        XCTAssertEqual(final, ["7E8037F2231"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    func testAListenThatOnlySeesABarePromptTimesOutDirty() async throws {
        wire.respond = { _ in "7E8037F2278\r\r>" }
        _ = try await exchange.send("22028D", retries: 1, responseTimeout: 0, deadline: now() + 1) { wire.target(adapter) }
        wire.deliver("\r>")
        do {
            _ = try await exchange.listen(deadline: now() + 0.1, policy: .redacted)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout, "\(error)")
        }
        XCTAssertTrue(processor.isStreamDirty, "the read is unresolved: resynchronize before the next write")
    }

    func testAListenOnADirtyStreamIsRefusedAndConsumesNothing() async throws {
        wire.respond = { _ in nil }
        await assertTimesOut("22028D")
        wire.deliver("7E80562028D0CE2\r\r>") // the late answer
        do {
            let lines = try await exchange.listen(deadline: now() + 0.2, policy: .redacted)
            XCTFail("a listen on a dirty stream was handed \(lines)")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout, "\(error)")
        }
    }

    /// Two reads through the real executor. The first is answered "response pending", then a
    /// bare prompt, then its final `7F 22 31`. That final answer used to be credited to the
    /// second read, which was sent as soon as the bare prompt arrived.
    func testAFinalAnswerAfterABarePromptBelongsToTheReadThatWasPending() async throws {
        let channel = ExchangeOEMChannel(exchange: exchange, wire: wire, peripheral: adapter)
        wire.respond = { [wire] command in
            switch command {
            case "ATSH 7E0", "ATSH 7DF": return "OK\r\r>"
            case "ATRV": return "12.4V\r\r>"
            case "22028D":
                // Pending now; a bare prompt and then the final refusal shortly after.
                Task.detached {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    wire?.deliver("\r>")
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    wire?.deliver("7E8037F2231\r\r>")
                }
                return "7E8037F2278\r\r>"
            case "221010": return "7E804621010A5\r\r>"
            case "0100": return "7E8064100BE3FA813\r\r>"
            default: return nil
            }
        }
        let batch = try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1010"])
        let result = await OEMBatchExecutor(batch: batch).run(on: channel)

        XCTAssertEqual(result.reads.map(\.outcome), [
            .negativeResponse(code: 0x31),
            .values([OEMSignalValue(signalID: "LOAD", value: .number(165))]),
        ])
        XCTAssertEqual(result.adapterState, .functional)
        XCTAssertEqual(wire.written, ["ATSH 7E0", "22028D", "221010", "ATSH 7DF", "0100"])
    }

    // MARK: P1-f: a manufacturer batch after an ordinary timeout

    /// An ordinary PID times out just before the batch, and its reply arrives as the batch
    /// starts writing. It used to be taken as the answer to `ATSH 7E0`, shifting every answer
    /// after it by one.
    func testABatchAfterAnOrdinaryTimeoutResynchronizesBeforeItsFirstWrite() async throws {
        let channel = ExchangeOEMChannel(exchange: exchange, wire: wire, peripheral: adapter)
        respond([
            "ATSH 7E0": "OK\r\r>", "ATSH 7DF": "OK\r\r>",
            "22028D": "7E80562028D0CE2\r\r>", "0100": "7E8064100BE3FA813\r\r>",
        ])
        await assertTimesOut("010C")
        wire.lateBytes = ["7E804410C1F40\r\r>"]

        let batch = try OEMTestCatalog.batch("test-vw", ["E.028D"])
        let result = await OEMBatchExecutor(batch: batch).run(on: channel)

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.adapterState, .functional)
        guard case .values = result.reads.first?.outcome else {
            return XCTFail("expected a value, got \(String(describing: result.reads.first?.outcome))")
        }
        XCTAssertEqual(wire.written, ["010C", "ATRV", "ATSH 7E0", "22028D", "ATSH 7DF", "0100"])
        XCTAssertFalse(channel.markedUnresolved)
    }

    /// The same start, but the adapter answers nothing: the batch configures nothing, so there
    /// is nothing to restore and the adapter isn't marked unresolved.
    func testABatchOnAStreamThatCannotBeProvenSendsNothingButProbes() async throws {
        let channel = ExchangeOEMChannel(exchange: exchange, wire: wire, peripheral: adapter)
        wire.respond = { _ in nil }
        await assertTimesOut("010C")

        let batch = try OEMTestCatalog.batch("test-vw", ["E.028D"])
        let result = await OEMBatchExecutor(batch: batch).run(on: channel)

        XCTAssertEqual(result.reads.map(\.outcome), [.notAttempted(.streamOutOfSync)])
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.adapterState, .functional)
        XCTAssertEqual(wire.written, ["010C", "ATRV", "ATDPN"])
        XCTAssertFalse(channel.markedUnresolved)
    }

    // MARK: P2-g: one absolute instant for the write and the reply

    func testTheWriteIsHandedTheAbsoluteDeadlineUnchanged() async throws {
        wire.respond = { _ in "7E80562028D0CE2\r\r>" }
        let deadline = now() + 0.5
        _ = try await exchange.send("22028D", retries: 1, responseTimeout: 0, deadline: deadline) { wire.target(adapter) }
        XCTAssertEqual(wire.writeDeadlines, [deadline])
    }

    /// The reply's prompt is timestamped as it is consumed. One that lands after the deadline is
    /// a timeout even though the waiting task collects it at once; its prompt was consumed, so
    /// the stream stays clean.
    func testAReplyThatLandsAfterTheDeadlineIsATimeout() async throws {
        let clock = ManualClock(1_000)
        processor = OBDMessageProcessor(clock: clock.now)
        wire = FakeAdapterWire(processor: processor)
        exchange = Self.fastExchange(processor: processor)
        let deadline: TimeInterval = 1_010

        // The write is slow: the reply lands 0.2 s after the deadline, and the write only
        // returns after that.
        wire.onWrite = { _ in clock.set(deadline + 0.2) }
        wire.respond = { _ in "7E80562028D0CE2\r\r>" }
        do {
            let lines = try await exchange.send("22028D", retries: 1, responseTimeout: 0, deadline: deadline) { wire.target(adapter) }
            XCTFail("a reply that landed after the deadline was returned: \(lines)")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout, "\(error)")
        }
        XCTAssertFalse(processor.isStreamDirty, "the reply was complete: nothing is outstanding")
    }

    /// The converse: a reply that landed in time counts even when the task gets to it late.
    func testAReplyThatLandedInTimeCountsEvenWhenCollectedLate() async throws {
        let clock = ManualClock(1_000)
        processor = OBDMessageProcessor(clock: clock.now)
        wire = FakeAdapterWire(processor: processor)
        exchange = Self.fastExchange(processor: processor)
        let deadline: TimeInterval = 1_010

        // The reply lands 0.1 s before the deadline; the write returns 0.5 s after it.
        wire.onWrite = { _ in clock.set(deadline - 0.1) }
        wire.respond = { [wire] _ in
            wire?.deliver("7E80562028D0CE2\r\r>")
            clock.set(deadline + 0.5)
            return nil
        }
        let lines = try await exchange.send("22028D", retries: 1, responseTimeout: 0, deadline: deadline) { wire.target(adapter) }
        XCTAssertEqual(lines, ["7E80562028D0CE2"])
    }

    func testNothingIsWrittenOnceTheDeadlineHasPassed() async {
        do {
            _ = try await exchange.send("22028D", retries: 1, responseTimeout: 0, deadline: now() - 0.01) { wire.target(adapter) }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout)
        }
        XCTAssertEqual(wire.written, [])
        XCTAssertFalse(processor.isStreamDirty, "nothing was armed or written")
    }

    // MARK: Buffer bound

    func testAnOverflowDropsTheRestOfThatResponseAndLeavesTheStreamDirty() throws {
        processor = OBDMessageProcessor(maxBufferSize: 32)
        let token = try processor.beginRequest()
        processor.processReceivedData(Data(String(repeating: "7E8100A4902014142\r", count: 4).utf8)) // overflows, no prompt
        processor.processReceivedData(Data("7E8214344454647\r\r>".utf8)) // the tail of the same response
        XCTAssertTrue(processor.isStreamDirty)
        processor.fail(token, with: BLEMessageProcessorError.responseTimeout)
        XCTAssertThrowsError(try processor.beginRequest())
    }
}
