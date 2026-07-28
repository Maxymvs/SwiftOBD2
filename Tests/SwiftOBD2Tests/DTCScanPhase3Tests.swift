//
//  DTCScanPhase3Tests.swift
//
//  Phase 3 gate of the DTC scan reliability work: services 07/0A, 29-bit ISO 15765-4, the NRC
//  dispositions (busy re-send, response-pending extra listen), the per-responder `0101` read
//  with its per-ECU cross-check, Mode 04 verification, and the mock's DTC scenarios.
//
//  Every fixture is the RFC's §6 "Phase 3 gate" list, one named test each.
//

import Combine
import CoreBluetooth
@testable import SwiftOBD2
import XCTest

final class DTCScanPhase3Tests: XCTestCase {
    // MARK: - Addresses

    private let engine = ECUAddress(raw: 0x7E8)
    private let transmission = ECUAddress(raw: 0x7E9)
    private let absECU = ECUAddress(raw: 0x7EA)
    private let bodyECU = ECUAddress(raw: 0x7EC)
    private let klineECU = ECUAddress(raw: 0x10)
    private let engine29 = ECUAddress(raw: 0x18DAF110)

    private enum FixtureFailure: Error {
        case notAnswered
    }

    // MARK: - Helpers

    private func parse(_ lines: [String], _ service: DTCService, _ family: DTCProtocolFamily = .can11) -> DTCServiceResult {
        DTCResponseParser.parse(lines: lines, service: service, family: family)
    }

    private func responders(
        _ result: DTCServiceResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DTCResponders {
        guard case let .answered(responders) = result else {
            XCTFail("Expected .answered, got \(result)", file: file, line: line)
            throw FixtureFailure.notAnswered
        }
        return responders
    }

    private func outcome(
        _ result: DTCServiceResult,
        _ address: ECUAddress,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DTCResponderOutcome {
        let responders = try responders(result, file: file, line: line)
        return try XCTUnwrap(responders[address], "No outcome for \(address)", file: file, line: line)
    }

    private func codes(_ outcome: DTCResponderOutcome) -> [String] {
        outcome.codes.map(\.code)
    }

    private func statusResponders(
        _ result: DTCStatusReadResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DTCStatusResponders {
        guard case let .answered(responders) = result else {
            XCTFail("Expected .answered status read, got \(result)", file: file, line: line)
            throw FixtureFailure.notAnswered
        }
        return responders
    }

    private func makeELM327(
        comm: CommProtocol,
        canProtocol: CANProtocol = ISO_15765_4_11bit_500k(),
        linkState: ConnectionState = .connectedToVehicle
    ) -> ELM327 {
        let sut = ELM327(comm: comm)
        sut.canProtocol = canProtocol
        sut.connectionState = linkState
        return sut
    }

    /// The demo transport, with its published connection state primed *before* the ELM327
    /// subscribes — `@Published` replays its current value on subscription, which would
    /// otherwise overwrite the link state the test just set.
    private func makeMock(scenario: MockDTCScenario) -> MOCKComm {
        let comm = MOCKComm()
        comm.connectionState = .connectedToVehicle
        comm.ecuSettings.dtcScenario = scenario
        return comm
    }

    /// A clean `0101` answer from the engine — the advisory read that now accompanies every scan.
    private static let cleanStatusLines = ["7E8 06 41 01 00 07 E1 00"]

    // MARK: - Services 07 and 0A

    /// Multi-frame ISO-TP with more than two codes, extended from 03 to 07 (§6 Phase 1 fixture
    /// carried forward): the canonical byte contract is per-family, not per-service.
    func testPendingMultiFrameISOTPDecodesEveryCode() throws {
        let result = parse([
            "7E8 10 08 47 03 01 04 05",
            "7E8 21 00 01 15 00 00 00",
        ], .pending)

        let outcome = try outcome(result, engine)
        XCTAssertEqual(codes(outcome), ["P0104", "P0500", "P0115"])
        XCTAssertTrue(outcome.codes.allSatisfy { $0.kind == .pending })
    }

    func testPendingPositiveShapeYieldsPendingObservations() throws {
        let result = parse(["7E8 04 47 01 01 04"], .pending)

        let outcome = try outcome(result, engine)
        XCTAssertEqual(codes(outcome), ["P0104"])
        XCTAssertEqual(outcome.codes.first?.kind, .pending)
    }

    func testPermanentPositiveShapeYieldsPermanentObservations() throws {
        let result = parse(["7E8 04 4A 01 04 20"], .permanent)

        let outcome = try outcome(result, engine)
        XCTAssertEqual(codes(outcome), ["P0420"])
        XCTAssertEqual(outcome.codes.first?.kind, .permanent)
    }

    func testPendingAndPermanentCleanShapesAreVerifiedClean() throws {
        XCTAssertEqual(try outcome(parse(["7E8 02 47 00"], .pending), engine), .responded(codes: []))
        XCTAssertEqual(try outcome(parse(["7E8 02 4A 00"], .permanent), engine), .responded(codes: []))
    }

    /// A `47` mode byte does not satisfy an 03 request (and vice versa): only a *verified*
    /// positive byte for the in-flight service can read as clean.
    func testPositiveByteMustMatchTheInFlightService() throws {
        XCTAssertEqual(try outcome(parse(["7E8 02 47 00"], .stored), engine), .malformed)
        XCTAssertEqual(try outcome(parse(["7E8 02 43 00"], .permanent), engine), .malformed)
    }

    /// The legacy prepend used to special-case `0x43` only, so a K-line `47` was misaligned.
    /// The report path canonicalises `47` the same way — real codes, no spurious leading code.
    func testKLinePendingResponseDecodesItsRealCodesOnly() throws {
        let result = parse(["48 6B 10 47 15 53 13 28 00 00 70"], .pending, .legacy)

        let outcome = try outcome(result, klineECU)
        XCTAssertEqual(codes(outcome), ["P1553", "P1328"])
        XCTAssertTrue(outcome.codes.allSatisfy { $0.kind == .pending })
    }

    func testKLinePendingResponseMergesMultipleLinesWithoutASpuriousCode() throws {
        let result = parse([
            "48 6B 10 47 15 53 13 28 00 00 70",
            "48 6B 10 47 01 04 00 00 00 00 70",
        ], .pending, .legacy)

        XCTAssertEqual(codes(try outcome(result, klineECU)), ["P1553", "P1328", "P0104"])
    }

    /// Per-message tolerance is service-generic: one responder's damaged `47` must not hide
    /// another responder's real pending codes, and the count-byte rule still applies.
    func testPendingToleratesDamagePerResponder() throws {
        let result = parse([
            "7E8 06 47 02 01 04 05 00",
            "7E9 07 47 01 04", // declares 7 application bytes, sends 3
            "7EA 04 47 01 00 00", // count claims 1, decodes none
        ], .pending)

        let responders = try responders(result)
        XCTAssertEqual(responders.count, 3)
        XCTAssertEqual(codes(try outcome(result, engine)), ["P0104", "P0500"])
        XCTAssertEqual(try outcome(result, transmission), .malformed)
        XCTAssertEqual(try outcome(result, absECU), .malformed)
    }

    // MARK: - Profiles

    func testFullProfileRequestsEveryServiceInOrder() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 04 43 01 01 04"]],
            "07": [["7E8 02 47 00"]],
            "0A": [["7E8 02 4A 00"]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .full)

        XCTAssertEqual(comm.sentCommands, ["0101", "03", "07", "0A"])
        XCTAssertEqual(report.profile, .full)
        XCTAssertEqual(report.services.count, 3)
        XCTAssertEqual(report.observations.map(\.code), ["P0104"])
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertTrue(report.isCoverageComplete)
    }

    func testFullProfileCleanAcrossEveryServiceReadsAsClean() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 02 43 00"]],
            "07": [["7E8 02 47 00"]],
            "0A": [["7E8 02 4A 00"]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .full)

        XCTAssertTrue(report.isCleanForProfile)
        XCTAssertTrue(report.isCoverageComplete)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    /// `quickConnect` stops at 07 — RFC §7 Q1 resolved that 0A never joins on any cadence,
    /// and an unrequested service is simply absent from the map.
    func testQuickConnectProfileOmitsPermanentCodes() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 02 43 00"]],
            "07": [["7E8 02 47 00"]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .quickConnect)

        XCTAssertEqual(comm.sentCommands, ["0101", "03", "07"])
        XCTAssertNil(report.services[.permanent])
        XCTAssertTrue(report.isCleanForProfile)
    }

    /// A permanent-code refusal is a definitive answer with no coverage: fully resolved, never
    /// clean, and never persisted as a complete scan.
    func testRefusedPermanentServiceResolvesWithoutCoverage() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 02 43 00"]],
            "07": [["7E8 02 47 00"]],
            "0A": [["7E8 03 7F 0A 11"]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .full)

        let permanent = try XCTUnwrap(report.services[.permanent])
        XCTAssertEqual(try outcome(permanent, engine), .negativeResponse(.serviceNotSupported))
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertFalse(report.isCoverageComplete)
    }

    // MARK: - Mixed-responder broadcast (all four outcomes)

    /// §6: clean 0x7E8 + codes 0x7E9 + `7F 03 11` on 0x7EA + one addressable-damaged message →
    /// all four outcomes present, the valid messages salvaged, the scan incomplete overall, and
    /// the engine still individually clean.
    func testMixedResponderBroadcastKeepsAllFourOutcomes() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [[
                "7E8 02 43 00",
                "7E9 06 43 02 01 04 05 00",
                "7EA 03 7F 03 11",
                "7EC 07 43 01 04", // declares 7 application bytes, sends 3
            ]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)
        let stored = try XCTUnwrap(report.services[.stored])
        let responders = try responders(stored)

        XCTAssertEqual(responders.count, 4)
        XCTAssertEqual(responders[engine], .responded(codes: []))
        XCTAssertEqual(codes(try outcome(stored, transmission)), ["P0104", "P0500"])
        XCTAssertEqual(try outcome(stored, absECU), .negativeResponse(.serviceNotSupported))
        XCTAssertEqual(try outcome(stored, bodyECU), .malformed)

        // The engine is individually clean while the scan as a whole is not.
        XCTAssertTrue(try outcome(stored, engine).isClean)
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertFalse(report.isCoverageComplete)
        // Salvage: the valid responders' codes survive the damaged message, and the salvage is
        // stated rather than implied.
        XCTAssertEqual(report.observations.map(\.code), ["P0104", "P0500"])
        XCTAssertEqual(report.warnings, [.salvagedResponder(ecuAddress: bodyECU, service: .stored)])
    }

    // MARK: - `0101` in the report

    func testStatusReadPreservesEveryResponder() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [[
                "7E8 06 41 01 82 34 56 78",
                "7E9 06 41 01 00 34 56 78",
            ]],
            "03": [["7E8 02 43 00", "7E9 02 43 00"]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)
        let statuses = try statusResponders(report.statusRead)

        XCTAssertEqual(statuses.count, 2)
        guard case let .responded(engineStatus) = try XCTUnwrap(statuses[engine]),
              case let .responded(transmissionStatus) = try XCTUnwrap(statuses[transmission])
        else { return XCTFail("Both responders must carry a decoded status") }
        XCTAssertEqual(engineStatus.dtcCount, 2)
        XCTAssertTrue(engineStatus.MIL)
        XCTAssertEqual(transmissionStatus.dtcCount, 0)
        XCTAssertFalse(transmissionStatus.MIL)
    }

    /// §6: ECU A promises 2 codes but its own Mode 03 is verified clean → a coverage-gap warning
    /// **for A specifically**. ECU B reports 0 codes yet has codes → no warning, codes shown.
    /// A count difference *between* the two ECUs produces nothing by itself.
    func testPerECUStatusCrossCheckWarnsOnlyForTheGappedECU() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [[
                "7E8 06 41 01 82 34 56 78", // ECU A: MIL, 2 stored codes claimed
                "7E9 06 41 01 00 34 56 78", // ECU B: no MIL, 0 codes claimed
            ]],
            "03": [[
                "7E8 02 43 00", // ECU A answers verified-clean — the promised codes never came
                "7E9 04 43 01 01 04", // ECU B answers with a code despite claiming none
            ]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(report.warnings, [
            // A: the count promised codes that never came → renders incomplete.
            .storedCodeCoverageGap(ecuAddress: engine, reportedCount: 2),
            // B: codes recovered despite a zero count → informational, completeness unchanged.
            .codesDespiteZeroCount(ecuAddress: transmission, recoveredCount: 1),
        ])
        // B's codes are shown, not suppressed.
        XCTAssertEqual(codes(try outcome(try XCTUnwrap(report.services[.stored]), transmission)), ["P0104"])
    }

    func testStatusCountDifferencesBetweenECUsAloneProduceNoWarning() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [[
                "7E8 06 41 01 82 34 56 78", // 2 codes claimed
                "7E9 06 41 01 00 34 56 78", // 0 codes claimed
            ]],
            "03": [[
                "7E8 06 43 02 01 04 05 00", // and 2 codes delivered
                "7E9 02 43 00",
            ]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testStatusReadPreservesARefusalAlongsideAValidStatus() throws {
        let result = DTCResponseParser.parseStatus(
            lines: ["7E8 06 41 01 00 07 E1 00", "7E9 03 7F 01 12"],
            family: .can11
        )
        let statuses = try statusResponders(result)

        XCTAssertEqual(statuses.count, 2)
        XCTAssertEqual(statuses[transmission], .negativeResponse(.subFunctionNotSupported))
        guard case .responded = try XCTUnwrap(statuses[engine]) else {
            return XCTFail("The valid status must survive alongside the refusal")
        }
    }

    func testStatusReadDistinguishesSilenceDamageAndNoise() {
        XCTAssertEqual(DTCResponseParser.parseStatus(lines: ["NO DATA"], family: .can11), .noResponse)
        XCTAssertEqual(DTCResponseParser.parseStatus(lines: [], family: .can11), .noResponse)
        // Bytes arrived with no recoverable address.
        XCTAssertEqual(DTCResponseParser.parseStatus(lines: ["41", "0"], family: .can11), .invalidResponse)
        // A `7F` echoing another service is noise, not a refusal of the status read.
        XCTAssertEqual(DTCResponseParser.parseStatus(lines: ["7E8 03 7F 03 11"], family: .can11), .invalidResponse)
        // A truncated positive is damage, never a decoded status.
        let damaged = DTCResponseParser.parseStatus(lines: ["7E8 02 41 01"], family: .can11)
        XCTAssertEqual(damaged, .answered(DTCStatusResponders([ECUAddress(raw: 0x7E8): .malformed])!))
    }

    /// A failed status read is advisory: it never fails the scan (D17).
    func testFailedStatusReadNeverFailsTheScan() async throws {
        let comm = ScriptedComm(
            responses: ["03": [["7E8 04 43 01 01 04"]]],
            errors: ["0101": BLEManagerError.sendMessageTimeout]
        )
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(report.statusRead, .transportFailure(.requestTimeout))
        XCTAssertEqual(report.observations.map(\.code), ["P0104"])
        XCTAssertTrue(report.warnings.isEmpty, "No status evidence means no cross-check")
    }

    func testSilentStatusReadIsRecordedAsNoResponse() async throws {
        let comm = ScriptedComm(
            responses: ["03": [["7E8 02 43 00"]]],
            errors: ["0101": BLEManagerError.noData]
        )
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(report.statusRead, .noResponse)
        XCTAssertTrue(report.isCleanForProfile, "The status read never decides cleanliness")
    }

    // MARK: - NRC dispositions (D15)

    /// §6: `7F 03 21` → re-sent up to the cap (2 extra, 3 total), then the **last NRC** is the
    /// recorded evidence — never converted to clean or to silence.
    func testBusyNegativeResponseIsResentUpToTheCap() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 03 7F 03 21"]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 3)
        let stored = try XCTUnwrap(report.services[.stored])
        XCTAssertEqual(try outcome(stored, engine), .negativeResponse(.busyRepeatRequest))
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertFalse(report.isCoverageComplete)
    }

    func testBusyNegativeResponseStopsResendingOnceTheECUAnswers() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 03 7F 03 21"], ["7E8 04 43 01 01 04"]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 2)
        XCTAssertEqual(report.observations.map(\.code), ["P0104"])
    }

    /// A terminal refusal is never re-sent: re-sending cannot change a definitive answer.
    func testTerminalNegativeResponseIsNotResent() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 03 7F 03 11"]],
        ])
        let sut = makeELM327(comm: comm)

        _ = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 1)
    }

    // MARK: - Evidence lattice (pure)

    private func observation(_ code: String, _ address: ECUAddress? = nil) -> DTCObservation {
        DTCObservation(code: code, kind: .stored, ecuAddress: address ?? engine)
    }

    private func mergedCodes(
        _ previous: DTCResponderOutcome?,
        _ latest: DTCResponderOutcome
    ) -> DTCResponderOutcome {
        DTCResponderOutcome.merging(previous: previous, latest: latest)
    }

    /// Verified codes are sticky: nothing a later attempt says may take them away.
    func testLatticeNeverDowngradesVerifiedCodes() {
        let codes = DTCResponderOutcome.responded(codes: [observation("P0104")])

        XCTAssertEqual(mergedCodes(codes, .responded(codes: [])), codes, "A later clean cannot erase codes")
        XCTAssertEqual(mergedCodes(codes, .negativeResponse(.busyRepeatRequest)), codes)
        XCTAssertEqual(mergedCodes(codes, .negativeResponse(.serviceNotSupported)), codes)
        XCTAssertEqual(mergedCodes(codes, .malformed), codes)
    }

    /// Later codes are added, deduplicated by code and order-stable.
    func testLatticeUnionsCodesAcrossAttempts() {
        let first = DTCResponderOutcome.responded(codes: [observation("P0104"), observation("P0500")])
        let second = DTCResponderOutcome.responded(codes: [observation("P0500"), observation("P0420")])

        XCTAssertEqual(
            mergedCodes(first, second).codes.map(\.code),
            ["P0104", "P0500", "P0420"]
        )
    }

    /// Verified clean is sticky against noise, but upgraded by codes.
    func testLatticeTreatsVerifiedCleanAsAnAnswer() {
        let clean = DTCResponderOutcome.responded(codes: [])

        XCTAssertEqual(mergedCodes(clean, .negativeResponse(.busyRepeatRequest)), clean)
        XCTAssertEqual(mergedCodes(clean, .malformed), clean)
        XCTAssertEqual(mergedCodes(clean, .negativeResponse(.serviceNotSupported)), clean)
        XCTAssertEqual(
            mergedCodes(clean, .responded(codes: [observation("P0104")])).codes.map(\.code),
            ["P0104"]
        )
    }

    /// Busy is the weakest evidence there is — anything non-busy replaces it.
    func testLatticeUpgradesBusyToAnythingElse() {
        let busy = DTCResponderOutcome.negativeResponse(.busyRepeatRequest)

        XCTAssertEqual(mergedCodes(busy, .responded(codes: [])), .responded(codes: []))
        XCTAssertEqual(mergedCodes(busy, .malformed), .malformed)
        XCTAssertEqual(
            mergedCodes(busy, .negativeResponse(.serviceNotSupported)),
            .negativeResponse(.serviceNotSupported)
        )
        // Still busy on the newest attempt: the last NRC is the recorded evidence.
        XCTAssertEqual(mergedCodes(busy, .negativeResponse(.responsePending)), .negativeResponse(.responsePending))
    }

    /// Damage is repaired by a verified answer from a fresh exchange, and only by that.
    func testLatticeRepairsMalformedOnlyWithAVerifiedAnswer() {
        XCTAssertEqual(
            mergedCodes(.malformed, .responded(codes: [observation("P0104")])).codes.map(\.code),
            ["P0104"]
        )
        XCTAssertEqual(
            mergedCodes(.malformed, .negativeResponse(.serviceNotSupported)),
            .negativeResponse(.serviceNotSupported)
        )
        XCTAssertEqual(mergedCodes(.malformed, .negativeResponse(.busyRepeatRequest)), .malformed)
        XCTAssertEqual(mergedCodes(.malformed, .malformed), .malformed)
    }

    /// A terminal refusal followed by codes yields the codes: a new exchange is new evidence.
    func testLatticePrefersCodesOverAnEarlierTerminalRefusal() {
        XCTAssertEqual(
            mergedCodes(.negativeResponse(.serviceNotSupported), .responded(codes: [observation("P0104")]))
                .codes.map(\.code),
            ["P0104"]
        )
        // Two terminal refusals: the newest NRC is what was observed.
        XCTAssertEqual(
            mergedCodes(.negativeResponse(.serviceNotSupported), .negativeResponse(.conditionsNotCorrect)),
            .negativeResponse(.conditionsNotCorrect)
        )
    }

    func testLatticePassesThroughAFirstAppearance() {
        XCTAssertEqual(mergedCodes(nil, .malformed), .malformed)
        XCTAssertEqual(mergedCodes(nil, .responded(codes: [])), .responded(codes: []))
    }

    /// The reviewer's conflicting-repeat fixture, end to end: A reports a code then answers clean
    /// on the re-send while B goes from busy to codes. A must keep P0104; B must gain P0420.
    func testConflictingRepeatKeepsEveryVerifiedCode() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [
                ["7E8 04 43 01 01 04", "7E9 03 7F 03 21"], // A: P0104, B: busy
                ["7E8 02 43 00", "7E9 04 43 01 04 20"], // A: clean (!), B: P0420
            ],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        let stored = try XCTUnwrap(report.services[.stored])
        XCTAssertEqual(codes(try outcome(stored, engine)), ["P0104"], "A's verified code must survive")
        XCTAssertEqual(codes(try outcome(stored, transmission)), ["P0420"])
        XCTAssertEqual(report.observations.map(\.code), ["P0104", "P0420"])
        XCTAssertFalse(report.isCleanForProfile)
    }

    /// Merging, not replacing: ECU A answered with codes on the first attempt and is absent from
    /// the retry buffer, so its codes must still be in the result alongside B's final answer.
    func testBusyRetryMergesEvidencePerResponder() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [
                ["7E8 06 43 02 01 04 05 00", "7E9 03 7F 03 21"], // A: codes, B: busy
                ["7E9 04 43 01 04 20"], // the re-send is answered by B alone
            ],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 2)
        let stored = try XCTUnwrap(report.services[.stored])
        let responders = try responders(stored)
        XCTAssertEqual(responders.count, 2, "A must not vanish because the retry buffer omitted it")
        XCTAssertEqual(codes(try outcome(stored, engine)), ["P0104", "P0500"])
        XCTAssertEqual(codes(try outcome(stored, transmission)), ["P0420"])
        XCTAssertEqual(report.observations.map(\.code), ["P0104", "P0500", "P0420"])
    }

    /// Another responder's damage must not veto a busy ECU's second chance — and the damaged
    /// responder keeps its own outcome.
    func testBusyResponderIsRetriedDespiteAnotherResponderBeingMalformed() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [
                ["7E8 07 43 01 04", "7E9 03 7F 03 21"], // A: damaged, B: busy
                ["7E9 04 43 01 01 04"],
            ],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 2, "Damage elsewhere must not veto the retry")
        let stored = try XCTUnwrap(report.services[.stored])
        XCTAssertEqual(try outcome(stored, engine), .malformed)
        XCTAssertEqual(codes(try outcome(stored, transmission)), ["P0104"])
        XCTAssertFalse(report.isCoverageComplete)
    }

    /// A terminal refusal elsewhere likewise does not veto the retry.
    func testBusyResponderIsRetriedDespiteAnotherResponderRefusing() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [
                ["7EA 03 7F 03 11", "7E9 03 7F 03 21"],
                ["7E9 02 43 00"],
            ],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 2)
        let stored = try XCTUnwrap(report.services[.stored])
        XCTAssertEqual(try outcome(stored, absECU), .negativeResponse(.serviceNotSupported))
        XCTAssertEqual(try outcome(stored, transmission), .responded(codes: []))
    }

    /// Exhaustion: B stays busy through every attempt, so its last NRC is the recorded evidence —
    /// and A's codes from the first attempt are still intact.
    func testBusyThroughExhaustionKeepsTheOtherRespondersEvidence() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [
                ["7E8 04 43 01 01 04", "7E9 03 7F 03 21"],
                ["7E9 03 7F 03 21"],
                ["7E9 03 7F 03 21"],
            ],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 3)
        let stored = try XCTUnwrap(report.services[.stored])
        XCTAssertEqual(codes(try outcome(stored, engine)), ["P0104"])
        XCTAssertEqual(try outcome(stored, transmission), .negativeResponse(.busyRepeatRequest))
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertFalse(report.isCoverageComplete)
    }

    /// A re-send that comes back silent (or unusable) must not erase what the first attempt
    /// proved: the accumulated evidence is returned, busy NRC included.
    func testSilentRetryDoesNotEraseAccumulatedEvidence() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [
                ["7E8 04 43 01 01 04", "7E9 03 7F 03 21"],
                ["NO DATA"],
            ],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        let stored = try XCTUnwrap(report.services[.stored])
        XCTAssertEqual(codes(try outcome(stored, engine)), ["P0104"])
        XCTAssertEqual(try outcome(stored, transmission), .negativeResponse(.busyRepeatRequest))
    }

    /// §6: `7F 03 78` followed by the final message **after** the initial buffered read →
    /// `.responded`, obtained by listening again rather than retransmitting.
    func testResponsePendingWaitsForTheFinalMessageWithoutRetransmitting() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 03 7F 03 78"]],
        ])
        comm.additionalResponses = [["7E8 04 43 01 01 04"]]
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 1, "A 0x78 is never retransmitted")
        XCTAssertEqual(comm.additionalListens, 1)
        let stored = try XCTUnwrap(report.services[.stored])
        XCTAssertEqual(codes(try outcome(stored, engine)), ["P0104"])
    }

    /// Nothing more arrives (or the transport cannot re-listen): the `0x78` stays the recorded
    /// evidence — never upgraded to clean, never turned into silence.
    func testResponsePendingWithoutAFinalMessageKeepsTheNRCAsEvidence() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 03 7F 03 78"]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 1)
        XCTAssertEqual(comm.additionalListens, 1)
        let stored = try XCTUnwrap(report.services[.stored])
        XCTAssertEqual(try outcome(stored, engine), .negativeResponse(.responsePending))
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertFalse(report.isCoverageComplete)
    }

    /// The wait is a *lifecycle*, not one read: the ECU may keep saying `78` for several
    /// windows before its real answer lands, and none of them may provoke a retransmit.
    func testResponsePendingKeepsListeningAcrossMultipleWindows() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 03 7F 03 78"]],
        ])
        comm.additionalResponses = [
            ["7E8 03 7F 03 78"],
            ["7E8 03 7F 03 78"],
            ["7E8 06 43 02 01 04 05 00"],
        ]
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 1, "Still exactly one send")
        XCTAssertEqual(comm.additionalListens, 3)
        XCTAssertEqual(report.observations.map(\.code), ["P0104", "P0500"])
    }

    /// The windows are bounded: when the budget runs out with the exchange still pending, the
    /// recorded evidence is the last `0x78` — the attempt concluded, the exchange never resolved.
    func testResponsePendingStopsAtTheListenBudget() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 03 7F 03 78"]],
        ])
        comm.additionalResponses = [["7E8 03 7F 03 78"]]
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 1)
        XCTAssertEqual(comm.additionalListens, 2, "One window delivered another 78, the next came back empty")
        let stored = try XCTUnwrap(report.services[.stored])
        XCTAssertEqual(try outcome(stored, engine), .negativeResponse(.responsePending))
    }

    /// An interruption during a listen window is terminal, not "the ECU went quiet": the scan
    /// must throw rather than publish a report resting on the interim `0x78`.
    func testCancellationDuringAListenWindowThrowsInsteadOfPublishing() async {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 03 7F 03 78"]],
        ])
        comm.continuationError = (window: 1, error: CancellationError())
        let sut = makeELM327(comm: comm)

        do {
            let report = try await sut.scanForTroubleCodes(profile: .storedOnly)
            XCTFail("Expected .cancelled, got a published report: \(report)")
        } catch let error as DTCScanError {
            guard case let .cancelled(partial) = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
            XCTAssertTrue(partial.services.isEmpty, "Mode 03 never resolved")
            guard case .answered = partial.statusRead else {
                return XCTFail("The status read so far must travel with the evidence")
            }
        } catch {
            XCTFail("Expected DTCScanError, got \(error)")
        }
    }

    /// Link loss during a listen window is the same story with the other terminal case.
    func testLinkLossDuringAListenWindowThrowsConnectionLost() async {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 03 7F 03 78"]],
        ])
        comm.continuationError = (window: 1, error: BLEManagerError.peripheralNotConnected)
        let sut = makeELM327(comm: comm)

        do {
            _ = try await sut.scanForTroubleCodes(profile: .storedOnly)
            XCTFail("Expected .connectionLost")
        } catch let error as DTCScanError {
            guard case .connectionLost = error else {
                return XCTFail("Expected .connectionLost, got \(error)")
            }
        } catch {
            XCTFail("Expected DTCScanError, got \(error)")
        }
    }

    /// The common case needs no extra window at all: the ELM327 extends its own timeout on
    /// `7F xx 78`, so the final message usually lands in the same buffered read.
    func testResponsePendingSupersededInTheSameBufferNeedsNoExtraListen() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 03 7F 03 78", "7E8 04 43 01 01 04"]],
        ])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.additionalListens, 0)
        XCTAssertEqual(report.observations.map(\.code), ["P0104"])
    }

    /// §6: a `7F` echoing another service during an 03 request is noise — never a negative
    /// response for 03, and never advisory-cache input.
    func testMismatchedServiceEchoStaysNoiseAndNeverCaches() async throws {
        let store = InMemoryDTCUnsupportedServiceStore()
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 03 7F 07 31"]],
        ])
        let sut = makeELM327(comm: comm)
        sut.unsupportedServiceStore = store

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(report.services[.stored], .invalidResponse)
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertTrue(store.unsupportedKeys.isEmpty)
    }

    // MARK: - Transport retries

    func testRecoverableFailureIsRetriedThreeTimesThenRecorded() async throws {
        let comm = ScriptedComm(
            responses: ["0101": [Self.cleanStatusLines]],
            errors: ["03": BLEManagerError.sendMessageTimeout]
        )
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 3)
        XCTAssertEqual(report.services[.stored], .transportFailure(.requestTimeout))
    }

    func testTerminalFailureIsNotRetried() async {
        let comm = ScriptedComm(
            responses: ["0101": [Self.cleanStatusLines]],
            errors: ["03": BLEManagerError.peripheralNotConnected]
        )
        let sut = makeELM327(comm: comm)

        do {
            _ = try await sut.scanForTroubleCodes(profile: .storedOnly)
            XCTFail("Expected .connectionLost")
        } catch let error as DTCScanError {
            guard case .connectionLost = error else {
                return XCTFail("Expected .connectionLost, got \(error)")
            }
        } catch {
            XCTFail("Expected DTCScanError, got \(error)")
        }
        XCTAssertEqual(comm.sentCommands.filter { $0 == "03" }.count, 1)
    }

    // MARK: - Interruption at service boundaries (D16)

    /// §6: a `.full` scan whose 03 answered with real codes and whose link then dies before 07
    /// throws `.connectionLost` **carrying the stored result** — the codes are never destroyed,
    /// and no report is published.
    func testLinkLossBeforePendingCarriesTheStoredEvidence() async throws {
        let comm = ScriptedComm(
            responses: [
                "0101": [Self.cleanStatusLines],
                "03": [["7E8 06 43 02 01 04 05 00"]],
            ],
            errors: ["07": BLEManagerError.peripheralNotConnected]
        )
        let sut = makeELM327(comm: comm)

        do {
            _ = try await sut.scanForTroubleCodes(profile: .full)
            XCTFail("Expected .connectionLost")
        } catch let error as DTCScanError {
            guard case let .connectionLost(partial) = error else {
                return XCTFail("Expected .connectionLost, got \(error)")
            }
            XCTAssertEqual(partial.profile, .full)
            XCTAssertEqual(partial.services.count, 1)
            XCTAssertEqual(partial.observations.map(\.code), ["P0104", "P0500"])
            guard case .answered = partial.statusRead else {
                return XCTFail("The status read so far must travel with the partial evidence")
            }
        }
    }

    /// The same evidence survives when the link is already gone at the service boundary, before
    /// the next request is even attempted.
    func testDisconnectAtAServiceBoundaryThrowsBeforeTheNextRequest() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 04 43 01 01 04"]],
        ])
        let sut = makeELM327(comm: comm)
        comm.onSend = { [weak sut] command, _ in
            if command == "03" { sut?.connectionState = .disconnected }
        }

        do {
            _ = try await sut.scanForTroubleCodes(profile: .full)
            XCTFail("Expected .connectionLost")
        } catch let error as DTCScanError {
            guard case let .connectionLost(partial) = error else {
                return XCTFail("Expected .connectionLost, got \(error)")
            }
            XCTAssertEqual(partial.observations.map(\.code), ["P0104"])
        }
        XCTAssertEqual(comm.sentCommands, ["0101", "03"], "No request may follow the link loss")
    }

    /// A cancellation that really arrives after the last requested service resolved never
    /// discards a fully answered scan — the publish/interrupt race, decided in favour of the
    /// evidence.
    func testCancellationAfterTheFinalServiceStillPublishesTheReport() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 02 43 00"]],
        ])
        let sut = makeELM327(comm: comm)

        let task = Task { try await sut.scanForTroubleCodes(profile: .storedOnly) }
        // Cancel for real, as soon as the final service has been sent: no boundary check follows
        // it, so the report must still publish.
        while !comm.sentCommands.contains("03") {
            await Task.yield()
        }
        task.cancel()

        let report = try await task.value
        XCTAssertTrue(report.isCleanForProfile)
        XCTAssertTrue(report.isCoverageComplete)
    }

    /// The mirror image: a cancellation *before* a service boundary aborts with typed evidence.
    func testCancellationBeforeALaterServiceThrowsWithEvidence() async {
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 04 43 01 01 04"]],
            "07": [["7E8 02 47 00"]],
        ])
        let sut = makeELM327(comm: comm)

        let task = Task { try await sut.scanForTroubleCodes(profile: .full) }
        while !comm.sentCommands.contains("03") {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            // A very fast machine may finish 07/0A before the cancellation lands; the guarantee
            // under test is that the scan never *silently* drops evidence, so a completed report
            // is acceptable here only if it is complete.
            XCTAssertEqual(comm.sentCommands, ["0101", "03", "07", "0A"])
        } catch let error as DTCScanError {
            guard case let .cancelled(partial) = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
            XCTAssertEqual(partial.observations.map(\.code), ["P0104"])
        } catch {
            XCTFail("Expected DTCScanError, got \(error)")
        }
    }

    // MARK: - 29-bit ISO 15765-4

    /// §6: an `18 DA F1 10`-headed response parses, with the **full** 29-bit id as the
    /// responder identity.
    func testTwentyNineBitResponseParsesWithItsFullIdentity() throws {
        let result = parse(["18 DA F1 10 06 43 02 01 04 05 00"], .stored, .can29)

        let outcome = try outcome(result, engine29)
        XCTAssertEqual(codes(outcome), ["P0104", "P0500"])
        XCTAssertTrue(outcome.codes.allSatisfy { $0.ecuAddress == self.engine29 })
    }

    func testTwentyNineBitCleanAndNegativeShapesParse() throws {
        XCTAssertEqual(
            try outcome(parse(["18 DA F1 10 02 43 00"], .stored, .can29), engine29),
            .responded(codes: [])
        )
        XCTAssertEqual(
            try outcome(parse(["18 DA F1 10 03 7F 03 11"], .stored, .can29), engine29),
            .negativeResponse(.serviceNotSupported)
        )
    }

    /// Two 29-bit modules differ only beyond the low byte — the full id keeps them apart.
    func testTwentyNineBitRespondersAreNotCollapsed() throws {
        let result = parse([
            "18 DA F1 10 02 43 00",
            "18 DA F1 18 04 43 01 01 04",
        ], .stored, .can29)

        let responders = try responders(result)
        XCTAssertEqual(responders.count, 2)
        XCTAssertEqual(responders[ECUAddress(raw: 0x18DAF110)], .responded(codes: []))
        XCTAssertEqual(codes(try outcome(result, ECUAddress(raw: 0x18DAF118))), ["P0104"])
    }

    func testTwentyNineBitScanRunsEndToEnd() async throws {
        let comm = ScriptedComm(responses: [
            "0101": [["18 DA F1 10 06 41 01 82 34 56 78"]],
            "03": [["18 DA F1 10 04 43 01 04 20"]],
        ])
        let sut = makeELM327(comm: comm, canProtocol: ISO_15765_4_29bit_500k())

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(report.observations.map(\.code), ["P0420"])
        let statuses = try statusResponders(report.statusRead)
        XCTAssertEqual(statuses.addresses, [engine29])
    }

    /// The generic parser is fixed too: `idBits` now comes from `PROTOCOL`, so a 29-bit vehicle
    /// can complete vehicle setup instead of throwing on every frame.
    func testGenericParserHandlesTwentyNineBitProtocols() throws {
        for canProtocol in [ISO_15765_4_29bit_500k(), ISO_15765_4_29bit_250k()] as [CANProtocol] {
            XCTAssertEqual(canProtocol.idBits, 29)
            let data = try canProtocol.parse(["18 DA F1 10 06 41 00 00 01 02 03"]).first?.data
            XCTAssertEqual(data, Data([0x00, 0x00, 0x01, 0x02, 0x03]))
        }
        for canProtocol in [ISO_15765_4_11bit_500k(), ISO_15765_4_11bit_250K()] as [CANProtocol] {
            XCTAssertEqual(canProtocol.idBits, 11, "11-bit protocols are unchanged")
        }
    }

    /// Unmapped protocols must fail loudly rather than leaving a silent `nil` parser.
    func testUnmappedProtocolsThrow() {
        for unmapped in [PROTOCOL.protocolB, .protocolC, .NONE] {
            XCTAssertThrowsError(try unmapped.parserImplementation(), "\(unmapped) has no implementation") { error in
                guard case ELM327Error.invalidProtocol? = error as? ELM327Error else {
                    return XCTFail("Expected .invalidProtocol for \(unmapped), got \(error)")
                }
            }
        }
        XCTAssertNoThrow(try PROTOCOL.protocol6.parserImplementation())
        XCTAssertNoThrow(try PROTOCOL.protocol7.parserImplementation())
    }

    // MARK: - Advisory unsupported cache (D10)

    /// §6: populated by a terminal `0x11`, and by nothing else.
    func testUnsupportedCacheIsPopulatedOnlyByServiceNotSupported() async throws {
        let store = InMemoryDTCUnsupportedServiceStore()
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["NO DATA"]],
            "07": [["7E8 03 7F 07 21"]],
            "0A": [["7E8 03 7F 0A 11"]],
        ])
        let sut = makeELM327(comm: comm)
        sut.unsupportedServiceStore = store
        sut.vehicleIdentifier = "1N4AL3AP7DC199583"

        _ = try await sut.scanForTroubleCodes(profile: .full)

        let scope = DTCUnsupportedServiceKey.vin("1N4AL3AP7DC199583")
        let permanentKey = DTCUnsupportedServiceKey(
            vehicleScope: scope,
            ecuAddress: engine,
            protocolID: "6",
            service: .permanent
        )
        XCTAssertEqual(store.unsupportedKeys, [permanentKey])
        XCTAssertTrue(store.isUnsupported(permanentKey))
        // A busy 0x21 and a silent Mode 03 say nothing about support.
        XCTAssertFalse(store.isUnsupported(
            DTCUnsupportedServiceKey(vehicleScope: scope, ecuAddress: engine, protocolID: "6", service: .pending)
        ))
        XCTAssertFalse(store.isUnsupported(
            DTCUnsupportedServiceKey(vehicleScope: scope, ecuAddress: engine, protocolID: "6", service: .stored)
        ))
    }

    /// The store refuses to record anything that does not derive "unsupported", even if a caller
    /// asks it to.
    func testUnsupportedStoreIgnoresNonDerivingNRCs() {
        let store = InMemoryDTCUnsupportedServiceStore()
        let key = DTCUnsupportedServiceKey(
            vehicleScope: DTCUnsupportedServiceKey.vin("VIN"),
            ecuAddress: engine,
            protocolID: "6",
            service: .stored
        )
        for nrc in [NegativeResponseCode.busyRepeatRequest, .responsePending, .conditionsNotCorrect, .requestOutOfRange] {
            store.record(key, nrc: nrc)
        }
        XCTAssertTrue(store.unsupportedKeys.isEmpty)

        store.record(key, nrc: .subFunctionNotSupported)
        XCTAssertTrue(store.isUnsupported(key))
    }

    /// Two successive VIN-less vehicles must not share evidence. With a shared `nil` scope, the
    /// first car's refusal would have coloured the second car's wording.
    func testVINLessConnectionsDoNotShareEvidence() async throws {
        let store = InMemoryDTCUnsupportedServiceStore()
        let refusal: [String: [[String]]] = [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 02 43 00"]],
            "07": [["7E8 02 47 00"]],
            "0A": [["7E8 03 7F 0A 11"]],
        ]

        let firstComm = ScriptedComm(responses: refusal)
        let first = makeELM327(comm: firstComm)
        first.unsupportedServiceStore = store
        _ = try await first.scanForTroubleCodes(profile: .full)
        let firstScope = first.dtcEvidenceScope

        // A new connection generation: state reset, no VIN either time.
        let secondComm = ScriptedComm(responses: refusal)
        let second = makeELM327(comm: secondComm)
        second.unsupportedServiceStore = store
        second.resetState()
        second.canProtocol = ISO_15765_4_11bit_500k()
        _ = try await second.scanForTroubleCodes(profile: .full)
        let secondScope = second.dtcEvidenceScope

        XCTAssertNotEqual(firstScope, secondScope, "A VIN-less vehicle gets its own session scope")
        XCTAssertEqual(store.unsupportedKeys.count, 2, "Neither vehicle may answer for the other")
        XCTAssertFalse(store.isUnsupported(
            DTCUnsupportedServiceKey(
                vehicleScope: secondScope,
                ecuAddress: engine,
                protocolID: "6",
                service: .stored
            )
        ))
    }

    /// Reconnecting to the *same* VIN legitimately shares evidence — that is the point of keying
    /// by VIN when one is available.
    func testSameVINReconnectSharesEvidence() async throws {
        let store = InMemoryDTCUnsupportedServiceStore()
        let refusal: [String: [[String]]] = [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 02 43 00"]],
            "07": [["7E8 02 47 00"]],
            "0A": [["7E8 03 7F 0A 11"]],
        ]

        let first = makeELM327(comm: ScriptedComm(responses: refusal))
        first.unsupportedServiceStore = store
        first.vehicleIdentifier = "SAMEVIN0000000001"
        _ = try await first.scanForTroubleCodes(profile: .full)

        let second = makeELM327(comm: ScriptedComm(responses: refusal))
        second.unsupportedServiceStore = store
        second.resetState()
        second.canProtocol = ISO_15765_4_11bit_500k()
        second.vehicleIdentifier = "SAMEVIN0000000001"
        _ = try await second.scanForTroubleCodes(profile: .full)

        XCTAssertEqual(first.dtcEvidenceScope, second.dtcEvidenceScope)
        XCTAssertEqual(store.unsupportedKeys.count, 1, "Same vehicle, same evidence")
    }

    /// A reset mints a new session scope even within one ELM327 instance.
    func testResetStateRegeneratesTheSessionScope() {
        let sut = makeELM327(comm: ScriptedComm())
        let before = sut.dtcEvidenceScope
        sut.resetState()
        XCTAssertNotEqual(before, sut.dtcEvidenceScope)
        XCTAssertTrue(before.hasPrefix("session:"))

        sut.vehicleIdentifier = "VIN1"
        XCTAssertEqual(sut.dtcEvidenceScope, DTCUnsupportedServiceKey.vin("VIN1"))
        // An empty VIN is no identity at all and must fall back to the session scope.
        sut.vehicleIdentifier = ""
        XCTAssertTrue(sut.dtcEvidenceScope.hasPrefix("session:"))
    }

    /// The cache never suppresses a request: a service refused once is still broadcast, because
    /// another module may support it.
    func testCachedUnsupportedServiceIsStillRequested() async throws {
        let store = InMemoryDTCUnsupportedServiceStore()
        let comm = ScriptedComm(responses: [
            "0101": [Self.cleanStatusLines],
            "03": [["7E8 02 43 00"]],
            "07": [["7E8 02 47 00"]],
            "0A": [["7E9 04 4A 01 04 20"]],
        ])
        let sut = makeELM327(comm: comm)
        sut.unsupportedServiceStore = store
        store.record(
            DTCUnsupportedServiceKey(
                vehicleScope: sut.dtcEvidenceScope,
                ecuAddress: engine,
                protocolID: "6",
                service: .permanent
            ),
            nrc: .serviceNotSupported
        )

        let report = try await sut.scanForTroubleCodes(profile: .full)

        XCTAssertTrue(comm.sentCommands.contains("0A"))
        XCTAssertEqual(report.observations.map(\.code), ["P0420"])
    }

    // MARK: - Mode 04 verification

    func testClearCodesSucceedsOnAVerifiedPositiveResponse() async throws {
        let comm = ScriptedComm(responses: ["04": [["7E8 01 44"]]])
        let sut = makeELM327(comm: comm)

        try await sut.clearTroubleCodes()

        XCTAssertEqual(comm.sentCommands, ["04"])
    }

    func testClearCodesThrowsOnARefusal() async {
        let comm = ScriptedComm(responses: ["04": [["7E8 03 7F 04 22"]]])
        let sut = makeELM327(comm: comm)

        do {
            try await sut.clearTroubleCodes()
            XCTFail("A refused clear must not look successful")
        } catch {
            XCTAssertTrue(error is ELM327Error, "Unexpected error: \(error)")
        }
    }

    func testClearCodesThrowsWhenNoPositiveResponseArrives() async {
        for lines in [["NO DATA"], [], ["7E8 02 43 00"], ["SEARCHING..."]] {
            let comm = ScriptedComm(responses: ["04": [lines]])
            let sut = makeELM327(comm: comm)
            do {
                try await sut.clearTroubleCodes()
                XCTFail("An unverified clear must throw (lines: \(lines))")
            } catch {
                XCTAssertTrue(error is ELM327Error, "Unexpected error: \(error)")
            }
        }
    }

    func testClearOutcomeVerifiesLegacyResponsesToo() {
        XCTAssertEqual(
            DTCResponseParser.clearOutcome(lines: ["48 6B 10 44 00 00 70"], family: .legacy),
            .verified
        )
        XCTAssertEqual(
            DTCResponseParser.clearOutcome(lines: ["48 6B 10 7F 04 11 70"], family: .legacy),
            .refused(.serviceNotSupported)
        )
    }

    // MARK: - Demo transport scenarios

    func testMockCleanScenarioProducesAVerifiedCleanFullScan() async throws {
        let comm = makeMock(scenario: .clean)
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .full)

        XCTAssertTrue(report.isCleanForProfile)
        XCTAssertTrue(report.isCoverageComplete)
        XCTAssertTrue(report.observations.isEmpty)
        // The mock's `0101` count agrees with the scenario, so no spurious coverage gap.
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testMockPendingOnlyScenarioSurfacesAPendingCode() async throws {
        let comm = makeMock(scenario: .pendingOnly)
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .full)

        XCTAssertEqual(report.observations.map(\.code), ["P0301"])
        XCTAssertEqual(report.observations.map(\.kind), [.pending])
        XCTAssertTrue(report.services[.stored]?.isClean == true)
        XCTAssertFalse(report.isCleanForProfile)
    }

    func testMockDefaultScenarioStillReportsTwoStoredCodes() async throws {
        let sut = makeELM327(comm: makeMock(scenario: .codes))

        let report = try await sut.scanForTroubleCodes(profile: .full)

        XCTAssertEqual(report.observations.count, 2)
        XCTAssertTrue(report.observations.allSatisfy { $0.kind == .stored })
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testMockVerifiesClearCodes() async throws {
        let sut = makeELM327(comm: makeMock(scenario: .codes))
        try await sut.clearTroubleCodes()
    }
}

// MARK: - Scripted transport

/// A comm layer that replays queued lines per command (the last entry repeats), can throw a
/// scripted error per command, records every send, and implements the exclusive send+listen
/// transaction with a **queue** of late windows — so "no retransmit happened", "the busy cap was
/// respected", "several windows were needed" and "an interruption during a window is typed" are
/// all assertable.
private final class ScriptedComm: CommProtocol {
    @Published var connectionState: ConnectionState
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    /// Queued responses per command; once exhausted the last entry repeats.
    private let responses: [String: [[String]]]
    private let errors: [String: Error]
    /// Called on every send with the command and its 1-based attempt number.
    var onSend: ((String, Int) -> Void)?

    // Mutable state is lock-guarded: the scan runs on its own task while a test may be polling
    // `sentCommands` to decide when to cancel, and an unsynchronised array crashes.
    private let lock = NSLock()
    private var recordedSends: [String] = []
    private var listens = 0
    private var queuedWindows: [[String]] = []
    private var scriptedContinuationError: (window: Int, error: Error)?

    init(
        responses: [String: [[String]]] = [:],
        errors: [String: Error] = [:],
        state: ConnectionState = .connectedToVehicle
    ) {
        self.responses = responses
        self.errors = errors
        connectionState = state
    }

    /// Lines the successive extra listen windows deliver, consumed in order. An exhausted queue
    /// behaves like a window that timed out with nothing in it.
    var additionalResponses: [[String]] {
        get { lock.lock(); defer { lock.unlock() }; return queuedWindows }
        set { lock.lock(); queuedWindows = newValue; lock.unlock() }
    }

    /// Thrown from the listen window whose 1-based index this matches — the transports only let
    /// terminal interruptions escape a window, so this models cancellation/link loss mid-exchange.
    var continuationError: (window: Int, error: Error)? {
        get { lock.lock(); defer { lock.unlock() }; return scriptedContinuationError }
        set { lock.lock(); scriptedContinuationError = newValue; lock.unlock() }
    }

    var sentCommands: [String] {
        lock.lock(); defer { lock.unlock() }; return recordedSends
    }

    var additionalListens: Int {
        lock.lock(); defer { lock.unlock() }; return listens
    }

    func sendCommand(_ command: String, retries _: Int) async throws -> [String] {
        lock.lock()
        recordedSends.append(command)
        let attempt = recordedSends.filter { $0 == command }.count
        lock.unlock()

        onSend?(command, attempt)
        if let error = errors[command] { throw error }
        guard let queued = responses[command], !queued.isEmpty else { return [] }
        return queued[min(attempt - 1, queued.count - 1)]
    }

    func sendCommandTransaction(
        _ command: String,
        retries: Int,
        shouldContinueListening: @escaping @Sendable ([String]) -> Bool,
        listenDeadline _: TimeInterval
    ) async throws -> [String] {
        var accumulated = try await sendCommand(command, retries: retries)
        while shouldContinueListening(accumulated) {
            lock.lock()
            listens += 1
            let window = listens
            let scripted = scriptedContinuationError
            let next = queuedWindows.isEmpty ? nil : queuedWindows.removeFirst()
            lock.unlock()

            if let scripted, scripted.window == window { throw scripted.error }
            guard let next else { break } // the window came back empty
            accumulated.append(contentsOf: next)
        }
        return accumulated
    }

    func disconnectPeripheral() {
        connectionState = .disconnected
    }

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral?) async throws {}

    func scanForPeripherals() async throws {}
}
