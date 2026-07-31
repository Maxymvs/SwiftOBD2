//
//  DTCReadinessTests.swift
//
//  Readiness monitors (SAE J1979 Mode 01 PID 01, bytes B/C/D): the decode, the
//  per-responder totality invariant, and the conservative multi-ECU aggregate.
//
//  The invariant under test throughout: **only verified evidence ever reads as ready.**
//  Silence, refusal, damage and undecodable payloads must each land somewhere other than
//  `.complete`.
//

@testable import SwiftOBD2
import XCTest

final class DTCReadinessTests: XCTestCase {
    // MARK: - Helpers

    private let engine = ECUAddress(raw: 0x7E8)
    private let transmission = ECUAddress(raw: 0x7E9)
    private let body = ECUAddress(raw: 0x7EA)

    /// Raw `41 01` status bytes A–D.
    ///
    /// Byte B: bit0/1/2 = misfire/fuel/components supported, bit3 = ignition type
    /// (0 spark / 1 compression), bit4/5/6 = the matching incomplete flags.
    /// Byte C = non-continuous supported bitmap, byte D = non-continuous incomplete bitmap.
    private func decodeStatus(_ bytes: [UInt8]) throws -> Status {
        let result = StatusDecoder().decode(data: Data(bytes), unit: .metric)
        return try XCTUnwrap(try result.get().statusResult)
    }

    private func decodeReadiness(_ bytes: [UInt8]) throws -> ECUReadiness {
        try XCTUnwrap(try decodeStatus(bytes).readiness)
    }

    /// A `0101` responder line for one address with the four status bytes behind it.
    private func statusLine(_ address: UInt32, _ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "\(String(address, radix: 16, uppercase: true)) 06 41 01 \(hex)"
    }

    /// Every aggregation fixture routes through here so the construction-surface invariant
    /// — non-empty `undeterminedResponders` ⇒ verdict ≠ `.complete` — is asserted globally
    /// rather than by a (impossible) init-failure test.
    private func assess(_ statusRead: DTCStatusReadResult) -> VehicleReadinessAssessment {
        let assessment = VehicleReadinessAssessment(statusRead: statusRead)
        if !assessment.undeterminedResponders.isEmpty {
            XCTAssertNotEqual(
                assessment.verdict, .complete,
                "a responder with unknown readiness must forbid a complete claim"
            )
        }
        return assessment
    }

    private func assess(lines: [String]) -> VehicleReadinessAssessment {
        assess(DTCResponseParser.parseStatus(lines: lines, family: .can11))
    }

    // Canonical byte-D-free payloads reused across fixtures.
    /// Spark, all three continuous + all seven spark monitors supported and complete.
    private let sparkAllComplete: [UInt8] = [0x00, 0x07, 0xEF, 0x00]
    /// Spark, everything supported, evaporative system incomplete (byte D bit 2).
    private let sparkEvapIncomplete: [UInt8] = [0x00, 0x07, 0xEF, 0x04]
    /// Spark, nothing supported anywhere.
    private let sparkNothingSupported: [UInt8] = [0x00, 0x00, 0x00, 0x00]

    // MARK: - Monitor namespace

    /// The rendering order aggregates sort by. Pinned because `.incomplete`'s union order is
    /// part of the contract, and `CaseIterable` order is declaration order.
    func testMonitorCaseIterableOrderIsTheCanonicalRenderingOrder() {
        XCTAssertEqual(ReadinessMonitor.allCases, [
            .misfire, .fuelSystem, .comprehensiveComponents,
            .catalyst, .heatedCatalyst, .evaporativeSystem, .secondaryAirSystem,
            .oxygenSensor, .oxygenSensorHeater,
            .nmhcCatalyst, .noxScrAftertreatment, .boostPressure, .exhaustGasSensor, .pmFilter,
            .egrVvtSystem
        ])
    }

    func testApplicableMonitorSetsAreThreeContinuousPlusSevenSparkOrSixCompression() {
        let spark = ECUReadiness.applicableMonitors(for: .spark)
        let compression = ECUReadiness.applicableMonitors(for: .compression)
        XCTAssertEqual(spark.count, 10)
        XCTAssertEqual(compression.count, 9)
        XCTAssertEqual(spark, [
            .misfire, .fuelSystem, .comprehensiveComponents,
            .catalyst, .heatedCatalyst, .evaporativeSystem, .secondaryAirSystem,
            .oxygenSensor, .oxygenSensorHeater, .egrVvtSystem
        ])
        XCTAssertEqual(compression, [
            .misfire, .fuelSystem, .comprehensiveComponents,
            .nmhcCatalyst, .noxScrAftertreatment, .boostPressure, .exhaustGasSensor, .pmFilter,
            .egrVvtSystem
        ])
        // The shared bit-7 monitor is the only non-continuous overlap.
        XCTAssertEqual(
            spark.intersection(compression),
            Set(ECUReadiness.continuousMonitors).union([.egrVvtSystem])
        )
    }

    func testReadinessTypesAreSendable() {
        requireReadinessSendable(ReadinessMonitor.self)
        requireReadinessSendable(ReadinessMonitorState.self)
        requireReadinessSendable(ECUReadiness.self)
        requireReadinessSendable(ECUReadiness.IgnitionType.self)
        requireReadinessSendable(VehicleReadinessAssessment.self)
        requireReadinessSendable(VehicleReadinessAssessment.Verdict.self)
        requireReadinessSendable(VehicleReadinessAssessment.Undetermined.self)
        requireReadinessSendable(VehicleReadinessAssessment.StatusUnavailable.self)
    }

    // MARK: - Decode: spark

    func testSparkEverythingSupportedAndCompleteDecodesEveryMonitorComplete() throws {
        let status = try decodeStatus(sparkAllComplete)
        XCTAssertFalse(status.MIL)
        XCTAssertEqual(status.dtcCount, 0)
        XCTAssertEqual(status.ignitionType, "Spark", "the legacy string stays derived")

        let readiness = try XCTUnwrap(status.readiness)
        XCTAssertEqual(readiness.ignitionType, .spark)
        XCTAssertEqual(Set(readiness.monitors.keys), ECUReadiness.applicableMonitors(for: .spark))
        XCTAssertTrue(
            readiness.monitors.values.allSatisfy { $0 == .complete },
            "every applicable monitor must read complete: \(readiness.monitors)"
        )
        XCTAssertTrue(readiness.incompleteMonitors.isEmpty)
        XCTAssertTrue(readiness.hasSupportedMonitors)

        let assessment = assess(lines: [statusLine(0x7E8, sparkAllComplete)])
        XCTAssertEqual(assessment.verdict, .complete)
        XCTAssertTrue(assessment.undeterminedResponders.isEmpty)
    }

    /// Dedup is exercised elsewhere; this pins ordering — `CaseIterable` position, not the
    /// bit order they were decoded in.
    func testSparkEvapAndCatalystIncompleteAreOrderedByCaseIterablePosition() throws {
        // Byte D bit0 = catalyst, bit2 = evaporative system.
        let readiness = try decodeReadiness([0x00, 0x07, 0xEF, 0x05])
        XCTAssertEqual(readiness.monitors[.catalyst], .incomplete)
        XCTAssertEqual(readiness.monitors[.evaporativeSystem], .incomplete)
        XCTAssertEqual(readiness.monitors[.heatedCatalyst], .complete)
        XCTAssertEqual(readiness.incompleteMonitors, [.catalyst, .evaporativeSystem])

        let assessment = assess(lines: [statusLine(0x7E8, [0x00, 0x07, 0xEF, 0x05])])
        XCTAssertEqual(assessment.verdict, .incomplete(monitors: [.catalyst, .evaporativeSystem]))
        XCTAssertTrue(assessment.undeterminedResponders.isEmpty)
    }

    /// The byte-B → `ECUReadiness` projection, which every byte-C/D fixture would miss.
    func testContinuousMonitorIncompleteProjectsFromByteB() throws {
        // Byte B bit0 = misfire supported, bit4 = misfire incomplete; nothing else supported.
        let readiness = try decodeReadiness([0x00, 0x11, 0x00, 0x00])
        XCTAssertEqual(readiness.monitors[.misfire], .incomplete)
        XCTAssertEqual(readiness.monitors[.fuelSystem], .unsupported)
        XCTAssertEqual(readiness.monitors[.comprehensiveComponents], .unsupported)
        XCTAssertEqual(readiness.incompleteMonitors, [.misfire])

        let assessment = assess(lines: [statusLine(0x7E8, [0x00, 0x11, 0x00, 0x00])])
        XCTAssertEqual(assessment.verdict, .incomplete(monitors: [.misfire]))
    }

    /// Each continuous monitor's supported/incomplete bit pair independently, so a
    /// transposed byte-B index cannot hide behind an all-ones fixture.
    func testEachContinuousMonitorMapsToItsOwnByteBBitPair() throws {
        let cases: [(UInt8, ReadinessMonitor)] = [
            (0x11, .misfire),                 // bit0 supported + bit4 incomplete
            (0x22, .fuelSystem),              // bit1 supported + bit5 incomplete
            (0x44, .comprehensiveComponents)  // bit2 supported + bit6 incomplete
        ]
        for (byteB, monitor) in cases {
            let readiness = try decodeReadiness([0x00, byteB, 0x00, 0x00])
            XCTAssertEqual(
                readiness.incompleteMonitors, [monitor],
                "byte B \(String(format: "0x%02X", byteB)) must mean \(monitor) incomplete alone"
            )
        }
    }

    /// Each spark table position independently — the same guard for bytes C/D.
    func testEachSparkTablePositionMapsToItsOwnBit() throws {
        let table: [ReadinessMonitor?] = [
            .catalyst, .heatedCatalyst, .evaporativeSystem, .secondaryAirSystem,
            nil, .oxygenSensor, .oxygenSensorHeater, .egrVvtSystem
        ]
        for (bit, monitor) in table.enumerated() {
            let mask = UInt8(1) << UInt8(bit)
            let readiness = try decodeReadiness([0x00, 0x00, mask, mask])
            guard let monitor else {
                XCTAssertTrue(
                    readiness.incompleteMonitors.isEmpty,
                    "spark bit \(bit) is reserved and must decode to no monitor"
                )
                continue
            }
            XCTAssertEqual(readiness.incompleteMonitors, [monitor], "spark bit \(bit)")
        }
    }

    // MARK: - Decode: compression

    func testCompressionVehicleSelectsTheCompressionTableAndOmitsSparkMonitors() throws {
        // Byte B bit3 = compression; byte C = every defined compression position supported;
        // byte D bit1 = NOx/SCR incomplete.
        let status = try decodeStatus([0x00, 0x0F, 0xEB, 0x02])
        XCTAssertEqual(status.ignitionType, "Compression")

        let readiness = try XCTUnwrap(status.readiness)
        XCTAssertEqual(readiness.ignitionType, .compression)
        XCTAssertEqual(
            Set(readiness.monitors.keys), ECUReadiness.applicableMonitors(for: .compression)
        )
        XCTAssertEqual(readiness.monitors[.noxScrAftertreatment], .incomplete)
        XCTAssertEqual(readiness.monitors[.nmhcCatalyst], .complete)
        XCTAssertEqual(readiness.monitors[.pmFilter], .complete)
        XCTAssertEqual(readiness.incompleteMonitors, [.noxScrAftertreatment])
        // Spark-only monitors are absent — absence means "not a monitor here", not a state.
        for sparkOnly: ReadinessMonitor in [
            .catalyst, .heatedCatalyst, .evaporativeSystem, .secondaryAirSystem,
            .oxygenSensor, .oxygenSensorHeater
        ] {
            XCTAssertNil(readiness.monitors[sparkOnly], "\(sparkOnly) is not a compression monitor")
        }

        let assessment = assess(lines: [statusLine(0x7E8, [0x00, 0x0F, 0xEB, 0x02])])
        XCTAssertEqual(assessment.verdict, .incomplete(monitors: [.noxScrAftertreatment]))
    }

    func testEachCompressionTablePositionMapsToItsOwnBit() throws {
        let table: [ReadinessMonitor?] = [
            .nmhcCatalyst, .noxScrAftertreatment, nil, .boostPressure,
            nil, .exhaustGasSensor, .pmFilter, .egrVvtSystem
        ]
        for (bit, monitor) in table.enumerated() {
            let mask = UInt8(1) << UInt8(bit)
            // Byte B bit3 keeps the compression table selected.
            let readiness = try decodeReadiness([0x00, 0x08, mask, mask])
            guard let monitor else {
                XCTAssertTrue(
                    readiness.incompleteMonitors.isEmpty,
                    "compression bit \(bit) is reserved and must decode to no monitor"
                )
                continue
            }
            XCTAssertEqual(readiness.incompleteMonitors, [monitor], "compression bit \(bit)")
        }
    }

    // MARK: - Decode: "unsupported wins"

    /// R2's regression fixture: an unsupported monitor's byte-D bit is undefined noise — some
    /// ECUs set it arbitrarily — and must never surface as `.incomplete`.
    func testUnsupportedMonitorsIgnoreNoisyIncompleteBits() throws {
        // Byte B: bit0 misfire supported (complete), bit5 sets *fuel* incomplete while fuel is
        // unsupported. Byte C: nothing non-continuous supported. Byte D: every bit noise.
        let readiness = try decodeReadiness([0x00, 0x21, 0x00, 0xFF])

        XCTAssertEqual(readiness.monitors[.misfire], .complete)
        XCTAssertEqual(
            readiness.monitors[.fuelSystem], .unsupported,
            "byte B's incomplete bit is meaningless while the supported bit is 0"
        )
        XCTAssertEqual(readiness.monitors[.comprehensiveComponents], .unsupported)
        for monitor in ECUReadiness.nonContinuousTable(for: .spark).compactMap({ $0 }) {
            XCTAssertEqual(
                readiness.monitors[monitor], .unsupported,
                "\(monitor): byte D noise must be ignored while byte C's bit is 0"
            )
        }
        XCTAssertTrue(readiness.incompleteMonitors.isEmpty)

        // One supported-and-complete monitor is real evidence, so this is a complete claim.
        let assessment = assess(lines: [statusLine(0x7E8, [0x00, 0x21, 0x00, 0xFF])])
        XCTAssertEqual(assessment.verdict, .complete)
    }

    func testReservedBitsAreNeverDecodedIntoMonitors() throws {
        // Spark bit4 reserved, set in both bitmaps.
        let spark = try decodeReadiness([0x00, 0x00, 0x10, 0x10])
        XCTAssertEqual(Set(spark.monitors.keys), ECUReadiness.applicableMonitors(for: .spark))
        XCTAssertTrue(spark.monitors.values.allSatisfy { $0 == .unsupported })

        // Compression bits 2 and 4 reserved, set in both bitmaps.
        let compression = try decodeReadiness([0x00, 0x08, 0x14, 0x14])
        XCTAssertEqual(
            Set(compression.monitors.keys), ECUReadiness.applicableMonitors(for: .compression)
        )
        XCTAssertTrue(compression.monitors.values.allSatisfy { $0 == .unsupported })
    }

    // MARK: - Short data: the decoder ladder and the retained parser invariant

    func testDecoderShortDataLadder() throws {
        // < 2 bytes → invalid data, no Status at all.
        for short in [[], [UInt8(0x83)]] {
            guard case let .failure(error) = StatusDecoder().decode(data: Data(short), unit: .metric)
            else { return XCTFail("\(short.count) byte(s) must not decode") }
            guard case .invalidData = error else {
                return XCTFail("\(short.count) byte(s) must fail with .invalidData, got \(error)")
            }
        }

        // 2–3 bytes → A/B decoded, readiness nil (never "no monitors", never "complete").
        for partial: [UInt8] in [[0x83, 0x07], [0x83, 0x07, 0xEF]] {
            let status = try decodeStatus(partial)
            XCTAssertTrue(status.MIL)
            XCTAssertEqual(status.dtcCount, 3)
            XCTAssertEqual(status.ignitionType, "Spark")
            XCTAssertNil(status.readiness, "\(partial.count) bytes cannot yield readiness")
        }

        // 4 bytes → full readiness.
        let full = try decodeStatus([0x83, 0x07, 0xEF, 0x00])
        XCTAssertNotNil(full.readiness)
        XCTAssertEqual(Set(try XCTUnwrap(full.readiness).monitors.keys).count, 10)
    }

    /// The truncation invariant is **retained, not relaxed**: the parser still classifies a
    /// short positive as damage, so the decoder's middle rung is unreachable through it.
    func testParserStillTreatsTruncatedStatusPositivesAsDamage() {
        for truncated in ["7E8 02 41 01", "7E8 04 41 01 00 07", "7E8 05 41 01 00 07 EF"] {
            XCTAssertEqual(
                DTCResponseParser.parseStatus(lines: [truncated], family: .can11),
                .answered(DTCStatusResponders([ECUAddress(raw: 0x7E8): .malformed])!),
                "\(truncated) must be damage, never a decoded status"
            )
        }
        // …and damage yields no readiness anywhere.
        let assessment = assess(lines: ["7E8 02 41 01"])
        XCTAssertEqual(assessment.verdict, .undetermined(.noDecodableReadiness))
        XCTAssertEqual(assessment.undeterminedResponders, [engine])
    }

    // MARK: - `ECUReadiness` init validation

    func testReadinessInitRequiresExactlyTheApplicableKeySet() {
        func total(_ ignitionType: ECUReadiness.IgnitionType) -> [ReadinessMonitor: ReadinessMonitorState] {
            Dictionary(
                uniqueKeysWithValues: ECUReadiness.applicableMonitors(for: ignitionType)
                    .map { ($0, ReadinessMonitorState.complete) }
            )
        }

        // The exact applicable sets succeed: 3 + 7 spark, 3 + 6 compression.
        let spark = ECUReadiness(ignitionType: .spark, monitors: total(.spark))
        XCTAssertEqual(spark?.monitors.count, 10)
        let compression = ECUReadiness(ignitionType: .compression, monitors: total(.compression))
        XCTAssertEqual(compression?.monitors.count, 9)

        // A spark map carrying a compression monitor.
        var wrongNamespace = total(.spark)
        wrongNamespace[.pmFilter] = .complete
        XCTAssertNil(ECUReadiness(ignitionType: .spark, monitors: wrongNamespace))

        // A map missing a continuous monitor.
        var missingContinuous = total(.spark)
        missingContinuous[.misfire] = nil
        XCTAssertNil(ECUReadiness(ignitionType: .spark, monitors: missingContinuous))

        // A partial table (one non-continuous position dropped).
        var partialTable = total(.compression)
        partialTable[.boostPressure] = nil
        XCTAssertNil(ECUReadiness(ignitionType: .compression, monitors: partialTable))

        // A compression map built from the spark set — right count, wrong namespace.
        XCTAssertNil(ECUReadiness(ignitionType: .compression, monitors: total(.spark)))
        XCTAssertNil(ECUReadiness(ignitionType: .spark, monitors: total(.compression)))

        // Empty.
        XCTAssertNil(ECUReadiness(ignitionType: .spark, monitors: [:]))
    }

    // MARK: - `ECUReadiness` Codable boundary

    /// Mirrors `ECUReadiness`'s encoded shape so invalid payloads can be produced without a
    /// door into the type itself.
    private struct RawReadiness: Encodable {
        let ignitionType: ECUReadiness.IgnitionType
        let monitors: [ReadinessMonitor: ReadinessMonitorState]
    }

    func testReadinessCodableRejectsValuesThatFailValidation() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        func assertRejects(_ raw: RawReadiness, _ message: String) throws {
            let data = try encoder.encode(raw)
            XCTAssertThrowsError(try decoder.decode(ECUReadiness.self, from: data), message) { error in
                guard case DecodingError.dataCorrupted = error else {
                    return XCTFail("\(message): expected .dataCorrupted, got \(error)")
                }
            }
        }

        var wrongNamespace = Dictionary(
            uniqueKeysWithValues: ECUReadiness.applicableMonitors(for: .spark)
                .map { ($0, ReadinessMonitorState.complete) }
        )
        wrongNamespace[.pmFilter] = .incomplete
        try assertRejects(
            RawReadiness(ignitionType: .spark, monitors: wrongNamespace),
            "a spark payload carrying a compression monitor"
        )

        try assertRejects(
            RawReadiness(ignitionType: .spark, monitors: [.misfire: .complete]),
            "a partial map"
        )
        try assertRejects(RawReadiness(ignitionType: .compression, monitors: [:]), "an empty map")
    }

    func testValidReadinessRoundTripsThroughCodable() throws {
        for bytes in [sparkEvapIncomplete, [0x00, 0x0F, 0xEB, 0x02]] {
            let original = try decodeReadiness(bytes)
            let data = try JSONEncoder().encode(original)
            let restored = try JSONDecoder().decode(ECUReadiness.self, from: data)
            XCTAssertEqual(restored, original)
            XCTAssertEqual(restored.monitors, original.monitors)
            XCTAssertEqual(restored.ignitionType, original.ignitionType)
        }
    }

    // MARK: - Aggregation rule 0: the status read never happened

    func testStatusNotReadPreservesItsCause() {
        let expectations: [(DTCStatusReadResult, VehicleReadinessAssessment.StatusUnavailable)] = [
            // The scan skipped the read entirely.
            (.notAttempted, .notAttempted),
            // `NO DATA` — the vehicle was silent.
            (DTCResponseParser.parseStatus(lines: ["NO DATA"], family: .can11), .noResponse),
            // Bytes arrived with no recoverable responder.
            (DTCResponseParser.parseStatus(lines: ["41", "0"], family: .can11), .invalidResponse),
            (.transportFailure(.requestTimeout), .transportFailure(.requestTimeout)),
            (.transportFailure(.adapterError), .transportFailure(.adapterError))
        ]
        for (statusRead, cause) in expectations {
            let assessment = assess(statusRead)
            XCTAssertEqual(
                assessment.verdict, .undetermined(.statusNotRead(cause)),
                "\(statusRead) must preserve its cause"
            )
            XCTAssertTrue(assessment.undeterminedResponders.isEmpty, "no responder map existed")
        }
        // The cause really is distinguished, not collapsed.
        XCTAssertNotEqual(
            VehicleReadinessAssessment(statusRead: .notAttempted).verdict,
            VehicleReadinessAssessment(
                statusRead: DTCResponseParser.parseStatus(lines: ["NO DATA"], family: .can11)
            ).verdict
        )
    }

    // MARK: - Aggregation rules 1–3

    func testLoneRefusedResponderIsUndecodableReadinessWithItsAddressListed() {
        let assessment = assess(lines: ["7E9 03 7F 01 12"])
        XCTAssertEqual(
            DTCResponseParser.parseStatus(lines: ["7E9 03 7F 01 12"], family: .can11),
            .answered(DTCStatusResponders([transmission: .negativeResponse(.subFunctionNotSupported)])!)
        )
        XCTAssertEqual(assessment.verdict, .undetermined(.noDecodableReadiness))
        XCTAssertEqual(assessment.undeterminedResponders, [transmission])
    }

    /// Rule 2's boundary: all recovered evidence is complete but one responder was damaged, so
    /// the totality `.complete` requires is missing.
    func testMalformedResponderAmongAllCompleteOnesIsPartialEvidence() {
        let assessment = assess(lines: [
            statusLine(0x7E8, sparkAllComplete),
            statusLine(0x7E9, sparkAllComplete),
            "7EA 02 41 01" // damaged
        ])
        XCTAssertEqual(assessment.verdict, .undetermined(.partialEvidence))
        XCTAssertEqual(assessment.undeterminedResponders, [body])
    }

    func testMultipleRespondersAllDecodingAllCompleteIsComplete() {
        let assessment = assess(lines: [
            statusLine(0x7E8, sparkAllComplete),
            statusLine(0x7E9, sparkAllComplete),
            statusLine(0x7EA, sparkAllComplete)
        ])
        XCTAssertEqual(assessment.verdict, .complete)
        XCTAssertTrue(assessment.undeterminedResponders.isEmpty)
    }

    /// Rule 1 precedence: positive evidence of incompleteness beats the unknown responder,
    /// which is carried as a caveat rather than erasing the finding.
    func testIncompleteBeatsUndeterminedWhenAnotherResponderRefuses() {
        let assessment = assess(lines: [
            statusLine(0x7E8, sparkEvapIncomplete),
            "7E9 03 7F 01 12" // TCM refuses
        ])
        XCTAssertEqual(assessment.verdict, .incomplete(monitors: [.evaporativeSystem]))
        XCTAssertEqual(assessment.undeterminedResponders, [transmission])
    }

    func testTheIncompleteUnionIsDeduplicatedAcrossResponders() {
        let assessment = assess(lines: [
            statusLine(0x7E8, sparkEvapIncomplete),
            statusLine(0x7E9, sparkEvapIncomplete)
        ])
        XCTAssertEqual(
            assessment.verdict, .incomplete(monitors: [.evaporativeSystem]),
            "two ECUs reporting the same monitor contribute one entry"
        )
        XCTAssertTrue(assessment.undeterminedResponders.isEmpty)
    }

    /// The namespace-blind union is a decision, not an accident: a spark engine and a
    /// compression-flagged auxiliary module each decode against their own table.
    func testMixedIgnitionTypesProduceANamespaceBlindUnion() {
        let assessment = assess(lines: [
            statusLine(0x7E8, sparkEvapIncomplete),          // spark: evap incomplete
            statusLine(0x7EA, [0x00, 0x0F, 0xEB, 0x02])      // compression: NOx/SCR incomplete
        ])
        XCTAssertEqual(
            assessment.verdict,
            .incomplete(monitors: [.evaporativeSystem, .noxScrAftertreatment])
        )
        XCTAssertTrue(assessment.undeterminedResponders.isEmpty)
    }

    /// Q2: "ready because nothing is monitored" is not a claim worth rendering, and decoding
    /// *did* succeed — so neither `.complete` nor `.noDecodableReadiness`.
    func testEveryResponderSupportingZeroMonitorsIsNoSupportedMonitors() {
        let assessment = assess(lines: [
            statusLine(0x7E8, sparkNothingSupported),
            statusLine(0x7E9, sparkNothingSupported)
        ])
        XCTAssertEqual(assessment.verdict, .undetermined(.noSupportedMonitors))
        XCTAssertTrue(assessment.undeterminedResponders.isEmpty)
        XCTAssertNotEqual(assessment.verdict, .complete)
        XCTAssertNotEqual(assessment.verdict, .undetermined(.noDecodableReadiness))
    }

    /// Rule 2 runs *before* rule 3: an unknown responder alongside modules that monitor
    /// nothing must NOT become `.partialEvidence`, whose wording ("every reporting module is
    /// complete") would be vacuously false-sounding. `.noSupportedMonitors` is scoped to the
    /// decoded responders, so it composes with the unknown rather than hiding it.
    func testRespondersMonitoringNothingBeatPartialEvidenceAndStillCarryTheUnknown() {
        let assessment = assess(lines: [
            statusLine(0x7E8, sparkNothingSupported),
            "7E9 03 7F 01 12" // refused — readiness unknown
        ])
        XCTAssertEqual(assessment.verdict, .undetermined(.noSupportedMonitors))
        XCTAssertNotEqual(
            assessment.verdict, .undetermined(.partialEvidence),
            "a module that monitors nothing is not evidence that anything is complete"
        )
        XCTAssertEqual(
            assessment.undeterminedResponders, [transmission],
            "the unknown responder is carried, not swallowed by the verdict"
        )
    }

    /// One responder monitoring nothing does not sink a real complete claim from another.
    func testOneResponderMonitoringNothingAlongsideRealEvidenceStaysComplete() {
        let assessment = assess(lines: [
            statusLine(0x7E8, sparkAllComplete),
            statusLine(0x7E9, sparkNothingSupported)
        ])
        XCTAssertEqual(assessment.verdict, .complete)
    }

    /// A responder that answered positively but whose payload yielded no readiness is an
    /// unknown, exactly like a refusal — assembled directly because the parser (correctly)
    /// cannot produce a four-byte-short positive.
    func testAPositiveResponderWithoutReadinessCountsAsUndetermined() throws {
        var readinessLess = Status()
        readinessLess.dtcCount = 0
        XCTAssertNil(readinessLess.readiness)
        let complete = try decodeStatus(sparkAllComplete)

        let responders = try XCTUnwrap(DTCStatusResponders([
            engine: .responded(complete),
            transmission: .responded(readinessLess)
        ]))
        let assessment = assess(.answered(responders))
        XCTAssertEqual(assessment.verdict, .undetermined(.partialEvidence))
        XCTAssertEqual(assessment.undeterminedResponders, [transmission])
    }

    func testUndeterminedRespondersAreOrderedByAscendingAddress() {
        let assessment = assess(lines: ["7EA 02 41 01", "7E8 02 41 01", "7E9 03 7F 01 12"])
        XCTAssertEqual(assessment.undeterminedResponders, [engine, transmission, body])
    }
}

/// Compiles only while every readiness type is `Sendable`.
private func requireReadinessSendable<T: Sendable>(_: T.Type) {}
