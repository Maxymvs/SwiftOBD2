//
//  OEMBatchExecutorTests.swift
//  SwiftOBD2Tests
//
//  Fault injection for manufacturer batches: a stream-faithful channel and a fake clock drive
//  every path the plan names (cancel during configuration, NRC 78 across prompts, truncation,
//  deadline expiry, admission, cleanup failure) plus the reply checks. Late answers and
//  resynchronization have their own file (`OEMResynchronizationTests`). Synthetic replies only.
//

@testable import SwiftOBD2
import XCTest

final class OEMBatchExecutorTests: XCTestCase {
    private func run(
        _ batch: OEMReadBatch,
        _ channel: ScriptedOEMChannel,
        deadline: TimeInterval? = nil,
        admission: OEMBatchAdmission? = nil
    ) async -> OEMBatchResult {
        await runOEMBatch(batch, on: channel, deadline: deadline, admission: admission)
    }

    private func outcomes(_ result: OEMBatchResult) -> [OEMReadOutcome] {
        result.reads.map(\.outcome)
    }

    private func number(_ outcome: OEMReadOutcome, _ signal: String) -> Double? {
        guard case let .values(values) = outcome,
              case let .number(value)? = values.first(where: { $0.signalID == signal })?.value else { return nil }
        return value
    }

    private static let functionalRestore = ["ATSH 7DF", "0100"]
    private static let bmwRestore = ["ATFCSM 0", "ATAR", "ATCEA", "ATSH 7DF", "0100"]
    private static let bmwSetup18 = ["ATCEA 18", "ATSH 6F1", "ATCRA 618", "ATFCSH 6F1", "ATFCSD 1830000A", "ATFCSM 1"]
    private static let gearDrive = OEMReadOutcome.values([OEMSignalValue(signalID: "GEAR", value: .text("DRIVE"))])

    // MARK: Happy paths

    func testHappyPathStandardAddressing() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E80562028D0CE2"])
        channel.reads["221002"] = .lines(["7E805621002FF9C"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), channel)

        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "221002"] + Self.functionalRestore)
        XCTAssertEqual(result.reads.map(\.commandID), ["E.028D", "E.1002"])
        XCTAssertEqual(try XCTUnwrap(number(result.reads[0].outcome, "ECU_T")), 56.7, accuracy: 1e-9)
        XCTAssertEqual(number(result.reads[1].outcome, "TORQUE"), -10)
        XCTAssertEqual(result.adapterState, .functional)
        XCTAssertNil(result.failure)
        XCTAssertFalse(channel.markedUnresolved)
        XCTAssertEqual(channel.listens, [], "nothing pending, nothing to listen for")
        XCTAssertEqual(result.elapsed, 0.25, accuracy: 1e-9) // five sends × 50 ms

        // Absolute deadlines: each phase's own timeout from the moment of the write.
        let windows = channel.sent.map { $0.deadline - $0.at }
        XCTAssertEqual(windows[0], OEMBatchExecutor.setupCommandTimeout, accuracy: 1e-9)
        XCTAssertEqual(windows[1], OEMBatchExecutor.readTimeout, accuracy: 1e-9)
        XCTAssertEqual(windows[3], OEMBatchExecutor.restoreCommandTimeout, accuracy: 1e-9)
        XCTAssertEqual(windows[4], OEMBatchExecutor.verificationTimeout, accuracy: 1e-9)
    }

    func testHappyPathBMWExtendedAddressingWithMultiFrameReply() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22DA2E"] = .lines(["618F10562DA2E0303"])
        channel.reads["22DA23"] = .lines(["618F1100762DA230000", "618F1211A0FFFFFFFFF"])
        let result = await run(try OEMTestCatalog.batch("test-bmw", ["B.DA2E", "B.DA23"]), channel)

        XCTAssertEqual(channel.commands, Self.bmwSetup18 + ["22DA2E", "22DA23"] + Self.bmwRestore)
        XCTAssertEqual(result.reads[0].outcome, Self.gearDrive)
        XCTAssertEqual(number(result.reads[1].outcome, "ODO"), 0x1A0F)
        XCTAssertEqual(result.adapterState, .functional)
        XCTAssertNil(result.failure)
    }

    func testStandardMultiFrameReplyReassembles() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["2258D1"] = .lines(["7E810116258D100013D", "7E8213A00013D3AFFFC", "7E82201030007AAAAAA"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.58D1"]), channel)
        XCTAssertEqual(number(result.reads[0].outcome, "LONG"), 7)
    }

    // MARK: Cancellation

    /// Premise changed: a cancellation that interrupts the wait for `ATCRA 618`'s prompt leaves
    /// its `OK` on the way, so restore must resynchronize (`ATRV`) before any `OK` counts.
    func testCancelDuringConfigurationResynchronizesThenRestoresAndVerifies() async throws {
        let channel = ScriptedOEMChannel()
        channel.onSend = { command in
            if command == "ATCRA 618" { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let result = await run(try OEMTestCatalog.batch("test-bmw", ["B.DA2E", "B.DA23"]), channel)

        XCTAssertEqual(channel.commands, ["ATCEA 18", "ATSH 6F1", "ATCRA 618", "ATRV"] + Self.bmwRestore)
        XCTAssertEqual(outcomes(result), [.notAttempted(.cancelled), .notAttempted(.cancelled)])
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(result.adapterState, .functional)
        // The interrupted `OK` was discarded, not credited to `ATFCSM 0`. Changed: the transport's
        // quiet drain now discards it before `ATRV` is written (was: handed to the probe).
        XCTAssertEqual(channel.deliveries.filter { $0.from == "ATCRA 618" }.map(\.to), ["drain"])
    }

    /// The old premise, kept: cancelled after a prompt arrived, the stream is in sync and restore
    /// needs no probe.
    func testCancelAfterASetupAnswerRestoresWithoutResynchronizing() async throws {
        let channel = ScriptedOEMChannel()
        channel.onAnswer = { command in
            if command == "ATCRA 618" { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let result = await run(try OEMTestCatalog.batch("test-bmw", ["B.DA2E", "B.DA23"]), channel)

        XCTAssertEqual(channel.commands, ["ATCEA 18", "ATSH 6F1", "ATCRA 618"] + Self.bmwRestore)
        XCTAssertEqual(outcomes(result), [.notAttempted(.cancelled), .notAttempted(.cancelled)])
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(result.adapterState, .functional)
    }

    /// Premise changed: a `CancellationError` thrown by the send means no prompt was seen, so the
    /// stream is proven with `ATRV` first.
    func testCancellationErrorFromASetupSendStillRestores() async throws {
        let channel = ScriptedOEMChannel()
        channel.script["ATSH 7E0"] = [.error(CancellationError())]
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)

        XCTAssertEqual(channel.commands, ["ATSH 7E0", "ATRV"] + Self.functionalRestore)
        XCTAssertEqual(outcomes(result), [.notAttempted(.cancelled)])
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(result.adapterState, .functional)
    }

    /// The caller is cancelled once the first read's answer is in: that value is kept, nothing
    /// else is read, restore runs.
    func testCancelBetweenReadsKeepsFinishedReadsAndRestores() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E80562028D0CE2"])
        channel.onAnswer = { command in
            if command == "22028D" { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002", "E.1010"]), channel)

        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D"] + Self.functionalRestore)
        XCTAssertNotNil(number(result.reads[0].outcome, "ECU_T"))
        XCTAssertEqual(Array(outcomes(result).dropFirst()), [.notAttempted(.cancelled), .notAttempted(.cancelled)])
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(result.adapterState, .functional)
    }

    func testCancelledBeforeAnythingSendsNothing() async throws {
        let channel = ScriptedOEMChannel()
        let executor = OEMBatchExecutor(batch: try OEMTestCatalog.batch("test-vw", ["E.028D"]), clock: channel.clock)
        let task = Task { () -> OEMBatchResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await executor.run(on: channel)
        }
        let result = await task.value
        XCTAssertEqual(channel.commands, [])
        XCTAssertEqual(outcomes(result), [.notAttempted(.cancelled)])
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(result.adapterState, .functional)
    }

    // MARK: Response pending

    func testResponsePendingAndAnswerInOnePrompt() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E8037F2278", "7E80562028D0CE2"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)
        XCTAssertEqual(try XCTUnwrap(number(result.reads[0].outcome, "ECU_T")), 56.7, accuracy: 1e-9)
        XCTAssertEqual(channel.listens, [])
    }

    /// Finding 8: `78` and its prompt, then the answer as a separate prompt. The executor
    /// listens for it and never writes the request again.
    func testResponsePendingAcrossPromptsOnBMW() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22DA2E"] = .prompts([(["618F1037F2278"], 0.05), (["618F10562DA2E0303"], 0.6)])
        let result = await run(try OEMTestCatalog.batch("test-bmw", ["B.DA2E"]), channel)

        XCTAssertEqual(result.reads[0].outcome, Self.gearDrive)
        XCTAssertEqual(channel.commands.filter { $0 == "22DA2E" }.count, 1, "the request is written exactly once")
        XCTAssertEqual(channel.listens.count, 1)
        XCTAssertEqual(channel.commands, Self.bmwSetup18 + ["22DA2E"] + Self.bmwRestore, "no resynchronization needed")
        XCTAssertEqual(result.adapterState, .functional)
    }

    func testResponsePendingAcrossPromptsOnStandardAddressing() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .prompts([(["7E8037F2278"], 0.05), (["7E80562028D0CE2"], 0.4)])
        channel.reads["221002"] = .lines(["7E805621002FF9C"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), channel)

        XCTAssertEqual(try XCTUnwrap(number(result.reads[0].outcome, "ECU_T")), 56.7, accuracy: 1e-9)
        XCTAssertEqual(number(result.reads[1].outcome, "TORQUE"), -10, "the next read gets its own answer")
        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "221002"] + Self.functionalRestore)
        XCTAssertEqual(result.adapterState, .functional)
    }

    func testSecondResponsePendingThenAnswer() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .prompts([(["7E8037F2278"], 0.05), (["7E8037F2278"], 0.5), (["7E80562028D0CE2"], 0.9)])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)

        XCTAssertEqual(try XCTUnwrap(number(result.reads[0].outcome, "ECU_T")), 56.7, accuracy: 1e-9)
        XCTAssertEqual(channel.commands.filter { $0 == "22028D" }.count, 1)
        XCTAssertEqual(channel.listens.count, 2)
    }

    /// The module never answers after `78`: no value, the stream is out of sync (the answer may
    /// still come), so later reads aren't sent and restore resynchronizes first.
    func testResponsePendingWithNoAnswerStopsTheStream() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E8037F2278"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002", "E.1010"]), channel)

        XCTAssertEqual(outcomes(result), [.responsePendingOnly, .notAttempted(.streamOutOfSync), .notAttempted(.streamOutOfSync)])
        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "ATRV"] + Self.functionalRestore)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.adapterState, .functional)
        // It listened for the pending window, no longer.
        let read = try XCTUnwrap(channel.sent.first { $0.command == "22028D" })
        XCTAssertEqual(try XCTUnwrap(channel.listens.last), read.at + 0.05 + OEMBatchExecutor.responsePendingWindow, accuracy: 1e-9)
    }

    /// `NO DATA` after `78`: the adapter gave up and printed its prompt, so the next read still
    /// runs. Changed: the module was told to wait and may still answer, so the transport proves
    /// the stream (`ATRV`) before it writes that read (was: written straight away).
    func testNoDataAfterResponsePendingKeepsReading() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .prompts([(["7E8037F2278"], 0.05), (nil, 0.3)])
        channel.reads["221002"] = .lines(["7E805621002FF9C"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), channel)

        XCTAssertEqual(result.reads[0].outcome, .responsePendingOnly)
        XCTAssertEqual(number(result.reads[1].outcome, "TORQUE"), -10)
        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "ATRV", "221002"] + Self.functionalRestore)
        XCTAssertEqual(channel.resynchronizations.filter(\.wasDirty).map(\.before), ["221002"])
        XCTAssertEqual(result.adapterState, .functional)
    }

    // MARK: Damaged replies

    func testTruncatedMultiFrameIsIncomplete() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["2258D1"] = .lines(["7E810116258D100013D", "7E8213A00013D3AFFFC"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.58D1"]), channel)
        XCTAssertEqual(outcomes(result), [.malformed(.incomplete)])
    }

    func testOutOfSequenceAndMergedFramesAreCorrupted() async throws {
        let replies: [[String]] = [
            ["7E810116258D100013D", "7E82201030007AAAAAA", "7E8213A00013D3AFFFC"], // out of order
            ["7E810116258D100013D", "7E8213A00013D3AFFFC7E82201030007AAAAAA"], // two frames merged
            ["7E810116258D100013D", "7E8213A00013D", "7E82201030007AAAAAA"], // short middle frame
            ["7E80562028D0CE"], // odd length
            ["7E80562028DXCE2"], // not hex
            ["7E80562028D"], // shorter than its declared length
            ["7E8300000"], // flow control from the module
        ]
        for reply in replies {
            let channel = ScriptedOEMChannel()
            channel.reads["2258D1"] = .lines(reply)
            channel.reads["22028D"] = .lines(reply)
            let id = reply[0].hasPrefix("7E81011") ? "E.58D1" : "E.028D"
            let result = await run(try OEMTestCatalog.batch("test-vw", [id]), channel)
            XCTAssertEqual(outcomes(result), [.malformed(.corruptedFrame)], "\(reply)")
        }
    }

    func testBMWFrameWithoutTesterAddressIsCorrupted() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22DA2E"] = .lines(["6180562DA2E0303"])
        let result = await run(try OEMTestCatalog.batch("test-bmw", ["B.DA2E"]), channel)
        XCTAssertEqual(outcomes(result), [.malformed(.corruptedFrame)])
    }

    func testBufferFullIsCorrupted() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E80562028D0CE2", "BUFFER FULL"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)
        XCTAssertEqual(outcomes(result), [.malformed(.corruptedFrame)])
    }

    // MARK: Reply checks

    func testWrongResponder() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E90562028D0CE2"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)
        XCTAssertEqual(outcomes(result), [.wrongResponder])
    }

    func testOtherRespondersAreIgnoredWhenTheModuleAnswers() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E90562028D0000", "SEARCHING...", "7E80562028D0CE2"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)
        XCTAssertEqual(try XCTUnwrap(number(result.reads[0].outcome, "ECU_T")), 56.7, accuracy: 1e-9)
    }

    func testIdentifierEchoMismatch() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E80562028E0CE2"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)
        XCTAssertEqual(outcomes(result), [.malformed(.identifierMismatch)])
    }

    func testUnexpectedService() async throws {
        for reply in ["7E803410C00", "7E8037F1931", "7E8027F22"] {
            let channel = ScriptedOEMChannel()
            channel.reads["22028D"] = .lines([reply])
            let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)
            XCTAssertEqual(outcomes(result), [.malformed(.unexpectedService)], reply)
        }
    }

    func testNegativeResponse() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E8037F2231"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)
        XCTAssertEqual(outcomes(result), [.negativeResponse(code: 0x31)])
    }

    func testNoDataIsNoAnswer() async throws {
        let thrown = ScriptedOEMChannel() // the processor throws `.noData` for `NO DATA`
        let resultThrown = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), thrown)
        XCTAssertEqual(outcomes(resultThrown), [.noAnswer])
        XCTAssertEqual(thrown.commands, ["ATSH 7E0", "22028D"] + Self.functionalRestore, "NO DATA has a prompt: in sync")

        let text = ScriptedOEMChannel()
        text.reads["22028D"] = .lines(["NO DATA"])
        let resultText = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), text)
        XCTAssertEqual(outcomes(resultText), [.noAnswer])
        XCTAssertEqual(resultText.adapterState, .functional)
    }

    func testUnexpectedReplyLength() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E80462028D0C"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)
        XCTAssertEqual(outcomes(result), [.malformed(.unexpectedLength)])
    }

    func testPayloadTooShortForASignal() async throws {
        // E.1002 has no recorded reply lengths, so the decoder is what catches the short payload.
        let channel = ScriptedOEMChannel()
        channel.reads["221002"] = .lines(["7E80462100201"])
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.1002"]), channel)
        XCTAssertEqual(outcomes(result), [.malformed(.payloadTooShort)])
    }

    // MARK: Budget and deadlines

    func testBudgetRunningOutBetweenReadsStillRestores() async throws {
        let channel = ScriptedOEMChannel()
        for wire in ["22028D", "221002", "221010", "222000"] {
            channel.reads[wire] = .noData(latency: 0.9)
        }
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002", "E.1010", "E.2000"]), channel)

        // 0.05 setup + 0.9 + 0.9 leaves 0.15 s, less than a read window.
        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "221002"] + Self.functionalRestore)
        XCTAssertEqual(outcomes(result), [.noAnswer, .noAnswer, .notAttempted(.budgetExhausted), .notAttempted(.budgetExhausted)])
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.adapterState, .functional)
    }

    /// Premise changed: a read cut short by the batch deadline got no prompt, so its answer can
    /// still arrive. It's `.noAnswer`, the next read is skipped as out of sync (not out of
    /// budget), and restore drains the late `NO DATA` before it trusts an `OK`.
    func testReadCutShortByTheBatchDeadlineStopsTheStream() async throws {
        let channel = ScriptedOEMChannel()
        for wire in ["22028D", "221002", "221010", "222000"] {
            channel.reads[wire] = .noData(latency: 0.8)
        }
        let start = channel.clock.now()
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002", "E.1010", "E.2000"]), channel)

        // 0.05 + 0.8 + 0.8 leaves 0.35 s: the third read gets exactly that and times out. Its late
        // `NO DATA` lands after `ATRV`'s window, ahead of `ATRV`'s answer, so `ATDPN` drains it.
        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "221002", "221010", "ATRV", "ATDPN"] + Self.functionalRestore)
        XCTAssertEqual(channel.sent[3].deadline, start + 2.0, accuracy: 1e-9)
        XCTAssertEqual(outcomes(result), [.noAnswer, .noAnswer, .noAnswer, .notAttempted(.streamOutOfSync)])
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.adapterState, .functional)
        for sent in channel.sent where sent.command.hasPrefix("22") {
            XCTAssertLessThanOrEqual(sent.deadline - sent.at, OEMBatchExecutor.readTimeout + 1e-9)
        }
    }

    func testBudgetTooSmallForAnyReadTouchesNothing() async throws {
        let channel = ScriptedOEMChannel()
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"], budget: 0.1), channel)
        XCTAssertEqual(channel.commands, [])
        XCTAssertEqual(outcomes(result), [.notAttempted(.budgetExhausted), .notAttempted(.budgetExhausted)])
        XCTAssertEqual(result.adapterState, .functional)
    }

    /// Finding 6: the transport starts the deadline before it waits for its mutex. When that
    /// wait ate the budget, the batch sends nothing, although the batch's own budget is 2 s.
    func testNearlySpentAbsoluteDeadlineSendsNothing() async throws {
        for remaining in [0.1, 0, -0.5] as [TimeInterval] {
            let channel = ScriptedOEMChannel()
            let result = await run(
                try OEMTestCatalog.batch("test-bmw", ["B.DA2E", "B.DA23"]), channel,
                deadline: channel.clock.now() + remaining
            )
            XCTAssertEqual(channel.commands, [], "\(remaining)")
            XCTAssertEqual(outcomes(result), [.notAttempted(.budgetExhausted), .notAttempted(.budgetExhausted)], "\(remaining)")
            XCTAssertNil(result.failure)
            XCTAssertEqual(result.adapterState, .functional)
            XCTAssertFalse(channel.markedUnresolved)
        }
    }

    /// No setup or read write is ever given a deadline past the batch's, whatever its own timeout.
    func testNoSetupOrReadSendOutlivesTheBatchDeadline() async throws {
        for remaining in [0.4, 0.7, 1.0, 1.3] as [TimeInterval] {
            let channel = ScriptedOEMChannel()
            channel.reads["22DA2E"] = .silence
            channel.reads["22DA23"] = .silence
            let batchDeadline = channel.clock.now() + remaining
            let batch = try OEMTestCatalog.batch("test-bmw", ["B.DA2E", "B.DA23"])
            _ = await run(batch, channel, deadline: batchDeadline)

            let setupAndReads = channel.sent.filter { sent in
                Self.bmwSetup18.contains(sent.command) || sent.command.hasPrefix("22")
            }
            XCTAssertFalse(setupAndReads.isEmpty, "\(remaining)")
            for sent in setupAndReads {
                XCTAssertLessThanOrEqual(sent.deadline, batchDeadline + 1e-9, "\(remaining): \(sent.command)")
            }
            // A silent read waits until exactly the batch deadline when that's sooner than its own.
            if let read = channel.sent.first(where: { $0.command.hasPrefix("22") }),
               batchDeadline - read.at < OEMBatchExecutor.readTimeout {
                XCTAssertEqual(read.deadline, batchDeadline, accuracy: 1e-9, "\(remaining)")
            }
        }
    }

    /// Restore has its own deadline: a read that ran to the batch deadline is still followed by
    /// a full restore and verification, all of it after the batch deadline.
    func testRestoreRunsAfterTheBatchDeadlineOnItsOwnBudget() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .silence
        let batchDeadline = channel.clock.now() + 1.0
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel, deadline: batchDeadline)

        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "ATRV"] + Self.functionalRestore)
        XCTAssertEqual(outcomes(result), [.noAnswer])
        XCTAssertEqual(result.adapterState, .functional)
        let restore = channel.sent.drop(while: { $0.command != "ATRV" })
        XCTAssertEqual(restore.count, 3)
        for sent in restore {
            XCTAssertGreaterThanOrEqual(sent.at, batchDeadline, sent.command)
            XCTAssertGreaterThan(sent.deadline, batchDeadline, sent.command)
        }
    }

    func testBudgetRunningOutDuringConfigurationStillRestores() async throws {
        let channel = ScriptedOEMChannel()
        channel.script["ATSH 6F1"] = [.lines(["OK"], latency: 0.45)]
        channel.script["ATCRA 612"] = [.lines(["OK"], latency: 0.45)]
        channel.script["ATFCSH 6F1"] = [.lines(["OK"], latency: 0.45)]
        channel.script["ATFCSD 1230000A"] = [.lines(["OK"], latency: 0.45)]
        let result = await run(try OEMTestCatalog.batch("test-bmw", ["B.4001"]), channel)

        XCTAssertEqual(channel.commands, ["ATCEA 12", "ATSH 6F1", "ATCRA 612", "ATFCSH 6F1", "ATFCSD 1230000A"] + Self.bmwRestore)
        XCTAssertEqual(outcomes(result), [.notAttempted(.budgetExhausted)])
        XCTAssertEqual(result.adapterState, .functional)
    }

    // MARK: Admission

    func testAdmissionRevokedBeforeSetupSendsNothing() async throws {
        let channel = ScriptedOEMChannel()
        let script = OEMAdmissionScript([false])
        let result = await run(try OEMTestCatalog.batch("test-bmw", ["B.DA2E", "B.DA23"]), channel, admission: script.admission)

        XCTAssertEqual(channel.commands, [])
        XCTAssertEqual(result.failure, .admissionRevoked)
        XCTAssertEqual(outcomes(result), [.notAttempted(.admissionRevoked), .notAttempted(.admissionRevoked)])
        XCTAssertEqual(result.adapterState, .functional)
        XCTAssertFalse(channel.markedUnresolved)
        let calls = await script.calls
        XCTAssertEqual(calls, 1)
    }

    func testAdmissionRevokedBetweenReadsKeepsEarlierResultsAndRestores() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E80562028D0CE2"])
        // Held (yes), before read 1 (yes), before read 2 (no).
        let script = OEMAdmissionScript([true, true, false])
        let result = await run(
            try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002", "E.1010"]), channel, admission: script.admission
        )

        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D"] + Self.functionalRestore)
        XCTAssertEqual(try XCTUnwrap(number(result.reads[0].outcome, "ECU_T")), 56.7, accuracy: 1e-9)
        XCTAssertEqual(Array(outcomes(result).dropFirst()), [.notAttempted(.admissionRevoked), .notAttempted(.admissionRevoked)])
        XCTAssertEqual(result.failure, .admissionRevoked)
        XCTAssertEqual(result.adapterState, .functional)
        let calls = await script.calls
        XCTAssertEqual(calls, 3)
    }

    func testAdmissionIsAskedOnceHeldAndBeforeEveryRead() async throws {
        let channel = ScriptedOEMChannel()
        let script = OEMAdmissionScript([true])
        _ = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002", "E.1010"]), channel, admission: script.admission)
        let calls = await script.calls
        XCTAssertEqual(calls, 4)
    }

    func testAdmissionCanReadMainActorStateSynchronously() async throws {
        let channel = ScriptedOEMChannel()
        let script = OEMAdmissionScript([true, false])
        let admission: OEMBatchAdmission = {
            // A synchronous call on its declared actor cannot suspend to issue a command.
            MainActor.assertIsolated()
            return script.next()
        }
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel, admission: admission)
        XCTAssertEqual(result.failure, .admissionRevoked)
        XCTAssertEqual(channel.commands, ["ATSH 7E0"] + Self.functionalRestore)
    }

    // MARK: Configuration failures

    func testQuestionMarkOnSetupIsConfigurationRejected() async throws {
        let channel = ScriptedOEMChannel()
        channel.script["ATSH 7E0"] = [.lines(["?"])]
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), channel)

        XCTAssertEqual(channel.commands, ["ATSH 7E0"] + Self.functionalRestore)
        XCTAssertEqual(result.failure, .configurationRejected(command: "ATSH 7E0"))
        XCTAssertEqual(outcomes(result), [.notAttempted(.configurationFailed), .notAttempted(.configurationFailed)])
        XCTAssertEqual(result.adapterState, .functional)
    }

    /// Premise extended: a silent setup command left no prompt, so restore proves the stream
    /// (`ATRV`) first; `STOPPED` and `NO DATA` came with a prompt and need no probe.
    func testSetupSilenceOrOtherTextIsConfigurationFailed() async throws {
        let cases: [(ScriptedOEMChannel.Step, [String])] = [
            (.silence, ["ATRV"]),
            (.lines(["STOPPED"]), []),
            (.noData(), []),
        ]
        for (step, probes) in cases {
            let channel = ScriptedOEMChannel()
            channel.script["ATCRA 618"] = [step]
            let result = await run(try OEMTestCatalog.batch("test-bmw", ["B.DA2E"]), channel)
            XCTAssertEqual(channel.commands, ["ATCEA 18", "ATSH 6F1", "ATCRA 618"] + probes + Self.bmwRestore)
            XCTAssertEqual(result.failure, .configurationFailed)
            XCTAssertEqual(outcomes(result), [.notAttempted(.configurationFailed)])
            XCTAssertEqual(result.adapterState, .functional)
        }
    }

    // MARK: Cleanup failures

    func testRestoreHeaderNotOKLeavesTheAdapterUnresolved() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E80562028D0CE2"])
        channel.script["ATSH 7DF"] = [.lines(["?"]), .lines(["?"])]
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)

        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "ATSH 7DF", "ATSH 7DF"])
        XCTAssertEqual(result.adapterState, .unresolved)
        XCTAssertTrue(channel.markedUnresolved)
        XCTAssertNotNil(number(result.reads[0].outcome, "ECU_T"), "finished reads are still reported")
    }

    func testRestoreRetryRecoversFromAStoppedAnswer() async throws {
        let channel = ScriptedOEMChannel()
        channel.script["ATSH 7DF"] = [.lines(["STOPPED"])]
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)
        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "ATSH 7DF", "ATSH 7DF", "0100"])
        XCTAssertEqual(result.adapterState, .functional)
        XCTAssertFalse(channel.markedUnresolved)
    }

    func testFailedBMWRestoreStepStillRunsTheRestButStaysUnresolved() async throws {
        let channel = ScriptedOEMChannel()
        channel.script["ATCEA"] = [.lines(["?"]), .lines(["?"])]
        let result = await run(try OEMTestCatalog.batch("test-bmw", ["B.4001"]), channel)
        XCTAssertEqual(Array(channel.commands.suffix(5)), ["ATFCSM 0", "ATAR", "ATCEA", "ATCEA", "ATSH 7DF"])
        XCTAssertFalse(channel.commands.contains("0100"))
        XCTAssertEqual(result.adapterState, .unresolved)
        XCTAssertTrue(channel.markedUnresolved)
    }

    func testFailedVerificationLeavesTheAdapterUnresolved() async throws {
        let failures: [(String, ScriptedOEMChannel.Step)] = [
            ("no data", .noData()),
            ("silence", .silence),
            ("negative", .lines(["7E8037F0111"])),
            ("not an OBD responder", .lines(["612064100BE3EB811"])),
            ("question mark", .lines(["?"])),
            ("short 41 00 frame", .lines(["7E8024100"])),
        ]
        for (name, step) in failures {
            let channel = ScriptedOEMChannel()
            channel.script["0100"] = [step]
            let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)
            XCTAssertEqual(channel.commands.last, "0100", name)
            XCTAssertEqual(result.adapterState, .unresolved, name)
            XCTAssertTrue(channel.markedUnresolved, name)
        }
    }

    /// Finding 4b: `7E8024100` is `41 00` without the bitmap. The old check took it as proof of
    /// functional addressing.
    func testShortSupportedPIDsAnswerDoesNotVerifyTheRestore() async throws {
        for (batch, restore) in [
            (try OEMTestCatalog.batch("test-vw", ["E.028D"]), Self.functionalRestore),
            (try OEMTestCatalog.batch("test-bmw", ["B.4001"]), Self.bmwRestore),
        ] {
            let channel = ScriptedOEMChannel()
            channel.script["0100"] = [.lines(["7E8024100"])]
            let result = await run(batch, channel)
            XCTAssertEqual(Array(channel.commands.suffix(restore.count)), restore)
            XCTAssertEqual(result.adapterState, .unresolved)
            XCTAssertTrue(channel.markedUnresolved)
        }
    }

    // MARK: Link loss

    func testLinkLossStopsTheBatchAndLeavesItUnresolved() async throws {
        for error in [BLEManagerError.peripheralNotConnected, BLEManagerError.missingPeripheralOrCharacteristic] as [Error]
            + [BLEMessageProcessorError.staleRequestToken, BLEWriteCoordinatorError.channelPoisoned] {
            let channel = ScriptedOEMChannel()
            channel.reads["22028D"] = .lines(["7E80562028D0CE2"])
            channel.reads["221002"] = .error(error)
            let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002", "E.1010"]), channel)

            XCTAssertNotNil(number(result.reads[0].outcome, "ECU_T"))
            XCTAssertEqual(Array(outcomes(result).dropFirst()), [.notAttempted(.linkLost), .notAttempted(.linkLost)], "\(error)")
            XCTAssertFalse(channel.commands.contains("221010"), "no read after the link dropped")
            XCTAssertEqual(result.failure, .linkLost)
            XCTAssertEqual(result.adapterState, .unresolved)
            XCTAssertTrue(channel.markedUnresolved)
        }
    }

    /// A caller with no admission check still gets a link check before every read.
    func testLinkReplacedBetweenReadsStopsBeforeTheNextRead() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .lines(["7E80562028D0CE2"])
        let executor = OEMBatchExecutor(batch: try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), clock: channel.clock)
        let result = await Task {
            await executor.run(on: channel, isLinkCurrent: { !channel.commands.contains("22028D") })
        }.value
        XCTAssertNotNil(number(result.reads[0].outcome, "ECU_T"))
        XCTAssertEqual(outcomes(result).last, .notAttempted(.linkLost))
        XCTAssertFalse(channel.commands.contains("221002"), "no read after the link was replaced")
        XCTAssertEqual(result.failure, .linkLost)
    }

    func testLinkLossDuringRestoreIsUnresolved() async throws {
        let channel = ScriptedOEMChannel()
        channel.script["ATSH 7DF"] = [.error(BLEManagerError.peripheralNotConnected)]
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D"]), channel)
        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "ATSH 7DF"])
        XCTAssertEqual(result.failure, .linkLost)
        XCTAssertEqual(result.adapterState, .unresolved)
    }

    func testWriteDeadlineExceededIsATimeoutNotALostLink() async throws {
        let channel = ScriptedOEMChannel()
        channel.reads["22028D"] = .error(BLEWriteCoordinatorError.deadlineExceeded)
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]), channel)

        XCTAssertEqual(outcomes(result), [.noAnswer, .notAttempted(.streamOutOfSync)])
        XCTAssertNil(result.failure)
        XCTAssertEqual(channel.commands, ["ATSH 7E0", "22028D", "ATRV"] + Self.functionalRestore)
        XCTAssertEqual(result.adapterState, .functional)
    }

    // MARK: Vehicle requests are never retransmitted

    func testEveryReadIsSentExactlyOnce() async throws {
        let channel = ScriptedOEMChannel()
        let result = await run(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002", "E.1010", "E.2000"]), channel)
        XCTAssertEqual(outcomes(result), Array(repeating: .noAnswer, count: 4))
        let reads = channel.commands.filter { $0.hasPrefix("22") }
        XCTAssertEqual(reads, ["22028D", "221002", "221010", "222000"])
    }
}
