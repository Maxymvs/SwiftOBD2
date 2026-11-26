//
//  WifiTransactionTests.swift
//
//  The WiFi transport's receive pump and its exclusive send+listen transaction, exercised through
//  the socket seam — `NWConnection` cannot be unit-tested, so `WifiSocket` is what the manager
//  talks to and a fake stands in for the wire.
//
//  The fake is deliberately **non-cooperative**: it never checks cancellation and never times a
//  read out on its own, exactly like the real Network callback. A read resolves only when the test
//  says so. Every timeout and cancellation below therefore has to be delivered by the
//  architecture — the pump owns the only read, and callers wait on a request slot — rather than
//  by a courteous fake.
//

import Foundation
@testable import SwiftOBD2
import XCTest

final class WifiTransactionTests: XCTestCase {
    private func makeManager(_ socket: FakeWifiSocket, readTimeout: TimeInterval = 0.4) -> WifiManager {
        let manager = WifiManager()
        manager.readTimeout = readTimeout
        manager.listenWindowTimeout = readTimeout
        manager.resynchronization = OBDStreamResynchronizer.Timing(quietWindow: 0.02, maximumDrain: 0.2, probeWindow: 0.5)
        manager.attach(socket: socket)
        manager.connectionState = .connectedToVehicle
        return manager
    }

    /// Keeps listening while any line is a `7F … 78`, exactly as the DTC layer's predicate does.
    private let awaitsPending: @Sendable ([String]) -> Bool = { lines in
        DTCResponseParser.awaitsPendingResponse(lines: lines, service: .stored, family: .can11)
    }

    // MARK: - No hang on a socket that never answers

    /// (a) The fake never resolves the read. With a caller-owned `NWConnection.receive` this hung
    /// forever behind the nominal timeout; the pump architecture bounds it at the *wait*.
    func testACallerTimesOutEvenThoughTheReadNeverResolves() async {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 0.3)

        let started = Date()
        do {
            _ = try await manager.sendCommand("03", retries: 1)
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertTrue(
                { if case CommunicationError.timeout = error { return true } else { return false } }(),
                "Expected .timeout, got \(error)"
            )
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2.0,
            "The wait must be bounded by the timeout, not by the socket"
        )
        XCTAssertEqual(socket.armedReceives, 1, "Exactly one outstanding read, owned by the pump")
    }

    /// (b) The abandoned request's late bytes must not become the next command's answer. They
    /// arrive with no slot armed and are discarded; the next command is written only after a
    /// probe has proven the stream.
    func testLateBytesFromATimedOutRequestAreNotTheNextCommandsResponse() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 0.3)

        do {
            _ = try await manager.sendCommand("03", retries: 1)
            XCTFail("Expected a timeout")
        } catch { /* expected */ }

        // The vehicle finally answers the abandoned request — with no slot armed.
        try await socket.deliverWhenArmed("7E8 04 43 01 01 04\r>")

        let lines = try await manager.performAfterResynchronizing(
            "0100", on: socket, answering: "7E8 06 41 00 BE 3F A8 13\r>"
        )

        XCTAssertEqual(
            lines,
            ["7E8 06 41 00 BE 3F A8 13"],
            "The stale response must never be served as this command's answer"
        )
        XCTAssertEqual(socket.sentCommands, ["03", "ATRV", "0100"])
    }

    /// The same late bytes, arriving only after the next command was issued (review finding
    /// P1-a). `010C` times out; its reply used to land in the armed `010D` slot and be shown as
    /// the speed.
    func testLateBytesArrivingAfterTheNextCommandIsIssuedAreNotItsResponse() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 0.3)

        do {
            _ = try await manager.sendCommand("010C", retries: 1)
            XCTFail("Expected a timeout")
        } catch { /* expected */ }

        async let speed = manager.sendCommand("010D", retries: 1)
        // Nothing but a probe goes out first, and the late reply arrives ahead of its answer.
        try await socket.waitForSend("ATRV")
        try await socket.deliverWhenArmed("7E8 04 41 0C 1F 40\r>")
        try await socket.deliverWhenArmed("12.4V\r\r>")
        try await socket.waitForSend("010D")
        try await socket.deliverWhenArmed("7E8 03 41 0D 20\r>")

        let lines = try await speed
        XCTAssertEqual(lines, ["7E8 03 41 0D 20"], "010D gets its own reply, not the late 010C one")
    }

    /// With no probe answered the next command is not written at all. Neither probe can prove
    /// anything after that, so the socket is retired (see `testWithNoUsableProbeTheSocketIsRetired`).
    func testNothingIsWrittenWhileTheStreamCannotBeProven() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 0.2)
        manager.resynchronization.probeWindow = 0.1

        _ = try? await manager.sendCommand("010C", retries: 1)
        do {
            _ = try await manager.sendCommand("010D", retries: 1)
            XCTFail("Expected link loss")
        } catch {
            XCTAssertTrue(
                { if case CommunicationError.connectionLost = error { return true } else { return false } }(),
                "Expected .connectionLost, got \(error)"
            )
        }
        XCTAssertEqual(socket.sentCommands, ["010C", "ATRV", "ATDPN"])
    }

    // MARK: - Serialization

    /// A transaction owns the transport for its whole exchange: an ordinary command issued while a
    /// listen window is open must wait, or it would write into the middle of the exchange.
    func testAnOrdinaryCommandCannotInterleaveATransaction() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 2.0)

        let transaction = Task {
            try await manager.sendCommandTransaction(
                "03",
                retries: 1,
                shouldContinueListening: self.awaitsPending,
                listenDeadline: 5
            )
        }
        try await socket.waitForSend("03")
        try await socket.deliverWhenArmed("7E8 03 7F 03 78\r>") // pending: a listen window opens

        let interleaved = Task { try await manager.sendCommand("0100", retries: 1) }
        for _ in 0 ..< 200 { await Task.yield() }
        XCTAssertEqual(socket.sentCommands, ["03"], "The second command must not reach the socket yet")

        try await socket.deliverWhenArmed("7E8 04 43 01 01 04\r>") // the final message ends it
        let dtcLines = try await transaction.value

        try await socket.waitForSend("0100")
        try await socket.deliverWhenArmed("7E8 06 41 00 BE 3F A8 13\r>")
        let pidLines = try await interleaved.value

        XCTAssertEqual(dtcLines, ["7E8 03 7F 03 78", "7E8 04 43 01 01 04"])
        XCTAssertEqual(pidLines, ["7E8 06 41 00 BE 3F A8 13"])
        XCTAssertEqual(socket.sentCommands, ["03", "0100"])
    }

    // MARK: - Timeout vs. failure

    /// An empty window is not a failure: the transaction ends with what it has, so the DTC layer
    /// keeps the recorded `0x78` as its evidence — and never retransmits.
    func testAnEmptyListenWindowEndsTheTransactionQuietly() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 0.3)

        let transaction = Task {
            try await manager.sendCommandTransaction(
                "03",
                retries: 1,
                shouldContinueListening: self.awaitsPending,
                listenDeadline: 1
            )
        }
        try await socket.waitForSend("03")
        try await socket.deliverWhenArmed("7E8 03 7F 03 78\r>")

        let lines = try await transaction.value
        XCTAssertEqual(lines, ["7E8 03 7F 03 78"])
        XCTAssertEqual(socket.sentCommands, ["03"], "A pending response is never retransmitted")
    }

    /// (d) The pump hitting a socket error fails the pending slot terminally and drops the socket,
    /// instead of leaving the caller to wait out a timeout on a dead connection.
    func testPumpFailureFailsThePendingRequestAndClearsTheSocket() async {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 5.0)

        let request = Task { try await manager.sendCommand("03", retries: 1) }
        do {
            try await socket.waitForSend("03")
            try await socket.failReadWhenArmed()

            _ = try await request.value
            XCTFail("A dead socket must not read as a quiet vehicle")
        } catch {
            XCTAssertTrue(
                { if case CommunicationError.connectionLost = error { return true } else { return false } }(),
                "Expected .connectionLost, got \(error)"
            )
        }

        XCTAssertNil(manager.socket, "A failed socket is dropped so the terminal guard stays armed")
        XCTAssertEqual(manager.connectionState, .disconnected)
    }

    /// A socket failure during a *listen window* is terminal in the same way.
    func testSocketFailureDuringAWindowThrowsConnectionLost() async {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 2.0)

        let transaction = Task {
            try await manager.sendCommandTransaction(
                "03",
                retries: 1,
                shouldContinueListening: self.awaitsPending,
                listenDeadline: 5
            )
        }
        do {
            try await socket.waitForSend("03")
            try await socket.deliverWhenArmed("7E8 03 7F 03 78\r>")
            // Whatever the transaction has reached by now — still consuming the interim, between
            // windows, or suspended in one — a dead socket must surface as link loss.
            try await socket.failReadWhenArmed()

            _ = try await transaction.value
            XCTFail("Expected link loss")
        } catch {
            XCTAssertTrue(
                { if case CommunicationError.connectionLost = error { return true } else { return false } }(),
                "Expected .connectionLost, got \(error)"
            )
        }
        XCTAssertNil(manager.socket)
    }

    /// And the DTC layer maps those errors the way D16 requires.
    func testCommunicationErrorsMapToTheRightDispositions() {
        XCTAssertEqual(
            DTCTransportDisposition(error: CommunicationError.connectionLost, linkIsUp: true),
            .connectionLost
        )
        XCTAssertEqual(
            DTCTransportDisposition(error: CommunicationError.timeout, linkIsUp: true),
            .transportFailure(.requestTimeout)
        )
    }

    /// A failed *write* is terminal too — retrying a dead socket is pointless.
    func testAFailedWriteIsTerminal() async {
        let socket = FakeWifiSocket()
        socket.failSends = true
        let manager = makeManager(socket)

        do {
            _ = try await manager.sendCommand("03", retries: 3)
            XCTFail("Expected link loss")
        } catch {
            XCTAssertTrue(
                { if case CommunicationError.connectionLost = error { return true } else { return false } }(),
                "Expected .connectionLost, got \(error)"
            )
        }
        XCTAssertEqual(socket.sentCommands.count, 1, "A dead socket is not retried")
        XCTAssertNil(manager.socket)
    }

    // MARK: - Disconnect

    /// Cancelling the connection used to leave the reference in place, so the terminal guard never
    /// fired and the published state stayed stale.
    func testDisconnectCancelsTheSocketAndArmsTheTerminalGuard() async {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket)

        manager.disconnectPeripheral()

        XCTAssertTrue(socket.wasCancelled)
        XCTAssertNil(manager.socket)
        XCTAssertEqual(manager.connectionState, .disconnected)

        do {
            _ = try await manager.sendCommand("03", retries: 1)
            XCTFail("A disconnected transport must refuse to send")
        } catch {
            XCTAssertTrue(
                { if case CommunicationError.connectionLost = error { return true } else { return false } }(),
                "Expected .connectionLost, got \(error)"
            )
        }
    }

    // MARK: - Cancellation

    /// (c) Cancellation mid-wait propagates promptly — and the pump is still healthy afterwards,
    /// because nothing was abandoned on the socket.
    func testCancellationMidWaitPropagatesAndLeavesThePumpHealthy() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 5.0)

        let request = Task { try await manager.sendCommand("03", retries: 1) }
        try await socket.waitForSend("03")
        let started = Date()
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Expected cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "Cancellation must not wait out the timeout")

        // The pump kept running: the next command works, once a probe has proven that the
        // cancelled command's answer isn't still on its way.
        let lines = try await manager.performAfterResynchronizing(
            "0100", on: socket, answering: "7E8 06 41 00 BE 3F A8 13\r>"
        )
        XCTAssertEqual(lines, ["7E8 06 41 00 BE 3F A8 13"])
        XCTAssertNotNil(manager.socket)
    }

    // MARK: - Framing across transport boundaries

    /// End to end through the pump: one socket callback carries the interim `7F … 78`, its prompt,
    /// **and** the first bytes of the real answer, with the rest arriving later. The buffer used to
    /// swallow that prefix, so the codes could never be reconstructed; the scan must now resolve
    /// `.responded` with them.
    func testAPumpCallbackCarryingAPartialFinalMessageStillResolvesTheScan() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 2.0)
        let elm = ELM327(comm: manager)
        elm.canProtocol = ISO_15765_4_11bit_500k()
        elm.connectionState = .connectedToVehicle

        let scan = Task { try await elm.scanForTroubleCodes(profile: .storedOnly) }

        try await socket.waitForSend("0101")
        try await socket.deliverWhenArmed("7E8 06 41 01 00 07 E1 00\r>")
        try await socket.waitForSend("03")
        // The response-pending, its prompt, and the beginning of the final message — one callback.
        try await socket.deliverWhenArmed("7E8 03 7F 03 78\r>\r7E8 04 43 01")
        // The remainder lands while the transaction is listening.
        try await socket.deliverWhenArmed(" 01 04\r\r>")

        let report = try await scan.value

        XCTAssertEqual(socket.sentCommands, ["0101", "03"], "The pending response is never retransmitted")
        XCTAssertEqual(report.observations.map(\.code), ["P0104"], "The final message must survive the split")
        let stored = try XCTUnwrap(report.services[.stored])
        guard case let .answered(responders) = stored,
              case let .responded(codes) = try XCTUnwrap(responders[ECUAddress(raw: 0x7E8)])
        else { return XCTFail("Expected the engine to have responded") }
        XCTAssertEqual(codes.map(\.code), ["P0104"])
    }

    /// A scan cancelled inside a WiFi listen window surfaces as the typed D16 interruption rather
    /// than a published report.
    func testCancellationInsideAWindowReachesTheScanAsCancelled() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 5.0)
        let elm = ELM327(comm: manager)
        elm.canProtocol = ISO_15765_4_11bit_500k()
        elm.connectionState = .connectedToVehicle

        let scan = Task { try await elm.scanForTroubleCodes(profile: .storedOnly) }
        try await socket.waitForSend("0101")
        try await socket.deliverWhenArmed("7E8 06 41 01 00 07 E1 00\r>")
        try await socket.waitForSend("03")
        try await socket.deliverWhenArmed("7E8 03 7F 03 78\r>") // the scan opens a listen window
        for _ in 0 ..< 50 { await Task.yield() }
        scan.cancel()

        do {
            _ = try await scan.value
            XCTFail("Expected .cancelled instead of a published report")
        } catch let error as DTCScanError {
            guard case let .cancelled(partial) = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
            XCTAssertTrue(partial.services.isEmpty, "Mode 03 never resolved")
        } catch {
            XCTFail("Expected DTCScanError, got \(error)")
        }
    }
}

// MARK: - Stream ownership round 2

extension WifiTransactionTests {
    private static let ownAnswer = "7E8 06 41 00 BE 3F A8 13"

    private func isCommunicationError(_ error: Error, _ expected: CommunicationError) -> Bool {
        switch (error as? CommunicationError, expected) {
        case (.connectionLost?, .connectionLost), (.timeout?, .timeout), (.invalidData?, .invalidData),
             (.noData?, .noData):
            return true
        default:
            return false
        }
    }

    /// Leaves the stream dirty the ordinary way: a command that never gets its prompt.
    private func timeOut(_ command: String, on manager: WifiManager) async {
        _ = try? await manager.sendCommand(command, retries: 1)
        XCTAssertTrue(manager.isStreamDirty)
    }

    /// The final answer a transaction stopped waiting for arrives right after the next command's
    /// first write. That command must have been preceded by a probe and get its own answer.
    private func assertLateAnswerIsNotCreditedToTheNextCommand(
        _ late: String,
        manager: WifiManager,
        socket: FakeWifiSocket,
        writtenBefore: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let next = Task { try await manager.sendCommand("0100", retries: 1) }
        try await socket.waitForSendCount(writtenBefore.count + 1)
        try await socket.deliverWhenArmed(late)
        if socket.sentCommands.last == "ATRV" {
            try await socket.deliverWhenArmed("12.4V\r\r>")
        }
        try await socket.waitForSend("0100")
        try await socket.deliverWhenArmed(Self.ownAnswer + "\r>")
        let lines = try await next.value
        XCTAssertEqual(lines, [Self.ownAnswer], "the late answer was credited to the next command", file: file, line: line)
        XCTAssertEqual(socket.sentCommands, writtenBefore + ["ATRV", "0100"], "proven before the next write", file: file, line: line)
    }

    private var moduleReadOwed: @Sendable ([String]) -> Bool {
        { lines in
            let compact = lines.map { $0.replacingOccurrences(of: " ", with: "").uppercased() }
            let pending = compact.contains { $0.hasPrefix("7E8") && $0.contains("7F1978") }
            let final = compact.contains { $0.hasPrefix("7E8") && $0.contains("5902") }
            return pending && !final
        }
    }

    // MARK: Item 1: authorized at the write

    func testALinkInvalidatedDuringTheProofStopsTheClearBeforeItsWrite() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 0.3)
        await timeOut("010C", on: manager)

        let linkIsCurrent = LockedFlag(true)
        socket.onSend = { if $0 == "ATRV" { linkIsCurrent.value = false } }
        let clear = Task {
            try await manager.sendCommand("04", retries: 1, beforeEachWrite: {
                guard linkIsCurrent.value else { throw OBDVehicleLinkError.linkChanged }
            })
        }
        try await socket.waitForSend("ATRV")
        try await socket.deliverWhenArmed("12.4V\r\r>")
        do {
            _ = try await clear.value
            XCTFail("expected the link check to stop the clear")
        } catch {
            XCTAssertEqual(error as? OBDVehicleLinkError, .linkChanged, "\(error)")
        }
        XCTAssertEqual(socket.sentCommands, ["010C", "ATRV"], "04 was never sent")
        XCTAssertFalse(manager.isStreamDirty, "nothing was written for the clear")

        socket.onSend = nil
        let lines = try await manager.perform("0100", on: socket, answering: Self.ownAnswer + "\r>")
        XCTAssertEqual(lines, [Self.ownAnswer])
        XCTAssertEqual(socket.sentCommands, ["010C", "ATRV", "0100"], "written directly, no probe")
    }

    // MARK: Item 2: a transaction that still owes its final answer leaves the stream dirty

    /// a. `7F 03 78`, then `NO DATA` in the listen window.
    func testNoDataInAListenWindowLeavesTheStreamDirty() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 1.0)
        let transaction = Task {
            try await manager.sendCommandTransaction(
                "03", retries: 1, shouldContinueListening: self.awaitsPending, listenDeadline: 3
            )
        }
        try await socket.waitForSend("03")
        try await socket.deliverWhenArmed("7E8 03 7F 03 78\r>")
        try await socket.deliverWhenArmed("NO DATA\r\r>")
        let lines = try await transaction.value
        XCTAssertEqual(lines, ["7E8 03 7F 03 78"])
        XCTAssertTrue(manager.isStreamDirty)

        try await assertLateAnswerIsNotCreditedToTheNextCommand(
            "7E8 04 43 01 01 04\r>", manager: manager, socket: socket, writtenBefore: ["03"]
        )
    }

    /// b. Cancelled between windows while the final answer is still owed.
    func testCancellationBetweenWindowsLeavesTheStreamDirty() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 1.0)
        let awaitsPending = self.awaitsPending
        let transaction = Task {
            try await manager.sendCommandTransaction(
                "03", retries: 1,
                shouldContinueListening: { lines in
                    // Called on the transaction's own task, right before the next window.
                    withUnsafeCurrentTask { $0?.cancel() }
                    return awaitsPending(lines)
                },
                listenDeadline: 3
            )
        }
        try await socket.waitForSend("03")
        try await socket.deliverWhenArmed("7E8 03 7F 03 78\r>")
        do {
            _ = try await transaction.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(manager.isStreamDirty)

        try await assertLateAnswerIsNotCreditedToTheNextCommand(
            "7E8 04 43 01 01 04\r>", manager: manager, socket: socket, writtenBefore: ["03"]
        )
    }

    /// c. The listen budget is spent while the answer is still owed.
    func testAnExhaustedBudgetLeavesTheStreamDirty() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 1.0)
        let transaction = Task {
            try await manager.sendCommandTransaction(
                "03", retries: 1, shouldContinueListening: self.awaitsPending, listenDeadline: 0
            )
        }
        try await socket.waitForSend("03")
        try await socket.deliverWhenArmed("7E8 03 7F 03 78\r>")
        let lines = try await transaction.value
        XCTAssertEqual(lines, ["7E8 03 7F 03 78"])
        XCTAssertTrue(manager.isStreamDirty)

        try await assertLateAnswerIsNotCreditedToTheNextCommand(
            "7E8 04 43 01 01 04\r>", manager: manager, socket: socket, writtenBefore: ["03"]
        )
    }

    /// d(i). The module scan's early prompt: the `59 02` list in the next window is returned.
    func testAModuleReadsFinalListInTheNextWindowIsReturned() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 1.0)
        let transaction = Task {
            try await manager.sendCommandTransaction(
                "1902FF", retries: 1, shouldContinueListening: self.moduleReadOwed, listenDeadline: 3
            )
        }
        try await socket.waitForSend("1902FF")
        try await socket.deliverWhenArmed("7E8 03 7F 19 78\r>")
        try await socket.deliverWhenArmed("7E8 06 59 02 FF 01 23 45\r>")
        let lines = try await transaction.value
        XCTAssertEqual(lines, ["7E8 03 7F 19 78", "7E8 06 59 02 FF 01 23 45"])
        XCTAssertFalse(manager.isStreamDirty)
    }

    /// d(ii). The same list arriving after the budget ran out is not the next command's.
    func testAModuleReadsListAfterTheBudgetIsNotTheNextCommandsAnswer() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 1.0)
        let transaction = Task {
            try await manager.sendCommandTransaction(
                "1902FF", retries: 1, shouldContinueListening: self.moduleReadOwed, listenDeadline: 0
            )
        }
        try await socket.waitForSend("1902FF")
        try await socket.deliverWhenArmed("7E8 03 7F 19 78\r>")
        let lines = try await transaction.value
        XCTAssertEqual(lines, ["7E8 03 7F 19 78"])
        XCTAssertTrue(manager.isStreamDirty)

        try await assertLateAnswerIsNotCreditedToTheNextCommand(
            "7E8 06 59 02 FF 01 23 45\r>", manager: manager, socket: socket, writtenBefore: ["1902FF"]
        )
    }

    /// A concluded transaction stays cheap: clean stream, no probe before the next command.
    func testAConcludedTransactionLeavesTheStreamCleanAndTheNextCommandUnprobed() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 1.0)
        let transaction = Task {
            try await manager.sendCommandTransaction(
                "03", retries: 1, shouldContinueListening: self.awaitsPending, listenDeadline: 3
            )
        }
        try await socket.waitForSend("03")
        try await socket.deliverWhenArmed("7E8 03 7F 03 78\r>")
        try await socket.deliverWhenArmed("7E8 04 43 01 01 04\r>")
        let lines = try await transaction.value
        XCTAssertEqual(lines, ["7E8 03 7F 03 78", "7E8 04 43 01 01 04"])
        XCTAssertFalse(manager.isStreamDirty)

        let next = try await manager.perform("0100", on: socket, answering: Self.ownAnswer + "\r>")
        XCTAssertEqual(next, [Self.ownAnswer])
        XCTAssertEqual(socket.sentCommands, ["03", "0100"])
    }

    // MARK: Item 3b: no usable probe

    /// Both probes went out and neither was answered: on WiFi the way to a new stream is a new
    /// socket, so this one is retired and the caller sees link loss.
    func testWithNoUsableProbeTheSocketIsRetired() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 0.2)
        manager.resynchronization.probeWindow = 0.1
        await timeOut("010C", on: manager)

        do {
            _ = try await manager.sendCommand("010D", retries: 3)
            XCTFail("expected link loss")
        } catch {
            XCTAssertTrue(isCommunicationError(error, .connectionLost), "\(error)")
        }
        XCTAssertEqual(socket.sentCommands, ["010C", "ATRV", "ATDPN"], "010D was never written")
        XCTAssertTrue(socket.wasCancelled)
        XCTAssertNil(manager.socket)
        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertFalse(manager.requiresReconnect, "the reconnect path on WiFi is the disconnect")
    }

    /// A stream that is merely unproven (one probe still usable) keeps its socket.
    func testAnUnprovenStreamKeepsItsSocket() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 0.2)
        manager.resynchronization.probeWindow = 0.1
        await timeOut("010C", on: manager)

        // ATRV's answer is followed by more bytes: answered (so not quarantined), not a proof.
        socket.onSend = { command in
            if command == "ATRV" {
                Task.detached { try? await socket.deliverWhenArmed("12.4V\r\r>7E8") }
            }
        }
        do {
            _ = try await manager.sendCommand("010D", retries: 1)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(isCommunicationError(error, .timeout), "\(error)")
        }
        XCTAssertNotNil(manager.socket)
        XCTAssertFalse(socket.wasCancelled)
    }

    // MARK: Item 5a: the shared encoder

    func testABlankOrMultiLineCommandIsRejectedUnwritten() async {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 0.2)
        for command in ["", "   ", "0100\r0902"] {
            do {
                _ = try await manager.sendCommand(command, retries: 1)
                XCTFail("expected \(command.debugDescription) to be rejected")
            } catch {
                XCTAssertTrue(isCommunicationError(error, .invalidData), "\(command.debugDescription): \(error)")
            }
        }
        XCTAssertEqual(socket.bytesSent, 0, "the socket saw nothing")
        XCTAssertFalse(manager.isStreamDirty)
        XCTAssertNotNil(manager.socket)
    }

    // MARK: Item 5b: the write deadline

    /// A write the socket never reports processed: past its deadline, whether it went out is
    /// unknown, so the socket is retired and the caller sees link loss, unretried.
    func testAStalledWritePastItsDeadlineRetiresTheSocket() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 2.0)
        manager.writeTimeout = 0.2
        socket.stallSends = true
        let unstuck = LockedFlag(false)
        let watchdog = Task.detached {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            unstuck.value = true
            socket.cancel()
        }
        defer { watchdog.cancel() }

        let started = Date()
        do {
            _ = try await manager.sendCommand("0100", retries: 3)
            XCTFail("expected link loss")
        } catch {
            XCTAssertTrue(isCommunicationError(error, .connectionLost), "\(error)")
        }
        XCTAssertFalse(unstuck.value, "the transport, not the watchdog, ended the write")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(socket.sentCommands, ["0100"], "not retried")
        XCTAssertTrue(socket.wasCancelled)
        XCTAssertNil(manager.socket)
        XCTAssertEqual(manager.connectionState, .disconnected)

        let failFast = Date()
        do {
            _ = try await manager.sendCommand("010D", retries: 1)
            XCTFail("expected link loss")
        } catch {
            XCTAssertTrue(isCommunicationError(error, .connectionLost), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(failFast), 0.1)
    }

    /// A probe's write is bounded by the deadline the resynchronizer hands it.
    func testAStalledProbeWriteRetiresTheSocket() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 0.2)
        manager.resynchronization.probeWindow = 0.2
        await timeOut("010C", on: manager)
        socket.stallSends = true
        let watchdog = Task.detached {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            socket.cancel()
        }
        defer { watchdog.cancel() }

        let started = Date()
        do {
            _ = try await manager.sendCommand("010D", retries: 1)
            XCTFail("expected link loss")
        } catch {
            XCTAssertTrue(isCommunicationError(error, .connectionLost), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(socket.sentCommands, ["010C", "ATRV"])
        XCTAssertNil(manager.socket)
    }

    func testAWriteThatCompletesInTimeIsUnaffected() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 1.0)
        manager.writeTimeout = 1.0
        socket.stallSends = true
        let request = Task { try await manager.sendCommand("0100", retries: 1) }
        try await socket.waitForSend("0100")
        try await Task.sleep(nanoseconds: 50_000_000)
        socket.releaseStalledSends()
        try await socket.deliverWhenArmed(Self.ownAnswer + "\r>")
        let lines = try await request.value
        XCTAssertEqual(lines, [Self.ownAnswer])
        XCTAssertFalse(socket.wasCancelled)
        XCTAssertNotNil(manager.socket)
    }
}

// MARK: - Helpers

private extension WifiManager {
    /// Sends `command` and answers it — waiting for the write to actually reach the socket, and
    /// for the pump to have a read armed, so nothing here depends on task scheduling.
    func perform(_ command: String, on socket: FakeWifiSocket, answering response: String) async throws -> [String] {
        async let lines = sendCommand(command, retries: 1)
        try await socket.waitForSend(command)
        try await socket.deliverWhenArmed(response)
        return try await lines
    }

    /// The same on a stream an earlier command left dirty: the transport probes first, and
    /// writes `command` only once the probe's own answer arrived.
    func performAfterResynchronizing(
        _ command: String, on socket: FakeWifiSocket, answering response: String
    ) async throws -> [String] {
        async let lines = sendCommand(command, retries: 1)
        try await socket.waitForSend("ATRV")
        try await socket.deliverWhenArmed("12.4V\r\r>")
        try await socket.waitForSend(command)
        try await socket.deliverWhenArmed(response)
        return try await lines
    }
}

// MARK: - Fake socket

/// A **non-cooperative** stand-in for the wire.
///
/// It never checks cancellation, never times a read out, and never resolves a read on its own —
/// only `deliver`/`failRead` do, exactly like the real Network callback. Anything that unblocks a
/// caller in these tests is therefore the transport's own doing.
private final class FakeWifiSocket: WifiSocket {
    private let lock = NSLock()
    private var pendingRead: ((Result<Data, WifiSocketError>) -> Void)?
    private var sends: [String] = []
    private var arms = 0
    private var cancelled = false
    private var shouldFailSends = false
    private var bytes = 0
    private var shouldStallSends = false
    private var stalledSends: [(Result<Void, WifiSocketError>) -> Void] = []
    private var sendObserver: ((String) -> Void)?

    /// When true, every write fails as a dead socket.
    var failSends: Bool {
        get { lock.lock(); defer { lock.unlock() }; return shouldFailSends }
        set { lock.lock(); shouldFailSends = newValue; lock.unlock() }
    }

    /// When true, a write is recorded but never reports itself processed, like a send stuck in
    /// `NWConnection`, until `cancel()` (which completes it with an error, as `NWConnection`
    /// does) or `releaseStalledSends()`.
    var stallSends: Bool {
        get { lock.lock(); defer { lock.unlock() }; return shouldStallSends }
        set { lock.lock(); shouldStallSends = newValue; lock.unlock() }
    }

    /// Called with each command as it is written, before the write reports back.
    var onSend: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return sendObserver }
        set { lock.lock(); sendObserver = newValue; lock.unlock() }
    }

    var sentCommands: [String] { lock.lock(); defer { lock.unlock() }; return sends }
    /// Every byte handed to `send`, terminators included.
    var bytesSent: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var armedReceives: Int { lock.lock(); defer { lock.unlock() }; return arms }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    // MARK: WifiSocket

    func send(_ data: Data, completion: @escaping (Result<Void, WifiSocketError>) -> Void) {
        let command = String(data: data, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        lock.lock()
        sends.append(command)
        bytes += data.count
        let shouldFail = shouldFailSends
        let shouldStall = shouldStallSends
        let observer = sendObserver
        lock.unlock()
        observer?(command)
        if shouldFail { return completion(.failure(.failed)) }
        if shouldStall {
            lock.lock()
            if cancelled {
                lock.unlock()
                completion(.failure(.failed))
                return
            }
            stalledSends.append(completion)
            lock.unlock()
            return
        }
        completion(.success(()))
    }

    /// Lets every stalled write report itself processed.
    func releaseStalledSends() {
        lock.lock()
        let stalled = stalledSends
        stalledSends = []
        lock.unlock()
        stalled.forEach { $0(.success(())) }
    }

    func receive(_ completion: @escaping (Result<Data, WifiSocketError>) -> Void) {
        lock.lock()
        arms += 1
        pendingRead = completion
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        pendingRead = nil
        let stalled = stalledSends
        stalledSends = []
        lock.unlock()
        // Like `NWConnection`: cancelling completes a pending send, with an error.
        stalled.forEach { $0(.failure(.failed)) }
    }

    // MARK: Test control

    /// Resolves the currently-armed read with these bytes; the pump re-arms from inside it.
    func deliver(_ text: String) {
        lock.lock()
        let completion = pendingRead
        pendingRead = nil
        lock.unlock()
        completion?(.success(Data(text.utf8)))
    }

    /// Breaks the socket underneath the pump, once a read is actually armed — otherwise the
    /// failure would silently go nowhere and the test would race the transport.
    func failReadWhenArmed(file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 2000 {
            lock.lock()
            let armed = pendingRead != nil
            lock.unlock()
            if armed {
                failRead()
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for the pump to arm a read", file: file, line: line)
    }

    /// Breaks the socket underneath the pump.
    func failRead() {
        lock.lock()
        let completion = pendingRead
        pendingRead = nil
        lock.unlock()
        completion?(.failure(.failed))
    }

    /// Waits until the pump has a read armed, then resolves it — for deliveries that follow an
    /// earlier one, where the pump re-arms asynchronously.
    func deliverWhenArmed(_ text: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 2000 {
            lock.lock()
            let armed = pendingRead != nil
            lock.unlock()
            if armed {
                deliver(text)
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for the pump to arm a read", file: file, line: line)
    }

    /// Waits until `command` has been written, so a test can respond deterministically.
    func waitForSend(_ command: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 2000 {
            if sentCommands.contains(command) { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(command) to be sent", file: file, line: line)
    }

    /// Waits until at least `count` writes have been made, whatever they were.
    func waitForSendCount(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 2000 {
            if sentCommands.count >= count { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for write #\(count)", file: file, line: line)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool

    init(_ value: Bool) { flag = value }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

extension WifiTransactionTests {
    func testDamagedMonitorContinuationCannotSupplyStoredCodes() async throws {
        let socket = FakeWifiSocket()
        let wifi = makeManager(socket, readTimeout: 1)
        let elm = ELM327(comm: wifi)
        elm.canProtocol = ISO_15765_4_11bit_500k()
        elm.connectionState = .connectedToVehicle
        async let monitor = wifi.sendCommand("0601", retries: 1)
        try await socket.waitForSend("0601")
        try await socket.deliverWhenArmed("7E8100A46010101000\r>")
        let needsProbe: Bool
        do {
            _ = try await monitor
            needsProbe = false
        } catch OBDStreamError.ambiguousResponse {
            needsProbe = true
        }

        async let scan = elm.scanForTroubleCodes(profile: .storedOnly)
        if needsProbe {
            try await socket.waitForSend("ATRV")
            try await socket.deliverWhenArmed("14.1V\r>")
        }
        try await socket.waitForSend("0101")
        try await socket.deliverWhenArmed("7E80641018407E100\r>")
        try await socket.waitForSend("03")
        try await socket.deliverWhenArmed("7E8100A430401230124\r7E82100010003AAAAAA\r>")
        let report = try await scan
        let codes = report.observations.map(\.code)
        XCTAssertEqual(report.services[.stored], .invalidResponse)
        XCTAssertTrue(codes.isEmpty, "Scan reported " + codes.joined(separator: ", "))
        XCTAssertEqual(socket.sentCommands, ["0601", "ATRV", "0101", "03"])
    }
}

extension WifiTransactionTests {
    func testSearchMergedMonitorHeadCannotSupplyStoredCodes() async throws {
        try await checkDamagedMonitorHead("SEARCHING...7E8100A460101010002")
    }

    func testDroppedHeaderDigitMonitorHeadCannotSupplyStoredCodes() async throws {
        try await checkDamagedMonitorHead("78100A460101010002")
    }

    func testDroppedLeadingCANDigitCannotSupplyStoredCodes() async throws {
        try await checkDamagedMonitorHead("E8100A460101010002", selectCAN: true)
    }

    private func checkDamagedMonitorHead(_ head: String, selectCAN: Bool = false) async throws {
        let socket = FakeWifiSocket()
        let wifi = makeManager(socket, readTimeout: 1)
        let elm = ELM327(comm: wifi)
        elm.canProtocol = ISO_15765_4_11bit_500k()
        elm.connectionState = .connectedToVehicle

        if selectCAN {
            async let select = wifi.sendCommand("ATSP6", retries: 1)
            try await socket.waitForSend("ATSP6")
            try await socket.deliverWhenArmed("OK\r>")
            _ = try await select
        }

        async let monitor = wifi.sendCommand("0601", retries: 1)
        try await socket.waitForSend("0601")
        try await socket.deliverWhenArmed(head + "\r>")
        let needsProbe: Bool
        do {
            _ = try await monitor
            needsProbe = false
        } catch OBDStreamError.ambiguousResponse {
            needsProbe = true
        }

        async let scan = elm.scanForTroubleCodes(profile: .storedOnly)
        if needsProbe {
            try await socket.waitForSend("ATRV")
            try await socket.deliverWhenArmed("14.1V\r>")
        }
        try await socket.waitForSend("0101")
        try await socket.deliverWhenArmed("7E80641018407E100\r>")
        try await socket.waitForSend("03")
        try await socket.deliverWhenArmed("7E8100A430401230124\r7E82100010003AAAAAA\r>")
        let report = try await scan
        XCTAssertEqual(report.services[.stored], .invalidResponse)
        XCTAssertTrue(report.observations.isEmpty)
        XCTAssertEqual(socket.sentCommands, (selectCAN ? ["ATSP6"] : []) + ["0601", "ATRV", "0101", "03"])
    }
}
