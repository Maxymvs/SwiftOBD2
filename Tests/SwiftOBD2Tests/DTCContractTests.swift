//
//  DTCContractTests.swift
//
//  Phase 0 of the DTC scan reliability work: the contract types only — no scan behavior
//  exists yet. These tests pin the invariants the later phases rely on: contradictory
//  states are unconstructible, and clean/coverage are derived, never asserted.
//

@testable import SwiftOBD2
import XCTest

final class DTCContractTests: XCTestCase {
    // MARK: - Helpers

    private let engine = ECUAddress(raw: 0x7E8)
    private let transmission = ECUAddress(raw: 0x7E9)
    private let abs = ECUAddress(raw: 0x7EA)

    private func observation(
        _ code: String,
        _ kind: DTCKind = .stored,
        _ address: ECUAddress
    ) -> DTCObservation {
        DTCObservation(code: code, kind: kind, ecuAddress: address)
    }

    /// `.answered` around a single responder, force-unwrapped: a non-empty map always
    /// builds, and a nil here should fail the test loudly.
    private func answered(
        _ outcomes: [ECUAddress: DTCResponderOutcome],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DTCServiceResult {
        let responders = try XCTUnwrap(DTCResponders(outcomes), file: file, line: line)
        return .answered(responders)
    }

    private func cleanService(_ addresses: ECUAddress...) throws -> DTCServiceResult {
        var outcomes: [ECUAddress: DTCResponderOutcome] = [:]
        for address in addresses { outcomes[address] = .responded(codes: []) }
        return try answered(outcomes)
    }

    // MARK: - Validated non-empty responder maps

    func testRespondersRejectEmptyMap() {
        XCTAssertNil(DTCResponders([:]))
        XCTAssertNil(DTCStatusResponders([:]))
    }

    func testRespondersAcceptNonEmptyMap() throws {
        let responders = try XCTUnwrap(DTCResponders([engine: .responded(codes: [])]))
        XCTAssertEqual(responders.count, 1)
        XCTAssertEqual(responders[engine], .responded(codes: []))
        XCTAssertEqual(responders.addresses, [engine])

        let statuses = try XCTUnwrap(DTCStatusResponders([engine: .malformed]))
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses[engine], .malformed)
        XCTAssertEqual(statuses.addresses, [engine])
    }

    func testResponderAddressesAreSortedByRawAddress() throws {
        let responders = try XCTUnwrap(DTCResponders([
            abs: .malformed,
            engine: .responded(codes: []),
            transmission: .negativeResponse(.serviceNotSupported)
        ]))
        XCTAssertEqual(responders.addresses, [engine, transmission, abs])
    }

    // MARK: - Report factory validation

    func testReportRejectsEmptyServices() {
        XCTAssertThrowsError(try DTCScanReport(profile: .storedOnly, services: [:])) { error in
            XCTAssertEqual(error as? DTCScanReport.ValidationError, .noServices)
        }
    }

    func testReportRejectsMissingRequiredService() throws {
        let services: [DTCService: DTCServiceResult] = [
            .stored: try cleanService(engine),
            .permanent: try cleanService(engine)
        ]
        XCTAssertThrowsError(try DTCScanReport(profile: .full, services: services)) { error in
            XCTAssertEqual(error as? DTCScanReport.ValidationError, .missingRequiredService(.pending))
        }
    }

    func testReportRejectsServiceOutsideProfile() throws {
        let services: [DTCService: DTCServiceResult] = [
            .stored: try cleanService(engine),
            .pending: try cleanService(engine)
        ]
        XCTAssertThrowsError(try DTCScanReport(profile: .storedOnly, services: services)) { error in
            XCTAssertEqual(error as? DTCScanReport.ValidationError, .serviceOutsideProfile(.pending))
        }
    }

    func testQuickConnectValidWithAndWithoutPermanent() throws {
        let withoutPermanent = try DTCScanReport(profile: .quickConnect, services: [
            .stored: try cleanService(engine),
            .pending: try cleanService(engine)
        ])
        XCTAssertNil(withoutPermanent.services[.permanent])

        let withPermanent = try DTCScanReport(profile: .quickConnect, services: [
            .stored: try cleanService(engine),
            .pending: try cleanService(engine),
            .permanent: try cleanService(engine)
        ])
        XCTAssertEqual(withPermanent.services.count, 3)
    }

    func testStoredOnlyReportBuildsWithJustStored() throws {
        let report = try DTCScanReport(profile: .storedOnly, services: [.stored: try cleanService(engine)])
        XCTAssertEqual(report.statusRead, .notAttempted)
        XCTAssertTrue(report.isCleanForProfile)
        XCTAssertTrue(report.isCoverageComplete)
    }

    // MARK: - isCleanForProfile

    func testCleanWhenEveryServiceAnsweredEmptyAcrossEveryResponder() throws {
        let report = try DTCScanReport(profile: .full, services: [
            .stored: try cleanService(engine, transmission),
            .pending: try cleanService(engine),
            .permanent: try cleanService(engine)
        ])
        XCTAssertTrue(report.isCleanForProfile)
        XCTAssertTrue(report.isCoverageComplete)
        XCTAssertTrue(report.observations.isEmpty)
    }

    func testAttemptedOptionalPermanentCodesBreakQuickConnectClean() throws {
        let report = try DTCScanReport(profile: .quickConnect, services: [
            .stored: try cleanService(engine),
            .pending: try cleanService(engine),
            .permanent: try answered([engine: .responded(codes: [observation("P0420", .permanent, engine)])])
        ])
        XCTAssertFalse(report.isCleanForProfile, "permanent codes must not hide inside a clean quick check")
        XCTAssertTrue(report.isCoverageComplete, "codes are still full coverage")
    }

    func testCleanIsFalseForEveryNonRespondedOutcome() throws {
        let breakers: [DTCServiceResult] = [
            try answered([engine: .negativeResponse(.serviceNotSupported)]),
            try answered([engine: .negativeResponse(.busyRepeatRequest)]),
            try answered([engine: .malformed]),
            .noResponse,
            .invalidResponse,
            .transportFailure(.requestTimeout),
            .transportFailure(.adapterError)
        ]
        for breaker in breakers {
            let report = try DTCScanReport(profile: .storedOnly, services: [.stored: breaker])
            XCTAssertFalse(report.isCleanForProfile, "\(breaker) must never read as clean")
            XCTAssertFalse(report.isCoverageComplete, "\(breaker) must never read as complete coverage")
        }
    }

    func testOneDirtyResponderBreaksCleanWhileOthersStayIndividuallyClean() throws {
        let responders = try XCTUnwrap(DTCResponders([
            engine: .responded(codes: []),
            transmission: .responded(codes: [observation("P0700", .stored, transmission)])
        ]))
        let report = try DTCScanReport(profile: .storedOnly, services: [.stored: .answered(responders)])
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertTrue(report.isCoverageComplete)
        XCTAssertEqual(responders[engine]?.isClean, true)
    }

    // MARK: - isCoverageComplete

    func testCoverageIncompleteForAnyNegativeOrMalformedResponder() throws {
        let coverageBreakers: [DTCResponderOutcome] = [
            .negativeResponse(.serviceNotSupported),   // terminal
            .negativeResponse(.conditionsNotCorrect),  // terminal
            .negativeResponse(.busyRepeatRequest),     // non-terminal
            .negativeResponse(.responsePending),       // non-terminal
            .malformed
        ]
        for outcome in coverageBreakers {
            let service = try answered([engine: .responded(codes: []), abs: outcome])
            let report = try DTCScanReport(profile: .storedOnly, services: [.stored: service])
            XCTAssertFalse(report.isCoverageComplete, "\(outcome) must break coverage")
            XCTAssertFalse(report.isCleanForProfile, "\(outcome) must break clean")
        }
    }

    func testCoverageCompleteWhenAllRespondedEvenWithCodes() throws {
        let report = try DTCScanReport(profile: .full, services: [
            .stored: try answered([engine: .responded(codes: [observation("P0301", .stored, engine)])]),
            .pending: try cleanService(engine),
            .permanent: try cleanService(engine)
        ])
        XCTAssertTrue(report.isCoverageComplete)
        XCTAssertFalse(report.isCleanForProfile)
    }

    // MARK: - Request resolution (D17)

    func testIsRequestResolvedFollowsNRCDisposition() {
        for raw: UInt8 in [0x11, 0x12, 0x22, 0x31, 0x99] {
            let outcome = DTCResponderOutcome.negativeResponse(NegativeResponseCode(rawValue: raw))
            XCTAssertTrue(outcome.isRequestResolved, "NRC 0x\(String(raw, radix: 16)) must resolve the request")
            XCTAssertFalse(outcome.providesCoverage, "a refusal obtains no coverage")
        }
        for raw: UInt8 in [0x21, 0x78] {
            let outcome = DTCResponderOutcome.negativeResponse(NegativeResponseCode(rawValue: raw))
            XCTAssertFalse(outcome.isRequestResolved, "NRC 0x\(String(raw, radix: 16)) is an interim answer")
        }
        XCTAssertFalse(DTCResponderOutcome.malformed.isRequestResolved)
        XCTAssertTrue(DTCResponderOutcome.responded(codes: []).isRequestResolved)
        XCTAssertTrue(DTCResponderOutcome.responded(codes: [observation("P0420", .stored, engine)]).isRequestResolved)
    }

    func testNegativeResponseCodeClassification() {
        XCTAssertTrue(NegativeResponseCode.serviceNotSupported.derivesUnsupported)
        XCTAssertTrue(NegativeResponseCode.subFunctionNotSupported.derivesUnsupported)
        for raw: UInt8 in [0x21, 0x22, 0x31, 0x78, 0x00, 0x99, 0xFF] {
            XCTAssertFalse(
                NegativeResponseCode(rawValue: raw).derivesUnsupported,
                "only 0x11/0x12 may derive unsupported"
            )
        }
        XCTAssertTrue(NegativeResponseCode(rawValue: 0x11).isTerminal)
        XCTAssertTrue(NegativeResponseCode(rawValue: 0x12).isTerminal)
        XCTAssertTrue(NegativeResponseCode(rawValue: 0x22).isTerminal)
        XCTAssertTrue(NegativeResponseCode(rawValue: 0x31).isTerminal)
        XCTAssertTrue(NegativeResponseCode(rawValue: 0x99).isTerminal, "unknown NRCs are terminal")
        XCTAssertFalse(NegativeResponseCode(rawValue: 0x21).isTerminal)
        XCTAssertFalse(NegativeResponseCode(rawValue: 0x78).isTerminal)
        XCTAssertEqual(NegativeResponseCode(rawValue: 0x11).rawValue, 0x11, "the raw byte is preserved")
    }

    // MARK: - Partial scans (D16)

    func testPartialScanRejectsServiceOutsideProfile() throws {
        let services: [DTCService: DTCServiceResult] = [.pending: try cleanService(engine)]
        XCTAssertThrowsError(try DTCPartialScan(profile: .storedOnly, services: services)) { error in
            XCTAssertEqual(error as? DTCPartialScan.ValidationError, .serviceOutsideProfile(.pending))
        }
    }

    func testPartialScanAcceptsValidSubsetAndEmptyServices() throws {
        let subset = try DTCPartialScan(profile: .full, services: [.stored: try cleanService(engine)])
        XCTAssertEqual(subset.services.count, 1, "a partial scan need not cover required services")

        let interruptedEarly = try DTCPartialScan(profile: .full, services: [:])
        XCTAssertTrue(interruptedEarly.services.isEmpty)
        XCTAssertTrue(interruptedEarly.observations.isEmpty)
        XCTAssertEqual(interruptedEarly.statusRead, .notAttempted)
    }

    func testPartialScanCarriesItsObservationsThroughAnError() throws {
        let codes = [observation("P0104", .stored, engine)]
        let partial = try DTCPartialScan(
            profile: .full,
            services: [.stored: try answered([engine: .responded(codes: codes)])]
        )
        let error = DTCScanError.connectionLost(partial)
        guard case let .connectionLost(carried) = error else { return XCTFail("wrong case") }
        XCTAssertEqual(carried.observations, codes)
        XCTAssertEqual(error, .connectionLost(partial))
        XCTAssertNotEqual(error, .cancelled(partial))
        XCTAssertNotEqual(DTCScanError.profileUnsupported(.full), .profileUnsupported(.quickConnect))
    }

    // MARK: - Shared warning derivation (report ⇔ partial scan)

    /// The evidence a `.full` scan had collected when the link dropped: ECU A promised two
    /// stored codes and answered verified-clean (coverage gap), ECU B claimed none yet
    /// answered with a code (informational), and the ABS module's reply was unusable
    /// (salvage). An interrupted scan's evidence is as real as a completed scan's, so the
    /// partial must derive exactly the warnings a report over the same evidence would.
    private func crossCheckEvidence() throws -> (
        services: [DTCService: DTCServiceResult],
        statusRead: DTCStatusReadResult
    ) {
        var gapped = Status()
        gapped.dtcCount = 2
        let clean = Status()
        let statuses = try XCTUnwrap(DTCStatusResponders([
            engine: .responded(gapped),
            transmission: .responded(clean)
        ]))
        let services: [DTCService: DTCServiceResult] = [
            .stored: try answered([
                engine: .responded(codes: []),
                transmission: .responded(codes: [observation("P0104", .stored, transmission)]),
                abs: .malformed
            ])
        ]
        return (services, .answered(statuses))
    }

    func testPartialScanDerivesTheSameWarningsAReportWould() throws {
        let evidence = try crossCheckEvidence()
        let expected: [DTCScanWarning] = [
            .storedCodeCoverageGap(ecuAddress: engine, reportedCount: 2),
            .codesDespiteZeroCount(ecuAddress: transmission, recoveredCount: 1),
            .salvagedResponder(ecuAddress: abs, service: .stored)
        ]

        let partial = try DTCPartialScan(
            profile: .full,
            services: evidence.services,
            statusRead: evidence.statusRead
        )
        XCTAssertEqual(partial.warnings, expected)

        // The same evidence published as a report (storedOnly requires only Mode 03).
        let report = try DTCScanReport(
            profile: .storedOnly,
            services: evidence.services,
            statusRead: evidence.statusRead
        )
        XCTAssertEqual(report.warnings, partial.warnings, "one derivation, two carriers")
    }

    func testInterruptedScanCarriesItsWarningsThroughTheError() throws {
        let evidence = try crossCheckEvidence()
        let partial = try DTCPartialScan(
            profile: .full,
            services: evidence.services,
            statusRead: evidence.statusRead
        )
        guard case let .connectionLost(carried) = DTCScanError.connectionLost(partial) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(carried.warnings, partial.warnings)
        XCTAssertTrue(carried.warnings.contains(.storedCodeCoverageGap(ecuAddress: engine, reportedCount: 2)))
    }

    func testPartialScanWithoutStatusEvidenceDerivesNoCrossCheckWarnings() throws {
        let partial = try DTCPartialScan(profile: .full, services: [
            .stored: try answered([engine: .responded(codes: [])])
        ])
        XCTAssertTrue(partial.warnings.isEmpty, "no 0101 evidence means no cross-check")

        let empty = DTCPartialScan.empty(profile: .full)
        XCTAssertTrue(empty.warnings.isEmpty, "an interruption before any service warns about nothing")
    }

    func testPartialScanSalvageWarningsFollowServiceOrder() throws {
        let partial = try DTCPartialScan(profile: .full, services: [
            .pending: try answered([engine: .malformed]),
            .stored: try answered([transmission: .malformed, engine: .malformed])
        ])
        XCTAssertEqual(partial.warnings, [
            .salvagedResponder(ecuAddress: engine, service: .stored),
            .salvagedResponder(ecuAddress: transmission, service: .stored),
            .salvagedResponder(ecuAddress: engine, service: .pending)
        ])
    }

    // MARK: - Observation flattening

    func testObservationsFlattenAcrossServicesAndECUsPreservingKindAndAddress() throws {
        let storedEngine = observation("P0301", .stored, engine)
        let storedTransmission = observation("P0700", .stored, transmission)
        let pendingAbs = observation("C0035", .pending, abs)
        let permanentEngine = observation("P0420", .permanent, engine)

        let report = try DTCScanReport(profile: .full, services: [
            .stored: try answered([
                transmission: .responded(codes: [storedTransmission]),
                engine: .responded(codes: [storedEngine]),
                abs: .malformed
            ]),
            .pending: try answered([abs: .responded(codes: [pendingAbs])]),
            .permanent: try answered([engine: .responded(codes: [permanentEngine])])
        ])

        XCTAssertEqual(report.services.count, 3, "correctly attributed multi-ECU/multi-service maps build")
        XCTAssertEqual(
            report.observations,
            [storedEngine, storedTransmission, pendingAbs, permanentEngine],
            "stored → pending → permanent, then ascending ECU address"
        )
        XCTAssertEqual(report.observations.map(\.kind), [.stored, .stored, .pending, .permanent])
        XCTAssertEqual(report.observations.map(\.ecuAddress), [engine, transmission, abs, engine])
        XCTAssertFalse(report.isCoverageComplete, "the malformed responder is still represented")
    }

    func testNonRespondedServicesContributeNoObservations() throws {
        let report = try DTCScanReport(profile: .storedOnly, services: [.stored: .noResponse])
        XCTAssertTrue(report.observations.isEmpty)
        XCTAssertNil(report.services[.stored]?.responders)
    }

    // MARK: - Observation attribution

    func testReportRejectsObservationKindMismatch() throws {
        let misattributed = observation("P0420", .permanent, engine)
        let services: [DTCService: DTCServiceResult] = [
            .stored: try answered([engine: .responded(codes: [misattributed])])
        ]
        XCTAssertThrowsError(try DTCScanReport(profile: .storedOnly, services: services)) { error in
            XCTAssertEqual(
                error as? DTCScanReport.ValidationError,
                .observationKindMismatch(service: .stored, observation: misattributed)
            )
        }
    }

    func testReportRejectsObservationAddressMismatch() throws {
        let misattributed = observation("P0700", .stored, transmission)
        let services: [DTCService: DTCServiceResult] = [
            .stored: try answered([engine: .responded(codes: [misattributed])])
        ]
        XCTAssertThrowsError(try DTCScanReport(profile: .storedOnly, services: services)) { error in
            XCTAssertEqual(
                error as? DTCScanReport.ValidationError,
                .observationAddressMismatch(expected: engine, observation: misattributed)
            )
        }
    }

    func testPartialScanRejectsObservationKindMismatch() throws {
        let misattributed = observation("P0420", .permanent, engine)
        let services: [DTCService: DTCServiceResult] = [
            .stored: try answered([engine: .responded(codes: [misattributed])])
        ]
        XCTAssertThrowsError(try DTCPartialScan(profile: .full, services: services)) { error in
            XCTAssertEqual(
                error as? DTCPartialScan.ValidationError,
                .observationKindMismatch(service: .stored, observation: misattributed)
            )
        }
    }

    func testPartialScanRejectsObservationAddressMismatch() throws {
        let misattributed = observation("C0035", .pending, abs)
        let services: [DTCService: DTCServiceResult] = [
            .pending: try answered([engine: .responded(codes: [misattributed])])
        ]
        XCTAssertThrowsError(try DTCPartialScan(profile: .full, services: services)) { error in
            XCTAssertEqual(
                error as? DTCPartialScan.ValidationError,
                .observationAddressMismatch(expected: engine, observation: misattributed)
            )
        }
    }

    func testCorrectlyAttributedMultiECUPartialScanStillBuilds() throws {
        let storedEngine = observation("P0301", .stored, engine)
        let storedTransmission = observation("P0700", .stored, transmission)
        let pendingAbs = observation("C0035", .pending, abs)

        let partial = try DTCPartialScan(profile: .full, services: [
            .stored: try answered([
                engine: .responded(codes: [storedEngine]),
                transmission: .responded(codes: [storedTransmission]),
                abs: .negativeResponse(.serviceNotSupported)
            ]),
            .pending: try answered([abs: .responded(codes: [pendingAbs])])
        ])
        XCTAssertEqual(partial.observations, [storedEngine, storedTransmission, pendingAbs])
    }

    // MARK: - Status read

    func testStatusReadIsAdvisoryOnlyAndPreservesMixedResponders() throws {
        var status = Status()
        status.dtcCount = 2
        let statuses = try XCTUnwrap(DTCStatusResponders([
            engine: .responded(status),
            transmission: .negativeResponse(.serviceNotSupported),
            abs: .malformed
        ]))
        let report = try DTCScanReport(
            profile: .storedOnly,
            services: [.stored: try cleanService(engine)],
            statusRead: .answered(statuses)
        )
        XCTAssertTrue(report.isCleanForProfile, "the 0101 read never affects clean")
        XCTAssertTrue(report.isCoverageComplete, "the 0101 read never affects coverage")
        XCTAssertEqual(report.statusRead, .answered(statuses))
        XCTAssertEqual(statuses[engine], .responded(status))
        XCTAssertEqual(statuses[transmission], .negativeResponse(.serviceNotSupported))
    }

    // MARK: - Profiles

    func testProfileServiceSets() {
        XCTAssertEqual(DTCScanProfile.storedOnly.requiredServices, [.stored])
        XCTAssertEqual(DTCScanProfile.storedOnly.allowedServices, [.stored])
        XCTAssertEqual(DTCScanProfile.full.requiredServices, [.stored, .pending, .permanent])
        XCTAssertEqual(DTCScanProfile.full.allowedServices, DTCScanProfile.full.requiredServices)
        XCTAssertEqual(DTCScanProfile.quickConnect.requiredServices, [.stored, .pending])
        XCTAssertEqual(DTCScanProfile.quickConnect.allowedServices, [.stored, .pending, .permanent])
        for profile in DTCScanProfile.allCases {
            XCTAssertTrue(
                profile.requiredServices.isSubset(of: profile.allowedServices),
                "\(profile): required must be allowed"
            )
        }
    }

    func testServiceRequestAndResponseBytes() {
        XCTAssertEqual(DTCService.stored.requestMode, "03")
        XCTAssertEqual(DTCService.pending.requestMode, "07")
        XCTAssertEqual(DTCService.permanent.requestMode, "0A")
        XCTAssertEqual(DTCService.stored.positiveResponseByte, 0x43)
        XCTAssertEqual(DTCService.pending.positiveResponseByte, 0x47)
        XCTAssertEqual(DTCService.permanent.positiveResponseByte, 0x4A)
        XCTAssertEqual(DTCService.allCases.map(\.kind), [.stored, .pending, .permanent])
    }

    func testECUAddressHexDescription() {
        XCTAssertEqual(ECUAddress(raw: 0x7E8).description, "0x7E8")
        XCTAssertEqual(ECUAddress(raw: 0x18DAF110).description, "0x18DAF110")
        XCTAssertEqual(ECUAddress(raw: 0x7E8), ECUAddress(raw: 0x7E8))
        XCTAssertNotEqual(ECUAddress(raw: 0x7E8), ECUAddress(raw: 0x7E9))
    }

    // MARK: - Sendable (compile-time)

    /// Compiles only while every contract type — and the library's `Status` — is `Sendable`.
    func testContractTypesAreSendable() {
        requireSendable(Status.self)
        requireSendable(StatusTest.self)
        requireSendable(DTCService.self)
        requireSendable(DTCKind.self)
        requireSendable(ECUAddress.self)
        requireSendable(DTCObservation.self)
        requireSendable(NegativeResponseCode.self)
        requireSendable(DTCTransportFailure.self)
        requireSendable(DTCResponderOutcome.self)
        requireSendable(DTCResponders.self)
        requireSendable(DTCServiceResult.self)
        requireSendable(DTCStatusResponderOutcome.self)
        requireSendable(DTCStatusResponders.self)
        requireSendable(DTCStatusReadResult.self)
        requireSendable(DTCScanProfile.self)
        requireSendable(DTCScanReport.self)
        requireSendable(DTCPartialScan.self)
        requireSendable(DTCScanError.self)
    }
}

/// Compile-time assertion helper: the call site fails to build unless `T: Sendable`.
private func requireSendable<T: Sendable>(_: T.Type) {}
