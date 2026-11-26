//
//  OEMGoldenFixtureTests.swift
//  SwiftOBD2Tests
//
//  OBDb's own per-vehicle test cases, run through this package's reply parser and decoder.
//  The expected values come from OBDb's reference decoder, so a mismatch is a semantic
//  difference, not a matter of taste.
//

@testable import SwiftOBD2
import XCTest

final class OEMGoldenFixtureTests: XCTestCase {
    private struct Fixtures: Decodable {
        let vehicles: [Vehicle]

        struct Vehicle: Decodable {
            let id: String
            let cases: [Case]
        }

        struct Case: Decodable {
            let command: String
            let response: [String]
            let expected: [String: Expected]
        }

        enum Expected: Decodable {
            case number(Double)
            case text(String)

            init(from decoder: Swift.Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self = .text(text)
                } else {
                    self = .number(try container.decode(Double.self))
                }
            }
        }
    }

    /// Cases this stricter parser refuses on purpose, keyed by vehicle and command, with why.
    /// Every entry must actually be refused; nothing else may be.
    private let knownRefusals: [String: [String: OEMReadOutcome]] = [:]

    /// A reading OBDb clamps to its signal's `[min, max]` edge and production must refuse.
    private struct ExpectedRefusal {
        let vehicle: String
        let caseIndex: Int
        let command: String
        let signal: String
        /// The signal's bits, sign applied.
        let raw: Int
        /// The scaled reading before OBDb's clamp.
        let value: Double
        let minimum: Double
        let maximum: Double

        var key: String { "\(vehicle) case \(caseIndex) \(command) \(signal)" }
    }

    /// Every golden value outside its signal's range, computed **without** the Swift decoder by
    /// `Fixtures/OEM/golden_refusals.py` (an independent re-implementation of OBDb's format that
    /// also reproduces all 991 of OBDb's recorded values). Regenerate with
    /// `python3 -I Tests/SwiftOBD2Tests/Fixtures/OEM/golden_refusals.py Tests/SwiftOBD2Tests/Fixtures/OEM`
    /// and paste its output here. Production must refuse exactly these and deliver the rest.
    private let expectedRefusals: [ExpectedRefusal] = [
        .init(vehicle: "vw-tiguan-2020", caseIndex: 256, command: "7E0.7E8.22121C", signal: "TIGUAN_AIR_FILLING", raw: 6019, value: 141.073322, minimum: 0, maximum: 100),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 467, command: "7E0.7E8.2216EE", signal: "TIGUAN_BOOST_P_ACTUATOR_CMD", raw: 13107, value: 159.9947687688, minimum: -399.993, maximum: 100),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 578, command: "7E0.7E8.2239FC", signal: "TIGUAN_BYPASS_VLV_HIGH_P_ACT", raw: 8194, value: 100.0244140625, minimum: -400, maximum: 100),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 707, command: "7E1.7E9.221062", signal: "TIGUAN_PQ35_CLUTCH_1_FRICTION_VALUE_CORRECTION_FACTOR", raw: 1024, value: 100.00384, minimum: 0, maximum: 100),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 860, command: "7E1.7E9.22385A", signal: "TIGUAN_MQB_DQ250_ACUTAL_POS_GEAR_POSER_B", raw: -246, value: -2.46, minimum: 0, maximum: 327.67),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 861, command: "7E1.7E9.22385A", signal: "TIGUAN_MQB_DQ250_ACUTAL_POS_GEAR_POSER_B", raw: -6, value: -0.06, minimum: 0, maximum: 327.67),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 863, command: "7E1.7E9.223862", signal: "TIGUAN_MQB_DQ250_ACUTAL_POS_GEAR_POSER_C", raw: -1, value: -0.01, minimum: 0, maximum: 327.67),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 867, command: "7E1.7E9.223871", signal: "TIGUAN_MQB_DQ250_SPECIFIED_IDLE_RPM", raw: 10240, value: 10240.0, minimum: 0, maximum: 7000),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 868, command: "7E1.7E9.223871", signal: "TIGUAN_MQB_DQ250_SPECIFIED_IDLE_RPM", raw: 17920, value: 17920.0, minimum: 0, maximum: 7000),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 869, command: "7E1.7E9.223871", signal: "TIGUAN_MQB_DQ250_SPECIFIED_IDLE_RPM", raw: 20480, value: 20480.0, minimum: 0, maximum: 7000),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 870, command: "7E1.7E9.223871", signal: "TIGUAN_MQB_DQ250_SPECIFIED_IDLE_RPM", raw: 46080, value: 46080.0, minimum: 0, maximum: 7000),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 871, command: "7E1.7E9.223871", signal: "TIGUAN_MQB_DQ250_SPECIFIED_IDLE_RPM", raw: 29185, value: 29185.0, minimum: 0, maximum: 7000),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 872, command: "7E1.7E9.223871", signal: "TIGUAN_MQB_DQ250_SPECIFIED_IDLE_RPM", raw: 47105, value: 47105.0, minimum: 0, maximum: 7000),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 873, command: "7E1.7E9.223871", signal: "TIGUAN_MQB_DQ250_SPECIFIED_IDLE_RPM", raw: 40450, value: 40450.0, minimum: 0, maximum: 7000),
        .init(vehicle: "vw-tiguan-2020", caseIndex: 874, command: "7E1.7E9.223871", signal: "TIGUAN_MQB_DQ250_SPECIFIED_IDLE_RPM", raw: 54275, value: 54275.0, minimum: 0, maximum: 7000),
    ]

    /// OBDb's reference clamps a value outside `[min, max]` to the nearest edge and reports the
    /// edge. Production refuses such a value (`.outOfRange`), because the edge isn't a reading.
    /// So every expected value is one of two things, decided by `expectedRefusals` (computed
    /// without the Swift decoder): listed, so it must be **refused** as `.outOfRange` whose clamp
    /// matches OBDb's value, or not listed, so it must be **delivered** exactly. A value that
    /// should have been delivered but was refused fails, and so does the reverse.
    func testEveryGoldenCaseDecodesToOBDbsValue() throws {
        let catalog = try OEMCatalog(data: oemFixture("OEMCatalog"))
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: oemFixture("OEMGoldenFixtures"))
        XCTAssertFalse(fixtures.vehicles.isEmpty)

        let refusalsByKey = Dictionary(uniqueKeysWithValues: expectedRefusals.map { ($0.key, $0) })
        XCTAssertEqual(refusalsByKey.count, 15, "the independent table lists 15 distinct refusals")

        var summary: [String] = []
        var totalExpected = 0
        var totalDelivered = 0
        var totalRefused = 0
        for fixtureVehicle in fixtures.vehicles {
            let vehicle = try XCTUnwrap(catalog.vehicle(id: fixtureVehicle.id), "No catalog vehicle \(fixtureVehicle.id)")
            var casesChecked = 0
            var expectedValues = 0
            var delivered = 0
            var refusedOutOfRange: Set<String> = []
            var listedRefusals = 0

            for (index, testCase) in fixtureVehicle.cases.enumerated() {
                let label = "\(vehicle.id) case \(index) \(testCase.command)"
                let command = try XCTUnwrap(vehicle.commands.first { $0.id == testCase.command }, "\(label): unknown command")
                let module = try XCTUnwrap(vehicle.module(id: command.moduleID), label)
                let outcome = OEMReply.outcome(lines: testCase.response, target: module.target, command: command)

                if let refusal = knownRefusals[vehicle.id]?[testCase.command] {
                    XCTAssertEqual(outcome, refusal, "\(label): expected the listed refusal")
                    listedRefusals += 1
                    continue
                }
                guard case let .values(values) = outcome else {
                    XCTFail("\(label): \(outcome) for \(testCase.response)")
                    continue
                }
                casesChecked += 1

                for (signalID, expected) in testCase.expected {
                    expectedValues += 1
                    let key = "\(label) \(signalID)"
                    let signal = try XCTUnwrap(command.signals.first { $0.id == signalID }, "\(key): unknown signal")
                    guard let decoded = values.first(where: { $0.signalID == signalID })?.value else {
                        XCTFail("\(key): no value")
                        continue
                    }
                    switch expected {
                    case let .text(want):
                        XCTAssertEqual(decoded, .text(want), key)
                        if decoded == .text(want) { delivered += 1 }
                    case let .number(want):
                        if let refusal = refusalsByKey[key] {
                            // The table's range is the catalog's, and OBDb's value is its clamp.
                            XCTAssertEqual(signal.format.minimum, refusal.minimum, "\(key): minimum")
                            XCTAssertEqual(signal.format.maximum, refusal.maximum, "\(key): maximum")
                            let edge = Swift.max(refusal.minimum, Swift.min(refusal.value, refusal.maximum))
                            XCTAssertEqual(want, edge, accuracy: 1e-5, "\(key): OBDb's clamp")
                            guard case let .outOfRange(clamped) = decoded else {
                                XCTFail("\(key): raw \(refusal.raw) reads \(refusal.value), outside "
                                    + "[\(refusal.minimum), \(refusal.maximum)], so it must be refused; decoded \(decoded)")
                                continue
                            }
                            XCTAssertEqual(clamped, edge, accuracy: 1e-5, "\(key): refusal's clamp")
                            refusedOutOfRange.insert(key)
                        } else {
                            guard case let .number(got) = decoded else {
                                XCTFail("\(key): expected \(want) to be delivered, decoded \(decoded)")
                                continue
                            }
                            XCTAssertEqual(got, want, accuracy: 1e-5, key)
                            if abs(got - want) <= 1e-5 { delivered += 1 }
                        }
                    }
                }
            }

            // Delivered and refused account for every expected value, and the refusals are
            // exactly the independently computed out-of-range set.
            let listed = Set(expectedRefusals.filter { $0.vehicle == vehicle.id }.map(\.key))
            XCTAssertEqual(refusedOutOfRange, listed, vehicle.id)
            XCTAssertEqual(delivered + refusedOutOfRange.count, expectedValues, "\(vehicle.id): delivered + refused")
            print(
                "OEM golden \(vehicle.id): \(casesChecked) cases, \(expectedValues) expected values: "
                    + "\(delivered) delivered, \(refusedOutOfRange.count) refused as out of range, "
                    + "\(listedRefusals) listed refusals"
            )
            summary.append("\(vehicle.id)=\(delivered) delivered/\(refusedOutOfRange.count) refused")
            totalExpected += expectedValues
            totalDelivered += delivered
            totalRefused += refusedOutOfRange.count
            XCTAssertGreaterThan(casesChecked, 0, vehicle.id)
            XCTAssertGreaterThan(delivered, 0, vehicle.id)
        }
        XCTAssertEqual(totalDelivered + totalRefused, totalExpected)
        XCTAssertEqual(totalExpected, 991)
        XCTAssertEqual(totalDelivered, 976)
        XCTAssertEqual(totalRefused, 15)
        print(
            "OEM golden totals: \(totalExpected) expected values, \(totalDelivered) delivered, "
                + "\(totalRefused) refused as out of range (" + summary.joined(separator: ", ") + ")"
        )
    }
}
