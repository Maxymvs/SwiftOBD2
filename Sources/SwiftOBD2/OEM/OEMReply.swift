//
//  OEMReply.swift
//  SwiftOBD2
//
//  Judges the raw lines of one Mode 22 read against the request that produced them.
//
//  The adapter runs with headers on and spaces off, so each frame line is the responder's 3-hex
//  CAN id, then (BMW only) one extended-address byte that must be F1, then the ISO-TP PCI and
//  data: `7E80562028D0CE2`, `618F10562DA2E0303`. Reassembly is strict, ported from the app's
//  `OBDCANReply`: a frame that is out of sequence, too long, or not hex spoils the reply, because
//  clone adapters drop characters and a loose reading of a damaged reply is a wrong number.
//

import Foundation

enum OEMReply {
    /// The outcome of one read: exactly one `OEMReadOutcome`, never a value from the wrong place.
    static func outcome(lines: [String], target: OEMTarget, command: OEMCatalogCommand) -> OEMReadOutcome {
        let message: [UInt8]
        switch reassemble(lines: lines, target: target) {
        case .nothing:
            return .noAnswer
        case .otherRespondersOnly:
            return .wrongResponder
        case .corrupted:
            return .malformed(.corruptedFrame)
        case .incomplete:
            return .malformed(.incomplete)
        case let .messages(messages):
            // "Response pending" is the module asking for patience; the answer follows it.
            guard let first = messages.first(where: { !isResponsePending($0) }) else {
                return .responsePendingOnly
            }
            message = first
        }

        if message.first == 0x7F {
            guard message.count == 3, message[1] == 0x22 else { return .malformed(.unexpectedService) }
            return .negativeResponse(code: message[2])
        }
        guard message.first == 0x62 else { return .malformed(.unexpectedService) }
        guard message.count >= 3,
              message[1] == UInt8(command.dataIdentifier >> 8),
              message[2] == UInt8(command.dataIdentifier & 0xFF)
        else {
            return .malformed(.identifierMismatch)
        }

        let payload = Array(message.dropFirst(3))
        if !command.replyLengths.isEmpty, !command.replyLengths.contains(payload.count) {
            return .malformed(.unexpectedLength)
        }

        var values: [OEMSignalValue] = []
        for signal in command.signals {
            do {
                values.append(OEMSignalValue(signalID: signal.id, value: try signal.format.decode(payload)))
            } catch {
                return .malformed(.payloadTooShort)
            }
        }
        return .values(values)
    }

    static func isResponsePending(_ message: [UInt8]) -> Bool {
        message == [0x7F, 0x22, 0x78]
    }

    // MARK: Reassembly

    enum Reassembly: Equatable {
        /// No frame at all: `NO DATA`, status text, an empty reply.
        case nothing
        /// Frames arrived, none of them from the expected responder.
        case otherRespondersOnly
        case corrupted
        case incomplete
        /// The expected responder's complete messages, in arrival order.
        case messages([[UInt8]])
    }

    /// The expected responder's messages. Frames from any other id are ignored.
    static func reassemble(lines: [String], target: OEMTarget) -> Reassembly {
        let responder = String(format: "%03X", target.responseID)
        var state = Reassembler(extendedAddress: target.replyExtendedAddress)
        var heardResponder = false
        var heardOthers = false
        var adapterOverflow = false

        for raw in lines {
            let line = raw.replacingOccurrences(of: " ", with: "").uppercased()
            guard !line.isEmpty else { continue }
            // The adapter ran out of buffer mid-reply: whatever it printed is partial.
            if line.contains("BUFFERFULL") { adapterOverflow = true; continue }
            if line.hasPrefix(responder) {
                heardResponder = true
                state.consume(String(line.dropFirst(responder.count)))
            } else if line.count > responder.count, line.allSatisfy(\.isHexDigit) {
                heardOthers = true
            }
            // Anything else is adapter status text (`NO DATA`, `SEARCHING...`, `STOPPED`, `?`).
        }

        if adapterOverflow { return .corrupted }
        guard heardResponder else { return heardOthers ? .otherRespondersOnly : .nothing }
        return state.result
    }

    /// Strict ISO-TP reassembly for one responder.
    struct Reassembler {
        let extendedAddress: UInt8?
        private(set) var messages: [[UInt8]] = []
        private var payload: [UInt8] = []
        private var declared: Int?
        private var nextSequence: UInt8 = 1
        private var corrupted = false

        init(extendedAddress: UInt8?) {
            self.extendedAddress = extendedAddress
        }

        /// Bytes a CAN frame spends on the extended address (BMW) before the PCI.
        private var addressLength: Int { extendedAddress == nil ? 0 : 1 }
        /// Largest single-frame payload; also the smallest a first frame may declare past.
        private var singleFrameCapacity: Int { 7 - addressLength }
        private var consecutiveFrameCapacity: Int { 7 - addressLength }

        var result: Reassembly {
            if corrupted { return .corrupted }
            if declared != nil { return .incomplete }
            return .messages(messages)
        }

        mutating func consume(_ hex: String) {
            guard !corrupted else { return }
            guard var frame = OEMReply.bytes(hex), frame.count <= 8 else {
                corrupted = true
                return
            }
            if let extendedAddress {
                guard frame.first == extendedAddress else {
                    corrupted = true
                    return
                }
                frame.removeFirst()
            }
            guard let pci = frame.first else {
                corrupted = true
                return
            }

            switch pci >> 4 {
            case 0x0:
                // Single frame. Padding after the declared length is allowed.
                let length = Int(pci & 0x0F)
                guard declared == nil, length >= 1, length <= singleFrameCapacity, frame.count > length else {
                    corrupted = true
                    return
                }
                messages.append(Array(frame[1...length]))
            case 0x1:
                // First frame: always a full frame, declaring more than a single frame can carry.
                guard declared == nil, frame.count == 8 - addressLength else {
                    corrupted = true
                    return
                }
                let total = Int(pci & 0x0F) << 8 | Int(frame[1])
                guard total > singleFrameCapacity else {
                    corrupted = true
                    return
                }
                declared = total
                payload = Array(frame.dropFirst(2))
                nextSequence = 1
            case 0x2:
                guard let total = declared, pci & 0x0F == nextSequence else {
                    corrupted = true
                    return
                }
                let data = Array(frame.dropFirst())
                let remaining = total - payload.count
                // Every consecutive frame but the last is full.
                guard data.count == consecutiveFrameCapacity || (data.count >= remaining && !data.isEmpty) else {
                    corrupted = true
                    return
                }
                payload += data.prefix(remaining)
                nextSequence = (nextSequence + 1) & 0x0F
                if payload.count >= total {
                    messages.append(payload)
                    payload = []
                    declared = nil
                }
            default:
                // Flow control from a module, or an invalid frame type: never part of an answer.
                corrupted = true
            }
        }
    }

    /// Hex text to bytes; nil for odd length or a non-hex character.
    static func bytes(_ hex: String) -> [UInt8]? {
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard hex[index..<next].allSatisfy(\.isHexDigit), let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            result.append(byte)
            index = next
        }
        return result
    }

    // MARK: Restore verification

    /// The line shapes a complete positive `0100` answer takes, headers on and spaces off as the
    /// initialization leaves the adapter. Each is exactly as strict as the others: an OBD
    /// responder's header, `41 00` and the four-byte supported-PID bitmap, nothing short.
    enum SupportedPIDsAnswerShape: CaseIterable {
        /// ISO 15765-4 11-bit (protocols 6, 8): a single frame from `7E8`–`7EF`,
        /// `7E8064100BE3FA813`.
        case can11Bit
        /// ISO 15765-4 29-bit (protocols 7, 9): a single frame to the tester, `18DAF1` plus the
        /// responder's address, `18DAF110064100BE3FA813`.
        case can29Bit
        /// J1850 PWM/VPW, ISO 9141-2 and ISO 14230-4 KWP (protocols 1–5): a three-byte header,
        /// `41 00`, the bitmap and the check byte, `486B104100BE3FA813` + check byte.
        case legacy
    }

    /// Whether a functional `0100` reply holds a complete positive answer from an 11-bit OBD
    /// responder (7E8–7EF): a single frame of exactly `41 00` plus the four-byte supported-PID
    /// bitmap, e.g. `7E8064100BE3FA813`. That's the proof the adapter is back on functional
    /// addressing; a shorter frame (`7E8024100`) is not an answer to `0100` and proves nothing.
    static func isPositiveSupportedPIDsAnswer(_ lines: [String]) -> Bool {
        isPositiveSupportedPIDsAnswer(lines, shapes: [.can11Bit])
    }

    /// Whether any line is a complete positive `0100` answer in one of `shapes`.
    static func isPositiveSupportedPIDsAnswer(_ lines: [String], shapes: Set<SupportedPIDsAnswerShape>) -> Bool {
        lines.contains { raw in
            let line = raw.replacingOccurrences(of: " ", with: "").uppercased()
            guard !line.isEmpty, line.allSatisfy(\.isHexDigit) else { return false }
            return shapes.contains { isPositiveSupportedPIDsLine(line, shape: $0) }
        }
    }

    private static func isPositiveSupportedPIDsLine(_ line: String, shape: SupportedPIDsAnswerShape) -> Bool {
        switch shape {
        case .can11Bit:
            guard line.count > 3, let id = UInt16(line.prefix(3), radix: 16), (0x7E8...0x7EF).contains(id) else {
                return false
            }
            return isSupportedPIDsSingleFrame(String(line.dropFirst(3)))
        case .can29Bit:
            // Priority 18, physical-response format DA, target the tester (F1), any responder.
            guard line.count > 8, line.hasPrefix("18DAF1") else { return false }
            return isSupportedPIDsSingleFrame(String(line.dropFirst(8)))
        case .legacy:
            // Header (priority, target, source), 41 00, four bitmap bytes, check byte.
            guard let message = bytes(line), message.count == 10 else { return false }
            return message[3] == 0x41 && message[4] == 0x00
        }
    }

    /// An ISO-TP single frame (after the CAN id) of exactly `41 00` and four bitmap bytes:
    /// PCI `06`, padding after the declared length allowed, never more than eight bytes.
    private static func isSupportedPIDsSingleFrame(_ hex: String) -> Bool {
        guard let frame = bytes(hex), frame.count <= 8, let pci = frame.first, pci >> 4 == 0 else {
            return false
        }
        return Int(pci & 0x0F) == 6 && frame.count >= 7 && frame[1] == 0x41 && frame[2] == 0x00
    }
}
