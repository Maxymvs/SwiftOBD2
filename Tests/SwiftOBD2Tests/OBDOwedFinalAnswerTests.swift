//
//  OBDOwedFinalAnswerTests.swift
//  SwiftOBD2Tests
//
//  P1-A: a final answer owed by a module must keep the stream from being credited to the next
//  command, whoever was waiting when the slot consumed the "response pending" (`7F <sid> 78`) or
//  the incomplete multi-frame message, and however that wait ended.
//
//  Each case is reproduced at three levels: the response slot alone (`OBDMessageProcessor`), the
//  Bluetooth exchange (`BLECommandExchange.transaction` and `.send`) with the real processor and
//  a scripted write, and the WiFi transport (`WifiManager.sendCommandTransaction` / `sendCommand`)
//  with a scripted socket. Cases A–D reproduce the bug; the controls guard against over-blocking
//  and must pass both before and after the fix.
//
//  Frames are what the adapter prints with headers on and spaces off. Synthetic data.
//

@testable import SwiftOBD2
import XCTest

final class OBDOwedFinalAnswerTests: XCTestCase {
    // MARK: Frames

    /// Mode 03: "response pending", then one stored code.
    private static let pending03 = "7E8037F0378"
    private static let final03 = "7E8044301012300"
    /// The next command's own answer.
    private static let speed = "7E803410D32"

    /// Module read `1902FF`.
    private static let pending19 = "7E8037F1978"
    /// `59 02 FF 01 02 03 | 04 05 06 07 08`: 11 bytes declared, 6 in the first frame.
    private static let firstFrame5902 = "7E8100B5902FF010203"
    /// The rest of that message: 5 bytes and 2 of padding.
    private static let consecutive5902 = "7E8210405060708AAAA"
    /// A well-formed positive answer to a *different* sub-function (`19 01`).
    private static let unrelated5901 = "7E806590100010203"
    /// The `19 02` answer as a single frame.
    private static let single5902 = "7E8065902FF012345"
    /// A terminal refusal of service 19 (sub-function not supported).
    private static let refusal19 = "7E8037F1931"

    /// `0902`, VIN `1G1ZT53826F109149`: a first frame and two consecutive frames.
    private static let vin = ["7E81014490201314731", "7E8215A543533383236", "7E82246313039313439"]

    /// Ordinary single-frame polls and their answers.
    private static let ordinary: [(command: String, reply: String)] = [
        ("010C", "7E804410C1AF8"),
        ("010D", "7E803410D32"),
        ("0105", "7E803410580"),
        ("012F", "7E803412F80"),
        ("0104", "7E803410440"),
        ("0111", "7E803411120"),
        ("0100", "7E8064100BE3FA813"),
        ("0101", "7E80641010007E100"),
    ]

    // MARK: Predicates

    /// Mode 03's predicate, as the DTC layer builds it.
    private static let awaitsPending03: @Sendable ([String]) -> Bool = { lines in
        DTCResponseParser.awaitsPendingResponse(lines: lines, service: .stored, family: .can11)
    }

    /// A module read's predicate as an app writes it: owed while the expected responder's latest
    /// message is "pending". A positive `59` (single or first frame) or a refusal of service 19
    /// ends it. So a first frame alone reads as "answered" (case C), and so does a positive answer
    /// to another sub-function (case D).
    private static let moduleReadOwed: @Sendable ([String]) -> Bool = { lines in
        var pending = false
        for line in lines {
            let compact = line.replacingOccurrences(of: " ", with: "").uppercased()
            guard compact.hasPrefix("7E8") else { continue }
            let frame = compact.dropFirst(3)
            if frame.hasPrefix("0") {
                let message = frame.dropFirst(2)
                if message.hasPrefix("7F19") {
                    pending = message.dropFirst(4).hasPrefix("78")
                } else if message.hasPrefix("59") {
                    pending = false
                }
            } else if frame.hasPrefix("1"), frame.dropFirst(4).hasPrefix("59") {
                pending = false
            }
        }
        return pending
    }

    // MARK: - Level (a): the processor alone

    private func deliver(_ text: String, to processor: OBDMessageProcessor) {
        processor.processReceivedData(Data(text.utf8))
    }

    private func roundTrip(_ processor: OBDMessageProcessor, _ command: String, _ reply: String) async throws -> [String] {
        let token = try processor.beginRequest(command: command)
        deliver(reply + "\r>", to: processor)
        return try await processor.awaitResponse(for: token, timeout: 1)
    }

    /// A write-free listen window that is handed `reply`.
    private func listen(_ processor: OBDMessageProcessor, _ reply: String) async throws -> [String] {
        let token = try processor.beginContinuationRequest()
        deliver(reply + "\r>", to: processor)
        return try await processor.awaitResponse(for: token, timeout: 1)
    }

    private func assertNextCommandCannotArm(
        _ processor: OBDMessageProcessor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try processor.beginRequest(command: "010D"),
            "the next command armed while a final answer is still owed",
            file: file, line: line
        ) { error in
            XCTAssertEqual(error as? OBDStreamError, .unsynchronized, "\(error)", file: file, line: line)
        }
        XCTAssertTrue(processor.isStreamDirty, "the stream must be dirty while an answer is owed", file: file, line: line)
    }

    private func assertNextCommandGetsItsOwnAnswer(
        _ processor: OBDMessageProcessor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertFalse(processor.isStreamDirty, "nothing is owed", file: file, line: line)
        let lines = try await roundTrip(processor, "010D", Self.speed)
        XCTAssertEqual(lines, [Self.speed], file: file, line: line)
        XCTAssertFalse(processor.isStreamDirty, file: file, line: line)
    }

    private func proveAdapterAfterPending(_ processor: OBDMessageProcessor) async throws {
        let pending = try await roundTrip(processor, "03", Self.pending03)
        XCTAssertEqual(pending, [Self.pending03])
        processor.beginResynchronization()
        let probe = processor.beginProbeRequest(command: "ATRV")
        deliver("14.1V\r>", to: processor)
        let reply = try await processor.awaitResponse(for: probe, timeout: 1)
        XCTAssertEqual(reply, ["14.1V"])
        XCTAssertTrue(processor.confirmSynchronized())
    }

    private func assertMode03StillOwed(_ processor: OBDMessageProcessor, line: UInt = #line) {
        XCTAssertThrowsError(try processor.beginRequest(command: "03"), line: line) {
            XCTAssertEqual($0 as? OBDStreamError, .ecuResponsePending, line: line)
        }
        XCTAssertFalse(processor.isStreamDirty, "The adapter is still synchronized", line: line)
    }

    func testECUDebtExpiresFiveSecondsAfterPending() async throws {
        let clock = ManualClock()
        let processor = OBDMessageProcessor(clock: clock.now)
        try await proveAdapterAfterPending(processor)
        clock.advance(4.999)
        assertMode03StillOwed(processor)
        clock.advance(0.002)
        let lines = try await roundTrip(processor, "03", Self.final03)
        XCTAssertEqual(lines, [Self.final03])
    }

    func testSecondPendingRestartsOnlyTheMatchingRespondersWindow() async throws {
        let clock = ManualClock()
        let processor = OBDMessageProcessor(clock: clock.now)
        try await proveAdapterAfterPending(processor)
        clock.advance(4)
        deliver(Self.pending03 + "\r>", to: processor)
        clock.advance(2)
        let speed = try await roundTrip(processor, "010D", "7E9024300\r" + Self.speed)
        XCTAssertEqual(speed, ["7E9024300", Self.speed], "another responder cannot discharge the debt")
        assertMode03StillOwed(processor)
        clock.advance(3.001)
        let lines = try await roundTrip(processor, "03", Self.final03)
        XCTAssertEqual(lines, [Self.final03])
    }

    func testLinkResetClearsECUDebtImmediately() async throws {
        let processor = OBDMessageProcessor()
        try await proveAdapterAfterPending(processor)
        assertMode03StillOwed(processor)
        processor.reset()
        let lines = try await roundTrip(processor, "03", Self.final03)
        XCTAssertEqual(lines, [Self.final03])
    }

    // A. Pending consumed, caller cancelled before collecting.

    func test_A_processor_pendingConsumedThenSlotFailedWithCancellation_nextCommandCannotArm() throws {
        let processor = OBDMessageProcessor()
        let token = try processor.beginRequest(command: "03")
        deliver(Self.pending03 + "\r>", to: processor)
        processor.fail(token, with: CancellationError())
        assertNextCommandCannotArm(processor)
    }

    func test_A_processor_pendingConsumedThenCancelledTaskAwaits_nextCommandCannotArm() async throws {
        let processor = OBDMessageProcessor()
        let token = try processor.beginRequest(command: "03")
        deliver(Self.pending03 + "\r>", to: processor)
        let waiting = Task { () async throws -> [String] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await processor.awaitResponse(for: token, timeout: 5)
        }
        do {
            let lines = try await waiting.value
            XCTFail("a cancelled caller collected \(lines)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        assertNextCommandCannotArm(processor)
    }

    // B. Pending consumed just after the deadline.

    /// The pending lands before anyone waits, timestamped after the deadline.
    func test_B_processor_pendingConsumedAfterTheDeadlineBeforeTheWait_nextCommandCannotArm() async throws {
        let clock = ManualClock(1_000)
        let processor = OBDMessageProcessor(clock: clock.now)
        let deadline: TimeInterval = 1_010
        let token = try processor.beginRequest(command: "03")
        clock.set(deadline + 0.001)
        deliver(Self.pending03 + "\r>", to: processor)
        do {
            let lines = try await processor.awaitResponse(for: token, deadline: deadline)
            XCTFail("a reply that landed after the deadline was returned: \(lines)")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout, "\(error)")
        }
        assertNextCommandCannotArm(processor)
    }

    /// The caller is suspended on the slot; the pending lands after the deadline on the
    /// processor's clock, before the real-time timer fires.
    func test_B_processor_pendingConsumedAfterTheDeadlineWhileSuspended_nextCommandCannotArm() async throws {
        let clock = ManualClock(1_000)
        let processor = OBDMessageProcessor(clock: clock.now)
        let deadline: TimeInterval = 1_030
        let token = try processor.beginRequest(command: "03")
        let waiting = Task { try await processor.awaitResponse(for: token, deadline: deadline) }
        try await Task.sleep(nanoseconds: 50_000_000)
        clock.set(deadline + 0.001)
        deliver(Self.pending03 + "\r>", to: processor)
        do {
            let lines = try await waiting.value
            XCTFail("a reply that landed after the deadline was returned: \(lines)")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout, "\(error)")
        }
        assertNextCommandCannotArm(processor)
    }

    // C. A first frame without its consecutive frames.

    func test_C_processor_pendingThenFirstFrameOnlyInAListen_nextCommandCannotArm() async throws {
        let processor = OBDMessageProcessor()
        let first = try await roundTrip(processor, "1902FF", Self.pending19)
        XCTAssertEqual(first, [Self.pending19])
        let window = try await listen(processor, Self.firstFrame5902)
        XCTAssertEqual(window, [Self.firstFrame5902])
        XCTAssertFalse(Self.moduleReadOwed(first + window), "precondition: the caller's predicate stops here")
        assertNextCommandCannotArm(processor)
    }

    func test_C_processor_firstFrameOnlyAsTheFirstResponse_nextCommandCannotArm() async throws {
        let processor = OBDMessageProcessor()
        let lines = try await roundTrip(processor, "1902FF", Self.firstFrame5902)
        XCTAssertEqual(lines, [Self.firstFrame5902])
        assertNextCommandCannotArm(processor)
    }

    // D. Pending, then an unrelated positive.

    func test_D_processor_pendingThenUnrelatedPositive_nextCommandCannotArm() async throws {
        let processor = OBDMessageProcessor()
        let first = try await roundTrip(processor, "1902FF", Self.pending19)
        let window = try await listen(processor, Self.unrelated5901)
        XCTAssertEqual(window, [Self.unrelated5901])
        XCTAssertFalse(Self.moduleReadOwed(first + window), "precondition: the caller's predicate stops here")
        assertNextCommandCannotArm(processor)
    }

    // Controls.

    func test_control_processor_pendingThenMatchingFinal_nextCommandArms() async throws {
        let processor = OBDMessageProcessor()
        _ = try await roundTrip(processor, "03", Self.pending03)
        let window = try await listen(processor, Self.final03)
        XCTAssertEqual(window, [Self.final03])
        try await assertNextCommandGetsItsOwnAnswer(processor)
    }

    func test_control_processor_pendingThenCompleteMultiFrameFinal_nextCommandArms() async throws {
        let processor = OBDMessageProcessor()
        _ = try await roundTrip(processor, "1902FF", Self.pending19)
        let window = try await listen(processor, Self.firstFrame5902 + "\r" + Self.consecutive5902)
        XCTAssertEqual(window, [Self.firstFrame5902, Self.consecutive5902])
        try await assertNextCommandGetsItsOwnAnswer(processor)
    }

    func test_control_processor_pendingThenTerminalRefusal_nextCommandArms() async throws {
        let processor = OBDMessageProcessor()
        _ = try await roundTrip(processor, "1902FF", Self.pending19)
        let window = try await listen(processor, Self.refusal19)
        XCTAssertEqual(window, [Self.refusal19])
        try await assertNextCommandGetsItsOwnAnswer(processor)
    }

    func test_control_processor_completeMultiFrameWithoutPending_nextCommandArms() async throws {
        let processor = OBDMessageProcessor()
        let lines = try await roundTrip(processor, "0902", Self.vin.joined(separator: "\r"))
        XCTAssertEqual(lines, Self.vin)
        try await assertNextCommandGetsItsOwnAnswer(processor)
    }

    func test_control_processor_thousandOrdinaryRoundTrips_neverDirty() async throws {
        let processor = OBDMessageProcessor()
        for index in 0..<1_000 {
            let (command, reply) = Self.ordinary[index % Self.ordinary.count]
            let lines = try await roundTrip(processor, command, reply)
            XCTAssertEqual(lines, [reply], "round trip \(index)")
            XCTAssertFalse(processor.isStreamDirty, "round trip \(index) (\(command)) left the stream dirty")
            if processor.isStreamDirty { return }
        }
    }

    // MARK: - Level (b): the Bluetooth exchange

    private let adapter = UUID()
    private var processor: OBDMessageProcessor!
    private var wire: FakeAdapterWire!
    private var exchange: BLECommandExchange!

    override func setUp() {
        super.setUp()
        rebuildExchange(clock: nil)
    }

    private func rebuildExchange(clock: ManualClock?) {
        processor = clock.map { OBDMessageProcessor(clock: $0.now) } ?? OBDMessageProcessor()
        wire = FakeAdapterWire(processor: processor)
        exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
        exchange.listenWindowTimeout = 0.2
    }

    private func transaction(
        _ command: String,
        responseTimeout: TimeInterval = 1,
        listenDeadline: TimeInterval = 1,
        until shouldContinue: @escaping ([String]) -> Bool
    ) async throws -> [String] {
        try await exchange.transaction(
            command,
            retries: 1,
            responseTimeout: responseTimeout,
            shouldContinueListening: shouldContinue,
            listenDeadline: listenDeadline,
            checkAttempt: {},
            checkLink: {}
        ) { wire.target(adapter) }
    }

    private func send(_ command: String, responseTimeout: TimeInterval = 1, deadline: TimeInterval? = nil) async throws -> [String] {
        try await exchange.send(command, retries: 1, responseTimeout: responseTimeout, deadline: deadline) {
            wire.target(adapter)
        }
    }

    /// The owed answer arrives as the next command goes out, ahead of that command's own answer.
    /// `010D` must be written only after a probe was written and answered, and get its own answer.
    private func assertExchangeNextCommandGetsItsOwnAnswer(
        late: String,
        writtenBefore: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        wire.onWrite = nil
        wire.lateBytes = [late]
        wire.respond = { command in
            switch command {
            case "ATRV": return "14.1V\r\r>"
            case "010D": return Self.speed + "\r>"
            default: return nil
            }
        }
        let lines = try await send("010D")
        XCTAssertEqual(lines, [Self.speed], "010D was handed another command's answer", file: file, line: line)
        XCTAssertEqual(
            wire.written, writtenBefore + ["ATRV", "010D"],
            "010D must be written only after a probe proved the stream", file: file, line: line
        )
    }

    private func assertExchangeNextCommandIsUnprobed(
        writtenBefore: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertFalse(processor.isStreamDirty, "nothing is owed", file: file, line: line)
        wire.lateBytes = []
        wire.respond = { $0 == "010D" ? Self.speed + "\r>" : nil }
        let lines = try await send("010D")
        XCTAssertEqual(lines, [Self.speed], file: file, line: line)
        XCTAssertEqual(wire.written, writtenBefore + ["010D"], "no probe on a clean stream", file: file, line: line)
    }

    // A.

    func test_A_exchangeTransaction_cancelledAfterPendingConsumed_nextCommandWaitsForAProbe() async throws {
        wire.respond = { command in
            guard command == "03" else { return nil }
            // The caller is cancelled as the pending lands, before the exchange collects it.
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.pending03 + "\r>"
        }
        let running = Task { try await self.transaction("03", until: Self.awaitsPending03) }
        do {
            let lines = try await running.value
            XCTFail("expected cancellation, got \(lines)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await assertExchangeNextCommandGetsItsOwnAnswer(late: Self.final03 + "\r>", writtenBefore: ["03"])
    }

    func test_A_exchangeSend_cancelledAfterPendingConsumed_nextCommandWaitsForAProbe() async throws {
        wire.respond = { command in
            guard command == "03" else { return nil }
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.pending03 + "\r>"
        }
        let running = Task { try await self.send("03") }
        do {
            let lines = try await running.value
            XCTFail("expected cancellation, got \(lines)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await assertExchangeNextCommandGetsItsOwnAnswer(late: Self.final03 + "\r>", writtenBefore: ["03"])
    }

    private func cancelMode03AfterPending() async throws {
        wire.respond = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.pending03 + "\r>"
        }
        let running = Task { try await self.transaction("03", until: Self.awaitsPending03) }
        do {
            _ = try await running.value
            XCTFail("expected cancellation after the pending reply")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPendingMode03FinalAfterProvenStreamDoesNotTakeSpeedSlot() async throws {
        try await cancelMode03AfterPending()
        wire.respond = { command in
            switch command {
            case "ATRV": return "14.1V\r>"
            case "010D":
                self.wire.deliver("7E8024300\r>")
                return Self.speed + "\r>"
            default: return nil
            }
        }

        let lines = try await send("010D")
        XCTAssertEqual(lines, [Self.speed])
        XCTAssertEqual(wire.written, ["03", "ATRV", "010D"])
    }

    func testPendingMode03FinalAfterProvenStreamCannotReportFalseClean() async throws {
        try await cancelMode03AfterPending()
        let sawProbe = expectation(description: "probe received its own reply")
        wire.respond = { command in
            if command == "ATRV" { return "14.1V\r>" }
            if command == "03" {
                if self.wire.delivered == 0 { self.wire.deliver("7E8024300\r>") }
                return Self.final03 + "\r>"
            }
            return nil
        }
        wire.onWrite = { if $0 == "ATRV" { sawProbe.fulfill() } }
        let running = Task { try await self.send("03") }
        await fulfillment(of: [sawProbe], timeout: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(wire.written, ["03", "ATRV"], "An indistinguishable request must stay unwritten")
        if wire.delivered == 0 { wire.deliver("7E8024300\r>") }

        let lines = try await running.value
        XCTAssertEqual(lines, [Self.final03])
        guard case let .answered(responders) = DTCResponseParser.parse(lines: lines, service: .stored, family: .can11)
        else { return XCTFail("the new scan must report its responder") }
        XCTAssertEqual(responders.outcomes.values.flatMap(\.codes).count, 1, "the new scan must report P0123")
        XCTAssertEqual(wire.written, ["03", "ATRV", "03"])
    }

    // B.

    /// The transaction's first send (ordinary timing): the pending lands after its response
    /// timeout on the processor's clock, while the exchange is suspended on the slot.
    func test_B_exchangeTransaction_pendingLandsAfterTheResponseTimeout_nextCommandWaitsForAProbe() async throws {
        let clock = ManualClock(1_000)
        rebuildExchange(clock: clock)
        wire.respond = { _ in nil }
        let wire = self.wire!
        let late = Task.detached {
            for _ in 0..<2_000 where !wire.written.contains("03") {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // the exchange is now suspended on the slot
            clock.advance(5) // past the 1 s response timeout; the real-time timer hasn't fired
            wire.deliver(Self.pending03 + "\r>")
            clock.advance(1) // then quiet
        }
        do {
            let lines = try await transaction("03", responseTimeout: 1, until: Self.awaitsPending03)
            XCTFail("a reply that landed after the timeout was returned: \(lines)")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout, "\(error)")
        }
        await late.value
        try await assertExchangeNextCommandGetsItsOwnAnswer(late: Self.final03 + "\r>", writtenBefore: ["03"])
    }

    /// The manufacturer channel's absolute deadline: the pending lands 0.2 s after it.
    func test_B_exchangeSend_deadlineMode_pendingLandsAfterTheDeadline_nextCommandWaitsForAProbe() async throws {
        let clock = ManualClock(1_000)
        rebuildExchange(clock: clock)
        let deadline: TimeInterval = 1_010
        wire.onWrite = { command in if command == "03" { clock.set(deadline + 0.2) } }
        wire.respond = { $0 == "03" ? Self.pending03 + "\r>" : nil }
        do {
            let lines = try await send("03", responseTimeout: 0, deadline: deadline)
            XCTFail("a reply that landed after the deadline was returned: \(lines)")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout, "\(error)")
        }
        clock.advance(1) // quiet
        try await assertExchangeNextCommandGetsItsOwnAnswer(late: Self.final03 + "\r>", writtenBefore: ["03"])
    }

    // C.

    func test_C_exchangeTransaction_pendingThenFirstFrameOnly_nextCommandWaitsForAProbe() async throws {
        wire.respond = { $0 == "1902FF" ? Self.pending19 + "\r>" + Self.firstFrame5902 + "\r>" : nil }
        let lines = try await transaction("1902FF", until: Self.moduleReadOwed)
        XCTAssertEqual(lines, [Self.pending19, Self.firstFrame5902])
        try await assertExchangeNextCommandGetsItsOwnAnswer(late: Self.consecutive5902 + "\r>", writtenBefore: ["1902FF"])
    }

    func test_C_exchangeSend_pendingThenListenGetsFirstFrameOnly_nextCommandWaitsForAProbe() async throws {
        wire.respond = { $0 == "1902FF" ? Self.pending19 + "\r>" + Self.firstFrame5902 + "\r>" : nil }
        let first = try await send("1902FF")
        XCTAssertEqual(first, [Self.pending19])
        let window = try await exchange.listen(deadline: processor.clock() + 1, policy: .full)
        XCTAssertEqual(window, [Self.firstFrame5902])
        try await assertExchangeNextCommandGetsItsOwnAnswer(late: Self.consecutive5902 + "\r>", writtenBefore: ["1902FF"])
    }

    func test_C_exchangeSend_firstFrameOnlyAsTheFirstResponse_nextCommandWaitsForAProbe() async throws {
        wire.respond = { $0 == "1902FF" ? Self.firstFrame5902 + "\r>" : nil }
        let lines = try await send("1902FF")
        XCTAssertEqual(lines, [Self.firstFrame5902])
        try await assertExchangeNextCommandGetsItsOwnAnswer(late: Self.consecutive5902 + "\r>", writtenBefore: ["1902FF"])
    }

    // D.

    func test_D_exchangeTransaction_pendingThenUnrelatedPositive_nextCommandWaitsForAProbe() async throws {
        wire.respond = { $0 == "1902FF" ? Self.pending19 + "\r>" + Self.unrelated5901 + "\r>" : nil }
        let lines = try await transaction("1902FF", until: Self.moduleReadOwed)
        XCTAssertEqual(lines, [Self.pending19, Self.unrelated5901])
        try await assertExchangeNextCommandGetsItsOwnAnswer(late: Self.single5902 + "\r>", writtenBefore: ["1902FF"])
    }

    func test_D_exchangeSend_pendingThenListenGetsUnrelatedPositive_nextCommandWaitsForAProbe() async throws {
        wire.respond = { $0 == "1902FF" ? Self.pending19 + "\r>" + Self.unrelated5901 + "\r>" : nil }
        _ = try await send("1902FF")
        let window = try await exchange.listen(deadline: processor.clock() + 1, policy: .full)
        XCTAssertEqual(window, [Self.unrelated5901])
        try await assertExchangeNextCommandGetsItsOwnAnswer(late: Self.single5902 + "\r>", writtenBefore: ["1902FF"])
    }

    // Controls.

    func test_control_exchangeTransaction_pendingThenMatchingFinal_nextCommandUnprobed() async throws {
        wire.respond = { $0 == "03" ? Self.pending03 + "\r>" + Self.final03 + "\r>" : nil }
        let lines = try await transaction("03", until: Self.awaitsPending03)
        XCTAssertEqual(lines, [Self.pending03, Self.final03])
        try await assertExchangeNextCommandIsUnprobed(writtenBefore: ["03"])
    }

    func test_control_exchangeTransaction_pendingThenCompleteMultiFrameFinal_nextCommandUnprobed() async throws {
        wire.respond = { command in
            command == "1902FF"
                ? Self.pending19 + "\r>" + Self.firstFrame5902 + "\r" + Self.consecutive5902 + "\r>"
                : nil
        }
        let lines = try await transaction("1902FF", until: Self.moduleReadOwed)
        XCTAssertEqual(lines, [Self.pending19, Self.firstFrame5902, Self.consecutive5902])
        try await assertExchangeNextCommandIsUnprobed(writtenBefore: ["1902FF"])
    }

    func test_control_exchangeTransaction_pendingThenTerminalRefusal_nextCommandUnprobed() async throws {
        wire.respond = { $0 == "1902FF" ? Self.pending19 + "\r>" + Self.refusal19 + "\r>" : nil }
        let lines = try await transaction("1902FF", until: Self.moduleReadOwed)
        XCTAssertEqual(lines, [Self.pending19, Self.refusal19])
        try await assertExchangeNextCommandIsUnprobed(writtenBefore: ["1902FF"])
    }

    func test_control_exchangeSend_completeMultiFrameWithoutPending_nextCommandUnprobed() async throws {
        wire.respond = { $0 == "0902" ? Self.vin.joined(separator: "\r") + "\r>" : nil }
        let lines = try await send("0902")
        XCTAssertEqual(lines, Self.vin)
        try await assertExchangeNextCommandIsUnprobed(writtenBefore: ["0902"])
    }

    func test_control_exchangeSend_thousandOrdinaryRoundTrips_neverDirtyNeverProbed() async throws {
        let replies = Dictionary(uniqueKeysWithValues: Self.ordinary.map { ($0.command, $0.reply + "\r>") })
        wire.respond = { replies[$0] }
        for index in 0..<1_000 {
            let (command, reply) = Self.ordinary[index % Self.ordinary.count]
            let lines = try await send(command)
            XCTAssertEqual(lines, [reply], "round trip \(index)")
            XCTAssertFalse(processor.isStreamDirty, "round trip \(index) (\(command)) left the stream dirty")
            if processor.isStreamDirty { return }
        }
        XCTAssertEqual(wire.written.filter { $0.hasPrefix("AT") }, [], "no probe was ever written")
        XCTAssertEqual(wire.written.count, 1_000)
    }

    // MARK: - Level (c): the WiFi transport

    private func makeManager(_ socket: ScriptedWifiSocket, readTimeout: TimeInterval = 1.0) -> WifiManager {
        let manager = WifiManager()
        manager.readTimeout = readTimeout
        manager.listenWindowTimeout = readTimeout
        manager.resynchronization = OBDStreamResynchronizer.Timing(quietWindow: 0.02, maximumDrain: 0.2, probeWindow: 0.5)
        manager.attach(socket: socket)
        manager.connectionState = .connectedToVehicle
        return manager
    }

    private func assertWifiNextCommandGetsItsOwnAnswer(
        _ manager: WifiManager,
        _ socket: ScriptedWifiSocket,
        late: String,
        writtenBefore: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        socket.afterSend = nil
        socket.lateBytes = [late]
        socket.respond = { command in
            switch command {
            case "ATRV": return "12.4V\r\r>"
            case "010D": return Self.speed + "\r>"
            default: return nil
            }
        }
        let lines = try await manager.sendCommand("010D", retries: 1)
        XCTAssertEqual(lines, [Self.speed], "010D was handed another command's answer", file: file, line: line)
        XCTAssertEqual(
            socket.sentCommands, writtenBefore + ["ATRV", "010D"],
            "010D must be written only after a probe proved the stream", file: file, line: line
        )
    }

    private func assertWifiNextCommandIsUnprobed(
        _ manager: WifiManager,
        _ socket: ScriptedWifiSocket,
        writtenBefore: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertFalse(manager.isStreamDirty, "nothing is owed", file: file, line: line)
        socket.lateBytes = []
        socket.respond = { $0 == "010D" ? Self.speed + "\r>" : nil }
        let lines = try await manager.sendCommand("010D", retries: 1)
        XCTAssertEqual(lines, [Self.speed], file: file, line: line)
        XCTAssertEqual(socket.sentCommands, writtenBefore + ["010D"], "no probe on a clean stream", file: file, line: line)
    }

    private func isTimeout(_ error: Error) -> Bool {
        if case CommunicationError.timeout = error { return true }
        return false
    }

    func testWifiFiltersOldMode03FinalSharingTheSpeedPromptAfterProof() async throws {
        let socket = ScriptedWifiSocket()
        let manager = makeManager(socket)
        socket.respond = { command in
            switch command {
            case "03": return Self.pending03 + "\r>"
            case "ATRV": return "14.1V\r>"
            case "010D": return "7E8024300\r" + Self.speed + "\r>"
            default: return nil
            }
        }
        _ = try await manager.sendCommand("03", retries: 1)
        let speed = try await manager.sendCommand("010D", retries: 1)
        XCTAssertEqual(speed, [Self.speed])
        XCTAssertEqual(socket.sentCommands, ["03", "ATRV", "010D"])
    }

    // A.

    func test_A_wifiTransaction_cancelledAfterPendingConsumed_nextCommandWaitsForAProbe() async throws {
        let socket = ScriptedWifiSocket()
        let manager = makeManager(socket)
        let handle = CancelHandle()
        socket.respond = { $0 == "03" ? Self.pending03 + "\r>" : nil }
        // Once the pending is in the slot and before the write returns: the caller is cancelled
        // before the transport collects it.
        socket.afterSend = { if $0 == "03" { handle.cancelWhenSet() } }
        let transaction = Task {
            try await manager.sendCommandTransaction(
                "03", retries: 1, shouldContinueListening: Self.awaitsPending03, listenDeadline: 1
            )
        }
        handle.set { transaction.cancel() }
        do {
            let lines = try await transaction.value
            XCTFail("expected cancellation, got \(lines)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await assertWifiNextCommandGetsItsOwnAnswer(manager, socket, late: Self.final03 + "\r>", writtenBefore: ["03"])
    }

    func test_A_wifiSend_cancelledAfterPendingConsumed_nextCommandWaitsForAProbe() async throws {
        let socket = ScriptedWifiSocket()
        let manager = makeManager(socket)
        let handle = CancelHandle()
        socket.respond = { $0 == "03" ? Self.pending03 + "\r>" : nil }
        socket.afterSend = { if $0 == "03" { handle.cancelWhenSet() } }
        let request = Task { try await manager.sendCommand("03", retries: 1) }
        handle.set { request.cancel() }
        do {
            let lines = try await request.value
            XCTFail("expected cancellation, got \(lines)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await assertWifiNextCommandGetsItsOwnAnswer(manager, socket, late: Self.final03 + "\r>", writtenBefore: ["03"])
    }

    // B. WiFi's processor runs on the real clock and can't be given another, so "consumed just
    // after the deadline" can only be reached by racing the real timer: the pending is delivered
    // at instants spread around the read timeout. An iteration that consumed it after the
    // deadline but before the timer fired is the bug; one the timer won is dirty anyway.

    private static let raceTimeout: TimeInterval = 0.03
    /// Delivery offsets from the write, around the read timeout (the wait starts a little after
    /// the write, so the spread leans late).
    private static let raceOffsets: [TimeInterval] = (0..<24).map { raceTimeout - 0.0005 + Double($0) * 0.00025 }

    func test_B_wifiTransaction_pendingRacingTheReadTimeout_neverLeavesTheStreamClean() async throws {
        var inTime = 0, timedOutDirty = 0, timedOutClean = 0
        for round in 0..<3 {
            for (index, offset) in Self.raceOffsets.enumerated() {
                let socket = ScriptedWifiSocket()
                let manager = makeManager(socket, readTimeout: Self.raceTimeout)
                let delivered = expectation(description: "delivered")
                socket.afterSend = { command in
                    guard command == "03" else { return }
                    DispatchQueue.global().asyncAfter(deadline: .now() + offset) {
                        socket.deliver(Self.pending03 + "\r>")
                        delivered.fulfill()
                    }
                }
                do {
                    // A pending in time is followed by an exhausted listen budget: dirty either way.
                    _ = try await manager.sendCommandTransaction(
                        "03", retries: 1, shouldContinueListening: Self.awaitsPending03, listenDeadline: 0
                    )
                    inTime += 1
                } catch where isTimeout(error) {
                    if manager.isStreamDirty { timedOutDirty += 1 } else { timedOutClean += 1 }
                }
                await fulfillment(of: [delivered], timeout: 2)
                XCTAssertTrue(
                    manager.isStreamDirty,
                    "round \(round) offset \(index): the pending was consumed and the stream is clean"
                )
            }
        }
        print("OBDOwedFinalAnswerTests WiFi transaction race: inTime=\(inTime) timedOutDirty=\(timedOutDirty) timedOutClean=\(timedOutClean)")
    }

    func test_B_wifiSend_pendingRacingTheReadTimeout_aTimedOutSendNeverLeavesTheStreamClean() async throws {
        var inTime = 0, timedOutDirty = 0, timedOutClean = 0
        for round in 0..<3 {
            for (index, offset) in Self.raceOffsets.enumerated() {
                let socket = ScriptedWifiSocket()
                let manager = makeManager(socket, readTimeout: Self.raceTimeout)
                let delivered = expectation(description: "delivered")
                socket.afterSend = { command in
                    guard command == "03" else { return }
                    DispatchQueue.global().asyncAfter(deadline: .now() + offset) {
                        socket.deliver(Self.pending03 + "\r>")
                        delivered.fulfill()
                    }
                }
                var timedOut = false
                do {
                    _ = try await manager.sendCommand("03", retries: 1)
                    inTime += 1
                } catch where isTimeout(error) {
                    timedOut = true
                    if manager.isStreamDirty { timedOutDirty += 1 } else { timedOutClean += 1 }
                }
                await fulfillment(of: [delivered], timeout: 2)
                // Only the timed-out iterations are case B. (A plain send that gets its pending in
                // time is a different question, not asserted here.)
                if timedOut {
                    XCTAssertTrue(
                        manager.isStreamDirty,
                        "round \(round) offset \(index): the pending was consumed after the timeout and the stream is clean"
                    )
                }
            }
        }
        print("OBDOwedFinalAnswerTests WiFi send race: inTime=\(inTime) timedOutDirty=\(timedOutDirty) timedOutClean=\(timedOutClean)")
    }

    // C.

    func test_C_wifiTransaction_pendingThenFirstFrameOnly_nextCommandWaitsForAProbe() async throws {
        let socket = ScriptedWifiSocket()
        let manager = makeManager(socket)
        socket.respond = { $0 == "1902FF" ? Self.pending19 + "\r>" + Self.firstFrame5902 + "\r>" : nil }
        let lines = try await manager.sendCommandTransaction(
            "1902FF", retries: 1, shouldContinueListening: Self.moduleReadOwed, listenDeadline: 1
        )
        XCTAssertEqual(lines, [Self.pending19, Self.firstFrame5902])
        try await assertWifiNextCommandGetsItsOwnAnswer(manager, socket, late: Self.consecutive5902 + "\r>", writtenBefore: ["1902FF"])
    }

    func test_C_wifiSend_firstFrameOnlyAsTheFirstResponse_nextCommandWaitsForAProbe() async throws {
        let socket = ScriptedWifiSocket()
        let manager = makeManager(socket)
        socket.respond = { $0 == "1902FF" ? Self.firstFrame5902 + "\r>" : nil }
        let lines = try await manager.sendCommand("1902FF", retries: 1)
        XCTAssertEqual(lines, [Self.firstFrame5902])
        try await assertWifiNextCommandGetsItsOwnAnswer(manager, socket, late: Self.consecutive5902 + "\r>", writtenBefore: ["1902FF"])
    }

    // D.

    func test_D_wifiTransaction_pendingThenUnrelatedPositive_nextCommandWaitsForAProbe() async throws {
        let socket = ScriptedWifiSocket()
        let manager = makeManager(socket)
        socket.respond = { $0 == "1902FF" ? Self.pending19 + "\r>" + Self.unrelated5901 + "\r>" : nil }
        let lines = try await manager.sendCommandTransaction(
            "1902FF", retries: 1, shouldContinueListening: Self.moduleReadOwed, listenDeadline: 1
        )
        XCTAssertEqual(lines, [Self.pending19, Self.unrelated5901])
        try await assertWifiNextCommandGetsItsOwnAnswer(manager, socket, late: Self.single5902 + "\r>", writtenBefore: ["1902FF"])
    }

    // Controls.

    func test_control_wifiTransaction_pendingThenMatchingFinal_nextCommandUnprobed() async throws {
        let socket = ScriptedWifiSocket()
        let manager = makeManager(socket)
        socket.respond = { $0 == "03" ? Self.pending03 + "\r>" + Self.final03 + "\r>" : nil }
        let lines = try await manager.sendCommandTransaction(
            "03", retries: 1, shouldContinueListening: Self.awaitsPending03, listenDeadline: 1
        )
        XCTAssertEqual(lines, [Self.pending03, Self.final03])
        try await assertWifiNextCommandIsUnprobed(manager, socket, writtenBefore: ["03"])
    }

    func test_control_wifiTransaction_pendingThenCompleteMultiFrameFinal_nextCommandUnprobed() async throws {
        let socket = ScriptedWifiSocket()
        let manager = makeManager(socket)
        socket.respond = { command in
            command == "1902FF"
                ? Self.pending19 + "\r>" + Self.firstFrame5902 + "\r" + Self.consecutive5902 + "\r>"
                : nil
        }
        let lines = try await manager.sendCommandTransaction(
            "1902FF", retries: 1, shouldContinueListening: Self.moduleReadOwed, listenDeadline: 1
        )
        XCTAssertEqual(lines, [Self.pending19, Self.firstFrame5902, Self.consecutive5902])
        try await assertWifiNextCommandIsUnprobed(manager, socket, writtenBefore: ["1902FF"])
    }

    func test_control_wifiTransaction_pendingThenTerminalRefusal_nextCommandUnprobed() async throws {
        let socket = ScriptedWifiSocket()
        let manager = makeManager(socket)
        socket.respond = { $0 == "1902FF" ? Self.pending19 + "\r>" + Self.refusal19 + "\r>" : nil }
        let lines = try await manager.sendCommandTransaction(
            "1902FF", retries: 1, shouldContinueListening: Self.moduleReadOwed, listenDeadline: 1
        )
        XCTAssertEqual(lines, [Self.pending19, Self.refusal19])
        try await assertWifiNextCommandIsUnprobed(manager, socket, writtenBefore: ["1902FF"])
    }

    func test_control_wifiSend_completeMultiFrameWithoutPending_nextCommandUnprobed() async throws {
        let socket = ScriptedWifiSocket()
        let manager = makeManager(socket)
        socket.respond = { $0 == "0902" ? Self.vin.joined(separator: "\r") + "\r>" : nil }
        let lines = try await manager.sendCommand("0902", retries: 1)
        XCTAssertEqual(lines, Self.vin)
        try await assertWifiNextCommandIsUnprobed(manager, socket, writtenBefore: ["0902"])
    }

    func test_control_wifiSend_thousandOrdinaryRoundTrips_neverDirtyNeverProbed() async throws {
        let socket = ScriptedWifiSocket()
        let manager = makeManager(socket)
        let replies = Dictionary(uniqueKeysWithValues: Self.ordinary.map { ($0.command, $0.reply + "\r>") })
        socket.respond = { replies[$0] }
        for index in 0..<1_000 {
            let (command, reply) = Self.ordinary[index % Self.ordinary.count]
            let lines = try await manager.sendCommand(command, retries: 1)
            XCTAssertEqual(lines, [reply], "round trip \(index)")
            XCTAssertFalse(manager.isStreamDirty, "round trip \(index) (\(command)) left the stream dirty")
            if manager.isStreamDirty { return }
        }
        XCTAssertEqual(socket.sentCommands.filter { $0.hasPrefix("AT") }, [], "no probe was ever written")
        XCTAssertEqual(socket.sentCommands.count, 1_000)
    }
}

// MARK: - Test doubles

/// A scripted socket: what an answer the adapter sends back for a command is delivered from
/// inside the write, through the transport's own receive pump, before the write reports back.
/// `lateBytes` arrive first, the way a real adapter answers in order.
private final class ScriptedWifiSocket: WifiSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingRead: ((Result<Data, WifiSocketError>) -> Void)?
    private var sends: [String] = []
    private var responder: (String) -> String? = { _ in nil }
    private var late: [String] = []
    private var observer: ((String) -> Void)?

    var respond: (String) -> String? {
        get { lock.withLock { responder } }
        set { lock.withLock { responder = newValue } }
    }

    var lateBytes: [String] {
        get { lock.withLock { late } }
        set { lock.withLock { late = newValue } }
    }

    /// Called after a write's answer was delivered, before the write reports back.
    var afterSend: ((String) -> Void)? {
        get { lock.withLock { observer } }
        set { lock.withLock { observer = newValue } }
    }

    var sentCommands: [String] { lock.withLock { sends } }

    func send(_ data: Data, completion: @escaping (Result<Void, WifiSocketError>) -> Void) {
        let command = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let (pendingLate, respond, after) = lock.withLock { () -> ([String], (String) -> String?, ((String) -> Void)?) in
            sends.append(command)
            defer { late = [] }
            return (late, responder, observer)
        }
        for text in pendingLate { deliver(text) }
        if let answer = respond(command) { deliver(answer) }
        after?(command)
        completion(.success(()))
    }

    func receive(_ completion: @escaping (Result<Data, WifiSocketError>) -> Void) {
        lock.withLock { pendingRead = completion }
    }

    func cancel() {
        lock.withLock { pendingRead = nil }
    }

    /// Resolves the armed read; the pump re-arms from inside the completion.
    func deliver(_ text: String) {
        let completion = lock.withLock { () -> ((Result<Data, WifiSocketError>) -> Void)? in
            defer { pendingRead = nil }
            return pendingRead
        }
        completion?(.success(Data(text.utf8)))
    }
}

/// Lets a write cancel the task that issued it, once the test has handed the task over.
private final class CancelHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancel: (() -> Void)?

    func set(_ cancel: @escaping () -> Void) {
        lock.withLock { self.cancel = cancel }
    }

    /// Waits (briefly) for the task to be handed over, then cancels it.
    func cancelWhenSet() {
        for _ in 0..<20_000 {
            if let cancel = lock.withLock({ self.cancel }) {
                cancel()
                return
            }
            usleep(100)
        }
    }
}
