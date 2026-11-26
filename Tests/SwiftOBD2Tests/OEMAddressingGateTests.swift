//
//  OEMAddressingGateTests.swift
//  SwiftOBD2Tests
//
//  The fail-closed gate after an unresolved batch: keyed by adapter, opened only by a verified
//  recovery. Also the recovery the real connection code sends, end to end through the transport's
//  exchange, and the entry point's refusals.
//

@testable import SwiftOBD2
import XCTest

final class OEMAddressingGateTests: XCTestCase {
    private let adapter = UUID()
    private let otherAdapter = UUID()

    private let banner = ["ELM327 v1.5"]
    private let ok = ["OK"]
    private let supportedPIDs = ["7E8064100BE3EB811"]

    private func assertRefused(_ gate: OEMAddressingGate, _ command: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try gate.check(command, peripheral: adapter), command, file: file, line: line) {
            XCTAssertEqual($0 as? OEMAddressingGateError, .addressingUnresolved, file: file, line: line)
        }
    }

    private func assertAllowed(_ gate: OEMAddressingGate, _ command: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try gate.check(command, peripheral: adapter), command, file: file, line: line)
    }

    /// Reset banner, then the initialization `adapterInitialization()` sends, each answered `OK`.
    private func reinitialize(_ gate: OEMAddressingGate) {
        gate.noteAnswered("ATZ", lines: banner, peripheral: adapter)
        for command in ["ATE0", "ATL0", "ATS0", "ATH1", "ATSP0"] {
            gate.noteAnswered(command, lines: ok, peripheral: adapter)
        }
    }

    // MARK: Arming and scope

    func testInertUntilMarked() {
        let gate = OEMAddressingGate()
        XCTAssertFalse(gate.isUnresolved(adapter))
        for command in ["0100", "010C", "22028D", "ATSH 7E0", "STPX d:0100"] {
            assertAllowed(gate, command)
        }
        // Answers to an adapter that was never marked change nothing.
        gate.noteAnswered("ATZ", lines: ["?"], peripheral: adapter)
        XCTAssertNil(gate.phase(of: adapter))
    }

    func testKeyedByPeripheral() {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        XCTAssertTrue(gate.isUnresolved(adapter))
        XCTAssertFalse(gate.isUnresolved(otherAdapter))
        XCTAssertNoThrow(try gate.check("010C", peripheral: otherAdapter))
        assertRefused(gate, "010C")

        // A recovery on the other adapter doesn't help this one.
        gate.markUnresolved(otherAdapter)
        gate.noteAnswered("ATZ", lines: banner, peripheral: otherAdapter)
        XCTAssertEqual(gate.phase(of: adapter), .needsReset)
    }

    /// Nothing but a verified recovery opens it: no traffic that isn't the recovery, no failed
    /// recovery step, and re-marking starts over.
    func testSurvivesEverythingButAVerifiedRecovery() {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        gate.noteAnswered("ATI", lines: banner, peripheral: adapter)
        gate.noteAnswered("0100", lines: supportedPIDs, peripheral: adapter)
        gate.noteAnswered("ATE0", lines: ok, peripheral: adapter)
        XCTAssertEqual(gate.phase(of: adapter), .needsReset, "nothing before the reset counts")

        reinitialize(gate)
        gate.markUnresolved(adapter)
        XCTAssertEqual(gate.phase(of: adapter), .needsReset, "re-arming mid-recovery starts over")
    }

    // MARK: What passes

    func testRefusesEverythingThatCanReachTheBusExceptTheProbe() {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        for command in ["STPX d:0100", "ATSH 7DF", "AT SH 7DF", "ATSP6", "ATCRA 7E8", "010C", "22028D", "0902", "0100", "03"] {
            assertRefused(gate, command)
        }
        for command in ["ATZ", "atz", "AT Z", "ATI", "AT@1", "STI", "ATE0"] {
            assertAllowed(gate, command)
        }

        gate.noteAnswered("ATZ", lines: banner, peripheral: adapter)
        // Re-initializing: the recovery's own commands pass, nothing else does.
        for command in ["ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "ATSP6", "ATSPA", "ATDPN", "ATRV"] {
            assertAllowed(gate, command)
        }
        // The probe only once the re-initialization is acknowledged (finding h).
        for command in ["STPX d:0100", "ATSH 7DF", "ATSPD", "ATSP06", "010C", "22028D", "0902", "01 00 01", "0100"] {
            assertRefused(gate, command)
        }
        for command in ["ATE0", "ATL0", "ATS0", "ATH1", "ATSP0"] {
            gate.noteAnswered(command, lines: ok, peripheral: adapter)
        }
        assertAllowed(gate, "0100")
        for command in ["STPX d:0100", "ATSH 7DF", "010C", "01 00 01"] {
            assertRefused(gate, command)
        }
    }

    // MARK: The reset

    func testAResetThatDidNotResetDoesNotAdvance() {
        for answer in [["?"], ["STOPPED"], ["OK"], [], ["ATZ"], ["NO DATA"]] {
            let gate = OEMAddressingGate()
            gate.markUnresolved(adapter)
            gate.noteAnswered("ATZ", lines: answer, peripheral: adapter)
            XCTAssertEqual(gate.phase(of: adapter), .needsReset, "\(answer)")
            assertRefused(gate, "ATL0")
        }
    }

    func testBannerMovesToReinitializing() {
        for answer in [["ELM327 v1.5"], ["ATZ", "", "ELM327 v2.1"], ["elm327 v1.4b"]] {
            let gate = OEMAddressingGate()
            gate.markUnresolved(adapter)
            gate.noteAnswered("ATZ", lines: answer, peripheral: adapter)
            XCTAssertEqual(gate.phase(of: adapter), .reinitializing(acknowledged: []), "\(answer)")
        }
    }

    // MARK: Opening

    func testTheProbeAloneDoesNotOpenIt() {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        reinitialize(gate)
        // A physical-addressing echo of the probe is not a complete 41 00 answer.
        gate.noteAnswered("0100", lines: ["7E8024100"], peripheral: adapter)
        XCTAssertTrue(gate.isUnresolved(adapter))
        gate.noteAnswered("0100", lines: ["NO DATA"], peripheral: adapter)
        XCTAssertTrue(gate.isUnresolved(adapter))
    }

    func testAFullAnswerBeforeTheInitializationWasAcknowledgedDoesNotOpenIt() {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        gate.noteAnswered("ATZ", lines: banner, peripheral: adapter)
        gate.noteAnswered("ATE0", lines: ok, peripheral: adapter)
        gate.noteAnswered("ATL0", lines: ["?"], peripheral: adapter) // not acknowledged
        gate.noteAnswered("ATS0", lines: ok, peripheral: adapter)
        gate.noteAnswered("ATH1", lines: ok, peripheral: adapter)
        gate.noteAnswered("ATSP0", lines: ok, peripheral: adapter)
        gate.noteAnswered("0100", lines: supportedPIDs, peripheral: adapter)
        XCTAssertTrue(gate.isUnresolved(adapter))

        // No protocol selection acknowledged.
        let noProtocol = OEMAddressingGate()
        noProtocol.markUnresolved(adapter)
        noProtocol.noteAnswered("ATZ", lines: banner, peripheral: adapter)
        for command in ["ATE0", "ATL0", "ATS0", "ATH1"] {
            noProtocol.noteAnswered(command, lines: ok, peripheral: adapter)
        }
        noProtocol.noteAnswered("0100", lines: supportedPIDs, peripheral: adapter)
        XCTAssertTrue(noProtocol.isUnresolved(adapter))
    }

    func testTheCompleteSequenceOpensIt() {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        reinitialize(gate)
        gate.noteAnswered("0100", lines: ["SEARCHING...", "7E8064100BE3EB811", "7E9064100 88180010"], peripheral: adapter)
        XCTAssertFalse(gate.isUnresolved(adapter))
        for command in ["010C", "22028D", "0902", "ATSH 7E0"] {
            assertAllowed(gate, command)
        }
    }

    func testALaterResetWithoutABannerStartsOver() {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        reinitialize(gate)
        gate.noteAnswered("ATZ", lines: ["?"], peripheral: adapter)
        XCTAssertEqual(gate.phase(of: adapter), .needsReset)
        gate.noteAnswered("0100", lines: supportedPIDs, peripheral: adapter)
        XCTAssertTrue(gate.isUnresolved(adapter))
    }

    // MARK: The recovery the connection code really sends, through the transport

    /// Replays a reconnect to an unresolved adapter with the exact commands
    /// `validateInferredChannelIfNeeded`, `adapterInitialization()` and
    /// `detectProtocolAutomatically()` send, and the answers a real ELM327 gives (echo is back on
    /// after `ATZ`, so `ATE0` is answered `ATE0` / `OK`). The gate must open on the `0100`.
    func testARealReconnectSequenceCompletesTheRecovery() async throws {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        let processor = OBDMessageProcessor()
        let wire = FakeAdapterWire(processor: processor)
        let exchange = BLECommandExchange(processor: processor, gate: gate)
        let answers: [String: String] = [
            "ATI": "ELM327 v1.5\r\r>",
            "ATZ": "ATZ\r\r\rELM327 v1.5\r\r>",
            "ATE0": "ATE0\rOK\r\r>",
            "ATL0": "OK\r\r>", "ATS0": "OK\r\r>", "ATH1": "OK\r\r>", "ATSP0": "OK\r\r>",
            "0100": "SEARCHING...\r7E8064100BE3EB811\r\r>",
            "ATDPN": "A6\r\r>",
        ]
        wire.respond = { answers[$0] }

        // Channel validation (inferred binding), before the reset.
        for command in ["ATI", "ATE0"] {
            _ = try await exchange.send(command, retries: 1, responseTimeout: 1) { wire.target(adapter) }
        }
        XCTAssertEqual(gate.phase(of: adapter), .needsReset)
        // adapterInitialization()
        for command in ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0"] {
            _ = try await exchange.send(command, retries: 1, responseTimeout: 1) { wire.target(adapter) }
        }
        XCTAssertTrue(gate.isUnresolved(adapter))
        // detectProtocolAutomatically()
        _ = try await exchange.send("ATSP0", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        _ = try await exchange.send("0100", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertFalse(gate.isUnresolved(adapter), "the verified recovery must open the gate")
    }

    /// Before the fix the echoed `ATE0` never counted, so the gate could not open on a real
    /// adapter. Only an exact echo of the command is dropped.
    func testOnlyTheCommandsOwnEchoIsDroppedFromTheAnswer() {
        XCTAssertEqual(BLECommandExchange.answerLines(to: "ATE0", from: ["ATE0", "OK"]), ["OK"])
        XCTAssertEqual(BLECommandExchange.answerLines(to: "AT E0", from: ["ate0", "OK"]), ["OK"])
        XCTAssertEqual(BLECommandExchange.answerLines(to: "ATE0", from: ["OK"]), ["OK"])
        XCTAssertEqual(BLECommandExchange.answerLines(to: "ATL0", from: ["ATE0", "OK"]), ["ATE0", "OK"])
        XCTAssertEqual(BLECommandExchange.answerLines(to: "ATE0", from: ["OK", "ATE0"]), ["OK", "ATE0"])
    }

    /// The gate is consulted for the peripheral being written to, before anything is armed or
    /// written.
    func testTheTransportConsultsTheGateForTheTargetPeripheral() async throws {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        let processor = OBDMessageProcessor()
        let wire = FakeAdapterWire(processor: processor)
        wire.respond = { _ in "7E804410C1AF8\r>" }
        let exchange = BLECommandExchange(processor: processor, gate: gate)

        do {
            _ = try await exchange.send("010C", retries: 3, responseTimeout: 1) { wire.target(adapter) }
            XCTFail("refused")
        } catch {
            XCTAssertEqual(error as? OEMAddressingGateError, .addressingUnresolved)
        }
        XCTAssertEqual(wire.written, [], "nothing may be written")

        _ = try await exchange.send("010C", retries: 1, responseTimeout: 1) { wire.target(otherAdapter) }
        XCTAssertEqual(wire.written, ["010C"])
    }

    // MARK: Finding h: a fresh recovery phase per reset

    /// A reset that was written but never answered (or answered late) must not leave the
    /// acknowledgements of an earlier attempt standing: writing `ATZ` starts the recovery over,
    /// so a later `0100` can't open the gate on credit gathered before the reset.
    func testWritingAResetForgetsEveryEarlierAcknowledgement() async throws {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        reinitialize(gate)
        gate.noteAnswered("ATDPN", lines: ["A6"], peripheral: adapter)
        let processor = OBDMessageProcessor()
        let wire = FakeAdapterWire(processor: processor)
        let exchange = BLECommandExchange(processor: processor, gate: gate)
        wire.respond = { _ in nil } // the reset never answers

        do {
            _ = try await exchange.send("ATZ", retries: 1, responseTimeout: 0.2) { wire.target(adapter) }
            XCTFail("no answer")
        } catch {}
        XCTAssertEqual(wire.written, ["ATZ"])
        XCTAssertEqual(gate.phase(of: adapter), .needsReset, "the written reset starts a fresh phase")
        assertRefused(gate, "0100")
        assertRefused(gate, "ATL0")
    }

    /// The transport's hook, directly: only `ATZ` on an unresolved adapter does anything.
    func testNoteWillSendOnlyResetsAnUnresolvedAdapterOnATZ() {
        let gate = OEMAddressingGate()
        gate.noteWillSend("ATZ", peripheral: adapter)
        XCTAssertNil(gate.phase(of: adapter), "an adapter that isn't unresolved is untouched")

        gate.markUnresolved(adapter)
        reinitialize(gate)
        let reinitialized = gate.phase(of: adapter)
        for command in ["ATE0", "ATI", "ATRV", "ATDPN", "0100", "ATSP0"] {
            gate.noteWillSend(command, peripheral: adapter)
            XCTAssertEqual(gate.phase(of: adapter), reinitialized, command)
        }
        gate.noteWillSend("at z", peripheral: adapter)
        XCTAssertEqual(gate.phase(of: adapter), .needsReset)
        // Only the answer to that reset moves it forward, and only a banner.
        gate.noteAnswered("ATZ", lines: ["STOPPED"], peripheral: adapter)
        XCTAssertEqual(gate.phase(of: adapter), .needsReset)
        gate.noteWillSend("ATZ", peripheral: adapter)
        gate.noteAnswered("ATZ", lines: banner, peripheral: adapter)
        XCTAssertEqual(gate.phase(of: adapter), .reinitializing(acknowledged: []))
    }

    /// `0100` reaches the bus only once every re-initialization command has been acknowledged.
    func testTheProbeWaitsForEveryReinitializationAcknowledgement() {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        gate.noteAnswered("ATZ", lines: banner, peripheral: adapter)
        assertRefused(gate, "0100")
        for command in ["ATE0", "ATL0", "ATS0", "ATH1"] {
            gate.noteAnswered(command, lines: ok, peripheral: adapter)
            assertRefused(gate, "0100")
        }
        gate.noteAnswered("ATSP0", lines: ["?"], peripheral: adapter)
        assertRefused(gate, "0100")
        gate.noteAnswered("ATSP0", lines: ok, peripheral: adapter)
        assertAllowed(gate, "0100")
    }

    /// The resynchronization probes are adapter-only and run before a recovery `ATZ`, so they
    /// pass in every phase; their answers never advance the gate and leave no evidence behind.
    func testTheResynchronizationProbesPassInEveryPhase() {
        let gate = OEMAddressingGate()
        gate.markUnresolved(adapter)
        for command in ["ATRV", "ATDPN", "AT RV", "at dpn"] {
            assertAllowed(gate, command)
        }
        for command in ["STPX d:0100", "ATD", "ATSH 7E0", "ATSP6", "ATDP", "ATRV1", "0100"] {
            assertRefused(gate, command)
        }
        gate.noteAnswered("ATRV", lines: ["14.1V"], peripheral: adapter)
        gate.noteAnswered("ATDPN", lines: ["A7"], peripheral: adapter)
        XCTAssertEqual(gate.phase(of: adapter), .needsReset)
        gate.noteAnswered("ATZ", lines: banner, peripheral: adapter)
        XCTAssertEqual(gate.phase(of: adapter), .reinitializing(acknowledged: []), "nothing from before the reset")
    }

    // MARK: Finding h: the probe the detected protocol produces

    private let can29PIDs = ["18DAF110064100BE3FA813"]
    private let kLinePIDs = ["486B104100BE3FA81311"]

    /// Walks `steps` through the gate as the transport would: check, the pre-write hook, then
    /// the answer. Every command must be allowed (no flow may deadlock behind the gate).
    private func walk(_ gate: OEMAddressingGate, _ steps: [(String, [String])], file: StaticString = #filePath, line: UInt = #line) {
        for (command, answer) in steps {
            XCTAssertNoThrow(try gate.check(command, peripheral: adapter), "\(command) refused", file: file, line: line)
            gate.noteWillSend(command, peripheral: adapter)
            gate.noteAnswered(command, lines: answer, peripheral: adapter)
        }
    }

    /// `adapterInitialization()`: ATZ, ATE0, ATL0, ATS0, ATH1, ATSP0.
    private var initialization: [(String, [String])] {
        [("ATZ", banner), ("ATE0", ok), ("ATL0", ok), ("ATS0", ok), ("ATH1", ok), ("ATSP0", ok)]
    }

    /// `detectProtocolAutomatically()` then `testProtocol`: ATSP0, 0100, ATDPN, 0100.
    func testAutomaticDetectionOpensOnEveryProtocolFamily() {
        let cases: [(String, [String], String)] = [
            ("11-bit CAN", supportedPIDs, "A6"),
            ("29-bit CAN", can29PIDs, "A7"),
            ("ISO 9141-2", ["SEARCHING..."] + kLinePIDs, "A3"),
        ]
        for (name, answer, dpn) in cases {
            let gate = OEMAddressingGate()
            gate.markUnresolved(adapter)
            walk(gate, initialization + [("ATSP0", ok), ("0100", answer), ("ATDPN", [dpn]), ("0100", answer)])
            XCTAssertFalse(gate.isUnresolved(adapter), name)
        }
    }

    /// `detectProtocolManually()` after the automatic search failed: ATSPn and `0100` per
    /// protocol, in `PROTOCOL.allCases` order, until one answers.
    func testManualDetectionOpensOnTheProtocolThatAnswers() {
        let failedAutomatic: [(String, [String])] = [
            ("ATSP0", ok), ("0100", ["SEARCHING...", "UNABLE TO CONNECT"]), ("ATDPN", ["A0"]),
        ]
        let cases: [(String, Int, [String])] = [
            ("ISO 9141-2 on ATSP3", 3, kLinePIDs),
            ("11-bit CAN on ATSP6", 6, supportedPIDs),
            ("29-bit CAN on ATSP7", 7, can29PIDs),
        ]
        for (name, answering, answer) in cases {
            let gate = OEMAddressingGate()
            gate.markUnresolved(adapter)
            var steps = initialization + failedAutomatic
            for number in 1..<answering {
                steps += [("ATSP\(number)", ok), ("0100", ["NO DATA"])]
            }
            steps += [("ATSP\(answering)", ok), ("0100", answer)]
            walk(gate, steps)
            XCTAssertFalse(gate.isUnresolved(adapter), name)
        }
    }

    /// The preferred-protocol path: `testProtocol` straight after initialization, no `ATSPn`.
    func testPreferredProtocolPathOpensWithoutProtocolSelection() {
        for (name, answer) in [("11-bit CAN", supportedPIDs), ("29-bit CAN", can29PIDs), ("J1850 VPW", kLinePIDs)] {
            let gate = OEMAddressingGate()
            gate.markUnresolved(adapter)
            walk(gate, initialization + [("0100", answer)])
            XCTAssertFalse(gate.isUnresolved(adapter), name)
        }
    }

    /// With protocol evidence, only the matching answer shape opens the gate.
    func testTheProbeMustMatchTheDetectedProtocol() {
        let shapes: [String: [String]] = ["11": supportedPIDs, "29": can29PIDs, "legacy": kLinePIDs]
        // (how the evidence arrives, the shape it admits; nil admits none)
        let cases: [([(String, [String])], String?)] = [
            ([("ATDPN", ["A6"])], "11"), ([("ATDPN", ["8"])], "11"),
            ([("ATDPN", ["A7"])], "29"), ([("ATDPN", ["9"])], "29"),
            ([("ATDPN", ["A1"])], "legacy"), ([("ATDPN", ["5"])], "legacy"),
            ([("ATSP6", ok)], "11"), ([("ATSP9", ok)], "29"), ([("ATSP2", ok)], "legacy"), ([("ATSP4", ok)], "legacy"),
            ([("ATDPN", ["A"])], nil), ([("ATDPN", ["AA"])], nil), ([("ATSPA", ok)], nil),
            ([("ATSPB", ok)], nil), ([("ATDPN", ["AC"])], nil),
        ]
        for (evidence, admitted) in cases {
            for (shape, answer) in shapes {
                let gate = OEMAddressingGate()
                gate.markUnresolved(adapter)
                walk(gate, initialization + evidence + [("0100", answer)])
                XCTAssertEqual(!gate.isUnresolved(adapter), shape == admitted, "\(evidence) answered \(shape)")
            }
        }
    }

    /// The latest evidence wins: a protocol selected after an `ATDPN` makes that answer stale,
    /// `ATSP0` returns to automatic search (no evidence), and a reset forgets it all.
    func testTheLatestProtocolEvidenceWins() {
        let staleDPN = OEMAddressingGate()
        staleDPN.markUnresolved(adapter)
        walk(staleDPN, initialization + [("ATDPN", ["A6"]), ("ATSP3", ok), ("0100", supportedPIDs)])
        XCTAssertTrue(staleDPN.isUnresolved(adapter), "ATSP3 replaced the 11-bit evidence")
        walk(staleDPN, [("0100", kLinePIDs)])
        XCTAssertFalse(staleDPN.isUnresolved(adapter))

        let backToAutomatic = OEMAddressingGate()
        backToAutomatic.markUnresolved(adapter)
        walk(backToAutomatic, initialization + [("ATSP7", ok), ("ATSP0", ok), ("0100", supportedPIDs)])
        XCTAssertFalse(backToAutomatic.isUnresolved(adapter))

        let afterReset = OEMAddressingGate()
        afterReset.markUnresolved(adapter)
        walk(afterReset, initialization + [("ATDPN", ["A7"]), ("ATZ", banner)])
        XCTAssertEqual(afterReset.phase(of: adapter), .reinitializing(acknowledged: []), "a reset forgets the evidence")
    }

    /// Each shape is as strict as the 11-bit one: exact header family, a single frame of
    /// exactly `41 00` and four bitmap bytes (plus the checksum on the legacy buses).
    func testIncompleteAnswersOfTheOtherShapesDoNotOpenIt() {
        let refused: [(String, [String])] = [
            ("29-bit short", ["18DAF110024100"]),
            ("29-bit truncated bitmap", ["18DAF110064100BE3F"]),
            ("29-bit declares five", ["18DAF110054100BE3FA8"]),
            ("29-bit request id", ["18DB33F1064100BE3FA813"]),
            ("29-bit physical request", ["18DA10F1064100BE3FA813"]),
            ("29-bit negative", ["18DAF110037F0112"]),
            ("29-bit first frame", ["18DAF1101008410000000000"]),
            ("29-bit wrong PID", ["18DAF110064120BE3FA813"]),
            ("29-bit over-long", ["18DAF110064100BE3FA81300AA"]),
            ("legacy no checksum", ["486B104100BE3FA813"]),
            ("legacy short", ["486B104100FF"]),
            ("legacy wrong PID", ["486B104120BE3FA81311"]),
            ("legacy over-long", ["486B104100BE3FA8131100"]),
            ("legacy negative", ["486B107F0112AA"]),
            ("legacy non-hex", ["486B104100BE3FA813ZZ"]),
        ]
        for (name, answer) in refused {
            let gate = OEMAddressingGate()
            gate.markUnresolved(adapter)
            walk(gate, initialization + [("0100", answer)])
            XCTAssertTrue(gate.isUnresolved(adapter), name)
        }
        // The single-argument judge keeps its 11-bit meaning (the restore verification).
        XCTAssertFalse(OEMReply.isPositiveSupportedPIDsAnswer(can29PIDs))
        XCTAssertFalse(OEMReply.isPositiveSupportedPIDsAnswer(kLinePIDs))
    }

    // MARK: Transports and entry point

    func testTransportsWithoutAnExclusiveChannelFailClosed() async {
        let comm = MOCKComm()
        do {
            _ = try await comm.withExclusiveCommandChannel(deadline: ProcessInfo.processInfo.systemUptime + 5) { _ in 0 }
            XCTFail("the demo transport must not run manufacturer batches")
        } catch {
            XCTAssertEqual(error as? OEMTransportError, .unsupportedTransport)
        }
    }

    func testEntryPointRefusesWhenNotConnected() async throws {
        let service = OBDService(connectionType: .demo)
        let result = await service.readManufacturerData(try OEMTestCatalog.batch("test-vw", ["E.028D", "E.1002"]))
        XCTAssertEqual(result.failure, .notConnected)
        XCTAssertEqual(result.reads.map(\.outcome), [.notAttempted(.batchNotStarted), .notAttempted(.batchNotStarted)])
        XCTAssertEqual(result.adapterState, .functional)
    }
}
