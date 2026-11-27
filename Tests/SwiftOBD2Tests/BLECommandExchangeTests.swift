//
//  BLECommandExchangeTests.swift
//  SwiftOBD2Tests
//
//  The Bluetooth exchange the manufacturer channel runs on, without CoreBluetooth: one absolute
//  deadline across the write and the response, and listening without writing. What happens to
//  a late answer after a timed-out slot is in `OBDStreamOwnershipTests`.
//

@testable import SwiftOBD2
import XCTest

final class BLECommandExchangeTests: XCTestCase {
    private let adapter = UUID()
    private var processor: OBDMessageProcessor!
    private var wire: FakeAdapterWire!
    private var exchange: BLECommandExchange!

    override func setUp() {
        super.setUp()
        processor = OBDMessageProcessor()
        wire = FakeAdapterWire(processor: processor)
        exchange = BLECommandExchange(processor: processor, gate: OEMAddressingGate())
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func send(_ command: String, deadline: TimeInterval?, retries: Int = 1) async throws -> [String] {
        try await exchange.send(command, retries: retries, responseTimeout: 3, deadline: deadline, policy: .redacted) {
            wire.target(adapter)
        }
    }

    // MARK: One absolute deadline

    func testNothingIsWrittenOnceTheDeadlineHasPassed() async {
        do {
            _ = try await send("22028D", deadline: now() - 0.01)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout)
            XCTAssertEqual(OEMBatchExecutor.classify(error), .timeout)
        }
        XCTAssertEqual(wire.written, [])
        XCTAssertEqual(wire.writeTimeouts, [], "the write was never started")
    }

    func testTheWriteGetsWhatIsLeftOfTheDeadline() async throws {
        wire.respond = { _ in "7E80562028D0CE2\r>" }
        _ = try await send("22028D", deadline: now() + 0.5)
        let writeTimeout = try XCTUnwrap(wire.writeTimeouts.first)
        XCTAssertLessThanOrEqual(writeTimeout, 0.5)
        XCTAssertGreaterThan(writeTimeout, 0.3)
    }

    /// The response wait gets only what the write left, not a fresh timeout.
    func testTheResponseGetsOnlyWhatTheWriteLeft() async {
        wire.writeLatency = 0.3
        let started = now()
        do {
            _ = try await send("22028D", deadline: started + 0.45)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout)
        }
        XCTAssertLessThan(now() - started, 0.8, "the deadline, not write + a fresh response timeout")
    }

    func testADeadlineBoundSendIsNeverRetransmitted() async {
        wire.respond = { _ in "NO DATA\r\r>" }
        do {
            _ = try await send("22028D", deadline: now() + 2, retries: 3)
            XCTFail("expected NO DATA")
        } catch {
            XCTAssertEqual(error as? BLEManagerError, .noData)
        }
        XCTAssertEqual(wire.written, ["22028D"])
    }

    func testOrdinaryTimingIsUnchanged() async throws {
        wire.respond = { _ in "7E8064100BE3EB811\r>" }
        _ = try await exchange.send("0100", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertEqual(wire.writeTimeouts.count, 1)
        XCTAssertEqual(wire.writeTimeouts.first ?? 0, BLEConstants.defaultTimeout, accuracy: 0.05)
    }

    /// What a write deadline throws is what the executor counts as a timeout, and the armed slot
    /// is given up so late bytes can't answer it. Part of the command may be on the wire, so the
    /// next command goes out only after a probe has answered.
    func testAWriteDeadlineIsATimeoutAndGivesUpTheSlot() async throws {
        wire.writeError = BLEWriteCoordinatorError.deadlineExceeded
        do {
            _ = try await send("22028D", deadline: now() + 1)
            XCTFail("expected the write error")
        } catch {
            XCTAssertEqual(error as? BLEWriteCoordinatorError, .deadlineExceeded)
            XCTAssertEqual(OEMBatchExecutor.classify(error), .timeout)
        }
        XCTAssertTrue(processor.isStreamDirty)
        wire.writeError = BLEWriteCoordinatorError.transportWriteFailed("x")
        do {
            _ = try await send("22028D", deadline: now() + 1)
        } catch {
            XCTAssertEqual(OEMBatchExecutor.classify(error), .linkLost)
        }
        wire.writeError = nil
        // The failed write above was the `ATRV` probe, so some of it may be on the wire and a
        // voltage could be its late answer: the other probe proves the stream.
        wire.respond = { $0 == "ATDPN" ? "A6\r\r>" : "7E80562028D0CE2\r>" }
        let lines = try await send("22028D", deadline: now() + 1)
        XCTAssertEqual(lines, ["7E80562028D0CE2"])
        XCTAssertEqual(wire.written, ["ATDPN", "22028D"])
    }

    // MARK: Authorized at the write

    /// A bound Mode 04 is checked when its target is resolved, then the dirty stream is proven
    /// (drain and probe). The link is invalidated while the probe is out, and the probe's own
    /// answer still proves the stream. The clear must not be written: the check runs again
    /// immediately before the write. Nothing was written for it, so the stream stays clean.
    func testALinkInvalidatedDuringTheProofStopsTheClearBeforeItsWrite() async throws {
        exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
        wire.respond = { _ in nil }
        _ = try? await exchange.send("22028D", retries: 1, responseTimeout: 0.03) { wire.target(adapter) }
        XCTAssertTrue(processor.isStreamDirty)

        let linkLock = NSLock()
        var linkIsCurrent = true
        wire.onWrite = { command in
            if command == "ATRV" { linkLock.withLock { linkIsCurrent = false } }
        }
        wire.respond = { $0 == "ATRV" ? "14.1V\r\r>" : "44\r\r>" }
        let revalidate: () throws -> Void = {
            guard linkLock.withLock({ linkIsCurrent }) else { throw OBDVehicleLinkError.linkChanged }
        }

        do {
            _ = try await exchange.send("04", retries: 1, responseTimeout: 1) {
                wire.target(adapter, revalidate: revalidate)
            }
            XCTFail("expected the link check to stop the clear")
        } catch {
            XCTAssertEqual(error as? OBDVehicleLinkError, .linkChanged, "\(error)")
        }
        XCTAssertEqual(wire.written, ["22028D", "ATRV"], "04 never reached the writer")
        XCTAssertFalse(processor.isStreamDirty, "nothing was written for the clear")

        wire.onWrite = nil
        wire.respond = { _ in "7E8064100BE3FA813\r>" }
        let lines = try await exchange.send("0100", retries: 1, responseTimeout: 1) { wire.target(adapter) }
        XCTAssertEqual(lines, ["7E8064100BE3FA813"])
        XCTAssertEqual(wire.written, ["22028D", "ATRV", "0100"], "written directly, no probe")
    }

    /// A revalidation failure is never retried: the retry would only fail the same way, and a
    /// bound request must not be re-checked into a write on another link.
    func testARevalidationFailureIsNotRetried() async {
        exchange = OBDStreamOwnershipTests.fastExchange(processor: processor)
        wire.respond = { _ in "44\r\r>" }
        var checks = 0
        do {
            _ = try await exchange.send("04", retries: 3, responseTimeout: 1) {
                wire.target(adapter, revalidate: {
                    checks += 1
                    throw OBDVehicleLinkError.linkChanged
                })
            }
            XCTFail("expected linkChanged")
        } catch {
            XCTAssertEqual(error as? OBDVehicleLinkError, .linkChanged)
        }
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(wire.written, [])
        XCTAssertFalse(processor.isStreamDirty)
    }

    // MARK: Listening without writing

    func testListenNeverWrites() async throws {
        let listening = Task { try await self.exchange.listen(deadline: self.now() + 1, policy: .redacted) }
        try await Task.sleep(nanoseconds: 50_000_000)
        wire.deliver("7E80562028D0CE2\r>")
        let lines = try await listening.value
        XCTAssertEqual(lines, ["7E80562028D0CE2"])
        XCTAssertEqual(wire.written, [])
    }

    func testListenReportsNoDataLikeANormalResponse() async {
        wire.deliver("NO DATA\r\r>")
        do {
            _ = try await exchange.listen(deadline: now() + 1, policy: .redacted)
            XCTFail("expected NO DATA")
        } catch {
            XCTAssertEqual(error as? BLEManagerError, .noData)
            XCTAssertEqual(OEMBatchExecutor.classify(error), .noData)
        }
    }

    func testListenHonoursItsDeadline() async throws {
        let started = now()
        do {
            _ = try await exchange.listen(deadline: started + 0.15, policy: .redacted)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(OEMBatchExecutor.classify(error), .timeout)
        }
        XCTAssertLessThan(now() - started, 1.0)
        XCTAssertTrue(processor.isStreamDirty, "a listen that ends without its answer leaves one outstanding")
    }

    /// A passed deadline doesn't arm, so a buffered answer stays for the next listen.
    func testAListenWithNoTimeLeftConsumesNothing() async throws {
        wire.deliver("7E80562028D0CE2\r>")
        do {
            _ = try await exchange.listen(deadline: now() - 0.01, policy: .redacted)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout)
        }
        let lines = try await exchange.listen(deadline: now() + 1, policy: .redacted)
        XCTAssertEqual(lines, ["7E80562028D0CE2"])
    }

    func testListenRethrowsCancellation() async {
        let listening = Task { try await self.exchange.listen(deadline: self.now() + 30, policy: .redacted) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        listening.cancel()
        do {
            _ = try await listening.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testListenRethrowsALinkReset() async {
        let listening = Task { try await self.exchange.listen(deadline: self.now() + 30, policy: .redacted) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        processor.reset()
        do {
            _ = try await listening.value
            XCTFail("expected the link error")
        } catch {
            XCTAssertEqual(OEMBatchExecutor.classify(error), .linkLost, "\(error)")
        }
    }

    // MARK: The processor's timeout

    /// An answer that lands as the timeout fires either wins (returned, stream clean) or loses
    /// (a timeout, stream dirty until a probe answers). It is never returned to a later slot,
    /// and never lost with the stream still counted clean.
    func testAnAnswerRacingTheTimeoutEitherWinsOrLeavesTheStreamDirty() async throws {
        for iteration in 0..<150 {
            let processor = OBDMessageProcessor()
            let token = try processor.beginRequest()
            let timeout = 0.003
            let delivered = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                processor.processReceivedData(Data("7E8044100\r>".utf8))
            }
            do {
                let lines = try await processor.awaitResponse(for: token, timeout: timeout)
                XCTAssertEqual(lines, ["7E8044100"], "iteration \(iteration)")
                XCTAssertFalse(processor.isStreamDirty, "iteration \(iteration)")
            } catch {
                XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout, "iteration \(iteration)")
                await delivered.value
                // Lost to the timer: outstanding. Lost to the deadline after its prompt was
                // consumed: complete, nothing outstanding. Either way no later slot gets it.
                if processor.isStreamDirty {
                    XCTAssertThrowsError(try processor.beginContinuationRequest(), "iteration \(iteration)")
                } else {
                    let next = try processor.beginContinuationRequest()
                    do {
                        let lines = try await processor.awaitResponse(for: next, timeout: 0.02)
                        XCTFail("iteration \(iteration): the late answer reached a later slot: \(lines)")
                    } catch {
                        XCTAssertEqual(error as? BLEMessageProcessorError, .responseTimeout, "iteration \(iteration)")
                    }
                }
            }
        }
    }
}
