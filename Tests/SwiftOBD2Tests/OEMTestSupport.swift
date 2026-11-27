//
//  OEMTestSupport.swift
//  SwiftOBD2Tests
//
//  Shared helpers for the manufacturer-data tests: a synthetic catalog, a fake clock, and a
//  model of the adapter behind its stream-owning transport that records everything the executor
//  sends. Synthetic data only.
//

import Foundation
@testable import SwiftOBD2
import XCTest

enum OEMTestCatalog {
    /// A small synthetic catalog: a VW-style car with engine, transmission and one module outside
    /// the allowlist, and a BMW-style car with two extended-address modules.
    static let json = """
    {
      "formatVersion": 1,
      "license": "CC BY-SA 4.0",
      "licenseURL": "https://creativecommons.org/licenses/by-sa/4.0/",
      "attribution": "test",
      "changes": "synthetic",
      "vehicles": [
        {
          "id": "test-vw", "make": "Testwagen", "model": "Synthetic", "modelYear": 2020,
          "source": {"repository": "test/vw", "commit": "0000000000000000000000000000000000000001",
                     "url": "https://example.invalid", "signalset": "s.json", "support": "s.yaml"},
          "modules": [
            {"id": "engine", "name": "Engine", "servedByDefault": true,
             "target": {"kind": "standard11Bit", "request": "7E0", "response": "7E8"}},
            {"id": "transmission", "name": "Transmission", "servedByDefault": false, "caveat": "test caveat",
             "target": {"kind": "standard11Bit", "request": "7E1", "response": "7E9"}},
            {"id": "other", "name": "Other", "servedByDefault": false,
             "target": {"kind": "standard11Bit", "request": "7E2", "response": "7EA"}}
          ],
          "commands": [
            {"id": "E.028D", "module": "engine", "did": "028D", "freq": 5, "fcm1": false, "evidence": "captured",
             "replyLengths": [2],
             "signals": [{"id": "ECU_T", "name": "ECU temperature", "path": "Engine",
               "fmt": {"len": 16, "div": 10, "add": -273.1, "min": -273.1, "max": 6280.4, "nullmin": -273.1, "unit": "celsius"}}]},
            {"id": "E.1002", "module": "engine", "did": "1002", "freq": 1, "fcm1": false, "evidence": "captured",
             "replyLengths": [],
             "signals": [{"id": "TORQUE", "name": "Torque", "path": "Engine",
               "fmt": {"len": 16, "sign": true, "div": 10, "min": -500, "max": 500, "unit": "newtonMeters"}}]},
            {"id": "E.1010", "module": "engine", "did": "1010", "freq": 1, "fcm1": false, "evidence": "catalog",
             "replyLengths": [1],
             "signals": [{"id": "LOAD", "name": "Load", "path": "Engine",
               "fmt": {"len": 8, "max": 255, "unit": "percent"}}]},
            {"id": "E.2000", "module": "engine", "did": "2000", "freq": 1, "fcm1": false, "evidence": "catalog",
             "replyLengths": [4],
             "signals": [
               {"id": "A", "name": "A", "path": "Engine", "fmt": {"len": 16, "max": 65535, "unit": "scalar"}},
               {"id": "B", "name": "B", "path": "Engine", "fmt": {"bix": 16, "len": 16, "max": 65535, "unit": "scalar"}}]},
            {"id": "E.58D1", "module": "engine", "did": "58D1", "freq": 1, "fcm1": true, "evidence": "catalog",
             "replyLengths": [14],
             "signals": [{"id": "LONG", "name": "Long", "path": "Engine",
               "fmt": {"bix": 96, "len": 16, "max": 65535, "unit": "scalar"}}]},
            {"id": "T.704E", "module": "transmission", "did": "704E", "freq": 5, "fcm1": true, "evidence": "catalog",
             "replyLengths": [1],
             "signals": [{"id": "TRANS_T", "name": "Transmission temperature", "path": "Transmission",
               "fmt": {"len": 8, "add": -40, "min": -40, "max": 215, "unit": "celsius"}}]},
            {"id": "O.3000", "module": "other", "did": "3000", "freq": 5, "fcm1": false, "evidence": "catalog",
             "replyLengths": [1],
             "signals": [{"id": "OTHER", "name": "Other", "path": "Body",
               "fmt": {"len": 8, "max": 255, "unit": "scalar"}}]}
          ]
        },
        {
          "id": "test-bmw", "make": "Testwerke", "model": "Synthetic", "modelYear": 2019,
          "source": {"repository": "test/bmw", "commit": "0000000000000000000000000000000000000002",
                     "url": "https://example.invalid", "signalset": "s.json", "support": "s.yaml"},
          "modules": [
            {"id": "engine", "name": "Engine", "servedByDefault": true,
             "target": {"kind": "bmwExtended", "address": "12", "request": "6F1", "response": "612"}},
            {"id": "transmission", "name": "Transmission", "servedByDefault": true,
             "target": {"kind": "bmwExtended", "address": "18", "request": "6F1", "response": "618"}}
          ],
          "commands": [
            {"id": "B.DA2E", "module": "transmission", "did": "DA2E", "freq": 1, "fcm1": true, "evidence": "catalog",
             "replyLengths": [2],
             "signals": [{"id": "GEAR", "name": "Gear", "path": "Transmission",
               "fmt": {"len": 8, "map": {"3": {"description": "Drive", "value": "DRIVE"}}}}]},
            {"id": "B.DA23", "module": "transmission", "did": "DA23", "freq": 1, "fcm1": true, "evidence": "catalog",
             "replyLengths": [4],
             "signals": [{"id": "ODO", "name": "Odometer", "path": "Trips",
               "fmt": {"len": 32, "max": 4294967295, "unit": "kilometers"}}]},
            {"id": "B.4001", "module": "engine", "did": "4001", "freq": 1, "fcm1": true, "evidence": "catalog",
             "replyLengths": [1],
             "signals": [{"id": "DME", "name": "DME", "path": "Engine",
               "fmt": {"len": 8, "max": 255, "unit": "scalar"}}]}
          ]
        }
      ]
    }
    """

    static func catalog() -> OEMCatalog {
        // swiftlint:disable:next force_try
        try! OEMCatalog(data: Data(json.utf8))
    }

    static func vehicle(_ id: String) -> OEMCatalogVehicle {
        catalog().vehicle(id: id)!
    }

    static func command(_ id: String, in vehicleID: String) -> OEMCatalogCommand {
        vehicle(vehicleID).commands.first { $0.id == id }!
    }

    static func batch(_ vehicleID: String, _ commandIDs: [String], budget: TimeInterval = 2.0) throws -> OEMReadBatch {
        let vehicle = vehicle(vehicleID)
        let commands = commandIDs.map { id in vehicle.commands.first { $0.id == id }! }
        return try OEMReadBatch(vehicle: vehicle, commands: commands, budget: budget)
    }
}

final class FakeClock: OEMClock {
    private(set) var time: TimeInterval = 1000

    func now() -> TimeInterval { time }

    func advance(_ seconds: TimeInterval) { time += seconds }

    /// Moves the clock forward to `instant`; never backwards.
    func advance(to instant: TimeInterval) { time = Swift.max(time, instant) }
}

/// The adapter as an ordered answer stream behind a transport that owns it, the way the executor
/// sees a real ELM327 through `OBDMessageProcessor` and `BLECommandExchange`.
///
/// **The adapter.** Every written command queues its answer (or answers, for a module that says
/// "response pending" first) with an arrival time of `write time + latency`, or queues nothing
/// at all (a lost write, silence), or throws at the call (link loss, cancellation). The adapter
/// answers in order, so an answer never arrives before an earlier command's.
///
/// **The transport rules this double mirrors** (the real ones live in `OBDMessageProcessor`,
/// `OBDStreamResynchronizer` and `BLECommandExchange`, and are tested against the real code in
/// `OBDStreamResynchronizerTests` and `OBDStreamOwnershipTests`, not here):
///
/// - The stream is `dirty` once a slot ends without its complete answer: a `send` or `listen`
///   that times out or is cancelled, a bare prompt answering a command, a thrown write, an answer
///   found waiting when a command is about to be written, `requireResynchronization()`, and
///   `injectLateAnswer` (an earlier command's answer is on its way). Only a proof clears it.
/// - `send` on a dirty stream runs `resynchronize(deadline:)` first. Unproven: nothing is written
///   and the call throws `OBDStreamError.unsynchronized` as soon as the proof gives up. On a clean stream the
///   next prompt-terminated answer is this command's own; `NO DATA` throws `BLEManagerError.noData`.
/// - `listen` on a dirty stream times out at once and consumes nothing. On a clean one it takes
///   the next answer; a bare prompt (`.lines([])`) is skipped and the listen goes on.
/// - `resynchronize(deadline:)` follows the real algorithm with the real `Timing()`: drain until
///   quiet (answers that arrive are discarded), then `ATRV` and `ATDPN` as ordinary scripted
///   writes, each judged by `OEMAdapterCommand.syncProbes[i].isAnswer`. A probe is skipped while
///   an earlier send of it is unanswered and freed when that late answer is discarded; `?` ends a
///   window early; a probe answer with another answer already behind it proves nothing.
///
/// Waiting advances the fake clock: to an answer's arrival, or to the deadline. Nothing sleeps.
final class ScriptedOEMChannel: OEMCommandChannel {
    static let defaultLatency: TimeInterval = 0.05

    /// One prompt-terminated answer. `.lines([])` is a bare prompt.
    enum Answer: Equatable {
        case lines([String])
        /// `NO DATA` and a prompt.
        case noData
    }

    struct Delivery {
        var answer: Answer
        /// Seconds after the write.
        var after: TimeInterval
    }

    /// What one write of a command does.
    struct Step {
        /// Prompt-terminated answers, in order. Empty: the command is never answered.
        var deliveries: [Delivery]
        /// Thrown at the call instead; nothing is queued.
        var thrown: Error?
        /// A busy adapter: written while an earlier answer is still on its way, this command
        /// interrupts it. The pending request answers `STOPPED` and this command answers `?`.
        /// When nothing is outstanding it behaves like `deliveries`.
        var interruptsBusyAdapter = false

        static func lines(_ lines: [String], latency: TimeInterval = ScriptedOEMChannel.defaultLatency) -> Step {
            Step(deliveries: [Delivery(answer: .lines(lines), after: latency)])
        }

        static func noData(latency: TimeInterval = ScriptedOEMChannel.defaultLatency) -> Step {
            Step(deliveries: [Delivery(answer: .noData, after: latency)])
        }

        /// Several prompt-terminated answers to one request, e.g. `7F 22 78` and then the value.
        /// `nil` lines mean `NO DATA`, `[]` a bare prompt. Times are seconds after the write.
        static func prompts(_ answers: [([String]?, TimeInterval)]) -> Step {
            Step(deliveries: answers.map { lines, after in
                Delivery(answer: lines.map(Answer.lines) ?? .noData, after: after)
            })
        }

        static func error(_ error: Error) -> Step {
            Step(deliveries: [], thrown: error)
        }

        /// Written, never answered.
        static let silence = Step(deliveries: [])

        /// See `interruptsBusyAdapter`.
        static func interruptingBusyAdapter(_ idle: Step) -> Step {
            var step = idle
            step.interruptsBusyAdapter = true
            return step
        }
    }

    /// One call of `resynchronize(deadline:)`, by the executor or by `send` on a dirty stream.
    struct Resynchronization: Equatable {
        enum Outcome: Equatable { case proven, unproven, threw }
        let deadline: TimeInterval
        /// Clock when it started.
        let at: TimeInterval
        /// Whether the stream was dirty on entry (a clean one is proven at once, nothing written).
        let wasDirty: Bool
        /// The command whose `send` ran it; nil when the executor asked.
        let before: String?
        var outcome: Outcome
    }

    private struct Outstanding {
        let command: String
        let answer: Answer
        let arrival: TimeInterval
    }

    let clock: FakeClock
    /// The resynchronizer's real constants.
    let timing = OBDStreamResynchronizer.Timing()
    /// Queued steps per command, used first-in first-out before `reads` and the defaults.
    var script: [String: [Step]] = [:]
    /// Read steps by wire request (e.g. `22028D`), reused for every send.
    var reads: [String: Step] = [:]
    /// Replaces the default step for any command without a script or read entry (nil falls
    /// through to `defaultStep`). E.g. `{ _ in .silence }` for a completely silent adapter.
    var fallback: ((String) -> Step?)?
    /// Called right after each write (probes included), e.g. to cancel the sending task.
    var onSend: ((String) -> Void)?
    /// Called after an answer is consumed, with the command it belonged to.
    var onAnswer: ((String) -> Void)?

    /// Every write, probes included: the command, its absolute deadline (a probe's: the end of
    /// its window), and the clock when it was written.
    private(set) var sent: [(command: String, deadline: TimeInterval, at: TimeInterval)] = []
    /// Deadline of every `listen`.
    private(set) var listens: [TimeInterval] = []
    /// Every answer consumed: which command it belonged to, and who took it: the command that
    /// was sent, `"listen"`, a probe command, or `"drain"` (discarded unseen while resynchronizing).
    private(set) var deliveries: [(from: String, to: String, answer: Answer)] = []
    private(set) var resynchronizations: [Resynchronization] = []
    private(set) var markedUnresolved = false
    /// An earlier slot may still be answered. Only a proven resynchronization clears it.
    private(set) var dirty = false
    private var outstanding: [Outstanding] = []
    /// Sends per command that ended without their own answer since the last proof.
    private var unanswered: [String: Int] = [:]
    /// Answers discarded while resynchronizing and not yet accounted for (the processor's
    /// `lateResponses`).
    private var lateAnswers: [[String]] = []
    private var lastByteAt: TimeInterval = -.infinity

    var commands: [String] { sent.map(\.command) }
    /// Answers still on their way (not yet collected).
    var outstandingCount: Int { outstanding.count }

    init(clock: FakeClock = FakeClock()) {
        self.clock = clock
    }

    /// Queues an answer from some earlier command that is still on its way; the stream is dirty.
    func injectLateAnswer(_ lines: [String]?, arrivingIn seconds: TimeInterval, from command: String = "earlier") {
        enqueue(command: command, answer: lines.map(Answer.lines) ?? .noData, at: clock.now() + seconds)
        dirty = true
    }

    // MARK: OEMCommandChannel

    func send(_ command: String, deadline: TimeInterval) async throws -> [String] {
        // Like the BLE send path: a cancelled task never writes.
        try Task.checkCancellation()
        if hasArrivedAnswer { dirty = true } // bytes nobody asked for are not this command's
        if dirty {
            guard try resynchronize(deadline: deadline, before: command) else {
                throw OBDStreamError.unsynchronized
            }
        }

        let now = clock.now()
        sent.append((command, deadline, now))
        onSend?(command)
        let step = nextStep(for: command)
        if let thrown = step.thrown {
            endedUnanswered(command) // part of it may be on the wire
            throw thrown
        }
        write(step, command: command, at: now)
        // Cancelled while waiting for the prompt: the answer is still on its way.
        if Task.isCancelled {
            endedUnanswered(command)
            throw CancellationError()
        }
        guard let next = takeNext(by: deadline, receiver: command) else {
            clock.advance(to: deadline)
            endedUnanswered(command)
            throw BLEMessageProcessorError.responseTimeout
        }
        switch next {
        case .lines([]):
            // A bare prompt: no answer, and the real one may still come.
            endedUnanswered(command)
            throw BLEManagerError.noData
        case let .lines(lines):
            return lines
        case .noData:
            throw BLEManagerError.noData
        }
    }

    func listen(deadline: TimeInterval) async throws -> [String] {
        listens.append(deadline)
        if Task.isCancelled { throw CancellationError() }
        // Past deadline: nothing armed. Dirty: it would be handed an earlier command's answer.
        guard deadline > clock.now(), !dirty else { throw BLEMessageProcessorError.responseTimeout }
        while let next = takeNext(by: deadline, receiver: "listen") {
            switch next {
            case .lines([]): continue // a bare prompt is not an answer
            case let .lines(lines): return lines
            case .noData: throw BLEManagerError.noData
            }
        }
        clock.advance(to: deadline)
        dirty = true
        throw BLEMessageProcessorError.responseTimeout
    }

    func resynchronize(deadline: TimeInterval) async throws -> Bool {
        try resynchronize(deadline: deadline, before: nil)
    }

    func requireResynchronization() {
        dirty = true
    }

    func markAddressingUnresolved() {
        markedUnresolved = true
    }

    // MARK: Resynchronization (mirrors `OBDStreamResynchronizer.resynchronize`)

    private func resynchronize(deadline: TimeInterval, before command: String?) throws -> Bool {
        let record = Resynchronization(deadline: deadline, at: clock.now(), wasDirty: dirty, before: command, outcome: .threw)
        resynchronizations.append(record)
        let index = resynchronizations.count - 1
        let proven = try prove(deadline: deadline)
        resynchronizations[index].outcome = proven ? .proven : .unproven
        return proven
    }

    private func prove(deadline: TimeInterval) throws -> Bool {
        guard dirty else { return true }
        let started = clock.now()

        // 1. Quiet: no answer for `quietWindow`, for at most `maximumDrain`.
        let drainEnd = Swift.min(deadline, started + timing.maximumDrain)
        while true {
            try Task.checkCancellation()
            if let arrived = outstanding.last(where: { $0.arrival <= clock.now() }) {
                lastByteAt = Swift.max(lastByteAt, arrived.arrival)
            }
            let idle = clock.now() - lastByteAt
            guard idle < timing.quietWindow, clock.now() < drainEnd else { break }
            clock.advance(Swift.min(timing.quietWindow - idle, drainEnd - clock.now()))
        }

        // 2. Probes.
        for probe in OEMAdapterCommand.syncProbes {
            accountForLateAnswers()
            guard unanswered[probe.command, default: 0] == 0 else { continue }
            let now = clock.now()
            let windowEnd = Swift.min(now + timing.probeWindow, deadline)
            guard windowEnd > now else { return false }

            // Whatever already arrived predates the probe: discarded, accounted later.
            while let next = takeNext(by: now, receiver: "drain") {
                if case let .lines(lines) = next, !lines.isEmpty { lateAnswers.append(lines) }
            }
            sent.append((probe.command, windowEnd, now))
            onSend?(probe.command)
            let step = nextStep(for: probe.command)
            if let thrown = step.thrown {
                unanswered[probe.command, default: 0] += 1
                throw thrown
            }
            write(step, command: probe.command, at: now)

            var answered = false
            window: while true {
                if Task.isCancelled {
                    unanswered[probe.command, default: 0] += 1
                    throw CancellationError()
                }
                guard let next = takeNext(by: windowEnd, receiver: probe.command) else {
                    clock.advance(to: windowEnd)
                    break window
                }
                let lines: [String]
                switch next {
                case .lines([]): continue window // a bare prompt is never a probe's answer
                case let .lines(raw): lines = BLECommandExchange.answerLines(to: probe.command, from: raw)
                case .noData: lines = []
                }
                if probe.isAnswer(lines) {
                    answered = true
                    // Bytes followed the answer: something is still arriving.
                    if hasArrivedAnswer { break window }
                    dirty = false
                    unanswered.removeAll()
                    lateAnswers.removeAll()
                    return true
                }
                account(forLateAnswer: lines)
                if lines.count == 1, lines[0].trimmingCharacters(in: .whitespaces) == "?" { break window }
            }
            if !answered { unanswered[probe.command, default: 0] += 1 }
        }
        accountForLateAnswers()
        return false
    }

    private func accountForLateAnswers() {
        let late = lateAnswers
        lateAnswers.removeAll()
        late.forEach(account(forLateAnswer:))
    }

    /// A late answer to an earlier send of a probe frees that probe.
    private func account(forLateAnswer lines: [String]) {
        for probe in OEMAdapterCommand.syncProbes
        where probe.isAnswer(BLECommandExchange.answerLines(to: probe.command, from: lines)) {
            if let count = unanswered[probe.command], count > 0 { unanswered[probe.command] = count - 1 }
        }
    }

    // MARK: The adapter

    private var hasArrivedAnswer: Bool {
        outstanding.first.map { $0.arrival <= clock.now() } ?? false
    }

    private func endedUnanswered(_ command: String) {
        dirty = true
        unanswered[command, default: 0] += 1
    }

    private func write(_ step: Step, command: String, at now: TimeInterval) {
        if step.interruptsBusyAdapter, !outstanding.isEmpty {
            // The command's first byte stops the pending request.
            let interrupted = outstanding[0].command
            outstanding.removeAll()
            enqueue(command: interrupted, answer: .lines(["STOPPED"]), at: now + Self.defaultLatency)
            enqueue(command: command, answer: .lines(["?"]), at: now + Self.defaultLatency)
        } else {
            for delivery in step.deliveries {
                enqueue(command: command, answer: delivery.answer, at: now + delivery.after)
            }
        }
    }

    private func nextStep(for command: String) -> Step {
        if var queue = script[command], !queue.isEmpty {
            let step = queue.removeFirst()
            script[command] = queue
            return step
        }
        if let read = reads[command] { return read }
        if let step = fallback?(command) { return step }
        return Self.defaultStep(command)
    }

    /// The adapter answers in order: nothing arrives before an earlier answer.
    private func enqueue(command: String, answer: Answer, at arrival: TimeInterval) {
        let ordered = Swift.max(arrival, outstanding.last?.arrival ?? arrival)
        outstanding.append(Outstanding(command: command, answer: answer, arrival: ordered))
    }

    /// Consumes the earliest outstanding answer if it arrives by `deadline`, advancing the clock.
    private func takeNext(by deadline: TimeInterval, receiver: String) -> Answer? {
        guard let next = outstanding.first, next.arrival <= deadline else { return nil }
        outstanding.removeFirst()
        clock.advance(to: next.arrival)
        lastByteAt = Swift.max(lastByteAt, next.arrival)
        deliveries.append((next.command, receiver, next.answer))
        onAnswer?(next.command)
        return next.answer
    }

    /// `OK` to adapter commands, a voltage to `ATRV`, a protocol number to `ATDPN`, a full
    /// `41 00` to `0100`, `NO DATA` to anything else.
    static func defaultStep(_ command: String) -> Step {
        switch command {
        case "ATRV": return .lines(["14.1V"])
        case "ATDPN": return .lines(["A6"])
        case "0100": return .lines(["7E8064100BE3EB811", "7E906410080000001"])
        default: return command.hasPrefix("AT") ? .lines(["OK"]) : .noData()
        }
    }
}

/// Runs `batch` in its own task, so a test can cancel "the caller" from inside the channel.
func runOEMBatch(
    _ batch: OEMReadBatch,
    on channel: ScriptedOEMChannel,
    deadline: TimeInterval? = nil,
    admission: OEMBatchAdmission? = nil
) async -> OEMBatchResult {
    let executor = OEMBatchExecutor(batch: batch, clock: channel.clock)
    return await Task { await executor.run(on: channel, deadline: deadline, admission: admission) }.value
}

/// Scripted admission answers, in order; the last one repeats. Counts every question.
@MainActor
final class OEMAdmissionScript {
    private var answers: [Bool]
    private(set) var calls = 0

    nonisolated init(_ answers: [Bool]) {
        self.answers = answers
    }

    func next() -> Bool {
        calls += 1
        return answers.count > 1 ? answers.removeFirst() : (answers.first ?? true)
    }

    nonisolated var admission: OEMBatchAdmission {
        { self.next() }
    }
}

extension XCTestCase {
    /// Loads a bundled fixture from `Fixtures/OEM`.
    func oemFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/OEM"),
            "Missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }
}
