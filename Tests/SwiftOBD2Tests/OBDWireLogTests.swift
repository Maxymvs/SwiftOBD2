//
//  OBDWireLogTests.swift
//  SwiftOBD2Tests
//
//  No command or response text of a manufacturer exchange may reach a log: not on success, a
//  timeout, `NO DATA`, a failed write or a listen, and not for a late answer parsed after the
//  exchange ended, until the stream is known clean.
//

@testable import SwiftOBD2
import CoreBluetooth
import XCTest

final class OBDWireLogTests: XCTestCase {
    private let adapter = UUID()
    /// Fragments of the manufacturer command and answer used below. None may be logged.
    private let secrets = ["22028D", "028D", "7E8", "0562", "0CE2", "ATSH", "7E0", "NO DATA"]

    private var sink: CapturingWireSink!
    private var processor: OBDMessageProcessor!
    private var wire: FakeAdapterWire!
    private var exchange: BLECommandExchange!

    override func setUp() {
        super.setUp()
        sink = CapturingWireSink()
        processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink))
        wire = FakeAdapterWire(processor: processor)
        exchange = BLECommandExchange(processor: processor, gate: OEMAddressingGate())
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func assertNothingSecretLogged(file: StaticString = #filePath, line: UInt = #line) {
        let logged = sink.text
        for secret in secrets {
            XCTAssertFalse(logged.contains(secret), "logged \(secret): \(logged)", file: file, line: line)
        }
    }

    private func sendRedacted(_ command: String = "22028D", deadline: TimeInterval) async throws -> [String] {
        try await exchange.send(command, retries: 1, responseTimeout: 3, deadline: deadline, policy: .redacted) {
            wire.target(adapter)
        }
    }

    // MARK: Every path of a redacted exchange

    func testSuccessLogsNoContent() async throws {
        wire.respond = { _ in "7E80562028D0CE2\r>" }
        _ = try await sendRedacted(deadline: now() + 1)
        assertNothingSecretLogged()
        XCTAssertTrue(sink.text.contains("Manufacturer exchange: answered"), sink.text)
    }

    func testTimeoutLogsNoContent() async {
        _ = try? await sendRedacted(deadline: now() + 0.1)
        assertNothingSecretLogged()
        XCTAssertTrue(sink.text.contains("(timeout)"), sink.text)
    }

    func testNoDataLogsNoContent() async {
        wire.respond = { _ in "NO DATA\r\r>" }
        _ = try? await sendRedacted(deadline: now() + 1)
        assertNothingSecretLogged()
        XCTAssertTrue(sink.text.contains("(no data)"), sink.text)
    }

    func testWriteFailureLogsNoContent() async {
        wire.writeError = BLEWriteCoordinatorError.transportWriteFailed("22028D")
        _ = try? await sendRedacted(deadline: now() + 1)
        assertNothingSecretLogged()
        XCTAssertTrue(sink.text.contains("(write failed)"), sink.text)
    }

    func testDeadlinePassedBeforeTheWriteLogsNoContent() async {
        _ = try? await sendRedacted("ATSH 7E0", deadline: now() - 1)
        assertNothingSecretLogged()
    }

    func testListenPathsLogNoContent() async throws {
        // Answered, NO DATA, timed out.
        wire.deliver("7E80562028D0CE2\r>")
        _ = try await exchange.listen(deadline: now() + 1, policy: .redacted)
        wire.deliver("NO DATA\r\r>")
        _ = try? await exchange.listen(deadline: now() + 1, policy: .redacted)
        _ = try? await exchange.listen(deadline: now() + 0.1, policy: .redacted)
        assertNothingSecretLogged()
        XCTAssertTrue(sink.text.contains("listen answered"), sink.text)
    }

    // MARK: The hold

    /// A late manufacturer answer that arrives after the exchange ended, while an ordinary
    /// command resynchronizes the stream, is still redacted: the hold lasts until the stream is
    /// known clean.
    func testALateAnswerParsedAfterTheExchangeIsStillRedacted() async throws {
        _ = try? await sendRedacted(deadline: now() + 0.1) // times out, answer still coming
        // An ordinary command. The late manufacturer answer arrives ahead of the probe's.
        wire.lateBytes = ["7E80562028D0CE2\r>"]
        wire.respond = { $0 == "ATRV" ? "12.4V\r\r>" : "ELM327 v1.5\r\r>" }
        _ = try await exchange.send("ATZ", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        assertNothingSecretLogged()
        XCTAssertTrue(processor.wireLog.isRedactionHeld)
    }

    /// The same late answer arriving while nothing is armed is dropped, and only its size is
    /// ever logged, hold or no hold.
    func testADiscardedLateAnswerIsNeverLoggedWithContent() async throws {
        _ = try? await sendRedacted(deadline: now() + 0.1)
        processor.wireLog.releaseRedaction() // even with the hold gone
        wire.deliver("7E80562028D0CE2\r>")
        assertNothingSecretLogged()
        XCTAssertTrue(sink.text.contains("Discarded a late response"), sink.text)
    }

    /// Review finding l: reconnecting to an adapter a manufacturer batch left unresolved used
    /// to end the hold when the new link's channel was validated, before the recovery (reset,
    /// re-initialization, probe) had run. The hold now stays with that adapter until its gate
    /// opens; a link to any other adapter starts unredacted.
    func testANewLinkToAnUnresolvedAdapterStaysRedacted() {
        let gate = OEMAddressingGate()
        let log = processor.wireLog
        gate.markUnresolved(adapter)

        log.releaseRedaction() // whatever the teardown left
        BLEManager.applyRedaction(forLinkTo: adapter, gate: gate, wireLog: log)
        XCTAssertTrue(log.isRedactionHeld, "the unresolved adapter's answers stay redacted through its recovery")

        BLEManager.applyRedaction(forLinkTo: UUID(), gate: gate, wireLog: log)
        XCTAssertFalse(log.isRedactionHeld, "another adapter's link is ordinary traffic")

        log.holdRedaction()
        BLEManager.applyRedaction(forLinkTo: nil, gate: gate, wireLog: log)
        XCTAssertFalse(log.isRedactionHeld)
    }

    func testReleasingTheHoldRestoresFullLogging() async throws {
        processor.wireLog.holdRedaction()
        processor.wireLog.releaseRedaction()
        wire.respond = { _ in "7E8064100BE3EB811\r>" }
        _ = try await exchange.send("0100", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertTrue(sink.text.contains("Sent command: 0100"), sink.text)
        XCTAssertTrue(sink.text.contains("7E8064100BE3EB811"), sink.text)
    }

    /// A verified recovery proves the stream clean, so it ends the hold.
    func testAVerifiedRecoveryEndsTheHold() async throws {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        exchange = BLECommandExchange(processor: processor, gate: gate)
        processor.wireLog.holdRedaction()
        let answers: [String: String] = [
            "ATZ": "ELM327 v1.5\r>", "ATE0": "ATE0\rOK\r>", "ATL0": "OK\r>", "ATS0": "OK\r>",
            "ATH1": "OK\r>", "ATSP0": "OK\r>", "0100": "7E8064100BE3EB811\r>",
        ]
        wire.respond = { answers[$0] }
        for command in ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0"] {
            _ = try await exchange.send(command, retries: 1, responseTimeout: 1) { wire.target(adapter) }
            XCTAssertTrue(processor.wireLog.isRedactionHeld, command)
        }
        _ = try await exchange.send("0100", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertFalse(gate.isUnresolved(adapter))
        XCTAssertFalse(processor.wireLog.isRedactionHeld)
    }

    // MARK: Bytes nobody claimed

    /// A late notification after teardown (the handler reset, the redaction hold released) lands
    /// on a characteristic the handler no longer owns. It may be a late manufacturer answer, so
    /// its payload is never logged, whatever the policy.
    func testUnclaimedNotificationNeverLogsPayload() {
        let handler = BLECharacteristicHandler(messageProcessor: processor)
        let stale = CBMutableCharacteristic(
            type: CBUUID(string: "FFF1"), properties: [.notify], value: nil, permissions: [.readable]
        )
        let lateAnswer = Data("7E80562028D0CE2\r\r>".utf8)

        handler.handleUpdatedValue(lateAnswer, from: stale)   // no hold: ordinary policy
        processor.wireLog.holdRedaction()
        handler.handleUpdatedValue(lateAnswer, from: stale)   // held
        processor.wireLog.releaseRedaction()
        handler.reset()
        handler.handleUpdatedValue(lateAnswer, from: stale)   // after teardown

        XCTAssertEqual(sink.records.count, 3, sink.text)
        assertNothingSecretLogged()
        XCTAssertFalse(sink.text.contains("0CE2"), sink.text)
        XCTAssertEqual(sink.records.map(\.message), [
            "18 bytes on an unclaimed characteristic",
            "Manufacturer exchange: 18 bytes on an unclaimed characteristic",
            "18 bytes on an unclaimed characteristic",
        ])
    }

    /// The event can only carry a count, and both policies render just that.
    func testUnclaimedBytesRenderCountOnlyUnderEveryPolicy() {
        XCTAssertEqual(
            OBDWireLog.render(.unclaimedBytes(byteCount: 17), policy: .full)?.message,
            "17 bytes on an unclaimed characteristic"
        )
        XCTAssertEqual(
            OBDWireLog.render(.unclaimedBytes(byteCount: 17), policy: .redacted)?.message,
            "Manufacturer exchange: 17 bytes on an unclaimed characteristic"
        )
    }

    // MARK: The decision itself

    func testRedactedRenderingNeverUsesContent() {
        let command = "22028D"
        let lines = ["7E80562028D0CE2"]
        let events: [OBDWireEvent] = [
            .sent(command: command),
            .answered(command: command, lines: lines, elapsed: 0.1),
            .parsed(lines: lines),
            .retrying(command: command, attempt: 1, attempts: 2, outcome: .timeout, detail: command),
            .failed(command: command, attempts: 1, outcome: .noData, detail: lines[0], elapsed: 0.2),
            .listenAnswered(lines: lines, elapsed: 0.1),
            .listenEnded(outcome: .timeout, detail: lines[0], elapsed: 0.1),
            .listenBudgetExhausted(command: command),
            .unclaimedBytes(byteCount: lines[0].utf8.count),
        ]
        for event in events {
            let message = OBDWireLog.render(event, policy: .redacted)?.message ?? ""
            for secret in secrets {
                XCTAssertFalse(message.contains(secret), "\(event) -> \(message)")
            }
            XCTAssertNotNil(OBDWireLog.render(event, policy: .full), "\(event)")
        }
        XCTAssertEqual(OBDWireLog.effectivePolicy(.full, redactionHeld: true), .redacted)
        XCTAssertEqual(OBDWireLog.effectivePolicy(.full, redactionHeld: false), .full)
        XCTAssertEqual(OBDWireLog.effectivePolicy(.redacted, redactionHeld: false), .redacted)
    }

    // MARK: Identifying replies (the VIN)

    /// A synthetic `49 02` reply: "SYN" and a filler. Its bytes must never be logged.
    private let vinReply = ["7E8 10 14 49 02 01 53 59 4E", "7E8 21 30 30 30 30 30 30 31"]
    private let vinFragments = ["53 59 4E", "53594E", "30 30 31", "7E8"]

    private func assertNoVINContent(_ message: String?, file: StaticString = #filePath, line: UInt = #line) {
        let message = message ?? ""
        for fragment in vinFragments {
            XCTAssertFalse(message.contains(fragment), "logged \(fragment): \(message)", file: file, line: line)
        }
    }

    func testTheIdentifyingDecision() {
        XCTAssertTrue(OBDWireLog.isIdentifying(command: "0902", lines: []))
        XCTAssertTrue(OBDWireLog.isIdentifying(command: "09 02", lines: ["NO DATA"]))
        XCTAssertTrue(OBDWireLog.isIdentifying(command: "0100", lines: vinReply), "backstop: the content")
        XCTAssertTrue(OBDWireLog.isIdentifying(command: nil, lines: ["7E8104902015359"]))
        XCTAssertFalse(OBDWireLog.isIdentifying(command: "010C", lines: ["7E804410C1F40"]))
        XCTAssertFalse(OBDWireLog.isIdentifying(command: "0904", lines: ["7E8 06 49 04 01 43 41 4C"]))
        XCTAssertFalse(OBDWireLog.isIdentifying(command: nil, lines: []))
    }

    func testA0902AnswerIsLoggedWithoutContent() {
        let record = OBDWireLog.render(.answered(command: "0902", lines: vinReply, elapsed: 0.1), policy: .full)
        assertNoVINContent(record?.message)
        XCTAssertEqual(record?.message, "Command response: identifying reply withheld (2 lines)")
    }

    func testA0902ParseIsLoggedWithoutContent() {
        let record = OBDWireLog.render(.parsed(lines: vinReply, command: "0902"), policy: .full)
        assertNoVINContent(record?.message)
        XCTAssertEqual(record?.message, "Parsed response: identifying reply withheld (2 lines)")
        // Even a 0902 reply with no 49 02 in it (a refusal) says nothing but its size.
        let refusal = OBDWireLog.render(.parsed(lines: ["7E8 03 7F 09 12"], command: "0902"), policy: .full)
        XCTAssertEqual(refusal?.message, "Parsed response: identifying reply withheld (1 line)")
    }

    /// A late VIN answer in another command's slot.
    func testAVINReplyInAnotherCommandsSlotIsLoggedWithoutContent() {
        let answered = OBDWireLog.render(.answered(command: "0100", lines: vinReply, elapsed: 0.1), policy: .full)
        let parsed = OBDWireLog.render(.parsed(lines: vinReply, command: "0100"), policy: .full)
        assertNoVINContent(answered?.message)
        assertNoVINContent(parsed?.message)
        XCTAssertNotNil(answered)
        XCTAssertNotNil(parsed)
    }

    func testAVINReplyInAListenWindowIsLoggedWithoutContent() {
        let parsed = OBDWireLog.render(.parsed(lines: vinReply, command: nil), policy: .full)
        let listened = OBDWireLog.render(.listenAnswered(lines: vinReply, elapsed: 0.1), policy: .full)
        assertNoVINContent(parsed?.message)
        assertNoVINContent(listened?.message)
        XCTAssertEqual(listened?.message, "Extra listen window delivered: identifying reply withheld (2 lines)")
    }

    func testAnOrdinaryReplyIsStillLoggedInFull() {
        let lines = ["7E804410C1F40"]
        XCTAssertEqual(
            OBDWireLog.render(.answered(command: "010C", lines: lines, elapsed: 0.1), policy: .full)?.message,
            "Command response: 7E804410C1F40"
        )
        XCTAssertEqual(
            OBDWireLog.render(.parsed(lines: lines, command: "010C"), policy: .full)?.message,
            "Parsed response: [\"7E804410C1F40\"]"
        )
        XCTAssertEqual(
            OBDWireLog.render(.listenAnswered(lines: lines, elapsed: 0.1), policy: .full)?.message,
            "Extra listen window delivered: 7E804410C1F40"
        )
    }

    func testRedactedRenderingOfIdentifyingRepliesIsUnchanged() {
        XCTAssertNil(OBDWireLog.render(.parsed(lines: vinReply, command: "0902"), policy: .redacted))
        XCTAssertEqual(
            OBDWireLog.render(.answered(command: "0902", lines: vinReply, elapsed: 0.1), policy: .redacted)?.message,
            "Manufacturer exchange: answered in 100 ms"
        )
    }

    /// End to end: the processor parses a VIN answer for a `0902` slot and the exchange logs its
    /// answer; neither shows the reply.
    func testAVINExchangeLogsNoContent() async throws {
        wire.respond = { $0 == "0902" ? "7E8 10 14 49 02 01 53 59 4E\r7E8 21 30 30 30 30 30 30 31\r\r>" : nil }
        let lines = try await exchange.send("0902", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertEqual(lines, vinReply)
        XCTAssertTrue(sink.text.contains("Sent command: 0902"), sink.text)
        XCTAssertTrue(sink.text.contains("identifying reply withheld"), sink.text)
        assertNoVINContent(sink.text)
    }

    // MARK: The VIN through UDS (`22 F1 90` -> `62 F1 90`)

    // Synthetic VIN WVWZZZ5NZLW000001 (valid shape, serial 000001): 57 56 57 5A 5A 5A 35 4E 5A
    // 4C 57 30 30 30 30 30 31. The answer is 62 F1 90 + 17 bytes = 20 (0x14) bytes.

    /// 11-bit: the first frame carries 62 F1 90 and three VIN bytes, then seven per frame.
    private let udsVINReply = [
        "7E8 10 14 62 F1 90 57 56 57", "7E8 21 5A 5A 5A 35 4E 5A 4C", "7E8 22 57 30 30 30 30 30 31",
    ]
    /// The same, headers on and spaces off, as the capture tool sees it.
    private let udsVINReplyCompact = ["7E8101462F190575657", "7E8215A5A5A354E5A4C", "7E82257303030303031"]
    /// BMW extended addressing: F1 leads every frame, so the first frame carries only five
    /// payload bytes (62 F1 90 and two VIN bytes) and the rest six.
    private let bmwVINReply = [
        "612 F1 10 14 62 F1 90 57 56", "612 F1 21 57 5A 5A 5A 35 4E",
        "612 F1 22 5A 4C 57 30 30 30", "612 F1 23 30 30 31 AA AA AA",
    ]
    private let bmwVINReplyCompact = ["612F1101462F1905756", "612F121575A5A5A354E", "612F1225A4C57303030", "612F123303031AAAAAA"]
    /// Pieces of the synthetic VIN, spaced and compacted, and the frames' headers.
    private let udsVINFragments = [
        "57 56 57", "575657", "57 56", "5A 5A 5A", "5A5A5A", "35 4E", "354E", "30 30 31", "303031",
        "WVW", "000001", "7E8", "612",
    ]

    private func assertNoUDSVINContent(_ message: String?, file: StaticString = #filePath, line: UInt = #line) {
        let message = message ?? ""
        for fragment in udsVINFragments {
            XCTAssertFalse(message.contains(fragment), "logged \(fragment): \(message)", file: file, line: line)
        }
    }

    func testTheUDSVINRequestIsIdentifyingWhateverItsAnswer() {
        XCTAssertTrue(OBDWireLog.isIdentifying(command: "22F190", lines: []))
        XCTAssertTrue(OBDWireLog.isIdentifying(command: "22 F1 90", lines: ["NO DATA"]))
        XCTAssertTrue(OBDWireLog.isIdentifying(command: "22f190", lines: ["7E8 03 7F 22 31"]), "even a refusal")
        XCTAssertFalse(OBDWireLog.isIdentifying(command: "22F191", lines: ["7E8 03 7F 22 31"]))
        XCTAssertFalse(OBDWireLog.isIdentifying(command: "22028D", lines: ["7E80562028D0CE2"]))
    }

    func testAnyReplyCarryingThe62F190AnswerIsIdentifying() {
        for reply in [udsVINReply, udsVINReplyCompact, bmwVINReply, bmwVINReplyCompact] {
            XCTAssertTrue(OBDWireLog.isIdentifying(command: nil, lines: reply), "\(reply)")
            XCTAssertTrue(OBDWireLog.isIdentifying(command: "0100", lines: reply), "late, in another slot: \(reply)")
            XCTAssertTrue(OBDWireLog.isIdentifying(command: "ATI", lines: reply), "late, in another slot: \(reply)")
        }
        // A single frame (a short identifier answer shape) and lowercase hex.
        XCTAssertTrue(OBDWireLog.isIdentifying(command: nil, lines: ["7E8 06 62 F1 90 57 56 57"]))
        XCTAssertTrue(OBDWireLog.isIdentifying(command: nil, lines: ["7e8101462f190575657"]))
        // Only the first frame carries the marker; it still covers the whole reply.
        XCTAssertTrue(OBDWireLog.isIdentifying(command: nil, lines: Array(bmwVINReply.prefix(1))))
        // Another identifier's answer is ordinary.
        XCTAssertFalse(OBDWireLog.isIdentifying(command: nil, lines: ["7E8 10 14 62 F1 91 57 56 57"]))
        XCTAssertFalse(OBDWireLog.isIdentifying(command: nil, lines: ["7E80562028D0CE2"]))
    }

    func testA22F190AnswerIsLoggedWithoutContent() {
        for reply in [udsVINReply, udsVINReplyCompact, bmwVINReply, bmwVINReplyCompact] {
            let answered = OBDWireLog.render(.answered(command: "22F190", lines: reply, elapsed: 0.1), policy: .full)
            let parsed = OBDWireLog.render(.parsed(lines: reply, command: "22F190"), policy: .full)
            assertNoUDSVINContent(answered?.message)
            assertNoUDSVINContent(parsed?.message)
            XCTAssertEqual(answered?.message, "Command response: identifying reply withheld (\(reply.count) lines)")
            XCTAssertEqual(parsed?.message, "Parsed response: identifying reply withheld (\(reply.count) lines)")
        }
        // The module's refusal in the VIN request's slot says nothing but its size.
        let refusal = OBDWireLog.render(.parsed(lines: ["7E8 03 7F 22 31"], command: "22F190"), policy: .full)
        XCTAssertEqual(refusal?.message, "Parsed response: identifying reply withheld (1 line)")
    }

    /// A late `62 F1 90` answer parsed for another command, or delivered to a listen window.
    func testA62F190ReplyInAnotherSlotOrAListenIsLoggedWithoutContent() {
        for reply in [udsVINReply, udsVINReplyCompact, bmwVINReply, bmwVINReplyCompact] {
            let messages = [
                OBDWireLog.render(.answered(command: "ATI", lines: reply, elapsed: 0.1), policy: .full)?.message,
                OBDWireLog.render(.parsed(lines: reply, command: "0100"), policy: .full)?.message,
                OBDWireLog.render(.parsed(lines: reply, command: nil), policy: .full)?.message,
                OBDWireLog.render(.listenAnswered(lines: reply, elapsed: 0.1), policy: .full)?.message,
            ]
            for message in messages {
                XCTAssertNotNil(message)
                assertNoUDSVINContent(message)
                XCTAssertTrue(message?.contains("identifying reply withheld (\(reply.count) lines)") ?? false, message ?? "")
            }
        }
    }

    /// End to end: the capture's `22F190` through the exchange.
    func testAUDSVINExchangeLogsNoContent() async throws {
        wire.respond = { $0 == "22F190" ? self.udsVINReplyCompact.joined(separator: "\r") + "\r\r>" : nil }
        let lines = try await exchange.send("22F190", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertEqual(lines, udsVINReplyCompact)
        XCTAssertTrue(sink.text.contains("Sent command: 22F190"), sink.text)
        XCTAssertTrue(sink.text.contains("identifying reply withheld (3 lines)"), sink.text)
        assertNoUDSVINContent(sink.text)
    }

    func testSplitVINContinuationsAfterProbeNeverReachWireLog() async throws {
        // Both replies carry the same synthetic 17-byte identifier.
        let mode09 = ["7E81014490201575657", "7E8215A5A5A354E5A4C", "7E82257303030303031"]
        for (command, frames) in [("0902", mode09), ("22F190", udsVINReplyCompact), ("22F190", bmwVINReplyCompact)] {
            for split in 1 ..< frames.count {
                let sink = CapturingWireSink()
                let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink))
                let wire = FakeAdapterWire(processor: processor)
                let exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
                wire.respond = { sent in
                    switch sent {
                    case command: return frames.prefix(split).joined(separator: "\r") + "\r>"
                    case "ATRV": return "14.1V\r>"
                    case "010D":
                        for frame in frames.dropFirst(split) { wire.deliver(frame + "\r>") }
                        return "7E803410D32\r>"
                    default: return nil
                    }
                }
                _ = try await exchange.send(command, retries: 1, responseTimeout: 1) { wire.target(adapter) }
                _ = try await exchange.send("010D", retries: 1, responseTimeout: 1) { wire.target(adapter) }
                XCTAssertEqual(wire.written, [command, "ATRV", "010D"])
                for frame in frames.dropFirst(split) {
                    XCTAssertFalse(sink.text.contains(frame), "VIN continuation logged for \(command) at split \(split)")
                }
            }
        }
    }

    func testVINContinuationsAreDeliveredToTheirOwnListenWithoutLogging() async throws {
        let frames = udsVINReplyCompact
        wire.respond = { _ in frames.joined(separator: "\r>") + "\r>" }

        let lines = try await exchange.transaction(
            "22F190", retries: 1, responseTimeout: 1, shouldContinueListening: { $0.count < frames.count },
            listenDeadline: 1, checkAttempt: {}, checkLink: {}
        ) { wire.target(adapter) }

        XCTAssertEqual(lines, frames)
        XCTAssertEqual(wire.written, ["22F190"])
        assertNoUDSVINContent(sink.text)
    }

    func testVINRedactionSurvivesDebtExpiryAndEndsWithTheLastFrame() async throws {
        let clock = ManualClock()
        let processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink), clock: clock.now)
        let frames = udsVINReplyCompact
        let vin = try processor.beginRequest(command: "22F190")
        processor.processReceivedData(Data((frames[0] + "\r>").utf8))
        _ = try await processor.awaitResponse(for: vin, timeout: 1)
        processor.beginResynchronization()
        XCTAssertTrue(processor.confirmSynchronized())

        clock.advance(10)
        let speed = try processor.beginRequest(command: "010D")
        for frame in frames.dropFirst() {
            processor.processReceivedData(Data((frame + "\r>").utf8))
        }
        let speedReply = "7E803410D32"
        processor.processReceivedData(Data((speedReply + "\r>").utf8))
        let lines = try await processor.awaitResponse(for: speed, timeout: 1)
        XCTAssertEqual(lines, [speedReply])
        for frame in frames { XCTAssertFalse(sink.text.contains(frame)) }

        // A new, ordinary ISO-TP reply from the same responder logs and delivers normally.
        let ordinary = ["7E8100B5902FF010203", "7E8210405060708AAAA"]
        let next = try processor.beginRequest(command: "1902FF")
        processor.processReceivedData(Data((ordinary.joined(separator: "\r") + "\r>").utf8))
        let nextLines = try await processor.awaitResponse(for: next, timeout: 1)
        XCTAssertEqual(nextLines, ordinary)
        XCTAssertTrue(sink.text.contains(ordinary[1]))
    }

    /// End to end: a BMW VIN answer that lands late, in the throwaway `ATI` after a timeout.
    func testALateBMWVINAnswerInAnotherCommandsSlotLogsNoContent() async throws {
        wire.respond = { $0 == "ATI" ? self.bmwVINReplyCompact.joined(separator: "\r") + "\r\r>" : nil }
        let lines = try await exchange.send("ATI", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertEqual(lines, bmwVINReplyCompact)
        XCTAssertTrue(sink.text.contains("Sent command: ATI"), sink.text)
        XCTAssertTrue(sink.text.contains("identifying reply withheld (4 lines)"), sink.text)
        assertNoUDSVINContent(sink.text)
    }
}
