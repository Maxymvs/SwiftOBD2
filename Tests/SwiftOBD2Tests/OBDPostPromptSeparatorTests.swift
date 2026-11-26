//
//  OBDPostPromptSeparatorTests.swift
//  SwiftOBD2Tests
//
//  Some adapters send a CR/LF after the prompt (`ELM327 v1.5\r\r>\r\n`). That whitespace is
//  nobody's: it must not read as unowned bytes when the next command arms (which used to turn the
//  stream dirty on every connect and send it into recovery), as a stale fragment that swallows a
//  probe's answer, or as bytes following a probe's answer. Non-whitespace still counts, and
//  whitespace inside a response is untouched. Real processor and real exchange behind a scripted
//  wire; synthetic data.
//

@testable import SwiftOBD2
import XCTest

final class OBDPostPromptSeparatorTests: XCTestCase {
    private let adapter = UUID()
    private var processor: OBDMessageProcessor!
    private var wire: FakeAdapterWire!
    private var exchange: BLECommandExchange!

    override func setUp() {
        super.setUp()
        processor = OBDMessageProcessor()
        wire = FakeAdapterWire(processor: processor)
        exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
    }

    private func deliver(_ text: String) {
        processor.processReceivedData(Data(text.utf8))
    }

    /// One command through the processor alone: arm, the adapter's bytes, the answer.
    private func command(_ command: String, answer: String) async throws -> [String] {
        let token = try processor.beginRequest(command: command)
        deliver(answer)
        return try await processor.awaitResponse(for: token, timeout: 1)
    }

    private func send(_ command: String, timeout: TimeInterval = 0.3) async throws -> [String] {
        try await exchange.send(command, retries: 1, responseTimeout: timeout) { wire.target(adapter) }
    }

    /// Answers the two probes and whatever `answers` lists; silent otherwise.
    private func respond(_ answers: [String: String]) {
        wire.respond = { command in
            switch command {
            case "ATRV": return "12.4V\r\r>"
            case "ATDPN": return "A6\r\r>"
            default: return answers[command]
            }
        }
    }

    private var probesWritten: [String] {
        wire.written.filter { $0 == "ATRV" || $0 == "ATDPN" }
    }

    // MARK: - Processor: the separator after a prompt

    func testCoalescedSeparatorLeavesTheStreamCleanForTheNextCommand() async throws {
        let identity = try await command("ATZ", answer: "ELM327 v1.5\r\r>\r\n")
        XCTAssertEqual(identity, ["ELM327 v1.5"])
        XCTAssertFalse(processor.isStreamDirty)

        let echo = try await command("ATE0", answer: "OK\r\r>")
        XCTAssertEqual(echo, ["OK"], "the next command arms and gets its own answer")
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// The separator arrives in its own chunk before the next command arms.
    func testASeparatorInALaterChunkBeforeTheNextArmIsNobodys() async throws {
        _ = try await command("ATZ", answer: "ELM327 v1.5\r\r>")
        deliver("\r\n")
        XCTAssertFalse(processor.isStreamDirty)

        let echo = try await command("ATE0", answer: "OK\r\r>")
        XCTAssertEqual(echo, ["OK"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// The separator arrives after the next command was armed and written, before its answer.
    func testASeparatorAfterTheNextArmIsNotPartOfItsAnswer() async throws {
        _ = try await command("ATZ", answer: "ELM327 v1.5\r\r>")
        let token = try processor.beginRequest(command: "ATE0")
        deliver("\r\n")
        deliver("OK\r\r>")
        let echo = try await processor.awaitResponse(for: token, timeout: 1)
        XCTAssertEqual(echo, ["OK"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// A dirty stream whose only buffered bytes are a separator: the first probe's answer is the
    /// probe's, not a stale fragment's tail.
    func testOnASeparatorOnlyDirtyStreamTheFirstProbesAnswerIsDelivered() async throws {
        let timedOut = try processor.beginRequest(command: "010C")
        processor.fail(timedOut, with: OBDMessageProcessorError.responseTimeout)
        XCTAssertTrue(processor.isStreamDirty)
        deliver("7E804410C1F40\r\r>\r\n") // the late answer and the adapter's separator

        processor.beginResynchronization()
        let probe = processor.beginProbeRequest(command: "ATRV")
        deliver("12.4V\r\r>")
        let lines = try await processor.awaitResponse(for: probe, timeout: 1)
        XCTAssertEqual(lines, ["12.4V"], "the probe's own answer, not swallowed as stale")
        XCTAssertTrue(processor.confirmSynchronized())
        XCTAssertFalse(processor.isStreamDirty)
    }

    func testOnlyASeparatorBufferedOnADirtyStreamDoesNotSwallowTheProbe() async throws {
        processor.markStreamDirty()
        deliver("\r\n")

        processor.beginResynchronization()
        let probe = processor.beginProbeRequest(command: "ATDPN")
        deliver("A6\r\r>")
        let lines = try await processor.awaitResponse(for: probe, timeout: 1)
        XCTAssertEqual(lines, ["A6"])
        XCTAssertTrue(processor.confirmSynchronized())
    }

    /// A probe's answer followed by the adapter's separator in the same chunk still proves the
    /// stream: the separator is not "bytes after the answer".
    func testAProbeAnswerFollowedByACoalescedSeparatorProvesTheStream() async throws {
        processor.markStreamDirty()
        processor.beginResynchronization()
        let probe = processor.beginProbeRequest(command: "ATRV")
        deliver("12.4V\r\r>\r\n")
        _ = try await processor.awaitResponse(for: probe, timeout: 1)

        XCTAssertTrue(processor.confirmSynchronized())
        XCTAssertFalse(processor.isStreamDirty)
        XCTAssertNoThrow(try processor.beginRequest(command: "010C"))
    }

    /// The separator arrives after the proof: the stream stays clean and the next command arms.
    func testAProbeAnswerWhoseSeparatorArrivesLaterKeepsTheStreamClean() async throws {
        processor.markStreamDirty()
        processor.beginResynchronization()
        let probe = processor.beginProbeRequest(command: "ATRV")
        deliver("12.4V\r\r>")
        _ = try await processor.awaitResponse(for: probe, timeout: 1)
        XCTAssertTrue(processor.confirmSynchronized())

        deliver("\r\n")
        XCTAssertFalse(processor.isStreamDirty)
        let next = try await command("010C", answer: "7E804410C1F40\r\r>")
        XCTAssertEqual(next, ["7E804410C1F40"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    // MARK: - Processor: what still counts

    func testNonWhitespaceAfterAPromptStillMakesTheStreamDirty() async throws {
        _ = try await command("ATZ", answer: "ELM327 v1.5\r\r>\r\nX")
        XCTAssertThrowsError(try processor.beginRequest(command: "ATE0")) {
            XCTAssertEqual($0 as? OBDStreamError, .unsynchronized)
        }
        XCTAssertTrue(processor.isStreamDirty)
    }

    func testABarePromptIsStillABarePrompt() async throws {
        do {
            let lines = try await command("010C", answer: "\r>")
            XCTFail("a bare prompt is no answer: \(lines)")
        } catch {
            XCTAssertEqual(error as? BLEManagerError, .noData)
        }
        XCTAssertTrue(processor.isStreamDirty, "nothing says whose prompt it was")
    }

    func testWhitespaceInsideAResponseIsUntouched() async throws {
        let lines = try await command("0100", answer: "\r\n7E8 06 41 00 BE 3F A8 13\r\n7E9 06 41 00 98 18 80 11\r\r>\r\n")
        XCTAssertEqual(lines, ["7E8 06 41 00 BE 3F A8 13", "7E9 06 41 00 98 18 80 11"])
    }

    // MARK: - Exchange: the next command is written with no probe

    func testCoalescedSeparatorNeedsNoProbeBeforeTheNextCommand() async throws {
        respond(["ATZ": "ELM327 v1.5\r\r>\r\n", "ATE0": "ATE0\rOK\r\r>\r\n"])
        let identity = try await send("ATZ")
        let echo = try await send("ATE0")

        XCTAssertEqual(identity, ["ELM327 v1.5"])
        XCTAssertEqual(echo, ["ATE0", "OK"])
        XCTAssertEqual(wire.written, ["ATZ", "ATE0"], "no probe: the stream never turned dirty")
        XCTAssertFalse(processor.isStreamDirty)
    }

    func testASeparatorChunkBeforeTheNextCommandNeedsNoProbe() async throws {
        respond(["ATZ": "ELM327 v1.5\r\r>", "ATE0": "OK\r\r>"])
        _ = try await send("ATZ")
        wire.deliver("\r\n")
        let echo = try await send("ATE0")

        XCTAssertEqual(echo, ["OK"])
        XCTAssertEqual(wire.written, ["ATZ", "ATE0"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    func testASeparatorChunkAfterTheNextCommandIsWrittenIsNotItsAnswer() async throws {
        respond(["ATZ": "ELM327 v1.5\r\r>", "ATE0": "OK\r\r>"])
        _ = try await send("ATZ")
        wire.lateBytes = ["\r\n"] // lands as ATE0 is written, ahead of its answer
        let echo = try await send("ATE0")

        XCTAssertEqual(echo, ["OK"])
        XCTAssertEqual(wire.written, ["ATZ", "ATE0"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    // MARK: - Exchange: inferred-GATT validation (`ATI`, then `ATE0`, one attempt each)

    private func validate(between: () -> Void = {}) async throws -> (identity: [String], echo: [String], validated: Bool) {
        var validation = BLEAdapterValidationState()
        let identity = try await send(BLEAdapterValidationCommand.identifyAdapter.rawValue)
        validation.receive(identity)
        between()
        let echo = try await send(BLEAdapterValidationCommand.disableEcho.rawValue)
        validation.receive(echo)
        return (identity, echo, validation.isAdapterValidated)
    }

    func testValidationWithCoalescedSeparatorsWritesOnlyATIAndATE0() async throws {
        respond(["ATI": "ELM327 v1.5\r\r>\r\n", "ATE0": "ATE0\rOK\r\r>\r\n"])
        let result = try await validate()

        XCTAssertEqual(wire.written, ["ATI", "ATE0"])
        XCTAssertEqual(probesWritten, [])
        XCTAssertEqual(result.identity, ["ELM327 v1.5"])
        XCTAssertEqual(result.echo, ["ATE0", "OK"])
        XCTAssertTrue(result.validated)
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// ATI's separator arrives in a chunk of its own before ATE0 is armed.
    func testValidationWithASeparatorChunkBetweenTheCommandsWritesOnlyATIAndATE0() async throws {
        respond(["ATI": "ELM327 v1.5\r\r>", "ATE0": "ATE0\rOK\r\r>"])
        let result = try await validate(between: { wire.deliver("\r\n") })
        wire.deliver("\r\n")

        XCTAssertEqual(wire.written, ["ATI", "ATE0"])
        XCTAssertEqual(probesWritten, [])
        XCTAssertEqual(result.identity, ["ELM327 v1.5"])
        XCTAssertEqual(result.echo, ["ATE0", "OK"])
        XCTAssertTrue(result.validated)
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// ATI's separator lands only once ATE0 was armed and written, ahead of ATE0's answer;
    /// ATE0's own separator comes in a chunk of its own after the answer.
    func testValidationWithASeparatorChunkAfterATE0IsWrittenWritesOnlyATIAndATE0() async throws {
        wire.respond = { command in
            switch command {
            case "ATI": return "ELM327 v1.5\r\r>"
            case "ATE0": return "ATE0\rOK\r\r>"
            case "ATRV": return "12.4V\r\r>"
            case "ATDPN": return "A6\r\r>"
            default: return nil
            }
        }
        wire.onWrite = { [wire] command in
            if command == "ATE0" { wire?.deliver("\r\n") }
        }
        let result = try await validate()
        wire.deliver("\r\n")

        XCTAssertEqual(wire.written, ["ATI", "ATE0"])
        XCTAssertEqual(probesWritten, [])
        XCTAssertEqual(result.identity, ["ELM327 v1.5"])
        XCTAssertEqual(result.echo, ["ATE0", "OK"])
        XCTAssertTrue(result.validated)
        XCTAssertFalse(processor.isStreamDirty)
    }

    // MARK: - Exchange: recovery

    /// A timed-out command's late answer arrives with the adapter's separator. The first probe
    /// proves the stream; the second is never needed.
    func testAfterALateAnswerWithASeparatorTheFirstProbeProvesTheStream() async throws {
        respond(["010D": "7E803410D20\r\r>"])
        do {
            _ = try await send("010C", timeout: 0.05)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout)
        }
        wire.deliver("7E804410C1F40\r\r>\r\n")

        let speed = try await send("010D")
        XCTAssertEqual(speed, ["7E803410D20"])
        XCTAssertEqual(wire.written, ["010C", "ATRV", "010D"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// The probe's own answer carries the separator: it still proves the stream.
    func testAProbeAnswerWithASeparatorProvesTheStreamThroughTheExchange() async throws {
        wire.respond = { command in
            switch command {
            case "ATRV": return "12.4V\r\r>\r\n"
            case "ATDPN": return "A6\r\r>\r\n"
            case "010D": return "7E803410D20\r\r>"
            default: return nil
            }
        }
        _ = try? await send("010C", timeout: 0.05)
        XCTAssertTrue(processor.isStreamDirty)

        let speed = try await send("010D")
        XCTAssertEqual(speed, ["7E803410D20"])
        XCTAssertEqual(wire.written, ["010C", "ATRV", "010D"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// Control: a stray non-whitespace byte after a prompt still sends the next command through
    /// a probe first.
    func testNonWhitespaceAfterAPromptStillCostsAProbe() async throws {
        respond(["ATZ": "ELM327 v1.5\r\r>X", "ATE0": "OK\r\r>"])
        _ = try await send("ATZ")
        _ = try? await send("ATE0")
        XCTAssertEqual(wire.written.first, "ATZ")
        XCTAssertEqual(wire.written.dropFirst().first, "ATRV", "the stream was dirty: a probe goes first")
    }
}
