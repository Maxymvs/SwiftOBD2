//
//  OBDVehicleLinkTests.swift
//
//  `OBDService.vehicleLink` is "the link that is up now". A setup that lost the connection to a
//  newer one must publish nothing, and the link's adapter is the peripheral the setup ran on,
//  never the app's saved reconnect target. The setups run end to end through `OBDService` and
//  `ELM327` over a scripted transport; only the transport is fake.
//

import Combine
import CoreBluetooth
import Foundation
@testable import SwiftOBD2
import XCTest

@MainActor
final class OBDVehicleLinkPublicationTests: XCTestCase {
    private let vinA = "TESTVIN0000000001"
    private let vinB = "TESTVIN0000000002"
    private let adapterA = UUID()
    private let adapterB = UUID()

    func testASingleSetupPublishesItsLink() async throws {
        let comm = LinkScriptedComm()
        comm.script(vin: vinA, peripheral: adapterA)
        let service = OBDService(comm: comm, connectionType: .demo)

        let info = try await service.startConnection()

        XCTAssertEqual(info.vin, vinA)
        let link = try XCTUnwrap(service.vehicleLink)
        XCTAssertEqual(link.vin, vinA)
        XCTAssertEqual(link.adapterID, adapterA)
        XCTAssertEqual(service.latestOBDInfo?.vin, vinA)
    }

    /// The app writes `lastConnectedPeripheralUUID` (the saved reconnect target). The link must
    /// name the peripheral the setup is actually connected to.
    func testTheLinkNamesTheConnectedPeripheralNotTheSavedReconnectTarget() async throws {
        let comm = LinkScriptedComm()
        comm.script(vin: vinA, peripheral: adapterA)
        let service = OBDService(comm: comm, connectionType: .demo)
        let savedTarget = UUID()
        service.vehicleSetupWillPublish = { @MainActor in
            service.lastConnectedPeripheralUUID = savedTarget
        }

        _ = try await service.startConnection()

        XCTAssertEqual(service.lastConnectedPeripheralUUID, savedTarget, "precondition: the target was overwritten")
        XCTAssertEqual(service.vehicleLink?.adapterID, adapterA)
    }

    /// Setup A reads its VIN and passes its last check, then stalls. Setup B starts, connects
    /// (to another adapter and car) and publishes. When A finally resumes it must publish
    /// nothing: no link, no `latestOBDInfo`, and B's link stays exactly as it was.
    func testASupersededStartConnectionPublishesNothing() async throws {
        let comm = LinkScriptedComm()
        comm.script(vin: vinA, peripheral: adapterA)
        let service = OBDService(comm: comm, connectionType: .demo)
        let hold = SetupHold()
        service.vehicleSetupWillPublish = { await hold.holdFirstCaller() }

        let setupA = Task { try await service.startConnection() }
        try await hold.waitUntilHeld()

        comm.script(vin: vinB, peripheral: adapterB)
        let infoB = try await service.startConnection()
        XCTAssertEqual(infoB.vin, vinB)
        let linkB = try XCTUnwrap(service.vehicleLink)
        XCTAssertEqual(linkB.vin, vinB)
        XCTAssertEqual(linkB.adapterID, adapterB)

        hold.release()
        let resultA = await setupA.result
        await drainMainQueue()

        XCTAssertEqual(service.vehicleLink, linkB, "A must not replace B's link")
        XCTAssertEqual(service.vehicleLink?.id, linkB.id)
        XCTAssertEqual(service.latestOBDInfo?.vin, vinB, "A must not publish its info either")
        if case .success = resultA {
            XCTFail("A setup that lost the connection must not report success")
        }
    }

    func testASupersededReinitializationPublishesNothing() async throws {
        let comm = LinkScriptedComm()
        comm.script(vin: vinA, peripheral: adapterA)
        let service = OBDService(comm: comm, connectionType: .demo)
        _ = try await service.startConnection()

        let hold = SetupHold()
        service.vehicleSetupWillPublish = { await hold.holdFirstCaller() }
        let reinitA = Task { try await service.reinitializeConnection() }
        try await hold.waitUntilHeld()

        comm.script(vin: vinB, peripheral: adapterB)
        _ = try await service.startConnection()
        let linkB = try XCTUnwrap(service.vehicleLink)
        XCTAssertEqual(linkB.vin, vinB)

        hold.release()
        let resultA = await reinitA.result
        await drainMainQueue()

        XCTAssertEqual(service.vehicleLink, linkB, "A must not replace B's link")
        XCTAssertEqual(service.latestOBDInfo?.vin, vinB)
        if case .success = resultA {
            XCTFail("A reinitialization that lost the connection must not report success")
        }
    }

    /// The transport moved to another adapter connection (a new attempt on another peripheral)
    /// while the setup was finishing, without a new service-level setup beginning. The setup
    /// must not publish a link that names a connection it no longer runs on.
    func testASetupWhoseTransportMovedOnPublishesNothing() async throws {
        let comm = LinkScriptedComm()
        comm.script(vin: vinA, peripheral: adapterA)
        let service = OBDService(comm: comm, connectionType: .demo)
        service.vehicleSetupWillPublish = {
            comm.reconnectUnderneath(to: self.adapterB)
        }

        do {
            _ = try await service.startConnection()
            XCTFail("A setup whose connection moved on must not report success")
        } catch {}
        await drainMainQueue()

        XCTAssertNil(service.vehicleLink)
        XCTAssertNil(service.latestOBDInfo)
    }

    /// A new link on the same adapter connection (reinitialization) still gets its own id.
    func testReinitializationMintsANewLinkID() async throws {
        let comm = LinkScriptedComm()
        comm.script(vin: vinA, peripheral: adapterA)
        let service = OBDService(comm: comm, connectionType: .demo)
        _ = try await service.startConnection()
        let first = try XCTUnwrap(service.vehicleLink)

        _ = try await service.reinitializeConnection()
        let second = try XCTUnwrap(service.vehicleLink)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.adapterID, adapterA)
    }
}

// MARK: - Mode 04 bound to one link

/// `OBDService.clearTroubleCodes(on:)` over the real WiFi transport (only the socket is fake), so
/// the link check runs where that transport serializes its writes.
@MainActor
final class OBDBoundClearTests: XCTestCase {
    private let vin = "TESTVIN0000000001"

    private func makeService() -> (OBDService, AnsweringWifiSocket, ScriptedWifiManager) {
        let socket = AnsweringWifiSocket(vin: vin)
        let manager = ScriptedWifiManager(socket: socket)
        manager.readTimeout = 1
        let service = OBDService(comm: manager, connectionType: .wifi)
        return (service, socket, manager)
    }

    func testABoundClearOnTheCurrentLinkSendsMode04Once() async throws {
        let (service, socket, _) = makeService()
        _ = try await service.startConnection()
        let link = try XCTUnwrap(service.vehicleLink)
        socket.forgetSent()

        try await service.clearTroubleCodes(on: link)

        XCTAssertEqual(socket.sentCommands, ["04"])
    }

    /// The clear is called on link 1 and waits for the transport's mutex behind another command.
    /// While it waits, a reinitialization starts replacing the link. When the clear gets the
    /// mutex the link is no longer link 1: nothing is sent and the caller sees `linkChanged`
    /// itself, not a wrapped failure. Link 2 then comes up, and link 1 stays refused on it.
    func testABoundClearWhoseLinkWasReplacedWhileWaitingSendsNothing() async throws {
        let (service, socket, _) = makeService()
        _ = try await service.startConnection()
        let link1 = try XCTUnwrap(service.vehicleLink)
        socket.forgetSent()

        socket.hold("0105")
        let holder = Task { try await service.sendCommandInternal("0105", retries: 1) }
        try await socket.waitForSend("0105")

        let clear = Task { try await service.clearTroubleCodes(on: link1) }
        for _ in 0 ..< 200 { await Task.yield() }
        XCTAssertEqual(socket.sentCommands, ["0105"], "The clear must still be waiting for the mutex")

        let reinit = Task { try await service.reinitializeConnection() }
        try await waitUntil { service.vehicleLink == nil }

        socket.release("0105")
        _ = try? await holder.value

        do {
            try await clear.value
            XCTFail("Expected linkChanged")
        } catch let error as OBDVehicleLinkError {
            XCTAssertEqual(error, .linkChanged)
        } catch {
            XCTFail("Expected linkChanged itself, got \(error)")
        }

        _ = try await reinit.value
        let link2 = try XCTUnwrap(service.vehicleLink)
        XCTAssertNotEqual(link2.id, link1.id)
        XCTAssertFalse(socket.sentCommands.contains("04"), "Nothing may be sent for the stale clear")

        do {
            try await service.clearTroubleCodes(on: link1)
            XCTFail("Expected linkChanged")
        } catch let error as OBDVehicleLinkError {
            XCTAssertEqual(error, .linkChanged)
        }
        XCTAssertFalse(socket.sentCommands.contains("04"))

        try await service.clearTroubleCodes(on: link2)
        XCTAssertEqual(socket.sentCommands.filter { $0 == "04" }.count, 1, "The current link clears normally")
    }

    func testABoundClearWithNoCurrentLinkSendsNothing() async throws {
        let (service, socket, manager) = makeService()
        try await manager.connectAsync(timeout: 1, peripheral: nil) // a socket a write could reach
        XCTAssertNil(service.vehicleLink)

        do {
            try await service.clearTroubleCodes(on: OBDVehicleLink(id: UUID(), vin: vin, adapterID: nil))
            XCTFail("Expected linkChanged")
        } catch let error as OBDVehicleLinkError {
            XCTAssertEqual(error, .linkChanged)
        }
        XCTAssertEqual(socket.sentCommands, [])
    }

    func testABoundClearAfterTheLinkDroppedSendsNothing() async throws {
        let (service, socket, manager) = makeService()
        _ = try await service.startConnection()
        let link = try XCTUnwrap(service.vehicleLink)
        socket.forgetSent()

        manager.connectionState = .connectedToAdapter // the vehicle side dropped
        try await waitUntil { service.vehicleLink == nil }

        do {
            try await service.clearTroubleCodes(on: link)
            XCTFail("Expected linkChanged")
        } catch let error as OBDVehicleLinkError {
            XCTAssertEqual(error, .linkChanged)
        }
        XCTAssertEqual(socket.sentCommands, [])
    }

    /// The check runs before every attempt, not once per call: a retry after a silent first
    /// attempt is refused when the binding no longer holds.
    func testTheWifiCheckRunsBeforeEveryAttempt() async throws {
        let socket = AnsweringWifiSocket(vin: vin)
        let manager = ScriptedWifiManager(socket: socket)
        manager.readTimeout = 0.3
        try await manager.connectAsync(timeout: 1, peripheral: nil)
        socket.hold("04") // the first attempt goes unanswered
        let checks = Counter()

        do {
            // Each attempt checks three times: when it starts, again once the stream is proven,
            // and at the submission itself (`OBDWriteAuthorization(check:)` runs the check inside
            // `whileAuthorized`). The first attempt's three checks pass; the retry's first fails.
            _ = try await manager.sendCommand("04", retries: 2, beforeEachWrite: {
                if checks.increment() > 3 { throw OBDVehicleLinkError.linkChanged }
            })
            XCTFail("Expected linkChanged")
        } catch let error as OBDVehicleLinkError {
            XCTAssertEqual(error, .linkChanged)
        }
        XCTAssertEqual(checks.value, 4)
        XCTAssertEqual(socket.sentCommands, ["04"], "The retry must not be written")
    }

    /// The link id alone isn't enough: the transport must still be on the adapter connection
    /// the link was published on. (Scripted transport: its connection is scriptable.)
    func testABoundClearAfterTheTransportReconnectedUnderneathSendsNothing() async throws {
        let comm = LinkScriptedComm()
        comm.script(vin: vin, peripheral: UUID())
        let service = OBDService(comm: comm, connectionType: .demo)
        _ = try await service.startConnection()
        let link = try XCTUnwrap(service.vehicleLink)

        comm.reconnectUnderneath(to: UUID())

        do {
            try await service.clearTroubleCodes(on: link)
            XCTFail("Expected linkChanged")
        } catch let error as OBDVehicleLinkError {
            XCTAssertEqual(error, .linkChanged)
        }
        XCTAssertFalse(comm.sentCommands.contains("04"))
    }

    // MARK: The link expires with its transport connection

    func testTheLinkIsReturnedWhileTheConnectionIsUnchanged() async throws {
        let comm = LinkScriptedComm()
        comm.script(vin: vin, peripheral: UUID())
        let service = OBDService(comm: comm, connectionType: .demo)
        _ = try await service.startConnection()

        let first = try XCTUnwrap(service.vehicleLink)
        for _ in 0 ..< 3 {
            XCTAssertEqual(service.vehicleLink, first)
        }
    }

    /// The transport's epoch advances (its connection went away) and no state change has reached
    /// the service: the getter already returns nil, and keeps doing so.
    func testTheLinkExpiresTheMomentTheTransportsEpochChanges() async throws {
        let comm = LinkScriptedComm()
        comm.script(vin: vin, peripheral: UUID())
        let service = OBDService(comm: comm, connectionType: .demo)
        _ = try await service.startConnection()
        XCTAssertNotNil(service.vehicleLink)
        let published = comm.adapterConnection

        comm.advanceEpoch()

        XCTAssertNil(service.vehicleLink, "no state-change callback is needed")
        XCTAssertEqual(service.connectionState, .connectedToVehicle, "precondition: the service heard nothing")
        await drainMainQueue()
        XCTAssertNil(service.vehicleLink)
        XCTAssertNil(service.vehicleLink)

        // Replaying the old identity is only possible on this test double. It shows the
        // getter left the record alone; real transport epochs advance on every transition.
        comm.setEpoch(published.epoch ?? 0)
        XCTAssertEqual(comm.adapterConnection, published)
        XCTAssertNotNil(service.vehicleLink)
    }

    func testABoundClearAfterTheEpochChangedThrowsLinkChangedAndSendsNothing() async throws {
        let comm = LinkScriptedComm()
        comm.script(vin: vin, peripheral: UUID())
        let service = OBDService(comm: comm, connectionType: .demo)
        _ = try await service.startConnection()
        let link = try XCTUnwrap(service.vehicleLink)
        let sentBefore = comm.sentCommands.count

        comm.advanceEpoch()

        do {
            try await service.clearTroubleCodes(on: link)
            XCTFail("Expected linkChanged")
        } catch let error as OBDVehicleLinkError {
            XCTAssertEqual(error, .linkChanged)
        }
        XCTAssertEqual(comm.sentCommands.count, sentBefore, "nothing may be sent")
        XCTAssertFalse(comm.sentCommands.contains("04"))
    }

    /// The unbound clear keeps today's error mapping.
    func testTheUnboundClearStillWrapsFailures() async throws {
        let (service, _, manager) = makeService()
        manager.readTimeout = 0.2
        try await manager.connectAsync(timeout: 1, peripheral: nil)
        manager.socket?.cancel()
        manager.socket = nil

        do {
            try await service.clearTroubleCodes()
            XCTFail("Expected clearFailed")
        } catch let error as OBDServiceError {
            guard case .clearFailed = error else { return XCTFail("Expected clearFailed, got \(error)") }
        }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 4000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Condition never held", file: file, line: line)
        throw CancellationError()
    }
}

// MARK: - Support

/// Lets every queued main-queue block (state deliveries) run.
@MainActor
func drainMainQueue() async {
    for _ in 0 ..< 5 {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// Holds the first caller until released; later callers pass straight through.
final class SetupHold: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var held = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func holdFirstCaller() async {
        let isFirst: Bool = lock.withLock {
            calls += 1
            return calls == 1
        }
        guard isFirst else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                held = true
                if released { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilHeld(file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 4000 {
            if lock.withLock({ held }) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("The first setup never reached publication", file: file, line: line)
        throw CancellationError()
    }

    func release() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

/// A transport that answers setup like the demo adapter, with a scripted VIN and a scripted
/// physical peripheral. Every `connectAsync` is a new adapter connection (a new attempt) to the
/// peripheral scripted at that moment, and records it as the reconnect target the way the BLE
/// transport does.
final class LinkScriptedComm: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    private let lock = NSLock()
    private let mock = MOCKComm()
    private var scriptedVIN = ""
    private var scriptedPeripheral: UUID?
    private var vinOnLink = ""
    private var connectedPeripheral: UUID?
    private var attempt: UInt64 = 0
    private var savedTarget: UUID?
    private var sent: [String] = []
    /// The transport-owned connection identity (see `OBDAdapterConnectionSnapshot.epoch`).
    private var epoch: UInt64 = 0

    var sentCommands: [String] { lock.withLock { sent } }

    /// What the next `connectAsync` connects to.
    func script(vin: String, peripheral: UUID) {
        lock.withLock {
            scriptedVIN = vin
            scriptedPeripheral = peripheral
        }
    }

    var adapterConnection: OBDAdapterConnectionSnapshot {
        lock.withLock { OBDAdapterConnectionSnapshot(attempt: attempt, peripheralID: connectedPeripheral, epoch: epoch) }
    }

    /// The connection went away underneath (its epoch advanced), with no state change published.
    func advanceEpoch() {
        lock.withLock { epoch &+= 1 }
    }

    /// Puts the epoch back to a value read earlier, as if the old connection were back.
    func setEpoch(_ value: UInt64) {
        lock.withLock { epoch = value }
    }

    var lastConnectedPeripheralUUID: UUID? {
        get { lock.withLock { savedTarget } }
        set { lock.withLock { savedTarget = newValue } }
    }

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral?) async throws {
        lock.withLock {
            attempt += 1
            epoch &+= 1
            connectedPeripheral = scriptedPeripheral
            vinOnLink = scriptedVIN
            savedTarget = scriptedPeripheral
        }
        connectionState = .connectedToAdapter
    }

    /// The transport reconnects by itself (a new attempt, another peripheral), the way a BLE
    /// auto-reconnect does, without a service-level setup.
    func reconnectUnderneath(to peripheral: UUID) {
        lock.withLock {
            attempt += 1
            connectedPeripheral = peripheral
        }
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        let vin: String = lock.withLock {
            sent.append(command)
            return vinOnLink
        }
        if command == "0902" {
            return Self.vinFrames(vin)
        }
        return try await mock.sendCommand(command, retries: retries)
    }

    func disconnectPeripheral() {
        connectionState = .disconnected
    }

    func scanForPeripherals() async throws {}

    /// A three-frame ISO-TP Mode 09 PID 02 answer from `7E8`.
    static func vinFrames(_ vin: String) -> [String] {
        let bytes = ["49", "02", "01"] + vin.utf8.map { String(format: "%02X", $0) }
        precondition(bytes.count == 20)
        let first = ["7E8", "10", "14"] + bytes[0 ..< 6]
        let second = ["7E8", "21"] + bytes[6 ..< 13]
        let third = ["7E8", "22"] + bytes[13 ..< 20]
        return [first, second, third].map { $0.joined(separator: " ") }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

/// The real WiFi transport with its socket connection scripted.
final class ScriptedWifiManager: WifiManager {
    private let scriptedSocket: AnsweringWifiSocket

    init(socket: AnsweringWifiSocket) {
        scriptedSocket = socket
        super.init()
    }

    override func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        attach(socket: scriptedSocket)
        connectionState = .connectedToAdapter
    }
}

/// A socket that answers every command like the demo adapter (with a scripted VIN), except
/// commands the test holds, which go unanswered until released.
final class AnsweringWifiSocket: WifiSocket {
    private let lock = NSLock()
    private let responder = LinkScriptedComm()
    private var pendingRead: ((Result<Data, WifiSocketError>) -> Void)?
    private var sends: [String] = []
    private var held: Set<String> = []

    init(vin: String) {
        responder.script(vin: vin, peripheral: UUID())
        Task { [responder] in try? await responder.connectAsync(timeout: 1, peripheral: nil) }
    }

    var sentCommands: [String] { lock.withLock { sends } }
    func forgetSent() { lock.withLock { sends.removeAll() } }
    func hold(_ command: String) { lock.withLock { _ = held.insert(command) } }

    /// Answers a held command now and stops holding it.
    func release(_ command: String) {
        lock.withLock { _ = held.remove(command) }
        Task { await self.answer(command) }
    }

    func waitForSend(_ command: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 4000 {
            if sentCommands.contains(command) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("\(command) was never sent", file: file, line: line)
        throw CancellationError()
    }

    func send(_ data: Data, completion: @escaping (Result<Void, WifiSocketError>) -> Void) {
        let command = String(data: data, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        let isHeld: Bool = lock.withLock {
            sends.append(command)
            return held.contains(command)
        }
        completion(.success(()))
        guard !isHeld else { return }
        Task { await self.answer(command) }
    }

    func receive(_ completion: @escaping (Result<Data, WifiSocketError>) -> Void) {
        lock.withLock { pendingRead = completion }
    }

    func cancel() {
        lock.withLock { pendingRead = nil }
    }

    private func answer(_ command: String) async {
        let lines = (try? await responder.sendCommand(command, retries: 1)) ?? ["NO DATA"]
        let text = lines.joined(separator: "\r") + "\r\r>"
        for _ in 0 ..< 2000 {
            let completion: ((Result<Data, WifiSocketError>) -> Void)? = lock.withLock {
                defer { pendingRead = nil }
                return pendingRead
            }
            if let completion {
                completion(.success(Data(text.utf8)))
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
