//
//  OEMResynchronizationTests.swift
//  SwiftOBD2Tests
//
//  Late answers on the adapter's stream (review finding 4a): a command that ended without its
//  prompt leaves an answer that can still arrive and be read as the next command's. These pin,
//  executor against `ScriptedOEMChannel`'s model of the stream-owning transport, that such an
//  answer is never credited to a read or a restore command, that the executor asks for a proof
//  where it must (before the batch's first write, on entering restore, after a restore command
//  without a prompt), what it does when the proof can't be had, and that restore stays inside
//  its own budget. Plus the answer-judging helpers restore and resynchronization rely on
//  (finding 4b). The resynchronization itself is tested against the real transport in
//  `OBDStreamResynchronizerTests` and `OBDStreamOwnershipTests`. Synthetic only.
//

@testable import SwiftOBD2
import XCTest

final class OEMResynchronizationTests: XCTestCase {
    private func outcomes(_ result: OEMBatchResult) -> [OEMReadOutcome] {
        result.reads.map(\.outcome)
    }

    private func number(_ outcome: OEMReadOutcome, _ signal: String) -> Double? {
        guard case let .values(values) = outcome,
              case let .number(value)? = values.first(where: { $0.signalID == signal })?.value else { return nil }
        return value
    }

    private static let functionalRestore = ["ATSH 7DF", "0100"]
    private static let bmwSetup18 = ["ATCEA 18", "ATSH 6F1", "ATCRA 618", "ATFCSH 6F1", "ATFCSD 1830000A", "ATFCSM 1"]
    private static let bmwRestoreCommands = ["ATFCSM 0", "ATAR", "ATCEA", "ATSH 7DF"]
    private static let probes = ["ATRV", "ATDPN"]

    /// After every resynchronization that proved nothing, nothing but a probe was written.
    private func assertNothingButProbesAfterAnUnprovenStream(
        _ channel: ScriptedOEMChannel, _ label: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let failed = channel.resynchronizations.first(where: { $0.outcome == .unproven }) else { return }
        let after = channel.sent.filter { $0.at >= failed.at }.map(\.command)
        XCTAssertTrue(after.allSatisfy(Self.probes.contains), "\(label): \(after)", file: file, line: line)
    }

    // MARK: A late OK is not a restore acknowledgement

    /// `ATFCSM 1` times out; its `OK` is still on its way when restore starts, and neither probe
    /// answers. The old executor took that `OK` as `ATFCSM 0`'s. Changed: on an unproven stream
    /// no restore command is written at all (was: each sent once, uncredited), so the late `OK`
    /// has nothing to be credited to.
    func testDelayedOKFromTimedOutSetupIsNotCreditedToTheRestore() async throws {
        let channel = ScriptedOEMChannel()
        // Written at +0.25, timed out at +0.75; both probes go unanswered (+0.75…+1.55), and the
        // late `OK` (+1.70) would have landed in `ATFCSM 0`'s window.
        channel.script["ATFCSM 1"] = [.lines(["OK"], latency: 1.45)]
        channel.script["ATRV"] = [.silence]
        channel.script["ATDPN"] = [.silence]
        channel.script["ATFCSM 0"] = [.silence]
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-bmw", ["B.DA2E"]), on: channel)

        XCTAssertEqual(channel.commands, Self.bmwSetup18 + Self.probes)
        XCTAssertFalse(channel.deliveries.contains { $0.from == "ATFCSM 1" && Self.bmwRestoreCommands.contains($0.to) })
        XCTAssertFalse(channel.commands.contains("0100"), "an unproven restore is never verified")
        XCTAssertEqual(result.failure, .configurationFailed)
        XCTAssertEqual(outcomes(result), [.notAttempted(.configurationFailed)])
        XCTAssertEqual(result.adapterState, .unresolved)
        XCTAssertTrue(channel.markedUnresolved)
    }

    /// Same late `OK`, but this time the probe drains it and proves the stream. `ATFCSM 0` then
    /// never answers: still unresolved, whatever `OK`s are around. Changed: the stream is proven
    /// again after each `ATFCSM 0` that got no prompt (was: only after the first; the old
    /// executor allowed two rounds of probes per restore).
    func testSilentRestoreCommandStaysUnacknowledgedAfterResynchronizing() async throws {
        let channel = ScriptedOEMChannel()
        channel.script["ATFCSM 1"] = [.lines(["OK"], latency: 0.6)]
        channel.script["ATFCSM 0"] = [.silence, .silence]
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-bmw", ["B.DA2E"]), on: channel)

        XCTAssertTrue(channel.deliveries.contains { $0.from == "ATFCSM 1" && $0.to == "ATRV" })
        XCTAssertEqual(
            channel.commands,
            Self.bmwSetup18 + ["ATRV", "ATFCSM 0", "ATRV", "ATFCSM 0", "ATRV", "ATAR", "ATCEA", "ATSH 7DF"]
        )
        XCTAssertEqual(result.adapterState, .unresolved)
        XCTAssertTrue(channel.markedUnresolved)
    }

    /// The late `OK` is drained by the probe; every restore command is then properly answered.
    func testDelayedOKIsDrainedAndAProperlyAnsweredRestoreVerifies() async throws {
        let channel = ScriptedOEMChannel()
        channel.script["ATFCSM 1"] = [.lines(["OK"], latency: 0.6)]
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-bmw", ["B.DA2E"]), on: channel)

        XCTAssertTrue(channel.deliveries.contains { $0.from == "ATFCSM 1" && $0.to == "ATRV" })
        XCTAssertEqual(channel.commands, Self.bmwSetup18 + ["ATRV"] + Self.bmwRestoreCommands + ["0100"])
        XCTAssertEqual(result.failure, .configurationFailed)
        XCTAssertEqual(result.adapterState, .functional)
        XCTAssertFalse(channel.markedUnresolved)
    }

    // MARK: A late reply is not the next read's

    /// The first read gets no prompt. Its `7F 22 31` arrives later; the old executor sent the
    /// next read and credited that negative response to it.
    func testReadWithoutPromptStopsReadsAndItsLateAnswerIsNeverCredited() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E8037F2231"], latency: 1.6) // past the 1.5 s read window
        channel.reads["221002"] = .lines(["7E805621002FF9C"])
        channel.reads["221010"] = .lines(["7E804621010FF"])
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002", "E.1010"]), on: channel)

        XCTAssertEqual(outcomes(result), [.noAnswer, .notAttempted(.streamOutOfSync), .notAttempted(.streamOutOfSync)])
        XCTAssertEqual(channel.commands.filter { $0.hasPrefix("22") }, ["22028D"], "no later read is written")
        XCTAssertFalse(outcomes(result).contains(.negativeResponse(code: 0x31)))
        XCTAssertTrue(channel.deliveries.contains { $0.from == "22028D" && $0.to == "ATRV" }, "the probe drains it")
        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "ATRV"] + Self.functionalRestore)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.adapterState, .functional)
    }

    // MARK: The stream a batch inherits

    /// The ordinary command just before the batch timed out and its answer is still on its way.
    /// The executor asks for a proof before its first write; the probe drains that answer, and
    /// setup and the reads then go ahead with their own answers.
    func testInheritedDirtyStreamIsProvenBeforeTheFirstWriteThenReadsNormally() async throws {
        let channel = ScriptedOEMChannel()
        channel.injectLateAnswer(["7E80562028D0CE2"], arrivingIn: 0.3, from: "earlier 22028D")
        channel.reads["22028D"] = .lines(["7E80562028D0CE2"])
        channel.reads["221002"] = .lines(["7E805621002FF9C"])
        let start = channel.clock.now()
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), on: channel)

        XCTAssertEqual(channel.commands, ["ATRV", "ATSH 7E0", "22028D", "221002"] + Self.functionalRestore)
        let first = try XCTUnwrap(channel.resynchronizations.first)
        XCTAssertNil(first.before, "asked for by the executor, not by a send")
        XCTAssertTrue(first.wasDirty)
        XCTAssertEqual(first.outcome, .proven)
        XCTAssertEqual(first.deadline, start + OEMBatchExecutor.synchronizationWindow, accuracy: 1e-9)
        XCTAssertEqual(channel.deliveries.filter { $0.from == "earlier 22028D" }.map(\.to), ["ATRV"], "drained, credited to nothing")
        XCTAssertEqual(try XCTUnwrap(number(result.reads[0].outcome, "ECU_T")), 56.7, accuracy: 1e-9)
        XCTAssertEqual(number(result.reads[1].outcome, "TORQUE"), -10)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.adapterState, .functional)
        XCTAssertFalse(channel.markedUnresolved)
    }

    /// The proof before setup is capped by the batch deadline as well as by its own window.
    func testProofBeforeSetupIsCappedByTheBatchDeadline() async throws {
        let channel = ScriptedOEMChannel()
        channel.requireResynchronization()
        channel.script["ATRV"] = [.silence]
        channel.script["ATDPN"] = [.silence]
        let batchDeadline = channel.clock.now() + 0.6
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-vw", ["E.028D"]), on: channel, deadline: batchDeadline)

        XCTAssertEqual(try XCTUnwrap(channel.resynchronizations.first).deadline, batchDeadline, accuracy: 1e-9)
        for sent in channel.sent {
            XCTAssertLessThanOrEqual(sent.deadline, batchDeadline + 1e-9, sent.command)
        }
        XCTAssertEqual(channel.commands, Self.probes, "ATDPN gets what is left of the batch")
        XCTAssertEqual(outcomes(result), [.notAttempted(.streamOutOfSync)])
    }

    /// The inherited stream can't be proven: nothing is configured, so there is nothing to
    /// restore and the adapter keeps its functional addressing. The reads wait for a later cycle.
    func testInheritedDirtyStreamThatCannotBeProvenConfiguresNothing() async throws {
        let channel = ScriptedOEMChannel()
        channel.injectLateAnswer(["OK"], arrivingIn: 5)
        channel.script["ATRV"] = [.silence]
        channel.script["ATDPN"] = [.silence]
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), on: channel)

        XCTAssertEqual(channel.commands, Self.probes, "no setup, no read, no restore")
        XCTAssertEqual(outcomes(result), [.notAttempted(.streamOutOfSync), .notAttempted(.streamOutOfSync)])
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.adapterState, .functional)
        XCTAssertFalse(channel.markedUnresolved)
        XCTAssertEqual(channel.resynchronizations.count, 1, "no restore, so no second proof")
        XCTAssertTrue(channel.dirty)
    }

    /// The real transport with no probe left that could prove the inherited stream (both have an
    /// unanswered earlier send): its `.reconnectRequired` reads exactly like an unproven stream
    /// here. Nothing is written or configured, the reads wait for a later cycle, and the
    /// adapter is not marked unresolved.
    func testAnInheritedStreamThatNeedsAReconnectConfiguresNothing() async throws {
        let adapter = UUID()
        let processor = OBDMessageProcessor()
        let wire = FakeAdapterWire(processor: processor)
        let exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
        _ = try? await exchange.send("010C", retries: 1, responseTimeout: 0.03) { wire.target(adapter) }
        let outcome = try await exchange.resynchronize(target: wire.target(adapter))
        XCTAssertEqual(outcome, .reconnectRequired)
        let writtenBefore = wire.written

        let channel = ExchangeOEMChannel(exchange: exchange, wire: wire, peripheral: adapter)
        do {
            _ = try await channel.send("ATSH 7E0", deadline: processor.clock() + 1)
            XCTFail("expected reconnectRequired")
        } catch {
            XCTAssertEqual(error as? OBDStreamError, .reconnectRequired)
            XCTAssertEqual(OEMBatchExecutor.classify(error), .unsynchronized)
        }

        let batch = try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"])
        let result = await OEMBatchExecutor(batch: batch).run(on: channel)
        XCTAssertEqual(wire.written, writtenBefore, "no setup, no read, no restore, no probe")
        XCTAssertEqual(outcomes(result), [.notAttempted(.streamOutOfSync), .notAttempted(.streamOutOfSync)])
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.adapterState, .functional)
        XCTAssertFalse(channel.markedUnresolved)
    }

    /// The link drops while the inherited stream is being proven: the batch ends `.linkLost`
    /// before anything was configured.
    func testLinkLossWhileProvingTheInheritedStreamIsLinkLost() async throws {
        let channel = ScriptedOEMChannel()
        channel.requireResynchronization()
        channel.script["ATRV"] = [.error(BLEManagerError.peripheralNotConnected)]
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), on: channel)

        XCTAssertEqual(channel.commands, ["ATRV"])
        XCTAssertEqual(outcomes(result), [.notAttempted(.linkLost), .notAttempted(.linkLost)])
        XCTAssertEqual(result.failure, .linkLost)
    }

    // MARK: Response pending

    /// A bare prompt between `78` and the module's answer is not an answer: the listen goes on,
    /// the value that follows is this read's, and the next read gets its own.
    func testBarePromptDuringResponsePendingDoesNotEndTheRead() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .prompts([(["7E8037F2278"], 0.05), ([], 0.2), (["7E80562028D0CE2"], 0.5)])
        channel.reads["221002"] = .lines(["7E805621002FF9C"])
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), on: channel)

        XCTAssertEqual(try XCTUnwrap(number(result.reads[0].outcome, "ECU_T")), 56.7, accuracy: 1e-9)
        XCTAssertEqual(number(result.reads[1].outcome, "TORQUE"), -10)
        XCTAssertEqual(channel.listens.count, 1, "one listen, across the bare prompt")
        XCTAssertEqual(
            channel.deliveries.filter { $0.from == "22028D" }.map(\.to), ["22028D", "listen", "listen"],
            "the bare prompt and the value both went to the listen"
        )
        XCTAssertEqual(channel.deliveries.filter { $0.to == "221002" }.map(\.from), ["221002"])
        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "221002"] + Self.functionalRestore, "no probe needed")
    }

    /// `NO DATA` after `78`: the module was told to wait and may still answer. The next read is
    /// only written once the stream is proven, and the module's late value is drained by the
    /// probe instead of being read as the next read's answer.
    func testNoDataDuringResponsePendingProvesTheStreamBeforeTheNextRead() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .prompts([(["7E8037F2278"], 0.05), (nil, 0.3), (["7E80562028D0CE2"], 0.6)])
        channel.reads["221002"] = .lines(["7E805621002FF9C"])
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), on: channel)

        XCTAssertEqual(result.reads[0].outcome, .responsePendingOnly)
        XCTAssertEqual(number(result.reads[1].outcome, "TORQUE"), -10, "its own answer, not 22028D's")
        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "ATRV", "221002"] + Self.functionalRestore)
        let proof = try XCTUnwrap(channel.resynchronizations.first { $0.wasDirty })
        XCTAssertEqual(proof.before, "221002", "the transport proved it before writing the read")
        XCTAssertEqual(proof.outcome, .proven)
        let late = try XCTUnwrap(channel.deliveries.first { $0.answer == .lines(["7E80562028D0CE2"]) })
        XCTAssertEqual(late.to, "ATRV")
    }

    /// Same, but the stream can't be proven: the next read is not written and gets no answer;
    /// restore then can't prove the stream either and ends unresolved.
    func testNoDataDuringResponsePendingWithAnUnprovenStreamWritesNoFurtherRead() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .prompts([(["7E8037F2278"], 0.05), (nil, 0.3)])
        channel.fallback = { command in Self.probes.contains(command) ? .silence : nil }
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), on: channel)

        XCTAssertEqual(channel.commands.filter { $0.hasPrefix("22") }, ["22028D"])
        // The second read was never written, and says so: it waits for a later cycle.
        XCTAssertEqual(outcomes(result), [.responsePendingOnly, .notAttempted(.streamOutOfSync)])
        XCTAssertFalse(channel.commands.contains("ATSH 7DF"))
        assertNothingButProbesAfterAnUnprovenStream(channel)
        XCTAssertEqual(result.adapterState, .unresolved)
        XCTAssertTrue(channel.markedUnresolved)
    }

    // MARK: Restore on an unproven stream

    /// The read gets no prompt and neither probe answers. Changed: no restore command is sent
    /// at all (was: each sent once, its `OK` uncredited), nothing is verified, and the adapter
    /// ends unresolved.
    func testUnprovenStreamSendsNoRestoreCommandAndEndsUnresolved() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22DA2E"] = .silence
        channel.script["ATRV"] = [.silence]
        channel.script["ATDPN"] = [.silence]
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-bmw", ["B.DA2E", "B.DA23"]), on: channel)

        XCTAssertEqual(channel.commands, Self.bmwSetup18 + ["22DA2E"] + Self.probes)
        XCTAssertEqual(outcomes(result), [.noAnswer, .notAttempted(.streamOutOfSync)])
        XCTAssertEqual(result.adapterState, .unresolved)
        XCTAssertTrue(channel.markedUnresolved)
    }

    /// Changed: restore entered on a dirty stream whose proof fails sends nothing but the probes
    /// (was: every restore command once).
    func testRestoreEnteredOnAnUnprovenStreamSendsNothingMore() async {
        let channel = ScriptedOEMChannel()
        channel.requireResynchronization()
        channel.script["ATRV"] = [.silence]
        channel.script["ATDPN"] = [.silence]
        let outcome = await OEMBatchExecutor.restore(target: .bmwExtended(address: 0x12), on: channel, clock: channel.clock)
        XCTAssertEqual(outcome, .init(verified: false, lostLink: false))
        XCTAssertEqual(channel.commands, Self.probes)
    }

    /// The stream is proven on entry, `ATFCSM 0` then gets no prompt and the second proof fails:
    /// no further restore command (no retry, no `ATAR`, `ATCEA`, `ATSH 7DF`, no `0100`).
    func testRestoreStopsWritingWhenTheStreamCannotBeProvenAgain() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22DA2E"] = .lines(["618F10562DA2E0303"])
        channel.script["ATFCSM 0"] = [.silence]
        channel.script["ATRV"] = [.silence]
        channel.script["ATDPN"] = [.silence]
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-bmw", ["B.DA2E"]), on: channel)

        XCTAssertEqual(channel.commands, Self.bmwSetup18 + ["22DA2E", "ATFCSM 0"] + Self.probes)
        XCTAssertEqual(channel.resynchronizations.map(\.outcome), [.proven, .proven, .unproven], "batch, restore entry, after ATFCSM 0")
        XCTAssertEqual(result.reads[0].outcome, .values([OEMSignalValue(signalID: "GEAR", value: .text("DRIVE"))]))
        XCTAssertEqual(result.adapterState, .unresolved)
        XCTAssertTrue(channel.markedUnresolved)
    }

    // MARK: A restore command without a prompt

    /// `ATSH 7DF`'s `OK` comes after its window. The stream is proven again (the probe drains
    /// that `OK`) before the retry's own `OK` is credited.
    func testRestoreCommandWithoutPromptResynchronizesBeforeTheRetryCounts() async throws {
        let channel = ScriptedOEMChannel()
        channel.script["ATSH 7DF"] = [.lines(["OK"], latency: 0.5), .lines(["OK"])]
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-vw", ["E.028D"]), on: channel)

        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "ATSH 7DF", "ATRV", "ATSH 7DF", "0100"])
        XCTAssertTrue(channel.deliveries.contains { $0.from == "ATSH 7DF" && $0.to == "ATRV" })
        XCTAssertEqual(result.adapterState, .functional)
    }

    /// Same late `OK`, but the retry is never answered. The old executor credited the first
    /// attempt's late `OK` to the retry.
    func testLateOKFromAFirstRestoreAttemptIsNotTheRetrysAnswer() async throws {
        let channel = ScriptedOEMChannel()
        channel.script["ATSH 7DF"] = [.lines(["OK"], latency: 0.5), .silence]
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-vw", ["E.028D"]), on: channel)

        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "ATSH 7DF", "ATRV", "ATSH 7DF", "ATRV"])
        XCTAssertFalse(channel.commands.contains("0100"))
        XCTAssertEqual(result.adapterState, .unresolved)
        XCTAssertTrue(channel.markedUnresolved)
    }

    // MARK: Cancellation

    /// The caller is cancelled while a read waits for its prompt: no more reads, the shielded
    /// restore still runs, proves the stream past that read's late answer, and verifies.
    func testCancelMidReadStopsReadsButRestoreResynchronizesAndVerifies() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E80562028D0CE2"])
        channel.reads["221002"] = .lines(["7E8037F2231"])
        channel.onSend = { command in
            if command == "221002" { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002", "E.1010"]), on: channel)

        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "221002", "ATRV"] + Self.functionalRestore)
        // Changed: the transport's quiet drain discards the late answer before `ATRV` is
        // written (was: handed to the probe). Either way it is credited to nothing.
        XCTAssertEqual(channel.deliveries.filter { $0.from == "221002" }.map(\.to), ["drain"])
        guard case .values = result.reads[0].outcome else { return XCTFail("\(result.reads[0].outcome)") }
        // The interrupted read is never given its late answer. A cancellation can also be thrown
        // before the write, so "sent but unanswered" can't be claimed: it is not attempted.
        XCTAssertEqual(result.reads[1].outcome, .notAttempted(.cancelled))
        XCTAssertEqual(result.reads[2].outcome, .notAttempted(.cancelled))
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(result.adapterState, .functional)
        XCTAssertFalse(channel.markedUnresolved)
    }

    // MARK: Restore budget

    /// Changed: 3.8 s and 6.2 s (was 3.4 s and 5.8 s): two proofs of up to
    /// `synchronizationWindow` each, instead of two rounds of two 0.4 s probe windows.
    func testRestoreBudgets() {
        XCTAssertEqual(OEMBatchExecutor.restoreBudget(for: .standard11Bit(request: 0x7E0, response: 0x7E8)), 3.8, accuracy: 1e-9)
        XCTAssertEqual(OEMBatchExecutor.restoreBudget(for: .bmwExtended(address: 0x12)), 6.2, accuracy: 1e-9)
    }

    /// Restore finishes inside its own budget however the adapter (mis)behaves. Every restore
    /// command is sent at least once whenever the stream can be proven; once a proof fails,
    /// nothing but probes is written. Changed: the old version sent every restore command even
    /// on an unproven stream.
    func testRestoreOnASilentAdapterFinishesWithinItsBudget() async {
        let adapters: [(String, (String) -> ScriptedOEMChannel.Step?, Bool)] = [
            ("completely silent", { _ in .silence }, false),
            ("only the probes answer", { command in
                Self.probes.contains(command) ? nil : .silence
            }, true),
            ("probes answer at the end of their window", { command in
                Self.probes.contains(command)
                    ? .lines(command == "ATRV" ? ["14.1V"] : ["A6"], latency: OBDStreamResynchronizer.Timing().probeWindow - 0.01)
                    : .silence
            }, true),
            ("everything answers late", { command in
                .lines(command == "ATRV" ? ["14.1V"] : command == "ATDPN" ? ["A6"] : ["OK"], latency: 0.45)
            }, false),
        ]
        let targets: [OEMTarget] = [.standard11Bit(request: 0x7E0, response: 0x7E8), .bmwExtended(address: 0x18)]
        for target in targets {
            let budget = OEMBatchExecutor.restoreBudget(for: target)
            for (name, fallback, provable) in adapters {
                for inSync in [true, false] {
                    let label = "\(target) \(name) inSync=\(inSync)"
                    let channel = ScriptedOEMChannel()
                    channel.fallback = fallback
                    if !inSync { channel.requireResynchronization() }
                    let start = channel.clock.now()
                    let outcome = await OEMBatchExecutor.restore(target: target, on: channel, clock: channel.clock)
                    XCTAssertFalse(outcome.verified, label)
                    XCTAssertFalse(outcome.lostLink, label)
                    XCTAssertLessThanOrEqual(channel.clock.now() - start, budget + 1e-9, label)
                    for sent in channel.sent {
                        XCTAssertLessThanOrEqual(sent.deadline, start + budget + 1e-9, "\(label): \(sent.command)")
                    }
                    if provable {
                        for command in OEMAdapterCommand.restore(for: target) {
                            XCTAssertTrue(channel.commands.contains(command), "\(label): \(command) never sent")
                        }
                    } else {
                        XCTAssertTrue(channel.resynchronizations.contains { $0.outcome == .unproven }, label)
                    }
                    assertNothingButProbesAfterAnUnprovenStream(channel, label)
                }
            }
        }
    }

    /// The same through `run`: a completely silent adapter, restore timed from its first write.
    /// Changed: the unproven restore writes only its probes (was: every restore command once).
    func testSilentAdapterBatchRestoresWithinTheRestoreBudget() async throws {
        let channel = ScriptedOEMChannel()
        channel.fallback = { _ in .silence }
        let result = await runOEMBatch(try OEMTestCatalog.batch("test-bmw", ["B.DA2E"]), on: channel)

        // `ATCEA 18` times out, so configuration failed after touching the adapter.
        XCTAssertEqual(result.failure, .configurationFailed)
        XCTAssertEqual(channel.commands, ["ATCEA 18"] + Self.probes)
        let restoreStart = try XCTUnwrap(channel.sent.first { $0.command == "ATRV" }?.at)
        XCTAssertLessThanOrEqual(
            channel.clock.now() - restoreStart,
            OEMBatchExecutor.restoreBudget(for: .bmwExtended(address: 0x18)) + 1e-9
        )
        XCTAssertEqual(result.adapterState, .unresolved)
        XCTAssertTrue(channel.markedUnresolved)
    }
}

/// The judges restore and resynchronization rely on.
final class OEMAnswerJudgingTests: XCTestCase {
    // MARK: `0100` verification (finding 4b)

    func testFullSupportedPIDsAnswerPasses() {
        XCTAssertTrue(OEMReply.isPositiveSupportedPIDsAnswer(["7E8064100BE3EB811"]))
        XCTAssertTrue(OEMReply.isPositiveSupportedPIDsAnswer(["7E8 06 41 00 BE 3E B8 11"]))
        XCTAssertTrue(OEMReply.isPositiveSupportedPIDsAnswer(["7EF064100BE3EB811"]))
        XCTAssertTrue(OEMReply.isPositiveSupportedPIDsAnswer(["7E8064100BE3EB811AA"]), "padding after the length")
        XCTAssertTrue(OEMReply.isPositiveSupportedPIDsAnswer(["SEARCHING...", "7E906410080000001", "7E8064100BE3EB811"]))
    }

    func testIncompleteOrForeignSupportedPIDsAnswersFail() {
        let failures: [(String, [String])] = [
            ("short frame", ["7E8024100"]),
            ("short frame, padded", ["7E8024100AAAAAAAA"]),
            ("declares six, carries four", ["7E8064100BE3E"]),
            ("declares five", ["7E8054100BE3EB8"]),
            ("wrong responder: request id", ["7E0064100BE3EB811"]),
            ("wrong responder: functional", ["7DF064100BE3EB811"]),
            ("wrong responder: BMW module", ["612064100BE3EB811"]),
            ("wrong responder: past 7EF", ["7F0064100BE3EB811"]),
            ("multi-frame first frame", ["7E8100841 00BE3EB8".replacingOccurrences(of: " ", with: ""), "7E8211122AAAAAAAA"]),
            ("non-hex", ["7E8064100BE3EB8ZZ"]),
            ("odd length", ["7E8064100BE3EB81"]),
            ("over-long frame", ["7E8064100BE3EB811AABB"]),
            ("negative response", ["7E8037F0111"]),
            ("wrong PID", ["7E8064120BE3EB811"]),
            ("wrong service", ["7E8064200BE3EB811"]),
            ("status text", ["NO DATA"]),
            ("OK", ["OK"]),
            ("question mark", ["?"]),
            ("nothing", []),
        ]
        for (name, lines) in failures {
            XCTAssertFalse(OEMReply.isPositiveSupportedPIDsAnswer(lines), name)
        }
    }

    // MARK: Sync probe answers

    private static let notAProbeAnswer: [[String]] = [
        ["OK"], ["?"], ["STOPPED"], ["NO DATA"], ["ELM327 v1.5"], ["7E8064100BE3FA813"], ["618F10562DA2E0303"],
        ["7E8037F2231"], ["CAN ERROR"], ["SEARCHING..."], [], [""],
    ]

    func testProtocolNumberAnswer() {
        for good in [["A6"], ["6"], ["AC"], ["1"], ["a6"], [" A6 "], ["", "A6", ""], ["A0"], ["C"]] {
            XCTAssertTrue(OEMAdapterCommand.isProtocolNumberAnswer(good), "\(good)")
        }
        let bad: [[String]] = [
            ["14.1V"], ["66"], ["AD"], ["D"], ["AA6"], ["A66"], ["B6"], ["A6", "OK"], ["A6", "A6"], ["6", "6"],
        ]
        for lines in Self.notAProbeAnswer + bad {
            XCTAssertFalse(OEMAdapterCommand.isProtocolNumberAnswer(lines), "\(lines)")
        }
    }

    /// A bare `A` is the auto prefix with no protocol digit after it (spec from the lead).
    func testBareAIsNotAProtocolNumberAnswer() {
        XCTAssertFalse(OEMAdapterCommand.isProtocolNumberAnswer(["A"]))
    }

    func testVoltageAnswer() {
        for good in [["14.1V"], ["12.65V"], ["9.8V"], ["14.1v"], [" 13.9V "]] {
            XCTAssertTrue(OEMAdapterCommand.isVoltageAnswer(good), "\(good)")
        }
        let bad: [[String]] = [
            ["A6"], ["6"], ["V"], ["141V"], ["14.1"], ["14..1V"], ["123.4V"], ["1.234V"], ["A.BV"], [".1V"], ["1.V"],
            ["14.1V", "OK"], ["14.1V", "14.1V"],
        ]
        for lines in Self.notAProbeAnswer + bad {
            XCTAssertFalse(OEMAdapterCommand.isVoltageAnswer(lines), "\(lines)")
        }
    }

    func testProbesAreATRVThenATDPN() {
        XCTAssertEqual(OEMAdapterCommand.syncProbes.map(\.command), ["ATRV", "ATDPN"])
        XCTAssertTrue(OEMAdapterCommand.syncProbes[0].isAnswer(["14.1V"]))
        XCTAssertFalse(OEMAdapterCommand.syncProbes[0].isAnswer(["A6"]))
        XCTAssertTrue(OEMAdapterCommand.syncProbes[1].isAnswer(["A6"]))
        XCTAssertFalse(OEMAdapterCommand.syncProbes[1].isAnswer(["14.1V"]))
    }

    /// A late probe answer must never pass for the `ATZ` reset banner the addressing gate waits
    /// for, and no probe resets or identifies the adapter.
    func testNoProbeAnswerLooksLikeAResetBanner() {
        XCTAssertFalse(OEMAddressingGate.isResetBanner(["14.1V"]))
        XCTAssertFalse(OEMAddressingGate.isResetBanner(["A6"]))
        XCTAssertTrue(OEMAddressingGate.isResetBanner(["ELM327 v1.5"]), "the banner itself is still recognized")
        for probe in OEMAdapterCommand.syncProbes {
            let compact = probe.command.filter { !$0.isWhitespace }.uppercased()
            XCTAssertNotEqual(compact, "ATI")
            XCTAssertFalse(compact.hasPrefix("ATZ"), probe.command)
            XCTAssertFalse(probe.isAnswer(["ELM327 v1.5"]), "\(probe.command) must not accept a reset banner")
        }
    }
}
