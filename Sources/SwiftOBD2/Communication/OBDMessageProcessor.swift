//
//  OBDMessageProcessor.swift
//  SwiftOBD2
//
//  The request/response slot every stream transport shares: bytes in, `>`-terminated responses
//  out, one pending request at a time.
//
//  It started life as `BLEMessageProcessor` and is transport-neutral: nothing in it knows about
//  CoreBluetooth. WiFi feeds it from a continuous receive pump, so both transports get the same
//  framing, the same timeout semantics (the timeout applies to the *wait*, never to a socket read
//  that would have to be abandoned) and the same ownership rules. `BLEMessageProcessor` remains
//  as an alias so the BLE call sites and their tests are untouched.
//
//  ## Stream ownership
//
//  The adapter answers commands in the order it received them and ends each answer with a
//  prompt. Nothing on the wire says which command an answer belongs to; position is the only
//  link. So the processor tracks whether that link still holds:
//
//  - The stream is **clean** while every command written has had its prompt consumed and no
//    bytes have arrived since. Only then is the next prompt-terminated response the answer to
//    the next command.
//  - The stream turns **dirty** whenever a slot ends without its complete reply: a timeout, a
//    cancellation, a failed or uncertain write, a bare prompt with no text, bytes found waiting
//    when a command is about to be written, a buffer overflow. A late answer may then still
//    arrive, whole or in pieces, and it would look exactly like the next command's answer.
//  - A dirty stream stays dirty across timeouts and retries. `beginRequest` refuses to arm on
//    it, so nothing can be written and credited. Only a proven resynchronization clears it
//    (`OBDStreamResynchronizer`: wait until the stream is quiet, then a probe whose complete
//    answer nothing else can produce), or a new link (`reset()`).
//  - Bytes keep their owner. Whatever was in the buffer before a probe is written belongs to
//    the past: when its prompt arrives the whole response is discarded, so the tail of a late
//    frame can never complete into a probe's answer.
//  - Whitespace between responses is nobody's. The front of the buffer is always a prompt
//    boundary (the start of the link, or the byte after a consumed prompt), and some adapters
//    send a CR/LF after the prompt (`ELM327 v1.5\r>\r\n`). Those separators are dropped as they
//    arrive: they are not unowned bytes, not a stale fragment, and not "bytes after a probe's
//    answer".
//
//  ## Owed final answers
//
//  A response can say that its real answer comes later: a module answers "response pending"
//  (`7F <service> 78`) and the adapter returns to its prompt, or a multi-frame message starts
//  and the prompt comes before its remaining frames. The prompt was consumed, so by the rule
//  above the stream would be clean, yet an answer is outstanding. So the slot keeps a second
//  record, the **exchange**: the command last armed and every response its slots consumed
//  (`OBDOwedAnswerTracker`). It is updated under the lock as each prompt is consumed, whoever is
//  waiting and whether or not anyone collects the response.
//
//  - The exchange's write-free listens can still receive its final answer. The next command
//    ends that exchange and requires adapter proof, but the ECU debt survives independently.
//  - After proof, unrelated services can write. Matching late frames are discarded before
//    any slot can take them. A matching-service write waits until the debt settles or expires.
//  - A link reset clears both kinds of state. VIN continuation redaction has its own lifetime.
//
////  The caller's own "keep listening" test decides how long it listens. It decides nothing about
//  what the stream owes.
//
//  A clean stream pays one flag check under the lock that was already taken, plus the tracker's
//  look at each response's lines.
//
//  Two `BLEManagerError` values are used as the module's transport-neutral signals: `.noData` for
//  "the adapter answered nothing" and `.peripheralNotConnected` for "the slot died with the
//  link". They keep their exact meaning for BLE; the WiFi transport translates them into
//  `CommunicationError` at its own boundary.
//

import Foundation
import OSLog

// MARK: - Request Token & State Machine

/// Opaque token returned by `beginRequest()` to scope all subsequent operations
/// to the correct request generation.
struct RequestToken {
    let generation: Int
}

/// The stream could not attribute an answer or safely arm a request.
enum OBDStreamError: Error, Equatable {
    /// An earlier slot ended without its complete reply (or unowned bytes are waiting), and no
    /// resynchronization has proven the stream clean since. Nothing was armed, so nothing may
    /// be written.
    case unsynchronized
    /// A responder still owes an indistinguishable reply. The new request was not written.
    case ecuResponsePending
    /// Consecutive frames could have belonged to competing transfers from the same ECU.
    case ambiguousResponse
    /// The stream is dirty and can't be proven clean on this connection: every probe has an
    /// earlier send of its own still unanswered, so no probe answer could be attributed. Nothing
    /// was written. Only a reconnect recovers (it resets the adapter and starts a new stream);
    /// waiting and retrying does not.
    case reconnectRequired
}

extension OBDStreamError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsynchronized:
            return "The adapter's stream could not be proven in sync; the command was not sent."
        case .ecuResponsePending:
            return "An ECU still owes a reply for this service; the command was not sent."
        case .ambiguousResponse:
            return "The ECU's reply could not be separated from an earlier transfer."
        case .reconnectRequired:
            return "The adapter's stream can't be resynchronized on this connection; the adapter must be reconnected."
        }
    }
}

/// What a slot is waiting for. Decides what may resolve it.
private enum SlotKind {
    /// A command written on a clean stream: the next prompt-terminated response is its answer.
    case command
    /// A listen without a write on a clean stream (after "response pending").
    case continuation
    /// A resynchronization probe on a dirty stream. The caller judges each response by its
    /// shape; a bare prompt is never one.
    case probe
}

/// Internal state of a single pending request.
private enum RequestState {
    case waitingForResponse
    /// Resolved before `awaitResponse` suspended. `receivedAt` is when the reply's prompt was
    /// consumed; nil for an outcome that isn't a reply (a timeout, a cancellation).
    case early(Result<[String], Error>, receivedAt: TimeInterval?)
    case suspended(CheckedContinuation<[String], Error>, deadline: TimeInterval)
    case completed

    /// Whether this slot can still take a completed response off the buffer.
    ///
    /// A slot that already resolved must not consume one: the bytes belong to whoever arms next.
    var canAcceptResponse: Bool {
        switch self {
        case .waitingForResponse, .suspended:
            return true
        case .early, .completed:
            return false
        }
    }
}

/// A single pending request slot (the sole source of truth for request lifecycle).
private struct PendingRequest {
    let generation: Int
    let kind: SlotKind
    /// The command this slot was armed for, compacted, when it was armed for a write.
    let command: String?
    var state: RequestState
}

// MARK: - BLEMessageProcessor

class OBDMessageProcessor {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "OBDMessageProcessor")

    /// How much unclaimed data may be retained before it is dropped.
    private let maxBufferSize: Int

    /// What of this stream's traffic may be logged. Shared with the transport that feeds this
    /// processor, so a redaction hold set for a manufacturer exchange also covers answers parsed
    /// here after the exchange ended.
    let wireLog: OBDWireLog

    /// Monotonic seconds. Every deadline this processor is given is on this clock, and so is the
    /// timestamp it puts on a reply when its prompt is consumed.
    let clock: @Sendable () -> TimeInterval

    init(
        maxBufferSize: Int = BLEConstants.maxBufferSize,
        wireLog: OBDWireLog = OBDWireLog(),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.maxBufferSize = maxBufferSize
        self.wireLog = wireLog
        self.clock = clock
    }

    private let lock = NSLock()

    // All mutable state is protected by `lock`
    private var pendingRequest: PendingRequest?
    private var currentGeneration: Int = 0
    private var buffer = Data()

    // Stream ownership. See the file header.
    private var streamDirty = false
    /// A resynchronization is running: responses that arrive between two probe slots are kept
    /// for the next one instead of being discarded.
    private var resynchronizing = false
    /// How many bytes at the front of `buffer` arrived before the last write. A response that
    /// starts inside them belongs to an earlier command and is discarded when its prompt arrives.
    private var staleByteCount = 0
    /// The buffer overflowed and was dropped mid-response: what follows, through the next
    /// prompt, is the rest of that response.
    private var discardThroughNextPrompt = false
    /// Commands written since the stream was last proven clean whose prompt never arrived, with
    /// how many times. A probe can't prove anything while an earlier send of the same command
    /// may still be answered.
    private var unanswered: [String: Int] = [:]
    /// Responses discarded since the last `takeLateResponses()`: late answers to dead slots.
    /// Memory only, never logged. Bounded.
    private var lateResponses: [[String]] = []
    private var lastByteAt: TimeInterval = -.infinity
    /// The exchange in progress: the command last armed and every response its slots consumed.
    private var exchange: OBDOwedAnswerTracker?
    private var exchangeCommand: String?
    private var exchangeGeneration: Int?
    /// ECU replies owed to ended exchanges, including across adapter probes.
    private var abandonedExchanges: [OBDOwedAnswerTracker] = []
    private var lastAbandonedCommand: String?
    private var vinReplies = OBDOwedAnswerTracker.VINReplies()
    /// Nil while the adapter is still discovering the vehicle's protocol.
    private var legacyFraming: Bool?
    private var promptGeneration = 0
    private var linkGeneration = 0
    /// When a resynchronization first found every probe unanswered on this dirty stream, on
    /// `clock`. Nil whenever that isn't known to be the case.
    private var probesExhaustedAt: TimeInterval?

    private static let maximumLateResponses = 16

    // MARK: - Stream ownership

    /// Whether an earlier slot may still be answered: the stream is dirty, or the exchange
    /// still owes a final answer (which only that exchange's own listens may take). See the
    /// file header.
    var isStreamDirty: Bool {
        lock.withLock { streamDirty || exchange?.isOwed == true }
    }

    /// Whether the current exchange still owes a final answer on a stream that is otherwise
    /// in sync: a write-free listen may be armed, a command may not.
    var isFinalAnswerOwed: Bool {
        lock.withLock { !streamDirty && exchange?.isOwed == true }
    }

    /// Declares the stream dirty from outside: the caller knows an answer may still arrive that
    /// the processor can't know about (a module said "response pending" and never followed up).
    func markStreamDirty() {
        lock.withLock { markDirtyLocked(unanswered: nil) }
    }

    /// Absolute instant the current quiet window ends.
    func quietDeadline(after interval: TimeInterval) -> TimeInterval {
        lock.withLock { lastByteAt + interval }
    }

    /// How many sends of `command` since the last proof never got their prompt.
    func unansweredCount(of command: String) -> Int {
        lock.withLock { unanswered[Self.compacted(command), default: 0] }
    }

    /// A send of `command` ended without its own answer.
    func noteUnanswered(_ command: String) {
        lock.withLock { unanswered[Self.compacted(command), default: 0] += 1 }
    }

    /// A late answer to an earlier send of `command` arrived and was discarded, so one fewer is
    /// outstanding.
    func noteLateAnswer(to command: String) {
        lock.withLock {
            let key = Self.compacted(command)
            guard let count = unanswered[key], count > 0 else { return }
            unanswered[key] = count == 1 ? nil : count - 1
            if count == 1 { probesExhaustedAt = nil }
        }
    }

    /// Records that every probe is unanswered on this dirty stream, and returns when that was
    /// first recorded (on `clock`). A late probe answer, a proof or a new link ends it.
    func noteProbesExhausted() -> TimeInterval {
        lock.withLock {
            if let probesExhaustedAt { return probesExhaustedAt }
            let now = clock()
            probesExhaustedAt = now
            return now
        }
    }

    /// The responses discarded since the last call, oldest first. Between probe slots,
    /// complete buffered replies also belong to the past before choosing another probe.
    func takeLateResponses(drainingUnowned: Bool = false) -> [[String]] {
        lock.withLock {
            if drainingUnowned, streamDirty, pendingRequest?.state.canAcceptResponse != true {
                staleByteCount = buffer.count
                discardUnownedResponsesLocked()
            }
            defer { lateResponses.removeAll() }
            return lateResponses
        }
    }

    /// Starts a resynchronization. Until `endResynchronization()` or `confirmSynchronized()`,
    /// a response that arrives while no probe slot is armed waits for the next one.
    ///
    /// An exchange that still owes its final answer is over once someone resynchronizes: the
    /// stream turns dirty first, so what is buffered is discarded as late like any other.
    func beginResynchronization() {
        lock.withLock {
            if !streamDirty, exchange?.isOwed == true { markDirtyLocked(unanswered: nil) }
            resynchronizing = true
        }
    }

    /// Ends a resynchronization that proved nothing. Everything still buffered belongs to the
    /// past.
    func endResynchronization() {
        lock.withLock {
            guard resynchronizing else { return }
            resynchronizing = false
            staleByteCount = buffer.count
            discardUnownedResponsesLocked()
        }
    }

    /// Declares the adapter in sync after a probe's own answer arrived. Refused (false) when
    /// bytes followed the answer. ECU replies can still be outstanding.
    func confirmSynchronized() -> Bool {
        lock.withLock {
            guard buffer.isEmpty, !discardThroughNextPrompt else { return false }
            if let request = pendingRequest, request.state.canAcceptResponse { return false }
            streamDirty = false
            resynchronizing = false
            staleByteCount = 0
            unanswered.removeAll()
            lateResponses.removeAll()
            endExchangeLocked()
            lastAbandonedCommand = nil
            probesExhaustedAt = nil
            return true
        }
    }

    /// Must be called with `lock` held.
    private func markDirtyLocked(unanswered command: String?) {
        streamDirty = true
        endExchangeLocked()
        if let command { unanswered[command, default: 0] += 1 }
        guard !resynchronizing else { return }
        // Whatever is buffered now belongs to the slot that just died.
        staleByteCount = buffer.count
        discardUnownedResponsesLocked()
    }

    private func endExchangeLocked() {
        if let exchange, exchange.isOwed { abandonedExchanges.append(exchange) }
        if let exchangeCommand { lastAbandonedCommand = exchangeCommand }
        exchange = nil
        exchangeCommand = nil
        exchangeGeneration = nil
    }

    private func expireECUDebtLocked(at now: TimeInterval) {
        for index in abandonedExchanges.indices.reversed() {
            abandonedExchanges[index].expire(at: now)
            if !abandonedExchanges[index].isOwed { abandonedExchanges.remove(at: index) }
        }
    }

    // MARK: - beginRequest

    /// Arms the slot for a command that is about to be written. **Must** be called before the
    /// write, so an answer that arrives at once still lands in this slot.
    ///
    /// Throws `OBDStreamError.unsynchronized` without arming when the stream is dirty, or when
    /// bytes are waiting that no slot owns (which makes it dirty). The caller must resynchronize
    /// before writing anything but a probe.
    ///
    /// Returns a `RequestToken` that must be passed to `awaitResponse`.
    func beginRequest(command: String? = nil) throws -> RequestToken {
        try arm(kind: .command, command: command.map(Self.compacted))
    }

    /// Arms before writing, waiting only when a proven stream still has matching ECU debt.
    /// An ordinary caller waits up to one P2* window. An explicit caller deadline takes
    /// precedence if earlier, and a link reset invalidates an in-progress wait.
    func beginRequestWaitingForECU(command: String, deadline: TimeInterval? = nil) async throws -> RequestToken {
        let compact = Self.compacted(command)
        let link = lock.withLock { linkGeneration }
        let end = min(deadline ?? .infinity, clock() + OBDOwedAnswerTracker.pendingWindow)
        while true {
            try Task.checkCancellation()
            do {
                return try arm(kind: .command, command: compact, expectedLink: link)
            } catch OBDStreamError.ecuResponsePending {
                let remaining = end - clock()
                guard remaining > 0 else { throw OBDStreamError.ecuResponsePending }
                try await Task.sleep(nanoseconds: UInt64(min(0.04, remaining) * 1_000_000_000))
                // Never arm after an explicit caller deadline, even if the debt just settled.
                if let deadline, clock() >= deadline { throw OBDStreamError.ecuResponsePending }
            }
        }
    }

    // MARK: - beginContinuationRequest

    /// Arms a slot for one more prompt-terminated answer **without any write**.
    ///
    /// Used after "response pending": the module's final message may already be buffered by the
    /// time the caller decides to keep listening, and it is delivered at once. A bare prompt
    /// with no text doesn't resolve this slot; the listen goes on until its deadline.
    ///
    /// Throws `OBDStreamError.unsynchronized` on a dirty stream: a listen there would be handed
    /// some earlier command's late answer.
    func beginContinuationRequest() throws -> RequestToken {
        try arm(kind: .continuation, command: nil)
    }

    private func arm(kind: SlotKind, command: String?, expectedLink: Int? = nil) throws -> RequestToken {
        var superseded: CheckedContinuation<[String], Error>?
        var token: RequestToken?
        var delivery = Delivery.none
        var failure = OBDStreamError.unsynchronized

        lock.lock()
        if let expectedLink, expectedLink != linkGeneration {
            lock.unlock()
            throw BLEMessageProcessorError.staleRequestToken
        }
        // A slot still waiting is a command whose prompt never came. The mutex above this
        // processor shouldn't allow it; if it happens, that command's answer is outstanding.
        if let previous = pendingRequest, previous.state.canAcceptResponse {
            if case let .suspended(continuation, _) = previous.state { superseded = continuation }
            pendingRequest?.state = .completed
            markDirtyLocked(unanswered: previous.kind == .command ? previous.command : nil)
        }
        if !streamDirty, kind == .command, exchange?.isOwed == true {
            // The exchange before this command still owes its final answer. Written now, this
            // command would be handed that answer. Whatever is buffered is that late answer.
            markDirtyLocked(unanswered: nil)
        }
        if !streamDirty, kind == .command, !buffer.isEmpty {
            // Bytes nobody asked for, on a stream thought clean. They aren't this command's.
            markDirtyLocked(unanswered: nil)
        }
        expireECUDebtLocked(at: clock())
        if !streamDirty, kind == .command, abandonedExchanges.contains(where: { $0.blocks(command) }) {
            failure = .ecuResponsePending
        } else if !streamDirty {
            switch kind {
            case .command:
                exchange = OBDOwedAnswerTracker(command: command)
                exchangeCommand = command
                exchangeGeneration = currentGeneration + 1
            case .continuation:
                // A listen continues the exchange it follows.
                if exchange == nil { exchange = OBDOwedAnswerTracker(command: nil) }
            case .probe:
                break
            }
            currentGeneration += 1
            pendingRequest = PendingRequest(generation: currentGeneration, kind: kind, command: command, state: .waitingForResponse)
            token = RequestToken(generation: currentGeneration)
            // A continuation takes whatever the buffer already completed.
            delivery = drainLocked()
        }
        lock.unlock()

        deliver(delivery)
        superseded?.resume(throwing: BLEManagerError.sendingMessagesInProgress)
        guard let token else { throw failure }
        return token
    }

    // MARK: - Probe slots

    /// Arms the slot for a resynchronization probe that is about to be written, on a dirty
    /// stream. Everything already buffered predates the probe, so it is marked stale: complete
    /// responses are discarded now, and an unfinished one is discarded when its prompt arrives.
    func beginProbeRequest(command: String) -> RequestToken {
        armProbe(command: Self.compacted(command), written: true)
    }

    /// Re-arms after a response that wasn't the probe's answer, to keep listening for it without
    /// writing. Responses that arrived meanwhile are delivered in order.
    func continueProbeRequest() -> RequestToken {
        armProbe(command: nil, written: false)
    }

    private func armProbe(command: String?, written: Bool) -> RequestToken {
        var superseded: CheckedContinuation<[String], Error>?

        lock.lock()
        if let previous = pendingRequest, case let .suspended(continuation, _) = previous.state {
            superseded = continuation
        }
        streamDirty = true
        endExchangeLocked()
        if written {
            staleByteCount = buffer.count
        }
        currentGeneration += 1
        pendingRequest = PendingRequest(generation: currentGeneration, kind: .probe, command: command, state: .waitingForResponse)
        let token = RequestToken(generation: currentGeneration)
        let delivery = drainLocked()
        lock.unlock()

        deliver(delivery)
        superseded?.resume(throwing: BLEManagerError.sendingMessagesInProgress)
        return token
    }

    // MARK: - awaitResponse

    /// Waits for the response to `token`'s slot for at most `timeout` seconds from now.
    func awaitResponse(for token: RequestToken, timeout: TimeInterval) async throws -> [String] {
        try await awaitResponse(for: token, deadline: clock() + Swift.max(0, timeout))
    }

    /// Waits for the response to `token`'s slot until `deadline`, an absolute instant on `clock`.
    ///
    /// The reply counts when its prompt was consumed at or before `deadline`: the timestamp is
    /// taken under the slot's lock as the bytes arrive, so a reply that landed in time is
    /// returned even when this task collects it late, and one that landed after the cut-off is a
    /// timeout however quickly it is collected. Such a late-but-complete reply leaves the stream
    /// clean (its prompt was consumed), unless what it said leaves a final answer owed: that is
    /// recorded as the prompt is consumed, before the deadline is judged. A slot that times out
    /// with no reply leaves the stream dirty.
    func awaitResponse(for token: RequestToken, deadline: TimeInterval) async throws -> [String] {
        if Task.isCancelled {
            // The command may already be on the wire: its answer is outstanding.
            fail(token, with: CancellationError())
            throw CancellationError()
        }

        // Check for an early result / validate the token. Returns the early lines, throws on an
        // early error or a stale token, or returns nil when the request is still pending.
        let earlyLines: [String]? = try lock.withLock {
            guard let request = pendingRequest, request.generation == token.generation else {
                throw BLEMessageProcessorError.staleRequestToken
            }
            switch request.state {
            case let .early(result, receivedAt):
                pendingRequest?.state = .completed
                if Self.landedTooLate(receivedAt, deadline: deadline, kind: request.kind) {
                    throw BLEMessageProcessorError.responseTimeout
                }
                return try result.get()
            case .waitingForResponse:
                return nil
            case .suspended, .completed:
                throw BLEMessageProcessorError.staleRequestToken
            }
        }
        if let earlyLines {
            return earlyLines
        }

        // Suspend until the slot resolves. The slot is the single source of truth: an answer,
        // the timeout, a cancellation and a reset all resolve it through the same lock, and the
        // first one wins. So a timeout can never throw away an answer the drain already consumed
        // for this slot.
        let remaining = deadline - clock()
        guard remaining > 0 else {
            fail(token, with: OBDMessageProcessorError.responseTimeout)
            return try await awaitResolvedSlot(for: token, deadline: deadline)
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Swift.min(remaining, 86_400) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fail(token, with: OBDMessageProcessorError.responseTimeout)
        }
        defer { timer.cancel() }
        return try await awaitResolvedSlot(for: token, deadline: deadline)
    }

    /// Whether a reply whose prompt was consumed at `receivedAt` missed `deadline`.
    ///
    /// A probe's window bounds how long the resynchronization waits, not whether the answer is
    /// the probe's own: one consumed by its slot counts whenever it landed.
    private static func landedTooLate(_ receivedAt: TimeInterval?, deadline: TimeInterval, kind: SlotKind) -> Bool {
        guard let receivedAt, kind != .probe else { return false }
        return receivedAt > deadline
    }

    /// Suspends on `token`'s slot until something resolves it. See `awaitResponse`.
    private func awaitResolvedSlot(for token: RequestToken, deadline: TimeInterval) async throws -> [String] {
        try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                    lock.lock()
                    // Re-validate: generation must still match and state must still be waitingForResponse
                    guard let request = pendingRequest,
                          request.generation == token.generation else {
                        lock.unlock()
                        continuation.resume(throwing: BLEMessageProcessorError.staleRequestToken)
                        return
                    }

                    switch request.state {
                    case .waitingForResponse:
                        pendingRequest?.state = .suspended(continuation, deadline: deadline)
                        lock.unlock()

                    case let .early(result, receivedAt):
                        // Resolved between the initial check and here
                        pendingRequest?.state = .completed
                        lock.unlock()
                        if Self.landedTooLate(receivedAt, deadline: deadline, kind: request.kind) {
                            continuation.resume(throwing: BLEMessageProcessorError.responseTimeout)
                        } else {
                            continuation.resume(with: result)
                        }

                    case .suspended, .completed:
                        lock.unlock()
                        continuation.resume(throwing: BLEMessageProcessorError.staleRequestToken)
                    }
                }
            } onCancel: {
                fail(token, with: CancellationError())
            }
    }

    /// Terminates the slot `token` owns with `error`, whether or not its awaiting task has
    /// actually suspended yet, and marks the stream dirty: the slot ended without its reply.
    ///
    /// The "not yet suspended" half is what makes it safe: a timeout or cancellation that fires
    /// between `beginRequest()` and the continuation body used to find the slot in
    /// `.waitingForResponse`, do nothing, and leave the body to suspend on a slot nobody would
    /// ever resume, so the call hung past its own timeout. Recording the outcome as an early
    /// error means the body throws the instant it runs. A slot that already took an answer is
    /// left alone, which is what lets an answer win over a timeout firing at the same moment.
    ///
    /// Internal rather than private so the "fired before suspension" half can be tested directly:
    /// racing a real timeout against task scheduling is not reproducible.
    func fail(_ token: RequestToken, with error: Error) {
        var continuationToFail: CheckedContinuation<[String], Error>?

        lock.lock()
        if let request = pendingRequest, request.generation == token.generation {
            switch request.state {
            case let .suspended(continuation, _):
                pendingRequest?.state = .completed
                continuationToFail = continuation
                markDirtyLocked(unanswered: request.kind == .command ? request.command : nil)
            case .waitingForResponse:
                pendingRequest?.state = .early(.failure(error), receivedAt: nil)
                markDirtyLocked(unanswered: request.kind == .command ? request.command : nil)
            case .early, .completed:
                break // already resolved
            }
        }
        lock.unlock()

        continuationToFail?.resume(throwing: error)
    }

    /// Gives up `token`'s slot after its write failed or was cancelled. Some of the command may
    /// be on the wire, so the stream is dirty; late bytes can no longer resolve this slot.
    func abandonRequest(_ token: RequestToken) {
        var continuationToFail: CheckedContinuation<[String], Error>?

        lock.lock()
        if let request = pendingRequest, request.generation == token.generation {
            if case let .suspended(continuation, _) = request.state { continuationToFail = continuation }
            if request.state.canAcceptResponse {
                pendingRequest?.state = .completed
                markDirtyLocked(unanswered: request.kind == .command ? request.command : nil)
            }
        }
        lock.unlock()

        continuationToFail?.resume(throwing: BLEMessageProcessorError.staleRequestToken)
    }

    /// Gives up `token`'s slot when **nothing was written** for it: the caller armed, then found
    /// it may not send after all (a bound request whose link changed while the stream was being
    /// proven). No answer is outstanding, so the stream stays clean, unless bytes arrived
    /// while the slot was armed: nobody asked for those, and they make it dirty.
    func releaseUnwrittenRequest(_ token: RequestToken) {
        var continuationToFail: CheckedContinuation<[String], Error>?

        lock.lock()
        if let request = pendingRequest, request.generation == token.generation {
            switch request.state {
            case .waitingForResponse:
                pendingRequest?.state = .completed
                if !buffer.isEmpty { markDirtyLocked(unanswered: nil) }
            case let .suspended(continuation, _):
                pendingRequest?.state = .completed
                continuationToFail = continuation
                if !buffer.isEmpty { markDirtyLocked(unanswered: nil) }
            case .early:
                // The slot already took a response, or already failed: either way something
                // happened on a slot that never wrote.
                pendingRequest?.state = .completed
                markDirtyLocked(unanswered: nil)
            case .completed:
                break
            }
        }
        lock.unlock()

        continuationToFail?.resume(throwing: BLEMessageProcessorError.staleRequestToken)
    }

    // MARK: - processReceivedData

    /// Called from the transport's callback queue when data arrives from the adapter.
    ///
    /// A callback carries whatever the wire happened to deliver: it is not aligned to responses,
    /// so it may hold part of one, exactly one, or one and a bit. All of that is the buffer's
    /// problem; this just appends and lets the drain take at most one complete response.
    func processReceivedData(_ data: Data) {
        lock.lock()
        lastByteAt = clock()
        buffer.append(data)
        dropLeadingSeparatorsLocked()
        let delivery = drainLocked()
        lock.unlock()

        deliver(delivery)
    }

    /// A suspended continuation that must be resumed outside the lock.
    private enum Delivery {
        case none
        case lines(CheckedContinuation<[String], Error>, [String])
        case error(CheckedContinuation<[String], Error>, Error)
    }

    /// Routes the complete responses in the buffer. **Must** be called with `lock` held; the
    /// returned delivery is resumed by the caller after unlocking.
    ///
    /// For each prompt-terminated response at the front of the buffer, in order:
    ///
    /// - one that starts in bytes from before the last write is a late answer: discarded;
    /// - with an armed slot that can take it, it resolves that slot (at most one per call);
    /// - with no such slot on a dirty stream, nobody will ever own it: discarded, unless a
    ///   resynchronization is between two probe slots, in which case it waits for the next;
    /// - with no such slot on a clean stream it is **retained**. That closes the gap in the
    ///   response-pending transaction: a module's final message landing between the `7F … 78`
    ///   prompt and the continuation re-arm waits here for that re-arm. If a command is armed
    ///   instead, finding it marks the stream dirty.
    private func drainLocked() -> Delivery {
        // The prompt terminates exactly one response. Everything after it is the *next* response
        // and must survive: a single TCP callback can carry `…78\r>\r7E8 04 43 01`.
        while let promptIndex = buffer.firstIndex(of: Self.promptByte) {
            let length = buffer.distance(from: buffer.startIndex, to: promptIndex) + 1

            if staleByteCount > 0 || discardThroughNextPrompt {
                discardResponseLocked(length: length)
                continue
            }

            guard let request = pendingRequest, request.state.canAcceptResponse else {
                if streamDirty, !resynchronizing {
                    discardResponseLocked(length: length)
                    continue
                }
                if !resynchronizing, exchange?.isOwed != true, discardKnownLateResponseLocked(length: length) {
                    continue
                }
                if buffer.count > maxBufferSize {
                    logger.warning("Unclaimed response exceeded max buffer size, clearing")
                    overflowLocked()
                }
                return .none
            }

            // Consume through the prompt, keep the remainder. Splitting on the prompt *byte*
            // keeps a partial multi-byte tail intact: a continuation byte is never `>`, so the
            // prefix always ends on a character boundary. Undecodable bytes inside it become
            // replacement characters rather than blocking the response forever.
            let response = takeResponseLocked(length: length)
            // The instant the prompt was consumed: sampled here, under the lock, before parsing
            // and logging can add to it.
            let receivedAt = clock()
            promptGeneration += 1
            expireECUDebtLocked(at: receivedAt)
            let vinOwner = OBDWireLog.isVINRequest(exchangeCommand) ? exchangeGeneration : nil
            var lines = Self.lines(of: response)
            let originalCount = lines.count
            var tracker = exchange ?? OBDOwedAnswerTracker(command: lastAbandonedCommand)
            let filtered = vinReplies.filterLateFrames(
                from: &lines, at: receivedAt, prompt: promptGeneration, vinOwner: vinOwner,
                command: request.command ?? exchangeCommand, legacyFraming: legacyFraming,
                current: &tracker, debt: &abandonedExchanges
            )
            // Record debt at consumption, before cancellation or a deadline can hide the reply.
            if request.kind == .probe {
                if tracker.isOwed { abandonedExchanges.append(tracker) }
            } else {
                exchange = tracker
            }
            let ambiguous = filtered.ambiguousCurrent
            if lines.count < originalCount {
                wireLog.record(.discardedLateResponse(byteCount: length))
                // The old answer may share a prompt with the adapter echoing the new write.
                if !ambiguous, lines.allSatisfy({ Self.compacted($0) == request.command }) { continue }
            }
            // A damaged prompt cannot prove the stream, even if it included adapter text
            // that would have answered the probe on its own. Keep listening for a clean one.
            if ambiguous, request.kind == .probe { continue }

            let outcome: Result<[String], Error>
            if ambiguous {
                markDirtyLocked(unanswered: nil)
                outcome = .failure(OBDStreamError.ambiguousResponse)
            } else if lines.isEmpty {
                // A bare prompt carries no reply, so nothing says whose prompt it is.
                switch request.kind {
                case .continuation, .probe:
                    continue // Not an answer: the listen goes on until its deadline.
                case .command:
                    // Reported as before (no data), but the command's real answer may still
                    // be on its way.
                    markDirtyLocked(unanswered: request.command)
                    outcome = .failure(BLEManagerError.noData)
                }
            } else if lines.first?.uppercased().contains("NO DATA") == true {
                outcome = .failure(BLEManagerError.noData)
            } else {
                outcome = .success(lines)
            }

            if !ambiguous {
                if let command = request.command { noteProtocolLocked(command, lines: lines) }
                wireLog.record(.parsed(lines: lines, command: exchangeCommand ?? request.command,
                                       identifying: filtered.identifying))
            }

            switch request.state {
            case let .suspended(continuation, deadline):
                pendingRequest?.state = .completed
                // In time is decided here, as the prompt is consumed, not when the waiting task
                // or its timer gets to run.
                if Self.landedTooLate(receivedAt, deadline: deadline, kind: request.kind) {
                    return .error(continuation, BLEMessageProcessorError.responseTimeout)
                }
                switch outcome {
                case let .success(lines): return .lines(continuation, lines)
                case let .failure(error): return .error(continuation, error)
                }

            case .waitingForResponse:
                // The response arrived before awaitResponse was called: store it.
                pendingRequest?.state = .early(outcome, receivedAt: receivedAt)
                return .none

            case .early, .completed:
                return .none // unreachable: `canAcceptResponse` already excluded these
            }
        }

        if buffer.count > maxBufferSize {
            logger.warning("Incomplete response exceeded max buffer size, clearing")
            overflowLocked()
        }
        return .none
    }

    /// Removes and returns the first `length` bytes of the buffer (one response and its prompt).
    private func takeResponseLocked(length: Int) -> String {
        let end = buffer.index(buffer.startIndex, offsetBy: length)
        let response = String(decoding: buffer[buffer.startIndex ..< end], as: UTF8.self)
        buffer = Data(buffer[end...])
        staleByteCount = Swift.max(0, staleByteCount - length)
        dropLeadingSeparatorsLocked()
        return response
    }

    /// Drops whitespace at the front of the buffer. **Must** be called with `lock` held, after
    /// every change to the buffer's front, so the buffer never starts with a separator.
    ///
    /// The front of the buffer is always a prompt boundary, and a response's leading whitespace
    /// never reaches its lines anyway. What this changes is everything that asks "are bytes
    /// waiting?": a CR/LF some adapters send after the prompt no longer reads as unowned bytes
    /// when the next command arms, as a stale fragment that swallows a probe's answer, or as
    /// bytes following a probe's answer.
    private func dropLeadingSeparatorsLocked() {
        guard let first = buffer.first, Self.isSeparator(first) else { return }
        let kept = buffer.firstIndex(where: { !Self.isSeparator($0) }) ?? buffer.endIndex
        let dropped = buffer.distance(from: buffer.startIndex, to: kept)
        buffer = Data(buffer[kept...])
        staleByteCount = Swift.max(0, staleByteCount - dropped)
    }

    /// CR, LF, space and the other ASCII whitespace an adapter puts between responses.
    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09 ... 0x0D).contains(byte)
    }

    private func noteProtocolLocked(_ command: String, lines: [String]) {
        switch command {
        case OEMAddressingGate.describeProtocolNumber:
            let answers = lines.filter { Self.compacted($0) != command }
            if let reported = OEMAddressingGate.reportedProtocol(answers) {
                legacyFraming = reported.map { OEMAddressingGate.admittedShapes($0).contains(.legacy) }
            }
        case OEMAddressingGate.reset where OEMAddressingGate.isResetBanner(lines):
            legacyFraming = nil
        case OEMAddressingGate.functionalProbe where legacyFraming == nil:
            if OEMReply.isPositiveSupportedPIDsAnswer(lines, shapes: [.can11Bit, .can29Bit]) {
                legacyFraming = false
            } else if lines.contains(where: OBDOwedAnswerTracker.isLegacyProtocolAnswer) {
                legacyFraming = true
            }
        default:
            if OEMAddressingGate.isProtocolSelection(command),
               OEMBatchExecutor.isOK(lines.filter({ Self.compacted($0) != command })) {
                legacyFraming = OEMAddressingGate.selectedProtocol(command)
                    .map { OEMAddressingGate.admittedShapes($0).contains(.legacy) }
            }
        }
    }

    /// Drops one response nobody owns. Its lines are kept, in memory only, so a
    /// resynchronization can tell when an outstanding probe's answer finally came.
    private func discardResponseLocked(length: Int) {
        let wasCutOff = discardThroughNextPrompt
        discardThroughNextPrompt = false
        var lines = Self.lines(of: takeResponseLocked(length: length))
        wireLog.record(.discardedLateResponse(byteCount: length))
        // A response whose start was dropped in an overflow isn't any command's whole answer.
        guard !wasCutOff, !lines.isEmpty else { return }
        let now = clock()
        promptGeneration += 1
        expireECUDebtLocked(at: now)
        var tracker = OBDOwedAnswerTracker(command: lastAbandonedCommand)
        let filtered = vinReplies.filterLateFrames(
            from: &lines, at: now, prompt: promptGeneration, vinOwner: nil,
            command: lastAbandonedCommand, legacyFraming: legacyFraming, current: &tracker, debt: &abandonedExchanges
        )
        if tracker.isOwed { abandonedExchanges.append(tracker) }
        if filtered.ambiguousCurrent {
            streamDirty = true
            exchange?.interruptAll(until: now + OBDOwedAnswerTracker.pendingWindow)
            endExchangeLocked()
        }
        guard !lines.isEmpty else { return }
        if lateResponses.count >= Self.maximumLateResponses { lateResponses.removeFirst() }
        lateResponses.append(lines)
    }

    /// A known late response can settle a debt between commands on a proven stream. Leave
    /// a prompt with any unclassified content in the buffer for normal ownership handling.
    private func discardKnownLateResponseLocked(length: Int) -> Bool {
        let now = clock()
        expireECUDebtLocked(at: now)
        guard !abandonedExchanges.isEmpty || !vinReplies.isEmpty else { return false }
        var debt = abandonedExchanges
        var vin = vinReplies
        var lines = Self.lines(of: String(decoding: buffer.prefix(length), as: UTF8.self))
        guard !lines.isEmpty else { return false }
        var tracker = OBDOwedAnswerTracker(command: lastAbandonedCommand)
        let filtered = vin.filterLateFrames(
            from: &lines, at: now, prompt: promptGeneration + 1, vinOwner: nil,
            command: lastAbandonedCommand, legacyFraming: legacyFraming, current: &tracker, debt: &debt
        )
        guard lines.isEmpty else { return false }
        _ = takeResponseLocked(length: length)
        promptGeneration += 1
        abandonedExchanges = debt
        vinReplies = vin
        wireLog.record(.discardedLateResponse(byteCount: length))
        if filtered.ambiguousCurrent {
            if tracker.isOwed { abandonedExchanges.append(tracker) }
            markDirtyLocked(unanswered: nil)
        }
        return true
    }

    /// Discards every complete response in the buffer. For a dirty stream with no slot armed.
    private func discardUnownedResponsesLocked() {
        while let promptIndex = buffer.firstIndex(of: Self.promptByte) {
            discardResponseLocked(length: buffer.distance(from: buffer.startIndex, to: promptIndex) + 1)
        }
    }

    /// The buffer outgrew its bound and is dropped. What it held was part of a response, so the
    /// rest of that response (through the next prompt) is dropped too, and the stream is dirty.
    private func overflowLocked() {
        let endedOnPrompt = buffer.last == Self.promptByte
        buffer.removeAll()
        staleByteCount = 0
        discardThroughNextPrompt = !endedOnPrompt
        streamDirty = true
        endExchangeLocked()
    }

    private func deliver(_ delivery: Delivery) {
        switch delivery {
        case .none:
            break
        case let .lines(continuation, lines):
            continuation.resume(returning: lines)
        case let .error(continuation, error):
            continuation.resume(throwing: error)
        }
    }

    // MARK: - reset

    /// Full reset, called when the link goes away or a new one starts. Bumps the generation to
    /// invalidate all outstanding tokens and cancels any suspended continuation. A new link
    /// starts clean: nothing written on the old one can be answered on it.
    func reset() {
        var contToResume: CheckedContinuation<[String], Error>?

        lock.lock()
        if let request = pendingRequest, case let .suspended(continuation, _) = request.state {
            contToResume = continuation
        }
        currentGeneration += 1
        linkGeneration += 1
        pendingRequest = nil
        buffer.removeAll()
        streamDirty = false
        resynchronizing = false
        staleByteCount = 0
        discardThroughNextPrompt = false
        unanswered.removeAll()
        lateResponses.removeAll()
        lastByteAt = -.infinity
        exchange = nil
        exchangeCommand = nil
        exchangeGeneration = nil
        abandonedExchanges.removeAll()
        lastAbandonedCommand = nil
        vinReplies = OBDOwedAnswerTracker.VINReplies()
        legacyFraming = nil
        promptGeneration = 0
        probesExhaustedAt = nil
        lock.unlock()

        if let cont = contToResume {
            cont.resume(throwing: BLEManagerError.peripheralNotConnected)
        }
    }

    // MARK: - Private Helpers

    /// `>`, the ELM327 prompt that terminates one response.
    private static let promptByte: UInt8 = 0x3E

    private static func lines(of response: String) -> [String] {
        response
            .replacingOccurrences(of: ">", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func compacted(_ command: String) -> String {
        command.filter { !$0.isWhitespace }.uppercased()
    }
}

// MARK: - Error Types

enum OBDMessageProcessorError: Error, Equatable, LocalizedError {
    case characteristicNotWritable
    case writeOperationFailed
    case responseTimeout
    case invalidResponseData
    case staleRequestToken

    var errorDescription: String? {
        switch self {
        case .characteristicNotWritable:
            return "BLE characteristic does not support write operations"
        case .writeOperationFailed:
            return "Failed to write data to BLE characteristic"
        case .responseTimeout:
            return "Timeout waiting for BLE response"
        case .invalidResponseData:
            return "Received invalid response data from BLE device"
        case .staleRequestToken:
            return "Request token is stale (generation mismatch)"
        }
    }
}
