@testable import SwiftOBD2
import Foundation
import XCTest

final class BLEWriteTransportTests: XCTestCase {
    func testCommandEncoderAppendsConfiguredTerminatorExactlyOnce() throws {
        let payload = try BLECommandEncoder.encode(command: "ATZ", terminator: "\r\n")

        XCTAssertEqual(Array(payload), Array("ATZ\r\n".utf8))
    }

    func testCommandEncoderRejectsInjectedControlCharacters() {
        XCTAssertThrowsError(try BLECommandEncoder.encode(command: "ATZ\rATI", terminator: "\r")) {
            XCTAssertEqual($0 as? BLECommandEncodingError, .controlCharacterInCommand)
        }
        XCTAssertThrowsError(try BLECommandEncoder.encode(command: "ATZ\n", terminator: "\r")) {
            XCTAssertEqual($0 as? BLECommandEncodingError, .controlCharacterInCommand)
        }
    }

    func testCommandEncoderRejectsBlankCommandInsteadOfRepeatingPreviousELMCommand() {
        XCTAssertThrowsError(try BLECommandEncoder.encode(command: "   ", terminator: "\r")) {
            XCTAssertEqual($0 as? BLECommandEncodingError, .emptyCommand)
        }
    }

    func testWithResponseUsesMTUAndWaitsForEachAcknowledgement() async throws {
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
        let transport = FakeWriteTransport(maximumLength: 3)
        let session = coordinator.activateSession()
        let task = Task {
            try await coordinator.write(
                Data("ABCDEFG".utf8),
                mode: .withResponse,
                session: session,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }

        await waitForWrites(1, from: transport)
        XCTAssertEqual(transport.writes.map(Array.init), [Array("ABC".utf8)])

        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        await waitForWrites(2, from: transport)
        XCTAssertEqual(transport.writes.map(Array.init), [Array("ABC".utf8), Array("DEF".utf8)])

        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        await waitForWrites(3, from: transport)
        XCTAssertEqual(transport.writes.map(Array.init), [
            Array("ABC".utf8), Array("DEF".utf8), Array("G".utf8),
        ])

        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        try await task.value
    }

    func testSynchronousAcknowledgementCannotReenterOrReorderWrites() async throws {
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
        let transport = FakeWriteTransport(maximumLength: 2)
        let session = coordinator.activateSession()
        transport.onWrite = { _, _ in
            coordinator.didReceiveAcknowledgement(session: session, error: nil)
        }

        try await coordinator.write(
            Data("ABCDE".utf8),
            mode: .withResponse,
            session: session,
            transport: transport,
            deadlineAt: farFromNow()
        )

        XCTAssertEqual(transport.writes.map(Array.init), [
            Array("AB".utf8), Array("CD".utf8), Array("E".utf8),
        ])
    }

    func testAcknowledgementErrorTerminatesOnceWithoutSendingAnotherChunk() async {
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
        let transport = FakeWriteTransport(maximumLength: 2)
        let session = coordinator.activateSession()
        let task = Task {
            try await coordinator.write(
                Data("ABCD".utf8),
                mode: .withResponse,
                session: session,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }

        await waitForWrites(1, from: transport)
        coordinator.didReceiveAcknowledgement(session: session, error: StableAckError())
        await assertThrows(
            task,
            BLEWriteCoordinatorError.acknowledgementFailed("rejected")
        )

        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        await coordinator.drainEvents()
        XCTAssertEqual(transport.writes.map(Array.init), [Array("AB".utf8)])
    }

    func testTransportThrowAfterPartialWriteTerminatesWithoutFurtherChunks() async {
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
        let transport = FakeWriteTransport(maximumLength: 2)
        transport.errorOnWriteNumber = 2
        let session = coordinator.activateSession()
        let task = Task {
            try await coordinator.write(
                Data("ABCDEF".utf8),
                mode: .withResponse,
                session: session,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }

        await waitForWrites(1, from: transport)
        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        await assertThrows(
            task,
            BLEWriteCoordinatorError.transportWriteFailed("transport failed")
        )
        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        await coordinator.drainEvents()
        XCTAssertEqual(transport.writeAttempts, 2)
        XCTAssertEqual(transport.writes.map(Array.init), [Array("AB".utf8)])
    }

    func testResponseArrivingBeforeFinalWriteAckRemainsAvailableToArmedRequest() async throws {
        let processor = OBDMessageProcessor()
        let token = try processor.beginRequest()
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
        let transport = FakeWriteTransport(maximumLength: 2)
        let session = coordinator.activateSession()
        let writeTask = Task {
            try await coordinator.write(
                Data("010C\r".utf8),
                mode: .withResponse,
                session: session,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }

        await waitForWrites(1, from: transport)
        processor.processReceivedData(Data("41 0C 1A F8\r>".utf8))

        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        await waitForWrites(2, from: transport)
        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        await waitForWrites(3, from: transport)
        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        try await writeTask.value

        let response = try await processor.awaitResponse(for: token, timeout: 0.1)
        XCTAssertEqual(response, ["41 0C 1A F8"])
    }

    func testWithoutResponseWaitsForCapacityAndReadyCallback() async throws {
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
        let transport = FakeWriteTransport(maximumLength: 2, canSend: false)
        transport.blockAfterEveryWrite = true
        let session = coordinator.activateSession()
        let task = Task {
            try await coordinator.write(
                Data("ABCDE".utf8),
                mode: .withoutResponse,
                session: session,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }

        await waitForTransportStart(transport)
        await coordinator.drainEvents()
        XCTAssertTrue(transport.writes.isEmpty)

        for expectedCount in 1 ... 3 {
            transport.canSend = true
            coordinator.peripheralIsReady(session: session)
            await waitForWrites(expectedCount, from: transport)
        }

        try await task.value
        XCTAssertEqual(transport.writes.map(Array.init), [
            Array("AB".utf8), Array("CD".utf8), Array("E".utf8),
        ])
    }

    func testConcurrentReadyCallbacksDoNotSendAChunkTwice() async throws {
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
        let transport = FakeWriteTransport(maximumLength: 1, canSend: false)
        transport.blockAfterEveryWrite = true
        let session = coordinator.activateSession()
        let task = Task {
            try await coordinator.write(
                Data("AB".utf8),
                mode: .withoutResponse,
                session: session,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }

        await waitForTransportStart(transport)
        await coordinator.drainEvents()
        transport.canSend = true
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            coordinator.peripheralIsReady(session: session)
        }
        await waitForWrites(1, from: transport)
        await coordinator.drainEvents()
        XCTAssertEqual(transport.writes.map(Array.init), [Array("A".utf8)])

        transport.canSend = true
        coordinator.peripheralIsReady(session: session)
        try await task.value
        XCTAssertEqual(transport.writes.map(Array.init), [Array("A".utf8), Array("B".utf8)])
    }

    func testDeadlineCancelsTransferPoisonsSessionAndIgnoresLateAck() async {
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
        let transport = FakeWriteTransport(maximumLength: 2)
        let session = coordinator.activateSession()
        let task = Task {
            try await coordinator.write(
                Data("ABCD".utf8),
                mode: .withResponse,
                session: session,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }

        await waitForWrites(1, from: transport)
        deadlines.fireAll()
        await assertThrows(task, BLEWriteCoordinatorError.deadlineExceeded)

        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        await coordinator.drainEvents()
        XCTAssertEqual(transport.writes.count, 1)

        let retry = Task {
            try await coordinator.write(
                Data("EF".utf8),
                mode: .withResponse,
                session: session,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }
        await assertThrows(retry, BLEWriteCoordinatorError.channelPoisoned)
        XCTAssertEqual(transport.writes.count, 1)
    }

    func testCancellationCompletesOncePoisonsSessionAndIgnoresLateCallbacks() async {
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
        let transport = FakeWriteTransport(maximumLength: 2)
        let session = coordinator.activateSession()
        let task = Task {
            try await coordinator.write(
                Data("ABCD".utf8),
                mode: .withResponse,
                session: session,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }

        await waitForWrites(1, from: transport)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        coordinator.peripheralIsReady(session: session)
        await coordinator.drainEvents()
        XCTAssertEqual(transport.writes.count, 1)
    }

    func testCancellationRacingInitialDispatchCannotSendFirstChunk() async {
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
        let transport = FakeWriteTransport(maximumLength: 2)
        let entered = expectation(description: "MTU query entered")
        let releaseQuery = transport.blockMaximumLengthQuery { entered.fulfill() }
        let session = coordinator.activateSession()
        let task = Task {
            try await coordinator.write(
                Data("AB".utf8),
                mode: .withResponse,
                session: session,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }

        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        releaseQuery()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testDisconnectInvalidatesTransferAndOldAckCannotAdvanceNewSession() async throws {
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
        let transport = FakeWriteTransport(maximumLength: 2)
        let oldSession = coordinator.activateSession()
        let oldTask = Task {
            try await coordinator.write(
                Data("ABCD".utf8),
                mode: .withResponse,
                session: oldSession,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }
        await waitForWrites(1, from: transport)

        coordinator.invalidateSession(oldSession, with: TestError.disconnected)
        await assertThrows(oldTask, TestError.disconnected)

        let newSession = coordinator.activateSession()
        let newTask = Task {
            try await coordinator.write(
                Data("EFGH".utf8),
                mode: .withResponse,
                session: newSession,
                transport: transport,
                deadlineAt: farFromNow()
            )
        }
        await waitForWrites(2, from: transport)

        coordinator.didReceiveAcknowledgement(session: oldSession, error: nil)
        await coordinator.drainEvents()
        XCTAssertEqual(transport.writes.count, 2)

        coordinator.didReceiveAcknowledgement(session: newSession, error: nil)
        await waitForWrites(3, from: transport)
        coordinator.didReceiveAcknowledgement(session: newSession, error: nil)
        try await newTask.value
    }

    func testInvalidAndUnrepresentableDeadlinesFailBeforeWriting() async {
        let clock = ManualWriteClock()
        let tooFar = clock.time + BLEWriteCoordinator.maximumSupportedDeadline + 1
        for deadlineAt in [-.infinity, .infinity, .nan, Double.greatestFiniteMagnitude, tooFar] {
            let deadlines = ManualDeadlineScheduler()
            let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler, now: clock.now)
            let transport = FakeWriteTransport(maximumLength: 20)
            let session = coordinator.activateSession()
            let task = Task {
                try await coordinator.write(
                    Data("ATZ\r".utf8),
                    mode: .withResponse,
                    session: session,
                    transport: transport,
                    deadlineAt: deadlineAt
                )
            }

            await assertThrows(task, BLEWriteCoordinatorError.invalidDeadline)
            XCTAssertTrue(transport.writes.isEmpty)
            XCTAssertTrue(deadlines.intervals.isEmpty)
        }
    }

    // MARK: The absolute instant

    /// An in-time write behaves exactly as before: same chunks, same order, one acknowledgement
    /// each, and the timer armed for the time left.
    func testInTimeWriteIsUnchanged() async throws {
        let clock = ManualWriteClock()
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler, now: clock.now)
        let transport = FakeWriteTransport(maximumLength: 3)
        let session = coordinator.activateSession()
        let task = Task {
            try await coordinator.write(
                Data("ABCDEFG".utf8), mode: .withResponse, session: session,
                transport: transport, deadlineAt: clock.time + 3
            )
        }

        for expected in 1 ... 3 {
            await waitForWrites(expected, from: transport)
            coordinator.didReceiveAcknowledgement(session: session, error: nil)
        }
        try await task.value
        XCTAssertEqual(transport.writes.map(Array.init), [
            Array("ABC".utf8), Array("DEF".utf8), Array("G".utf8),
        ])
        XCTAssertEqual(deadlines.intervals, [3])

        // Not poisoned: the next command goes out normally.
        transport.onWrite = { _, _ in coordinator.didReceiveAcknowledgement(session: session, error: nil) }
        try await coordinator.write(
            Data("H".utf8), mode: .withResponse, session: session,
            transport: transport, deadlineAt: clock.time + 3
        )
        XCTAssertEqual(transport.writes.count, 4)
    }

    /// The executor got to the write only after the caller's instant had passed (it sat queued
    /// behind other work). Nothing may be written, and since nothing was, the stream is intact
    /// and the session stays usable.
    func testWriteReachingTheExecutorAfterItsInstantWritesNothing() async throws {
        for mode in [BLEWriteMode.withResponse, .withoutResponse] {
            let clock = ManualWriteClock()
            let deadlines = ManualDeadlineScheduler()
            let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler, now: clock.now)
            let transport = FakeWriteTransport(maximumLength: 20)
            let session = coordinator.activateSession()
            let instant = clock.time
            clock.time += 0.5

            let late = Task {
                try await coordinator.write(
                    Data("22028D\r".utf8), mode: mode, session: session,
                    transport: transport, deadlineAt: instant
                )
            }
            // Nothing was handed to the transport: the "wrote nothing" flavour of the expiry.
            await assertThrows(late, BLEWriteCoordinatorError.deadlineExceededBeforeWrite)
            XCTAssertTrue(transport.writes.isEmpty, "\(mode)")
            XCTAssertTrue(deadlines.intervals.isEmpty, "no timer for a write that never started: \(mode)")

            transport.onWrite = { _, _ in coordinator.didReceiveAcknowledgement(session: session, error: nil) }
            try await coordinator.write(
                Data("0100\r".utf8), mode: mode, session: session,
                transport: transport, deadlineAt: clock.time + 1
            )
            XCTAssertEqual(transport.writes.map(Array.init), [Array("0100\r".utf8)], "\(mode)")
        }
    }

    /// Time the coordinator spends before the first physical write (here a slow MTU query) is
    /// charged to the caller's instant: past it, the first chunk is not written.
    func testInstantPassingBeforeTheFirstChunkWritesNothing() async throws {
        let clock = ManualWriteClock()
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler, now: clock.now)
        let transport = FakeWriteTransport(maximumLength: 20)
        let entered = expectation(description: "MTU query entered")
        let releaseQuery = transport.blockMaximumLengthQuery { entered.fulfill() }
        let session = coordinator.activateSession()
        transport.onWrite = { _, _ in coordinator.didReceiveAcknowledgement(session: session, error: nil) }
        let deadlineAt = clock.time + 1
        let task = Task {
            try await coordinator.write(
                Data("22028D\r".utf8), mode: .withResponse, session: session,
                transport: transport, deadlineAt: deadlineAt
            )
        }

        await fulfillment(of: [entered], timeout: 1)
        clock.time = deadlineAt + 0.5
        releaseQuery()
        await assertThrows(task, BLEWriteCoordinatorError.deadlineExceededBeforeWrite)
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertEqual(transport.writeAttempts, 0)

        // Zero chunks reached the wire, so the session is not poisoned.
        let nextTransport = FakeWriteTransport(maximumLength: 20)
        nextTransport.onWrite = { _, _ in coordinator.didReceiveAcknowledgement(session: session, error: nil) }
        try await coordinator.write(
            Data("0100\r".utf8), mode: .withResponse, session: session,
            transport: nextTransport, deadlineAt: clock.time + 1
        )
        XCTAssertEqual(nextTransport.writes.count, 1)
    }

    /// With response: the instant passes while the first chunk's acknowledgement is pending. The
    /// acknowledgement must not release the next chunk, and because a prefix is on the wire the
    /// session is poisoned.
    func testInstantPassingBetweenAcknowledgedChunksStopsBeforeTheNextWrite() async {
        let clock = ManualWriteClock()
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler, now: clock.now)
        let transport = FakeWriteTransport(maximumLength: 2)
        let session = coordinator.activateSession()
        let deadlineAt = clock.time + 1
        // Each chunk is acknowledged at once; the clock reaches the instant as the first one is
        // written, so the acknowledgement arrives after it.
        transport.onWrite = { _, _ in
            clock.time = deadlineAt
            coordinator.didReceiveAcknowledgement(session: session, error: nil)
        }
        let task = Task {
            try await coordinator.write(
                Data("ABCDEF".utf8), mode: .withResponse, session: session,
                transport: transport, deadlineAt: deadlineAt
            )
        }

        await assertThrows(task, BLEWriteCoordinatorError.deadlineExceeded)
        transport.onWrite = { _, _ in coordinator.didReceiveAcknowledgement(session: session, error: nil) }

        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        await coordinator.drainEvents()
        XCTAssertEqual(transport.writes.map(Array.init), [Array("AB".utf8)])
        XCTAssertEqual(transport.writeAttempts, 1)

        let next = Task {
            try await coordinator.write(
                Data("EF".utf8), mode: .withResponse, session: session,
                transport: transport, deadlineAt: clock.time + 1
            )
        }
        await assertThrows(next, BLEWriteCoordinatorError.channelPoisoned)
        XCTAssertEqual(transport.writes.count, 1)
    }

    /// Without response: the instant passes while waiting for flow control after the first
    /// chunk. The ready callback must not release the next chunk.
    func testInstantPassingBetweenFlowControlledChunksStopsBeforeTheNextWrite() async {
        let clock = ManualWriteClock()
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler, now: clock.now)
        let transport = FakeWriteTransport(maximumLength: 2, canSend: false)
        transport.blockAfterEveryWrite = true
        let session = coordinator.activateSession()
        let deadlineAt = clock.time + 1
        let task = Task {
            try await coordinator.write(
                Data("ABCDEF".utf8), mode: .withoutResponse, session: session,
                transport: transport, deadlineAt: deadlineAt
            )
        }

        await waitForTransportStart(transport)
        await coordinator.drainEvents()
        transport.canSend = true
        coordinator.peripheralIsReady(session: session)
        await waitForWrites(1, from: transport)
        await coordinator.drainEvents()

        // From here the peripheral would take every remaining chunk without pausing.
        clock.time = deadlineAt + 0.01
        transport.blockAfterEveryWrite = false
        transport.canSend = true
        coordinator.peripheralIsReady(session: session)
        await assertThrows(task, BLEWriteCoordinatorError.deadlineExceeded)
        XCTAssertEqual(transport.writes.map(Array.init), [Array("AB".utf8)])

        let next = Task {
            try await coordinator.write(
                Data("GH".utf8), mode: .withoutResponse, session: session,
                transport: transport, deadlineAt: clock.time + 1
            )
        }
        await assertThrows(next, BLEWriteCoordinatorError.channelPoisoned)
        XCTAssertEqual(transport.writes.count, 1)
    }

    /// The timer covers what is left of the caller's budget when it is armed, not a fresh full
    /// interval counted from whenever the executor got round to it.
    func testDeadlineTimerIsArmedForTheRemainingTime() async throws {
        let clock = ManualWriteClock()
        let deadlines = ManualDeadlineScheduler()
        let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler, now: clock.now)
        let transport = FakeWriteTransport(maximumLength: 20)
        let entered = expectation(description: "MTU query entered")
        let releaseQuery = transport.blockMaximumLengthQuery { entered.fulfill() }
        let session = coordinator.activateSession()
        let deadlineAt = clock.time + 3
        let task = Task {
            try await coordinator.write(
                Data("ATRV\r".utf8), mode: .withResponse, session: session,
                transport: transport, deadlineAt: deadlineAt
            )
        }

        await fulfillment(of: [entered], timeout: 1)
        clock.time += 2
        releaseQuery()
        await waitForWrites(1, from: transport)
        XCTAssertEqual(deadlines.intervals.count, 1)
        XCTAssertEqual(deadlines.intervals.first ?? .nan, 1, accuracy: 1e-9)

        coordinator.didReceiveAcknowledgement(session: session, error: nil)
        try await task.value
    }

    /// The deadline timer fires in both states: before any chunk reached the transport (here,
    /// waiting for flow control) it reports "wrote nothing" and leaves the session usable; after
    /// a chunk was submitted it reports the plain expiry and poisons the session.
    func testTimerExpiryDistinguishesNothingWrittenFromAPrefixWritten() async throws {
        // Zero chunks submitted.
        do {
            let deadlines = ManualDeadlineScheduler()
            let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
            let transport = FakeWriteTransport(maximumLength: 2, canSend: false)
            let session = coordinator.activateSession()
            let task = Task {
                try await coordinator.write(
                    Data("ATRV\r".utf8), mode: .withoutResponse, session: session,
                    transport: transport, deadlineAt: farFromNow()
                )
            }
            await waitForTransportStart(transport)
            await coordinator.drainEvents()
            deadlines.fireAll()
            await assertThrows(task, BLEWriteCoordinatorError.deadlineExceededBeforeWrite)
            XCTAssertEqual(transport.writeAttempts, 0)
            XCTAssertTrue(BLEWriteCoordinatorError.deadlineExceededBeforeWrite.wroteNothing)
            XCTAssertTrue(BLEWriteCoordinatorError.deadlineExceededBeforeWrite.isDeadlineExpiry)

            transport.canSend = true
            try await coordinator.write(
                Data("ATDPN\r".utf8), mode: .withoutResponse, session: session,
                transport: transport, deadlineAt: farFromNow()
            )
            XCTAssertEqual(transport.writes.count, 3, "the session was not poisoned")
        }

        // One chunk submitted.
        do {
            let deadlines = ManualDeadlineScheduler()
            let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
            let transport = FakeWriteTransport(maximumLength: 2, canSend: true)
            transport.blockAfterEveryWrite = true
            let session = coordinator.activateSession()
            let task = Task {
                try await coordinator.write(
                    Data("ATRV\r".utf8), mode: .withoutResponse, session: session,
                    transport: transport, deadlineAt: farFromNow()
                )
            }
            await waitForWrites(1, from: transport)
            await coordinator.drainEvents()
            deadlines.fireAll()
            await assertThrows(task, BLEWriteCoordinatorError.deadlineExceeded)
            XCTAssertFalse(BLEWriteCoordinatorError.deadlineExceeded.wroteNothing)
            XCTAssertTrue(BLEWriteCoordinatorError.deadlineExceeded.isDeadlineExpiry)

            transport.canSend = true
            transport.blockAfterEveryWrite = false
            let next = Task {
                try await coordinator.write(
                    Data("AT".utf8), mode: .withoutResponse, session: session,
                    transport: transport, deadlineAt: farFromNow()
                )
            }
            await assertThrows(next, BLEWriteCoordinatorError.channelPoisoned)
        }
    }

    private func assertThrows<E: Error & Equatable>(
        _ task: Task<Void, Error>,
        _ expected: E,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }

    private func waitForWrites(_ count: Int, from transport: FakeWriteTransport) async {
        let reached = expectation(description: "transport reached \(count) writes")
        transport.notifyWhenWriteCountReaches(count) { reached.fulfill() }
        await fulfillment(of: [reached], timeout: 1)
    }

    /// An instant no test reaches with the live clock.
    private func farFromNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime + 60
    }

    private func waitForTransportStart(_ transport: FakeWriteTransport) async {
        let started = expectation(description: "transport MTU queried")
        transport.notifyWhenMaximumLengthIsQueried { started.fulfill() }
        await fulfillment(of: [started], timeout: 1)
    }
}

private enum TestError: Error, Equatable {
    case disconnected
}

private struct StableAckError: LocalizedError {
    var errorDescription: String? { "rejected" }
}

private struct StableTransportError: LocalizedError {
    var errorDescription: String? { "transport failed" }
}

private final class FakeWriteTransport: BLEWriteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumLength: Int
    private var capacity: Bool
    private var recordedWrites: [Data] = []
    private var attempts = 0
    private var writeObservers: [(count: Int, action: () -> Void)] = []
    private var maximumLengthWasQueried = false
    private var maximumLengthObservers: [() -> Void] = []
    private var maximumLengthGate: DispatchSemaphore?
    private var maximumLengthEntered: (() -> Void)?
    var onWrite: ((Data, BLEWriteMode) -> Void)?
    var blockAfterEveryWrite = false
    var errorOnWriteNumber: Int?

    init(maximumLength: Int, canSend: Bool = true) {
        self.maximumLength = maximumLength
        capacity = canSend
    }

    func maximumWriteValueLength(for _: BLEWriteMode) -> Int {
        let state = lock.withLock { () -> ([() -> Void], DispatchSemaphore?, (() -> Void)?) in
            maximumLengthWasQueried = true
            defer { maximumLengthObservers.removeAll() }
            return (maximumLengthObservers, maximumLengthGate, maximumLengthEntered)
        }
        state.0.forEach { $0() }
        state.2?()
        state.1?.wait()
        return maximumLength
    }

    var canSendWriteWithoutResponse: Bool {
        lock.withLock { capacity }
    }

    var canSend: Bool {
        get { lock.withLock { capacity } }
        set { lock.withLock { capacity = newValue } }
    }

    var writes: [Data] {
        lock.withLock { recordedWrites }
    }

    var writeAttempts: Int {
        lock.withLock { attempts }
    }

    func notifyWhenWriteCountReaches(_ count: Int, action: @escaping () -> Void) {
        let shouldRun = lock.withLock { () -> Bool in
            if recordedWrites.count >= count { return true }
            writeObservers.append((count, action))
            return false
        }
        if shouldRun { action() }
    }

    func notifyWhenMaximumLengthIsQueried(action: @escaping () -> Void) {
        let shouldRun = lock.withLock { () -> Bool in
            if maximumLengthWasQueried { return true }
            maximumLengthObservers.append(action)
            return false
        }
        if shouldRun { action() }
    }

    func blockMaximumLengthQuery(onEntered: @escaping () -> Void) -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock {
            maximumLengthGate = gate
            maximumLengthEntered = onEntered
        }
        return { gate.signal() }
    }

    func write(_ data: Data, mode: BLEWriteMode) throws {
        let result = lock.withLock { () -> (
            failed: Bool,
            writeCallback: ((Data, BLEWriteMode) -> Void)?,
            observers: [() -> Void]
        ) in
            attempts += 1
            if attempts == errorOnWriteNumber { return (true, nil, []) }
            recordedWrites.append(data)
            if blockAfterEveryWrite { capacity = false }
            let observers = writeObservers
                .filter { recordedWrites.count >= $0.count }
                .map(\.action)
            writeObservers.removeAll { recordedWrites.count >= $0.count }
            return (false, onWrite, observers)
        }
        if result.failed { throw StableTransportError() }
        result.writeCallback?(data, mode)
        result.observers.forEach { $0() }
    }
}

/// A monotonic clock that only moves when the test moves it.
private final class ManualWriteClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100

    var time: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    var now: @Sendable () -> TimeInterval { { [self] in time } }
}

private final class ManualDeadlineScheduler: @unchecked Sendable {
    private final class Token: BLEWriteDeadlineToken, @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false

        func cancel() { lock.withLock { isCancelled = true } }
        var cancelled: Bool { lock.withLock { isCancelled } }
    }

    private struct Entry {
        let token: Token
        let action: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var scheduledIntervals: [TimeInterval] = []

    var scheduler: BLEWriteDeadlineScheduler {
        BLEWriteDeadlineScheduler { [weak self] interval, action in
            let token = Token()
            self?.lock.withLock {
                self?.entries.append(Entry(token: token, action: action))
                self?.scheduledIntervals.append(interval)
            }
            return token
        }
    }

    /// The interval each timer was armed with, in order.
    var intervals: [TimeInterval] { lock.withLock { scheduledIntervals } }

    func fireAll() {
        let pending = lock.withLock { entries }
        for entry in pending where !entry.token.cancelled { entry.action() }
    }
}
