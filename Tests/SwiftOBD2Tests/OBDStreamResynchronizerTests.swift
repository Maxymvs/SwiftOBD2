//
//  OBDStreamResynchronizerTests.swift
//  SwiftOBD2Tests
//
//  The proof that clears a dirty stream (review finding P1-b and the transport half of P1-a):
//  drain until quiet, then a probe whose complete answer can be attributed. Real processor and
//  resynchronizer behind a scripted wire. Synthetic data.
//

@testable import SwiftOBD2
import XCTest

final class OBDStreamResynchronizerTests: XCTestCase {
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

    private func now() -> TimeInterval { processor.clock() }

    /// Leaves the stream dirty the ordinary way: a command that never gets its prompt.
    private func timeOut(_ command: String = "22028D", partial: String? = nil) async {
        let saved = wire.respond
        wire.respond = { _ in partial }
        _ = try? await exchange.send(command, retries: 1, responseTimeout: 0.03) { wire.target(adapter) }
        wire.respond = saved
        XCTAssertTrue(processor.isStreamDirty)
    }

    private func resynchronize(within seconds: TimeInterval = 5) async throws -> OBDStreamResynchronizer.Outcome {
        try await exchange.resynchronize(deadline: now() + seconds, target: wire.target(adapter))
    }

    // MARK: A probe's own answer

    func testACleanStreamNeedsNoProbe() async throws {
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertEqual(wire.written, [])
    }

    func testTheFirstProbesOwnAnswerProvesSync() async throws {
        await timeOut()
        wire.respond = { $0 == "ATRV" ? "14.1V\r\r>" : nil }
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertEqual(wire.written, ["22028D", "ATRV"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    func testLateAnswersThatArriveFirstAreDrained() async throws {
        await timeOut()
        wire.lateBytes = ["OK\r\r>", "7E8037F2231\r\r>"]
        wire.respond = { $0 == "ATRV" ? "14.1V\r\r>" : nil }
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertEqual(wire.written, ["22028D", "ATRV"])
    }

    /// With echo on (after a reset) the adapter repeats the probe before answering it.
    func testAnEchoedProbeAnswerCounts() async throws {
        await timeOut()
        wire.respond = { $0 == "ATRV" ? "ATRV\r14.1V\r\r>" : nil }
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
    }

    /// The first probe's first byte interrupts a request the adapter was still busy with: the
    /// pending request answers `STOPPED`, the probe is read as garbage and answers `?`. The
    /// second probe is then answered for real.
    func testAProbeSwallowedByABusyAdapterThenTheSecondProbeProvesSync() async throws {
        await timeOut()
        wire.respond = { command in
            switch command {
            case "ATRV": return "STOPPED\r\r>?\r\r>"
            case "ATDPN": return "A6\r\r>"
            default: return nil
            }
        }
        let started = now()
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertEqual(wire.written, ["22028D", "ATRV", "ATDPN"])
        XCTAssertLessThan(now() - started, 0.14, "the `?` ends the first probe's window early")
    }

    /// Both probes went out and neither got its answer: neither can prove anything until its late
    /// answer has been seen, so this is the "no usable probe" outcome, not a plain failure.
    func testNeitherProbeAnsweringLeavesTheStreamUnproven() async throws {
        await timeOut()
        wire.respond = { _ in nil }
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .reconnectRequired)
        XCTAssertEqual(wire.written, ["22028D", "ATRV", "ATDPN"])
        XCTAssertTrue(processor.isStreamDirty)
    }

    func testProbesThatOnlySeeOtherAnswersStayUnproven() async throws {
        await timeOut()
        wire.respond = { command in
            switch command {
            case "ATRV": return "OK\r\r>"
            case "ATDPN": return "7E8037F2231\r\r>NO DATA\r\r>"
            default: return nil
            }
        }
        let outcome = try await resynchronize()
        XCTAssertNotEqual(outcome, .synchronized)
        XCTAssertEqual(outcome, .reconnectRequired, "both probes are now unanswered")
        XCTAssertTrue(processor.isStreamDirty)
    }

    /// A probe answer with more bytes behind it proves nothing: something is still arriving.
    func testAProbeAnswerFollowedByMoreBytesIsNotAProof() async throws {
        await timeOut()
        wire.respond = { command in
            switch command {
            case "ATRV": return "14.1V\r\r>7E8037F"
            case "ATDPN": return nil
            default: return nil
            }
        }
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .unproven)
        XCTAssertTrue(processor.isStreamDirty)
    }

    // MARK: P1-b: late bytes keep their owner

    /// The reviewer's case. The first half of a late CAN frame lands in the `ATRV` window
    /// without a prompt; its last character and the prompt land in the `ATDPN` window. `1` and a
    /// prompt used to read as a protocol number and "prove" the stream.
    func testASplitLateFrameCannotCompleteAProbeAnswer() async throws {
        await timeOut()
        wire.respond = { command in
            switch command {
            case "ATRV": return "7E8037F223"
            case "ATDPN": return "1\r>"
            default: return nil
            }
        }
        let outcome = try await resynchronize()
        XCTAssertNotEqual(outcome, .synchronized, "the tail of a late frame is not ATDPN's answer")
        XCTAssertTrue(processor.isStreamDirty)
    }

    /// The same split on the X3's extended addressing.
    func testASplitLateExtendedFrameCannotCompleteAProbeAnswer() async throws {
        await timeOut("22DA2E")
        wire.respond = { command in
            switch command {
            case "ATRV": return "618F1037F223"
            case "ATDPN": return "1\r>"
            default: return nil
            }
        }
        let outcome = try await resynchronize()
        XCTAssertNotEqual(outcome, .synchronized)
    }

    /// With the tail discarded, the probe's real answer behind it still counts.
    func testAProbeAnswerBehindTheTailOfALateFrameStillCounts() async throws {
        await timeOut()
        wire.respond = { command in
            switch command {
            case "ATRV": return "7E8037F223"
            case "ATDPN": return "1\r>A6\r\r>"
            default: return nil
            }
        }
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
    }

    /// The late frame's first half was already buffered when the slot timed out.
    func testBytesBufferedBeforeTheProbeAreNeverItsAnswer() async throws {
        await timeOut(partial: "1")
        wire.respond = { command in
            switch command {
            case "ATRV": return "4.1V\r\r>" // completes the buffered "1" into "14.1V"
            case "ATDPN": return nil
            default: return nil
            }
        }
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .unproven, "a response that started before the probe was written isn't the probe's")
    }

    // MARK: A late answer to the same probe

    /// `ATRV` gets no answer in its window. Its late answer then arrives in `ATDPN`'s window:
    /// not a protocol number, so not `ATDPN`'s answer. `ATDPN`'s own answer proves the stream.
    func testALateAnswerToProbeOneIsNotProbeTwosAnswer() async throws {
        await timeOut()
        wire.respond = { command in
            switch command {
            case "ATDPN": return "14.1V\r\r>" // ATRV's late answer, and nothing else
            default: return nil
            }
        }
        var outcome = try await resynchronize()
        XCTAssertEqual(outcome, .unproven)

        // ATDPN is now itself unanswered and ATRV's late answer has been seen, so the next
        // attempt can use ATRV again.
        wire.respond = { $0 == "ATRV" ? "14.1V\r\r>" : nil }
        outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertEqual(wire.written, ["22028D", "ATRV", "ATDPN", "ATRV"])
    }

    /// An ordinary `ATRV` timed out, so a voltage that arrives now could be its late answer.
    /// The resynchronization doesn't use `ATRV` until that answer has been seen.
    func testAProbeWhoseEarlierSendIsUnansweredIsSkipped() async throws {
        await timeOut("ATRV")
        wire.respond = { $0 == "ATDPN" ? "A6\r\r>" : nil }
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertEqual(wire.written, ["ATRV", "ATDPN"], "ATRV was not sent again")
    }

    func testWithBothProbesUnansweredNothingCanBeProvenUntilALateAnswerIsSeen() async throws {
        await timeOut()
        wire.respond = { _ in nil }
        var outcome = try await resynchronize()
        XCTAssertEqual(outcome, .reconnectRequired)
        let writtenSoFar = wire.written

        // Nothing usable: no probe is written at all.
        outcome = try await resynchronize()
        XCTAssertEqual(outcome, .reconnectRequired)
        XCTAssertEqual(wire.written, writtenSoFar)

        // ATRV's late answer finally arrives and is discarded; ATRV is usable again.
        wire.deliver("14.1V\r\r>")
        wire.respond = { $0 == "ATRV" ? "14.2V\r\r>" : nil }
        outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertEqual(wire.written, writtenSoFar + ["ATRV"])
    }

    // MARK: Quiet first

    /// Bytes are still arriving: the probe waits until they stop.
    func testTheProbeIsWrittenOnlyAfterTheStreamGoesQuiet() async throws {
        exchange.resynchronization = OBDStreamResynchronizer.Timing(quietWindow: 0.1, maximumDrain: 2, probeWindow: 0.3)
        await timeOut()
        var bytesBeforeTheProbe = 0
        wire.onWrite = { [wire] command in
            if command == "ATRV" { bytesBeforeTheProbe = wire?.delivered ?? 0 }
        }
        wire.respond = { $0 == "ATRV" ? "14.1V\r\r>" : nil }
        wire.deliver("7E8") // already arriving when the resynchronization starts
        let trickle = Task.detached { [wire] in
            for _ in 0..<7 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                wire?.deliver("7E8")
            }
            wire?.deliver("\r\r>")
        }
        let outcome = try await resynchronize()
        await trickle.value
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertEqual(bytesBeforeTheProbe, 8 * 3 + 3, "the whole late reply had arrived before the probe was written")
    }

    // MARK: Limits and the link

    func testNoTimeLeftSendsNoProbe() async throws {
        await timeOut()
        wire.respond = { _ in "14.1V\r\r>" }
        let outcome = try await exchange.resynchronize(deadline: now() - 0.01, target: wire.target(adapter))
        XCTAssertEqual(outcome, .unproven)
        XCTAssertEqual(wire.written, ["22028D"])
    }

    func testAFailedProbeWriteIsRethrown() async {
        await timeOut()
        wire.writeError = BLEWriteCoordinatorError.transportWriteFailed("x")
        do {
            _ = try await resynchronize()
            XCTFail("expected the write error")
        } catch {
            XCTAssertEqual(OEMBatchExecutor.classify(error), .linkLost, "\(error)")
        }
        XCTAssertTrue(processor.isStreamDirty)
    }

    func testALinkResetWhileProbingIsRethrown() async {
        await timeOut()
        wire.respond = { _ in nil }
        let probing = Task { try await self.resynchronize(within: 30) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        processor.reset()
        do {
            _ = try await probing.value
            XCTFail("expected the link error")
        } catch {
            XCTAssertEqual(OEMBatchExecutor.classify(error), .linkLost, "\(error)")
        }
    }

    // MARK: A probe write that wrote nothing

    /// The write ran out of time before its first byte was handed over: the adapter can't answer
    /// a probe it never received, so the probe is not quarantined and proves the stream next time.
    func testAProbeWriteThatWroteNothingDoesNotSpendTheProbe() async throws {
        await timeOut()
        wire.writeError = BLEWriteCoordinatorError.deadlineExceededBeforeWrite
        do {
            _ = try await resynchronize()
            XCTFail("expected the write error")
        } catch {
            XCTAssertEqual(error as? BLEWriteCoordinatorError, .deadlineExceededBeforeWrite)
        }
        XCTAssertEqual(processor.unansweredCount(of: "ATRV"), 0)
        XCTAssertTrue(processor.isStreamDirty)

        wire.writeError = nil
        wire.respond = { $0 == "ATRV" ? "14.1V\r\r>" : nil }
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertEqual(wire.written, ["22028D", "ATRV"], "the same probe proved the stream")
    }

    /// A deadline that passed after a chunk was submitted: part of the probe may be on the wire,
    /// and a voltage arriving later could be its answer. Still quarantined.
    func testAProbeWriteThatMayHaveWrittenIsStillQuarantined() async throws {
        await timeOut()
        wire.writeError = BLEWriteCoordinatorError.deadlineExceeded
        do {
            _ = try await resynchronize()
            XCTFail("expected the write error")
        } catch {
            XCTAssertEqual(error as? BLEWriteCoordinatorError, .deadlineExceeded)
        }
        XCTAssertEqual(processor.unansweredCount(of: "ATRV"), 1)

        wire.writeError = nil
        wire.respond = { command in
            switch command {
            case "ATRV": return "14.1V\r\r>"
            case "ATDPN": return "A6\r\r>"
            default: return nil
            }
        }
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertEqual(wire.written, ["22028D", "ATDPN"], "ATRV was skipped")
    }

    func testOnlyFailuresThatCertainlyWroteNothingSpareTheProbe() {
        let wroteNothing: [Error] = [
            BLEWriteCoordinatorError.deadlineExceededBeforeWrite,
            BLEWriteCoordinatorError.noActiveSession,
            BLEWriteCoordinatorError.channelPoisoned,
            BLECommandEncodingError.emptyCommand,
            OEMAddressingGateError.addressingUnresolved,
            BLEManagerError.missingPeripheralOrCharacteristic,
        ]
        for error in wroteNothing {
            XCTAssertFalse(OBDStreamResynchronizer.mayHaveWritten(error), "\(error)")
        }
        let mayHaveWritten: [Error] = [
            CancellationError(),
            BLEWriteCoordinatorError.deadlineExceeded,
            BLEWriteCoordinatorError.sessionChanged,
            BLEWriteCoordinatorError.transportWriteFailed("x"),
            BLEManagerError.peripheralNotConnected,
            WifiSocketError.failed,
            CommunicationError.connectionLost,
        ]
        for error in mayHaveWritten {
            XCTAssertTrue(OBDStreamResynchronizer.mayHaveWritten(error), "\(error)")
        }
    }

    // MARK: No usable probe

    /// Both probes genuinely unanswered: nothing can prove this stream until a late answer
    /// happens to arrive. That is its own outcome, and a command fails as such, unwritten and
    /// unretried, instead of as a timeout.
    func testWithEveryProbeUnansweredAReconnectIsRequired() async throws {
        let sink = CapturingWireSink()
        processor = OBDMessageProcessor(wireLog: OBDWireLog(sink: sink.sink))
        wire = FakeAdapterWire(processor: processor)
        exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
        await timeOut()
        wire.respond = { _ in nil }
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .reconnectRequired)
        XCTAssertTrue(OBDStreamResynchronizer.isExhausted(processor))
        let writtenSoFar = wire.written
        XCTAssertEqual(writtenSoFar, ["22028D", "ATRV", "ATDPN"])

        for _ in 0..<2 {
            do {
                _ = try await exchange.send("0100", retries: 3, responseTimeout: 0.05) { wire.target(adapter) }
                XCTFail("expected reconnectRequired")
            } catch {
                XCTAssertEqual(error as? OBDStreamError, .reconnectRequired, "\(error)")
            }
            XCTAssertEqual(wire.written, writtenSoFar, "nothing further is written")
        }
        XCTAssertTrue(sink.text.contains("Command failed after 1 attempts: 0100"), sink.text)

        // ATRV's late answer finally arrives: the condition clears by itself.
        wire.deliver("14.1V\r\r>")
        XCTAssertFalse(OBDStreamResynchronizer.isExhausted(processor))
        wire.respond = { command in
            switch command {
            case "ATRV": return "14.2V\r\r>"
            case "0100": return "7E8064100BE3FA813\r>"
            default: return nil
            }
        }
        let lines = try await exchange.send("0100", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertEqual(lines, ["7E8064100BE3FA813"])
        XCTAssertEqual(wire.written, writtenSoFar + ["ATRV", "0100"])
        XCTAssertFalse(OBDStreamResynchronizer.isExhausted(processor))
    }

    func testExhaustionClearsOnAReset() async throws {
        await timeOut()
        wire.respond = { _ in nil }
        _ = try await resynchronize()
        XCTAssertTrue(OBDStreamResynchronizer.isExhausted(processor))
        processor.reset()
        XCTAssertFalse(OBDStreamResynchronizer.isExhausted(processor))
    }

    /// One probe still usable is not exhaustion: the stream is merely unproven.
    func testOneUsableProbeLeavesTheStreamOnlyUnproven() async throws {
        await timeOut("ATRV")
        wire.respond = { _ in nil }
        let outcome = try await exchange.resynchronize(deadline: now() - 0.01, target: wire.target(adapter))
        XCTAssertEqual(outcome, .unproven, "ATDPN had no time to be written, and is still usable")
        XCTAssertEqual(wire.written, ["ATRV"])
        XCTAssertFalse(OBDStreamResynchronizer.isExhausted(processor))
    }

    // MARK: P2-2: exhaustion is judged on what arrived, after a receive-only grace

    /// `Timing`'s default grace before "every probe unanswered" becomes "reconnect required".
    private static let grace: TimeInterval = 1.0

    /// A processor on a manual clock. Probe windows still run on real-time timers (30 ms here);
    /// only the injected sleep (the drain and the grace) moves the clock.
    private func makeManualClockRig() -> ManualClock {
        let clock = ManualClock(1_000)
        processor = OBDMessageProcessor(clock: clock.now)
        wire = FakeAdapterWire(processor: processor)
        exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
        return clock
    }

    /// The resynchronizer the exchange would build, with a sleep that runs `onSleep` and then
    /// moves the manual clock by the time asked for.
    private func manualResynchronizer(
        _ clock: ManualClock,
        onSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
    ) -> OBDStreamResynchronizer {
        var resynchronizer = OBDStreamResynchronizer(
            processor: processor,
            timing: OBDStreamResynchronizer.Timing(quietWindow: 0.02, maximumDrain: 0.2, probeWindow: 0.03)
        )
        resynchronizer.sleep = { seconds in
            try await onSleep(seconds)
            clock.advance(seconds)
        }
        return resynchronizer
    }

    private func run(_ resynchronizer: OBDStreamResynchronizer, deadline: TimeInterval) async throws -> OBDStreamResynchronizer.Outcome {
        let target = wire.target(adapter)
        return try await resynchronizer.resynchronize(deadline: deadline) { probe, writeDeadline in
            try await target.write(probe, writeDeadline)
        }
    }

    /// A late `ATRV` answer arrives while the drain waits for quiet, with every probe unanswered.
    /// It used to be kept in the buffer for a probe slot that never came, so it was never
    /// accounted, and the stream was declared beyond proof although the answer that frees `ATRV`
    /// had arrived.
    func testALateProbeAnswerDuringTheQuietDrainFreesTheProbe() async throws {
        let clock = makeManualClockRig()
        processor.markStreamDirty()
        processor.noteUnanswered("ATRV")
        processor.noteUnanswered("ATDPN")
        wire.deliver("7E803410D32\r>") // still talking: the drain waits for quiet
        let once = LockedCounter()
        let wire = self.wire!
        let resynchronizer = manualResynchronizer(clock) { _ in
            if once.increment() == 1 { wire.deliver("14.1V\r\r>") } // ATRV's late answer
        }
        wire.respond = { $0 == "ATRV" ? "14.2V\r\r>" : nil }

        let outcome = try await run(resynchronizer, deadline: clock.now() + 10)
        XCTAssertNotEqual(outcome, .reconnectRequired, "the late answer had arrived")
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertEqual(wire.written, ["ATRV"])
    }

    /// The last probe's window ends (`?`), and that probe's late answer is already in the buffer
    /// behind it when the outcome is judged. It used to be discarded only after the judgement.
    func testALateAnswerBufferedBehindTheLastProbesWindowIsAccountedBeforeTheJudgement() async throws {
        let clock = makeManualClockRig()
        processor.markStreamDirty()
        processor.noteUnanswered("ATRV")
        wire.respond = { $0 == "ATDPN" ? "?\r\r>A6\r\r>" : nil }

        let outcome = try await run(manualResynchronizer(clock), deadline: clock.now() + 10)
        XCTAssertNotEqual(outcome, .reconnectRequired, "ATDPN's late answer had arrived")
        XCTAssertEqual(outcome, .unproven)
        XCTAssertEqual(wire.written, ["ATDPN"])
        XCTAssertTrue(processor.isStreamDirty)
    }

    /// Both probes unanswered in their windows; `ATRV`'s answer arrives during the grace. Nothing
    /// is written during the grace, the stream stays dirty (`.unproven`, never `.synchronized`),
    /// and the next resynchronization proves it with `ATRV`.
    func testALateAnswerDuringTheGraceLeavesTheStreamUnprovenAndTheNextProofSucceeds() async throws {
        let clock = makeManualClockRig()
        processor.markStreamDirty()
        wire.respond = { _ in nil }
        let polls = LockedCounter()
        let wire = self.wire!
        let resynchronizer = manualResynchronizer(clock) { _ in
            if polls.increment() == 3 { wire.deliver("14.1V\r\r>") }
        }
        let started = clock.now()

        let outcome = try await run(resynchronizer, deadline: started + 10)
        XCTAssertEqual(outcome, .unproven)
        XCTAssertEqual(wire.written, ["ATRV", "ATDPN"], "nothing is written during the grace")
        XCTAssertTrue(processor.isStreamDirty)
        XCTAssertLessThan(clock.now() - started, Self.grace, "ended as soon as the probe was freed")
        XCTAssertFalse(OBDStreamResynchronizer.isExhausted(processor))

        wire.respond = { $0 == "ATRV" ? "14.2V\r\r>" : nil }
        let next = try await run(manualResynchronizer(clock), deadline: clock.now() + 10)
        XCTAssertEqual(next, .synchronized)
        XCTAssertEqual(wire.written, ["ATRV", "ATDPN", "ATRV"])
        XCTAssertFalse(processor.isStreamDirty)
    }

    /// Both probes stay unanswered through the whole grace: only then is a reconnect required,
    /// and `isExhausted` agrees (false during the grace, true after it).
    func testAReconnectIsRequiredOnlyAfterTheWholeGrace() async throws {
        let clock = makeManualClockRig()
        processor.markStreamDirty()
        wire.respond = { _ in nil }
        let duringGrace = LockedFlags()
        let processor = self.processor!
        let resynchronizer = manualResynchronizer(clock) { _ in
            duringGrace.append(OBDStreamResynchronizer.isExhausted(processor))
        }
        let started = clock.now()

        let outcome = try await run(resynchronizer, deadline: started + 10)
        XCTAssertEqual(outcome, .reconnectRequired)
        XCTAssertEqual(clock.now() - started, Self.grace, accuracy: 1e-6, "the whole grace, measured from the first observation")
        XCTAssertEqual(wire.written, ["ATRV", "ATDPN"], "nothing is written during the grace")
        XCTAssertFalse(duringGrace.values.isEmpty, "the grace polled")
        XCTAssertFalse(duringGrace.values.contains(true), "not exhausted before the grace ran out")
        XCTAssertTrue(OBDStreamResynchronizer.isExhausted(processor))
        XCTAssertTrue(processor.isStreamDirty)
    }

    /// `isExhausted` on its own: measured from the first observation, cleared when a probe is
    /// freed, and started again from a new observation.
    func testIsExhaustedOnlyAfterTheGraceSinceTheFirstObservation() {
        let clock = makeManualClockRig()
        processor.markStreamDirty()
        processor.noteUnanswered("ATRV")
        processor.noteUnanswered("ATDPN")
        XCTAssertFalse(OBDStreamResynchronizer.isExhausted(processor), "first observation")
        clock.advance(Self.grace - 0.01)
        XCTAssertFalse(OBDStreamResynchronizer.isExhausted(processor))
        clock.advance(0.02)
        XCTAssertTrue(OBDStreamResynchronizer.isExhausted(processor))

        wire.deliver("A6\r\r>") // ATDPN's late answer
        XCTAssertFalse(OBDStreamResynchronizer.isExhausted(processor))
        processor.noteUnanswered("ATDPN")
        XCTAssertFalse(OBDStreamResynchronizer.isExhausted(processor), "a new observation starts a new grace")
        clock.advance(Self.grace)
        XCTAssertTrue(OBDStreamResynchronizer.isExhausted(processor))
    }

    /// The grace is not restarted by asking again: a second resynchronization inside it writes
    /// nothing and ends when the first observation's grace ends. A deadline that cuts the grace
    /// short is `.unproven`, not `.reconnectRequired`.
    func testASecondResynchronizationContinuesTheSameGraceAndADeadlineCutsItShort() async throws {
        let clock = makeManualClockRig()
        processor.markStreamDirty()
        wire.respond = { _ in nil }
        let started = clock.now()

        let first = try await run(manualResynchronizer(clock), deadline: started + 0.3)
        XCTAssertEqual(first, .unproven, "the deadline cut the grace short")
        XCTAssertEqual(clock.now() - started, 0.3, accuracy: 1e-6)
        XCTAssertEqual(wire.written, ["ATRV", "ATDPN"])

        clock.advance(0.2)
        let second = try await run(manualResynchronizer(clock), deadline: started + 10)
        XCTAssertEqual(second, .reconnectRequired)
        XCTAssertEqual(wire.written, ["ATRV", "ATDPN"], "nothing written: every probe is still unanswered")
        XCTAssertEqual(clock.now() - started, Self.grace, accuracy: 1e-6, "not extended by the second attempt")
    }

    /// Cancelled during the grace: thrown, the stream stays dirty, and the grace keeps its start.
    func testCancellationDuringTheGraceThrowsAndLeavesTheStreamDirty() async throws {
        let clock = makeManualClockRig()
        processor.markStreamDirty()
        wire.respond = { _ in nil }
        let wire = self.wire!
        let resynchronizer = manualResynchronizer(clock) { _ in
            guard wire.written.count == 2 else { return }
            withUnsafeCurrentTask { $0?.cancel() }
            try Task.checkCancellation()
        }
        let started = clock.now()
        let running = Task { try await self.run(resynchronizer, deadline: started + 10) }
        do {
            let outcome = try await running.value
            XCTFail("expected cancellation, got \(outcome)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(processor.isStreamDirty)
        XCTAssertEqual(wire.written, ["ATRV", "ATDPN"])
        clock.set(started + Self.grace)
        XCTAssertTrue(OBDStreamResynchronizer.isExhausted(processor), "the grace kept its first observation")
    }

    /// The gate is asked about every probe, like any other write.
    func testProbesGoThroughTheAddressingGate() async throws {
        let gate = OEMAddressingGate()
        exchange = OBDStreamOwnershipTests.fastExchange(processor: processor, gate: gate)
        await timeOut()
        gate.markUnresolved(adapter)
        wire.respond = { $0 == "ATRV" ? "14.1V\r\r>" : nil }
        // The probes are adapter-only queries and pass on an unresolved adapter, so a recovery
        // can resynchronize before its reset.
        let outcome = try await resynchronize()
        XCTAssertEqual(outcome, .synchronized)
        XCTAssertTrue(gate.isUnresolved(adapter), "a probe's answer never advances the gate")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Adds one and returns the new count.
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class LockedFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [Bool] = []

    var values: [Bool] { lock.withLock { flags } }

    func append(_ flag: Bool) {
        lock.withLock { flags.append(flag) }
    }
}
