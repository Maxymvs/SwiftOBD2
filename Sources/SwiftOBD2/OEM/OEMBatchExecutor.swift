//
//  OEMBatchExecutor.swift
//  SwiftOBD2
//
//  Runs one manufacturer batch over a command channel the transport already holds exclusively:
//  configure the adapter for the module, read, restore functional addressing, verify. Nothing
//  else can interleave, because the whole run happens inside one acquisition of the transport's
//  command mutex (see `CommProtocol.withExclusiveCommandChannel`).
//
//  Two rules keep a reply from being credited to the wrong command:
//
//  - **The stream must be in sync.** The adapter answers commands in order and ends each answer
//    with a prompt. A command that ends without its prompt (a timeout, a cancellation) leaves an
//    answer that may still arrive, and it would then be read as the answer to the next command.
//    The transport owns that state for every command, manufacturer or not (see
//    `OBDMessageProcessor`): it writes nothing on a dirty stream but a probe, and clears the
//    state only when a probe's own answer arrives. This executor asks for that proof before the
//    batch's first write (the ordinary command just before it may have timed out) and before
//    restore, sends no further read after one that got no prompt, and ends `.unresolved` when
//    the proof can't be had.
//  - **One deadline per phase.** Setup and reads share the batch's absolute deadline, which
//    started before the transport's mutex was acquired. Restore has its own, end to end.
//
//  Transport-agnostic and clock-injected, so tests script every fault: a `?` on setup, response
//  pending, truncation, cancellation mid-configuration, deadline expiry, a late answer, a failed
//  restore.
//

import Foundation

/// Sends one command at a time while the transport's command mutex is already held by the
/// caller. Deadlines are absolute, in `OEMClock` seconds.
protocol OEMCommandChannel {
    /// Sends `command` once and waits for the adapter's prompt. `deadline` covers everything:
    /// write readiness, the write's acknowledgement and the response.
    ///
    /// The answer returned is this command's own: the transport writes only on a stream proven
    /// in sync. On a dirty stream it resynchronizes first, inside `deadline`, and when that
    /// fails the command is not written and the call throws `OBDStreamError.unsynchronized`.
    func send(_ command: String, deadline: TimeInterval) async throws -> [String]
    /// Waits for one more prompt-terminated answer **without writing anything**, after a
    /// "response pending". An answer already buffered is delivered; a bare prompt is not one.
    func listen(deadline: TimeInterval) async throws -> [String]
    /// Proves that no answer to an earlier command is still on its way, writing nothing but
    /// adapter-only probes: drain until quiet, then a probe whose answer can be attributed
    /// (`OBDStreamResynchronizer`). True when the stream is clean, at once if it already was;
    /// false when it couldn't be proven by `deadline`. Throws when the link is lost.
    func resynchronize(deadline: TimeInterval) async throws -> Bool
    /// The caller knows an answer may still arrive that the transport can't know about: a
    /// module said "response pending" and never followed up. The stream counts as dirty until
    /// the next proof.
    func requireResynchronization()
    /// Records that the adapter's addressing couldn't be restored, so the transport refuses
    /// vehicle requests until a verified recovery. Called before the channel is released, so
    /// nothing can slip in first.
    func markAddressingUnresolved()
}

/// Monotonic seconds. Injected so tests control every deadline.
protocol OEMClock {
    func now() -> TimeInterval
}

struct OEMSystemClock: OEMClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Asked after the adapter is acquired and again before every read. `false` stops the batch:
/// the caller no longer owns this work (its request ended, the link or the car changed, the
/// module stopped being served). Read caller-maintained state synchronously; the adapter
/// command channel is held during this check.
public typealias OEMBatchAdmission = @MainActor @Sendable () -> Bool

struct OEMBatchExecutor {
    /// A read is only started when at least this much of the budget is left.
    static let minimumReadWindow: TimeInterval = 0.25
    /// Per setup command, further capped by the batch deadline.
    static let setupCommandTimeout: TimeInterval = 0.5
    /// Per read, further capped by the batch deadline.
    static let readTimeout: TimeInterval = 1.5
    /// How long to keep listening (no second request) after a module answers "response
    /// pending", further capped by the batch deadline.
    static let responsePendingWindow: TimeInterval = 1.5
    static let restoreCommandTimeout: TimeInterval = 0.4
    /// A second try covers an adapter that answered something other than `OK` once.
    static let restoreAttempts = 2
    static let verificationTimeout: TimeInterval = 1.0
    /// The most one proof of the stream may take: the quiet wait and both probes' windows.
    static let synchronizationWindow: TimeInterval = 1.0

    /// Restore's own end-to-end limit, outside the batch budget: every restore command's
    /// attempts, two proofs of the stream, and the verification. 3.8 s for 11-bit targets,
    /// 6.2 s for BMW.
    static func restoreBudget(for target: OEMTarget) -> TimeInterval {
        let commands = Double(OEMAdapterCommand.restore(for: target).count * restoreAttempts) * restoreCommandTimeout
        return commands + 2 * synchronizationWindow + verificationTimeout
    }

    let batch: OEMReadBatch
    let clock: OEMClock

    init(batch: OEMReadBatch, clock: OEMClock = OEMSystemClock()) {
        self.batch = batch
        self.clock = clock
    }

    /// - Parameters:
    ///   - deadline: Absolute end of setup and reads, in `clock` seconds. Nil starts the batch's
    ///     budget now; the transport passes the deadline it started before taking its mutex.
    ///   - admission: See `OEMBatchAdmission`. Nil admits everything.
    func run(
        on channel: OEMCommandChannel,
        deadline: TimeInterval? = nil,
        admission: OEMBatchAdmission? = nil,
        isLinkCurrent: () -> Bool = { true }
    ) async -> OEMBatchResult {
        let start = clock.now()
        let deadline = deadline ?? (start + batch.budget)
        let target = batch.module.target
        var outcomes = [OEMReadOutcome?](repeating: nil, count: batch.commands.count)
        var failure: OEMBatchFailure?
        var configurationAttempted = false
        var lostLink = false

        func skipRemaining(_ reason: OEMSkipReason) {
            for index in outcomes.indices where outcomes[index] == nil {
                outcomes[index] = .notAttempted(reason)
            }
        }
        func stop(_ batchFailure: OEMBatchFailure?, skipping reason: OEMSkipReason) {
            if failure == nil { failure = batchFailure }
            if batchFailure == .linkLost { lostLink = true }
            skipRemaining(reason)
        }
        func admitted() async -> Bool {
            guard let admission else { return true }
            return await MainActor.run(body: admission)
        }

        // The first check that runs with the adapter held: whatever changed while this batch
        // waited for it is seen here, before a single byte is sent.
        if Task.isCancelled {
            stop(.cancelled, skipping: .cancelled)
        } else if !(await admitted()) {
            stop(.admissionRevoked, skipping: .admissionRevoked)
        } else if !isLinkCurrent() {
            stop(.linkLost, skipping: .linkLost)
        }

        // The stream this batch inherits may be dirty: the ordinary command just before it may
        // have ended without its prompt, and its late answer would be read as the answer to
        // setup. Prove it clean before the first write. When that can't be done nothing was
        // configured, so there is nothing to restore; the reads wait for a later cycle.
        if failure == nil {
            switch await Self.synchronize(on: channel, clock: clock, deadline: deadline) {
            case .inSync:
                break
            case .unproven:
                stop(Task.isCancelled ? .cancelled : nil, skipping: Task.isCancelled ? .cancelled : .streamOutOfSync)
            case .lostLink:
                stop(.linkLost, skipping: .linkLost)
            }
        }

        // Configuration, unless something above already decided the reads' outcomes.
        if failure == nil, outcomes.allSatisfy({ $0 == nil }) {
            for command in OEMAdapterCommand.setup(for: target) {
                if Task.isCancelled {
                    stop(.cancelled, skipping: .cancelled)
                    break
                }
                guard isLinkCurrent() else {
                    stop(.linkLost, skipping: .linkLost)
                    break
                }
                let now = clock.now()
                // Only worth (continuing to) configure when a read can still follow.
                guard deadline - now >= Self.minimumReadWindow else {
                    stop(nil, skipping: .budgetExhausted)
                    break
                }
                configurationAttempted = true
                do {
                    let lines = try await channel.send(
                        command, deadline: Swift.min(now + Self.setupCommandTimeout, deadline)
                    )
                    if Self.isOK(lines) { continue }
                    stop(Self.isQuestionMark(lines) ? .configurationRejected(command: command) : .configurationFailed,
                         skipping: .configurationFailed)
                } catch {
                    switch Self.classify(error) {
                    case .cancelled:
                        stop(.cancelled, skipping: .cancelled)
                    case .linkLost:
                        stop(.linkLost, skipping: .linkLost)
                    case .timeout, .noData, .unsynchronized:
                        stop(.configurationFailed, skipping: .configurationFailed)
                    }
                }
                break
            }
        }

        // Reads: each request is sent exactly once.
        let configured = outcomes.allSatisfy { $0 == nil }
        if configured {
            reads: for (index, command) in batch.commands.enumerated() {
                if Task.isCancelled {
                    stop(.cancelled, skipping: .cancelled)
                    break
                }
                guard isLinkCurrent() else {
                    stop(.linkLost, skipping: .linkLost)
                    break
                }
                guard await admitted() else {
                    stop(.admissionRevoked, skipping: .admissionRevoked)
                    break
                }
                let now = clock.now()
                guard deadline - now >= Self.minimumReadWindow else {
                    stop(nil, skipping: .budgetExhausted)
                    break
                }

                var lines: [String]
                do {
                    lines = try await channel.send(
                        OEMRequestPolicy.wireRequest(for: command.dataIdentifier),
                        deadline: Swift.min(now + Self.readTimeout, deadline)
                    )
                } catch {
                    switch Self.classify(error) {
                    case .noData:
                        outcomes[index] = .noAnswer
                        continue
                    case .timeout:
                        // No prompt: this read's answer may still arrive, and nothing would
                        // tell it apart from the next read's. Stop here.
                        outcomes[index] = .noAnswer
                        stop(nil, skipping: .streamOutOfSync)
                    case .unsynchronized:
                        // Never written: the stream an earlier read left dirty couldn't be
                        // proven. This read waits for a later cycle like the ones after it.
                        stop(nil, skipping: .streamOutOfSync)
                    case .cancelled:
                        stop(.cancelled, skipping: .cancelled)
                    case .linkLost:
                        stop(.linkLost, skipping: .linkLost)
                    }
                    break reads
                }

                var outcome = OEMReply.outcome(lines: lines, target: target, command: command)
                // "Response pending" and then a prompt: the answer is still coming. Keep
                // listening under the same mutex and deadline; never ask again.
                let pendingDeadline = Swift.min(clock.now() + Self.responsePendingWindow, deadline)
                while outcome == .responsePendingOnly {
                    do {
                        guard clock.now() < pendingDeadline else { throw BLEMessageProcessorError.responseTimeout }
                        lines += try await channel.listen(deadline: pendingDeadline)
                        outcome = OEMReply.outcome(lines: lines, target: target, command: command)
                    } catch {
                        switch Self.classify(error) {
                        case .noData:
                            // The adapter printed `NO DATA`: it gave up waiting. The module was
                            // told to wait, though, and may still answer, so the next read is
                            // written only after the stream is proven again.
                            outcomes[index] = .responsePendingOnly
                            channel.requireResynchronization()
                            continue reads
                        case .timeout, .unsynchronized:
                            // The module may still answer after we stop listening.
                            outcomes[index] = .responsePendingOnly
                            channel.requireResynchronization()
                            stop(nil, skipping: .streamOutOfSync)
                        case .cancelled:
                            outcomes[index] = .responsePendingOnly
                            channel.requireResynchronization()
                            stop(.cancelled, skipping: .cancelled)
                        case .linkLost:
                            stop(.linkLost, skipping: .linkLost)
                        }
                        break reads
                    }
                }
                outcomes[index] = outcome
            }
        }

        // Restore, whenever configuration was touched: on success, failure, deadline expiry and
        // cancellation alike. It runs in an unstructured task so the caller's cancellation can't
        // skip it (the send path checks for cancellation); this function awaits it while the
        // caller still holds the channel. Only the restore is shielded.
        var adapterState = OEMAdapterState.functional
        if configurationAttempted {
            let clock = self.clock
            let restoreTask = Task {
                await Self.restore(target: target, on: channel, clock: clock)
            }
            let restore = await restoreTask.value
            if restore.lostLink {
                lostLink = true
                if failure == nil { failure = .linkLost }
            }
            if !restore.verified || lostLink {
                adapterState = .unresolved
            }
        }
        if adapterState == .unresolved {
            channel.markAddressingUnresolved()
        }

        let reads = zip(batch.commands, outcomes).map { command, outcome in
            OEMReadResult(commandID: command.id, outcome: outcome ?? .notAttempted(.cancelled))
        }
        return OEMBatchResult(reads: reads, adapterState: adapterState, failure: failure, elapsed: clock.now() - start)
    }

    // MARK: Restore

    struct RestoreOutcome: Equatable {
        /// Every restore command answered `OK` on a stream proven in sync, and `0100` returned a
        /// full `41 00` answer.
        let verified: Bool
        let lostLink: Bool
    }

    /// Undoes the module's configuration and proves functional addressing works again, inside
    /// `restoreBudget(for:)`.
    ///
    /// Nothing is written, and no `OK` is credited, on a stream that isn't proven in sync: a late
    /// `OK` from an earlier command looks the same as this command's. So the stream is proven
    /// on entry and again after a restore command that got no prompt. When the proof can't be
    /// had, no further restore command is sent (the transport wouldn't write it anyway), the
    /// result is unverified, and the caller arms the gate: the adapter keeps the module's
    /// addressing until a reset, and the gate lets nothing but that reset through.
    static func restore(
        target: OEMTarget,
        on channel: OEMCommandChannel,
        clock: OEMClock = OEMSystemClock()
    ) async -> RestoreOutcome {
        let deadline = clock.now() + restoreBudget(for: target)

        switch await synchronize(on: channel, clock: clock, deadline: deadline) {
        case .inSync: break
        case .unproven: return RestoreOutcome(verified: false, lostLink: false)
        case .lostLink: return RestoreOutcome(verified: false, lostLink: true)
        }

        var allAcknowledged = true
        for command in OEMAdapterCommand.restore(for: target) {
            var acknowledged = false
            var attemptsLeft = restoreAttempts
            while attemptsLeft > 0 {
                attemptsLeft -= 1
                let now = clock.now()
                guard now < deadline else { break }
                do {
                    let lines = try await channel.send(command, deadline: Swift.min(now + restoreCommandTimeout, deadline))
                    if isOK(lines) {
                        acknowledged = true
                        break
                    }
                } catch {
                    switch classify(error) {
                    case .linkLost:
                        return RestoreOutcome(verified: false, lostLink: true)
                    case .noData:
                        break // A prompt arrived: still in sync, not acknowledged.
                    case .unsynchronized:
                        // The proof inside the send just failed: nothing more may be written.
                        return RestoreOutcome(verified: false, lostLink: false)
                    case .timeout, .cancelled:
                        // This command's answer may now arrive late and look like the next
                        // one's `OK`. Prove the stream again before anything else is written.
                        switch await synchronize(on: channel, clock: clock, deadline: deadline) {
                        case .inSync: break
                        case .unproven: return RestoreOutcome(verified: false, lostLink: false)
                        case .lostLink: return RestoreOutcome(verified: false, lostLink: true)
                        }
                    }
                }
            }
            allAcknowledged = allAcknowledged && acknowledged
        }
        guard allAcknowledged else { return RestoreOutcome(verified: false, lostLink: false) }

        let now = clock.now()
        guard now < deadline else { return RestoreOutcome(verified: false, lostLink: false) }
        do {
            let lines = try await channel.send(
                OEMAdapterCommand.verificationRequest, deadline: Swift.min(now + verificationTimeout, deadline)
            )
            return RestoreOutcome(verified: OEMReply.isPositiveSupportedPIDsAnswer(lines), lostLink: false)
        } catch {
            return RestoreOutcome(verified: false, lostLink: classify(error) == .linkLost)
        }
    }

    // MARK: Stream ownership

    enum Synchronization: Equatable {
        /// Nothing from an earlier command is outstanding.
        case inSync
        case unproven
        case lostLink
    }

    /// Asks the transport to prove the stream clean, within `synchronizationWindow` and
    /// `deadline`. Costs nothing on a stream that already is.
    static func synchronize(
        on channel: OEMCommandChannel,
        clock: OEMClock,
        deadline: TimeInterval
    ) async -> Synchronization {
        do {
            let proven = try await channel.resynchronize(
                deadline: Swift.min(clock.now() + synchronizationWindow, deadline)
            )
            return proven ? .inSync : .unproven
        } catch {
            return classify(error) == .linkLost ? .lostLink : .unproven
        }
    }

    // MARK: Answers and errors

    static func isOK(_ lines: [String]) -> Bool {
        !lines.isEmpty && lines.allSatisfy { normalized($0) == "OK" }
    }

    static func isQuestionMark(_ lines: [String]) -> Bool {
        lines.contains { normalized($0) == "?" }
    }

    private static func normalized(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    enum ChannelFailure: Equatable {
        /// The adapter printed `NO DATA` and its prompt: nothing is outstanding.
        case noData
        /// No prompt before the deadline. An answer may still arrive.
        case timeout
        /// Cancelled before a prompt. An answer may still arrive.
        case cancelled
        /// Not written: an earlier command left the stream dirty and it couldn't be proven in
        /// sync in time.
        case unsynchronized
        /// The link dropped or the error is unknown. The adapter's state is unknowable, so it
        /// fails closed.
        case linkLost
    }

    static func classify(_ error: Error) -> ChannelFailure {
        switch error {
        case is CancellationError:
            return .cancelled
        case is OBDStreamError:
            return .unsynchronized
        case let managerError as BLEManagerError:
            switch managerError {
            case .noData: return .noData
            case .timeout, .sendMessageTimeout: return .timeout
            default: return .linkLost
            }
        case let processorError as BLEMessageProcessorError:
            return processorError == .responseTimeout ? .timeout : .linkLost
        case let writeError as BLEWriteCoordinatorError:
            // The deadline passed before the write was ready or acknowledged: no prompt, and part
            // of the command may have gone out. The write coordinator poisons its session after
            // this, so the probes that follow fail as a lost link and the batch ends unresolved.
            // That is the safe outcome for a command of unknown length on the wire.
            return writeError.isDeadlineExpiry ? .timeout : .linkLost
        default:
            return .linkLost
        }
    }
}
