//
//  DTCUnsupportedServiceStore.swift
//  SwiftOBD2
//
//  The **advisory** record of "this module told us it does not offer this service".
//
//  It exists for wording only. A generic DTC request is a functional broadcast, so one module's
//  `0x11` must never hide another module that does support the service — which is why nothing in
//  the scan path ever *reads* this store to decide whether to send a request. It is written on
//  terminal service-not-supported refusals and read by consumers that want to say
//  "ECU 0x7EA previously rejected permanent-code reads" instead of a vehicle-wide claim.
//

import Foundation

/// What a single module said about a single service, scoped so the claim can never widen.
///
/// Vehicle + ECU + protocol: the same module answers differently on a different protocol state,
/// and an address means nothing across vehicles.
public struct DTCUnsupportedServiceKey: Sendable, Hashable {
    /// The vehicle the refusal was observed on.
    ///
    /// **Never optional, deliberately.** It is the VIN when the adapter gave us one — so evidence
    /// survives reconnects to the same car — and otherwise an opaque per-connection session id. A
    /// shared `nil` would file every VIN-less vehicle in one bucket, and one car's refusal would
    /// then colour another car's wording inside the same process. Build it with ``vin(_:)`` or
    /// ``session(_:)`` rather than by hand.
    public let vehicleScope: String
    /// The module that refused.
    public let ecuAddress: ECUAddress
    /// The ELM protocol id in force at the time (e.g. `"6"`).
    public let protocolID: String?
    /// The service that was refused.
    public let service: DTCService

    public init(
        vehicleScope: String,
        ecuAddress: ECUAddress,
        protocolID: String?,
        service: DTCService
    ) {
        self.vehicleScope = vehicleScope
        self.ecuAddress = ecuAddress
        self.protocolID = protocolID
        self.service = service
    }

    /// Scope keyed by VIN — evidence is shared across reconnects to the same vehicle.
    public static func vin(_ vin: String) -> String { "vin:" + vin }

    /// Scope keyed by a single connection session — the only honest option with no VIN, since it
    /// cannot reach another vehicle.
    public static func session(_ id: UUID) -> String { "session:" + id.uuidString }
}

/// An injectable store of terminal service-not-supported evidence.
///
/// Implementations must be safe to call from the scan task. Reading is **advisory**: no
/// implementation may be consulted to suppress a request.
public protocol DTCUnsupportedServiceStore: AnyObject {
    /// Records a refusal. Callers only ever pass `0x11`/`0x12`; implementations must ignore
    /// anything else rather than trusting the caller.
    func record(_ key: DTCUnsupportedServiceKey, nrc: NegativeResponseCode)
    /// Whether this exact module/service/protocol/vehicle combination refused before.
    func isUnsupported(_ key: DTCUnsupportedServiceKey) -> Bool
    /// Everything recorded so far, for wording and diagnostics.
    var unsupportedKeys: Set<DTCUnsupportedServiceKey> { get }
}

/// The default in-memory store: cleared with the process, never persisted.
///
/// Deliberately not persistent — a refusal observed once should not outlive the session and
/// start colouring wording for a vehicle whose module set has changed.
public final class InMemoryDTCUnsupportedServiceStore: DTCUnsupportedServiceStore {
    private let lock = NSLock()
    private var keys: Set<DTCUnsupportedServiceKey> = []

    public init() {}

    public func record(_ key: DTCUnsupportedServiceKey, nrc: NegativeResponseCode) {
        // Only `0x11`/`0x12` derive "unsupported". A busy `0x21`, a pending `0x78`, a
        // conditions-not-correct `0x22` or a `NO DATA` all mean something else entirely, and the
        // datasheet is explicit that `NO DATA` is ambiguous.
        guard nrc.derivesUnsupported else { return }
        lock.lock()
        keys.insert(key)
        lock.unlock()
    }

    public func isUnsupported(_ key: DTCUnsupportedServiceKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.contains(key)
    }

    public var unsupportedKeys: Set<DTCUnsupportedServiceKey> {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }
}
