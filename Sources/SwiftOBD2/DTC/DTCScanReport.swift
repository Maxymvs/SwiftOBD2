//
//  DTCScanReport.swift
//  SwiftOBD2
//
//  The result of a completed DTC scan, the evidence carried out of an interrupted one,
//  and the typed errors that interrupt it.
//

import Foundation

// MARK: - Report

/// A completed DTC scan.
///
/// Built only through the validating initializer, which guarantees the report covers
/// every service its profile requires and nothing outside the profile — so the derived
/// clean/coverage answers can never be vacuously true over a short or empty map.
public struct DTCScanReport: Sendable, Equatable {
    /// Why can a report not be built?
    public enum ValidationError: Error, Sendable, Equatable {
        /// No service was attempted — a report must cover something.
        case noServices
        /// The profile requires this service and the map has no result for it.
        case missingRequiredService(DTCService)
        /// The map carries a result for a service this profile never requests.
        case serviceOutsideProfile(DTCService)
        /// An observation's lineage disagrees with the service that reported it.
        case observationKindMismatch(service: DTCService, observation: DTCObservation)
        /// An observation is attributed to an ECU other than the responder that sent it.
        case observationAddressMismatch(expected: ECUAddress, observation: DTCObservation)

        init(_ mismatch: DTCAttributionMismatch) {
            switch mismatch {
            case let .kind(service, observation):
                self = .observationKindMismatch(service: service, observation: observation)
            case let .address(expected, observation):
                self = .observationAddressMismatch(expected: expected, observation: observation)
            }
        }
    }

    /// The profile this scan requested.
    public let profile: DTCScanProfile
    /// Exactly the services attempted this scan. An absent key means "not requested".
    public let services: [DTCService: DTCServiceResult]
    /// The accompanying `0101` read; `.notAttempted` while the consumer reads it itself.
    public let statusRead: DTCStatusReadResult

    /// Validating initializer. Throws ``ValidationError`` for an empty service map, a
    /// missing profile-required service, a service outside the profile, or an observation
    /// misattributed to the wrong lineage or ECU.
    public init(
        profile: DTCScanProfile,
        services: [DTCService: DTCServiceResult],
        statusRead: DTCStatusReadResult = .notAttempted
    ) throws {
        guard !services.isEmpty else { throw ValidationError.noServices }
        let allowed = profile.allowedServices
        for service in DTCService.allCases where services[service] != nil {
            guard allowed.contains(service) else {
                throw ValidationError.serviceOutsideProfile(service)
            }
        }
        for service in DTCService.allCases where profile.requiredServices.contains(service) {
            guard services[service] != nil else {
                throw ValidationError.missingRequiredService(service)
            }
        }
        if let mismatch = firstAttributionMismatch(in: services) {
            throw ValidationError(mismatch)
        }
        self.profile = profile
        self.services = services
        self.statusRead = statusRead
    }

    /// Every observed code across all services and responders, in a deterministic order
    /// (stored → pending → permanent, then ascending ECU address).
    public var observations: [DTCObservation] {
        flattenObservations(services)
    }

    /// Whether the scan is clean *for what it asked*: every service present in the map
    /// answered, with every responder affirmatively reporting no codes.
    ///
    /// Derived over **attempted** services, not just required ones — an attempted optional
    /// service participates fully, so permanent codes can never hide inside a clean quick
    /// check. Required-service completeness is already the initializer's job.
    public var isCleanForProfile: Bool {
        services.values.allSatisfy(\.isClean)
    }

    /// Whether every attempted service actually obtained diagnostic data from every
    /// responder. Refusals (terminal or not) and malformed responders both break coverage.
    public var isCoverageComplete: Bool {
        services.values.allSatisfy(\.isCoverageComplete)
    }

    /// The advisory findings derived from this report's own evidence — never supplied.
    ///
    /// Three distinct notices in a deterministic order: the two per-ECU `0101` cross-check
    /// directions (D2) first, by ascending ECU address, then the salvage notices in service
    /// order. All three are **advisory** — a notice never suppresses a code, a service or a
    /// request — but they differ in consequence, which each case documents.
    ///
    /// The cross-check is strictly per ECU and only over *stored* codes (`0101` counts nothing
    /// else): a count difference *between* modules is normal and produces nothing at all.
    public var warnings: [DTCScanWarning] {
        deriveWarnings(services: services, statusRead: statusRead)
    }
}

// MARK: - Warnings

/// An advisory finding derived from a report's own evidence.
///
/// Advisory does not mean consequence-free: the three cases differ precisely in what they imply
/// for completeness, which is why they are separate values rather than one flat warning list.
public enum DTCScanWarning: Sendable, Hashable {
    /// This ECU's `0101` read reported stored codes, but that same ECU's Mode 03 answer was a
    /// verified-clean `.responded([])` — the codes the count promised were never recovered.
    ///
    /// **Consequence: incomplete.** The scan renders and persists as incomplete for that module
    /// rather than clean, and the result leaves the stored-code recurrence denominator.
    case storedCodeCoverageGap(ecuAddress: ECUAddress, reportedCount: UInt8)

    /// This ECU reported a `0101` count of zero yet answered Mode 03 with real codes.
    ///
    /// **Consequence: none — informational.** No evidence was lost, so completeness is unchanged
    /// and the codes are shown exactly as recovered. Common and legitimate: `0101` counts only
    /// confirmed, MIL-relevant emissions codes.
    case codesDespiteZeroCount(ecuAddress: ECUAddress, recoveredCount: Int)

    /// This responder's message was recorded as `.malformed` while other responders' valid
    /// messages were kept.
    ///
    /// **Consequence: user-visible.** Usually redundant with the coverage table — a malformed
    /// responder already breaks `isCoverageComplete` — but surfaced so the salvage is stated
    /// rather than implied: nothing was silently dropped.
    case salvagedResponder(ecuAddress: ECUAddress, service: DTCService)
}

// MARK: - Partial scan

/// Everything a scan completed before it was interrupted — the evidence carried by
/// ``DTCScanError`` so a mid-scan cancellation or disconnect cannot destroy real codes.
///
/// `services` may be empty (the interruption can precede any completed service), but it
/// can never claim a service the profile never requested.
public struct DTCPartialScan: Sendable, Equatable {
    /// Why can a partial scan not be built?
    public enum ValidationError: Error, Sendable, Equatable {
        /// The map carries a result for a service this profile never requests.
        case serviceOutsideProfile(DTCService)
        /// An observation's lineage disagrees with the service that reported it.
        case observationKindMismatch(service: DTCService, observation: DTCObservation)
        /// An observation is attributed to an ECU other than the responder that sent it.
        case observationAddressMismatch(expected: ECUAddress, observation: DTCObservation)

        init(_ mismatch: DTCAttributionMismatch) {
            switch mismatch {
            case let .kind(service, observation):
                self = .observationKindMismatch(service: service, observation: observation)
            case let .address(expected, observation):
                self = .observationAddressMismatch(expected: expected, observation: observation)
            }
        }
    }

    /// The profile the interrupted scan requested.
    public let profile: DTCScanProfile
    /// Services that completed before the interruption; possibly empty.
    public let services: [DTCService: DTCServiceResult]
    /// The `0101` read as of the interruption.
    public let statusRead: DTCStatusReadResult

    /// Validating initializer. Throws ``ValidationError`` when a result belongs to a
    /// service outside the profile, or when an observation is misattributed to the wrong
    /// lineage or ECU.
    public init(
        profile: DTCScanProfile,
        services: [DTCService: DTCServiceResult],
        statusRead: DTCStatusReadResult = .notAttempted
    ) throws {
        let allowed = profile.allowedServices
        for service in DTCService.allCases where services[service] != nil {
            guard allowed.contains(service) else {
                throw ValidationError.serviceOutsideProfile(service)
            }
        }
        if let mismatch = firstAttributionMismatch(in: services) {
            throw ValidationError(mismatch)
        }
        self.profile = profile
        self.services = services
        self.statusRead = statusRead
    }

    /// Observations salvaged from the completed services, in the same deterministic order
    /// a report uses. Consumers must render these rather than discarding them.
    public var observations: [DTCObservation] {
        flattenObservations(services)
    }

    /// The same advisory findings ``DTCScanReport/warnings`` derives, over the evidence
    /// that left the library inside a ``DTCScanError`` instead of a published report.
    ///
    /// Shared derivation, not a parallel one: a cancelled scan's coverage-gap and salvage
    /// evidence is exactly as real as a completed scan's (D3 forbids discarding it), so
    /// both types read the same rule rather than two copies that can drift apart.
    public var warnings: [DTCScanWarning] {
        deriveWarnings(services: services, statusRead: statusRead)
    }
}

// MARK: - Errors

/// The only errors the report API lets escape: terminal interruptions and capability
/// refusals. Recoverable, request-scoped failures are per-service outcomes instead.
public enum DTCScanError: Error, Sendable, Equatable {
    /// The scan task was cancelled; carries what had completed.
    case cancelled(DTCPartialScan)
    /// The link was lost before or during the scan; carries what had completed.
    case connectionLost(DTCPartialScan)
    /// The requested profile is not implemented — never a silently partial report.
    ///
    /// Every profile is implemented today (`.storedOnly`, `.quickConnect`, `.full`), so nothing
    /// raises this; the case stays so a future capability refusal has somewhere honest to go
    /// instead of degrading into a short report.
    case profileUnsupported(DTCScanProfile)
}

// MARK: - Shared validation

/// An observation whose attribution contradicts where it sits in a service map.
enum DTCAttributionMismatch: Sendable, Equatable {
    /// The observation's `kind` is not the containing service's lineage.
    case kind(service: DTCService, observation: DTCObservation)
    /// The observation's `ecuAddress` is not the responder key it sits under.
    case address(expected: ECUAddress, observation: DTCObservation)
}

/// The first misattributed observation in a service map, in the deterministic order the
/// flattening uses — so an observation can never be published under a lineage or ECU it
/// was not reported by.
private func firstAttributionMismatch(
    in services: [DTCService: DTCServiceResult]
) -> DTCAttributionMismatch? {
    for service in DTCService.allCases {
        guard let responders = services[service]?.responders else { continue }
        for address in responders.addresses {
            for observation in responders[address]?.codes ?? [] {
                guard observation.kind == service.kind else {
                    return .kind(service: service, observation: observation)
                }
                guard observation.ecuAddress == address else {
                    return .address(expected: address, observation: observation)
                }
            }
        }
    }
    return nil
}

// MARK: - Shared derivation

/// The one implementation of the D2/D17 advisory findings, shared by ``DTCScanReport``
/// and ``DTCPartialScan`` so a completed scan and an interrupted one can never disagree
/// about the same evidence.
///
/// Order is deterministic: the two per-ECU `0101` cross-check directions first, by
/// ascending ECU address, then the salvage notices in service order. The cross-check is
/// strictly per ECU and only over *stored* codes — `0101` counts nothing else — so a
/// count difference *between* modules produces nothing at all.
private func deriveWarnings(
    services: [DTCService: DTCServiceResult],
    statusRead: DTCStatusReadResult
) -> [DTCScanWarning] {
    var warnings: [DTCScanWarning] = []

    if case let .answered(statuses) = statusRead, let stored = services[.stored]?.responders {
        for address in statuses.addresses {
            guard let statusOutcome = statuses[address], let storedOutcome = stored[address],
                  case let .responded(status) = statusOutcome,
                  case let .responded(codes) = storedOutcome
            else { continue }
            if status.dtcCount > 0, codes.isEmpty {
                warnings.append(.storedCodeCoverageGap(ecuAddress: address, reportedCount: status.dtcCount))
            } else if status.dtcCount == 0, !codes.isEmpty {
                warnings.append(.codesDespiteZeroCount(ecuAddress: address, recoveredCount: codes.count))
            }
        }
    }

    for service in DTCService.allCases {
        guard let responders = services[service]?.responders else { continue }
        for address in responders.addresses where responders[address] == .malformed {
            warnings.append(.salvagedResponder(ecuAddress: address, service: service))
        }
    }

    return warnings
}

/// Flattens responder observations in a deterministic order: service lineage order first
/// (stored → pending → permanent), then ascending ECU address, then decode order.
private func flattenObservations(_ services: [DTCService: DTCServiceResult]) -> [DTCObservation] {
    var result: [DTCObservation] = []
    for service in DTCService.allCases {
        guard let responders = services[service]?.responders else { continue }
        for address in responders.addresses {
            result.append(contentsOf: responders[address]?.codes ?? [])
        }
    }
    return result
}
