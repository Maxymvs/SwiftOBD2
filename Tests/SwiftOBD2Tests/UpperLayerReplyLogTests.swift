//
//  UpperLayerReplyLogTests.swift
//  SwiftOBD2Tests
//
//  While a manufacturer batch's late answer may still be on the stream, an unexpected reply to
//  an adapter command can *be* that manufacturer data. Upper-layer errors never carry reply
//  text, and upper-layer logs render it only when the transport holds no redaction.
//

import Combine
import CoreBluetooth
@testable import SwiftOBD2
import XCTest

final class UpperLayerReplyLogTests: XCTestCase {
    /// A late manufacturer reply (`62 02 8D 0B EE`) landing in the `ATE0` slot.
    private let lateManufacturerReply = ["7E80562028D0BEE", "7E8 05 62 02 8D 0B EE"]

    func testOkResponseErrorCarriesNoReplyText() async {
        let comm = OwnershipScriptedComm(responses: ["ATE0": lateManufacturerReply])
        let sut = ELM327(comm: comm)

        do {
            _ = try await sut.okResponse("ATE0")
            XCTFail("expected an error")
        } catch {
            let text = "\(error) \(error.localizedDescription)"
            for fragment in ["7E8", "028D", "0BEE", "62 02", "0B EE"] {
                XCTAssertFalse(text.contains(fragment), "error text leaks reply text '\(fragment)': \(text)")
            }
            XCTAssertTrue(text.contains("ATE0"), "the command name is enough to debug: \(text)")
        }
    }

    func testOkResponseErrorCarriesNoReplyTextEvenWithoutHold() async {
        let comm = OwnershipScriptedComm(responses: ["ATL0": ["SOMETHING ELSE"]])
        comm.redactionHeld = false
        let sut = ELM327(comm: comm)

        do {
            _ = try await sut.okResponse("ATL0")
            XCTFail("expected an error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("SOMETHING"), error.localizedDescription)
        }
    }

    func testUnexpectedReplyDescriptionNamesCommandAndCountOnly() {
        let text = ELM327.unexpectedReplyDescription(command: "ATE0", lines: lateManufacturerReply)
        XCTAssertEqual(text, "ATE0: unexpected reply (2 reply lines)")
    }

    func testReplyTextIsRenderedOnlyWithoutHold() {
        let free = OBDReplyLogText.render(lateManufacturerReply, redactionHeld: false)
        XCTAssertTrue(free.contains("7E80562028D0BEE"), "ordinary debugging output is unchanged: \(free)")

        let held = OBDReplyLogText.render(lateManufacturerReply, redactionHeld: true)
        XCTAssertEqual(held, "2 reply lines")
        XCTAssertEqual(OBDReplyLogText.render(["X"], redactionHeld: true), "1 reply line")
        XCTAssertEqual(OBDReplyLogText.render([], redactionHeld: true), "0 reply lines")
    }

    func testELM327FollowsTheTransportsHold() {
        let comm = OwnershipScriptedComm(responses: [:])
        let sut = ELM327(comm: comm)

        XCTAssertFalse(sut.isWireRedactionHeld)
        XCTAssertTrue(sut.replyLogText(lateManufacturerReply).contains("0BEE"))

        comm.redactionHeld = true
        XCTAssertTrue(sut.isWireRedactionHeld)
        XCTAssertEqual(sut.replyLogText(lateManufacturerReply), "2 reply lines")
    }

    /// A late `49 02` answer (synthetic bytes) in an ordinary slot: upper-layer logs show only
    /// its size, hold or no hold.
    func testAVINReplyIsNeverRenderedByUpperLayers() {
        let vinReply = ["7E8 10 14 49 02 01 53 59 4E", "7E8 21 30 30 30 30 30 30 31"]
        XCTAssertEqual(OBDReplyLogText.render(vinReply, redactionHeld: false), "2 reply lines")
        XCTAssertEqual(OBDReplyLogText.render(["7E81014490201535"], redactionHeld: false), "1 reply line")
        let sut = ELM327(comm: OwnershipScriptedComm(responses: [:]))
        XCTAssertEqual(sut.replyLogText(vinReply), "2 reply lines")
    }

    /// A `62 F1 90` answer (synthetic VIN WVWZZZ5NZLW000001), single- or multi-frame, 11-bit or
    /// BMW extended addressing, spaced or compact: upper-layer logs show only its size, hold or
    /// no hold, whatever command's slot it landed in.
    func testAUDSVINReplyIsNeverRenderedByUpperLayers() {
        let replies: [[String]] = [
            ["7E8 10 14 62 F1 90 57 56 57", "7E8 21 5A 5A 5A 35 4E 5A 4C", "7E8 22 57 30 30 30 30 30 31"],
            ["7E8101462F190575657", "7E8215A5A5A354E5A4C", "7E82257303030303031"],
            ["612 F1 10 14 62 F1 90 57 56", "612 F1 21 57 5A 5A 5A 35 4E",
             "612 F1 22 5A 4C 57 30 30 30", "612 F1 23 30 30 31 AA AA AA"],
            ["612F1101462F1905756", "612F121575A5A5A354E", "612F1225A4C57303030", "612F123303031AAAAAA"],
        ]
        let sut = ELM327(comm: OwnershipScriptedComm(responses: [:]))
        for reply in replies {
            let expected = "\(reply.count) reply lines"
            XCTAssertEqual(OBDReplyLogText.render(reply, redactionHeld: false), expected)
            XCTAssertEqual(OBDReplyLogText.render(reply, redactionHeld: true), expected)
            XCTAssertEqual(sut.replyLogText(reply), expected)
        }
        XCTAssertEqual(OBDReplyLogText.render(["7E8 06 62 F1 90 57 56 57"], redactionHeld: false), "1 reply line")
        // Another identifier's answer is still rendered when nothing is held.
        XCTAssertTrue(OBDReplyLogText.render(["7E8 10 14 62 F1 91 57 56 57"], redactionHeld: false).contains("62 F1 91"))
    }

    /// A malformed buffer can be a whole VIN reply: a parse error names the reason and the size.
    func testParseErrorsLogTheByteCountOnly() {
        let buffer = Data([0x49, 0x02, 0x01, 0x53, 0x59, 0x4E])
        let message = OBDLogger.parseErrorMessage("Unknown frame type", byteCount: buffer.count, expectedFormat: "Valid FrameType")
        XCTAssertEqual(message, "Parse error: Unknown frame type | 6 bytes | Expected: Valid FrameType")
        XCTAssertEqual(OBDLogger.parseErrorMessage("x", byteCount: 1, expectedFormat: nil), "Parse error: x | 1 byte")
    }

    func testTransportsWithoutAWireLogNeverHold() {
        XCTAssertFalse(HoldlessComm().isWireRedactionHeld)
        XCTAssertFalse(MOCKComm().isWireRedactionHeld)
    }
}

/// A transport that doesn't implement the hold: the protocol's default applies.
private final class HoldlessComm: CommProtocol {
    @Published var connectionState: ConnectionState = .connectedToAdapter
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    func sendCommand(_: String, retries _: Int) async throws -> [String] { [] }
    func disconnectPeripheral() {}
    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral?) async throws {}
    func scanForPeripherals() async throws {}
}
