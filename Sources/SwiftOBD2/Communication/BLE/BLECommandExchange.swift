//
//  BLECommandExchange.swift
//  SwiftOBD2
//
//  The write-and-await body of every Bluetooth command, with the command mutex already held by
//  the caller, and the write-free listen of the manufacturer channel. Split out of `BLEManager`
//  so it runs without CoreBluetooth: the write is injected, everything else (the response slot,
//  stream ownership, the addressing gate, deadlines, the wire log) is the real thing.
//
//  Every command is written on a stream proven in sync (see `OBDMessageProcessor`). When an
//  earlier command left it dirty, `send` first resynchronizes: nothing but a probe is written
//  until a probe's own answer arrives, and if none does the command is not sent at all. So the
//  answer `send` returns always belongs to the command it sent.
//
//  Two timing modes:
//
//  - **Ordinary** (`deadline == nil`): the write gets `BLEConstants.defaultTimeout`, the response
//    gets `responseTimeout`, and a failed attempt may be retried.
//  - **Absolute deadline** (manufacturer channel): one attempt, never retransmitted. The same
//    absolute instant bounds a resynchronization, the write and the response: it is handed to
//    the write as it is and checked there before each physical write, and a reply counts only if
//    its prompt was consumed by then. With nothing left before the write, nothing is written.
//

import Foundation

struct BLECommandExchange {
    /// Where one attempt goes: the peripheral the gate is consulted for, and the write to it.
    struct Target {
        let peripheralID: UUID
        /// Re-checks, immediately before the command's write and after any resynchronization,
        /// that what was true when this target was resolved still is (the link a bound request
        /// was checked against, the peripheral and write session the target writes to). A
        /// cheap early answer, not what makes a bound write safe (see `firstWriteGate`). Any
        /// error it throws, of any type, ends the command unwritten and is never retried: the
        /// slot is released unwritten and the error escapes unchanged.
        let revalidate: () throws -> Void
        /// For a bound command (`OBDWriteAuthorization.whileAuthorized`): the hand-off of the
        /// command's first chunk runs inside it, after any wait for flow control, atomically
        /// with every revocation of the binding. Given to the command's write only, never to a
        /// resynchronization probe's. When it refuses, nothing was written: the slot is released
        /// unwritten (the stream stays clean) and its error escapes unchanged, never retried.
        let firstWriteGate: BLEFirstWriteGate?
        /// Writes one command (or probe). The second argument is the absolute instant (on the
        /// exchange's clock) the write must be accepted by; nothing may be written after it. The
        /// third is the gate to run the first chunk's hand-off in (nil for probes and unbound
        /// commands); a refusal must surface as `BLEFirstWriteRefused`.
        let gatedWrite: (_ command: String, _ deadlineAt: TimeInterval, _ gate: BLEFirstWriteGate?) async throws -> Void

        init(
            peripheralID: UUID,
            revalidate: @escaping () throws -> Void = {},
            write: @escaping (_ command: String, _ deadlineAt: TimeInterval) async throws -> Void
        ) {
            self.peripheralID = peripheralID
            self.revalidate = revalidate
            self.firstWriteGate = nil
            self.gatedWrite = { command, deadlineAt, _ in try await write(command, deadlineAt) }
        }

        init(
            peripheralID: UUID,
            revalidate: @escaping () throws -> Void = {},
            firstWriteGate: BLEFirstWriteGate?,
            gatedWrite: @escaping (_ command: String, _ deadlineAt: TimeInterval, _ gate: BLEFirstWriteGate?) async throws -> Void
        ) {
            self.peripheralID = peripheralID
            self.revalidate = revalidate
            self.firstWriteGate = firstWriteGate
            self.gatedWrite = gatedWrite
        }

        /// An ungated write: resynchronization probes.
        func write(_ command: String, _ deadlineAt: TimeInterval) async throws {
            try await gatedWrite(command, deadlineAt, nil)
        }
    }

    /// The binding (revalidation or the first-write gate) refused, with nothing written for
    /// this attempt. Never retried, whatever `underlying` is; `send` rethrows `underlying`.
    private struct BindingRefusal: Error {
        let underlying: Error
    }

    let processor: OBDMessageProcessor
    let gate: OEMAddressingGate
    var retryDelay: TimeInterval = BLEConstants.retryDelay
    var defaultWriteTimeout: TimeInterval = BLEConstants.defaultTimeout
    /// The longest one extra listen window of a transaction waits.
    var listenWindowTimeout: TimeInterval = BLEConstants.defaultTimeout
    var resynchronization = OBDStreamResynchronizer.Timing()

    /// The processor's clock: deadlines are compared against the instant a reply's prompt was
    /// consumed, so both must read the same one.
    var now: @Sendable () -> TimeInterval { processor.clock }

    private var wireLog: OBDWireLog { processor.wireLog }

    /// Sends `command` and waits for its prompt-terminated answer.
    ///
    /// - Parameters:
    ///   - deadline: Absolute, in `now()` seconds. When set, exactly one attempt is made and the
    ///     deadline covers a resynchronization, the write and the response; `retries` and
    ///     `responseTimeout` are not used.
    ///   - resolveTarget: Called before every attempt (the link may drop between retries).
    func send(
        _ command: String,
        retries: Int,
        responseTimeout: TimeInterval,
        deadline: TimeInterval? = nil,
        policy: OBDWireLogPolicy = .full,
        resolveTarget: () throws -> Target
    ) async throws -> [String] {
        try Task.checkCancellation()
        holdRedactionIfNeeded(policy)
        let attempts = deadline == nil ? max(1, retries) : 1
        let started = now()

        for attempt in 1...attempts {
            try Task.checkCancellation()
            let target = try resolveTarget()
            // With the mutex held, so the check and the write it guards can't be separated.
            try gate.check(command, peripheral: target.peripheralID)

            if let deadline, deadline - now() <= 0 {
                // Nothing written and nothing armed: the stream is untouched.
                wireLog.record(
                    .failed(command: command, attempts: attempt, outcome: .timeout,
                            detail: "deadline passed before the write", elapsed: now() - started),
                    policy: policy
                )
                throw BLEMessageProcessorError.responseTimeout
            }

            do {
                let token: RequestToken
                do {
                    token = try await armOnCleanStream(command, target: target, deadline: deadline)
                } catch OBDStreamError.unsynchronized where deadline == nil {
                    // Ordinary callers see what they always saw when the adapter didn't answer.
                    throw BLEMessageProcessorError.responseTimeout
                }
                // Authorized at the write, not before the proof: the proof may have taken a
                // while, and the link or the write channel may have changed meanwhile. Nothing
                // was written for this slot, so giving it up leaves the stream as it was.
                do {
                    try target.revalidate()
                } catch {
                    processor.releaseUnwrittenRequest(token)
                    throw BindingRefusal(underlying: error)
                }
                gate.noteWillSend(command, peripheral: target.peripheralID)
                do {
                    try await target.gatedWrite(
                        command, deadline ?? (now() + defaultWriteTimeout), target.firstWriteGate
                    )
                } catch let refusal as BLEFirstWriteRefused {
                    // The binding was revoked while the command waited to be written (flow
                    // control, the write queue). The gate refused before the first chunk was
                    // handed over: nothing of the command is on the wire, so the slot is given up
                    // unwritten and the stream is left exactly as it was.
                    processor.releaseUnwrittenRequest(token)
                    throw BindingRefusal(underlying: refusal.underlying)
                } catch {
                    // The response slot was armed before the first chunk so an early adapter
                    // response cannot be lost. A failed or cancelled write gives the slot up
                    // before any late bytes arrive, and leaves the stream dirty: part of the
                    // command may be on the wire.
                    processor.abandonRequest(token)
                    throw error
                }
                wireLog.record(.sent(command: command), policy: policy)

                let response: [String]
                if let deadline {
                    response = try await processor.awaitResponse(for: token, deadline: deadline)
                } else {
                    response = try await processor.awaitResponse(for: token, timeout: responseTimeout)
                }
                wireLog.record(.answered(command: command, lines: response, elapsed: now() - started), policy: policy)
                noteAnswered(command, lines: response, peripheral: target.peripheralID)
                return response
            } catch let caught {
                // A refusal by the binding is rethrown as the binding's own error and never
                // retried, whatever its type: a retry can't make a revoked binding hold again,
                // and must never re-check it into a write on another link.
                let refusal = caught as? BindingRefusal
                let error = refusal?.underlying ?? caught
                // Non-retryable errors — exit immediately
                let retryable = refusal == nil
                    && !(error is CancellationError)
                    // A write coordinator error may follow one or more submitted
                    // chunks. Retrying the command would duplicate an unknown prefix.
                    && !(error is BLEWriteCoordinatorError)
                    && !(error is BLECommandEncodingError)
                    && !(error is OEMAddressingGateError)
                    && !(error is OBDStreamError)
                    // The request's binding no longer holds: retrying can't make it hold again.
                    && !(error is OBDVehicleLinkError)
                    && (error as? BLEMessageProcessorError) != .staleRequestToken
                if !retryable || attempt == attempts {
                    // Ordinary traffic logged only the last of a retried command's failures;
                    // keep that, and always account for a deadline-bound exchange and for a
                    // stream that needs a reconnect.
                    if attempt == attempts || deadline != nil
                        || (error as? OBDStreamError) == .reconnectRequired {
                        wireLog.record(
                            .failed(command: command, attempts: attempt, outcome: OBDWireOutcome(error),
                                    detail: error.localizedDescription, elapsed: now() - started),
                            policy: policy
                        )
                    }
                    throw error
                }
                wireLog.record(
                    .retrying(command: command, attempt: attempt, attempts: attempts,
                              outcome: OBDWireOutcome(error), detail: error.localizedDescription),
                    policy: policy
                )
                // The failed attempt left the stream dirty; the next one resynchronizes before
                // it writes. The slot's state is deliberately not reset here.
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        throw BLEManagerError.noData
    }

    /// Sends once, then listens for as many windows as the exchange needs, **never writing
    /// again**: the body of `BLEManager.sendCommandTransaction`, with the command mutex already
    /// held by the caller for the whole transaction.
    ///
    /// Each window is armed with `beginContinuationRequest()`, which keeps the buffer, so a final
    /// message that landed in the gap since the last prompt is delivered instead of lost. A
    /// window that times out (or reports `NO DATA`), a dirty stream and an exhausted budget end
    /// the transaction with whatever arrived; cancellation and link loss are rethrown.
    ///
    /// - Parameters:
    ///   - responseTimeout: The first send's wait for its answer.
    ///   - listenDeadline: The budget for the extra windows, in seconds on `now()` from the end of
    ///     the first send.
    ///   - checkAttempt: Before every window; throws when the connection attempt is no longer
    ///     the one the transaction started on.
    ///   - checkLink: Before every window, once the budget allows one; throws when the link is
    ///     gone.
    func transaction(
        _ command: String,
        retries: Int,
        responseTimeout: TimeInterval,
        shouldContinueListening: ([String]) -> Bool,
        listenDeadline: TimeInterval,
        checkAttempt: () throws -> Void,
        checkLink: () throws -> Void,
        resolveTarget: () throws -> Target
    ) async throws -> [String] {
        var accumulated = try await send(
            command,
            retries: retries,
            responseTimeout: responseTimeout,
            resolveTarget: resolveTarget
        )
        // Every exit from here (a return, `NO DATA`, cancellation, the budget, a window timeout,
        // a dirty-stream window, link loss) that still owes the final answer leaves the stream
        // dirty, still under the caller's mutex: that answer may arrive later and must not be
        // credited to the next command. After link loss this is harmless (a new link resets).
        defer {
            if shouldContinueListening(accumulated) { processor.markStreamDirty() }
        }
        let started = now()

        listening: while shouldContinueListening(accumulated) {
            try Task.checkCancellation()
            try checkAttempt()
            let remaining = listenDeadline - (now() - started)
            guard remaining > 0 else {
                wireLog.record(.listenBudgetExhausted(command: command))
                break listening
            }
            try checkLink()

            do {
                // Throws on a dirty stream: a window there would be handed some earlier
                // command's late answer. Ends the transaction like a quiet window.
                let token = try processor.beginContinuationRequest()
                let response = try await processor.awaitResponse(
                    for: token,
                    timeout: min(remaining, listenWindowTimeout)
                )
                wireLog.record(.listenAnswered(lines: response, elapsed: 0, command: command))
                accumulated.append(contentsOf: response)
            } catch is CancellationError {
                throw CancellationError()
            } catch OBDStreamError.ambiguousResponse {
                throw OBDStreamError.ambiguousResponse
            } catch let error as BLEMessageProcessorError where error == .staleRequestToken {
                throw error // the processor was reset under us: a disconnect, not a quiet ECU
            } catch let error as BLEManagerError {
                // `NO DATA` in a listen window means nothing more came; anything else (peripheral
                // gone, unauthorized, …) is terminal and must never read as silence.
                if case .noData = error { break listening }
                throw error
            } catch {
                wireLog.record(
                    .listenEnded(outcome: OBDWireOutcome(error), detail: error.localizedDescription, elapsed: 0)
                )
                break listening
            }
        }
        return accumulated
    }

    /// Waits for one more prompt-terminated answer **without writing**, until the absolute
    /// `deadline`. Only on a clean stream (after "response pending"): an answer that already
    /// arrived is delivered at once, and a bare prompt with no text is not an answer, so the
    /// listen goes on. `NO DATA` throws `BLEManagerError.noData`, like a normal response;
    /// cancellation, a reset slot and a dropped link are rethrown. A listen that ends without an
    /// answer leaves the stream dirty.
    func listen(deadline: TimeInterval, policy: OBDWireLogPolicy) async throws -> [String] {
        try Task.checkCancellation()
        holdRedactionIfNeeded(policy)
        let started = now()
        let remaining = deadline - started
        guard remaining > 0 else {
            wireLog.record(
                .listenEnded(outcome: .timeout, detail: "deadline passed before listening", elapsed: 0),
                policy: policy
            )
            throw BLEMessageProcessorError.responseTimeout
        }
        do {
            let token: RequestToken
            do {
                token = try processor.beginContinuationRequest()
            } catch OBDStreamError.unsynchronized {
                // A listen on a dirty stream would be handed some earlier command's answer.
                throw BLEMessageProcessorError.responseTimeout
            }
            let lines = try await processor.awaitResponse(for: token, deadline: deadline)
            wireLog.record(.listenAnswered(lines: lines, elapsed: now() - started), policy: policy)
            return lines
        } catch {
            wireLog.record(
                .listenEnded(outcome: OBDWireOutcome(error), detail: error.localizedDescription, elapsed: now() - started),
                policy: policy
            )
            throw error
        }
    }

    // MARK: Stream ownership

    /// Whether an earlier command's answer may still arrive. See `OBDMessageProcessor`.
    var isStreamDirty: Bool { processor.isStreamDirty }

    /// Proves the stream in sync before anything else is written: drain until quiet, then probe
    /// (see `OBDStreamResynchronizer`). Returns at once on a clean stream. Probes go through the
    /// addressing gate like every write, and their answers are never fed to it.
    ///
    /// - Parameter deadline: Absolute. Nil allows the resynchronizer's own worst case.
    func resynchronize(
        deadline: TimeInterval? = nil,
        policy: OBDWireLogPolicy = .full,
        target: Target
    ) async throws -> OBDStreamResynchronizer.Outcome {
        holdRedactionIfNeeded(policy)
        let resynchronizer = OBDStreamResynchronizer(processor: processor, timing: resynchronization)
        return try await resynchronizer.resynchronize(
            deadline: deadline ?? (now() + resynchronization.worstCase)
        ) { probe, writeDeadline in
            try gate.check(probe, peripheral: target.peripheralID)
            try await target.write(probe, writeDeadline)
        }
    }

    /// Arms the response slot for `command`, resynchronizing first when the stream is dirty.
    /// Throws `OBDStreamError.unsynchronized`, with nothing written but probes, when the stream
    /// can't be proven, and `OBDStreamError.reconnectRequired` when no probe could prove it. A
    /// deadline-bound caller gets either error as it is, so it can tell "never sent" from "sent
    /// and not answered"; ordinary callers get `.reconnectRequired` as it is too.
    private func armOnCleanStream(_ command: String, target: Target, deadline: TimeInterval?) async throws -> RequestToken {
        do {
            return try await processor.beginRequestWaitingForECU(command: command, deadline: deadline)
        } catch OBDStreamError.unsynchronized {
            // Fall through to the proof.
        }
        // A late manufacturer answer may be among what gets drained; the hold set when the
        // manufacturer channel opened is still in force for it (see `OBDWireLog`).
        switch try await resynchronize(deadline: deadline, policy: .full, target: target) {
        case .synchronized:
            break
        case .unproven:
            throw OBDStreamError.unsynchronized
        case .reconnectRequired:
            // No probe can prove this stream: waiting and retrying won't help, a reconnect will.
            throw OBDStreamError.reconnectRequired
        }
        // Throws the same error when bytes arrived between the proof and the arm: still not
        // this command's stream.
        return try await processor.beginRequestWaitingForECU(command: command, deadline: deadline)
    }

    /// A redacted exchange's answer may be parsed by the processor, and may arrive late, after
    /// this call returned. Both log through the shared wire log, so the redaction is held there
    /// until the stream is known clean (see `OBDWireLog`).
    private func holdRedactionIfNeeded(_ policy: OBDWireLogPolicy) {
        if policy == .redacted { wireLog.holdRedaction() }
    }

    // MARK: The addressing gate

    /// Feeds an answer to the gate. When this answer completed a verified recovery, the stream
    /// is known clean (the reset flushed everything older), so a redaction hold ends too.
    private func noteAnswered(_ command: String, lines: [String], peripheral: UUID) {
        let wasUnresolved = gate.isUnresolved(peripheral)
        gate.noteAnswered(command, lines: Self.answerLines(to: command, from: lines), peripheral: peripheral)
        if wasUnresolved, !gate.isUnresolved(peripheral) {
            wireLog.releaseRedaction()
        }
    }

    /// The answer without the adapter's echo of the command.
    ///
    /// `ATZ` turns echo back on, so the recovery's `ATE0` is answered `ATE0` / `OK`: the first
    /// line is the adapter repeating the command it received, not part of the answer. Only a
    /// first line that is exactly the command (ignoring spaces and case) is dropped; anything
    /// else, including a different command's echo, is left for the gate to judge.
    static func answerLines(to command: String, from lines: [String]) -> [String] {
        guard let first = lines.first, compacted(first) == compacted(command), !compacted(command).isEmpty else {
            return lines
        }
        return Array(lines.dropFirst())
    }

    private static func compacted(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.uppercased()
    }
}
