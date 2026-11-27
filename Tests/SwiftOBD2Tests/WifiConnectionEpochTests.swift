//
//  WifiConnectionEpochTests.swift
//  SwiftOBD2Tests
//
//  `WifiManager.adapterConnection` carries the epoch a published vehicle link is checked against.
//  It must stay put while one socket is attached and move whenever that socket is replaced or
//  goes away: an attach, a disconnect, a failed receive pump. Only the socket is fake.
//

@testable import SwiftOBD2
import XCTest

final class WifiConnectionEpochTests: XCTestCase {
    private func epoch(_ manager: WifiManager) -> UInt64? {
        manager.adapterConnection.epoch
    }

    func testTheEpochIsStableWhileOneSocketIsAttached() throws {
        let manager = WifiManager()
        let socket = EpochTestSocket()
        manager.attach(socket: socket)
        let attached = try XCTUnwrap(epoch(manager))

        // Traffic on the same socket doesn't move it.
        socket.deliverWhenArmed("7E8064100BE3FA813\r\r>")
        socket.deliverWhenArmed("\r\n")
        XCTAssertEqual(epoch(manager), attached)
        XCTAssertEqual(manager.adapterConnection, manager.adapterConnection)
    }

    func testAttachingASocketChangesTheEpoch() throws {
        let manager = WifiManager()
        let before = epoch(manager)
        manager.attach(socket: EpochTestSocket())
        let first = epoch(manager)
        XCTAssertNotEqual(first, before)

        manager.attach(socket: EpochTestSocket())
        XCTAssertNotEqual(epoch(manager), first, "a replaced socket is another connection")
    }

    func testDisconnectingChangesTheEpoch() throws {
        let manager = WifiManager()
        let socket = EpochTestSocket()
        manager.attach(socket: socket)
        let attached = epoch(manager)

        manager.disconnectPeripheral()

        XCTAssertNotEqual(epoch(manager), attached)
        XCTAssertTrue(socket.wasCancelled)
        XCTAssertNil(manager.socket)
    }

    func testAFailedReceivePumpChangesTheEpoch() throws {
        let manager = WifiManager()
        let socket = EpochTestSocket()
        manager.attach(socket: socket)
        let attached = epoch(manager)

        socket.failRead()

        XCTAssertNotEqual(epoch(manager), attached)
        XCTAssertNil(manager.socket)
    }

    /// A connection that went away never compares equal to anything read afterwards, even when
    /// a new socket is attached in its place.
    func testNoLaterConnectionEqualsOneThatWentAway() throws {
        let manager = WifiManager()
        manager.attach(socket: EpochTestSocket())
        let published = manager.adapterConnection

        manager.disconnectPeripheral()
        let afterDisconnect = manager.adapterConnection
        manager.attach(socket: EpochTestSocket())
        let afterReattach = manager.adapterConnection

        XCTAssertNotEqual(afterDisconnect, published)
        XCTAssertNotEqual(afterReattach, published)
        XCTAssertNotEqual(afterReattach, afterDisconnect)
    }
}

/// A socket that does nothing on its own: reads resolve only when the test says so.
private final class EpochTestSocket: WifiSocket {
    private let lock = NSLock()
    private var pendingRead: ((Result<Data, WifiSocketError>) -> Void)?
    private var cancelled = false

    var wasCancelled: Bool { lock.withLock { cancelled } }

    func send(_: Data, completion: @escaping (Result<Void, WifiSocketError>) -> Void) {
        completion(.success(()))
    }

    func receive(_ completion: @escaping (Result<Data, WifiSocketError>) -> Void) {
        lock.withLock { pendingRead = completion }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            pendingRead = nil
        }
    }

    /// Resolves the armed read with bytes; the pump re-arms synchronously from inside it.
    func deliverWhenArmed(_ text: String) {
        let completion = lock.withLock { () -> ((Result<Data, WifiSocketError>) -> Void)? in
            defer { pendingRead = nil }
            return pendingRead
        }
        XCTAssertNotNil(completion, "the pump had no read armed")
        completion?(.success(Data(text.utf8)))
    }

    /// Breaks the socket underneath the pump.
    func failRead() {
        let completion = lock.withLock { () -> ((Result<Data, WifiSocketError>) -> Void)? in
            defer { pendingRead = nil }
            return pendingRead
        }
        XCTAssertNotNil(completion, "the pump had no read armed")
        completion?(.failure(.failed))
    }
}
