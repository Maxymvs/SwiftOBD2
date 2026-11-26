//
//  OBDWireLog.swift
//  SwiftOBD2
//
//  The one place that decides what of an exchange's wire content may be logged.
//
//  Ordinary OBD traffic is logged in full, as it always was. A manufacturer (Mode 22) exchange is
//  not: its commands name a module's addressing and its answers are raw module data, so for those
//  neither the command text nor any response text may reach a log. Only a neutral line with the
//  outcome class and timing is written.
//
//  Redaction has two sources:
//
//  - **Per exchange.** A send or listen on the manufacturer channel asks for `.redacted`.
//  - **Held.** While a manufacturer channel is open, and afterwards for as long as the stream may
//    still carry one of its answers, *everything* is redacted, whoever logs it. A late answer can
//    arrive after the channel closed and be parsed for another command (a recovery `ATZ`, a
//    probe), and it is still manufacturer data. The hold ends only when the stream is known
//    clean: the channel closed with the adapter functional (restore verified, so the stream was
//    proven in sync), the addressing gate opened after a verified recovery, or the link was torn
//    down.
//
//  The decision is a pure function (`render`) and the output goes to an injectable sink, so tests
//  see exactly what would be logged.
//

import Foundation

/// How much of an exchange's wire content may be logged.
enum OBDWireLogPolicy: Equatable, Sendable {
    /// Commands and responses in full.
    case full
    /// No command or response text: only the outcome class and timing.
    case redacted
}

/// Something worth logging about one exchange. Carries the raw content; `OBDWireLog.render`
/// decides whether any of it is written.
enum OBDWireEvent: Equatable, Sendable {
    /// The command's bytes were written and acknowledged.
    case sent(command: String)
    /// A prompt-terminated answer to `command`.
    case answered(command: String, lines: [String], elapsed: TimeInterval)
    /// The processor split one prompt-terminated response into lines. `command` is the command
    /// the slot was armed for (compacted, upper case), nil for a listen without a write.
    case parsed(lines: [String], command: String? = nil, identifying: Bool = false)
    /// An attempt failed and the command will be written again (ordinary traffic only).
    case retrying(command: String, attempt: Int, attempts: Int, outcome: OBDWireOutcome, detail: String)
    /// The exchange ended without an answer.
    case failed(command: String, attempts: Int, outcome: OBDWireOutcome, detail: String, elapsed: TimeInterval)
    /// A listen window (no write) delivered an answer.
    case listenAnswered(lines: [String], elapsed: TimeInterval, command: String? = nil)
    /// A listen window (no write) ended without an answer.
    case listenEnded(outcome: OBDWireOutcome, detail: String, elapsed: TimeInterval)
    /// A transaction stopped listening because its budget ran out.
    case listenBudgetExhausted(command: String)
    /// Bytes arrived on a characteristic that isn't (or is no longer) the adapter's read channel.
    /// Only the count is kept: after a teardown (hold released, binding gone) these can still be a
    /// late manufacturer answer, so their content is never logged under any policy.
    case unclaimedBytes(byteCount: Int)
    /// A complete response no slot owned was dropped: a late answer to a command that had
    /// already ended. Only its size is ever logged.
    case discardedLateResponse(byteCount: Int)
    /// A dirty stream was proven in sync again before the next command was written.
    case resynchronized(elapsed: TimeInterval)
    /// A dirty stream couldn't be proven in sync; the command that needed it wasn't written.
    case resynchronizationFailed(elapsed: TimeInterval)
}

/// The outcome class of a failed exchange: safe to log under any policy.
enum OBDWireOutcome: String, Equatable, Sendable {
    case noData = "no data"
    case timeout
    case cancelled
    case writeFailed = "write failed"
    case linkLost = "link lost"
    case refused
    /// The stream can't be proven in sync on this connection; nothing was sent.
    case reconnectRequired = "reconnect required"
    case other

    init(_ error: Error) {
        switch error {
        case is CancellationError:
            self = .cancelled
        case is OEMAddressingGateError:
            self = .refused
        case let streamError as OBDStreamError:
            self = streamError == .reconnectRequired ? .reconnectRequired : .timeout
        case let managerError as BLEManagerError:
            switch managerError {
            case .noData: self = .noData
            case .timeout, .sendMessageTimeout: self = .timeout
            case .peripheralNotConnected, .missingPeripheralOrCharacteristic: self = .linkLost
            default: self = .other
            }
        case let processorError as OBDMessageProcessorError:
            switch processorError {
            case .responseTimeout: self = .timeout
            case .staleRequestToken: self = .linkLost
            case .characteristicNotWritable, .writeOperationFailed: self = .writeFailed
            case .invalidResponseData: self = .other
            }
        case let writeError as BLEWriteCoordinatorError:
            self = writeError.isDeadlineExpiry ? .timeout : .writeFailed
        case is BLECommandEncodingError:
            self = .writeFailed
        default:
            self = .other
        }
    }
}

/// One line to write. `message` is exactly what reaches the log.
struct OBDWireLogRecord: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case debug, info, error
    }

    let level: Level
    let message: String
}

/// Shared by everything that logs one transport's traffic (the message processor, the
/// characteristic handler and the manager), so a hold set by the manufacturer channel reaches
/// all of them.
final class OBDWireLog: @unchecked Sendable {
    typealias Sink = @Sendable (OBDWireLogRecord) -> Void

    private let lock = NSLock()
    private var redactionHeld = false
    private let sink: Sink

    init(sink: @escaping Sink = OBDWireLog.systemSink) {
        self.sink = sink
    }

    /// Redact everything until `releaseRedaction()`.
    func holdRedaction() {
        lock.withLock { redactionHeld = true }
    }

    /// The stream is known clean: ordinary traffic may be logged in full again.
    func releaseRedaction() {
        lock.withLock { redactionHeld = false }
    }

    var isRedactionHeld: Bool {
        lock.withLock { redactionHeld }
    }

    /// The policy that applies to an exchange that asked for `requested`.
    func effectivePolicy(_ requested: OBDWireLogPolicy) -> OBDWireLogPolicy {
        Self.effectivePolicy(requested, redactionHeld: isRedactionHeld)
    }

    func record(_ event: OBDWireEvent, policy: OBDWireLogPolicy = .full) {
        guard let record = Self.render(event, policy: effectivePolicy(policy)) else { return }
        sink(record)
    }

    // MARK: The decision

    static func effectivePolicy(_ requested: OBDWireLogPolicy, redactionHeld: Bool) -> OBDWireLogPolicy {
        redactionHeld ? .redacted : requested
    }

    /// What is written for `event` under `policy`; nil writes nothing. Under `.redacted` no
    /// command, response or error text is used, only the event's kind, outcome class and timing.
    static func render(_ event: OBDWireEvent, policy: OBDWireLogPolicy) -> OBDWireLogRecord? {
        switch policy {
        case .full:
            return renderFull(event)
        case .redacted:
            return renderRedacted(event)
        }
    }

    private static func renderFull(_ event: OBDWireEvent) -> OBDWireLogRecord? {
        switch event {
        case let .sent(command):
            return OBDWireLogRecord(level: .info, message: "Sent command: \(command)")
        case let .answered(command, lines, _):
            if isIdentifying(command: command, lines: lines) {
                return OBDWireLogRecord(level: .debug, message: "Command response: \(identifyingSummary(lines))")
            }
            return OBDWireLogRecord(level: .debug, message: "Command response: \(lines.joined(separator: " | "))")
        case let .parsed(lines, command, identifying):
            if identifying || isIdentifying(command: command, lines: lines) {
                return OBDWireLogRecord(level: .debug, message: "Parsed response: \(identifyingSummary(lines))")
            }
            return OBDWireLogRecord(level: .debug, message: "Parsed response: \(lines)")
        case let .retrying(command, attempt, attempts, _, detail):
            return OBDWireLogRecord(
                level: .debug,
                message: "Attempt \(attempt)/\(attempts) failed for \(command): \(detail), retrying..."
            )
        case let .failed(command, attempts, _, detail, _):
            return OBDWireLogRecord(level: .error, message: "Command failed after \(attempts) attempts: \(command) - \(detail)")
        case let .listenAnswered(lines, _, command):
            if isIdentifying(command: command, lines: lines) {
                return OBDWireLogRecord(level: .debug, message: "Extra listen window delivered: \(identifyingSummary(lines))")
            }
            return OBDWireLogRecord(level: .debug, message: "Extra listen window delivered: \(lines.joined(separator: " | "))")
        case let .listenEnded(_, detail, _):
            return OBDWireLogRecord(level: .debug, message: "Extra listen window ended with no response: \(detail)")
        case let .listenBudgetExhausted(command):
            return OBDWireLogRecord(level: .debug, message: "Extra listen budget exhausted for \(command)")
        case let .unclaimedBytes(byteCount):
            return OBDWireLogRecord(level: .info, message: "\(byteCount) bytes on an unclaimed characteristic")
        case .discardedLateResponse, .resynchronized, .resynchronizationFailed:
            return renderStreamOwnership(event)
        }
    }

    static func isIdentifying(command: String?, lines: [String]) -> Bool {
        OBDReplyPrivacy.shouldWithholdVIN(command: command, lines: lines)
    }

    static func isVINRequest(_ command: String?) -> Bool {
        OBDReplyPrivacy.isVINRequest(command)
    }

    /// The neutral line an identifying reply is logged as: how many lines, never what they said.
    static func identifyingSummary(_ lines: [String]) -> String {
        let count = lines.count == 1 ? "1 line" : "\(lines.count) lines"
        return "identifying reply withheld (\(count))"
    }

    private static func renderRedacted(_ event: OBDWireEvent) -> OBDWireLogRecord? {
        let prefix = "Manufacturer exchange"
        switch event {
        case .sent, .parsed, .listenBudgetExhausted:
            // The answer or the failure that follows says everything that may be said.
            return nil
        case let .answered(_, _, elapsed):
            return OBDWireLogRecord(level: .debug, message: "\(prefix): answered in \(milliseconds(elapsed)) ms")
        case let .retrying(_, attempt, attempts, outcome, _):
            return OBDWireLogRecord(
                level: .debug,
                message: "\(prefix): attempt \(attempt)/\(attempts) ended (\(outcome.rawValue)), retrying"
            )
        case let .failed(_, _, outcome, _, elapsed):
            return OBDWireLogRecord(
                level: .debug,
                message: "\(prefix): ended without an answer (\(outcome.rawValue)) after \(milliseconds(elapsed)) ms"
            )
        case let .listenAnswered(_, elapsed, _):
            return OBDWireLogRecord(level: .debug, message: "\(prefix): listen answered in \(milliseconds(elapsed)) ms")
        case let .listenEnded(outcome, _, elapsed):
            return OBDWireLogRecord(
                level: .debug,
                message: "\(prefix): listen ended (\(outcome.rawValue)) after \(milliseconds(elapsed)) ms"
            )
        case let .unclaimedBytes(byteCount):
            return OBDWireLogRecord(level: .info, message: "\(prefix): \(byteCount) bytes on an unclaimed characteristic")
        case .discardedLateResponse, .resynchronized, .resynchronizationFailed:
            return renderStreamOwnership(event)
        }
    }

    /// Stream-ownership events carry no wire content, so they read the same under both policies.
    private static func renderStreamOwnership(_ event: OBDWireEvent) -> OBDWireLogRecord? {
        switch event {
        case let .discardedLateResponse(byteCount):
            return OBDWireLogRecord(level: .info, message: "Discarded a late response nobody owned (\(byteCount) bytes)")
        case let .resynchronized(elapsed):
            return OBDWireLogRecord(level: .info, message: "Stream resynchronized in \(milliseconds(elapsed)) ms")
        case let .resynchronizationFailed(elapsed):
            return OBDWireLogRecord(
                level: .error,
                message: "Stream could not be resynchronized after \(milliseconds(elapsed)) ms; nothing was written"
            )
        default:
            return nil
        }
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((max(0, seconds) * 1_000).rounded())
    }

    /// Production: the package logger, in the communication category.
    static let systemSink: Sink = { record in
        switch record.level {
        case .debug: obdDebug(record.message, category: .communication)
        case .info: obdInfo(record.message, category: .communication)
        case .error: obdError(record.message, category: .communication)
        }
    }
}

/// Shared VIN export policy for transport logs and diagnostic captures.
public enum OBDReplyPrivacy {
    /// A VIN request or positive VIN response withholds the whole reply. When framing
    /// is damaged, a raw marker anywhere in the reply is enough to withhold it.
    public static func shouldWithholdVIN(command: String?, lines: [String]) -> Bool {
        if isVINRequest(command) { return true }
        return hasRawVINMarker(lines) && OBDOwedAnswerTracker.carriesVIN(lines, ignoringEchoOf: command.map(compact))
    }

    static func isVINRequest(_ command: String?) -> Bool {
        command.map { vinRequests.contains(compact($0)) } ?? false
    }

    static func hasRawVINMarker(_ lines: [String]) -> Bool {
        let text = compact(lines.joined())
        return text.contains("4902") || text.contains("62F190")
    }

    static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.uppercased()
    }

    private static let vinRequests: Set<String> = ["0902", "22F190"]
}
