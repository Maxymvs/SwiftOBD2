//
//  OBDStreamResynchronizer.swift
//  SwiftOBD2
//
//  Proves a dirty stream clean again, for every stream transport (Bluetooth and WiFi).
//
//  `OBDMessageProcessor` marks the stream dirty when a slot ends without its complete reply, and
//  refuses to arm another command until this has run. The proof has two steps:
//
//  1. **Drain until quiet.** Wait until no byte has arrived for a short while, so a late answer
//     that is in flight finishes instead of being cut in two by the next write. Complete
//     responses that arrive are discarded; an unfinished one keeps its owner (the past) and is
//     discarded when its prompt comes.
//  2. **A probe whose complete answer can be attributed.** An adapter-only query whose answer no
//     other command produces: `ATRV` answers a voltage, `ATDPN` a protocol number. The adapter
//     reports its own command results in order. The probe proves the adapter is at its
//     prompt. Separate ECU debt in the processor survives that proof.
//
//  A probe proves nothing while an earlier send of the same command may still be answered: that
//  late answer would look like this one's. The processor counts sends that never got their
//  prompt, and such a probe is skipped until its late answer has been seen and discarded. The
//  two probes differ so that one of them is usable when the other was swallowed by an adapter
//  that was still busy (the first byte of a command interrupts a pending request).
//
//  Neither probe reaches the car or changes any adapter setting, and nothing else is written
//  until one of them is answered. Without a proof the stream stays dirty and the caller's
//  command is not sent.
//

import Foundation

struct OBDStreamResynchronizer {
    private static let exhaustionGrace: TimeInterval = 1.0
    private static let gracePollInterval: TimeInterval = 0.04

    struct Timing: Equatable {
        /// No byte for this long counts as quiet.
        var quietWindow: TimeInterval = 0.12
        /// The longest the drain waits for quiet before probing anyway. A stream that never
        /// goes quiet needs the probe's write to interrupt whatever is talking.
        var maximumDrain: TimeInterval = 1.0
        /// How long one probe waits for its own answer.
        var probeWindow: TimeInterval = 0.4

        /// The most one resynchronization can take when no deadline cuts it shorter.
        var worstCase: TimeInterval {
            maximumDrain + Double(OEMAdapterCommand.syncProbes.count) * probeWindow + OBDStreamResynchronizer.exhaustionGrace
        }
    }

    enum Outcome: Equatable {
        /// The stream is clean: a probe's own answer arrived and nothing followed it.
        case synchronized
        /// No probe could be answered attributably. The stream is still dirty.
        case unproven
        /// Nothing proved the stream, and every probe now has an earlier send of its own still
        /// unanswered: no probe can prove this stream until a late answer happens to arrive.
        /// The stream is still dirty. See `isExhausted(_:)`.
        case reconnectRequired
    }

    /// Whether no probe can prove `processor`'s stream: it is dirty and every probe has an
    /// earlier send still unanswered. Computed from the processor's live state, so it clears by
    /// itself when the link resets, a proof succeeds, or an outstanding probe's late answer
    /// arrives (late answers discarded since the last look are accounted for first, exactly as
    /// a resynchronization would before choosing a probe).
    static func isExhausted(_ processor: OBDMessageProcessor) -> Bool {
        guard let graceEnd = exhaustionDeadline(on: processor) else { return false }
        return processor.clock() >= graceEnd
    }

    private static func exhaustionDeadline(on processor: OBDMessageProcessor) -> TimeInterval? {
        accountForLateAnswers(on: processor)
        guard processor.isStreamDirty,
              OEMAdapterCommand.syncProbes.allSatisfy({ processor.unansweredCount(of: $0.command) > 0 })
        else { return nil }
        return processor.noteProbesExhausted() + exhaustionGrace
    }

    /// Whether a failed probe write may have put any of the probe on the wire, so that an answer
    /// to it may still arrive. False only when the failure guarantees that nothing was written.
    static func mayHaveWritten(_ error: Error) -> Bool {
        switch error {
        case let writeError as BLEWriteCoordinatorError:
            return !writeError.wroteNothing
        case is BLECommandEncodingError, is OEMAddressingGateError:
            return false
        case is WifiWriteRefusal:
            // The WiFi transport refused the write before submitting anything to the socket
            // (its deadline had passed, or the socket was no longer current).
            return false
        case let managerError as BLEManagerError:
            if case .missingPeripheralOrCharacteristic = managerError { return false }
            return true
        default:
            // Cancellation, a socket failure, anything unknown: not certain.
            return true
        }
    }

    let processor: OBDMessageProcessor
    var timing = Timing()
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(Swift.max(0, seconds) * 1_000_000_000))
    }

    private var probes: [OEMAdapterCommand.SyncProbe] { OEMAdapterCommand.syncProbes }

    /// Does nothing on a clean stream. On a dirty one, drains and probes until `deadline`
    /// (absolute, on the processor's clock).
    ///
    /// - Parameter write: Writes one probe; the second argument is the absolute instant the
    ///   write must be done by. Whatever it throws is rethrown: a failed write is the link's
    ///   problem, not an answer about the stream.
    func resynchronize(
        deadline: TimeInterval,
        write: (_ probe: String, _ deadline: TimeInterval) async throws -> Void
    ) async throws -> Outcome {
        guard processor.isStreamDirty else { return .synchronized }
        let clock = processor.clock
        let started = clock()

        processor.beginResynchronization()
        var proven = false
        defer {
            if !proven { processor.endResynchronization() }
            processor.wireLog.record(
                proven ? .resynchronized(elapsed: clock() - started) : .resynchronizationFailed(elapsed: clock() - started)
            )
        }

        // 1. Quiet.
        let drainEnd = Swift.min(deadline, started + timing.maximumDrain)
        while true {
            try Task.checkCancellation()
            let now = clock()
            let quietEnd = Swift.min(drainEnd, processor.quietDeadline(after: timing.quietWindow))
            guard now < quietEnd else { break }
            try await sleep(quietEnd - now)
        }

        // 2. Probes.
        for probe in probes {
            Self.accountForLateAnswers(on: processor, drainingUnowned: true)
            guard processor.unansweredCount(of: probe.command) == 0 else { continue }
            let now = clock()
            let windowEnd = Swift.min(now + timing.probeWindow, deadline)
            guard windowEnd > now else { return .unproven }

            var token = processor.beginProbeRequest(command: probe.command)
            do {
                try await write(probe.command, windowEnd)
            } catch {
                processor.abandonRequest(token)
                // Part of it may be on the wire, and then its answer may still come. A probe the
                // adapter never received can't be answered, and stays usable.
                if Self.mayHaveWritten(error) {
                    processor.noteUnanswered(probe.command)
                }
                throw error
            }

            var answered = false
            do {
                window: while true {
                    var lines: [String]
                    do {
                        lines = try await processor.awaitResponse(for: token, deadline: windowEnd)
                    } catch let error as BLEManagerError where error == .noData {
                        lines = [] // `NO DATA` and a prompt: some other command's answer.
                    } catch let error as BLEMessageProcessorError where error == .responseTimeout {
                        break window
                    }
                    lines = BLECommandExchange.answerLines(to: probe.command, from: lines)
                    if probe.isAnswer(lines) {
                        answered = true
                        if processor.confirmSynchronized() {
                            proven = true
                            return .synchronized
                        }
                        // Bytes followed the answer: something is still arriving.
                        break window
                    }
                    account(forLateAnswer: lines)
                    // `?`: the adapter was busy and read this probe as garbage. Its answer isn't
                    // coming, so don't wait out the window.
                    if Self.isUnknownCommandReply(lines) { break window }
                    guard clock() < windowEnd else { break window }
                    token = processor.continueProbeRequest()
                }
            } catch {
                // Cancelled or the link went away mid-window.
                processor.noteUnanswered(probe.command)
                throw error
            }
            if !answered { processor.noteUnanswered(probe.command) }
        }
        // Free any probe whose late answer was already buffered behind the last window.
        // Then let the dirty processor discard arrivals directly for the receive-only grace.
        processor.endResynchronization()
        while let graceEnd = Self.exhaustionDeadline(on: processor) {
            try Task.checkCancellation()
            let now = clock()
            if now >= graceEnd { return .reconnectRequired }
            guard now < deadline else { break }
            let nextCheck = Swift.min(deadline, graceEnd, now + Self.gracePollInterval)
            try await sleep(nextCheck - now)
        }
        return .unproven
    }

    /// Late answers that were discarded may be the outstanding answer to an earlier send of a
    /// probe command. Each one seen frees that probe for use again.
    private func account(forLateAnswer lines: [String]) {
        Self.account(forLateAnswer: lines, on: processor)
    }

    private static func accountForLateAnswers(on processor: OBDMessageProcessor, drainingUnowned: Bool = false) {
        for lines in processor.takeLateResponses(drainingUnowned: drainingUnowned) {
            account(forLateAnswer: lines, on: processor)
        }
    }

    private static func account(forLateAnswer lines: [String], on processor: OBDMessageProcessor) {
        for probe in OEMAdapterCommand.syncProbes
        where probe.isAnswer(BLECommandExchange.answerLines(to: probe.command, from: lines)) {
            processor.noteLateAnswer(to: probe.command)
        }
    }

    private static func isUnknownCommandReply(_ lines: [String]) -> Bool {
        lines.count == 1 && lines[0].trimmingCharacters(in: .whitespacesAndNewlines) == "?"
    }
}
