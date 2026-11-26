//
//  BLEFirstWriteAuthorizationTests.swift
//  SwiftOBD2Tests
//
//  A bound command (Mode 04 bound to one vehicle link) is handed to the Bluetooth write
//  coordinator after its last cheap check, and may then wait (flow control, a slow executor)
//  before its first chunk is physically written. A revocation of the link during that wait must
//  stop it: the first chunk's hand-off runs inside the link record's lock, after checking under
//  that lock that the link is still the published one.
//
//  The end-to-end tests run the real `OBDVehicleLinkRecord` (through `authorization(for:adapter:)`),
//  the real `BLECommandExchange` and `OBDMessageProcessor` and the real `BLEWriteCoordinator`,
//  over a scripted `BLEWriteTransport`. The target is built the way `BLEManager.commandTarget`
//  builds it (CoreBluetooth is the only thing left out).
//

import Foundation
@testable import SwiftOBD2
import XCTest

// MARK: - End to end: link record, exchange, processor, coordinator

final class BLEFirstWriteAuthorizationTests: XCTestCase {
    /// The reviewer's reproduction. `04` is bound to the link, revalidated, and handed to the
    /// coordinator, which waits for flow control. The link is cleared during the wait, then the
    /// peripheral signals ready. Nothing of `04` may reach the transport.
    func testALinkClearedWhileTheClearWaitsForFlowControlWritesNothing() async throws {
        let rig = BoundClearRig(mode: .withoutResponse)
        rig.transport.canSend = false
        let flowControlChecked = rig.transport.expectFlowControlRefusal()

        let clear = Task { try await rig.sendBoundClear(retries: 3) }
        await flowControlChecked.value
        await rig.coordinator.drainEvents()
        XCTAssertTrue(rig.transport.chunks.isEmpty, "precondition: the clear is queued behind flow control")

        rig.record.clear()
        rig.transport.canSend = true
        rig.coordinator.peripheralIsReady(session: rig.session)

        await rig.assertRefusedWithoutWriting(clear, expected: OBDVehicleLinkError.linkChanged)
        try await rig.assertStreamAndSessionUntouched()
    }

    @MainActor
    func testStopConnectionRevokesAFlowControlledClearBeforeDisconnecting() async throws {
        let rig = BoundClearRig(mode: .withoutResponse)
        let comm = FlowControlledClearComm(rig: rig)
        comm.script(vin: "TESTVIN0000000001", peripheral: UUID())
        let service = OBDService(comm: comm, connectionType: .demo)
        _ = try await service.startConnection(preferedProtocol: .protocol6)
        let link = try XCTUnwrap(service.vehicleLink)
        rig.transport.canSend = false
        let blocked = rig.transport.expectFlowControlRefusal()
        let clear = Task { try await service.clearTroubleCodes(on: link) }
        await blocked.value
        await rig.coordinator.drainEvents()

        // Give the write capacity back inside disconnectPeripheral(), before the
        // transport reports the dropped connection or invalidates the write session.
        service.stopConnection()

        do {
            try await clear.value
            XCTFail("The queued Mode 04 must be refused")
        } catch let error as OBDVehicleLinkError {
            XCTAssertEqual(error, .linkChanged)
        }
        XCTAssertTrue(rig.transport.commands.isEmpty)
    }

    /// With response: there is no flow-control wait, so the revocation lands while the executor
    /// is busy before the first chunk (here, a slow MTU query). The gate sits at the first chunk.
    func testWithResponseALinkClearedBeforeTheFirstChunkWritesNothing() async throws {
        let rig = BoundClearRig(mode: .withResponse)
        let queried = rig.transport.blockNextMaximumLengthQuery()

        let clear = Task { try await rig.sendBoundClear(retries: 3) }
        await queried.entered.value
        rig.record.clear()
        queried.release()

        await rig.assertRefusedWithoutWriting(clear, expected: OBDVehicleLinkError.linkChanged)
        try await rig.assertStreamAndSessionUntouched()
    }

    /// A different link published (a reinitialization finished) is a revocation too.
    func testAnotherLinkPublishedWhileTheClearWaitsWritesNothing() async throws {
        for mode in [BLEWriteMode.withoutResponse, .withResponse] {
            let rig = BoundClearRig(mode: mode)
            let clear: Task<[String], Error>
            switch mode {
            case .withoutResponse:
                rig.transport.canSend = false
                let flowControlChecked = rig.transport.expectFlowControlRefusal()
                clear = Task { try await rig.sendBoundClear(retries: 3) }
                await flowControlChecked.value
                await rig.coordinator.drainEvents()
                rig.publishAnotherLink()
                rig.transport.canSend = true
                rig.coordinator.peripheralIsReady(session: rig.session)
            case .withResponse:
                let queried = rig.transport.blockNextMaximumLengthQuery()
                clear = Task { try await rig.sendBoundClear(retries: 3) }
                await queried.entered.value
                rig.publishAnotherLink()
                queried.release()
            }

            await rig.assertRefusedWithoutWriting(clear, expected: OBDVehicleLinkError.linkChanged)
            try await rig.assertStreamAndSessionUntouched()
        }
    }

    /// The other side of the race: the link is still current when the first chunk is handed
    /// over, after waiting for flow control. `04` is written once and its answer returned.
    func testALinkStillCurrentAtTheHandOffWritesTheClearOnceAndReturnsItsAnswer() async throws {
        for mode in [BLEWriteMode.withoutResponse, .withResponse] {
            let rig = BoundClearRig(mode: mode)
            let clear: Task<[String], Error>
            if mode == .withoutResponse {
                rig.transport.canSend = false
                let flowControlChecked = rig.transport.expectFlowControlRefusal()
                clear = Task { try await rig.sendBoundClear(retries: 3) }
                await flowControlChecked.value
                await rig.coordinator.drainEvents()
                rig.transport.canSend = true
                rig.coordinator.peripheralIsReady(session: rig.session)
            } else {
                clear = Task { try await rig.sendBoundClear(retries: 3) }
            }

            let lines = try await clear.value
            XCTAssertEqual(lines, ["44"], "\(mode)")
            XCTAssertEqual(rig.transport.commands, ["04"], "\(mode)")
            XCTAssertEqual(rig.attempts.value, 1, "\(mode)")
            XCTAssertFalse(rig.exchange.isStreamDirty, "\(mode)")
        }
    }

    /// A gate that refuses with an error type nobody listed as non-retryable: still one attempt,
    /// nothing written, and the error escapes unchanged.
    func testAGateRefusalOfAnyErrorTypeIsNeverRetried() async throws {
        let rig = BoundClearRig(mode: .withoutResponse)
        let gateCalls = Counter()
        let authorization = OBDWriteAuthorization(
            check: {},
            whileAuthorized: { _ in
                _ = gateCalls.increment()
                throw CustomBindingError.refused
            }
        )

        let clear = Task { try await rig.sendBoundClear(retries: 3, authorization: authorization) }

        await rig.assertRefusedWithoutWriting(clear, expected: CustomBindingError.refused)
        XCTAssertEqual(gateCalls.value, 1)
        try await rig.assertStreamAndSessionUntouched()
    }

    /// Many races of `clear()` against a bound write released from flow control. Whenever the
    /// transport received `04`, it received it before `clear()` returned; whenever it didn't,
    /// the send reports the binding's error and leaves the stream clean.
    func testStressARevocationNeverPrecedesTheClearsFirstWrite() async throws {
        var written = 0
        var refused = 0
        for iteration in 0 ..< 300 {
            let rig = BoundClearRig(mode: .withoutResponse)
            let sequence = SequenceCounter()
            rig.transport.sequence = sequence
            rig.transport.canSend = false
            let flowControlChecked = rig.transport.expectFlowControlRefusal()

            let clear = Task { try await rig.sendBoundClear(retries: 3) }
            await flowControlChecked.value
            await rig.coordinator.drainEvents()

            let clearedAt = LockedValue<Int?>(nil)
            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            // A few microseconds of busy-wait jitter on the revoking side (finer than a sleep),
            // so both outcomes occur.
            let jitter = TimeInterval.random(in: 0 ... 0.000_06)
            DispatchQueue.global().async(group: group) {
                start.wait()
                let spinUntil = ProcessInfo.processInfo.systemUptime + jitter
                while ProcessInfo.processInfo.systemUptime < spinUntil {}
                rig.record.clear()
                clearedAt.set(sequence.next())
            }
            DispatchQueue.global().async(group: group) {
                start.wait()
                rig.transport.canSend = true
                rig.coordinator.peripheralIsReady(session: rig.session)
            }
            start.signal()
            start.signal()
            await withCheckedContinuation { continuation in
                group.notify(queue: .global()) { continuation.resume() }
            }

            let result = await clear.result
            let cleared = try XCTUnwrap(clearedAt.get())
            if let writtenAt = rig.transport.firstWriteSequence {
                written += 1
                XCTAssertLessThan(writtenAt, cleared, "iteration \(iteration): 04 written after clear() returned")
                XCTAssertEqual(rig.transport.commands, ["04"], "iteration \(iteration)")
                XCTAssertEqual(try? result.get(), ["44"], "iteration \(iteration)")
            } else {
                refused += 1
                XCTAssertTrue(rig.transport.chunks.isEmpty, "iteration \(iteration)")
                switch result {
                case .success:
                    XCTFail("iteration \(iteration): succeeded without writing")
                case let .failure(error):
                    XCTAssertEqual(error as? OBDVehicleLinkError, .linkChanged, "iteration \(iteration): \(error)")
                }
                XCTAssertFalse(rig.exchange.isStreamDirty, "iteration \(iteration)")
            }
            XCTAssertEqual(rig.attempts.value, 1, "iteration \(iteration)")
        }
        // The split is up to the scheduler, so it is only reported.
        print("first-write race: \(written) written before the revocation, \(refused) refused")
    }
}

// MARK: - Retry rule

final class BLEBindingRetryTests: XCTestCase {
    /// The binding's check passes when the attempt starts, then (after the dirty stream was
    /// proven) throws a type the exchange has never heard of. It is not retried and escapes
    /// unchanged, and the slot is given up unwritten.
    func testACustomRevalidationErrorAfterAResynchronizationIsNotRetried() async throws {
        let processor = OBDMessageProcessor()
        let wire = FakeAdapterWire(processor: processor)
        let exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
        let adapter = UUID()

        wire.respond = { _ in nil }
        _ = try? await exchange.send("22028D", retries: 1, responseTimeout: 0.03) { wire.target(adapter) }
        XCTAssertTrue(processor.isStreamDirty, "precondition: the next send resynchronizes first")
        wire.respond = { $0 == "ATRV" ? "14.1V\r\r>" : ($0 == "04" ? "44\r\r>" : nil) }

        let checks = Counter()
        let check: () throws -> Void = {
            if checks.increment() >= 2 { throw CustomBindingError.refused }
        }
        do {
            _ = try await exchange.send("04", retries: 3, responseTimeout: 1) {
                try check()
                return wire.target(adapter, revalidate: check)
            }
            XCTFail("expected the binding's own error")
        } catch {
            XCTAssertEqual(error as? CustomBindingError, .refused, "\(error)")
        }
        XCTAssertEqual(checks.value, 2, "one attempt: its start, and its revalidation")
        XCTAssertEqual(wire.written, ["22028D", "ATRV"], "04 never reached the writer")
        XCTAssertFalse(processor.isStreamDirty, "nothing was written for the clear")
    }
}

// MARK: - Coordinator: the first-write gate

final class BLEFirstWriteGateCoordinatorTests: XCTestCase {
    func testARefusingGateWritesNothingAndLeavesTheSessionUsable() async throws {
        for mode in [BLEWriteMode.withResponse, .withoutResponse] {
            let deadlines = GateDeadlineScheduler()
            let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
            let transport = ScriptedGateTransport(maximumLength: 20)
            let session = coordinator.activateSession()
            let gateCalls = Counter()
            // Acknowledged at once, so a gate that is ignored shows up as a write, not a hang.
            transport.onWrite = { _, _ in coordinator.didReceiveAcknowledgement(session: session, error: nil) }

            do {
                try await coordinator.write(
                    Data("04\r".utf8), mode: mode, session: session, transport: transport,
                    deadlineAt: farFromNow(),
                    firstWriteGate: { _ in
                        _ = gateCalls.increment()
                        throw CustomBindingError.refused
                    }
                )
                XCTFail("expected the refusal: \(mode)")
            } catch let refusal as BLEFirstWriteRefused {
                XCTAssertEqual(refusal.underlying as? CustomBindingError, .refused, "\(mode)")
            } catch {
                XCTFail("expected BLEFirstWriteRefused, got \(error): \(mode)")
            }
            XCTAssertEqual(gateCalls.value, 1, "\(mode)")
            XCTAssertEqual(transport.writeAttempts, 0, "\(mode)")
            XCTAssertTrue(deadlines.allCancelled, "the deadline timer is cancelled: \(mode)")

            // Not poisoned, no transfer left behind: the next write goes out.
            try await coordinator.write(
                Data("0100\r".utf8), mode: mode, session: session, transport: transport, deadlineAt: farFromNow()
            )
            XCTAssertEqual(transport.writes.map(Array.init), [Array("0100\r".utf8)], "\(mode)")
        }
    }

    func testAPassingGateWritesTheFirstChunkInsideIt() async throws {
        for mode in [BLEWriteMode.withResponse, .withoutResponse] {
            let coordinator = BLEWriteCoordinator(deadlineScheduler: GateDeadlineScheduler().scheduler)
            let transport = ScriptedGateTransport(maximumLength: 20)
            let session = coordinator.activateSession()
            let insideGate = LockedValue(false)
            let writesInsideGate = Counter()
            transport.onWrite = { _, _ in
                if insideGate.get() { _ = writesInsideGate.increment() }
                coordinator.didReceiveAcknowledgement(session: session, error: nil)
            }

            try await coordinator.write(
                Data("04\r".utf8), mode: mode, session: session, transport: transport,
                deadlineAt: farFromNow(),
                firstWriteGate: { submit in
                    insideGate.set(true)
                    defer { insideGate.set(false) }
                    try submit()
                }
            )
            XCTAssertEqual(transport.writes.map(Array.init), [Array("04\r".utf8)], "\(mode)")
            XCTAssertEqual(writesInsideGate.value, 1, "\(mode)")
        }
    }

    /// The transport failing inside the gate is a transport failure, exactly as without a gate:
    /// the session is poisoned. It is never mistaken for a refusal.
    func testATransportErrorInsideTheGateIsStillATransportFailure() async throws {
        for mode in [BLEWriteMode.withResponse, .withoutResponse] {
            let coordinator = BLEWriteCoordinator(deadlineScheduler: GateDeadlineScheduler().scheduler)
            let transport = ScriptedGateTransport(maximumLength: 20)
            transport.errorOnWriteNumber = 1
            let session = coordinator.activateSession()

            do {
                try await coordinator.write(
                    Data("04\r".utf8), mode: mode, session: session, transport: transport,
                    deadlineAt: farFromNow(),
                    firstWriteGate: { submit in try submit() }
                )
                XCTFail("expected the transport failure: \(mode)")
            } catch {
                XCTAssertEqual(
                    error as? BLEWriteCoordinatorError, .transportWriteFailed("transport failed"), "\(mode): \(error)"
                )
            }
            XCTAssertEqual(transport.writeAttempts, 1, "\(mode)")

            do {
                try await coordinator.write(
                    Data("0100\r".utf8), mode: mode, session: session, transport: transport, deadlineAt: farFromNow()
                )
                XCTFail("expected the poisoned channel: \(mode)")
            } catch {
                XCTAssertEqual(error as? BLEWriteCoordinatorError, .channelPoisoned, "\(mode)")
            }
        }
    }

    /// Only the first chunk is gated: a prefix can't be recalled, so later chunks go out as
    /// they always did.
    func testAMultiChunkPayloadGatesOnlyTheFirstChunk() async throws {
        for mode in [BLEWriteMode.withResponse, .withoutResponse] {
            let coordinator = BLEWriteCoordinator(deadlineScheduler: GateDeadlineScheduler().scheduler)
            let transport = ScriptedGateTransport(maximumLength: 2)
            let session = coordinator.activateSession()
            let gateCalls = Counter()
            let insideGate = LockedValue(false)
            let chunksInsideGate = LockedValue<[Data]>([])
            transport.onWrite = { data, _ in
                if insideGate.get() { chunksInsideGate.mutate { $0.append(data) } }
                coordinator.didReceiveAcknowledgement(session: session, error: nil)
            }

            try await coordinator.write(
                Data("ATRV\r".utf8), mode: mode, session: session, transport: transport,
                deadlineAt: farFromNow(),
                firstWriteGate: { submit in
                    _ = gateCalls.increment()
                    insideGate.set(true)
                    defer { insideGate.set(false) }
                    try submit()
                }
            )
            XCTAssertEqual(gateCalls.value, 1, "\(mode)")
            XCTAssertEqual(chunksInsideGate.get().map(Array.init), [Array("AT".utf8)], "\(mode)")
            XCTAssertEqual(transport.writes.map(Array.init), [
                Array("AT".utf8), Array("RV".utf8), Array("\r".utf8),
            ], "\(mode)")
        }
    }

    /// A transfer whose instant has passed ends as it always did, without asking the gate.
    func testTheGateIsNotConsultedOnceTheDeadlineHasPassed() async throws {
        // Passed before the executor reached the write.
        do {
            let clock = GateWriteClock()
            let coordinator = BLEWriteCoordinator(deadlineScheduler: GateDeadlineScheduler().scheduler, now: clock.now)
            let transport = ScriptedGateTransport(maximumLength: 20)
            let session = coordinator.activateSession()
            let gateCalls = Counter()
            let instant = clock.time
            clock.time += 0.5
            do {
                try await coordinator.write(
                    Data("04\r".utf8), mode: .withoutResponse, session: session, transport: transport,
                    deadlineAt: instant,
                    firstWriteGate: { submit in _ = gateCalls.increment(); try submit() }
                )
                XCTFail("expected the expiry")
            } catch {
                XCTAssertEqual(error as? BLEWriteCoordinatorError, .deadlineExceededBeforeWrite)
            }
            XCTAssertEqual(gateCalls.value, 0)
            XCTAssertEqual(transport.writeAttempts, 0)
        }

        // Passed while the executor was busy before the first chunk.
        do {
            let clock = GateWriteClock()
            let coordinator = BLEWriteCoordinator(deadlineScheduler: GateDeadlineScheduler().scheduler, now: clock.now)
            let transport = ScriptedGateTransport(maximumLength: 20)
            let queried = transport.blockNextMaximumLengthQuery()
            let session = coordinator.activateSession()
            let gateCalls = Counter()
            let deadlineAt = clock.time + 1
            let task = Task {
                try await coordinator.write(
                    Data("04\r".utf8), mode: .withResponse, session: session, transport: transport,
                    deadlineAt: deadlineAt,
                    firstWriteGate: { submit in _ = gateCalls.increment(); try submit() }
                )
            }
            await queried.entered.value
            clock.time = deadlineAt + 0.5
            queried.release()
            do {
                try await task.value
                XCTFail("expected the expiry")
            } catch {
                XCTAssertEqual(error as? BLEWriteCoordinatorError, .deadlineExceededBeforeWrite)
            }
            XCTAssertEqual(gateCalls.value, 0)
            XCTAssertEqual(transport.writeAttempts, 0)
        }
    }

    /// Cancelled while waiting for flow control, with a gate set: exactly as without one
    /// (cancellation, the session poisoned), and the gate is never asked.
    func testCancellationWhileWaitingForFlowControlIsUnchangedByAGate() async throws {
        let coordinator = BLEWriteCoordinator(deadlineScheduler: GateDeadlineScheduler().scheduler)
        let transport = ScriptedGateTransport(maximumLength: 20)
        transport.canSend = false
        let flowControlChecked = transport.expectFlowControlRefusal()
        let session = coordinator.activateSession()
        let gateCalls = Counter()
        let task = Task {
            try await coordinator.write(
                Data("04\r".utf8), mode: .withoutResponse, session: session, transport: transport,
                deadlineAt: farFromNow(),
                firstWriteGate: { submit in _ = gateCalls.increment(); try submit() }
            )
        }
        await flowControlChecked.value
        await coordinator.drainEvents()

        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        transport.canSend = true
        coordinator.peripheralIsReady(session: session)
        await coordinator.drainEvents()
        XCTAssertEqual(gateCalls.value, 0)
        XCTAssertEqual(transport.writeAttempts, 0)

        do {
            try await coordinator.write(
                Data("0100\r".utf8), mode: .withoutResponse, session: session, transport: transport,
                deadlineAt: farFromNow()
            )
            XCTFail("expected the poisoned channel, as before")
        } catch {
            XCTAssertEqual(error as? BLEWriteCoordinatorError, .channelPoisoned)
        }
    }

    private func farFromNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime + 60 }
}

// MARK: - P2-4: reading the link record never changes it

final class OBDVehicleLinkRecordReadTests: XCTestCase {
    /// An entry published on connection epoch B is read while the transport still reports epoch
    /// A (the publish and the transport's own update raced). That read says "no link", and must
    /// not erase the entry: once the transport reports B the link is there.
    func testAReadAgainstAnOlderConnectionNeverErasesANewerEntry() async throws {
        let comm = LinkScriptedComm()
        let adapter = ELM327(comm: comm)
        let record = OBDVehicleLinkRecord()
        let epochA = comm.adapterConnection
        var epochB = epochA
        epochB.epoch = (epochA.epoch ?? 0) &+ 1
        let link = OBDVehicleLink(id: UUID(), vin: nil, adapterID: nil)

        record.publish(link, adapter: adapter, connection: epochB)

        XCTAssertNil(record.currentLink(adapter: adapter), "the transport is still on A")
        XCTAssertFalse(record.isCurrent(link, adapter: adapter))
        XCTAssertNil(record.currentLink(adapter: adapter), "and keeps saying so while it is")

        comm.setEpoch(epochB.epoch ?? 0)
        XCTAssertEqual(record.currentLink(adapter: adapter), link, "the entry survived the reads")
        XCTAssertTrue(record.isCurrent(link, adapter: adapter))
        XCTAssertNoThrow(try record.authorization(for: link, adapter: adapter).check())
    }
}

// MARK: - Support

private enum CustomBindingError: Error, Equatable {
    case refused
}

private struct GateTransportError: LocalizedError {
    var errorDescription: String? { "transport failed" }
}

/// The real link record, exchange, processor and coordinator, and a scripted transport that
/// answers each complete command the way an adapter would, off the coordinator's executor.
private final class BoundClearRig: @unchecked Sendable {
    let comm = LinkScriptedComm()
    let adapter: ELM327
    let record = OBDVehicleLinkRecord()
    let link = OBDVehicleLink(id: UUID(), vin: "TESTVIN0000000001", adapterID: nil)
    let processor = OBDMessageProcessor()
    let exchange: BLECommandExchange
    let coordinator = BLEWriteCoordinator()
    let session: UInt64
    let transport = ScriptedGateTransport(maximumLength: 20)
    let mode: BLEWriteMode
    let peripheral = UUID()
    /// How many attempts resolved a target.
    let attempts = Counter()

    init(mode: BLEWriteMode) {
        self.mode = mode
        adapter = ELM327(comm: comm)
        exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
        session = coordinator.activateSession()
        record.publish(link, adapter: adapter, connection: comm.adapterConnection)
        let processor = processor
        let coordinator = coordinator
        let session = session
        transport.onCommand = { command in
            let answer: String?
            switch command {
            case "04": answer = "44\r\r>"
            case "0100": answer = "7E8064100BE3FA813\r>"
            case "ATRV": answer = "14.1V\r\r>"
            case "ATDPN": answer = "A6\r\r>"
            default: answer = nil
            }
            guard let answer else { return }
            // Off the executor (and off the link record's lock), like a notification.
            DispatchQueue.global().async { processor.processReceivedData(Data(answer.utf8)) }
        }
        transport.onWrite = { _, mode in
            if mode == .withResponse { coordinator.didReceiveAcknowledgement(session: session, error: nil) }
        }
    }

    var authorization: OBDWriteAuthorization { record.authorization(for: link, adapter: adapter) }

    func publishAnotherLink() {
        record.publish(OBDVehicleLink(id: UUID(), vin: link.vin, adapterID: nil), adapter: adapter, connection: comm.adapterConnection)
    }

    /// What `BLEManager.commandTarget` builds: the binding checked when the target is resolved
    /// and again at revalidation, and its `whileAuthorized` as the command's first-write gate.
    func target(authorization: OBDWriteAuthorization?) throws -> BLECommandExchange.Target {
        _ = attempts.increment()
        try authorization?.check()
        let coordinator = coordinator
        let session = session
        let transport = transport
        let mode = mode
        return BLECommandExchange.Target(
            peripheralID: peripheral,
            revalidate: { try authorization?.check() },
            firstWriteGate: authorization?.whileAuthorized
        ) { command, deadlineAt, gate in
            let payload = try BLECommandEncoder.encode(command: command, terminator: "\r")
            try await coordinator.write(
                payload, mode: mode, session: session, transport: transport,
                deadlineAt: deadlineAt, firstWriteGate: gate
            )
        }
    }

    func sendBoundClear(retries: Int, authorization: OBDWriteAuthorization? = nil) async throws -> [String] {
        let authorization = authorization ?? self.authorization
        return try await exchange.send("04", retries: retries, responseTimeout: 1) {
            try target(authorization: authorization)
        }
    }

    func assertRefusedWithoutWriting<E: Error & Equatable>(
        _ clear: Task<[String], Error>,
        expected: E,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let lines = try await clear.value
            XCTFail("expected \(expected), the clear returned \(lines)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, "\(error)", file: file, line: line)
        }
        await coordinator.drainEvents()
        XCTAssertTrue(transport.chunks.isEmpty, "no byte of 04 reached the transport: \(transport.commands)", file: file, line: line)
        XCTAssertEqual(attempts.value, 1, "exactly one attempt", file: file, line: line)
    }

    /// The stream is clean (the next command goes out with no probe ahead of it) and the write
    /// session is not poisoned (that command is written on the same session).
    func assertStreamAndSessionUntouched(file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertFalse(exchange.isStreamDirty, "nothing was written, so nothing is outstanding", file: file, line: line)
        transport.canSend = true
        let lines = try await exchange.send("0100", retries: 1, responseTimeout: 1) {
            try target(authorization: nil)
        }
        XCTAssertEqual(lines, ["7E8064100BE3FA813"], file: file, line: line)
        XCTAssertEqual(transport.commands, ["0100"], "written directly on the same session, no probe", file: file, line: line)
    }
}

private final class FlowControlledClearComm: LinkScriptedComm {
    let rig: BoundClearRig

    init(rig: BoundClearRig) { self.rig = rig }

    override func sendCommand(_ command: String, retries: Int, authorization: OBDWriteAuthorization) async throws -> [String] {
        try await rig.exchange.send(command, retries: retries, responseTimeout: 1) {
            try self.rig.target(authorization: authorization)
        }
    }

    override func disconnectPeripheral() {
        advanceEpoch()
        rig.transport.canSend = true
        rig.coordinator.peripheralIsReady(session: rig.session)
        let drained = DispatchSemaphore(value: 0)
        Task.detached { [rig] in
            await rig.coordinator.drainEvents()
            drained.signal()
        }
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        super.disconnectPeripheral()
    }
}

/// A `BLEWriteTransport` a test scripts: capacity for writes without response, a blockable MTU
/// query, write failures, and observers. Every callback runs outside the transport's lock.
private final class ScriptedGateTransport: BLEWriteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumLength: Int
    private var capacity = true
    private var recordedWrites: [Data] = []
    private var attempts = 0
    private var pendingText = ""
    private var completedCommands: [String] = []
    private var firstWriteAt: Int?
    private var flowControlRefusalObservers: [() -> Void] = []
    private var maximumLengthBlock: (entered: () -> Void, gate: DispatchSemaphore)?

    /// Called for every chunk accepted, with the mode.
    var onWrite: ((Data, BLEWriteMode) -> Void)?
    /// Called with each complete command (up to its carriage return) once all of it was written.
    var onCommand: ((String) -> Void)?
    /// The attempt number (1-based) whose write throws instead of writing.
    var errorOnWriteNumber: Int?
    /// When set, the first accepted chunk takes a number from it, inside the write.
    var sequence: SequenceCounter?

    init(maximumLength: Int) {
        self.maximumLength = maximumLength
    }

    var canSend: Bool {
        get { lock.withLock { capacity } }
        set { lock.withLock { capacity = newValue } }
    }

    var writes: [Data] { lock.withLock { recordedWrites } }
    var chunks: [Data] { writes }
    var writeAttempts: Int { lock.withLock { attempts } }
    /// Every complete command written, in order.
    var commands: [String] { lock.withLock { completedCommands } }
    /// The sequence number the first accepted chunk took, if any chunk was accepted.
    var firstWriteSequence: Int? { lock.withLock { firstWriteAt } }

    /// Resolves the first time the coordinator finds no capacity (it is about to wait for flow
    /// control; drain the coordinator's events to be sure it has).
    func expectFlowControlRefusal() -> Task<Void, Never> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        lock.withLock {
            flowControlRefusalObservers.append { continuation.yield(); continuation.finish() }
        }
        return Task { for await _ in stream { return } }
    }

    /// Holds the next MTU query (on the coordinator's executor) until released.
    func blockNextMaximumLengthQuery() -> (entered: Task<Void, Never>, release: () -> Void) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        lock.withLock {
            maximumLengthBlock = ({ continuation.yield(); continuation.finish() }, gate)
        }
        return (Task { for await _ in stream { return } }, { gate.signal() })
    }

    func maximumWriteValueLength(for _: BLEWriteMode) -> Int {
        let block = lock.withLock { () -> (entered: () -> Void, gate: DispatchSemaphore)? in
            defer { maximumLengthBlock = nil }
            return maximumLengthBlock
        }
        if let block {
            block.entered()
            block.gate.wait()
        }
        return maximumLength
    }

    var canSendWriteWithoutResponse: Bool {
        let (value, observers) = lock.withLock { () -> (Bool, [() -> Void]) in
            guard !capacity else { return (true, []) }
            defer { flowControlRefusalObservers.removeAll() }
            return (false, flowControlRefusalObservers)
        }
        observers.forEach { $0() }
        return value
    }

    func write(_ data: Data, mode: BLEWriteMode) throws {
        let sequenceNumber = lock.withLock { firstWriteAt == nil && attempts + 1 != errorOnWriteNumber } ? sequence?.next() : nil
        let result = lock.withLock { () -> (failed: Bool, commands: [String]) in
            attempts += 1
            if attempts == errorOnWriteNumber { return (true, []) }
            recordedWrites.append(data)
            if firstWriteAt == nil { firstWriteAt = sequenceNumber ?? 0 }
            pendingText += String(decoding: data, as: UTF8.self)
            var finished: [String] = []
            while let end = pendingText.firstIndex(of: "\r") {
                finished.append(String(pendingText[..<end]))
                pendingText = String(pendingText[pendingText.index(after: end)...])
            }
            completedCommands.append(contentsOf: finished)
            return (false, finished)
        }
        if result.failed { throw GateTransportError() }
        onWrite?(data, mode)
        result.commands.forEach { onCommand?($0) }
    }
}

/// A shared, strictly increasing counter: orders events across threads.
private final class SequenceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
}

private final class GateWriteClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var time: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    var now: @Sendable () -> TimeInterval { { [self] in time } }
}

private final class GateDeadlineScheduler: @unchecked Sendable {
    private final class Token: BLEWriteDeadlineToken, @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false
        func cancel() { lock.withLock { isCancelled = true } }
        var cancelled: Bool { lock.withLock { isCancelled } }
    }

    private let lock = NSLock()
    private var tokens: [Token] = []

    var scheduler: BLEWriteDeadlineScheduler {
        // Strong: a scheduler made inline must keep collecting tokens.
        BLEWriteDeadlineScheduler { [self] _, _ in
            let token = Token()
            lock.withLock { tokens.append(token) }
            return token
        }
    }

    /// At least one timer was armed and every one was cancelled.
    var allCancelled: Bool {
        lock.withLock { !tokens.isEmpty && tokens.allSatisfy(\.cancelled) }
    }
}
