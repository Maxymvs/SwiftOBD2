//
//  OEMCatalogLoaderTests.swift
//  SwiftOBD2Tests
//
//  "Every fmt field is supported, or the command is rejected": one test per rejection rule, the
//  structural errors that throw, and the bundled catalog loading cleanly.
//

@testable import SwiftOBD2
import XCTest

final class OEMCatalogLoaderTests: XCTestCase {
    // MARK: Helpers

    private static let validSignal: [String: Any] = [
        "id": "SIG", "name": "Signal", "path": "Engine",
        "fmt": ["len": 8, "max": 255, "unit": "scalar"] as [String: Any],
    ]

    private static func validCommand() -> [String: Any] {
        [
            "id": "E.1234", "module": "engine", "did": "1234", "freq": 1, "fcm1": false,
            "evidence": "catalog", "replyLengths": [1], "signals": [validSignal],
        ]
    }

    private static let engineModule: [String: Any] = [
        "id": "engine", "name": "Engine", "servedByDefault": true,
        "target": ["kind": "standard11Bit", "request": "7E0", "response": "7E8"],
    ]

    private static func catalogJSON(commands: [[String: Any]], modules: [[String: Any]] = [engineModule]) -> [String: Any] {
        [
            "formatVersion": 1, "license": "CC BY-SA 4.0", "licenseURL": "https://example.invalid",
            "attribution": "test", "changes": "synthetic",
            "vehicles": [[
                "id": "v", "make": "Make", "model": "Model", "modelYear": 2020,
                "source": [
                    "repository": "r", "commit": String(repeating: "a", count: 40), "url": "u",
                    "signalset": "s", "support": "t",
                ],
                "modules": modules,
                "commands": commands,
            ] as [String: Any]],
        ]
    }

    private func load(_ object: [String: Any]) throws -> OEMCatalog {
        try OEMCatalog(data: JSONSerialization.data(withJSONObject: object))
    }

    /// Loads one command and returns why it was rejected (nil when accepted).
    private func rejection(_ command: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws
        -> OEMCatalogRejection.Reason? {
        let catalog = try load(Self.catalogJSON(commands: [command]))
        XCTAssertEqual(catalog.vehicles[0].commands.count + catalog.rejectedCommands.count, 1, file: file, line: line)
        return catalog.rejectedCommands.first?.reason
    }

    private func command(fmt changes: [String: Any?]) -> [String: Any] {
        var fmt = Self.validSignal["fmt"] as! [String: Any]
        for (key, value) in changes { fmt[key] = value }
        var signal = Self.validSignal
        signal["fmt"] = fmt
        var command = Self.validCommand()
        command["signals"] = [signal]
        return command
    }

    // MARK: Accepted

    func testValidCommandLoadsWithOBDbDefaults() throws {
        let catalog = try load(Self.catalogJSON(commands: [Self.validCommand()]))
        XCTAssertTrue(catalog.rejectedCommands.isEmpty)
        let command = try XCTUnwrap(catalog.vehicles.first?.commands.first)
        XCTAssertEqual(command.dataIdentifier, 0x1234)
        XCTAssertEqual(command.evidence, .catalog)
        XCTAssertFalse(command.usesFlowControl)
        let format = command.signals[0].format
        XCTAssertEqual(format.bitOffset, 0)
        XCTAssertFalse(format.isLittleEndian)
        XCTAssertFalse(format.isSigned)
        XCTAssertEqual(format.multiplier, 1)
        XCTAssertEqual(format.divisor, 1)
        XCTAssertEqual(format.offset, 0)
        XCTAssertEqual(format.minimum, 0)
        XCTAssertNil(format.nullMinimum)
        XCTAssertNil(format.enumeration)
    }

    func testEveryFormatFieldIsRead() throws {
        let command = command(fmt: [
            "bix": 4, "len": 12, "blsb": true, "sign": true, "mul": 2, "div": 5, "add": -1.5,
            "min": -100, "max": 100, "unit": "volts", "nullmin": -99, "nullmax": 99,
        ])
        let format = try XCTUnwrap(try load(Self.catalogJSON(commands: [command])).vehicles[0].commands.first?.signals[0].format)
        XCTAssertEqual(format.bitOffset, 4)
        XCTAssertEqual(format.bitLength, 12)
        XCTAssertTrue(format.isLittleEndian)
        XCTAssertTrue(format.isSigned)
        XCTAssertEqual(format.multiplier, 2)
        XCTAssertEqual(format.divisor, 5)
        XCTAssertEqual(format.offset, -1.5)
        XCTAssertEqual(format.minimum, -100)
        XCTAssertEqual(format.maximum, 100)
        XCTAssertEqual(format.unit, "volts")
        XCTAssertEqual(format.nullMinimum, -99)
        XCTAssertEqual(format.nullMaximum, 99)
    }

    func testMapWithoutUnitOrMaxIsAccepted() throws {
        let command = command(fmt: [
            "unit": nil, "max": nil,
            "map": ["1": ["description": "On", "value": "ON"], "2": "OFF"] as [String: Any],
        ])
        XCTAssertNil(try rejection(command))
        let format = try load(Self.catalogJSON(commands: [command])).vehicles[0].commands[0].signals[0].format
        XCTAssertEqual(format.enumeration?[1], OEMEnumerationValue(value: "ON", description: "On"))
        XCTAssertEqual(format.enumeration?[2], OEMEnumerationValue(value: "OFF", description: "OFF"))
    }

    // MARK: Rejection rules

    func testUnknownFormatKeyRejects() throws {
        XCTAssertEqual(try rejection(command(fmt: ["omin": 1])), .unknownFormatKey("omin"))
    }

    func testUnknownSignalKeyRejects() throws {
        var signal = Self.validSignal
        signal["hidden"] = true
        var command = Self.validCommand()
        command["signals"] = [signal]
        XCTAssertEqual(try rejection(command), .unknownSignalKey("hidden"))
    }

    func testUnknownCommandKeyRejects() throws {
        var command = Self.validCommand()
        command["tmo"] = "FF"
        XCTAssertEqual(try rejection(command), .unknownCommandKey("tmo"))
    }

    func testDataIdentifierMustBeFourHexDigits() throws {
        for did in ["28D", "0028D", "02G1", "", " 28D"] {
            var command = Self.validCommand()
            command["did"] = did
            let reason = try rejection(command)
            XCTAssertTrue(reason == .invalidDataIdentifier || reason == .invalidField("did"), "\(did): \(String(describing: reason))")
        }
        var numeric = Self.validCommand()
        numeric["did"] = 1234
        XCTAssertEqual(try rejection(numeric), .invalidField("did"))
    }

    func testVINIdentifierIsRejected() throws {
        for did in ["F190", "f190"] {
            var command = Self.validCommand()
            command["did"] = did
            XCTAssertEqual(try rejection(command), .deniedDataIdentifier)
        }
    }

    func testBitLayoutBounds() throws {
        XCTAssertEqual(try rejection(command(fmt: ["len": 0])), .invalidBitLayout)
        XCTAssertEqual(try rejection(command(fmt: ["len": 65])), .invalidBitLayout)
        XCTAssertEqual(try rejection(command(fmt: ["len": nil])), .invalidBitLayout)
        XCTAssertEqual(try rejection(command(fmt: ["bix": -1])), .invalidBitLayout)
        XCTAssertNil(try rejection(command(fmt: ["len": 64, "max": 1])))
    }

    func testZeroDivisorRejects() throws {
        XCTAssertEqual(try rejection(command(fmt: ["div": 0])), .zeroDivisor)
    }

    func testUnknownModuleRejects() throws {
        var command = Self.validCommand()
        command["module"] = "brakes"
        XCTAssertEqual(try rejection(command), .unknownModule)
    }

    func testCommandWithoutSignalsRejects() throws {
        var empty = Self.validCommand()
        empty["signals"] = [Any]()
        XCTAssertEqual(try rejection(empty), .noSignals)
        var missing = Self.validCommand()
        missing["signals"] = nil
        XCTAssertEqual(try rejection(missing), .noSignals)
    }

    func testMissingMaxRejectsScaledSignals() throws {
        XCTAssertEqual(try rejection(command(fmt: ["max": nil])), .missingMaximum)
    }

    func testMissingUnitRejectsScaledSignals() throws {
        XCTAssertEqual(try rejection(command(fmt: ["unit": nil])), .missingUnit)
    }

    func testMistypedFieldsReject() throws {
        XCTAssertEqual(try rejection(command(fmt: ["blsb": 1])), .invalidField("blsb"))
        XCTAssertEqual(try rejection(command(fmt: ["len": true])), .invalidField("len"))
        XCTAssertEqual(try rejection(command(fmt: ["len": 8.5])), .invalidField("len"))
        XCTAssertEqual(try rejection(command(fmt: ["mul": "2"])), .invalidField("mul"))
        XCTAssertEqual(try rejection(command(fmt: ["map": ["x": "ON"]])), .invalidField("map"))
        XCTAssertEqual(try rejection(command(fmt: ["map": ["1": ["value": "ON", "extra": 1] as [String: Any]]])), .invalidField("map"))
        var evidence = Self.validCommand()
        evidence["evidence"] = "rumor"
        XCTAssertEqual(try rejection(evidence), .invalidField("evidence"))
        var lengths = Self.validCommand()
        lengths["replyLengths"] = [-1]
        XCTAssertEqual(try rejection(lengths), .invalidField("replyLengths"))
    }

    func testOneBadCommandDoesNotTakeTheOthersWithIt() throws {
        var bad = Self.validCommand()
        bad["id"] = "E.BAD"
        bad["did"] = "F190"
        let catalog = try load(Self.catalogJSON(commands: [Self.validCommand(), bad]))
        XCTAssertEqual(catalog.vehicles[0].commands.map(\.id), ["E.1234"])
        XCTAssertEqual(catalog.rejectedCommands, [OEMCatalogRejection(vehicleID: "v", commandID: "E.BAD", reason: .deniedDataIdentifier)])
    }

    func testDuplicateCommandIDRejectsTheSecond() throws {
        let catalog = try load(Self.catalogJSON(commands: [Self.validCommand(), Self.validCommand()]))
        XCTAssertEqual(catalog.vehicles[0].commands.count, 1)
        XCTAssertEqual(catalog.rejectedCommands.first?.reason, .duplicateCommand)
    }

    // MARK: Structural errors throw

    func testMalformedTopLevelThrows() {
        XCTAssertThrowsError(try OEMCatalog(data: Data("[]".utf8)))
        XCTAssertThrowsError(try OEMCatalog(data: Data("not json".utf8)))
        var wrongVersion = Self.catalogJSON(commands: [])
        wrongVersion["formatVersion"] = 2
        XCTAssertThrowsError(try load(wrongVersion)) { XCTAssertEqual($0 as? OEMCatalogError, .unsupportedFormatVersion) }
        var missingLicense = Self.catalogJSON(commands: [])
        missingLicense["license"] = nil
        XCTAssertThrowsError(try load(missingLicense))
    }

    func testUnknownTargetKindThrows() {
        var module = Self.engineModule
        module["target"] = ["kind": "kLine", "request": "7E0", "response": "7E8"]
        XCTAssertThrowsError(try load(Self.catalogJSON(commands: [], modules: [module])))
    }

    func testNonHexIdsThrow() {
        for ids in [("7G0", "7E8"), ("7E0", "7E"), ("7E0", "FFF"), ("7E0", "7E0")] {
            var module = Self.engineModule
            module["target"] = ["kind": "standard11Bit", "request": ids.0, "response": ids.1]
            XCTAssertThrowsError(try load(Self.catalogJSON(commands: [], modules: [module])), "\(ids)")
        }
    }

    func testBMWResponseMustBeSixPlusAddress() {
        for (address, request, response) in [("18", "6F1", "612"), ("18", "6F0", "618"), ("1G", "6F1", "61G"), ("018", "6F1", "618")] {
            var module = Self.engineModule
            module["target"] = ["kind": "bmwExtended", "address": address, "request": request, "response": response]
            XCTAssertThrowsError(try load(Self.catalogJSON(commands: [], modules: [module])), "\(address) \(response)")
        }
        var good = Self.engineModule
        good["target"] = ["kind": "bmwExtended", "address": "18", "request": "6F1", "response": "618"]
        XCTAssertEqual(try load(Self.catalogJSON(commands: [], modules: [good])).vehicles[0].modules[0].target, .bmwExtended(address: 0x18))
    }

    func testUnknownModuleKeyThrows() {
        var module = Self.engineModule
        module["session"] = "03"
        XCTAssertThrowsError(try load(Self.catalogJSON(commands: [], modules: [module])))
    }

    // MARK: Bundled catalog

    func testBundledCatalogLoadsCleanly() throws {
        let catalog = try OEMCatalog(data: oemFixture("OEMCatalog"))
        XCTAssertEqual(catalog.formatVersion, 1)
        XCTAssertEqual(catalog.rejectedCommands, [], "Rejected: \(catalog.rejectedCommands)")
        XCTAssertEqual(catalog.vehicles.count, 2)
        XCTAssertFalse(catalog.license.isEmpty)
        XCTAssertFalse(catalog.attribution.isEmpty)

        for vehicle in catalog.vehicles {
            XCTAssertTrue(
                vehicle.source.commit.count == 40 && vehicle.source.commit.allSatisfy { $0.isASCII && $0.isHexDigit },
                "\(vehicle.id) commit \(vehicle.source.commit)"
            )
            XCTAssertFalse(vehicle.commands.isEmpty, vehicle.id)
            for command in vehicle.commands {
                let module = try XCTUnwrap(vehicle.module(id: command.moduleID), command.id)
                XCTAssertNoThrow(
                    try OEMRequestPolicy.validate(target: module.target, dataIdentifiers: [command.dataIdentifier]),
                    command.id
                )
                XCTAssertNoThrow(try OEMReadBatch(vehicle: vehicle, commands: [command]), command.id)
            }
            for module in vehicle.modules {
                XCTAssertEqual(vehicle.commands(inModule: module.id).allSatisfy { $0.moduleID == module.id }, true)
            }
        }
        print("OEM catalog: " + catalog.vehicles.map { "\($0.id) \($0.commands.count) commands" }.joined(separator: ", "))
    }
}
