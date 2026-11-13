//
//  AdapterIdentity.swift
//  SwiftOBD2
//
//  What an adapter says about itself, and which vehicle computers answered it.
//
//  Clone firmware reports versions that genuine ELM327 chips never shipped ("v1.5", "v2.2"),
//  so these strings are evidence for classification, not a verdict. Two adapters that both
//  claimed "ELM327 v1.5" behaved differently on the same car (2026-11-03 Tiguan capture):
//  one heard the transmission, one only ever heard the engine.
//

import Foundation

public struct AdapterIdentity: Codable, Hashable, Sendable {
    /// `ATI` reply, e.g. "ELM327 v1.5". STN chips emulate this too ("ELM327 v1.4b").
    public var elmVersion: String?
    /// `AT@1` device description, e.g. "OBD SOLUTIONS LLC" or "OBDII to RS232 Interpreter".
    public var deviceDescription: String?
    /// `STI` reply on STN-based adapters (OBDLink), e.g. "STN2310 v5.10.1". Nil when the
    /// adapter rejected the command, which every clone in our captures did.
    public var stnFirmware: String?

    public init(elmVersion: String? = nil, deviceDescription: String? = nil, stnFirmware: String? = nil) {
        self.elmVersion = elmVersion
        self.deviceDescription = deviceDescription
        self.stnFirmware = stnFirmware
    }

    /// Longest identity string kept. Real answers are under 32 characters ("STN2310 v5.10.1").
    static let maxAnswerLength = 40

    /// The adapter's own answer to an identity command, or nil for rejections, prompts,
    /// echoes and status text. Adapter replies are untrusted input: only printable ASCII is
    /// kept, whitespace is collapsed and the result is capped at `maxAnswerLength`.
    static func answer(to command: String, lines: [String]?) -> String? {
        guard let lines else { return nil }
        let rejected: Set<String> = ["?", "OK", "NO DATA", "ERROR"]
        for raw in lines {
            let line = sanitize(raw)
            guard !line.isEmpty else { continue }
            if rejected.contains(line.uppercased()) { continue }
            // Echo is off after init, but some clones echo anyway.
            if line.replacingOccurrences(of: " ", with: "").uppercased() == command { continue }
            return line
        }
        return nil
    }

    static func sanitize(_ raw: String) -> String {
        let printable = raw.unicodeScalars.map { scalar -> Character in
            (0x21...0x7E).contains(scalar.value) && scalar != ">" ? Character(scalar) : " "
        }
        let collapsed = String(printable)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return String(collapsed.prefix(maxAnswerLength))
    }

    /// STN firmware looks like "STN2310 v5.10.1": "STN", four digits, a version.
    static func stnFirmware(from answer: String?) -> String? {
        guard let answer,
              answer.range(of: #"^STN[0-9]{4}( v[0-9][0-9A-Za-z.]*)?$"#, options: .regularExpression) != nil
        else { return nil }
        return answer
    }
}

/// Completed identity probes per BLE peripheral for one app session, including "nothing
/// answered". A cancelled probe, a probe whose peripheral changed while it ran, or one
/// without a peripheral (Wi-Fi) is never stored.
struct AdapterIdentityCache {
    private var entries: [UUID: AdapterIdentity?] = [:]

    /// `.some(identity)` when a completed probe for this peripheral is cached (identity may be
    /// nil); nil when the adapter must be asked.
    func lookup(_ peripheralID: UUID?) -> AdapterIdentity?? {
        guard let peripheralID else { return nil }
        return entries[peripheralID]
    }

    mutating func store(_ probe: ELM327.IdentityProbe, for peripheralID: UUID?, currentPeripheral: UUID?) {
        guard probe.completed, let peripheralID, peripheralID == currentPeripheral else { return }
        entries[peripheralID] = .some(probe.identity)
    }
}

extension OBDInfo {
    /// CAN response headers that answered the functional `0100`, e.g. ["7E8", "7E9"] for an
    /// engine and a transmission. Only well-formed positive single-frame `41 00` replies from
    /// OBD response identifiers count (7E8–7EF, or 18DAF1xx on 29-bit CAN). Nil for non-CAN
    /// protocols or when nothing qualified.
    static func responderHeaders(from lines: [String], obdProtocol: PROTOCOL?) -> [String]? {
        let headerLength: Int
        switch obdProtocol {
        case .protocol6, .protocol8: headerLength = 3
        case .protocol7, .protocol9: headerLength = 8
        default: return nil
        }
        var headers: [String] = []
        for line in lines {
            let compact = Array(line.replacingOccurrences(of: " ", with: "").uppercased())
            guard compact.allSatisfy(\.isHexDigit), compact.count >= headerLength + 2 + 4 else { continue }
            let header = String(compact[0..<headerLength])
            if headerLength == 3 {
                guard header.hasPrefix("7E"), let last = header.last, "89ABCDEF".contains(last) else { continue }
            } else {
                guard header.hasPrefix("18DAF1") else { continue }
            }
            // A classic CAN frame: PCI plus up to seven data bytes, whole bytes only. The
            // positive 0100 reply is single-frame (PCI 06): 41 00 and a four-byte bitmap, with
            // any padding after it.
            let frame = compact[headerLength...]
            guard frame.count % 2 == 0, frame.count <= 16 else { continue }
            guard String(frame.prefix(2)) == "06" else { continue }
            let payload = frame.dropFirst(2)
            guard payload.count >= 12, String(payload.prefix(4)) == "4100" else { continue }
            if !headers.contains(header) { headers.append(header) }
        }
        return headers.isEmpty ? nil : headers.sorted()
    }
}
