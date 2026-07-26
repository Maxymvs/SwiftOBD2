//
//  DTCScanContract.swift
//  SwiftOBD2
//
//  The diagnostic-trouble-code scan contract: services, ECU addressing, per-responder
//  outcomes and the request-level results they live in.
//
//  Only a *verified positive* response ever reads as clean — silence, refusal, damage and
//  transport trouble are all distinct, representable outcomes. Contradictory states are
//  unrepresentable by construction: responder maps are validated non-empty, so
//  "answered by nobody" cannot be built.
//

import Foundation

// MARK: - Services and lineage

/// A generic OBD-II diagnostic service that reports trouble codes.
public enum DTCService: String, Sendable, Hashable, Codable, CaseIterable {
    /// Mode 03 — confirmed/stored codes.
    case stored
    /// Mode 07 — pending codes from the current or last completed drive cycle.
    case pending
    /// Mode 0A — permanent codes (cleared only by the ECU itself).
    case permanent

    /// The ELM327 request bytes for this service.
    public var requestMode: String {
        switch self {
        case .stored: return "03"
        case .pending: return "07"
        case .permanent: return "0A"
        }
    }

    /// The positive-response mode byte this service must echo (`43` / `47` / `4A`).
    public var positiveResponseByte: UInt8 {
        switch self {
        case .stored: return 0x43
        case .pending: return 0x47
        case .permanent: return 0x4A
        }
    }

    /// The lineage carried by codes obtained from this service.
    public var kind: DTCKind {
        switch self {
        case .stored: return .stored
        case .pending: return .pending
        case .permanent: return .permanent
        }
    }
}

/// The lineage of an individual observed code — kept separate from ``DTCService`` so a
/// stored observation stays meaningful independently of the request that produced it.
public enum DTCKind: String, Sendable, Hashable, Codable, CaseIterable {
    case stored
    case pending
    case permanent
}

// MARK: - ECU addressing

/// A stable, protocol-specific responder address (e.g. a CAN TX id such as `0x7E8`, or a
/// K-line source address).
///
/// Unlike ``ECUID`` — which collapses every responder to engine/transmission/unknown and
/// stays a *display* label — this preserves the identity the vehicle actually answered
/// with, so two non-engine modules can never collide in a responder map.
public struct ECUAddress: Sendable, Hashable, CustomStringConvertible {
    /// The raw protocol address. CAN ids (11- or 29-bit) fit as-is.
    public let raw: UInt32

    public init(raw: UInt32) {
        self.raw = raw
    }

    /// Hexadecimal rendering, e.g. `0x7E8`.
    public var description: String {
        "0x" + String(raw, radix: 16, uppercase: true)
    }
}

// MARK: - Observations

/// One trouble code as observed from one responder during one service request.
public struct DTCObservation: Sendable, Hashable {
    /// The code itself, e.g. `"P0420"`.
    public let code: String
    /// Whether the code is stored, pending or permanent.
    public let kind: DTCKind
    /// The responder that reported it.
    public let ecuAddress: ECUAddress
    /// Optional library-table description; consumers should prefer their own lookup.
    public let description: String?

    public init(code: String, kind: DTCKind, ecuAddress: ECUAddress, description: String? = nil) {
        self.code = code
        self.kind = kind
        self.ecuAddress = ecuAddress
        self.description = description
    }
}

// MARK: - Negative responses

/// A `7F <service> <nrc>` negative response code, preserved raw.
///
/// The raw byte is kept because dispositions are not interchangeable: only
/// `0x11`/`0x12` mean "the vehicle does not offer this service", while `0x21`/`0x78`
/// mean the exchange has not concluded at all.
public struct NegativeResponseCode: Sendable, Hashable, CustomStringConvertible {
    /// The raw NRC byte as sent by the ECU.
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// service not supported
    public static let serviceNotSupported = NegativeResponseCode(rawValue: 0x11)
    /// sub-function not supported
    public static let subFunctionNotSupported = NegativeResponseCode(rawValue: 0x12)
    /// busy — repeat request
    public static let busyRepeatRequest = NegativeResponseCode(rawValue: 0x21)
    /// conditions not correct
    public static let conditionsNotCorrect = NegativeResponseCode(rawValue: 0x22)
    /// request out of range
    public static let requestOutOfRange = NegativeResponseCode(rawValue: 0x31)
    /// response pending
    public static let responsePending = NegativeResponseCode(rawValue: 0x78)

    /// `true` when the code ends the exchange for this scan.
    ///
    /// `0x21` (busy) and `0x78` (response pending) are interim answers — everything else,
    /// including codes we don't recognise, is terminal.
    public var isTerminal: Bool {
        switch rawValue {
        case Self.busyRepeatRequest.rawValue, Self.responsePending.rawValue:
            return false
        default:
            return true
        }
    }

    /// `true` only for `0x11`/`0x12` — the sole codes that justify treating a service as
    /// unsupported (and the only ones allowed to populate the advisory unsupported cache).
    public var derivesUnsupported: Bool {
        rawValue == Self.serviceNotSupported.rawValue || rawValue == Self.subFunctionNotSupported.rawValue
    }

    public var description: String {
        "0x" + String(format: "%02X", rawValue)
    }
}

// MARK: - Transport failures

/// A *recoverable*, request-scoped transport failure.
///
/// There is deliberately no `disconnected` case: link loss is terminal and always leaves
/// through ``DTCScanError``, never as a per-service outcome.
public enum DTCTransportFailure: String, Sendable, Hashable, Codable, CaseIterable {
    /// The adapter produced no answer within the request window.
    case requestTimeout
    /// The adapter itself errored (BLE/WiFi write or protocol-level failure).
    case adapterError
}

// MARK: - Per-responder outcomes

/// What a single ECU did with a single DTC service request.
public enum DTCResponderOutcome: Sendable, Equatable {
    /// A verified positive mode byte with a consistent count byte. `codes` may be empty —
    /// that, and only that, is an affirmative clean answer.
    case responded(codes: [DTCObservation])
    /// `7F <service> <nrc>` with a service byte echoing the in-flight request.
    case negativeResponse(NegativeResponseCode)
    /// This responder's message was unusable. Carries no payload: salvage means keeping
    /// *other* responders' valid messages, never partial pairs out of a damaged one.
    case malformed

    /// Whether the request/response exchange with this responder concluded definitively.
    ///
    /// A negative response resolves the request without obtaining any coverage — except
    /// for the interim `0x21`/`0x78` codes, which resolve nothing.
    public var isRequestResolved: Bool {
        switch self {
        case .responded:
            return true
        case let .negativeResponse(nrc):
            return nrc.isTerminal
        case .malformed:
            return false
        }
    }

    /// Whether this responder actually yielded diagnostic data (empty code lists count).
    public var providesCoverage: Bool {
        if case .responded = self { return true }
        return false
    }

    /// Whether this responder affirmatively reported nothing wrong.
    public var isClean: Bool {
        if case let .responded(codes) = self { return codes.isEmpty }
        return false
    }

    /// The codes this responder reported; empty for every non-`responded` outcome.
    public var codes: [DTCObservation] {
        if case let .responded(codes) = self { return codes }
        return []
    }
}

/// A validated **non-empty** map of responder address → outcome.
///
/// `DTCServiceResult.answered` can only be built around one of these, so "answered by
/// nobody" is unrepresentable.
public struct DTCResponders: Sendable, Equatable {
    /// Every responder that was recoverable for this request.
    public let outcomes: [ECUAddress: DTCResponderOutcome]

    /// Fails when `outcomes` is empty — the only rejection reason.
    public init?(_ outcomes: [ECUAddress: DTCResponderOutcome]) {
        guard !outcomes.isEmpty else { return nil }
        self.outcomes = outcomes
    }

    public subscript(address: ECUAddress) -> DTCResponderOutcome? {
        outcomes[address]
    }

    /// Responder addresses, ordered by raw address for deterministic rendering.
    public var addresses: [ECUAddress] {
        outcomes.keys.sorted { $0.raw < $1.raw }
    }

    public var count: Int { outcomes.count }
}

// MARK: - Request-level results

/// The outcome of one DTC service request (one functional broadcast).
public enum DTCServiceResult: Sendable, Equatable {
    /// At least one responder was recoverable; per-ECU detail lives inside.
    case answered(DTCResponders)
    /// `NO DATA` or genuinely empty transport output. **Not** clean.
    case noResponse
    /// Bytes arrived but no ECU-addressed responder was recoverable. Not clean, and not
    /// silence — the vehicle did answer.
    case invalidResponse
    /// A recoverable, request-scoped transport failure (the link is still up).
    case transportFailure(DTCTransportFailure)

    /// The responder map, when this request was answered.
    public var responders: DTCResponders? {
        if case let .answered(responders) = self { return responders }
        return nil
    }

    /// Every responder answered affirmatively with no codes.
    public var isClean: Bool {
        guard let responders else { return false }
        return responders.outcomes.values.allSatisfy(\.isClean)
    }

    /// Every responder yielded diagnostic data — refusals and damage both break this.
    public var isCoverageComplete: Bool {
        guard let responders else { return false }
        return responders.outcomes.values.allSatisfy(\.providesCoverage)
    }
}

// MARK: - Status (Mode 01 PID 01) read

/// What a single ECU did with the `0101` status request.
public enum DTCStatusResponderOutcome: Sendable, Equatable {
    /// A verified positive `41 01` payload.
    case responded(Status)
    case negativeResponse(NegativeResponseCode)
    case malformed
}

/// A validated **non-empty** map of responder address → status outcome, so a mixed status
/// read (one ECU valid, another refused) preserves both sides.
public struct DTCStatusResponders: Sendable, Equatable {
    public let outcomes: [ECUAddress: DTCStatusResponderOutcome]

    /// Fails when `outcomes` is empty — the only rejection reason.
    public init?(_ outcomes: [ECUAddress: DTCStatusResponderOutcome]) {
        guard !outcomes.isEmpty else { return nil }
        self.outcomes = outcomes
    }

    public subscript(address: ECUAddress) -> DTCStatusResponderOutcome? {
        outcomes[address]
    }

    /// Responder addresses, ordered by raw address for deterministic rendering.
    public var addresses: [ECUAddress] {
        outcomes.keys.sorted { $0.raw < $1.raw }
    }

    public var count: Int { outcomes.count }
}

/// The `0101` read that accompanies a scan. Advisory context only: it never affects
/// whether a scan is clean or coverage-complete.
public enum DTCStatusReadResult: Sendable, Equatable {
    /// The scan did not read `0101` (e.g. the consumer reads it itself).
    case notAttempted
    case answered(DTCStatusResponders)
    case noResponse
    case invalidResponse
    case transportFailure(DTCTransportFailure)
}

// MARK: - Profiles

/// Which services a scan asks for — so a report can never claim more than was requested.
public enum DTCScanProfile: String, Sendable, Hashable, Codable, CaseIterable {
    /// Stored codes only. Interim profile while only Mode 03 is implemented; clean claims
    /// read "stored-code check clean", never "vehicle clean".
    case storedOnly
    /// A user-initiated full scan: stored + pending + permanent, all required.
    case full
    /// The connect-time quick check: stored + pending required, permanent optional.
    case quickConnect

    /// Services that must be present in a report for this profile.
    public var requiredServices: Set<DTCService> {
        switch self {
        case .storedOnly: return [.stored]
        case .full: return [.stored, .pending, .permanent]
        case .quickConnect: return [.stored, .pending]
        }
    }

    /// Services a report for this profile may contain. Anything else is a validation
    /// failure; the difference from ``requiredServices`` is the profile's optional set.
    public var allowedServices: Set<DTCService> {
        switch self {
        case .storedOnly: return [.stored]
        case .full: return [.stored, .pending, .permanent]
        case .quickConnect: return [.stored, .pending, .permanent]
        }
    }
}
