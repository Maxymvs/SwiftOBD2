//
//  OEMRequestPolicy.swift
//  SwiftOBD2
//
//  The read-only allowlist for manufacturer requests, and the typed batch it is applied to.
//
//  Default deny over the complete typed request: the only vehicle service this path can produce
//  is `22` (read data by identifier), one identifier per request, to one of four module targets.
//  Nothing outside that table can be expressed, let alone sent.
//

import Foundation

public enum OEMRequestPolicy {
    public static let maximumReadsPerBatch = 4
    /// Hard budget for one batch's configuration and reads. Restoring the adapter afterwards is
    /// outside it (see `OEMBatchExecutor`).
    public static let maximumBudget: TimeInterval = 2.0

    /// VW/Audi engine (7E0 → 7E8) and transmission (7E1 → 7E9), BMW DME (0x12) and EGS (0x18).
    public static let allowedTargets: Set<OEMTarget> = [
        .standard11Bit(request: 0x7E0, response: 0x7E8),
        .standard11Bit(request: 0x7E1, response: 0x7E9),
        .bmwExtended(address: 0x12),
        .bmwExtended(address: 0x18),
    ]

    /// Identifiers never read through this path. F190 is the VIN, which is personal data and is
    /// read (once, functionally) by connection setup instead.
    public static let deniedDataIdentifiers: Set<UInt16> = [0xF190]

    /// Throws unless every request in the batch is allowed. Order of checks: shape, target,
    /// identifiers.
    static func validate(target: OEMTarget, dataIdentifiers: [UInt16]) throws {
        guard !dataIdentifiers.isEmpty else { throw OEMPolicyViolation.emptyBatch }
        guard dataIdentifiers.count <= maximumReadsPerBatch else { throw OEMPolicyViolation.tooManyReads }
        guard Set(dataIdentifiers).count == dataIdentifiers.count else { throw OEMPolicyViolation.duplicateCommand }
        guard allowedTargets.contains(target) else { throw OEMPolicyViolation.targetNotAllowed }
        if let denied = dataIdentifiers.first(where: { deniedDataIdentifiers.contains($0) }) {
            throw OEMPolicyViolation.identifierDenied(denied)
        }
    }

    /// The wire form of one read: always `22` followed by four uppercase hex digits. This and the
    /// `0100` verification constant are the only places the OEM path produces a vehicle request.
    static func wireRequest(for dataIdentifier: UInt16) -> String {
        "22" + String(format: "%04X", dataIdentifier)
    }
}

public enum OEMPolicyViolation: Error, Equatable, Sendable {
    case emptyBatch
    case tooManyReads
    case duplicateCommand
    case mixedModules
    case commandNotInVehicle
    case targetNotAllowed
    case identifierDenied(UInt16)
}

/// Up to four reads from one module of one catalog vehicle, validated against the allowlist.
public struct OEMReadBatch: Sendable {
    public let vehicleID: String
    public let module: OEMCatalogModule
    public let commands: [OEMCatalogCommand]
    /// Clamped to `(0, OEMRequestPolicy.maximumBudget]`.
    public let budget: TimeInterval

    /// Commands must be 1...4, distinct, all in the same module of `vehicle`, and allowed by
    /// `OEMRequestPolicy`. Throws `OEMPolicyViolation` otherwise.
    public init(
        vehicle: OEMCatalogVehicle,
        commands: [OEMCatalogCommand],
        budget: TimeInterval = OEMRequestPolicy.maximumBudget
    ) throws {
        guard let first = commands.first else { throw OEMPolicyViolation.emptyBatch }
        guard commands.count <= OEMRequestPolicy.maximumReadsPerBatch else { throw OEMPolicyViolation.tooManyReads }
        guard Set(commands.map(\.id)).count == commands.count else { throw OEMPolicyViolation.duplicateCommand }
        guard commands.allSatisfy({ $0.moduleID == first.moduleID }) else { throw OEMPolicyViolation.mixedModules }
        // Only the vehicle's own, loader-checked definitions: a command that merely shares an id
        // with one of them isn't enough.
        guard commands.allSatisfy({ command in vehicle.commands.contains(command) }),
              let module = vehicle.module(id: first.moduleID)
        else {
            throw OEMPolicyViolation.commandNotInVehicle
        }
        try OEMRequestPolicy.validate(target: module.target, dataIdentifiers: commands.map(\.dataIdentifier))

        self.vehicleID = vehicle.id
        self.module = module
        self.commands = commands
        self.budget = Self.clampedBudget(budget)
    }

    static func clampedBudget(_ budget: TimeInterval) -> TimeInterval {
        // A non-positive (or NaN) budget still has to land inside (0, max]: it becomes a sliver too
        // small for any read, so the batch reports every read as out of budget without touching
        // the adapter.
        guard budget > 0 else { return 0.001 }
        return Swift.min(budget, OEMRequestPolicy.maximumBudget)
    }
}
