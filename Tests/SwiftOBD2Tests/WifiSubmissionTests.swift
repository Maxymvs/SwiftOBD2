//
//  WifiSubmissionTests.swift
//  SwiftOBD2Tests
//
//  The WiFi transport's write submission and socket ownership:
//
//  - A bound command (a Mode 04 clear bound to one vehicle link) is submitted to the socket only
//    inside the binding's `whileAuthorized`, so a revocation either comes first and nothing is
//    written, or returns only after the bytes were handed over.
//  - A write refused before submission (its deadline passed, or its socket is no longer the
//    current one) wrote nothing: the slot is released unwritten and a refused probe is not spent.
//  - A socket's teardown touches only that socket: retiring, failing or cancelling a socket that
//    was already replaced changes nothing, and its late bytes never reach its successor.
//
//  Only the socket (and, where needed, the clock) is fake.
//

import Combine
import Foundation
import Network
@testable import SwiftOBD2
import XCTest

final class WifiSubmissionTests: XCTestCase {
    private static let ownAnswer = "7E8 06 41 00 BE 3F A8 13"

    private func makeManager(
        _ socket: SubmissionTestSocket,
        readTimeout: TimeInterval = 0.3,
        clock: ManualTestClock? = nil
    ) -> WifiManager {
        let manager = clock.map { clock in WifiManager(clock: { clock.now }) } ?? WifiManager()
        manager.readTimeout = readTimeout
        manager.listenWindowTimeout = readTimeout
        manager.resynchronization = OBDStreamResynchronizer.Timing(quietWindow: 0.02, maximumDrain: 0.2, probeWindow: 0.3)
        manager.attach(socket: socket)
        manager.connectionState = .connectedToVehicle
        return manager
    }

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
        XCTAssertTrue(manager.isStreamDirty, "precondition: the stream is dirty")
    }

    // MARK: - P1-B: the bound write is authorized at its submission

    /// The binding is revoked right after the post-resynchronization check returns, i.e. between
    /// the last check and the submission. Nothing may be written.
    func testARevocationBetweenTheLastCheckAndTheSubmissionWritesNothing() async throws {
        let socket = SubmissionTestSocket()
        socket.answers = ["ATRV": "12.4V\r\r>", "0100": Self.ownAnswer + "\r>"]
        let manager = makeManager(socket)
        await timeOut("010C", on: manager)

        let revoked = LockedBox(false)
        let checks = Counter()
        let authorization = OBDWriteAuthorization(
            check: {
                let call = checks.increment()
                if revoked.value { throw OBDVehicleLinkError.linkChanged }
                // The second check of the attempt is the one after the proof: revoke as it returns.
                if call == 2 { revoked.value = true }
            },
            whileAuthorized: { submit in
                try revoked.withLock { isRevoked in
                    if isRevoked { throw OBDVehicleLinkError.linkChanged }
                    try submit()
                }
            }
        )

        do {
            _ = try await manager.sendCommand("04", retries: 3, authorization: authorization)
            XCTFail("expected linkChanged")
        } catch {
            XCTAssertEqual(error as? OBDVehicleLinkError, .linkChanged, "the binding's error escapes unchanged: \(error)")
        }
        XCTAssertFalse(socket.sentCommands.contains("04"), "04 reached the socket on a revoked link")
        XCTAssertEqual(checks.value, 2, "one attempt only: a refused binding is not retried")
        XCTAssertFalse(manager.isStreamDirty, "nothing was written for the clear")

        let lines = try await manager.sendCommand("0100", retries: 1)
        XCTAssertEqual(lines, [Self.ownAnswer])
        XCTAssertEqual(socket.sentCommands, ["010C", "ATRV", "0100"], "the next command is written with no probe first")
    }

    private func makeLinkedManager(
        _ socket: SubmissionTestSocket
    ) -> (WifiManager, ELM327, OBDVehicleLinkRecord, OBDVehicleLink) {
        let manager = makeManager(socket, readTimeout: 1.0)
        let elm = ELM327(comm: manager)
        let record = OBDVehicleLinkRecord()
        let link = OBDVehicleLink(id: UUID(), vin: nil, adapterID: nil)
        record.publish(link, adapter: elm, connection: manager.adapterConnection)
        return (manager, elm, record, link)
    }

    /// The same with the real link record: `clear()` lands after every check passed and before
    /// the socket send starts.
    func testTheRealLinkRecordClearedBeforeTheSubmissionWritesNothing() async throws {
        let socket = SubmissionTestSocket()
        socket.answers = ["04": "44\r\r>", "0100": Self.ownAnswer + "\r>"]
        let (manager, elm, record, link) = makeLinkedManager(socket)
        manager.willSubmitWrite = { data in
            if data == Data("04\r".utf8) { record.clear() }
        }

        do {
            _ = try await manager.sendCommand("04", retries: 3, authorization: record.authorization(for: link, adapter: elm))
            XCTFail("expected linkChanged")
        } catch {
            XCTAssertEqual(error as? OBDVehicleLinkError, .linkChanged, "\(error)")
        }
        XCTAssertEqual(socket.sentCommands, [], "04 reached the socket after clear()")
        XCTAssertFalse(manager.isStreamDirty)

        manager.willSubmitWrite = nil
        let lines = try await manager.sendCommand("0100", retries: 1)
        XCTAssertEqual(lines, [Self.ownAnswer])
        XCTAssertEqual(socket.sentCommands, ["0100"])
    }

    /// The other side: the link is still current, so `04` is written once and answered.
    func testABoundClearOnTheCurrentLinkIsWrittenOnceAndAnswered() async throws {
        let socket = SubmissionTestSocket()
        socket.answers = ["04": "44\r\r>"]
        let (manager, elm, record, link) = makeLinkedManager(socket)

        let lines = try await manager.sendCommand("04", retries: 3, authorization: record.authorization(for: link, adapter: elm))

        XCTAssertEqual(lines, ["44"])
        XCTAssertEqual(socket.sentCommands, ["04"])
        XCTAssertFalse(manager.isStreamDirty)
    }

    /// `record.clear()` raced against the bound send, many times. Whenever the socket received
    /// `04`, it received it before `clear()` returned.
    func testARacingClearNeverReturnsBeforeABoundWriteThatStillGoesOut() async throws {
        let socket = SubmissionTestSocket()
        socket.answers = ["04": "44\r\r>"]
        let (manager, elm, record, _) = makeLinkedManager(socket)
        let sequence = Counter()
        let sentAt = LockedBox<Int?>(nil)
        socket.onSend = { command in
            if command == "04" { sentAt.value = sequence.increment() }
        }

        var violations = 0
        var written = 0
        var refused = 0
        for iteration in 0 ..< 300 {
            let link = OBDVehicleLink(id: UUID(), vin: nil, adapterID: nil)
            record.publish(link, adapter: elm, connection: manager.adapterConnection)
            sentAt.value = nil
            let authorization = record.authorization(for: link, adapter: elm)

            let send = Task.detached { try await manager.sendCommand("04", retries: 1, authorization: authorization) }
            let clear = Task.detached { () -> Int in
                // Spread the clear across the send's whole path.
                for _ in 0 ..< (iteration % 40) * 25 { _ = sequence.value }
                record.clear()
                return sequence.increment()
            }
            let clearedAt = await clear.value
            let result = await send.result

            if let sent = sentAt.value {
                written += 1
                if sent > clearedAt { violations += 1 }
                if case let .failure(error) = result {
                    XCTFail("iteration \(iteration): 04 went out but the send failed: \(error)")
                }
            } else {
                refused += 1
                if case let .failure(error) = result {
                    XCTAssertEqual(error as? OBDVehicleLinkError, .linkChanged, "iteration \(iteration): \(error)")
                } else {
                    XCTFail("iteration \(iteration): succeeded without writing")
                }
            }
            XCTAssertFalse(manager.isStreamDirty, "iteration \(iteration)")
        }
        XCTAssertEqual(violations, 0, "04 reached the socket after clear() returned (\(written) written, \(refused) refused)")
        print("WifiSubmissionTests race: \(written) written, \(refused) refused, \(violations) violations")
    }

    // MARK: - P2-3: a write refused before submission wrote nothing

    /// The probe's deadline passes before its submission: it wasn't written, so it stays usable
    /// and the next resynchronization starts with that same probe.
    func testAProbeRefusedForItsDeadlineIsNotSpent() async throws {
        let clock = ManualTestClock()
        let socket = SubmissionTestSocket()
        socket.answers = ["ATRV": "12.4V\r\r>", "0100": Self.ownAnswer + "\r>"]
        let manager = makeManager(socket, clock: clock)
        await timeOut("010C", on: manager)

        let refusedOnce = LockedBox(false)
        manager.willSubmitWrite = { data in
            guard data == Data("ATRV\r".utf8), !refusedOnce.value else { return }
            refusedOnce.value = true
            clock.advance(by: 60) // past the probe's write deadline
        }
        do {
            _ = try await manager.sendCommand("0101", retries: 1)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(isCommunicationError(error, .timeout), "\(error)")
        }
        XCTAssertEqual(socket.sentCommands, ["010C"], "the refused probe wrote nothing")
        XCTAssertTrue(manager.isStreamDirty, "nothing proved the stream")

        let lines = try await manager.sendCommand("0100", retries: 1)
        XCTAssertEqual(lines, [Self.ownAnswer])
        XCTAssertEqual(socket.sentCommands, ["010C", "ATRV", "0100"], "the next proof uses the same first probe")
    }

    /// A command whose write deadline passes before its submission writes nothing and leaves the
    /// stream as it was.
    func testACommandRefusedForItsDeadlineWritesNothingAndLeavesTheStreamClean() async throws {
        let clock = ManualTestClock()
        let socket = SubmissionTestSocket()
        socket.answers = ["0101": "7E8 06 41 01 00 07 E1 00\r>"]
        let manager = makeManager(socket, clock: clock)
        manager.willSubmitWrite = { data in
            if data == Data("0100\r".utf8) { clock.advance(by: 60) }
        }

        do {
            _ = try await manager.sendCommand("0100", retries: 1)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(isCommunicationError(error, .timeout), "\(error)")
        }
        XCTAssertEqual(socket.sentCommands, [])
        XCTAssertFalse(manager.isStreamDirty)
        XCTAssertTrue(manager.socket === socket, "a refused write keeps its socket")

        manager.willSubmitWrite = nil
        let lines = try await manager.sendCommand("0101", retries: 1)
        XCTAssertEqual(lines, ["7E8 06 41 01 00 07 E1 00"])
        XCTAssertEqual(socket.sentCommands, ["0101"], "written directly, no probe")
    }

    /// A probe whose socket was replaced before its submission goes nowhere: not to the old
    /// socket, not to the new one. The caller sees link loss; the new stream is untouched.
    func testAProbeWhoseSocketWasReplacedBeforeSubmissionWritesNothing() async throws {
        let socketA = SubmissionTestSocket()
        let socketB = SubmissionTestSocket()
        socketB.answers = ["0100": Self.ownAnswer + "\r>"]
        let manager = makeManager(socketA)
        await timeOut("010C", on: manager)
        manager.willSubmitWrite = { data in
            if data == Data("ATRV\r".utf8) { manager.attach(socket: socketB) }
        }

        do {
            _ = try await manager.sendCommand("0101", retries: 3)
            XCTFail("expected link loss")
        } catch {
            XCTAssertTrue(isCommunicationError(error, .connectionLost), "\(error)")
        }
        XCTAssertEqual(socketA.sentCommands, ["010C"], "the old socket got no probe")
        XCTAssertEqual(socketB.sentCommands, [], "the new socket got nothing")
        XCTAssertTrue(manager.socket === socketB)
        XCTAssertFalse(manager.isStreamDirty)

        manager.willSubmitWrite = nil
        let lines = try await manager.sendCommand("0100", retries: 1)
        XCTAssertEqual(lines, [Self.ownAnswer])
        XCTAssertEqual(socketB.sentCommands, ["0100"], "written directly, no probe")
    }

    /// The same for a command.
    func testACommandWhoseSocketWasReplacedBeforeSubmissionWritesNothing() async throws {
        let socketA = SubmissionTestSocket()
        let socketB = SubmissionTestSocket()
        socketB.answers = ["0100": Self.ownAnswer + "\r>"]
        let manager = makeManager(socketA)
        manager.willSubmitWrite = { data in
            if data == Data("0101\r".utf8) { manager.attach(socket: socketB) }
        }

        do {
            _ = try await manager.sendCommand("0101", retries: 3)
            XCTFail("expected link loss")
        } catch {
            XCTAssertTrue(isCommunicationError(error, .connectionLost), "\(error)")
        }
        XCTAssertEqual(socketA.sentCommands, [])
        XCTAssertEqual(socketB.sentCommands, [])
        XCTAssertFalse(manager.isStreamDirty)

        manager.willSubmitWrite = nil
        let lines = try await manager.sendCommand("0100", retries: 1)
        XCTAssertEqual(lines, [Self.ownAnswer])
        XCTAssertEqual(socketB.sentCommands, ["0100"])
    }

    // MARK: - P2-1: a socket's teardown touches only that socket

    /// Records every publication, in order: `connectionState` (synchronously, as assigned), the
    /// delegate callback, and markers the test adds.
    private func record(_ manager: WifiManager) -> (EventLog, AnyCancellable, StateDelegateRecorder) {
        let log = EventLog()
        let subscription = manager.$connectionState.dropFirst().sink { log.append("state:\($0)") }
        let delegate = StateDelegateRecorder(log: log)
        manager.obdDelegate = delegate
        return (log, subscription, delegate)
    }

    private func assertNothingDisconnectedAfter(
        _ marker: String, in log: EventLog, file: StaticString = #filePath, line: UInt = #line
    ) {
        let events = log.events
        guard let index = events.lastIndex(of: marker) else {
            return XCTFail("\(marker) never happened: \(events)", file: file, line: line)
        }
        let after = events[(index + 1)...].filter { $0.hasSuffix("disconnected") }
        XCTAssertTrue(after.isEmpty, "a stale disconnect was published after \(marker): \(events)", file: file, line: line)
    }

    /// The reviewer's reproduction: socket A's write stalls past its deadline, so A is retired;
    /// A's `cancel()` installs socket B. B must survive A's retirement.
    func testASocketInstalledDuringTheRetiredSocketsCancelSurvives() async throws {
        let socketA = SubmissionTestSocket()
        socketA.stallSends = true
        let socketB = SubmissionTestSocket()
        socketB.answers = ["0100": Self.ownAnswer + "\r>"]
        let manager = makeManager(socketA, readTimeout: 1.0)
        manager.writeTimeout = 0.2
        let (log, subscription, delegate) = record(manager)
        defer { subscription.cancel(); _ = delegate }
        socketA.onCancel = {
            manager.attach(socket: socketB)
            manager.connectionState = .connectedToAdapter
            log.append("installed B")
        }

        do {
            _ = try await manager.sendCommand("0101", retries: 1)
            XCTFail("expected link loss")
        } catch {
            XCTAssertTrue(isCommunicationError(error, .connectionLost), "\(error)")
        }
        XCTAssertEqual(socketA.cancelCount, 1)
        XCTAssertTrue(manager.socket === socketB, "B was cleared by A's retirement")
        XCTAssertNotEqual(manager.connectionState, .disconnected)
        assertNothingDisconnectedAfter("installed B", in: log)

        let lines = try await manager.sendCommand("0100", retries: 1)
        XCTAssertEqual(lines, [Self.ownAnswer])
        XCTAssertEqual(socketB.sentCommands, ["0100"])
    }

    /// `disconnectPeripheral()` retires the current socket, once; a socket A's `cancel()`
    /// installs is a new connection and stays.
    func testDisconnectRetiresExactlyTheCurrentSocketOnce() async throws {
        let socketA = SubmissionTestSocket()
        let socketB = SubmissionTestSocket()
        socketB.answers = ["0100": Self.ownAnswer + "\r>"]
        let manager = makeManager(socketA)
        let (log, subscription, delegate) = record(manager)
        defer { subscription.cancel(); _ = delegate }
        socketA.onCancel = {
            manager.attach(socket: socketB)
            manager.connectionState = .connectedToAdapter
            log.append("installed B")
        }

        manager.disconnectPeripheral()

        XCTAssertEqual(socketA.cancelCount, 1)
        XCTAssertEqual(socketB.cancelCount, 0)
        XCTAssertTrue(manager.socket === socketB, "B was cleared by A's disconnect")
        XCTAssertNotEqual(manager.connectionState, .disconnected)
        assertNothingDisconnectedAfter("installed B", in: log)
        let lines = try await manager.sendCommand("0100", retries: 1)
        XCTAssertEqual(lines, [Self.ownAnswer])
    }

    func testDisconnectTwiceCancelsOnceAndPublishesOnce() {
        let socket = SubmissionTestSocket()
        let manager = makeManager(socket)
        let (log, subscription, delegate) = record(manager)
        defer { subscription.cancel(); _ = delegate }

        manager.disconnectPeripheral()
        manager.disconnectPeripheral()

        XCTAssertEqual(socket.cancelCount, 1)
        XCTAssertNil(manager.socket)
        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertEqual(log.events, ["state:disconnected", "delegate:disconnected"])
    }

    /// A's receive pump fails after B was installed: nothing changes.
    func testAReplacedSocketsPumpFailureChangesNothing() async throws {
        let socketA = SubmissionTestSocket()
        let socketB = SubmissionTestSocket()
        socketB.answers = ["0100": Self.ownAnswer + "\r>"]
        let manager = makeManager(socketA)
        manager.attach(socket: socketB)
        let epoch = manager.adapterConnection
        let (log, subscription, delegate) = record(manager)
        defer { subscription.cancel(); _ = delegate }

        socketA.failRead()

        XCTAssertTrue(manager.socket === socketB)
        XCTAssertEqual(manager.adapterConnection, epoch)
        XCTAssertEqual(manager.connectionState, .connectedToVehicle)
        XCTAssertEqual(log.events, [])
        let lines = try await manager.sendCommand("0100", retries: 1)
        XCTAssertEqual(lines, [Self.ownAnswer])
    }

    /// The same raced: A's pump failure and B's install, from two threads. Whichever comes first,
    /// B is the current socket afterwards.
    func testARacingPumpFailureNeverClearsItsSuccessor() {
        var cleared = 0
        for _ in 0 ..< 400 {
            let socketA = SubmissionTestSocket()
            let socketB = SubmissionTestSocket()
            let manager = WifiManager()
            manager.attach(socket: socketA)
            Self.race({ socketA.failRead() }, { manager.attach(socket: socketB) })
            if manager.socket !== socketB { cleared += 1 }
        }
        XCTAssertEqual(cleared, 0, "a replaced socket's pump failure cleared its successor")
    }

    /// A's late bytes after B was installed never reach B's stream.
    func testAReplacedSocketsLateBytesNeverReachItsSuccessor() async throws {
        let socketA = SubmissionTestSocket()
        let socketB = SubmissionTestSocket()
        socketB.answers = ["0100": Self.ownAnswer + "\r>"]
        let manager = makeManager(socketA)
        manager.attach(socket: socketB)

        socketA.deliver("7E8 04 41 0C 1F 40\r>")

        let lines = try await manager.sendCommand("0100", retries: 1)
        XCTAssertEqual(lines, [Self.ownAnswer])
        XCTAssertEqual(socketB.sentCommands, ["0100"], "B's stream saw none of A's bytes")
    }

    /// The same raced: A's bytes and B's install from two threads. Either way B's stream never
    /// holds A's bytes, so B's first command is written with no probe.
    func testRacingLateBytesNeverReachTheSuccessorsStream() async throws {
        var polluted = 0
        for _ in 0 ..< 300 {
            let socketA = SubmissionTestSocket()
            let socketB = SubmissionTestSocket()
            socketB.answers = ["0100": Self.ownAnswer + "\r>"]
            let manager = WifiManager()
            manager.readTimeout = 0.3
            manager.resynchronization = OBDStreamResynchronizer.Timing(quietWindow: 0.01, maximumDrain: 0.05, probeWindow: 0.05)
            manager.attach(socket: socketA)
            Self.race({ socketA.deliver("7E8 04 41 0C 1F 40\r>") }, { manager.attach(socket: socketB) })
            _ = try? await manager.sendCommand("0100", retries: 1)
            if socketB.sentCommands != ["0100"] { polluted += 1 }
        }
        XCTAssertEqual(polluted, 0, "a replaced socket's bytes reached its successor's stream")
    }

    // MARK: connectAsync's state handler

    func testAnOldConnectionsCancellationChangesNothing() async throws {
        let socketA = SubmissionTestSocket()
        let socketB = SubmissionTestSocket()
        socketB.answers = ["0100": Self.ownAnswer + "\r>"]
        let manager = WifiManager()
        manager.readTimeout = 0.3
        manager.beginConnectionAttempt(socket: socketA)
        XCTAssertNotNil(manager.connectionStateDidChange(.ready, socket: socketA))
        manager.beginConnectionAttempt(socket: socketB)
        XCTAssertNotNil(manager.connectionStateDidChange(.ready, socket: socketB))
        XCTAssertTrue(manager.socket === socketB)
        let epoch = manager.adapterConnection
        let (log, subscription, delegate) = record(manager)
        defer { subscription.cancel(); _ = delegate }

        _ = manager.connectionStateDidChange(.cancelled, socket: socketA)
        _ = manager.connectionStateDidChange(.failed(.posix(.ECONNRESET)), socket: socketA)

        XCTAssertTrue(manager.socket === socketB)
        XCTAssertEqual(manager.adapterConnection, epoch)
        XCTAssertEqual(manager.connectionState, .connectedToAdapter)
        XCTAssertEqual(log.events, [], "an old connection published something")
        let lines = try await manager.sendCommand("0100", retries: 1)
        XCTAssertEqual(lines, [Self.ownAnswer])
    }

    func testAConnectionThatNeverBecameCurrentPublishesNothing() {
        let current = SubmissionTestSocket()
        let neverReady = SubmissionTestSocket()
        let manager = WifiManager()
        manager.beginConnectionAttempt(socket: current)
        XCTAssertNotNil(manager.connectionStateDidChange(.ready, socket: current))
        let (log, subscription, delegate) = record(manager)
        defer { subscription.cancel(); _ = delegate }

        manager.beginConnectionAttempt(socket: neverReady)
        let outcome = manager.connectionStateDidChange(.failed(.posix(.ECONNREFUSED)), socket: neverReady)
        _ = manager.connectionStateDidChange(.cancelled, socket: neverReady)

        if case .success? = outcome { XCTFail("a failed connection reported success") }
        XCTAssertTrue(manager.socket === current)
        XCTAssertEqual(log.events, [])
    }

    func testAbandonedReadyCannotReplaceTheCurrentSocketOrResetItsSlot() async throws {
        let abandoned = SubmissionTestSocket()
        let current = SubmissionTestSocket()
        let manager = WifiManager()
        manager.readTimeout = 1
        manager.beginConnectionAttempt(socket: abandoned)
        XCTAssertNil(manager.connectionStateDidChange(.waiting(.posix(.ENETDOWN)), socket: abandoned))
        manager.disconnectPeripheral()
        XCTAssertEqual(abandoned.cancelCount, 1)

        manager.beginConnectionAttempt(socket: current)
        guard case .success? = manager.connectionStateDidChange(.ready, socket: current) else {
            return XCTFail("current attempt must install")
        }
        let epoch = manager.adapterConnection
        let waiting = expectation(description: "B has a live response slot")
        current.onSend = { _ in waiting.fulfill() }
        let request = Task { try await manager.sendCommand("0100", retries: 1) }
        await fulfillment(of: [waiting], timeout: 1)

        guard case .failure? = manager.connectionStateDidChange(.ready, socket: abandoned) else {
            request.cancel()
            return XCTFail("abandoned attempt reported ready")
        }
        current.deliver(Self.ownAnswer + "\r>")
        let lines = try await request.value
        XCTAssertEqual(lines, [Self.ownAnswer])
        XCTAssertTrue(manager.socket === current)
        XCTAssertEqual(manager.adapterConnection, epoch)
    }

    func testTheCurrentConnectionsCancellationDisconnects() {
        let socket = SubmissionTestSocket()
        let manager = WifiManager()
        manager.beginConnectionAttempt(socket: socket)
        XCTAssertNotNil(manager.connectionStateDidChange(.ready, socket: socket))
        XCTAssertEqual(manager.connectionState, .connectedToAdapter)
        let (log, subscription, delegate) = record(manager)
        defer { subscription.cancel(); _ = delegate }

        _ = manager.connectionStateDidChange(.cancelled, socket: socket)

        XCTAssertNil(manager.socket)
        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertEqual(log.events, ["state:disconnected", "delegate:disconnected"])
    }

    // MARK: - Support

    /// Runs `first` and `second` on two threads, released together.
    private static func race(_ first: @escaping () -> Void, _ second: @escaping () -> Void) {
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for body in [first, second] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                start.wait()
                body()
                group.leave()
            }
        }
        start.signal()
        start.signal()
        group.wait()
    }
}

// MARK: - Fakes

/// A socket for these tests. Commands listed in `answers` are answered synchronously, from
/// inside `send`, through the pump's armed read (the harshest re-entrancy a real socket could
/// show); everything else goes unanswered. Reads otherwise resolve only when the test says so.
final class SubmissionTestSocket: WifiSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingRead: ((Result<Data, WifiSocketError>) -> Void)?
    private var sends: [String] = []
    private var cancels = 0
    private var stall = false
    private var stalledSends: [(Result<Void, WifiSocketError>) -> Void] = []
    private var answerTable: [String: String] = [:]
    private var sendObserver: ((String) -> Void)?
    private var cancelObserver: (() -> Void)?

    var answers: [String: String] {
        get { lock.withLock { answerTable } }
        set { lock.withLock { answerTable = newValue } }
    }

    /// When true, a write is recorded but never reports itself processed until `cancel()`.
    var stallSends: Bool {
        get { lock.withLock { stall } }
        set { lock.withLock { stall = newValue } }
    }

    /// Called with each command as it reaches the socket, before it is answered.
    var onSend: ((String) -> Void)? {
        get { lock.withLock { sendObserver } }
        set { lock.withLock { sendObserver = newValue } }
    }

    /// Called from inside `cancel()`, after the socket is cancelled.
    var onCancel: (() -> Void)? {
        get { lock.withLock { cancelObserver } }
        set { lock.withLock { cancelObserver = newValue } }
    }

    var sentCommands: [String] { lock.withLock { sends } }
    var cancelCount: Int { lock.withLock { cancels } }

    func send(_ data: Data, completion: @escaping (Result<Void, WifiSocketError>) -> Void) {
        let command = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let (observer, answer, shouldStall) = lock.withLock { () -> (((String) -> Void)?, String?, Bool) in
            sends.append(command)
            return (sendObserver, answerTable[command], stall)
        }
        observer?(command)
        if let answer { deliver(answer) }
        if shouldStall {
            let cancelled: Bool = lock.withLock {
                if cancels > 0 { return true }
                stalledSends.append(completion)
                return false
            }
            if cancelled { completion(.failure(.failed)) }
            return
        }
        // Reported processed before `send` returns, like the harshest real socket could.
        completion(.success(()))
    }

    func receive(_ completion: @escaping (Result<Data, WifiSocketError>) -> Void) {
        lock.withLock { pendingRead = completion }
    }

    func cancel() {
        let (stalled, observer) = lock.withLock { () -> ([(Result<Void, WifiSocketError>) -> Void], (() -> Void)?) in
            cancels += 1
            pendingRead = nil
            defer { stalledSends = [] }
            return (stalledSends, cancelObserver)
        }
        // Like `NWConnection`: cancelling completes a pending send, with an error.
        stalled.forEach { $0(.failure(.failed)) }
        observer?()
    }

    /// Resolves the armed read, if any, with these bytes; the pump re-arms from inside it.
    func deliver(_ text: String) {
        let completion = lock.withLock { () -> ((Result<Data, WifiSocketError>) -> Void)? in
            defer { pendingRead = nil }
            return pendingRead
        }
        completion?(.success(Data(text.utf8)))
    }

    /// Breaks the socket underneath the pump.
    func failRead() {
        let completion = lock.withLock { () -> ((Result<Data, WifiSocketError>) -> Void)? in
            defer { pendingRead = nil }
            return pendingRead
        }
        completion?(.failure(.failed))
    }
}

final class ManualTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 1000

    var now: TimeInterval { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&stored)
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var events: [String] { lock.withLock { stored } }
    func append(_ event: String) { lock.withLock { stored.append(event) } }
}

final class StateDelegateRecorder: OBDServiceDelegate {
    private let log: EventLog
    init(log: EventLog) { self.log = log }
    func connectionStateChanged(state: ConnectionState) { log.append("delegate:\(state)") }
}
