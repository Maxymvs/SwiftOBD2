//
//  DTCReadiness.swift
//  SwiftOBD2
//
//  SAE J1979 Mode 01 PID 01 readiness monitors: the public per-responder readiness
//  contract and the conservative multi-ECU aggregate derived from a scan's `0101` read.
//
//  Inherits the DTC reliability invariant verbatim: **only verified evidence ever reads as
//  ready**. Silence, refusal, damage and undecodable payloads are all distinct from
//  "complete," and none of them may ever render as it. Invalid states are unconstructible:
//  ``ECUReadiness`` is total over its ignition type's applicable monitor set by its
//  initializer (including the `Codable` path), and ``VehicleReadinessAssessment`` has no
//  public constructor that accepts a verdict at all — only the total derivation.
//

import Foundation

// MARK: - Monitors

/// An SAE J1979 readiness monitor. One namespace for both ignition types; which
/// non-continuous monitors apply to a given ECU is decided by its ignition-type flag.
///
/// `CaseIterable` order is the canonical rendering order (continuous first, then the spark
/// table, then the compression table, then the monitor both tables share) and aggregates
/// sort their unions by it.
public enum ReadinessMonitor: String, Sendable, Hashable, Codable, CaseIterable {
    // Continuous (byte B) — present for every ignition type.
    case misfire
    case fuelSystem
    case comprehensiveComponents
    // Non-continuous, spark (byte C/D, ignition flag = spark).
    case catalyst
    case heatedCatalyst
    case evaporativeSystem
    case secondaryAirSystem
    case oxygenSensor
    case oxygenSensorHeater
    // Non-continuous, compression (byte C/D, ignition flag = compression).
    case nmhcCatalyst
    case noxScrAftertreatment
    case boostPressure
    case exhaustGasSensor
    case pmFilter
    // Shared bit-7 monitor — same case for both tables.
    case egrVvtSystem
}

/// Per monitor, per responder — mutually exclusive by construction.
public enum ReadinessMonitorState: String, Sendable, Hashable, Codable {
    /// Supported bit = 0. The incomplete bit is then **meaningless** and is never read.
    case unsupported
    /// Supported bit = 1, incomplete bit = 0.
    case complete
    /// Supported bit = 1, incomplete bit = 1.
    case incomplete
}

// MARK: - Per-responder readiness

/// One responder's decoded readiness. Lives on ``Status`` as an additive optional.
///
/// Total by construction: `monitors` holds *exactly* the applicable key set for its
/// ignition type — the 3 continuous monitors plus the defined positions of that ignition
/// table (7 spark, 6 compression). Reserved bits are never decoded, so they are absent;
/// absence means "not a monitor on this ECU", never a state.
public struct ECUReadiness: Sendable, Hashable, Codable {
    public enum IgnitionType: String, Sendable, Hashable, Codable {
        case spark
        case compression
    }

    /// Decoded from the same byte-B bit as ``Status/ignitionType``; this typed value is
    /// authoritative (it selected the table). The legacy string field stays display-only.
    public let ignitionType: IgnitionType

    /// Total over: the 3 continuous monitors + the *defined* positions of this responder's
    /// 8-bit ignition table.
    public let monitors: [ReadinessMonitor: ReadinessMonitorState]

    /// Fails unless `monitors`' key set is *exactly* ``ECUReadiness/applicableMonitors(for:)``
    /// for `ignitionType` — a spark map carrying a compression monitor, a map missing a
    /// continuous monitor, and a partial table all fail. Totality is a type invariant, not
    /// a decoder courtesy: the decoder's own output goes through this initializer too.
    public init?(ignitionType: IgnitionType, monitors: [ReadinessMonitor: ReadinessMonitorState]) {
        guard Set(monitors.keys) == Self.applicableMonitors(for: ignitionType) else { return nil }
        self.ignitionType = ignitionType
        self.monitors = monitors
    }

    /// The exact monitor set that applies to `ignitionType`: the continuous monitors plus
    /// that ignition table's defined positions.
    public static func applicableMonitors(for ignitionType: IgnitionType) -> Set<ReadinessMonitor> {
        Set(continuousMonitors).union(nonContinuousTable(for: ignitionType).compactMap { $0 })
    }

    /// The three continuous monitors, in byte-B order — present for every ignition type.
    static let continuousMonitors: [ReadinessMonitor] = [
        .misfire, .fuelSystem, .comprehensiveComponents
    ]

    /// Byte C/D bit 0…7 → monitor for the given ignition type. `nil` positions are SAE
    /// **reserved** and are never decoded into monitors, whatever their bit value.
    static func nonContinuousTable(for ignitionType: IgnitionType) -> [ReadinessMonitor?] {
        switch ignitionType {
        case .spark:
            return [
                .catalyst,            // bit 0
                .heatedCatalyst,      // bit 1
                .evaporativeSystem,   // bit 2
                .secondaryAirSystem,  // bit 3
                nil,                  // bit 4 — reserved
                .oxygenSensor,        // bit 5
                .oxygenSensorHeater,  // bit 6
                .egrVvtSystem         // bit 7
            ]
        case .compression:
            return [
                .nmhcCatalyst,         // bit 0
                .noxScrAftertreatment, // bit 1
                nil,                   // bit 2 — reserved
                .boostPressure,        // bit 3
                nil,                   // bit 4 — reserved
                .exhaustGasSensor,     // bit 5
                .pmFilter,             // bit 6
                .egrVvtSystem          // bit 7
            ]
        }
    }

    /// Monitors whose state is `.incomplete`, in ``ReadinessMonitor`` `CaseIterable` order.
    public var incompleteMonitors: [ReadinessMonitor] {
        ReadinessMonitor.allCases.filter { monitors[$0] == .incomplete }
    }

    /// Whether this responder supports at least one monitor. A responder supporting none
    /// proves nothing about readiness — see ``VehicleReadinessAssessment/Undetermined/noSupportedMonitors``.
    public var hasSupportedMonitors: Bool {
        monitors.values.contains { $0 != .unsupported }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case ignitionType
        case monitors
    }

    /// Swift's synthesized `init(from:)` assigns stored properties directly and would
    /// bypass ``init(ignitionType:monitors:)`` — so decoding delegates to the validated
    /// initializer and throws ``DecodingError/dataCorrupted(_:)`` when validation fails.
    /// No door into the type skips validation.
    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ignitionType = try container.decode(IgnitionType.self, forKey: .ignitionType)
        let monitors = try container.decode(
            [ReadinessMonitor: ReadinessMonitorState].self, forKey: .monitors
        )
        guard let validated = ECUReadiness(ignitionType: ignitionType, monitors: monitors) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: """
                    Decoded readiness is not total over the \(ignitionType.rawValue) monitor set: \
                    expected exactly \(ECUReadiness.applicableMonitors(for: ignitionType).count) \
                    monitors, found \(monitors.count).
                    """
                )
            )
        }
        self = validated
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ignitionType, forKey: .ignitionType)
        try container.encode(monitors, forKey: .monitors)
    }
}

// MARK: - Multi-ECU aggregation

/// A conservative readiness claim over one scan's `0101` read.
///
/// One assessment = one ``DTCStatusReadResult``. Claims are never merged across scans,
/// sessions or vehicles.
///
/// **Construction surface:** the memberwise initializer is `internal`; the only public
/// constructor is the total derivation ``init(statusRead:)``. Nothing can be rejected
/// because nothing can be supplied — "complete with unknown responders" is unrepresentable
/// to callers because no caller ever assembles a verdict/responders pair by hand.
public struct VehicleReadinessAssessment: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// Union across responders, **deduplicated**, ordered by ``ReadinessMonitor``
        /// `CaseIterable` position (two ECUs both reporting evap incomplete contribute one
        /// entry). The union is namespace-blind by design: responders with different
        /// ignition types (hybrids, quirky gateways) contribute their own table's monitors.
        case incomplete(monitors: [ReadinessMonitor])
        /// Every recovered responder decoded readiness and every supported monitor on every
        /// one of them is complete. Scoped to the responders that were *reported*.
        case complete
        /// Why nothing stronger can be claimed.
        case undetermined(Undetermined)
    }

    public enum Undetermined: Sendable, Equatable {
        /// `statusRead ≠ .answered` — the cause is **preserved**, not collapsed, so
        /// rendering can tell "never asked" from "vehicle silent".
        case statusNotRead(StatusUnavailable)
        /// Responders answered; none yielded a decodable readiness payload.
        case noDecodableReadiness
        /// ≥1 decoded responder **supports** monitors (all complete), ≥1 responder unknown.
        ///
        /// The supported-monitor requirement keeps the rendered sentence "every reporting
        /// module is complete" from being vacuously false-sounding when the decoded modules
        /// monitor nothing — that combination is ``noSupportedMonitors``.
        case partialEvidence
        /// No **decoded** responder supports any monitor — scoped to reported modules, so it
        /// composes with unknowns: carried ``undeterminedResponders`` render as a suffix
        /// ("— N module(s) didn't report readiness").
        ///
        /// Never a vacuous `.complete` ("ready because nothing is monitored" is not a claim
        /// worth rendering) and never ``noDecodableReadiness``, which would be factually
        /// wrong — readiness *was* decoded fine.
        case noSupportedMonitors
    }

    /// Why the status read produced no responder map. One case per non-`.answered`
    /// ``DTCStatusReadResult`` case — additions there are compile-visible here.
    public enum StatusUnavailable: Sendable, Equatable {
        case notAttempted
        case noResponse
        case invalidResponse
        case transportFailure(DTCTransportFailure)
    }

    public let verdict: Verdict

    /// **All** responders whose readiness is unknown (refused, malformed, or
    /// `readiness == nil`), ascending by address — valid under every verdict; for a lone
    /// refused responder it holds that one address.
    ///
    /// Invariant: non-empty ⇒ `verdict != .complete`.
    public let undeterminedResponders: [ECUAddress]

    /// Internal so the only public door is the derivation below.
    init(verdict: Verdict, undeterminedResponders: [ECUAddress]) {
        self.verdict = verdict
        self.undeterminedResponders = undeterminedResponders
    }

    /// The total derivation. Precedence — the whole design in one rule:
    /// **incomplete beats undetermined beats complete.**
    ///
    /// 0. `statusRead ≠ .answered` ⇒ `.undetermined(.statusNotRead(cause))`, evaluated
    ///    first, with the cause carried over. (An `.answered` map is non-empty by
    ///    ``DTCStatusResponders`` validation, so every later rule quantifies over at least
    ///    one responder.)
    /// 1. Any decoded responder reporting ≥1 `incomplete` monitor ⇒ `.incomplete(union)` —
    ///    positive evidence of incompleteness can never over-claim readiness, so it is
    ///    valid even when other responders are unknown; those are carried in
    ///    ``undeterminedResponders`` and rendered as a caveat.
    /// 2. No decoded responder supports **any** monitor ⇒
    ///    `.undetermined(.noSupportedMonitors)` — evaluated *before* the partial-evidence
    ///    check, because "every reporting module is complete" must never be uttered when
    ///    the reporting modules monitor nothing; carried unknowns render as a suffix.
    /// 3. `.complete` requires **total** evidence *over the recovered responders*: every
    ///    responder decoded, ≥1 supported monitor exists, and every supported monitor is
    ///    complete. One refused/malformed/undecodable responder forbids it — with the rest
    ///    all-complete (and supporting ≥1 monitor somewhere) that is
    ///    `.undetermined(.partialEvidence)`.
    /// 4. Nobody decoded readiness at all ⇒ `.undetermined(.noDecodableReadiness)`.
    ///    Evaluated in code *before* rule 2, which would otherwise be vacuously true over
    ///    an empty decoded set and steal the honest "nothing was readable" answer.
    public init(statusRead: DTCStatusReadResult) {
        switch statusRead {
        case .notAttempted:
            self.init(verdict: .undetermined(.statusNotRead(.notAttempted)), undeterminedResponders: [])
        case .noResponse:
            self.init(verdict: .undetermined(.statusNotRead(.noResponse)), undeterminedResponders: [])
        case .invalidResponse:
            self.init(verdict: .undetermined(.statusNotRead(.invalidResponse)), undeterminedResponders: [])
        case let .transportFailure(failure):
            self.init(
                verdict: .undetermined(.statusNotRead(.transportFailure(failure))),
                undeterminedResponders: []
            )
        case let .answered(responders):
            self.init(responders: responders)
        }
    }

    private init(responders: DTCStatusResponders) {
        var decoded: [ECUReadiness] = []
        var unknown: [ECUAddress] = []
        // `addresses` is ascending by raw address, so both collections are deterministic.
        for address in responders.addresses {
            guard case let .responded(status) = responders[address],
                  let readiness = status.readiness
            else {
                unknown.append(address)
                continue
            }
            decoded.append(readiness)
        }

        // Rule 1 — positive evidence of incompleteness wins outright.
        var incompleteUnion: Set<ReadinessMonitor> = []
        for readiness in decoded {
            incompleteUnion.formUnion(readiness.incompleteMonitors)
        }
        if !incompleteUnion.isEmpty {
            let ordered = ReadinessMonitor.allCases.filter { incompleteUnion.contains($0) }
            self.init(verdict: .incomplete(monitors: ordered), undeterminedResponders: unknown)
            return
        }

        // Rule 4, hoisted — nobody decoded readiness at all. It must precede rule 2: over an
        // empty decoded set "no decoded responder supports any monitor" is vacuously true,
        // and answering `.noSupportedMonitors` there would claim knowledge of monitors that
        // were never read.
        if decoded.isEmpty {
            self.init(verdict: .undetermined(.noDecodableReadiness), undeterminedResponders: unknown)
            return
        }

        // Rule 2 — the reporting modules monitor nothing. Ahead of rule 3 so an unknown
        // responder alongside them cannot produce `.partialEvidence`, whose wording ("every
        // reporting module is complete") would be vacuously false-sounding here. Scoped to
        // the decoded responders, so it composes with the unknowns rather than hiding them.
        guard decoded.contains(where: \.hasSupportedMonitors) else {
            self.init(verdict: .undetermined(.noSupportedMonitors), undeterminedResponders: unknown)
            return
        }

        // Rule 3 — `.complete` needs total evidence over the recovered responders.
        if !unknown.isEmpty {
            self.init(verdict: .undetermined(.partialEvidence), undeterminedResponders: unknown)
            return
        }

        self.init(verdict: .complete, undeterminedResponders: unknown)
    }
}
