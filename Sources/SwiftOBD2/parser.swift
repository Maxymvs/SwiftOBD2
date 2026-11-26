//
//  parser.swift
//  SmartOBD2
//
//  Created by kemo konteh on 9/19/23.
//

import Foundation

enum FrameType: UInt8, Codable {
    case singleFrame = 0x00
    case firstFrame = 0x10
    case consecutiveFrame = 0x20
}

public enum ECUID: UInt8, Codable {
    case engine = 0x00
    case transmission = 0x01
    case unknown = 0x02

    public var description: String {
        switch self {
        case .engine:
            return "Engine"
        case .transmission:
            return "Transmission"
        case .unknown:
            return "Unknown"
        }
    }
}

enum TxId: UInt8, Codable {
    case engine = 0x00
    case transmission = 0x01
}

public struct CANParser {
    public let messages: [Message]
    let frames: [Frame]

    public init(_ lines: [String], idBits: Int) throws {
        let obdLines = lines
            .map { $0.replacingOccurrences(of: " ", with: "") }
            .filter(\.isHex)

        frames = try obdLines.compactMap { try Frame(raw: $0, idBits: idBits) }

        let framesByECU = Dictionary(grouping: frames) { $0.txID }

        messages = try framesByECU.values.compactMap { try Message(frames: $0) }
    }
}

public struct Message: MessageProtocol {
    var frames: [Frame]
    public var data: Data?

    public var ecu: ECUID {
        frames.first?.txID ?? .unknown
    }

    init(frames: [Frame]) throws {
        self.frames = frames
        switch frames.count {
        case 1:
            data = try parseSingleFrameMessage(frames)
        case 2...:
            data = try parseMultiFrameMessage(frames)
        default:
            throw ParserError.error("Invalid frame count")
        }
    }

    private func parseSingleFrameMessage(_ frames: [Frame]) throws -> Data {
        guard let frame = frames.first, frame.type == .singleFrame,
              let dataLen = frame.dataLen, dataLen > 0,
              frame.data.count >= dataLen + 1
        else { // Pre-validate the length
            throw ParserError.error("Frame validation failed")
        }
        // `0N <service> <payload…>`: N counts the service byte and the payload, nothing else.
        // Whatever follows is CAN padding (often `00`, `AA` or `55`) and must never be read as a
        // measurement, so the data stops at the declared length. `N == 1` leaves it empty.
        let start = frame.data.startIndex
        return frame.data[(start + 2) ..< (start + 1 + Int(dataLen))]
    }

    private func parseMultiFrameMessage(_ frames: [Frame]) throws -> Data {
        guard let firstFrame = frames.first(where: { $0.type == .firstFrame }) else {
            throw ParserError.error("Failed to parse multi frame message")
        }
        let consecutiveFrames = frames.filter { $0.type == .consecutiveFrame }
        return try assembleData(firstFrame: firstFrame, consecutiveFrames: consecutiveFrames)
    }

    private func assembleData(firstFrame: Frame, consecutiveFrames: [Frame]) throws -> Data {
        var assembledFrame: Frame = firstFrame
        // Extract data from consecutive frames, skipping the PCI byte
        for frame in consecutiveFrames {
            assembledFrame.data.append(frame.data[1...])
        }
        return try extractDataFromFrame(assembledFrame, startIndex: 3)
    }

    /// The declared payload of an assembled multi-frame message from `startIndex` on. The
    /// payload sits at `2 ..< 2 + length` (after the two first-frame PCI bytes), so this stops at
    /// `2 + length` and the last consecutive frame's padding is never read. A message that came up
    /// short keeps what arrived.
    private func extractDataFromFrame(_ frame: Frame, startIndex: Int) throws -> Data {
        guard let frameDataLen = frame.dataLen else {
            throw ParserError.error("Failed to extract data from frame")
        }
        let endIndex = startIndex + Int(frameDataLen) - 1
        guard endIndex <= frame.data.count else {
            return frame.data[startIndex...]
        }
        return frame.data[startIndex ..< endIndex]
    }
}

struct Frame {
    var raw: String
    var data = Data()
    var priority: UInt8
    var addrMode: UInt8
    var rxID: UInt8
    var txID: ECUID
    var type: FrameType
    var seqIndex: UInt8 = 0 // Only used when type = CF
    var dataLen: UInt8?

    init(raw: String, idBits: Int) throws {
        self.raw = raw

        let paddedRawData = idBits == 11 ? "00000" + raw : raw

        let dataBytes = paddedRawData.hexBytes

        data = Data(dataBytes.dropFirst(4))

        guard dataBytes.count >= 6, dataBytes.count <= 12 else {
            obdError("Invalid frame size: \(dataBytes.count) bytes", category: .parsing)
            OBDLogger.shared.logParseError("Frame size out of range (6-12 bytes)", data: Data(dataBytes), expectedFormat: "6-12 bytes")
            throw ParserError.error("Invalid frame size")
        }

        guard let dataType = data.first,
              let type = FrameType(rawValue: dataType & 0xF0)
        else {
            obdError("Invalid frame type detected", category: .parsing)
            OBDLogger.shared.logParseError("Unknown frame type", data: Data(dataBytes), expectedFormat: "Valid FrameType enum value")
            throw ParserError.error("Invalid frame type")
        }

        priority = dataBytes[2] & 0x0F
        addrMode = dataBytes[3] & 0xF0
        rxID = dataBytes[2]
        txID = ECUID(rawValue: dataBytes[3] & 0x07) ?? .unknown
        self.type = type

        switch type {
        case .singleFrame:
            dataLen = (data[0] & 0x0F)
        case .firstFrame:
            dataLen = ((UInt8(data[0] & 0x0F) << 8) + UInt8(data[1]))
        case .consecutiveFrame:
            seqIndex = data[0] & 0x0F
        }
    }
}

enum ParserError: Error {
    case error(String)
}

// MARK: - Response ownership

/// The service byte a responder sent and the byte after it (the echoed PID/MID for services
/// that echo one), read from the raw frames. The message parsers drop the service byte from
/// `data` (and the legacy multi-frame parser drops the echo and order byte too), so a decoder
/// can't tell a `41 0C` from a `41 0D`, a `49 02` or a `62 …` by `data` alone.
struct OBDResponseHead: Equatable {
    let service: UInt8
    let echo: UInt8?
}

/// Whether a parsed message is the positive answer to the request that was sent, so a late
/// reply landing in another command's slot can never decode as that command's value.
enum OBDResponseOwnership {
    /// Services whose positive response echoes the request's second byte (PID, MID, InfoType).
    private static let echoingServices: Set<UInt8> = [0x01, 0x02, 0x05, 0x06, 0x08, 0x09]

    /// The service and, for an echoing service, the PID a hex request asks for: `"010C"` →
    /// (0x01, 0x0C), `"03"` → (0x03, nil). Nil for anything that isn't a hex service request
    /// (adapter commands such as `ATRV`), which no parsed message can answer.
    static func request(_ command: String) -> (service: UInt8, pid: UInt8?)? {
        let compact = command.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 2, compact.count % 2 == 0, compact.isHex else { return nil }
        let bytes = compact.hexBytes
        guard let service = bytes.first, service < 0x40 else { return nil }
        let pid = echoingServices.contains(service) && bytes.count >= 2 ? bytes[1] : nil
        return (service, pid)
    }

    /// `message` is a positive response (`service + 0x40`) to `service` and, when `pid` is
    /// given, echoes it.
    static func isPositiveResponse(_ message: MessageProtocol, service: UInt8, pid: UInt8?) -> Bool {
        guard let head = message.responseHead, head.service == service &+ 0x40 else { return false }
        guard let pid else { return true }
        return head.echo == pid
    }

    /// `message` is the positive response to the hex request `command`.
    static func isPositiveResponse(_ message: MessageProtocol, to command: String) -> Bool {
        guard let request = request(command) else { return false }
        return isPositiveResponse(message, service: request.service, pid: request.pid)
    }
}

extension MessageProtocol {
    /// The service and echo byte as sent, or nil when they can't be read (unknown message type,
    /// too-short frame, or legacy frames that disagree on the service).
    var responseHead: OBDResponseHead? {
        switch self {
        case let message as Message:
            return message.canResponseHead
        case let message as LegacyMessage:
            return message.legacyResponseHead
        default:
            return nil
        }
    }
}

extension Message {
    /// ISO-TP: a single frame is `0N <service> <echo> …`, a first frame `1L LL <service> <echo> …`.
    var canResponseHead: OBDResponseHead? {
        if let first = frames.first(where: { $0.type == .firstFrame }) {
            let bytes = Array(first.data)
            guard bytes.count >= 4 else { return nil }
            return OBDResponseHead(service: bytes[2], echo: bytes[3])
        }
        guard frames.count == 1, let single = frames.first, single.type == .singleFrame else { return nil }
        let bytes = Array(single.data)
        let length = Int(bytes.first.map { $0 & 0x0F } ?? 0)
        guard length >= 1, bytes.count >= 2 else { return nil }
        return OBDResponseHead(service: bytes[1], echo: length >= 2 && bytes.count >= 3 ? bytes[2] : nil)
    }
}

extension LegacyMessage {
    /// Every legacy frame repeats `<service> <echo> …` after its header. All frames must agree on
    /// the service; the echo is kept only when they agree on it too.
    var legacyResponseHead: OBDResponseHead? {
        let heads = frames.map { Array($0.data) }
        guard let first = heads.first, let service = first.first,
              heads.allSatisfy({ $0.first == service })
        else { return nil }
        let echo = first.count >= 2 ? first[1] : nil
        let echoAgrees = heads.allSatisfy { ($0.count >= 2 ? $0[1] : nil) == echo }
        return OBDResponseHead(service: service, echo: echoAgrees ? echo : nil)
    }
}
