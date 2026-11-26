//
//  OEMRequestPolicyTests.swift
//  SwiftOBD2Tests
//
//  The read-only allowlist: default deny for every target outside the table, batch shape rules,
//  the VIN identifier, the wire form, and a vocabulary audit of every string the executor can
//  send, across every allowed target and every failure path.
//

@testable import SwiftOBD2
import XCTest

final class OEMRequestPolicyTests: XCTestCase {
    // MARK: Targets

    func testOnlyTheFourTargetsAreAllowed() throws {
        XCTAssertEqual(OEMRequestPolicy.allowedTargets, [
            .standard11Bit(request: 0x7E0, response: 0x7E8),
            .standard11Bit(request: 0x7E1, response: 0x7E9),
            .bmwExtended(address: 0x12),
            .bmwExtended(address: 0x18),
        ])
        for target in OEMRequestPolicy.allowedTargets {
            XCTAssertNoThrow(try OEMRequestPolicy.validate(target: target, dataIdentifiers: [0x028D]))
        }
    }

    func testEveryOtherTargetIsDenied() {
        let denied: [OEMTarget] = [
            .standard11Bit(request: 0x7DF, response: 0x7E8), // functional
            .standard11Bit(request: 0x713, response: 0x77D), // brakes
            .standard11Bit(request: 0x70E, response: 0x778),
            .standard11Bit(request: 0x710, response: 0x77A),
            .standard11Bit(request: 0x746, response: 0x7B0),
            .standard11Bit(request: 0x7E2, response: 0x7EA),
            .standard11Bit(request: 0x7E0, response: 0x7E9), // mismatched pair
            .standard11Bit(request: 0x7E1, response: 0x7E8),
            .standard11Bit(request: 0x7E8, response: 0x7E0), // reversed
            .standard11Bit(request: 0x6F1, response: 0x612),
            .bmwExtended(address: 0x29), // DSC
            .bmwExtended(address: 0x40), // BDC
            .bmwExtended(address: 0x01),
            .bmwExtended(address: 0x10),
            .bmwExtended(address: 0x00),
            .bmwExtended(address: 0xF1),
            .bmwExtended(address: 0xFF),
        ]
        for target in denied {
            XCTAssertThrowsError(try OEMRequestPolicy.validate(target: target, dataIdentifiers: [0x028D]), "\(target)") {
                XCTAssertEqual($0 as? OEMPolicyViolation, .targetNotAllowed)
            }
        }
    }

    // MARK: Shape

    func testBatchShapeRules() {
        let target = OEMTarget.standard11Bit(request: 0x7E0, response: 0x7E8)
        XCTAssertThrowsError(try OEMRequestPolicy.validate(target: target, dataIdentifiers: [])) {
            XCTAssertEqual($0 as? OEMPolicyViolation, .emptyBatch)
        }
        XCTAssertThrowsError(try OEMRequestPolicy.validate(target: target, dataIdentifiers: [1, 2, 3, 4, 5])) {
            XCTAssertEqual($0 as? OEMPolicyViolation, .tooManyReads)
        }
        XCTAssertThrowsError(try OEMRequestPolicy.validate(target: target, dataIdentifiers: [1, 1])) {
            XCTAssertEqual($0 as? OEMPolicyViolation, .duplicateCommand)
        }
        XCTAssertThrowsError(try OEMRequestPolicy.validate(target: target, dataIdentifiers: [0x028D, 0xF190])) {
            XCTAssertEqual($0 as? OEMPolicyViolation, .identifierDenied(0xF190))
        }
        XCTAssertNoThrow(try OEMRequestPolicy.validate(target: target, dataIdentifiers: [1, 2, 3, 4]))
    }

    func testBatchInitEnforcesTheSameRules() throws {
        let vw = OEMTestCatalog.vehicle("test-vw")
        let engine = vw.commands(inModule: "engine")
        XCTAssertGreaterThanOrEqual(engine.count, 5)

        XCTAssertThrowsError(try OEMReadBatch(vehicle: vw, commands: [])) {
            XCTAssertEqual($0 as? OEMPolicyViolation, .emptyBatch)
        }
        XCTAssertThrowsError(try OEMReadBatch(vehicle: vw, commands: Array(engine.prefix(5)))) {
            XCTAssertEqual($0 as? OEMPolicyViolation, .tooManyReads)
        }
        XCTAssertThrowsError(try OEMReadBatch(vehicle: vw, commands: [engine[0], engine[0]])) {
            XCTAssertEqual($0 as? OEMPolicyViolation, .duplicateCommand)
        }
        XCTAssertThrowsError(try OEMReadBatch(vehicle: vw, commands: [engine[0], OEMTestCatalog.command("T.704E", in: "test-vw")])) {
            XCTAssertEqual($0 as? OEMPolicyViolation, .mixedModules)
        }
        XCTAssertThrowsError(try OEMReadBatch(vehicle: vw, commands: [OEMTestCatalog.command("B.4001", in: "test-bmw")])) {
            XCTAssertEqual($0 as? OEMPolicyViolation, .commandNotInVehicle)
        }
        XCTAssertThrowsError(try OEMReadBatch(vehicle: vw, commands: [OEMTestCatalog.command("O.3000", in: "test-vw")])) {
            XCTAssertEqual($0 as? OEMPolicyViolation, .targetNotAllowed)
        }
        let batch = try OEMReadBatch(vehicle: vw, commands: Array(engine.prefix(4)))
        XCTAssertEqual(batch.module.id, "engine")
        XCTAssertEqual(batch.vehicleID, "test-vw")
    }

    func testBudgetIsClampedIntoRange() throws {
        XCTAssertEqual(try OEMTestCatalog.batch("test-vw", ["E.028D"], budget: 10).budget, 2.0)
        XCTAssertEqual(try OEMTestCatalog.batch("test-vw", ["E.028D"], budget: 1.2).budget, 1.2)
        for tiny in [0, -1, .nan] as [TimeInterval] {
            let budget = try OEMTestCatalog.batch("test-vw", ["E.028D"], budget: tiny).budget
            XCTAssertTrue(budget > 0 && budget <= 2.0, "\(tiny) → \(budget)")
        }
    }

    func testVINIsDenied() {
        XCTAssertEqual(OEMRequestPolicy.deniedDataIdentifiers, [0xF190])
        for target in OEMRequestPolicy.allowedTargets {
            XCTAssertThrowsError(try OEMRequestPolicy.validate(target: target, dataIdentifiers: [0xF190]))
        }
    }

    // MARK: Wire form

    func testWireRequestIsAlwaysServiceTwentyTwoAndFourHexDigits() throws {
        let pattern = try NSRegularExpression(pattern: "^22[0-9A-F]{4}$")
        var identifiers: [UInt16] = [0, 1, 0x0F, 0x10, 0xFF, 0x100, 0x028D, 0xABCD, 0xF190, 0xFFFF]
        var generator = SystemRandomNumberGenerator()
        identifiers += (0..<500).map { _ in UInt16.random(in: .min ... .max, using: &generator) }
        for identifier in identifiers {
            let wire = OEMRequestPolicy.wireRequest(for: identifier)
            XCTAssertEqual(pattern.numberOfMatches(in: wire, range: NSRange(wire.startIndex..., in: wire)), 1, wire)
        }
        XCTAssertEqual(OEMRequestPolicy.wireRequest(for: 0x028D), "22028D")
        XCTAssertEqual(OEMRequestPolicy.wireRequest(for: 0xabcd), "22ABCD")
    }

    // MARK: Vocabulary audit

    /// Every string the executor sends, over every allowed target and every scripted path, must
    /// match this list. Nothing else is ever on the wire from the OEM path. `ATRV` and `ATDPN`
    /// are the resynchronization probes (adapter-only queries); the transport writes them, so
    /// here `ScriptedOEMChannel`'s model of it does, whenever the executor asks for a proof or
    /// sends on a dirty stream. `ATI` is never sent: its answer
    /// is the same line as the `ATZ` reset banner the addressing gate waits for.
    private static let allowedVocabulary = [
        "^ATSH 7E[01]$", "^ATSH 7DF$", "^ATSH 6F1$",
        "^ATCEA (12|18)$", "^ATCEA$", "^ATCRA 6(12|18)$", "^ATAR$",
        "^ATFCSH 6F1$", "^ATFCSD (12|18)30000A$", "^ATFCSM [01]$",
        "^ATRV$", "^ATDPN$",
        "^0100$", "^22[0-9A-F]{4}$",
    ]

    func testTheProbesAreTheOnlyAdditionsToTheVocabulary() {
        XCTAssertEqual(OEMAdapterCommand.syncProbes.map(\.command), ["ATRV", "ATDPN"])
        XCTAssertFalse(Self.allowedVocabulary.contains("^ATI$"))
        XCTAssertEqual(Self.allowedVocabulary.count, 14)
    }

    func testExecutorSendsOnlyTheAllowedVocabulary() async throws {
        let patterns = try Self.allowedVocabulary.map { try NSRegularExpression(pattern: $0) }
        func matching(_ command: String) -> [Int] {
            patterns.indices.filter {
                patterns[$0].numberOfMatches(in: command, range: NSRange(command.startIndex..., in: command)) == 1
            }
        }

        // One batch per allowed target, built from the synthetic catalog plus synthetic targets.
        let vw = OEMTestCatalog.vehicle("test-vw")
        let bmw = OEMTestCatalog.vehicle("test-bmw")
        let batches = [
            try OEMReadBatch(vehicle: vw, commands: Array(vw.commands(inModule: "engine").prefix(4))),
            try OEMReadBatch(vehicle: vw, commands: vw.commands(inModule: "transmission")),
            try OEMReadBatch(vehicle: bmw, commands: bmw.commands(inModule: "engine")),
            try OEMReadBatch(vehicle: bmw, commands: bmw.commands(inModule: "transmission")),
        ]
        XCTAssertEqual(Set(batches.map(\.module.target)), OEMRequestPolicy.allowedTargets)

        let allReads = ["22028D", "221002", "221010", "222000", "22704E", "224001", "22DA2E", "22DA23"]
        let firstReads = ["22028D", "22704E", "224001", "22DA2E"]
        let setupHeaders = ["ATSH 7E0", "ATSH 7E1", "ATSH 6F1"]
        let firstSetup = ["ATSH 7E0", "ATSH 7E1", "ATCEA 12", "ATCEA 18"]
        let lastSetup = ["ATSH 7E0", "ATSH 7E1", "ATFCSM 1"]
        let cancelPoints = ["ATSH 7E0", "ATSH 7E1", "ATCRA 612", "ATCRA 618"]
        typealias Scenario = (String, (ScriptedOEMChannel) -> Void, [Bool]?)
        let scenarios: [Scenario] = [
            ("happy", { _ in }, nil),
            ("setup question mark", { channel in for command in setupHeaders { channel.script[command] = [.lines(["?"])] } }, nil),
            ("setup silence", { channel in for command in firstSetup { channel.script[command] = [.silence] } }, nil),
            ("late setup OK, probes silent", { channel in
                for command in lastSetup { channel.script[command] = [.lines(["OK"], latency: 1.45)] }
                channel.script["ATRV"] = [.silence]
                channel.script["ATDPN"] = [.silence]
            }, nil),
            ("restore fails", { channel in channel.script["ATSH 7DF"] = [.lines(["?"]), .lines(["?"])] }, nil),
            ("restore without prompt", { channel in channel.script["ATSH 7DF"] = [.lines(["OK"], latency: 0.5), .silence] }, nil),
            ("verify fails", { channel in channel.script["0100"] = [.noData()] }, nil),
            ("verify short", { channel in channel.script["0100"] = [.lines(["7E8024100"])] }, nil),
            ("link lost", { channel in
                for wire in firstReads { channel.reads[wire] = .error(BLEManagerError.peripheralNotConnected) }
            }, nil),
            ("link lost while probing", { channel in
                for wire in firstReads { channel.reads[wire] = .silence }
                channel.script["ATRV"] = [.error(BLEManagerError.peripheralNotConnected)]
            }, nil),
            ("slow reads", { channel in
                for wire in allReads { channel.reads[wire] = .noData(latency: 0.9) }
            }, nil),
            ("read without prompt", { channel in
                for wire in firstReads { channel.reads[wire] = .lines(["7E8037F2231"], latency: 1.6) }
            }, nil),
            ("response pending across prompts", { channel in
                for wire in allReads { channel.reads[wire] = .prompts([(["7E8037F2278"], 0.05), (nil, 0.3)]) }
            }, nil),
            ("response pending forever", { channel in
                for wire in firstReads { channel.reads[wire] = .lines(["7E8037F2278"]) }
            }, nil),
            ("busy adapter swallows ATRV", { channel in
                for wire in firstReads { channel.reads[wire] = .lines(["7E8037F2231"], latency: 2.5) }
                channel.script["ATRV"] = [.interruptingBusyAdapter(.lines(["14.1V"]))]
            }, nil),
            ("probes unproven", { channel in
                for wire in firstReads { channel.reads[wire] = .silence }
                channel.script["ATRV"] = [.silence]
                channel.script["ATDPN"] = [.silence]
            }, nil),
            ("completely silent adapter", { channel in channel.fallback = { _ in .silence } }, nil),
            ("cancel during setup", { channel in
                channel.onSend = { command in
                    if cancelPoints.contains(command) { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }, nil),
            ("cancel mid-read", { channel in
                channel.onSend = { command in
                    if firstReads.contains(command) { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }, nil),
            // The stream the batch inherits is dirty: proven before setup, or nothing is written
            // but the probes.
            ("inherited dirty stream", { channel in channel.requireResynchronization() }, nil),
            ("inherited dirty stream, unproven", { channel in
                channel.requireResynchronization()
                channel.script["ATRV"] = [.silence]
                channel.script["ATDPN"] = [.silence]
            }, nil),
            ("no data after response pending", { channel in
                for wire in allReads { channel.reads[wire] = .prompts([(["7E8037F2278"], 0.05), (nil, 0.3)]) }
            }, nil),
            ("admission revoked before setup", { _ in }, [false]),
            ("admission revoked between reads", { _ in }, [true, true, false]),
        ]

        var sentAnything = 0
        var patternsUsed = Set<Int>()
        for batch in batches {
            for (name, configure, admissionAnswers) in scenarios {
                let channel = ScriptedOEMChannel()
                configure(channel)
                let admission = admissionAnswers.map { OEMAdmissionScript($0).admission }
                let result = await runOEMBatch(batch, on: channel, admission: admission)
                XCTAssertEqual(result.reads.count, batch.commands.count)
                for command in channel.commands {
                    sentAnything += 1
                    let matches = matching(command)
                    XCTAssertFalse(matches.isEmpty, "\(batch.module.target) \(name): sent \(command)")
                    patternsUsed.formUnion(matches)
                    let compact = command.replacingOccurrences(of: " ", with: "").uppercased()
                    XCTAssertFalse(compact == "ATI", command)
                    XCTAssertFalse(compact.hasPrefix("ATD") && compact != "ATDPN", command)
                    XCTAssertFalse(compact.hasPrefix("ATZ"), command)
                    XCTAssertFalse(compact.hasPrefix("ATWS"), command)
                    XCTAssertFalse(compact.hasPrefix("ATSP"), command)
                    XCTAssertFalse(compact.hasPrefix("ATST"), command)
                    XCTAssertFalse(compact.hasPrefix("ATAT"), command)
                    XCTAssertFalse(compact.hasPrefix("ATPP"), command)
                }
            }
        }
        XCTAssertGreaterThan(sentAnything, 300)
        // The scenarios reach every entry, the probes included.
        XCTAssertEqual(
            patternsUsed, Set(patterns.indices),
            "never exercised: \(Set(patterns.indices).subtracting(patternsUsed).map { Self.allowedVocabulary[$0] })"
        )
    }
}
