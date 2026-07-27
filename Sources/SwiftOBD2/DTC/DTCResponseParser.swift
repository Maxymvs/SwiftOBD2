//
//  DTCResponseParser.swift
//  SwiftOBD2
//
//  Outcome extraction for DTC service responses, performed **where the mode byte is still
//  visible**.
//
//  The generic pipeline (`CANParser`/`LegacyParcer` → `Message` → `CommandProperties.decode`)
//  strips the PCI, the mode byte and the count byte blindly, so a negative response `7F 03 11`
//  decodes as an empty *success* and a positive `43` is never actually verified. This parser
//  replaces that path for DTC requests only: it keeps every responder's raw address, verifies
//  the mode byte, checks the CAN count byte against the pairs it decoded, routes `7F` to a
//  negative response, and tolerates damage per responder instead of aborting the batch.
//
//  Pure and synchronous by design — raw ELM lines in, `DTCServiceResult` out — so every rule
//  is testable from a fixture without a transport.
//

import Foundation

// MARK: - Protocol family

/// The raw framing/addressing family a DTC response arrived in.
///
/// DTC responses are canonicalised per family: 11-bit CAN carries an ISO-TP PCI and (for a
/// positive response) a count byte, while the legacy K-line/J1850 families carry a 3-byte
/// header plus a trailing checksum and no count byte at all.
enum DTCProtocolFamily: Sendable, Hashable {
    /// ISO 15765-4 with 11-bit ids (ELM protocols 6 and 8).
    case can11
    /// ISO 15765-4 with 29-bit ids (ELM protocols 7 and 9). Headers ON means a 4-byte header
    /// such as `18 DA F1 10`; the responder identity is the whole 29-bit id.
    case can29
    /// K-line / J1850: ISO 9141-2, ISO 14230-4 KWP, SAE J1850 (ELM protocols 1–5).
    case legacy
    /// Recognised but not parseable: J1939 (A — DM1/DM2, not services 03/07/0A), the unmapped
    /// user protocols (B/C), and "no protocol established yet".
    ///
    /// A response that reaches the parser with unusable addressing resolves to
    /// ``DTCServiceResult/invalidResponse`` — present but unrecoverable, never clean.
    case unsupportedAddressing

    /// Maps an ``CANProtocol/elmID`` (`"6"`, `"5"`, …) onto a family; `nil` — no protocol
    /// established — is ``unsupportedAddressing``.
    init(elmID: String?) {
        switch elmID {
        case "1", "2", "3", "4", "5":
            self = .legacy
        case "6", "8":
            self = .can11
        case "7", "9":
            self = .can29
        default:
            self = .unsupportedAddressing
        }
    }

    /// Whether responses carry an ISO-TP PCI and (for a positive response) a count byte.
    /// K-line/J1850 has neither.
    var isCAN: Bool {
        switch self {
        case .can11, .can29: return true
        case .legacy, .unsupportedAddressing: return false
        }
    }
}

extension DTCService {
    /// The service byte a `7F <service> <nrc>` negative response must echo (`0x03`/`0x07`/`0x0A`).
    ///
    /// Positive response bytes are the request byte plus `0x40`.
    var requestServiceByte: UInt8 {
        positiveResponseByte - 0x40
    }
}

// MARK: - Parser

/// Turns the raw lines of one DTC request (post-`>` buffering, headers ON) into a
/// ``DTCServiceResult``.
enum DTCResponseParser {
    /// Parses one buffered read of a single DTC service request.
    ///
    /// - Parameters:
    ///   - lines: The adapter's response lines exactly as the transport delivered them.
    ///     Spaces, the `>` prompt, and non-hex chatter (`SEARCHING...`, `BUS INIT`, `OK`) are
    ///     tolerated; a `NO DATA` line is recognised here so the result is transport-neutral.
    ///   - service: The in-flight service — its positive byte is verified and its request byte
    ///     must be echoed by any `7F` for that `7F` to count as a negative response.
    ///   - family: The addressing family the response was framed in.
    /// - Returns: `.answered` when at least one responder was recoverable (per-ECU detail
    ///   inside, damage isolated to its own responder), `.noResponse` for `NO DATA`/empty
    ///   output, and `.invalidResponse` when bytes arrived but no responder was recoverable.
    static func parse(
        lines: [String],
        service: DTCService,
        family: DTCProtocolFamily
    ) -> DTCServiceResult {
        let sanitized = sanitize(lines)

        // `NO DATA`/empty output is silence; anything hex is a response, even if unusable.
        guard !sanitized.hexLines.isEmpty else {
            obdDebug(
                "Mode \(service.requestMode): no usable response lines (NO DATA: \(sanitized.sawNoData))",
                category: .parsing
            )
            return .noResponse
        }
        guard family != .unsupportedAddressing else { return .invalidResponse }

        let grouping = group(sanitized.hexLines, family: family)

        var outcomes: [ECUAddress: DTCResponderOutcome] = [:]
        for address in grouping.order {
            if grouping.damaged.contains(address) {
                outcomes[address] = .malformed
                continue
            }
            guard let frames = grouping.frames[address] else { continue }
            let messages = messages(for: frames, family: family, positiveByte: service.positiveResponseByte)
            guard let outcome = outcome(for: messages, address: address, service: service, family: family) else {
                continue // noise only (e.g. a `7F` echoing another service): not recoverable
            }
            outcomes[address] = outcome
        }

        guard let responders = DTCResponders(outcomes) else {
            // Bytes arrived — unrecoverable addressing, or nothing but discarded noise.
            return .invalidResponse
        }
        return .answered(responders)
    }

    /// Parses one buffered read of a `0101` status request into per-responder outcomes.
    ///
    /// Framing, grouping and damage attribution are exactly the DTC rules — only the payload
    /// contract differs (`41 01 <4 status bytes>`, decoded per responder by ``StatusDecoder``).
    /// The generic ``ELM327/getStatus()`` is untouched: it still returns the first responder's
    /// aggregate status for its existing callers.
    ///
    /// - Returns: `.answered` when at least one responder was recoverable, `.noResponse` for
    ///   `NO DATA`/empty output, `.invalidResponse` when bytes arrived unrecoverable.
    static func parseStatus(lines: [String], family: DTCProtocolFamily) -> DTCStatusReadResult {
        let sanitized = sanitize(lines)
        guard !sanitized.hexLines.isEmpty else {
            obdDebug("0101: no usable response lines (NO DATA: \(sanitized.sawNoData))", category: .parsing)
            return .noResponse
        }
        guard family != .unsupportedAddressing else { return .invalidResponse }

        let grouping = group(sanitized.hexLines, family: family)

        var outcomes: [ECUAddress: DTCStatusResponderOutcome] = [:]
        for address in grouping.order {
            if grouping.damaged.contains(address) {
                outcomes[address] = .malformed
                continue
            }
            guard let frames = grouping.frames[address] else { continue }
            let messages = messages(for: frames, family: family, positiveByte: Self.statusPositiveByte)
            guard let outcome = statusOutcome(for: messages) else {
                continue // noise only (a `7F` echoing another service)
            }
            outcomes[address] = outcome
        }

        guard let responders = DTCStatusResponders(outcomes) else { return .invalidResponse }
        return .answered(responders)
    }

    /// Whether the lines so far leave any responder still owing its real answer after a
    /// `7F <service> 78`.
    ///
    /// Pure, and evaluated over *all* accumulated lines, so the supersede rule decides: a `78`
    /// already followed by that responder's final message has resolved and needs no further
    /// listening. This is the predicate the transport's listen loop is driven by.
    static func awaitsPendingResponse(
        lines: [String],
        service: DTCService,
        family: DTCProtocolFamily
    ) -> Bool {
        guard let responders = parse(lines: lines, service: service, family: family).responders else {
            return false
        }
        return responders.outcomes.values.contains { outcome in
            if case let .negativeResponse(nrc) = outcome { return nrc == .responsePending }
            return false
        }
    }

    /// What a Mode 04 (clear) request resolved to.
    enum ClearOutcome: Sendable, Equatable {
        /// At least one responder returned a verified `44`, and none refused.
        case verified
        /// A responder explicitly refused with `7F 04 <nrc>`.
        case refused(NegativeResponseCode)
        /// Bytes arrived (or did not) without a single verified `44` — never call this a success.
        case unverified
    }

    /// Verifies the `44` positive response to Mode 04.
    ///
    /// The old implementation discarded the response entirely (`_ = try await sendCommand`), so a
    /// refusal or silence looked exactly like a successful clear.
    static func clearOutcome(lines: [String], family: DTCProtocolFamily) -> ClearOutcome {
        let sanitized = sanitize(lines)
        guard !sanitized.hexLines.isEmpty, family != .unsupportedAddressing else { return .unverified }

        let grouping = group(sanitized.hexLines, family: family)
        var sawPositive = false
        for address in grouping.order where !grouping.damaged.contains(address) {
            guard let frames = grouping.frames[address] else { continue }
            for message in messages(for: frames, family: family, positiveByte: Self.clearPositiveByte) {
                guard case let .payload(bytes) = message, let mode = bytes.first else { continue }
                if mode == 0x7F, bytes.count >= 3, bytes[1] == Self.clearRequestByte {
                    return .refused(NegativeResponseCode(rawValue: bytes[2]))
                }
                if mode == Self.clearPositiveByte { sawPositive = true }
            }
        }
        return sawPositive ? .verified : .unverified
    }

    /// `41` — the positive response byte for Mode 01 (the `0101` status read).
    private static let statusPositiveByte: UInt8 = 0x41
    /// `01` — the service byte a `7F` must echo to count as a refusal of the status read.
    private static let statusRequestByte: UInt8 = 0x01
    /// `01` — the PID the status read asks for; a positive response must echo it.
    private static let statusPID: UInt8 = 0x01
    /// `44` / `04` — Mode 04 (clear) positive response and request bytes.
    private static let clearPositiveByte: UInt8 = 0x44
    private static let clearRequestByte: UInt8 = 0x04

    // MARK: - Line sanitising

    /// Compacted, uppercased hex lines plus whether the adapter reported `NO DATA`.
    ///
    /// `NO DATA` detection lives here rather than in the comm layers: BLE surfaces it as
    /// `BLEManagerError.noData` while WiFi collapses it into a generic error, and other
    /// callers must keep their existing transport behaviour.
    static func sanitize(_ lines: [String]) -> (hexLines: [String], sawNoData: Bool) {
        var hexLines: [String] = []
        var sawNoData = false
        for line in lines {
            let text = line
                .replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if text.isEmpty { continue }
            if text.contains("NO DATA") {
                sawNoData = true
                continue
            }
            let compact = text.replacingOccurrences(of: " ", with: "")
            // Non-hex chatter (`SEARCHING...`, `BUS INIT`, `OK`, `STOPPED`, `ERROR`) is noise,
            // not a response — the generic parsers filter it the same way.
            if compact.isHex {
                hexLines.append(compact)
            }
        }
        return (hexLines, sawNoData)
    }

    // MARK: - Framing

    /// What one raw line yielded.
    ///
    /// The three-way split matters: as soon as a **complete header** parses, the damage stays
    /// attributed to that responder (`.malformed`) — a header-only line still names its ECU.
    /// Only a fragment too short or garbled to yield a full header counts merely towards the
    /// request-level `.invalidResponse`.
    private enum FrameExtraction {
        case frame(address: ECUAddress, payload: [UInt8])
        case damaged(address: ECUAddress)
        case unrecoverable
    }

    /// One buffered read grouped by responder: frame payloads in arrival order, plus the
    /// responders whose lines could not be framed at all.
    private struct Grouping {
        /// Responders in first-seen order, so message order within a responder is preserved.
        var order: [ECUAddress] = []
        var frames: [ECUAddress: [[UInt8]]] = [:]
        var damaged: Set<ECUAddress> = []
    }

    /// Groups frames by *raw* responder address — never by the lossy engine/transmission
    /// classification, which is what collapses two non-engine modules onto one key.
    private static func group(_ hexLines: [String], family: DTCProtocolFamily) -> Grouping {
        var grouping = Grouping()
        for line in hexLines {
            switch frame(from: line, family: family) {
            case let .frame(address, payload):
                if grouping.frames[address] == nil {
                    grouping.frames[address] = []
                    grouping.order.append(address)
                }
                grouping.frames[address]?.append(payload)

            case let .damaged(address):
                // The address survived, the frame did not. No junk-frame dropping: this responder
                // is damaged even when it also sent something that parses cleanly.
                if grouping.frames[address] == nil {
                    grouping.frames[address] = []
                    grouping.order.append(address)
                }
                grouping.damaged.insert(address)

            case .unrecoverable:
                continue // not even an address survived — only the request level sees this
            }
        }
        return grouping
    }

    /// Splits one line into its responder address and the bytes after the header (for CAN:
    /// starting at the ISO-TP PCI; for legacy: starting at the mode byte, checksum removed).
    private static func frame(from line: String, family: DTCProtocolFamily) -> FrameExtraction {
        switch family {
        case .can11, .can29:
            // `7E8` (11-bit) or `18DAF110` (29-bit) + whole payload bytes. A complete id *is* the
            // responder identity, even when nothing usable follows it: a header-only or truncated
            // line is that ECU's damage, never a line to drop. The full 29-bit id is preserved —
            // collapsing it to the low byte would merge distinct modules.
            let headerNibbles = family == .can29 ? 8 : 3
            guard line.count >= headerNibbles, let id = UInt32(line.prefix(headerNibbles), radix: 16) else {
                return .unrecoverable
            }
            let address = ECUAddress(raw: id)
            guard let payload = hexBytes(String(line.dropFirst(headerNibbles))), !payload.isEmpty else {
                return .damaged(address: address) // no payload at all, or a trailing half-byte
            }
            return .frame(address: address, payload: payload)

        case .legacy:
            // `<format> <target> <source>` + payload + checksum; the source byte is the ECU.
            // As on CAN, a complete header is enough to attribute the damage to its responder.
            let headerNibbles = 6
            guard line.count >= headerNibbles,
                  let header = hexBytes(String(line.prefix(headerNibbles)))
            else { return .unrecoverable }
            let address = ECUAddress(raw: UInt32(header[2]))
            guard let bytes = hexBytes(line), bytes.count >= 5 else {
                return .damaged(address: address)
            }
            let payload = Array(bytes.dropFirst(3).dropLast())
            guard !payload.isEmpty else { return .damaged(address: address) }
            return .frame(address: address, payload: payload)

        case .unsupportedAddressing:
            return .unrecoverable
        }
    }

    /// Whole bytes, or `nil` for an odd number of nibbles — unlike `String.hexBytes`, which
    /// drops a trailing half-byte silently.
    private static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        let bytes = hex.hexBytes
        guard bytes.count == hex.count / 2 else { return nil }
        return bytes
    }

    // MARK: - Message assembly

    /// One responder message: either its application bytes (mode byte first, truncated to the
    /// declared length) or unusable.
    private enum RawMessage {
        case payload([UInt8])
        case damaged
    }

    /// Splits one responder's frames into messages using its family's rules.
    private static func messages(
        for frames: [[UInt8]],
        family: DTCProtocolFamily,
        positiveByte: UInt8
    ) -> [RawMessage] {
        family == .legacy
            ? legacyMessages(frames, positiveByte: positiveByte)
            : canMessages(frames)
    }

    /// Splits one responder's frames into ISO-TP messages, so a `7F … 78` interim response and
    /// the final message that supersedes it stay distinguishable inside one buffered read.
    ///
    /// Bytes beyond the declared length are transport padding and are dropped here; a message
    /// whose frames don't add up to its declared length is damaged as a whole (no partial
    /// salvage — that is D1's rule).
    private static func canMessages(_ frames: [[UInt8]]) -> [RawMessage] {
        var messages: [RawMessage] = []
        var index = 0
        while index < frames.count {
            let frame = frames[index]
            guard let pci = frame.first else {
                messages.append(.damaged)
                index += 1
                continue
            }
            switch pci & 0xF0 {
            case 0x00: // single frame
                let declared = Int(pci & 0x0F)
                let body = Array(frame.dropFirst())
                messages.append(declared > 0 && body.count >= declared
                    ? .payload(Array(body.prefix(declared)))
                    : .damaged)
                index += 1

            case 0x10: // first frame of a multi-frame message
                guard frame.count >= 2 else {
                    messages.append(.damaged)
                    index += 1
                    continue
                }
                let declared = (Int(pci & 0x0F) << 8) | Int(frame[1])
                var assembled = Array(frame.dropFirst(2))
                // Consecutive frames are numbered 1…F and wrap to 0. A missing, duplicated or
                // reordered frame means the assembly is not what the ECU sent, so the message is
                // damaged — it must never be decoded into codes.
                var expectedSequence: UInt8 = 1
                var sequenceIsIntact = true
                index += 1
                while assembled.count < declared, index < frames.count,
                      let nextPCI = frames[index].first, nextPCI & 0xF0 == 0x20 {
                    if nextPCI & 0x0F != expectedSequence { sequenceIsIntact = false }
                    assembled.append(contentsOf: frames[index].dropFirst())
                    expectedSequence = (expectedSequence &+ 1) & 0x0F
                    index += 1
                }
                messages.append(sequenceIsIntact && declared > 0 && assembled.count >= declared
                    ? .payload(Array(assembled.prefix(declared)))
                    : .damaged)

            default: // an orphan consecutive frame, flow control, or an unknown frame type
                messages.append(.damaged)
                index += 1
            }
        }
        return messages
    }

    /// Splits one responder's legacy frames into messages.
    ///
    /// K-line/J1850 carries no PCI and no count byte: each line is a complete message, except a
    /// positive response spread over several lines, which repeats the mode byte on each line
    /// and is merged back into one message here. This is the canonicalisation that replaces the
    /// synthetic `43 00` prepend — the generic path's extra byte shifted the whole pair stream
    /// and fabricated codes. It applies to `43`, `47` and `4A` alike (the generic path
    /// special-cased only `0x43`), and to the `41` of the status read.
    /// The merged positive stays at the position of the **first** positive line, so message order
    /// relative to any negative message is preserved — reordering it to the end would let a
    /// terminal refusal be silently superseded by a later positive line.
    private static func legacyMessages(_ frames: [[UInt8]], positiveByte: UInt8) -> [RawMessage] {
        var messages: [RawMessage] = []
        var positive: [UInt8] = []
        var positiveIndex: Int?
        for frame in frames {
            if frame.first == positiveByte {
                if let positiveIndex {
                    positive.append(contentsOf: frame.dropFirst())
                    messages[positiveIndex] = .payload(positive)
                } else {
                    positive = frame
                    positiveIndex = messages.count
                    messages.append(.payload(positive))
                }
            } else {
                messages.append(.payload(frame))
            }
        }
        return messages
    }

    // MARK: - Classification

    private enum ClassifiedMessage {
        case positive([DTCObservation])
        case negative(NegativeResponseCode)
        case malformed
        /// A `7F` echoing a different service — adapter buffering or an ECU straggler. Never a
        /// negative response for *this* request, and never evidence.
        case noise
    }

    /// The responder's outcome, or `nil` when nothing it sent was recoverable.
    ///
    /// A responder normally sends exactly one final message. The single sanctioned exception is an
    /// **interim** negative response (`0x21` busy, `0x78` response pending) followed by the real
    /// answer in the same buffered read — only those may be superseded. Every other multi-message
    /// combination (a terminal refusal and a positive, two positives, …) is conflicting evidence
    /// and resolves to `.malformed`: a terminal `7F 03 11` must never be overwritten by a `43 00`.
    private static func outcome(
        for messages: [RawMessage],
        address: ECUAddress,
        service: DTCService,
        family: DTCProtocolFamily
    ) -> DTCResponderOutcome? {
        let classified = messages
            .map { classify($0, address: address, service: service, family: family) }
            .filter { if case .noise = $0 { return false } else { return true } }

        guard let final = classified.last else { return nil }
        let superseded = classified.dropLast()
        let supersedable = superseded.allSatisfy { message in
            if case let .negative(nrc) = message { return !nrc.isTerminal }
            return false
        }
        guard supersedable else { return .malformed }

        switch final {
        case let .positive(codes):
            return .responded(codes: codes)
        case let .negative(nrc):
            return .negativeResponse(nrc)
        case .malformed, .noise:
            return .malformed
        }
    }

    private static func classify(
        _ message: RawMessage,
        address: ECUAddress,
        service: DTCService,
        family: DTCProtocolFamily
    ) -> ClassifiedMessage {
        guard case let .payload(bytes) = message, let mode = bytes.first else { return .malformed }

        if mode == 0x7F {
            guard bytes.count >= 3 else { return .malformed }
            guard bytes[1] == service.requestServiceByte else { return .noise }
            return .negative(NegativeResponseCode(rawValue: bytes[2]))
        }

        // Only a *verified* positive mode byte can ever read as clean.
        guard mode == service.positiveResponseByte else { return .malformed }

        switch family {
        case .can11, .can29:
            guard bytes.count >= 2 else { return .malformed }
            let declaredCount = Int(bytes[1])
            let pairs = Array(bytes.dropFirst(2))
            guard pairs.count % 2 == 0 else { return .malformed }
            let codes = observations(from: pairs, service: service, address: address)
            // Count-byte consistency: `43 01 00 00` claims one code and decodes none, so it is
            // damaged — never a clean answer. `.responded([])` therefore needs a count of 0.
            guard codes.count == declaredCount else { return .malformed }
            return .positive(codes)

        case .legacy:
            let pairs = Array(bytes.dropFirst())
            guard pairs.count % 2 == 0 else { return .malformed }
            return .positive(observations(from: pairs, service: service, address: address))

        case .unsupportedAddressing:
            return .malformed
        }
    }

    // MARK: - Status classification

    private enum ClassifiedStatusMessage {
        case positive(Status)
        case negative(NegativeResponseCode)
        case malformed
        /// A `7F` echoing a service other than Mode 01 — noise, never evidence.
        case noise
    }

    /// One responder's status outcome, or `nil` when nothing it sent was recoverable.
    ///
    /// Same supersede discipline as the DTC path: an interim `0x21`/`0x78` may be followed by the
    /// real answer in the same buffered read; any other multi-message combination is conflicting.
    private static func statusOutcome(for messages: [RawMessage]) -> DTCStatusResponderOutcome? {
        let classified = messages
            .map(classifyStatus)
            .filter { if case .noise = $0 { return false } else { return true } }

        guard let final = classified.last else { return nil }
        let supersedable = classified.dropLast().allSatisfy { message in
            if case let .negative(nrc) = message { return !nrc.isTerminal }
            return false
        }
        guard supersedable else { return .malformed }

        switch final {
        case let .positive(status):
            return .responded(status)
        case let .negative(nrc):
            return .negativeResponse(nrc)
        case .malformed, .noise:
            return .malformed
        }
    }

    private static func classifyStatus(_ message: RawMessage) -> ClassifiedStatusMessage {
        guard case let .payload(bytes) = message, let mode = bytes.first else { return .malformed }

        if mode == 0x7F {
            guard bytes.count >= 3 else { return .malformed }
            guard bytes[1] == Self.statusRequestByte else { return .noise }
            return .negative(NegativeResponseCode(rawValue: bytes[2]))
        }

        // Only a verified `41` echoing PID `01` with four status bytes behind it decodes.
        guard mode == Self.statusPositiveByte, bytes.count >= 6, bytes[1] == Self.statusPID else {
            return .malformed
        }
        let statusBytes = Data(bytes[2 ..< 6])
        guard case let .success(decoded) = StatusDecoder().decode(data: statusBytes, unit: .metric),
              case let .statusResult(status) = decoded
        else {
            return .malformed
        }
        return .positive(status)
    }

    /// Decodes 2-byte DTC pairs, reusing the library's `parseDTC` (which also filters `00 00`
    /// padding), and attributes every code to the responder that reported it.
    private static func observations(
        from pairs: [UInt8],
        service: DTCService,
        address: ECUAddress
    ) -> [DTCObservation] {
        var observations: [DTCObservation] = []
        var index = 0
        while index + 1 < pairs.count {
            let pair = Data([pairs[index], pairs[index + 1]])
            index += 2
            guard let code = parseDTC(pair) else { continue }
            observations.append(
                DTCObservation(
                    code: code.code,
                    kind: service.kind,
                    ecuAddress: address,
                    description: code.description
                )
            )
        }
        return observations
    }
}
