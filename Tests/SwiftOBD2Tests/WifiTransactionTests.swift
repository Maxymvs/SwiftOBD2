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

    /// (b) The abandoned request's late bytes must not become the next command's answer. They land
    /// in the processor's buffer, and the next arm decides what happens to them.
    func testLateBytesFromATimedOutRequestAreNotTheNextCommandsResponse() async throws {
        let socket = FakeWifiSocket()
        let manager = makeManager(socket, readTimeout: 0.3)

        do {
            _ = try await manager.sendCommand("03", retries: 1)
            XCTFail("Expected a timeout")
        } catch { /* expected */ }

        // The vehicle finally answers the abandoned request — with no slot armed.
        try await socket.deliverWhenArmed("7E8 04 43 01 01 04\r>")

        let lines = try await manager.perform("0100", on: socket, answering: "7E8 06 41 00 BE 3F A8 13\r>")

        XCTAssertEqual(
            lines,
            ["7E8 06 41 00 BE 3F A8 13"],
            "The stale response must never be served as this command's answer"
        )
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

        // The pump kept running: the next command works normally.
        let lines = try await manager.perform("0100", on: socket, answering: "7E8 06 41 00 BE 3F A8 13\r>")
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

    /// When true, every write fails as a dead socket.
    var failSends: Bool {
        get { lock.lock(); defer { lock.unlock() }; return shouldFailSends }
        set { lock.lock(); shouldFailSends = newValue; lock.unlock() }
    }

    var sentCommands: [String] { lock.lock(); defer { lock.unlock() }; return sends }
    var armedReceives: Int { lock.lock(); defer { lock.unlock() }; return arms }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    // MARK: WifiSocket

    func send(_ data: Data) async throws {
        let command = String(data: data, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        lock.lock()
        sends.append(command)
        let shouldFail = shouldFailSends
        lock.unlock()
        if shouldFail { throw WifiSocketError.failed }
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
        lock.unlock()
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
}
