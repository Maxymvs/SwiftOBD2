//
//  OEMAddressingGate.swift
//  SwiftOBD2
//
//  Fail-closed guard for the one state the OEM path can leave behind: an adapter whose header,
//  receive filter, extended addressing or flow control couldn't be restored and verified. A
//  vehicle request sent through it could reach the wrong module.
//
//  The state belongs to the **adapter**, not to a connection. The adapter is powered by the car
//  and keeps its settings across a Bluetooth disconnect, so the gate is keyed by the peripheral
//  and survives disconnects, new connection attempts and a rebuilt transport. It opens again
//  only after a **verified recovery** on that same adapter, in this order:
//
//  1. `ATZ` written, which starts a fresh recovery: every acknowledgement and all protocol
//     evidence gathered before it are forgotten. Only that reset's own answer, the
//     interpreter's banner, moves it forward. A `?`, `STOPPED` or a late `OK` is not a reset.
//  2. The standard re-initialization: echo, linefeeds and spaces off, headers on, a protocol
//     selected, each answered `OK`.
//  3. Only then may the functional `0100` be sent, and it opens the gate only with a complete
//     `41 00` answer (the four-byte bitmap) in the shape the detected protocol produces.
//
//  Until then only the commands of that recovery pass, plus the adapter-only queries that pass
//  in every phase (identity, `ATE0`, and the resynchronization probes `ATRV` and `ATDPN`). This
//  is an exact list, not a prefix rule: an adapter command can put a request on the bus
//  (`STPX d:0100`), so "starts with AT or ST" is not a safe exemption.
//
//  The gate trusts that every answer it is given belongs to its own command: the transport only
//  writes on a stream proven in sync (after a command that ended without its prompt, it drains
//  and probes with `ATRV`/`ATDPN` before writing anything else), so a late answer to an earlier
//  command can't be credited to `ATZ` or to a re-initialization step.
//
//  Inert until an OEM batch ends `.unresolved`. The transport consults it while holding its
//  command mutex, so a check and the send it guards can't be separated by another command.
//

import Foundation

/// Thrown instead of sending a command the gate doesn't allow on an unresolved adapter.
public enum OEMAddressingGateError: Error, Equatable {
    /// The adapter needs a verified recovery (reset, re-initialization, functional probe)
    /// before this command may be sent.
    case addressingUnresolved
}

/// Lock-protected so any thread may consult it; the lock is never held across an await.
///
/// **Which `0100` answer opens it.** The answer must match the protocol the adapter is on, as
/// far as the gate knows since the last reset banner. The evidence is the most recent of:
/// an `ATDPN` answer (`A6`, `6`, …), or an `ATSPn` answered `OK`. `ATSP0` and an `ATDPN` of `0`
/// / `A0` mean automatic search with nothing found yet, i.e. no evidence; an unreadable `ATDPN`
/// answer leaves the evidence as it was.
/// - Protocols 6 and 8 admit only the 11-bit CAN shape, 7 and 9 only the 29-bit shape, 1–5
///   only the legacy (J1850 / ISO 9141-2 / KWP) shape.
/// - J1939 (`A`) and the user CAN protocols (`B`, `C`) admit nothing: J1939 doesn't speak
///   OBD-II, and B/C have a user-set id width and no parser in this package, so no shape can be
///   tied to them.
/// - With no evidence (the automatic and preferred-protocol flows, which probe right after
///   `ATSP0`), any one of the complete shapes opens it.
final class OEMAddressingGate: @unchecked Sendable {
    /// Process-wide: the adapter stays misconfigured whichever transport object talks to it next.
    static let shared = OEMAddressingGate()

    /// Where an unresolved adapter is in its recovery.
    enum Phase: Equatable {
        /// Nothing counts until a written `ATZ` answers with a reset banner.
        case needsReset
        /// Reset seen. Holds the re-initialization commands answered `OK` since, and the
        /// protocol the adapter is known to be on (nil: automatic, or not known).
        case reinitializing(acknowledged: Set<String>, protocolEvidence: PROTOCOL? = nil)
    }

    typealias AnswerShape = OEMReply.SupportedPIDsAnswerShape

    /// The functional probe, and the only vehicle request an unresolved adapter may be sent.
    static let functionalProbe = "0100"
    static let reset = "ATZ"
    static let describeProtocolNumber = "ATDPN"
    /// Adapter-only commands that pass in every phase because connection setup sends them before
    /// the reset: the identity queries (`probeAdapterIdentity`, and `ATI` in channel validation)
    /// and echo off (`ATE0`, the second command of channel validation for an inferred GATT
    /// binding). None of them reaches the car or touches addressing. An `ATE0` answered before
    /// the reset still doesn't count toward the re-initialization: only answers in
    /// `.reinitializing` are recorded.
    static let alwaysAllowed: Set<String> = ["ATI", "AT@1", "STI", "ATE0"]
    /// The transport's resynchronization probes. Adapter-only queries that send nothing to the
    /// car and change nothing, so they pass in every phase: the resync must be able to run
    /// before a recovery `ATZ`. Their answers never advance or open the gate; an `ATDPN` answer
    /// after the reset banner is protocol evidence.
    static let resynchronizationProbes: Set<String> = ["ATRV", describeProtocolNumber]
    /// Each must be answered `OK` after the reset before the probe may be sent.
    static let requiredInitialization: Set<String> = ["ATE0", "ATL0", "ATS0", "ATH1"]

    private let lock = NSLock()
    private var phases: [UUID: Phase] = [:]

    func phase(of peripheral: UUID) -> Phase? {
        lock.withLock { phases[peripheral] }
    }

    func isUnresolved(_ peripheral: UUID) -> Bool {
        phase(of: peripheral) != nil
    }

    /// Arms the gate for `peripheral`. Re-arming an adapter that is mid-recovery starts it over.
    func markUnresolved(_ peripheral: UUID) {
        lock.withLock { phases[peripheral] = .needsReset }
    }

    /// Throws unless `command` may be sent to `peripheral` right now.
    func check(_ command: String, peripheral: UUID) throws {
        guard let phase = phase(of: peripheral) else { return }
        guard Self.isAllowed(Self.compacted(command), in: phase) else {
            throw OEMAddressingGateError.addressingUnresolved
        }
    }

    /// Call with the command mutex held, after `check` passed and immediately before the
    /// physical write. Writing `ATZ` to an unresolved adapter starts a fresh recovery phase:
    /// every acknowledgement and all protocol evidence so far are forgotten, and only the answer
    /// to this reset can move it forward. Does nothing for any other command, or for an adapter
    /// that isn't unresolved.
    func noteWillSend(_ command: String, peripheral: UUID) {
        guard Self.compacted(command) == Self.reset else { return }
        lock.withLock {
            if phases[peripheral] != nil {
                phases[peripheral] = .needsReset
            }
        }
    }

    /// Call with the answer to `command`, once its prompt arrived. This is the only way the gate
    /// advances or opens.
    func noteAnswered(_ command: String, lines: [String], peripheral: UUID) {
        let compact = Self.compacted(command)
        lock.withLock {
            guard let phase = phases[peripheral] else { return }
            if compact == Self.reset {
                // Any reset starts the recovery over; only a banner moves it forward.
                phases[peripheral] = Self.isResetBanner(lines) ? .reinitializing(acknowledged: []) : .needsReset
                return
            }
            guard case .reinitializing(var acknowledged, var evidence) = phase else { return }
            if compact == Self.functionalProbe {
                if Self.isInitializationComplete(acknowledged),
                   OEMReply.isPositiveSupportedPIDsAnswer(lines, shapes: Self.admittedShapes(evidence)) {
                    phases[peripheral] = nil
                }
                return
            }
            if compact == Self.describeProtocolNumber {
                if let reported = Self.reportedProtocol(lines) {
                    evidence = reported
                    phases[peripheral] = .reinitializing(acknowledged: acknowledged, protocolEvidence: evidence)
                }
            } else if Self.isInitializationCommand(compact), OEMBatchExecutor.isOK(lines) {
                acknowledged.insert(compact)
                if Self.isProtocolSelection(compact) {
                    evidence = Self.selectedProtocol(compact)
                }
                phases[peripheral] = .reinitializing(acknowledged: acknowledged, protocolEvidence: evidence)
            }
        }
    }

    /// Forgets every adapter. Tests only: production never opens the gate without a recovery.
    func resetForTesting() {
        lock.withLock { phases.removeAll() }
    }

    // MARK: The recovery vocabulary

    static func isAllowed(_ compact: String, in phase: Phase) -> Bool {
        if compact == reset || alwaysAllowed.contains(compact) || resynchronizationProbes.contains(compact) {
            return true
        }
        switch phase {
        case .needsReset:
            return false
        case let .reinitializing(acknowledged, _):
            if compact == functionalProbe { return isInitializationComplete(acknowledged) }
            return isInitializationCommand(compact)
        }
    }

    /// The fixed commands of adapter initialization, plus protocol selection (`ATSP` and one
    /// protocol digit, `0` for automatic).
    static func isInitializationCommand(_ compact: String) -> Bool {
        requiredInitialization.contains(compact) || isProtocolSelection(compact)
    }

    static func isProtocolSelection(_ compact: String) -> Bool {
        guard compact.count == 5, compact.hasPrefix("ATSP"), let digit = compact.last else { return false }
        return digit.isHexDigit && digit <= "C"
    }

    static func isInitializationComplete(_ acknowledged: Set<String>) -> Bool {
        requiredInitialization.isSubset(of: acknowledged) && acknowledged.contains(where: isProtocolSelection)
    }

    // MARK: Protocol evidence

    /// The protocol an acknowledged `ATSPn` fixed; nil for `ATSP0` (automatic search).
    static func selectedProtocol(_ compact: String) -> PROTOCOL? {
        guard let digit = compact.last, digit != "0" else { return nil }
        return PROTOCOL(rawValue: String(digit))
    }

    /// Reads an `ATDPN` answer: the protocol number, prefixed `A` while automatic (`A6`, `6`;
    /// J1939 is `A`, or `AA` when found automatically). `.some(nil)` for `0` / `A0`: no protocol
    /// found yet. nil when the answer isn't a protocol number at all.
    static func reportedProtocol(_ lines: [String]) -> PROTOCOL?? {
        let answers = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        guard answers.count == 1, var number = answers.first, number.count == 1 || number.count == 2 else { return nil }
        if number.count == 2 {
            guard number.hasPrefix("A") else { return nil }
            number.removeFirst()
        }
        if number == "0" { return .some(nil) }
        guard let reported = PROTOCOL(rawValue: number) else { return nil }
        return .some(reported)
    }

    /// The `0100` answer shapes the evidence admits (see the type's comment).
    static func admittedShapes(_ evidence: PROTOCOL?) -> Set<AnswerShape> {
        guard let evidence else { return Set(AnswerShape.allCases) }
        switch evidence {
        case .protocol6, .protocol8:
            return [.can11Bit]
        case .protocol7, .protocol9:
            return [.can29Bit]
        case .protocol1, .protocol2, .protocol3, .protocol4, .protocol5:
            return [.legacy]
        case .protocolA, .protocolB, .protocolC, .NONE:
            return []
        }
    }

    /// The interpreter's reset banner: one of the answer's lines starts with `ELM327`
    /// (`ELM327 v1.5`; STN chips print `ELM327 v1.4b`). `?`, `STOPPED` and `OK` are not a reset.
    ///
    /// `ATI` prints the same line, so a late `ATI` answer credited to `ATZ` would look like a
    /// reset. The gate can't tell the two apart from the text; what keeps them apart is the
    /// transport: it never writes `ATZ` on a stream with an answer still outstanding (a timed-out
    /// `ATI` is drained and the stream re-synchronized first), and writing `ATZ` itself starts a
    /// fresh phase (`noteWillSend`), so only the answer to that reset counts.
    static func isResetBanner(_ lines: [String]) -> Bool {
        lines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("ELM327") }
    }

    private static func compacted(_ command: String) -> String {
        command.filter { !$0.isWhitespace }.uppercased()
    }
}
