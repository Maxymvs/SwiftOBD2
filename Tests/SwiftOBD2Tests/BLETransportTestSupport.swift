//
//  BLETransportTestSupport.swift
//  SwiftOBD2Tests
//
//  A scripted adapter behind `BLECommandExchange`: the injected write records the command and
//  the absolute write deadline it was given, then feeds the scripted answer into the real message
//  processor, the way CoreBluetooth notifications would.
//

@testable import SwiftOBD2
import Foundation

final class FakeAdapterWire: @unchecked Sendable {
    private let processor: OBDMessageProcessor
    private let lock = NSLock()
    private var _written: [String] = []
    private var _writeTimeouts: [TimeInterval] = []
    private var _writeDeadlines: [TimeInterval] = []
    private var _delivered = 0

    /// The raw text (prompt included) the adapter sends back for a command; nil sends nothing.
    var respond: (String) -> String? = { _ in nil }
    /// Thrown by the write instead of writing.
    var writeError: Error?
    /// How long the write takes before it is accepted.
    var writeLatency: TimeInterval = 0
    /// Raw text from earlier commands that is still on its way: it arrives as the next command
    /// is written, ahead of that command's own answer, the way a real adapter answers in order.
    var lateBytes: [String] = []
    /// Called on every write, before any answer is delivered.
    var onWrite: ((String) -> Void)?

    init(processor: OBDMessageProcessor) {
        self.processor = processor
    }

    var written: [String] { lock.withLock { _written } }
    /// What was left of each write's deadline when the write was called.
    var writeTimeouts: [TimeInterval] { lock.withLock { _writeTimeouts } }
    /// The absolute instant each write was told to finish by.
    var writeDeadlines: [TimeInterval] { lock.withLock { _writeDeadlines } }

    func target(_ peripheral: UUID, revalidate: @escaping () throws -> Void = {}) -> BLECommandExchange.Target {
        BLECommandExchange.Target(peripheralID: peripheral, revalidate: revalidate) { [self] command, deadlineAt in
            lock.withLock {
                _writeDeadlines.append(deadlineAt)
                _writeTimeouts.append(deadlineAt - processor.clock())
            }
            if writeLatency > 0 {
                try await Task.sleep(nanoseconds: UInt64(writeLatency * 1_000_000_000))
            }
            if let writeError { throw writeError }
            lock.withLock { _written.append(command) }
            onWrite?(command)
            let late = lateBytes
            lateBytes = []
            for text in late {
                processor.processReceivedData(Data(text.utf8))
            }
            if let answer = respond(command) {
                processor.processReceivedData(Data(answer.utf8))
            }
        }
    }

    /// Bytes arriving on their own, e.g. a late answer to an earlier command.
    func deliver(_ text: String) {
        lock.withLock { _delivered += text.utf8.count }
        processor.processReceivedData(Data(text.utf8))
    }

    /// How many bytes `deliver` has handed to the processor so far.
    var delivered: Int { lock.withLock { _delivered } }
}

/// Collects what the wire log would have written.
final class CapturingWireSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [OBDWireLogRecord] = []

    var records: [OBDWireLogRecord] { lock.withLock { _records } }
    var text: String { records.map(\.message).joined(separator: "\n") }

    lazy var sink: OBDWireLog.Sink = { [unowned self] record in
        self.lock.withLock { self._records.append(record) }
    }
}

/// A clock a test moves by hand, for the processor and everything that shares its clock.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval

    init(_ time: TimeInterval = 1_000) {
        self.time = time
    }

    var now: @Sendable () -> TimeInterval {
        { [self] in lock.withLock { time } }
    }

    func set(_ instant: TimeInterval) {
        lock.withLock { time = instant }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { time += seconds }
    }
}

/// The manufacturer channel as `BLEManager` builds it, without CoreBluetooth: the real exchange,
/// the real processor and a scripted wire.
final class ExchangeOEMChannel: OEMCommandChannel {
    let exchange: BLECommandExchange
    let wire: FakeAdapterWire
    let peripheral: UUID
    private(set) var markedUnresolved = false

    init(exchange: BLECommandExchange, wire: FakeAdapterWire, peripheral: UUID = UUID()) {
        self.exchange = exchange
        self.wire = wire
        self.peripheral = peripheral
    }

    func send(_ command: String, deadline: TimeInterval) async throws -> [String] {
        try await exchange.send(command, retries: 1, responseTimeout: 0, deadline: deadline, policy: .redacted) {
            wire.target(peripheral)
        }
    }

    func listen(deadline: TimeInterval) async throws -> [String] {
        try await exchange.listen(deadline: deadline, policy: .redacted)
    }

    func resynchronize(deadline: TimeInterval) async throws -> Bool {
        try await exchange.resynchronize(deadline: deadline, policy: .redacted, target: wire.target(peripheral)) == .synchronized
    }

    func requireResynchronization() {
        exchange.processor.markStreamDirty()
    }

    func markAddressingUnresolved() {
        markedUnresolved = true
    }
}
