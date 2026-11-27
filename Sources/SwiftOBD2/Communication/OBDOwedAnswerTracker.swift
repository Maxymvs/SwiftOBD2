//
//  OBDOwedAnswerTracker.swift
//  SwiftOBD2
//

import Foundation

/// Tracks the responders of one exchange. Once the exchange ends, the same tracker quarantines
/// its late frames independently of the adapter's prompt synchronization.
struct OBDOwedAnswerTracker {
    // P2*ServerMax after an NRC 78 (ISO 14229 session timing). Five seconds is the
    // default budget used here without negotiated server timing. Each matching 78 restarts it.
    static let pendingWindow: TimeInterval = 5

    private let request: Request?
    private var responders: [Responder] = []
    private var unresolvedUntil: TimeInterval?

    init(command: String?) {
        request = command.flatMap(Request.init)
    }

    var isOwed: Bool { !responders.isEmpty || unresolvedUntil != nil }

    mutating func consume(_ lines: [String], at now: TimeInterval = 0, allowLegacyFraming: Bool = false) {
        for line in lines {
            consume(line, at: now, onlyOwed: false, allowLegacyFraming: allowLegacyFraming)
        }
    }

    /// A negative response echoes only the service. Commands at this boundary do not carry
    /// authoritative responder filters, so any recorded responder could answer a new request.
    func blocks(_ command: String?) -> Bool {
        guard let command else { return isOwed }
        guard let service = Request(command)?.service else { return false }
        return (request?.service == service && unresolvedUntil != nil) || responders.contains { $0.owes(service) }
    }

    mutating func expire(at now: TimeInterval) {
        if let unresolvedUntil, unresolvedUntil <= now { self.unresolvedUntil = nil }
        for index in responders.indices.reversed() {
            responders[index].pending = responders[index].pending.filter { $0.value > now }
            responders[index].interrupted = responders[index].interrupted.filter { $0.value > now }
            if let message = responders[index].message, message.expiresAt <= now {
                responders[index].message = nil
            }
            if responders[index].isIdle { responders.remove(at: index) }
        }
    }

    /// Claims one late frame, including the first and consecutive frames of an owed ISO-TP
    /// final. A matching frame updates the debt even when no request is waiting.
    mutating func discardIfOwed(_ line: String, at now: TimeInterval) -> Bool {
        consume(line, at: now, onlyOwed: true, allowLegacyFraming: false)
    }

    @discardableResult
    private mutating func consume(_ line: String, at now: TimeInterval, onlyOwed: Bool, allowLegacyFraming: Bool) -> Bool {
        guard let reply = Reply(line, isBareService: { bareServices?.contains($0) == true },
                                allowLegacyFraming: allowLegacyFraming) else { return false }
        return consume(reply, at: now, onlyOwed: onlyOwed)
    }

    private var bareServices: Dictionary<UInt8, TimeInterval>.Keys? {
        responders.first { $0.key == .headerless }?.pending.keys
    }

    @discardableResult
    private mutating func consume(_ reply: Reply, at now: TimeInterval, onlyOwed: Bool) -> Bool {
        let key = reply.key
        let existing = responders.first { $0.key == key }
        let expiry = now + Self.pendingWindow

        switch reply.payload {
        case .damaged:
            interrupt(key)
            return false

        case let .complete(head):
            guard let service = head.service else { return false }
            if onlyOwed {
                guard let existing, existing.owes(service),
                      head.isNegative || echoMatches(service: service, head: head) else { return false }
            }
            let settles = head.isNegative || echoMatches(service: service, head: head)
            update(key) { responder in
                if head.isPending {
                    responder.pending[service] = expiry
                } else if settles {
                    responder.settle(service)
                }
            }

        case let .first(message):
            if onlyOwed {
                guard let service = message.head.service, let existing, existing.owes(service),
                      echoMatches(service: service, head: message.head) else { return false }
            }
            let requestService = request?.service
            update(key) { responder in
                responder.interrupt(fallbackService: requestService)
                responder.message = message
                responder.message?.expiresAt = expiry
            }

        case let .consecutive(sequence, count):
            guard var message = existing?.message else {
                // A sequence already broke. Any further suffix from this responder remains
                // ambiguous, but without a new first frame it cannot settle the debt.
                return onlyOwed && existing?.interrupted.isEmpty == false
            }
            guard existing?.interrupted.isEmpty == true,
                  message.advance(sequence: sequence, count: count, capacity: key.capacity) else {
                interrupt(key)
                return true
            }
            let settledService = message.isComplete ? message.head.service.flatMap {
                echoMatches(service: $0, head: message.head) ? $0 : nil
            } : nil
            update(key) { responder in
                responder.message = message.isComplete ? nil : message
                if let settledService { responder.settle(settledService) }
            }
        }
        return true
    }

    private func matchesRequest(_ head: Head) -> Bool {
        guard let service = head.service, service == request?.service else { return false }
        return head.isNegative || echoMatches(service: service, head: head)
    }

    private func echoMatches(service: UInt8, head: Head) -> Bool {
        guard let request, request.service == service else { return true }
        let echoed: Int
        switch service {
        case 0x01, 0x05, 0x06, 0x08, 0x09, 0x19, 0x21: echoed = 1
        case 0x02, 0x22: echoed = 2
        default: echoed = 0
        }
        let compared = Swift.min(echoed, request.parameterCount)
        guard head.count >= 1 + compared else { return false }
        for offset in 0 ..< compared {
            var expected = request.parameter(offset)
            if service == 0x19 { expected &= 0x7F }
            if head[1 + offset] != expected { return false }
        }
        return true
    }

    private enum ResponderKey: Hashable {
        case can11(id: UInt16, extended: Bool)
        case can29(id: UInt32)
        case legacy(source: UInt8)
        case headerless

        var capacity: Int {
            if case .can11(_, extended: true) = self { return 6 }
            return 7
        }

        var otherAddressing: ResponderKey? {
            guard case let .can11(id, extended) = self else { return nil }
            return .can11(id: id, extended: !extended)
        }
    }

    private struct Responder {
        let key: ResponderKey
        var pending: [UInt8: TimeInterval] = [:]
        var message: Message?
        var interrupted: [UInt8: TimeInterval] = [:]

        var isIdle: Bool { pending.isEmpty && message == nil && interrupted.isEmpty }

        var continuationClaims: Int { interrupted.count + (message == nil ? 0 : 1) }

        mutating func interrupt(fallbackService: UInt8?) {
            guard let message else { return }
            if let service = message.head.service ?? fallbackService {
                interrupted[service] = max(interrupted[service] ?? 0, message.expiresAt)
            }
            self.message = nil
        }

        func owes(_ service: UInt8) -> Bool {
            pending[service] != nil || message?.head.service == service || interrupted[service] != nil
        }

        mutating func settle(_ service: UInt8) {
            pending.removeValue(forKey: service)
            interrupted.removeValue(forKey: service)
            if message?.head.service == service { message = nil }
        }
    }

    private struct Message {
        let declared: Int
        var received: Int
        let head: Head
        var expiresAt: TimeInterval = 0
        var nextSequence: UInt8 = 1

        var isComplete: Bool { received >= declared }
        var isCompleteVINLength: Bool { head.startsFullVIN && declared == Head.vinLength }

        func accepts(sequence: UInt8, count: Int, capacity: Int) -> Bool {
            sequence == nextSequence && count >= min(capacity, declared - received)
        }

        mutating func advance(sequence: UInt8, count: Int, capacity: Int) -> Bool {
            guard accepts(sequence: sequence, count: count, capacity: capacity) else { return false }
            nextSequence = (nextSequence + 1) & 0x0F
            received += count
            return true
        }
    }

    private mutating func update(_ key: ResponderKey, _ change: (inout Responder) -> Void) {
        if let index = responders.firstIndex(where: { $0.key == key }) {
            change(&responders[index])
            if responders[index].isIdle { responders.remove(at: index) }
        } else {
            var responder = Responder(key: key)
            change(&responder)
            if !responder.isIdle { responders.append(responder) }
        }
    }

    private func hasContinuationClaim(for key: ResponderKey) -> Bool {
        responders.contains { $0.key == key && $0.continuationClaims > 0 }
    }

    private mutating func interrupt(_ key: ResponderKey) {
        let service = request?.service
        update(key) { $0.interrupt(fallbackService: service) }
    }

    mutating func interruptAll(until: TimeInterval) {
        for index in responders.indices {
            responders[index].interrupt(fallbackService: request?.service)
            responders[index].pending = responders[index].pending.mapValues { max($0, until) }
            responders[index].interrupted = responders[index].interrupted.mapValues { max($0, until) }
        }
        if let unresolvedUntil { self.unresolvedUntil = max(unresolvedUntil, until) }
        responders.removeAll(where: \.isIdle)
    }

    // MARK: Wire layouts

    /// Automatic detection can see the first supported-PIDs reply before ATDPN answers.
    static func isLegacyProtocolAnswer(_ line: String) -> Bool {
        guard let hex = HexLine(line), hex.hasLegacyHeader, hex.isComplete, hex.nibbleCount == 20 else { return false }
        return hex.byte(atNibble: 6) == 0x41 && hex.byte(atNibble: 8) == 0x00
    }

    private struct Reply {
        enum Payload {
            case complete(Head)
            case first(Message)
            case consecutive(sequence: UInt8, count: Int)
            case damaged
        }

        let key: ResponderKey
        let payload: Payload

        init?(
            _ line: String,
            isBareService: (UInt8) -> Bool = { _ in false },
            allowBarePayload: Bool = false,
            allowLegacyFraming: Bool = false,
            knownCANResponder: (ResponderKey) -> Bool = { _ in false }
        ) {
            guard let hex = HexLine(line) else { return nil }
            let length = hex.nibbleCount
            let first = hex.byte(atNibble: 0)
            if length >= 8, hex.leadingWord >> 16 == 0x18DA || hex.leadingWord >> 16 == 0x18DB {
                self.init(can: hex, prefix: 8, key: .can29(id: hex.leadingWord))
                return
            }

            // Recognize standard legacy headers before considering a bare diagnostic payload.
            if allowLegacyFraming, hex.hasLegacyHeader {
                let key = ResponderKey.legacy(source: hex.byte(atNibble: 4))
                if hex.isComplete, length.isMultiple(of: 2), (10 ... 24).contains(length) {
                    self.init(message: Frame(hex: hex, firstNibble: 6, count: length / 2 - 4), key: key)
                } else {
                    self.init(key: key, payload: .damaged)
                }
                return
            }

            // A dropped digit in an 11-bit frame changes its parity. Recognize the
            // header independently for OBD responders, extended addressing and open transfers.
            let id = UInt16(first) << 4 | UInt16(hex.nibble(2))
            let extended = length >= 5 && hex.byte(atNibble: 3) == 0xF1
            let can11 = ResponderKey.can11(id: id, extended: extended)
            let negative = first == 0x7F && length == 6
            if length >= 3, id <= 0x7FF, !negative,
               (length >= 5 && length % 2 == 1) || (0x700 ... 0x7EF).contains(id)
                || (extended && id >= 0x600) || knownCANResponder(can11)
                || can11.otherAddressing.map(knownCANResponder) == true
                || hex.firstGroupLength == 3 {
                self.init(can: hex, prefix: extended ? 5 : 3, key: can11)
                return
            }

            guard hex.isComplete, length.isMultiple(of: 2) else { return nil }
            if negative || isBareService(first &- 0x40)
                || (allowBarePayload && !hex.hasLegacyHeader && (0x40 ..< 0x80).contains(first)) {
                self.init(message: Frame(hex: hex, firstNibble: 0, count: length / 2), key: .headerless)
                return
            }

            guard allowLegacyFraming, !allowBarePayload, length >= 10 else { return nil }
            // Legacy: three header bytes, the message, and one checksum byte.
            self.init(message: Frame(hex: hex, firstNibble: 6, count: length / 2 - 4),
                      key: .legacy(source: hex.byte(atNibble: 4)))
        }

        private init(key: ResponderKey, payload: Payload) {
            self.key = key
            self.payload = payload
        }

        private init(message: Frame, key: ResponderKey) {
            self.key = key
            payload = .complete(Head(message, from: 0, available: message.count))
        }

        private init(can hex: HexLine, prefix: Int, key: ResponderKey) {
            self.key = key
            let digits = hex.nibbleCount - prefix
            let capacity = key.capacity
            guard hex.isComplete, digits.isMultiple(of: 2), (2 ... (capacity + 1) * 2).contains(digits) else {
                payload = .damaged
                return
            }

            let frame = Frame(hex: hex, firstNibble: prefix, count: digits / 2)
            let pci = frame[0]
            switch pci >> 4 {
            case 0:
                let size = Int(pci & 0x0F)
                guard (1 ... capacity).contains(size), frame.count > size else {
                    payload = .damaged
                    return
                }
                payload = .complete(Head(frame, from: 1, available: size))
            case 1 where frame.count == capacity + 1:
                let declared = Int(pci & 0x0F) << 8 | Int(frame[1])
                guard declared > capacity else {
                    payload = .damaged
                    return
                }
                let received = frame.count - 2
                payload = .first(Message(declared: declared, received: received,
                                         head: Head(frame, from: 2, available: received)))
            case 2 where frame.count > 1:
                payload = .consecutive(sequence: pci & 0x0F, count: frame.count - 1)
            default:
                payload = .damaged
            }
        }
    }

    /// Given a raw VIN marker somewhere in the reply, distinguish a payload header
    /// from identical bytes in otherwise intact diagnostic data.
    static func carriesVIN(_ lines: [String], ignoringEchoOf command: String?) -> Bool {
        var messages: [ResponderKey: Message] = [:]
        for line in lines {
            let compact = OBDReplyPrivacy.compact(line)
            if compact == command || compact == "SEARCHING..." { continue }
            guard let reply = Reply(line, allowBarePayload: true, knownCANResponder: { messages[$0] != nil })
            else { return true }

            switch reply.payload {
            case .damaged:
                return true
            case let .complete(head):
                if head.isVIN { return true }
            case let .first(message):
                if message.head.isVIN || messages[reply.key] != nil { return true }
                messages[reply.key] = message
            case let .consecutive(sequence, count):
                // The first frame may have arrived in a previous prompt.
                guard var message = messages[reply.key] else { continue }
                guard message.advance(sequence: sequence, count: count, capacity: reply.key.capacity)
                else { return true }
                messages[reply.key] = message.isComplete ? nil : message
            }
        }
        return false
    }

    /// Tracks continuation ownership and VIN privacy across prompts. It retains only response
    /// identities, frame lengths, sequence, damage state and the originating exchange.
    struct VINReplies {
        private struct Transfer {
            var remaining: Int
            var nextSequence: UInt8 = 1
            let exchange: Int?
            let prompt: Int
            var ambiguous = false

            func accepts(sequence: UInt8, count: Int, capacity: Int) -> Bool {
                sequence == nextSequence && count >= min(capacity, remaining)
            }
        }

        private var transfers: [ResponderKey: Transfer] = [:]
        // A damaged prompt could have come from any responder. After the ECU window, an
        // unproven responder must supply its complete fresh transfer in a single prompt.
        private var damagedUntil: TimeInterval?
        private var settledResponders: Set<ResponderKey> = []
        private var redactContinuations = false

        var isEmpty: Bool { transfers.isEmpty && damagedUntil == nil }

        mutating func filterLateFrames(
            from lines: inout [String], at now: TimeInterval, prompt: Int, vinOwner: Int?,
            command: String?, legacyFraming: Bool?, current: inout OBDOwedAnswerTracker,
            debt: inout [OBDOwedAnswerTracker]
        ) -> (identifying: Bool, ambiguousCurrent: Bool) {
            // Stage every change. Even a valid final earlier in the prompt cannot settle
            // anything if a later line is damaged.
            var next = self
            var stagedCurrent = current
            var stagedDebt = debt
            var kept: [String] = []
            var identifying = false
            var damaged = false
            var mightOweCurrent = false
            var freshHeads: Set<ResponderKey> = []
            var incompleteRecovery: Set<ResponderKey> = []
            var verifiedVIN = false

            for line in lines {
                let compact = OBDReplyPrivacy.compact(line)
                if compact == command {
                    kept.append(line)
                    continue
                }
                let allowLegacyFraming = legacyFraming == true
                    || (legacyFraming == nil && command == "0100" && OBDOwedAnswerTracker.isLegacyProtocolAnswer(line))
                guard let reply = Reply(line, isBareService: { service in
                    stagedCurrent.request?.service == service
                        || stagedCurrent.bareServices?.contains(service) == true
                        || stagedDebt.contains { $0.bareServices?.contains(service) == true }
                }, allowBarePayload: stagedCurrent.request == nil, allowLegacyFraming: allowLegacyFraming,
                   knownCANResponder: { key in
                    next.transfers[key] != nil
                        || stagedCurrent.responders.contains { $0.key == key }
                        || stagedDebt.contains { tracker in tracker.responders.contains { $0.key == key } }
                }) else {
                    damaged = damaged || Self.isMalformedFrame(line, compact: compact)
                    kept.append(line)
                    continue
                }

                let key = reply.key
                let activeMessage = stagedCurrent.responders.first { $0.key == key }?.message
                switch reply.payload {
                case .damaged:
                    damaged = true
                    continue
                case let .first(message):
                    let matches = stagedCurrent.matchesRequest(message.head)
                    mightOweCurrent = mightOweCurrent || matches
                    if next.damagedUntil != nil, !matches {
                        // No slot owns this first frame. A later suffix still cannot settle it.
                        if message.head.isVIN { next.redactContinuations = true }
                        continue
                    }
                case let .complete(head):
                    mightOweCurrent = mightOweCurrent || (head.isPending && stagedCurrent.matchesRequest(head))
                case let .consecutive(sequence, count):
                    if let until = next.damagedUntil {
                        // An old final can never reassemble out of suffixes after damage.
                        guard let activeMessage else { continue }
                        let freshVIN = vinOwner != nil && activeMessage.isCompleteVINLength
                            && stagedCurrent.matchesRequest(activeMessage.head) && freshHeads.contains(key)
                        guard now >= until, stagedCurrent.matchesRequest(activeMessage.head),
                              !next.redactContinuations || freshVIN,
                              next.settledResponders.contains(key) || freshHeads.contains(key) else {
                            damaged = true
                            continue
                        }
                    }
                    guard !next.hasCompetingClaims(key, current: stagedCurrent, debt: stagedDebt),
                          next.acceptsContinuation(key, sequence: sequence, count: count,
                                                   current: stagedCurrent, debt: stagedDebt) else {
                        damaged = true
                        continue
                    }
                }

                let privacy = next.classify(reply, prompt: prompt, exchange: vinOwner,
                                            current: stagedCurrent, debt: stagedDebt)
                var claimed = false
                for index in stagedDebt.indices where stagedDebt[index].consume(reply, at: now, onlyOwed: true) {
                    claimed = true
                    break
                }
                if claimed { continue }
                if privacy == .abandoned { continue }
                if privacy == .identifying { identifying = true }

                if next.damagedUntil != nil {
                    switch reply.payload {
                    case let .first(message) where stagedCurrent.matchesRequest(message.head):
                        freshHeads.insert(key)
                        if !next.settledResponders.contains(key) || next.redactContinuations {
                            incompleteRecovery.insert(key)
                        }
                    case let .complete(head) where !head.isPending && stagedCurrent.matchesRequest(head):
                        if !head.isVIN || head.isCompleteVINLength {
                            next.settledResponders.insert(key)
                        }
                        verifiedVIN = verifiedVIN || (vinOwner != nil && head.isCompleteVINLength)
                    case let .consecutive(_, count):
                        if let activeMessage, count >= activeMessage.declared - activeMessage.received {
                            incompleteRecovery.remove(key)
                            next.settledResponders.insert(key)
                            verifiedVIN = verifiedVIN || (vinOwner != nil && freshHeads.contains(key)
                                && activeMessage.isCompleteVINLength && stagedCurrent.matchesRequest(activeMessage.head))
                        }
                    default:
                        break
                    }
                }
                stagedCurrent.consume(reply, at: now, onlyOwed: false)
                kept.append(line)
            }

            if damaged || !incompleteRecovery.isEmpty {
                let until = now + OBDOwedAnswerTracker.pendingWindow
                damagedUntil = until
                settledResponders.removeAll()
                redactContinuations = redactContinuations || !transfers.isEmpty || vinOwner != nil
                    || OBDReplyPrivacy.hasRawVINMarker(lines)
                transfers.removeAll()
                current.interruptAll(until: until)
                for index in debt.indices { debt[index].interruptAll(until: until) }
                // The damaged prompt gives no usable responder identity. A plausible open
                // answer still warrants waiting out the current service's ECU window.
                if mightOweCurrent { current.unresolvedUntil = until }
                lines.removeAll()
                return (redactContinuations, true)
            }

            if verifiedVIN { next.redactContinuations = false }
            self = next
            current = stagedCurrent
            debt = stagedDebt.filter(\.isOwed)
            lines = kept
            return (identifying, false)
        }

        private static func isMalformedFrame(_ line: String, compact: String) -> Bool {
            // Standalone adapter chatter and CAF numbered lines have their own parsers.
            // A frame joined to SEARCHING... has lost a line boundary.
            if compact.hasPrefix("SEARCHING...") { return compact != "SEARCHING..." }
            if OBDReplyPrivacy.hasRawVINMarker([line]) { return true }
            guard let hex = HexLine(line), hex.nibbleCount >= 3 else { return false }
            if let colon = compact.firstIndex(of: ":"), compact[..<colon].allSatisfy(\.isHexDigit),
               compact[compact.index(after: colon)...].allSatisfy(\.isHexDigit) { return false }
            return !(hex.isComplete && hex.nibbleCount == 3)
        }

        private func acceptsContinuation(
            _ key: ResponderKey, sequence: UInt8, count: Int,
            current: OBDOwedAnswerTracker, debt: [OBDOwedAnswerTracker]
        ) -> Bool {
            if let transfer = transfers[key], !transfer.accepts(sequence: sequence, count: count, capacity: key.capacity) {
                return false
            }
            func accepts(_ tracker: OBDOwedAnswerTracker) -> Bool {
                tracker.responders.first { $0.key == key }?.message?
                    .accepts(sequence: sequence, count: count, capacity: key.capacity) ?? true
            }
            return accepts(current) && debt.allSatisfy(accepts)
        }

        private func hasCompetingClaims(
            _ key: ResponderKey, current: OBDOwedAnswerTracker, debt: [OBDOwedAnswerTracker]
        ) -> Bool {
            let active = current.responders.first { $0.key == key }
            var claims = active?.continuationClaims ?? 0
            var trackedVIN = active?.message?.head.isVIN == true
            for tracker in debt {
                guard let responder = tracker.responders.first(where: { $0.key == key }) else { continue }
                claims += responder.continuationClaims
                trackedVIN = trackedVIN || responder.message?.head.isVIN == true
            }
            // The privacy record outlives ECU debt. Count it once if the VIN's first
            // frame is also represented by a live ECU transfer.
            if transfers[key] != nil, !trackedVIN { claims += 1 }
            return claims > 1 || transfers[key]?.ambiguous == true
        }

        private enum FrameOwnership {
            case ordinary
            case identifying
            case abandoned
        }

        private mutating func classify(
            _ reply: Reply, prompt: Int, exchange: Int?,
            current: OBDOwedAnswerTracker, debt: [OBDOwedAnswerTracker]
        ) -> FrameOwnership {
            switch reply.payload {
            case let .first(message):
                guard message.head.isVIN else {
                    // The competing first frame makes subsequent suffixes unprovable,
                    // even after either ECU debt has expired.
                    transfers[reply.key]?.ambiguous = true
                    return .ordinary
                }
                let competing = transfers[reply.key] != nil
                    || current.hasContinuationClaim(for: reply.key)
                    || debt.contains { $0.hasContinuationClaim(for: reply.key) }
                transfers[reply.key] = Transfer(
                    remaining: message.declared - message.received, exchange: exchange, prompt: prompt,
                    ambiguous: competing
                )
                return .identifying
            case let .consecutive(sequence, count):
                guard var transfer = transfers[reply.key] else { return .ordinary }
                // Ownership, sequence and length were checked before either tracker advanced.
                transfer.nextSequence = (sequence + 1) & 0x0F
                transfer.remaining -= count
                transfers[reply.key] = transfer.remaining <= 0 ? nil : transfer
                // An out-of-sequence frame can still contain identifying bytes.
                if transfer.prompt == prompt || (exchange != nil && transfer.exchange == exchange) {
                    return .identifying
                }
                return .abandoned
            default:
                return .ordinary
            }
        }
    }

    // MARK: The request

    private struct Request {
        let service: UInt8
        /// Up to the first two bytes after the service.
        private let first: UInt8
        private let second: UInt8
        /// How many of them the request has (0…2).
        let parameterCount: Int

        /// A hex request: all hex (whitespace aside), an even number of digits, at least one
        /// byte, and a service below `0x40`. Anything else (`ATRV`, `ATSH 7E0`) is nil.
        init?(_ command: String) {
            var digits = 0
            var high: UInt8 = 0
            var bytes: (UInt8, UInt8, UInt8) = (0, 0, 0)
            for unit in command.utf8 {
                if HexLine.isWhitespace(unit) { continue }
                guard let value = HexLine.value(of: unit) else { return nil }
                if digits % 2 == 0 {
                    high = value
                } else {
                    let byte = high << 4 | value
                    switch digits / 2 {
                    case 0: bytes.0 = byte
                    case 1: bytes.1 = byte
                    case 2: bytes.2 = byte
                    default: break
                    }
                }
                digits += 1
            }
            guard digits >= 2, digits % 2 == 0, bytes.0 < 0x40 else { return nil }
            service = bytes.0
            first = bytes.1
            second = bytes.2
            parameterCount = Swift.min(digits / 2 - 1, 2)
        }

        func parameter(_ offset: Int) -> UInt8 {
            offset == 0 ? first : second
        }
    }

    // MARK: Reading a line without allocating

    /// The hex digits of one line, the first 32 packed into two words. Only the first 24 can
    /// matter (a 29-bit id, two PCI bytes and three message bytes).
    private struct HexLine {
        private(set) var nibbleCount = 0
        private(set) var firstGroupLength: Int?
        private(set) var isComplete = true
        private var high: UInt64 = 0
        private var low: UInt64 = 0

        /// Keep the hex prefix to distinguish a malformed frame from adapter text.
        init?(_ line: String) {
            for unit in line.utf8 {
                if Self.isWhitespace(unit) {
                    if nibbleCount > 0, firstGroupLength == nil { firstGroupLength = nibbleCount }
                    continue
                }
                guard let value = Self.value(of: unit) else {
                    isComplete = false
                    break
                }
                if nibbleCount < 16 {
                    high |= UInt64(value) << UInt64(60 - 4 * nibbleCount)
                } else if nibbleCount < 32 {
                    low |= UInt64(value) << UInt64(60 - 4 * (nibbleCount - 16))
                }
                nibbleCount += 1
            }
            guard nibbleCount > 0 else { return nil }
        }

        /// The digit at `index`; 0 past the first 32.
        func nibble(_ index: Int) -> UInt8 {
            if index < 16 { return UInt8(truncatingIfNeeded: high >> UInt64(60 - 4 * index)) & 0x0F }
            if index < 32 { return UInt8(truncatingIfNeeded: low >> UInt64(60 - 4 * (index - 16))) & 0x0F }
            return 0
        }

        func byte(atNibble index: Int) -> UInt8 {
            nibble(index) << 4 | nibble(index + 1)
        }

        /// The first 8 digits as a number (a 29-bit CAN id).
        var leadingWord: UInt32 {
            UInt32(truncatingIfNeeded: high >> 32)
        }

        var hasLegacyHeader: Bool {
            guard nibbleCount >= 6 else { return false }
            let first = byte(atNibble: 0)
            let second = byte(atNibble: 2)
            return ((first == 0x41 || first == 0x48) && second == 0x6B)
                || (first == 0x68 && second == 0x6A) || (first >= 0x80 && second == 0xF1)
        }

        static func isWhitespace(_ unit: UInt8) -> Bool {
            unit == 0x20 || (0x09 ... 0x0D).contains(unit)
        }

        static func value(of unit: UInt8) -> UInt8? {
            switch unit {
            case 0x30 ... 0x39: return unit - 0x30 // 0-9
            case 0x41 ... 0x46: return unit - 0x37 // A-F
            case 0x61 ... 0x66: return unit - 0x57 // a-f
            default: return nil
            }
        }
    }

    /// `count` bytes of a line starting at a digit.
    private struct Frame {
        let hex: HexLine
        let firstNibble: Int
        let count: Int

        subscript(index: Int) -> UInt8 {
            hex.byte(atNibble: firstNibble + 2 * index)
        }
    }

    /// Message length and up to the first three bytes.
    private struct Head {
        static let vinLength = 20 // Three service/count or service/DID bytes, then a 17-byte VIN.
        let count: Int
        private let bytes: (UInt8, UInt8, UInt8)

        /// Record the size and read the first `min(3, available)` bytes starting at `offset`.
        init(_ frame: Frame, from offset: Int, available: Int) {
            count = available
            bytes = (
                count > 0 ? frame[offset] : 0,
                count > 1 ? frame[offset + 1] : 0,
                count > 2 ? frame[offset + 2] : 0
            )
        }

        var service: UInt8? {
            if isNegative { return self[1] }
            guard count > 0, (0x40 ..< 0x80).contains(self[0]) else { return nil }
            return self[0] - 0x40
        }

        var isNegative: Bool { count >= 3 && self[0] == 0x7F }
        var isPending: Bool { isNegative && self[2] == 0x78 }
        var isCompleteVINLength: Bool { startsFullVIN && count == Self.vinLength }
        var startsFullVIN: Bool { isVIN && (self[0] != 0x49 || (count >= 3 && self[2] == 1)) }
        var isVIN: Bool {
            (count >= 2 && self[0] == 0x49 && self[1] == 0x02) ||
                (count >= 3 && self[0] == 0x62 && self[1] == 0xF1 && self[2] == 0x90)
        }

        subscript(index: Int) -> UInt8 {
            switch index {
            case 0: return bytes.0
            case 1: return bytes.1
            default: return bytes.2
            }
        }
    }
}
