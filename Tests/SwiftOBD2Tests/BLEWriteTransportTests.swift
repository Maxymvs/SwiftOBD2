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
                deadline: 3
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
            deadline: 3
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
                deadline: 3
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
                deadline: 3
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
        let token = processor.beginRequest()
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
                deadline: 3
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
                deadline: 3
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
                deadline: 3
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
                deadline: 3
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
                deadline: 3
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
                deadline: 3
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
                deadline: 3
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
                deadline: 3
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
                deadline: 3
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
        for deadline in [0, -.infinity, .infinity, .nan, Double.greatestFiniteMagnitude] {
            let deadlines = ManualDeadlineScheduler()
            let coordinator = BLEWriteCoordinator(deadlineScheduler: deadlines.scheduler)
            let transport = FakeWriteTransport(maximumLength: 20)
            let session = coordinator.activateSession()
            let task = Task {
                try await coordinator.write(
                    Data("ATZ\r".utf8),
                    mode: .withResponse,
                    session: session,
                    transport: transport,
                    deadline: deadline
                )
            }

            await assertThrows(task, BLEWriteCoordinatorError.invalidDeadline)
            XCTAssertTrue(transport.writes.isEmpty)
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

    var scheduler: BLEWriteDeadlineScheduler {
        BLEWriteDeadlineScheduler { [weak self] _, action in
            let token = Token()
            self?.lock.withLock { self?.entries.append(Entry(token: token, action: action)) }
            return token
        }
    }

    func fireAll() {
        let pending = lock.withLock { entries }
        for entry in pending where !entry.token.cancelled { entry.action() }
    }
}
