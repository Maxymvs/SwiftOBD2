//
//  OBDOwedAnswerTrackerTests.swift
//  SwiftOBD2Tests
//
//  `OBDOwedAnswerTracker`: whether some responder still owes its final answer, from the lines of
//  one exchange. Every layout the adapter prints with headers on and spaces off, ISO-TP per
//  responder, the echo rule, and the bias: ordinary complete traffic is never owed, anything
//  doubtful is. Synthetic data.
//

@testable import SwiftOBD2
import XCTest

final class OBDOwedAnswerTrackerTests: XCTestCase {
    // MARK: Helpers

    private func isOwed(_ command: String?, batches: [[String]], allowLegacyFraming: Bool) -> Bool {
        var tracker = OBDOwedAnswerTracker(command: command)
        for batch in batches {
            tracker.consume(batch, allowLegacyFraming: allowLegacyFraming)
        }
        return tracker.isOwed
    }

    /// All lines in one response, and again one response per line: the answer must not depend on
    /// how the lines were split into listen windows.
    private func assertOwed(
        _ expected: Bool,
        _ command: String?,
        _ lines: [String],
        _ message: String = "",
        allowLegacyFraming: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(isOwed(command, batches: [lines], allowLegacyFraming: allowLegacyFraming),
                       expected, "one response: \(message) \(lines)", file: file, line: line)
        XCTAssertEqual(isOwed(command, batches: lines.map { [$0] }, allowLegacyFraming: allowLegacyFraming),
                       expected, "one line per response: \(message) \(lines)", file: file, line: line)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    private enum Layout: String, CaseIterable {
        case can11, can11Extended, can29, legacy

        /// One message as a single line from responder 0 or 1.
        func line(_ message: [UInt8], from responder: Int = 0) -> String {
            switch self {
            case .can11:
                return ["7E8", "7E9"][responder] + OBDOwedAnswerTrackerTests.hex([UInt8(message.count)] + message)
            case .can11Extended:
                return ["618", "640"][responder] + "F1" + OBDOwedAnswerTrackerTests.hex([UInt8(message.count)] + message)
            case .can29:
                return ["18DAF110", "18DAF118"][responder] + OBDOwedAnswerTrackerTests.hex([UInt8(message.count)] + message)
            case .legacy:
                let bytes: [UInt8] = [0x48, 0x6B, [0x10, 0x18][responder]] + message
                let check = UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 + Int($1) })
                return OBDOwedAnswerTrackerTests.hex(bytes + [check])
            }
        }
    }

    // Messages.
    private static let pending19: [UInt8] = [0x7F, 0x19, 0x78]
    private static let final5902: [UInt8] = [0x59, 0x02, 0xFF, 0x01, 0x23, 0x45]
    private static let refusal19: [UInt8] = [0x7F, 0x19, 0x31]
    private static let refusal22: [UInt8] = [0x7F, 0x22, 0x31]
    private static let positive22: [UInt8] = [0x62, 0xF1, 0x90, 0x41]
    private static let positive5901: [UInt8] = [0x59, 0x01, 0xFF, 0x01, 0x00, 0x03]
    private static let pending22: [UInt8] = [0x7F, 0x22, 0x78]
    private static let final62F190: [UInt8] = [0x62, 0xF1, 0x90, 0x41, 0x42]
    private static let wrong62F191: [UInt8] = [0x62, 0xF1, 0x91, 0x41, 0x42]

    // MARK: The spec's own example lines

    func testTheSpecsExampleLinesParseAsPending() {
        XCTAssertEqual(Layout.can11Extended.line(Self.pending19), "618F1037F1978")
        XCTAssertEqual(Layout.can29.line([0x7F, 0x03, 0x78]), "18DAF110037F0378")
        XCTAssertTrue(Layout.legacy.line([0x7F, 0x03, 0x78]).hasPrefix("486B107F0378"))
        for line in ["7E8037F0378", "618F1037F1978", "18DAF110037F0378"] {
            assertOwed(true, nil, [line])
        }
        assertOwed(true, nil, [Layout.legacy.line([0x7F, 0x03, 0x78])], allowLegacyFraming: true)
    }

    // MARK: Every layout

    private struct Case {
        let name: String
        let command: String
        let messages: [(bytes: [UInt8], responder: Int)]
        let owed: Bool
    }

    private static let layoutCases: [Case] = [
        Case(name: "pending", command: "1902FF", messages: [(pending19, 0)], owed: true),
        Case(name: "pending + matching final", command: "1902FF", messages: [(pending19, 0), (final5902, 0)], owed: false),
        Case(name: "pending + terminal refusal", command: "1902FF", messages: [(pending19, 0), (refusal19, 0)], owed: false),
        Case(name: "pending + refusal of another service", command: "1902FF", messages: [(pending19, 0), (refusal22, 0)], owed: true),
        Case(name: "pending + positive of another service", command: "1902FF", messages: [(pending19, 0), (positive22, 0)], owed: true),
        Case(name: "pending + wrong echo 59 01", command: "1902FF", messages: [(pending19, 0), (positive5901, 0)], owed: true),
        Case(name: "pending + another responder's final", command: "1902FF", messages: [(pending19, 0), (final5902, 1)], owed: true),
        Case(name: "two pendings then one final", command: "1902FF", messages: [(pending19, 0), (pending19, 0), (final5902, 0)], owed: false),
        Case(name: "pending + wrong echo 62 F1 91", command: "22F190", messages: [(pending22, 0), (wrong62F191, 0)], owed: true),
        Case(name: "pending + 62 F1 90", command: "22F190", messages: [(pending22, 0), (final62F190, 0)], owed: false),
        Case(name: "both pending, one final", command: "1902FF", messages: [(pending19, 0), (pending19, 1), (final5902, 0)], owed: true),
        Case(name: "both pending, both final", command: "1902FF", messages: [(pending19, 0), (pending19, 1), (final5902, 1), (final5902, 0)], owed: false),
        Case(name: "both pending, one final one refusal", command: "1902FF", messages: [(pending19, 0), (pending19, 1), (refusal19, 1), (final5902, 0)], owed: false),
        Case(name: "final before pending", command: "1902FF", messages: [(final5902, 0), (pending19, 0)], owed: true),
        Case(name: "refusal without pending", command: "1902FF", messages: [(refusal19, 0)], owed: false),
        Case(name: "pending + final + pending again", command: "1902FF", messages: [(pending19, 0), (final5902, 0), (pending19, 0)], owed: true),
    ]

    func testEveryLayout() {
        for layout in Layout.allCases {
            for testCase in Self.layoutCases {
                let lines = testCase.messages.map { layout.line($0.bytes, from: $0.responder) }
                assertOwed(testCase.owed, testCase.command, lines, "\(layout.rawValue): \(testCase.name)",
                           allowLegacyFraming: layout == .legacy)
            }
        }
    }

    /// The pending's responder key includes the `F1` of extended addressing, and the legacy key is
    /// the source address only.
    func testResponderKeys() {
        // 11-bit `618` with and without extended addressing are different responders.
        assertOwed(true, "1902FF", ["618F1037F1978", "618065902FF012345"])
        // Legacy: the same source behind a different target byte is the same responder.
        let pending = Layout.legacy.line(Self.pending19)
        var final = Layout.legacy.line(Self.final5902)
        final = "48" + "6A" + final.dropFirst(4)
        assertOwed(false, "1902FF", [pending, final], allowLegacyFraming: true)
        // 29-bit: `18DA` and `18DB` with the same tail are different ids.
        assertOwed(true, "1902FF", ["18DAF110037F1978", "18DBF110065902FF012345"])
    }

    // MARK: Multi-frame

    private static let firstFrame = "7E8100B5902FF010203"
    private static let consecutive = "7E82149494949494949"
    private static let vin = ["7E81014490201494949", "7E82149494949494949", "7E82249494949494949"]

    func testAFirstFrameOnlyIsOwed() {
        assertOwed(true, "1902FF", [Self.firstFrame])
        assertOwed(true, "0902", [Self.vin[0]])
        assertOwed(true, nil, [Self.firstFrame])
    }

    func testAFirstFrameAndAllItsConsecutiveFramesIsNotOwed() {
        assertOwed(false, "1902FF", [Self.firstFrame, Self.consecutive])
    }

    func testOneConsecutiveFrameMissingIsOwed() {
        assertOwed(true, "0902", [Self.vin[0], Self.vin[1]])
        assertOwed(true, "0902", [Self.vin[0], Self.vin[2]])
    }

    func testACompleteVINReplyIsNotOwed() {
        assertOwed(false, "0902", Self.vin)
        assertOwed(false, nil, Self.vin)
        // With the spaces a log shows.
        assertOwed(false, "09 02", Self.vin.map { line in
            String(line.prefix(3)) + " " + stride(from: 3, to: line.count, by: 2).map { offset -> String in
                let start = line.index(line.startIndex, offsetBy: offset)
                return String(line[start ..< line.index(start, offsetBy: 2)])
            }.joined(separator: " ")
        })
    }

    func testTwoRespondersMultiFrameRepliesInterleaved() {
        let engine = Self.vin
        let transmission = ["7E910144902014F4F4F", "7E9214F4F4F4F4F4F4F", "7E9224F4F4F4F4F4F4F"]
        assertOwed(false, "0902", [engine[0], transmission[0], engine[1], transmission[1], engine[2], transmission[2]])
        assertOwed(false, "0902", [transmission[0], engine[0], engine[1], transmission[1], transmission[2], engine[2]])
        assertOwed(true, "0902", [engine[0], transmission[0], engine[1], transmission[1], engine[2]], "the transmission's last frame is missing")
        // A consecutive frame from one responder doesn't advance another's message.
        assertOwed(true, "0902", [engine[0], transmission[1], transmission[2]])
    }

    /// BMW extended addressing: the frame after `F1` is 7 bytes, so a first frame carries 5
    /// payload bytes and a consecutive frame 6.
    func testBMWExtendedAddressingMultiFrame() {
        let firstFrame = "618F1100B5902FF0102" // 59 02 FF 01 02 of 11
        let consecutive = "618F121030405060708" // 6 more: 12 >= 11
        assertOwed(true, "1902FF", [firstFrame])
        assertOwed(false, "1902FF", [firstFrame, consecutive])
        assertOwed(true, "1902FF", ["618F1037F1978", firstFrame])
        assertOwed(false, "1902FF", ["618F1037F1978", firstFrame, consecutive])
        // 12 bytes declared: 5 + 6 is one short.
        assertOwed(true, "1902FF", ["618F1100C5902FF0102", consecutive])
    }

    func testAnUnpaddedShortLastConsecutiveFrame() {
        // 10 bytes declared: 6 in the first frame, 4 in an unpadded consecutive frame.
        assertOwed(false, "1902FF", ["7E8100A5902FF010203", "7E82104050607"])
        assertOwed(true, "1902FF", ["7E8100A5902FF010203", "7E821040506"])
    }

    func testTwentyNineBitMultiFrame() {
        let firstFrame = "18DAF1101014490201494949"
        let consecutive = ["18DAF1102149494949494949", "18DAF1102249494949494949"]
        assertOwed(true, "0902", [firstFrame, consecutive[0]])
        assertOwed(false, "0902", [firstFrame] + consecutive)
    }

    func testAPendingSettledByAMultiFrameFinal() {
        assertOwed(true, "1902FF", ["7E8037F1978", Self.firstFrame])
        assertOwed(false, "1902FF", ["7E8037F1978", Self.firstFrame, Self.consecutive])
        // Complete but the wrong sub-function: still owed.
        assertOwed(true, "1902FF", ["7E8037F1978", "7E8100B5901FF010203", Self.consecutive])
    }

    func testAMalformedFirstFrameCannotSettlePending() {
        // Declared 6, carries 6. This payload had to be encoded as a single frame.
        assertOwed(true, "1902FF", ["7E8037F1978", "7E810065902FF010203"])
    }

    func testOverlappingFirstFramesKeepTheDebtOwed() {
        // The suffix might belong to either first frame, even within the same service.
        assertOwed(true, "1902FF", ["7E81014590201020304", Self.firstFrame, Self.consecutive])
        assertOwed(true, "1902FF", [Self.firstFrame, "7E81014590201020304", Self.consecutive])
    }

    func testOutOfSequenceBytesDoNotCompleteAMatchingFinal() {
        assertOwed(true, "1902FF", ["7E8037F1978", Self.firstFrame, "7E8220405060708"])
        assertOwed(true, "1902FF", [Self.firstFrame, "7E8220405060708"])
    }

    func testAnUnrelatedMultiFrameMessageDoesNotDischargeTheInterruptedAnswer() {
        assertOwed(true, "1902FF", [Self.firstFrame, "7E8100B5901FF010203", Self.consecutive])
    }

    func testAMatchingTerminalRefusalCanEndAnIncompleteAnswer() {
        assertOwed(false, "1902FF", ["7E8037F1978", Self.firstFrame, "7E8037F1931"])
        assertOwed(true, "1902FF", [Self.firstFrame, "7E8037F2231"])
    }

    func testHeaderlessPendingStillRequiresTheMatchingFinal() {
        assertOwed(true, "1902FF", ["7F 19 78", "59 01 FF 01 00 00"])
        assertOwed(false, "1902FF", ["7F 19 78", "59 02 FF"])
    }

    func testAStrayConsecutiveFrameOrFlowControlIsIgnored() {
        assertOwed(false, "1902FF", [Self.consecutive])
        assertOwed(false, "1902FF", ["7E8300000"])
        assertOwed(true, "1902FF", [Self.firstFrame, "7E8300000"])
    }

    // MARK: State across calls

    func testStateCarriesAcrossConsumeCalls() {
        var tracker = OBDOwedAnswerTracker(command: "03")
        tracker.consume(["7E8037F0378"])
        XCTAssertTrue(tracker.isOwed)
        tracker.consume(["NO DATA"])
        XCTAssertTrue(tracker.isOwed)
        tracker.consume(["7E8044301012300"])
        XCTAssertFalse(tracker.isOwed)

        var multiFrame = OBDOwedAnswerTracker(command: "0902")
        multiFrame.consume([Self.vin[0]])
        XCTAssertTrue(multiFrame.isOwed)
        multiFrame.consume([Self.vin[1]])
        XCTAssertTrue(multiFrame.isOwed)
        multiFrame.consume([Self.vin[2]])
        XCTAssertFalse(multiFrame.isOwed)
    }

    // MARK: The echo rule

    func testEcho() {
        let cases: [(command: String?, lines: [String], owed: Bool, why: String)] = [
            ("0100", ["7E8037F0178", "7E8064100BE3FA813"], false, "01: one byte echoed"),
            ("0100", ["7E8037F0178", "7E804410C1AF8"], true, "01: wrong PID"),
            ("010C0D", ["7E8037F0178", "7E806410C1AF80D32"], false, "01: multi-PID echoes the first"),
            ("020C00", ["7E8037F0278", "7E805420C001AF8"], false, "02: one byte echoed"),
            ("0601", ["7E8037F0678", "7E8054601010203"], false, "06"),
            ("0602", ["7E8037F0678", "7E8054601010203"], true, "06: wrong MID"),
            ("0904", ["7E8037F0978", "7E80449040141"], false, "09"),
            ("2101", ["7E8037F2178", "7E80461010203"], false, "21"),
            ("2102", ["7E8037F2178", "7E80461010203"], true, "21: wrong local id"),
            ("1982FF", ["7E8037F1978", "7E8065902FF012345"], false, "19: bit 7 of the request byte is ignored"),
            ("19", ["7E8037F1978", "7E806590100010203"], false, "19 with no sub-function: compare what it has"),
            ("2201", ["7E8037F2278", "7E804620102AA"], false, "22 with one DID byte: compare one"),
            ("2201", ["7E8037F2278", "7E804620202AA"], true, "22 with one DID byte: wrong"),
            ("22F190", ["7E8037F2278", "7E80262F1"], true, "22: a head too short to compare does not match"),
            ("22F190", ["7E8037F2278", "7E80162"], true, "22: bare service byte does not match"),
            ("0902", ["7E8037F0978", "7E80149"], true, "09: bare service byte does not match"),
            ("03", ["7E8037F0378", "7E8024300"], false, "03: nothing echoed"),
            ("04", ["7E8037F0478", "7E80144"], false, "04: nothing echoed"),
            ("0A", ["7E8037F0A78", "7E8024A00"], false, "0A: nothing echoed"),
            ("3101FF00", ["7E8037F3178", "7E8047102FF00"], false, "unlisted service: the service alone settles"),
            ("1902FF", ["7E8037F2278", "7E80462F19041"], false, "a pending for another service than the request's: the service alone settles"),
            ("19 02 ff", ["7E8037F1978", "7E8065902FF012345"], false, "spaces and lowercase in the command"),
            ("19 02 ff", ["7E8037F1978", "7E806590100010203"], true, "spaces and lowercase in the command, wrong echo"),
        ]
        for testCase in cases {
            assertOwed(testCase.owed, testCase.command, testCase.lines, testCase.why)
        }
    }

    /// No hex request: the pending is still detected, and the service match alone settles.
    func testAnUnknownOrAdapterCommand() {
        for command in [nil, "ATRV", "ATSH 7E0", "ATDPN", "", "7", "123", "4100", "7F"] as [String?] {
            let label = command ?? "nil"
            assertOwed(true, command, ["7E8037F1978"], "\(label): pending")
            assertOwed(false, command, ["7E8037F1978", "7E806590100010203"], "\(label): any 59 settles")
            assertOwed(false, command, ["7E8037F1978", "7E8037F1931"], "\(label): refusal settles")
            assertOwed(true, command, ["7E8037F1978", "7E80462F19041"], "\(label): another service doesn't")
            assertOwed(true, command, ["7E8037F1978", "7E8037F2231"], "\(label): another service's refusal doesn't")
        }
    }

    // MARK: Never owed

    private static let ordinaryReplies: [String] = [
        "7E804410C1AF8", "7E803410D32", "7E803412F80", "7E803410580", "7E803410440", "7E803411120",
        "7E804410C1AF8AAAAAA", "7E803410D32AAAAAAAA", "7E804410C1AF8000000", "7E803410D3200000000",
        "7E803410D3255555555", "7E8064100BE3FA813", "7E80641010007E100", "7E8024300",
        "7E9064100983B0011", "7e804410c1af8", "7E8 04 41 0C 1A F8", "7E8 03 41 0D 32 AA AA AA AA",
        "18DAF11003410D32", "18DAF11003410D32AAAAAAAA", "18DAF1100641 00BE3FA813",
        "486B10410D3249", "48 6B 10 41 0C 1A F8 C0", "83F1114100BE3FA813A7",
        "7E8037F0112", "7E8037F0311",
    ]

    private static let adapterText: [String] = [
        "OK", "NO DATA", "SEARCHING...", "STOPPED", "?", "BUFFER FULL", "CAN ERROR", "ELM327 v1.5",
        "14.1V", "12.4V", "BUS INIT: ...OK", "UNABLE TO CONNECT", "<DATA ERROR", "A6", "6", "ACT ALERT",
    ]

    private static let garbage: [String] = [
        "", " ", "\t", "7E", "7E8", "7E80", "ZZ", "7E8F1", "7E810", "7E81FF", "7E8037F", "7E8037F03",
        "0123456789ABCDEF0123456789ABCDEF01234567", "7E8037F0378Z", "7E8 03 7F 03 78 >",
        String(repeating: "F", count: 41), String(repeating: "0", count: 1_000), "18DA", "18DAF110",
        "18DAF11000", "7E8007F0378", "7E8087F0378AAAAAAAA", "7E8037F0378AAAAAAAAAAAA",
    ]

    func testOrdinaryRepliesAreNeverOwed() {
        for command in [nil, "0100", "010C", "010D", "03"] as [String?] {
            for line in Self.ordinaryReplies {
                assertOwed(false, command, [line], "command \(command ?? "nil")")
            }
            assertOwed(false, command, Self.ordinaryReplies, "all at once")
            assertOwed(false, command, ["7E8064100BE3FA813", "7E9064100983B0011"], "two ECUs answering 0100")
        }
    }

    func testAdapterTextAndGarbageAreNeverOwed() {
        for command in [nil, "0100", "ATRV"] as [String?] {
            assertOwed(false, command, [])
            assertOwed(false, command, [""])
            for line in Self.adapterText + Self.garbage {
                assertOwed(false, command, [line], "command \(command ?? "nil")")
            }
            assertOwed(false, command, Self.adapterText + Self.garbage)
        }
    }

    /// Characters dropped off an ordinary CAN reply never turn it into an owed answer.
    func testEveryTruncationOfAnOrdinaryCANReplyIsNeverOwed() {
        for reply in Self.ordinaryReplies where reply.hasPrefix("7E") || reply.hasPrefix("7e") || reply.hasPrefix("18DA") {
            var prefix = ""
            for character in reply {
                prefix.append(character)
                assertOwed(false, "010C", [prefix])
            }
        }
    }

    func testTruncatedKWPCannotStartACANTransfer() {
        assertOwed(false, "0100", ["83F1114100BE3FA813A"])
        assertOwed(false, "0100", ["83F1114100BE3FA813A7"])
    }

    /// Never crashes, whatever the bytes. Deterministic.
    func testRandomGarbageNeverCrashes() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        let alphabet = Array("0123456789ABCDEFabcdef \t\r>:.Z?F1")
        let commands: [String?] = [nil, "1902FF", "22F190", "0100", "ATRV", "03"]
        var owedCount = 0
        for round in 0 ..< 2_000 {
            var tracker = OBDOwedAnswerTracker(command: commands[round % commands.count])
            for _ in 0 ..< Int(next() % 4) + 1 {
                var lines: [String] = []
                for _ in 0 ..< Int(next() % 4) {
                    let length = Int(next() % 48)
                    lines.append(String((0 ..< length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] }))
                }
                tracker.consume(lines)
            }
            if tracker.isOwed { owedCount += 1 }
        }
        XCTAssertLessThan(owedCount, 2_000)
    }
}
