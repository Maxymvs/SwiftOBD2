//
//  DTCScanPhase1Tests.swift
//
//  Phase 1 gate of the DTC scan reliability work: raw ELM lines → expected outcome, plus the
//  transport boundary. These are the fixtures the RFC's §6 "Phase 1 gate" enumerates — the
//  layer that had zero coverage while a negative response decoded as a clean scan.
//

import Combine
import CoreBluetooth
@testable import SwiftOBD2
import XCTest

final class DTCScanPhase1Tests: XCTestCase {
    // MARK: - Addresses

    private let engine = ECUAddress(raw: 0x7E8)
    private let transmission = ECUAddress(raw: 0x7E9)
    private let absECU = ECUAddress(raw: 0x7EA)
    private let bodyECU = ECUAddress(raw: 0x7EB)
    private let klineECU = ECUAddress(raw: 0x12)

    private enum FixtureFailure: Error {
        case notAnswered
    }

    // MARK: - Helpers

    private func parseCAN(_ lines: [String]) -> DTCServiceResult {
        DTCResponseParser.parse(lines: lines, service: .stored, family: .can11)
    }

    private func parseLegacy(_ lines: [String]) -> DTCServiceResult {
        DTCResponseParser.parse(lines: lines, service: .stored, family: .legacy)
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

    // MARK: - Verified clean

    func testCleanSingleFrameReadsAsVerifiedClean() throws {
        let result = parseCAN(["7E8 02 43 00"])

        XCTAssertEqual(try outcome(result, engine), .responded(codes: []))
        let report = DTCScanReport.storedOnly(result)
        XCTAssertTrue(report.isCleanForProfile)
        XCTAssertTrue(report.isCoverageComplete)
        XCTAssertEqual(report.profile, .storedOnly)
        XCTAssertEqual(report.statusRead, .notAttempted)
    }

    /// Clean is "verified `43` + a count-consistent zero pairs", not one literal byte shape:
    /// bytes beyond the ISO-TP declared length are transport padding.
    func testTransportPaddingBeyondDeclaredLengthIsIgnored() throws {
        let result = parseCAN(["7E8 02 43 00 00 00 00 00 00 00"])

        XCTAssertEqual(try outcome(result, engine), .responded(codes: []))
        XCTAssertTrue(DTCScanReport.storedOnly(result).isCleanForProfile)
    }

    // MARK: - Negative responses (evidence only in this phase)

    /// The regression fixture for §1.3: today's pipeline decodes this to an empty *success*.
    func testServiceNotSupportedNegativeResponseIsNeverClean() throws {
        let result = parseCAN(["7E8 03 7F 03 11"])

        XCTAssertEqual(
            try outcome(result, engine),
            .negativeResponse(NegativeResponseCode(rawValue: 0x11))
        )
        let report = DTCScanReport.storedOnly(result)
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertFalse(report.isCoverageComplete)
    }

    func testBusyNegativeResponseIsRecordedWithoutAnyRetry() async throws {
        let comm = ScriptedComm(responses: ["03": ["7E8 03 7F 03 21"]])
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        let result = try XCTUnwrap(report.services[.stored])
        XCTAssertEqual(
            try outcome(result, engine),
            .negativeResponse(NegativeResponseCode(rawValue: 0x21))
        )
        // No NRC-driven retry or wait exists until Phase 3.
        XCTAssertEqual(comm.sentCommands, ["03"])
        XCTAssertFalse(report.isCleanForProfile)
    }

    /// A `7F` whose echoed service byte is not the in-flight request is noise, not evidence —
    /// and noise-only means the vehicle answered with nothing usable.
    func testMismatchedServiceEchoIsNoiseNotANegativeResponse() {
        let result = parseCAN(["7E8 03 7F 07 31"])

        XCTAssertEqual(result, .invalidResponse)
        XCTAssertNil(result.responders)
        XCTAssertFalse(DTCScanReport.storedOnly(result).isCleanForProfile)
    }

    // MARK: - Silence vs. damage

    func testNoDataAndEmptyOutputAreNoResponse() {
        XCTAssertEqual(parseCAN(["NO DATA"]), .noResponse)
        XCTAssertEqual(parseCAN(["NO DATA", ">"]), .noResponse)
        XCTAssertEqual(parseCAN([]), .noResponse)
        XCTAssertEqual(parseCAN(["", "   "]), .noResponse)
        // Adapter chatter alone is not a response either.
        XCTAssertEqual(parseCAN(["SEARCHING..."]), .noResponse)

        XCTAssertFalse(DTCScanReport.storedOnly(parseCAN(["NO DATA"])).isCleanForProfile)
    }

    /// Bytes arrived, but no line yields even a complete header — a response, not silence, and
    /// attributable to no ECU.
    func testDamagedOnlyResponseIsInvalidNotSilent() {
        let result = parseCAN(["43", "0F", "7"])

        XCTAssertEqual(result, .invalidResponse)
        XCTAssertFalse(DTCScanReport.storedOnly(result).isCleanForProfile)
    }

    /// A header-only line still names its responder, so it is that ECU's damage — it must not
    /// leave a clean message from the same ECU standing.
    func testHeaderOnlyLineDamagesItsResponder() throws {
        let result = parseCAN(["7E8 02 43 00", "7E8"])

        let responders = try responders(result)
        XCTAssertEqual(responders.count, 1)
        XCTAssertEqual(try outcome(result, engine), .malformed)
        let report = DTCScanReport.storedOnly(result)
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertFalse(report.isCoverageComplete)
    }

    /// The legacy equivalent: a complete 3-byte header with no payload behind it.
    func testLegacyHeaderOnlyLineDamagesItsResponder() throws {
        let result = parseLegacy(["87 F1 12 43 01 04 70", "87 F1 12"])

        let responders = try responders(result)
        XCTAssertEqual(responders.count, 1)
        XCTAssertEqual(try outcome(result, klineECU), .malformed)
        XCTAssertFalse(DTCScanReport.storedOnly(result).isCleanForProfile)
    }

    /// Damage whose *address* is readable stays attributed to that responder — and overrides a
    /// valid message the same responder also sent. No junk-frame dropping.
    func testAddressableDamageOverridesAValidMessageFromTheSameResponder() throws {
        let result = parseCAN(["7E8 02 43 00", "7E8 02 43 00 F"])

        let responders = try responders(result)
        XCTAssertEqual(responders.count, 1)
        XCTAssertEqual(try outcome(result, engine), .malformed)
        let report = DTCScanReport.storedOnly(result)
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertFalse(report.isCoverageComplete)
    }

    /// A garbled line long enough to carry an id keeps its responder present and malformed
    /// instead of vanishing from the report.
    func testAddressableGarbageBecomesAMalformedResponder() throws {
        let result = parseCAN(["11 22 33"])

        XCTAssertEqual(try outcome(result, ECUAddress(raw: 0x112)), .malformed)
    }

    // MARK: - Positive decodes

    func testSingleFrameCodesAreAttributedToTheirResponder() throws {
        let result = parseCAN(["7E8 06 43 02 01 04 05 00"])

        let outcome = try outcome(result, engine)
        XCTAssertEqual(codes(outcome), ["P0104", "P0500"])
        XCTAssertTrue(outcome.codes.allSatisfy { $0.ecuAddress == engine })
        XCTAssertTrue(outcome.codes.allSatisfy { $0.kind == .stored })
        XCTAssertFalse(DTCScanReport.storedOnly(result).isCleanForProfile)
    }

    /// Issue #25's capture: the engine is clean and another module holds the codes. Neither
    /// responder may overwrite the other.
    func testMultiECUResponseKeepsBothResponders() throws {
        let result = parseCAN(["7E8 02 43 00", "7E9 04 43 01 15 53"])

        let responders = try responders(result)
        XCTAssertEqual(responders.count, 2)
        XCTAssertEqual(responders[engine], .responded(codes: []))
        XCTAssertEqual(codes(try outcome(result, transmission)), ["P1553"])
        XCTAssertEqual(DTCScanReport.storedOnly(result).observations.count, 1)
    }

    /// Issue #25's K-line capture. The generic path prepends a synthetic `43 00`, which shifts
    /// the whole pair stream and fabricates codes; the report path canonicalises instead.
    func testKLineResponseDecodesItsRealCodesOnly() throws {
        let result = parseLegacy(["87 F1 12 43 15 53 13 28 00 00 70"])

        let responders = try responders(result)
        XCTAssertEqual(responders.count, 1)
        let outcome = try outcome(result, klineECU)
        XCTAssertEqual(codes(outcome), ["P1553", "P1328"])
        XCTAssertTrue(outcome.codes.allSatisfy { $0.ecuAddress == self.klineECU })
    }

    /// A positive response spread over several K-line lines merges into one message.
    func testKLineMergesAMultiLinePositiveResponse() throws {
        let result = parseLegacy([
            "87 F1 12 43 15 53 13 28 00 00 70",
            "87 F1 12 43 01 04 00 00 00 00 70",
        ])

        XCTAssertEqual(codes(try outcome(result, klineECU)), ["P1553", "P1328", "P0104"])
    }

    /// The merge must not reorder: a terminal refusal followed by positive lines is conflicting
    /// evidence, exactly as on CAN.
    func testKLineTerminalNegativeIsNotMaskedByALaterPositive() throws {
        let result = parseLegacy([
            "87 F1 12 7F 03 11 70",
            "87 F1 12 43 15 53 13 28 00 00 70",
        ])

        XCTAssertEqual(try outcome(result, klineECU), .malformed)
        XCTAssertFalse(DTCScanReport.storedOnly(result).isCleanForProfile)
    }

    func testKLineInterimNegativeIsSupersededByThePositive() throws {
        let result = parseLegacy([
            "87 F1 12 7F 03 78 70",
            "87 F1 12 43 15 53 13 28 00 00 70",
        ])

        XCTAssertEqual(codes(try outcome(result, klineECU)), ["P1553", "P1328"])
    }

    func testMultiFrameISOTPMessageDecodesEveryCode() throws {
        let result = parseCAN([
            "7E8 10 08 43 03 01 04 05",
            "7E8 21 00 01 15 00 00 00",
        ])

        XCTAssertEqual(codes(try outcome(result, engine)), ["P0104", "P0500", "P0115"])
    }

    func testMultiFrameISOTPAcceptsAFullConsecutiveSequence() throws {
        let result = parseCAN([
            "7E8 10 0E 43 06 01 04 05 00",
            "7E8 21 01 15 01 33 02 20 03",
            "7E8 22 01 00 00 00 00 00 00",
        ])

        XCTAssertEqual(
            codes(try outcome(result, engine)),
            ["P0104", "P0500", "P0115", "P0133", "P0220", "P0301"]
        )
    }

    /// A dropped consecutive frame changes what the bytes mean, so the message is damaged —
    /// decoding the surviving frames would invent codes the ECU never sent.
    func testMultiFrameISOTPRejectsASkippedConsecutiveFrame() throws {
        let result = parseCAN([
            "7E8 10 08 43 03 01 04 05",
            "7E8 22 00 01 15 00 00 00", // `21` never arrived
        ])

        XCTAssertEqual(try outcome(result, engine), .malformed)
        XCTAssertFalse(DTCScanReport.storedOnly(result).isCleanForProfile)
    }

    func testMultiFrameISOTPRejectsADuplicatedConsecutiveFrame() throws {
        let result = parseCAN([
            "7E8 10 0E 43 06 01 04 05 00",
            "7E8 21 01 15 01 33 02 20 03",
            "7E8 21 01 00 00 00 00 00 00",
        ])

        XCTAssertEqual(try outcome(result, engine), .malformed)
    }

    // MARK: - Count-byte consistency and tolerance

    /// `43 01 00 00` claims one code and decodes none — damaged, never clean.
    func testCountByteInconsistencyIsMalformed() throws {
        let result = parseCAN(["7E8 04 43 01 00 00"])

        XCTAssertEqual(try outcome(result, engine), .malformed)
        let report = DTCScanReport.storedOnly(result)
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertFalse(report.isCoverageComplete)
    }

    /// Per-message tolerance: one responder's damage must not hide another's real codes.
    func testDamagedResponderDoesNotHideAValidOne() throws {
        let result = parseCAN([
            "7E8 06 43 02 01 04 05 00",
            "7E9 07 43 01 04", // declares 7 application bytes, sends 3
        ])

        let responders = try responders(result)
        XCTAssertEqual(responders.count, 2)
        XCTAssertEqual(codes(try outcome(result, engine)), ["P0104", "P0500"])
        XCTAssertEqual(try outcome(result, transmission), .malformed)
        XCTAssertFalse(DTCScanReport.storedOnly(result).isCoverageComplete)
    }

    /// Same buffered read: the final message supersedes the interim response-pending.
    func testFinalMessageSupersedesResponsePendingInTheSameBuffer() throws {
        let result = parseCAN(["7E8 03 7F 03 78", "7E8 04 43 01 01 04"])

        let responders = try responders(result)
        XCTAssertEqual(responders.count, 1)
        XCTAssertEqual(codes(try outcome(result, engine)), ["P0104"])
    }

    /// `0x21` busy is the other interim code, so it may be superseded too.
    func testInterimBusyNegativeIsSupersededByTheFinalMessage() throws {
        let result = parseCAN(["7E8 03 7F 03 21", "7E8 04 43 01 01 04"])

        XCTAssertEqual(codes(try outcome(result, engine)), ["P0104"])
    }

    /// A *terminal* refusal is a definitive answer: a later positive message from the same
    /// responder is conflicting evidence, not a supersede, and must never read as clean.
    func testTerminalNegativeIsNotSupersededByALaterPositive() throws {
        let result = parseCAN(["7E8 03 7F 03 11", "7E8 02 43 00"])

        XCTAssertEqual(try outcome(result, engine), .malformed)
        XCTAssertFalse(DTCScanReport.storedOnly(result).isCleanForProfile)
    }

    /// Two positive messages from one responder in one buffer are equally conflicting.
    func testTwoPositiveMessagesFromOneResponderAreConflictingEvidence() throws {
        let result = parseCAN(["7E8 02 43 00", "7E8 04 43 01 01 04"])

        XCTAssertEqual(try outcome(result, engine), .malformed)
    }

    // MARK: - Addressing families

    func testProtocolFamilyMapping() {
        XCTAssertEqual(DTCProtocolFamily(elmID: "6"), .can11)
        XCTAssertEqual(DTCProtocolFamily(elmID: "8"), .can11)
        XCTAssertEqual(DTCProtocolFamily(elmID: "5"), .legacy)
        XCTAssertEqual(DTCProtocolFamily(elmID: "1"), .legacy)
        // 29-bit ISO 15765-4 and J1939 stay out of scope until Phase 3.
        XCTAssertEqual(DTCProtocolFamily(elmID: "7"), .unsupportedAddressing)
        XCTAssertEqual(DTCProtocolFamily(elmID: "9"), .unsupportedAddressing)
        XCTAssertEqual(DTCProtocolFamily(elmID: "A"), .unsupportedAddressing)
        XCTAssertEqual(DTCProtocolFamily(elmID: nil), .unsupportedAddressing)
    }

    /// A 29-bit response fails explicitly: present but unparseable, never clean, never silent.
    func testUnsupportedAddressingIsInvalidWhenBytesArrive() {
        let lines = ["18 DA F1 10 02 43 00"]
        XCTAssertEqual(
            DTCResponseParser.parse(lines: lines, service: .stored, family: .unsupportedAddressing),
            .invalidResponse
        )
        XCTAssertEqual(
            DTCResponseParser.parse(lines: ["NO DATA"], service: .stored, family: .unsupportedAddressing),
            .noResponse
        )
    }

    // MARK: - Profiles

    func testUnimplementedProfilesThrowBeforeAnyIO() async {
        for profile in [DTCScanProfile.full, .quickConnect] {
            let comm = ScriptedComm(responses: ["03": ["7E8 02 43 00"]])
            let sut = makeELM327(comm: comm)
            do {
                _ = try await sut.scanForTroubleCodes(profile: profile)
                XCTFail("Expected .profileUnsupported for \(profile)")
            } catch let error as DTCScanError {
                XCTAssertEqual(error, .profileUnsupported(profile))
            } catch {
                XCTFail("Expected DTCScanError, got \(error)")
            }
            XCTAssertTrue(comm.sentCommands.isEmpty, "No I/O may happen for \(profile)")
        }
    }

    // MARK: - Transport boundary

    func testNoDataErrorFromTransportBecomesNoResponse() async throws {
        let comm = ScriptedComm(error: BLEManagerError.noData)
        let sut = makeELM327(comm: comm)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(report.services[.stored], .noResponse)
        XCTAssertFalse(report.isCleanForProfile)
    }

    func testRecoverableTimeoutWithLinkUpPublishesATransportFailure() async throws {
        let comm = ScriptedComm(error: BLEManagerError.sendMessageTimeout, state: .connectedToVehicle)
        let sut = makeELM327(comm: comm, linkState: .connectedToVehicle)

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        XCTAssertEqual(report.services[.stored], .transportFailure(.requestTimeout))
        XCTAssertFalse(report.isCleanForProfile)
        XCTAssertFalse(report.isCoverageComplete)
    }

    func testDisconnectFlaggedErrorThrowsConnectionLostWithEmptyPartial() async {
        let comm = ScriptedComm(error: BLEManagerError.peripheralNotConnected)
        let sut = makeELM327(comm: comm, linkState: .connectedToVehicle)

        do {
            _ = try await sut.scanForTroubleCodes(profile: .storedOnly)
            XCTFail("Expected .connectionLost")
        } catch let error as DTCScanError {
            guard case let .connectionLost(partial) = error else {
                return XCTFail("Expected .connectionLost, got \(error)")
            }
            XCTAssertEqual(partial.profile, .storedOnly)
            XCTAssertTrue(partial.services.isEmpty)
            XCTAssertEqual(partial.statusRead, .notAttempted)
            XCTAssertTrue(partial.observations.isEmpty)
        } catch {
            XCTFail("Expected DTCScanError, got \(error)")
        }
    }

    func testCancellationThrowsCancelledWithEmptyPartial() async {
        let comm = ScriptedComm(error: CancellationError())
        let sut = makeELM327(comm: comm, linkState: .connectedToVehicle)

        do {
            _ = try await sut.scanForTroubleCodes(profile: .storedOnly)
            XCTFail("Expected .cancelled")
        } catch let error as DTCScanError {
            guard case let .cancelled(partial) = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
            XCTAssertEqual(partial.profile, .storedOnly)
            XCTAssertTrue(partial.services.isEmpty)
        } catch {
            XCTFail("Expected DTCScanError, got \(error)")
        }
    }

    /// Terminal beats per-service: the same recoverable error becomes link loss once the link
    /// is gone, because the remaining services could not genuinely be attempted.
    func testTransportDispositionPrecedence() {
        XCTAssertEqual(
            DTCTransportDisposition(error: BLEManagerError.sendMessageTimeout, linkIsUp: true),
            .transportFailure(.requestTimeout)
        )
        XCTAssertEqual(
            DTCTransportDisposition(error: BLEManagerError.sendMessageTimeout, linkIsUp: false),
            .connectionLost
        )
        XCTAssertEqual(
            DTCTransportDisposition(error: BLEManagerError.noData, linkIsUp: true),
            .noResponse
        )
        XCTAssertEqual(
            DTCTransportDisposition(error: BLEMessageProcessorError.staleRequestToken, linkIsUp: true),
            .connectionLost
        )
        XCTAssertEqual(
            DTCTransportDisposition(error: CancellationError(), linkIsUp: true),
            .cancelled
        )
    }

    /// WiFi now reports `NO DATA` explicitly, so silence is never *inferred* from its generic
    /// error — which also covers garbled bytes and a missing socket.
    func testWiFiDispositionSeparatesSilenceFromGarbage() {
        XCTAssertEqual(
            DTCTransportDisposition(error: CommunicationError.noData, linkIsUp: true),
            .noResponse
        )
        XCTAssertEqual(
            DTCTransportDisposition(error: CommunicationError.invalidData, linkIsUp: true),
            .transportFailure(.adapterError)
        )
        XCTAssertEqual(
            DTCTransportDisposition(error: CommunicationError.invalidData, linkIsUp: false),
            .connectionLost
        )
        XCTAssertEqual(
            DTCTransportDisposition(error: CommunicationError.errorOccurred(CocoaError(.fileNoSuchFile)), linkIsUp: true),
            .transportFailure(.adapterError)
        )
    }

    // MARK: - Deprecated dictionary wrapper

    func testWrapperKeysCodesByProjectedECUID() async throws {
        let comm = ScriptedComm(responses: ["03": ["7E8 02 43 00", "7E9 04 43 01 15 53"]])
        let sut = makeELM327(comm: comm)

        let dictionary = try await sut.scanForTroubleCodes()

        XCTAssertEqual(dictionary[.transmission]?.map(\.code), ["P1553"])
        XCTAssertNil(dictionary[.engine], "A clean responder contributes no codes")
    }

    func testWrapperReturnsAnEmptyDictionaryForAVerifiedCleanScan() async throws {
        let comm = ScriptedComm(responses: ["03": ["7E8 02 43 00"]])
        let sut = makeELM327(comm: comm)

        let dictionary = try await sut.scanForTroubleCodes()

        XCTAssertTrue(dictionary.isEmpty)
    }

    func testWrapperMergesECUIDCollisionsInsteadOfOverwriting() async throws {
        let comm = ScriptedComm(responses: ["03": ["7EA 04 43 01 01 04", "7EB 04 43 01 05 00"]])
        let sut = makeELM327(comm: comm)

        let dictionary = try await sut.scanForTroubleCodes()

        // 0x7EA and 0x7EB both project to `.unknown`; neither may be dropped.
        XCTAssertEqual(absECU.ecuID, .unknown)
        XCTAssertEqual(bodyECU.ecuID, .unknown)
        XCTAssertEqual(dictionary[.unknown]?.map(\.code), ["P0104", "P0500"])
    }

    func testWrapperThrowsWhenAnyResponderIsNotPositive() async {
        let cases: [String: [String]] = [
            "malformed": ["7E8 04 43 01 00 00"],
            "negative": ["7E8 03 7F 03 11"],
            "invalid": ["43", "0F", "7"],
            "headerOnlyDamage": ["7E8 02 43 00", "7E8"],
            "mixedDamage": ["7E8 06 43 02 01 04 05 00", "7E9 07 43 01 04"],
        ]
        for (name, lines) in cases {
            let comm = ScriptedComm(responses: ["03": lines])
            let sut = makeELM327(comm: comm)
            do {
                let dictionary = try await sut.scanForTroubleCodes()
                XCTFail("Expected \(name) to throw, got \(dictionary)")
            } catch {
                XCTAssertTrue(error is ELM327Error, "Unexpected error for \(name): \(error)")
            }
        }
    }

    func testWrapperThrowsOnSilenceInsteadOfReportingClean() async {
        let comm = ScriptedComm(error: BLEManagerError.noData)
        let sut = makeELM327(comm: comm)

        do {
            let dictionary = try await sut.scanForTroubleCodes()
            XCTFail("NO DATA must not read as clean, got \(dictionary)")
        } catch {
            XCTAssertTrue(error is ELM327Error, "Unexpected error: \(error)")
        }
    }

    // MARK: - Demo transport

    /// The demo mock's Mode 03 response must be a *well-formed* frame: its length byte covered a
    /// stray pair boundary, which the new count-byte rule correctly calls damaged.
    func testDemoMockReturnsAWellFormedModeThreeResponse() async throws {
        let sut = makeELM327(comm: MOCKComm())

        let report = try await sut.scanForTroubleCodes(profile: .storedOnly)

        let result = try XCTUnwrap(report.services[.stored])
        XCTAssertEqual(codes(try outcome(result, engine)).count, 2)
        XCTAssertFalse(report.isCleanForProfile)
    }

    // MARK: - Status exposure

    func testStatusExposesMILAndIgnitionType() throws {
        let data = Data([0x83, 0x07, 0xFF, 0x00])
        let decoded = StatusDecoder().decode(data: data, unit: .metric)
        let status = try XCTUnwrap(try decoded.get().statusResult)

        XCTAssertTrue(status.MIL)
        XCTAssertEqual(status.dtcCount, 3)
        XCTAssertFalse(status.ignitionType.isEmpty)
    }

    // MARK: - Fixtures

    private func makeELM327(comm: CommProtocol, linkState: ConnectionState = .connectedToVehicle) -> ELM327 {
        let sut = ELM327(comm: comm)
        sut.canProtocol = ISO_15765_4_11bit_500k()
        sut.connectionState = linkState
        return sut
    }
}

/// A comm layer that replays scripted lines (or throws a scripted error) and records what was
/// sent, so "no I/O happened" and "exactly one request was sent" are assertable.
private final class ScriptedComm: CommProtocol {
    @Published var connectionState: ConnectionState
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    private let responses: [String: [String]]
    private let error: Error?
    private(set) var sentCommands: [String] = []

    init(
        responses: [String: [String]] = [:],
        error: Error? = nil,
        state: ConnectionState = .connectedToVehicle
    ) {
        self.responses = responses
        self.error = error
        connectionState = state
    }

    func sendCommand(_ command: String, retries _: Int) async throws -> [String] {
        sentCommands.append(command)
        if let error { throw error }
        return responses[command] ?? []
    }

    func disconnectPeripheral() {
        connectionState = .disconnected
    }

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral?) async throws {}

    func scanForPeripherals() async throws {}
}
