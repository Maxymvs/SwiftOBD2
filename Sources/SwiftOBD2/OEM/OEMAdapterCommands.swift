//
//  OEMAdapterCommands.swift
//  SwiftOBD2
//
//  Every adapter command the OEM path can send, in one table, so the vocabulary is auditable.
//
//  Only configurations proven on real cars are here (oem-data-parity-plan §9, §13):
//  - VW engine/transmission: `ATSH 7E0`/`7E1` with the adapter's automatic flow control;
//    restore `ATSH 7DF`.
//  - BMW: extended addressing with explicit flow control that carries the module address;
//    restore `ATFCSM 0`, `ATAR`, bare `ATCEA`, `ATSH 7DF`.
//  Then a functional `0100` proves the adapter is back on normal addressing.
//
//  After a command got no prompt, two adapter-only queries (`ATRV`, then `ATDPN`) prove that no
//  late answer is still on its way. The transport runs them for every command, manufacturer or
//  not (see `OBDStreamResynchronizer`). Neither reaches the car or changes any adapter setting. `ATI` is deliberately not one of them: it answers
//  `ELM327 …`, which is also the reset banner the addressing gate waits for after `ATZ`, so a
//  late probe answer could pass for a reset.
//
//  Never `ATD` (it resets echo, linefeeds, spaces and headers), `ATZ`, `ATWS`, `ATPP…`, `ATSP…`,
//  `ATST…` or `ATAT…`. A bare `ATCRA` answers `?` on a common clone, so `ATAR` clears the filter.
//

import Foundation

enum OEMAdapterCommand {
    /// The functional header every other request in the app assumes.
    static let functionalHeader = "ATSH 7DF"
    /// The only vehicle request besides `22 <DID>`: proof that functional addressing works again.
    static let verificationRequest = "0100"

    static func header(_ id: UInt16) -> String { "ATSH " + hex3(id) }
    static func extendedAddress(_ address: UInt8) -> String { "ATCEA " + hex2(address) }
    /// Bare `ATCEA`: extended addressing off.
    static let extendedAddressOff = "ATCEA"
    static func receiveAddress(_ id: UInt16) -> String { "ATCRA " + hex3(id) }
    /// Clears the receive filter without the bare `ATCRA` some clones reject.
    static let automaticReceive = "ATAR"
    static func flowControlHeader(_ id: UInt16) -> String { "ATFCSH " + hex3(id) }
    /// Flow control data with the module address in front: clear to send, no block limit,
    /// 10 ms between frames so clones keep up.
    static func flowControlData(address: UInt8) -> String { "ATFCSD " + hex2(address) + "30000A" }
    static let flowControlUserDefined = "ATFCSM 1"
    static let flowControlAutomatic = "ATFCSM 0"

    /// Commands that address `target`. Each must answer `OK`.
    static func setup(for target: OEMTarget) -> [String] {
        switch target {
        case let .standard11Bit(request, _):
            return [header(request)]
        case let .bmwExtended(address):
            let tester = 0x600 | UInt16(OEMTarget.bmwTesterAddress)
            return [
                extendedAddress(address),
                header(tester),
                receiveAddress(target.responseID),
                flowControlHeader(tester),
                flowControlData(address: address),
                flowControlUserDefined,
            ]
        }
    }

    /// Commands that undo `setup(for:)`, ending with the functional header. Each must answer
    /// `OK`; `verificationRequest` follows them.
    static func restore(for target: OEMTarget) -> [String] {
        switch target {
        case .standard11Bit:
            return [functionalHeader]
        case .bmwExtended:
            return [flowControlAutomatic, automaticReceive, extendedAddressOff, functionalHeader]
        }
    }

    /// A resynchronization probe: an adapter-only query whose answer no other command produces
    /// (not `OK`, not `?`, not status text, not a frame, not a reset banner). A late answer to an
    /// earlier send of the same probe is the one thing that looks like it, which is why the
    /// transport counts unanswered sends (see `OBDStreamResynchronizer`).
    struct SyncProbe {
        let command: String
        let isAnswer: ([String]) -> Bool
    }

    /// Tried in this order. The two answers can't be mistaken for each other either. Every
    /// adapter in our captures answers both (§9–§19: a voltage, and `A6`).
    static let syncProbes: [SyncProbe] = [
        SyncProbe(command: "ATRV", isAnswer: isVoltageAnswer),
        SyncProbe(command: "ATDPN", isAnswer: isProtocolNumberAnswer),
    ]

    /// `ATRV`: one line with the supply voltage, e.g. `14.1V`.
    static func isVoltageAnswer(_ lines: [String]) -> Bool {
        guard let answer = singleLine(lines), answer.hasSuffix("V") else { return false }
        let parts = answer.dropLast().split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2
            && (1...2).contains(parts[0].count) && (1...2).contains(parts[1].count)
            && parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// `ATDPN`: one line with the protocol number, `A` in front when it was found automatically:
    /// `A6`, `6`. One or two characters, so never a frame (a frame starts with a 3-digit id).
    ///
    /// A bare `A` is refused: it could be protocol A or a truncated `A6`, and this path only
    /// runs on protocols 6 and 8 anyway. Unproven is the safe reading.
    static func isProtocolNumberAnswer(_ lines: [String]) -> Bool {
        guard let answer = singleLine(lines), answer != "A" else { return false }
        let digits = answer.hasPrefix("A") && answer.count == 2 ? answer.dropFirst() : Substring(answer)
        guard digits.count == 1, let digit = digits.first else { return false }
        return digit.isASCII && digit.isHexDigit && digit <= "C"
    }

    /// The answer when it is exactly one non-empty line, trimmed and uppercased.
    private static func singleLine(_ lines: [String]) -> String? {
        let answer = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty }
        return answer.count == 1 ? answer[0] : nil
    }

    private static func hex3(_ value: UInt16) -> String { String(format: "%03X", value) }
    private static func hex2(_ value: UInt8) -> String { String(format: "%02X", value) }
}
