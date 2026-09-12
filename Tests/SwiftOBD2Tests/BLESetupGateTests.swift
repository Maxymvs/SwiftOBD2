@testable import SwiftOBD2
import Foundation
import XCTest

final class BLESetupGateTests: XCTestCase {
    func testEarlySuccessIsRetainedForLaterWait() async throws {
        let deadlines = SetupManualDeadlineScheduler()
        let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
        let token = gate.begin()
        gate.finish(token: token, result: .success(()))

        try await gate.wait(token: token, timeout: 3)
    }

    func testPrecancelledWaitDoesNotConsumeRetainedEarlySuccess() async throws {
        let deadlines = SetupManualDeadlineScheduler()
        let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
        let token = gate.begin()
        gate.finish(token: token, result: .success(()))
        let latch = SetupTestLatch()
        let started = expectation(description: "task started")
        let wait = Task {
            started.fulfill()
            await latch.wait()
            try await gate.wait(token: token, timeout: 3)
        }
        await fulfillment(of: [started], timeout: 1)

        wait.cancel()
        await latch.open()
        await assertCancellation { try await wait.value }

        try await gate.wait(token: token, timeout: 3)
    }

    func testEarlyFailureIsRetainedForLaterWait() async {
        let deadlines = SetupManualDeadlineScheduler()
        let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
        let token = gate.begin()
        gate.finish(token: token, result: .failure(SetupTestError.failed))

        await assertThrows({ try await gate.wait(token: token, timeout: 3) }, SetupTestError.failed)
    }

    func testStaleTimeoutCannotFinishNewAttempt() async throws {
        let deadlines = SetupManualDeadlineScheduler()
        let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
        let oldToken = gate.begin()
        let oldWait = Task { try await gate.wait(token: oldToken, timeout: 3) }
        await waitForSchedules(1, from: deadlines)

        let newToken = gate.begin()
        await assertThrows({ try await oldWait.value }, BLESetupGateError.superseded)

        deadlines.fire(index: 0)
        gate.finish(token: newToken, result: .success(()))
        try await gate.wait(token: newToken, timeout: 3)
    }

    func testStaleCancellationCannotCloseNewAttempt() async throws {
        let deadlines = SetupManualDeadlineScheduler()
        let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
        let oldToken = gate.begin()
        let oldWait = Task { try await gate.wait(token: oldToken, timeout: 3) }
        await waitForSchedules(1, from: deadlines)

        let newToken = gate.begin()
        oldWait.cancel()
        await assertThrows({ try await oldWait.value }, BLESetupGateError.superseded)

        gate.finish(token: newToken, result: .success(()))
        try await gate.wait(token: newToken, timeout: 3)
    }

    func testDuplicateWaiterFailsWithoutDisturbingFirstWaiter() async throws {
        let deadlines = SetupManualDeadlineScheduler()
        let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
        let token = gate.begin()
        let firstWait = Task { try await gate.wait(token: token, timeout: 3) }
        await waitForSchedules(1, from: deadlines)

        await assertThrows(
            { try await gate.wait(token: token, timeout: 3) },
            BLESetupGateError.waiterAlreadyRegistered
        )

        gate.finish(token: token, result: .success(()))
        try await firstWait.value
    }

    func testCancelledWaitWinsOverLateFinishAndIsRetained() async {
        let deadlines = SetupManualDeadlineScheduler()
        let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
        let token = gate.begin()
        let wait = Task { try await gate.wait(token: token, timeout: 3) }
        await waitForSchedules(1, from: deadlines)

        wait.cancel()
        await assertCancellation { try await wait.value }
        gate.finish(token: token, result: .success(()))
        await assertCancellation { try await gate.wait(token: token, timeout: 3) }
    }

    func testBeginSupersedesAndResolvesExistingWaiter() async {
        let deadlines = SetupManualDeadlineScheduler()
        let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
        let token = gate.begin()
        let wait = Task { try await gate.wait(token: token, timeout: 3) }
        await waitForSchedules(1, from: deadlines)

        _ = gate.begin()

        await assertThrows({ try await wait.value }, BLESetupGateError.superseded)
    }

    func testCloseAndResetTerminatePendingWaiters() async {
        let deadlines = SetupManualDeadlineScheduler()
        let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
        let closeToken = gate.begin()
        let closeWait = Task { try await gate.wait(token: closeToken, timeout: 3) }
        await waitForSchedules(1, from: deadlines)

        gate.close(token: closeToken, with: SetupTestError.closed)
        await assertThrows({ try await closeWait.value }, SetupTestError.closed)

        let resetToken = gate.begin()
        let resetWait = Task { try await gate.wait(token: resetToken, timeout: 3) }
        await waitForSchedules(2, from: deadlines)
        gate.reset(with: SetupTestError.reset)
        await assertThrows({ try await resetWait.value }, SetupTestError.reset)
        XCTAssertFalse(gate.isCurrent(resetToken))
    }

    func testDuplicateAndStaleFinishAreIgnored() async throws {
        let deadlines = SetupManualDeadlineScheduler()
        let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
        let oldToken = gate.begin()
        gate.finish(token: oldToken, result: .success(()))
        gate.finish(token: oldToken, result: .failure(SetupTestError.failed))
        try await gate.wait(token: oldToken, timeout: 3)

        let newToken = gate.begin()
        gate.finish(token: oldToken, result: .failure(SetupTestError.failed))
        gate.finish(token: newToken, result: .success(()))
        try await gate.wait(token: newToken, timeout: 3)
    }

    func testTimeoutIsTerminalAndLateSuccessIsIgnored() async {
        let deadlines = SetupManualDeadlineScheduler()
        let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
        let token = gate.begin()
        let wait = Task { try await gate.wait(token: token, timeout: 3) }
        await waitForSchedules(1, from: deadlines)

        deadlines.fire(index: 0)
        await assertThrows({ try await wait.value }, BLESetupGateError.timedOut)
        gate.finish(token: token, result: .success(()))
        await assertThrows(
            { try await gate.wait(token: token, timeout: 3) },
            BLESetupGateError.timedOut
        )
    }

    func testInvalidTimeoutsFailWithoutRegisteringWaiter() async throws {
        for timeout in [0, -.infinity, .infinity, .nan, Double.greatestFiniteMagnitude] {
            let deadlines = SetupManualDeadlineScheduler()
            let gate = BLESetupGate(deadlineScheduler: deadlines.scheduler)
            let token = gate.begin()
            await assertThrows(
                { try await gate.wait(token: token, timeout: timeout) },
                BLESetupGateError.invalidTimeout
            )
            XCTAssertTrue(gate.isCurrent(token))
            gate.finish(token: token, result: .success(()))
            try await gate.wait(token: token, timeout: 3)
        }
    }

    private func waitForSchedules(
        _ count: Int,
        from scheduler: SetupManualDeadlineScheduler
    ) async {
        let reached = expectation(description: "scheduler reached \(count) entries")
        scheduler.notifyWhenCountReaches(count) { reached.fulfill() }
        await fulfillment(of: [reached], timeout: 1)
    }

    private func assertCancellation(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected CancellationError", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, file: file, line: line)
        }
    }

    private func assertThrows<E: Error & Equatable>(
        _ operation: () async throws -> Void,
        _ expected: E,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }
}

private enum SetupTestError: Error, Equatable {
    case failed
    case closed
    case reset
}

private actor SetupTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class SetupManualDeadlineScheduler: @unchecked Sendable {
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
    private var observers: [(count: Int, action: () -> Void)] = []

    var scheduler: BLEWriteDeadlineScheduler {
        BLEWriteDeadlineScheduler { [weak self] _, action in
            let token = Token()
            let callbacks = self?.lock.withLock { () -> [() -> Void] in
                guard let self else { return [] }
                self.entries.append(Entry(token: token, action: action))
                let callbacks = self.observers.filter { self.entries.count >= $0.count }.map(\.action)
                self.observers.removeAll { self.entries.count >= $0.count }
                return callbacks
            } ?? []
            callbacks.forEach { $0() }
            return token
        }
    }

    func notifyWhenCountReaches(_ count: Int, action: @escaping () -> Void) {
        let shouldRun = lock.withLock { () -> Bool in
            if entries.count >= count { return true }
            observers.append((count, action))
            return false
        }
        if shouldRun { action() }
    }

    func fire(index: Int) {
        let entry = lock.withLock { entries[index] }
        if !entry.token.cancelled { entry.action() }
    }
}
