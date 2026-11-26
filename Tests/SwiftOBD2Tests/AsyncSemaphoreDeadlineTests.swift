//
//  AsyncSemaphoreDeadlineTests.swift
//  SwiftOBD2Tests
//
//  The deadline-bounded wait the manufacturer channel takes the command mutex with: it acquires,
//  times out, cancels, and never loses or grants an extra permit when its deadline races a
//  `signal()`.
//

@testable import SwiftOBD2
import XCTest

final class AsyncSemaphoreDeadlineTests: XCTestCase {
    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Exactly `expected` permits are free and nobody is queued.
    private func assertPermits(_ semaphore: AsyncSemaphore, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        let snapshot = semaphore.snapshot
        XCTAssertEqual(snapshot.available, expected, "free permits", file: file, line: line)
        XCTAssertEqual(snapshot.waiting, 0, "queued waiters", file: file, line: line)
    }

    func testAFreePermitIsTakenAtOnce() async {
        let semaphore = AsyncSemaphore(value: 1)
        let outcome = await semaphore.wait(until: now() + 1)
        XCTAssertEqual(outcome, .acquired)
        assertPermits(semaphore, 0)
        semaphore.signal()
        assertPermits(semaphore, 1)
    }

    func testAPermitReleasedBeforeTheDeadlineIsAcquired() async {
        let semaphore = AsyncSemaphore(value: 1)
        let held = await semaphore.wait()
        XCTAssertTrue(held)
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            semaphore.signal()
        }
        let outcome = await semaphore.wait(until: now() + 2)
        XCTAssertEqual(outcome, .acquired)
        semaphore.signal()
        assertPermits(semaphore, 1)
    }

    func testTheDeadlineEndsTheWaitWithoutAPermit() async {
        let semaphore = AsyncSemaphore(value: 1)
        let held = await semaphore.wait()
        XCTAssertTrue(held)
        let started = now()
        let outcome = await semaphore.wait(until: started + 0.15)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertGreaterThanOrEqual(now() - started, 0.1)
        XCTAssertLessThan(now() - started, 1.5, "bounded by the deadline")
        assertPermits(semaphore, 0)
        // The holder's permit is still the only one.
        semaphore.signal()
        assertPermits(semaphore, 1)
    }

    func testAPassedDeadlineTimesOutWithoutQueuing() async {
        let semaphore = AsyncSemaphore(value: 0)
        let outcome = await semaphore.wait(until: now() - 1)
        XCTAssertEqual(outcome, .timedOut)
        assertPermits(semaphore, 0)
    }

    func testCancellationEndsTheWaitWithoutAPermit() async {
        let semaphore = AsyncSemaphore(value: 0)
        let waiter = Task { await semaphore.wait(until: self.now() + 30) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .cancelled)
        assertPermits(semaphore, 0)
        semaphore.signal()
        assertPermits(semaphore, 1)
    }

    /// A deadline racing a `signal()`: whichever wins, the permit ends up exactly once with the
    /// waiter or back in the semaphore — never lost, never doubled.
    func testATimeoutRacingASignalNeitherLosesNorAddsAPermit() async {
        for iteration in 0..<200 {
            let semaphore = AsyncSemaphore(value: 1)
            let held = await semaphore.wait()
        XCTAssertTrue(held)
            let window = 0.002
            let deadline = now() + window
            let waiter = Task { await semaphore.wait(until: deadline) }
            Task {
                let left = deadline - self.now()
                if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
                semaphore.signal()
            }
            let outcome = await waiter.value
            switch outcome {
            case .acquired:
                // The waiter owns the permit the holder released.
                try? await Task.sleep(nanoseconds: 5_000_000)
                XCTAssertEqual(semaphore.snapshot.available, 0, "iteration \(iteration)")
                semaphore.signal()
            case .timedOut:
                // The holder's signal must have returned the permit.
                for _ in 0..<100 where semaphore.snapshot.available == 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            case .cancelled:
                XCTFail("nobody cancelled")
            }
            assertPermits(semaphore, 1)
            // And exactly one: a second immediate taker would time out.
            let first = await semaphore.wait(until: now())
            let second = await semaphore.wait(until: now())
            XCTAssertEqual(first, .acquired)
            XCTAssertEqual(second, .timedOut)
            semaphore.signal()
        }
    }

    /// The unbounded wait keeps its old contract next to the bounded one.
    func testTheUnboundedWaitStillWorks() async {
        let semaphore = AsyncSemaphore(value: 1)
        let held = await semaphore.wait()
        XCTAssertTrue(held)
        let waiter = Task { await semaphore.wait() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        let acquired = await waiter.value
        XCTAssertFalse(acquired)
        semaphore.signal()
        assertPermits(semaphore, 1)
    }
}
