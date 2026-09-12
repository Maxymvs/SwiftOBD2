@testable import SwiftOBD2
import Foundation
import XCTest

final class BLEWriteAcknowledgementLedgerTests: XCTestCase {
    func testLateOldAcknowledgementCannotAdvanceNewTransfer() async throws {
        let ledger = BLEWriteAcknowledgementLedger()
        let coordinator = BLEWriteCoordinator()
        let recorder = AcknowledgementLedgerTestRecorder()
        let peripheralID = UUID()
        let characteristicUUID = "FFE1"

        let oldSession = coordinator.activateSession()
        let transport = AcknowledgementLedgerTestTransport(
            maximumLength: 2,
            ledger: ledger,
            session: oldSession,
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID,
            recorder: recorder
        )
        let oldTask = Task {
            try await coordinator.write(
                Data("ABCD".utf8),
                mode: .withResponse,
                session: oldSession,
                transport: transport,
                deadline: 3
            )
        }
        await waitForWrites(1, from: recorder)
        coordinator.invalidateSession(oldSession, with: AcknowledgementLedgerTestError.disconnected)
        await assertThrows(oldTask, AcknowledgementLedgerTestError.disconnected)

        let newSession = coordinator.activateSession()
        let newTransport = AcknowledgementLedgerTestTransport(
            maximumLength: 2,
            ledger: ledger,
            session: newSession,
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID,
            recorder: recorder
        )
        let newTask = Task {
            try await coordinator.write(
                Data("EFGH".utf8),
                mode: .withResponse,
                session: newSession,
                transport: newTransport,
                deadline: 3
            )
        }
        await waitForWrites(2, from: recorder)

        let lateOldSession = try XCTUnwrap(ledger.consumeAcknowledgement(
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID
        ))
        coordinator.didReceiveAcknowledgement(session: lateOldSession, error: nil)
        await coordinator.drainEvents()
        XCTAssertEqual(recorder.writes.count, 2)

        let currentSession = try XCTUnwrap(ledger.consumeAcknowledgement(
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID
        ))
        coordinator.didReceiveAcknowledgement(session: currentSession, error: nil)
        await waitForWrites(3, from: recorder)
        let finalSession = try XCTUnwrap(ledger.consumeAcknowledgement(
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID
        ))
        coordinator.didReceiveAcknowledgement(session: finalSession, error: nil)
        try await newTask.value
    }

    func testConfirmedDisconnectClearsAbandonedAcknowledgementBeforeReconnect() async throws {
        let ledger = BLEWriteAcknowledgementLedger()
        let coordinator = BLEWriteCoordinator()
        let recorder = AcknowledgementLedgerTestRecorder()
        let peripheralID = UUID()
        let characteristicUUID = "FFE1"
        let oldSession = coordinator.activateSession()
        let transport = AcknowledgementLedgerTestTransport(
            maximumLength: 2,
            ledger: ledger,
            session: oldSession,
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID,
            recorder: recorder
        )
        let oldTask = Task {
            try await coordinator.write(
                Data("ABCD".utf8),
                mode: .withResponse,
                session: oldSession,
                transport: transport,
                deadline: 3
            )
        }
        await waitForWrites(1, from: recorder)
        coordinator.invalidateSession(oldSession, with: AcknowledgementLedgerTestError.disconnected)
        await assertThrows(oldTask, AcknowledgementLedgerTestError.disconnected)

        ledger.confirmedDisconnect(peripheralID: peripheralID)
        XCTAssertNil(ledger.consumeAcknowledgement(
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID
        ))
        let newSession = coordinator.activateSession()
        let newTransport = AcknowledgementLedgerTestTransport(
            maximumLength: 2,
            ledger: ledger,
            session: newSession,
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID,
            recorder: recorder
        )
        let newTask = Task {
            try await coordinator.write(
                Data("EFGH".utf8),
                mode: .withResponse,
                session: newSession,
                transport: newTransport,
                deadline: 3
            )
        }
        await waitForWrites(2, from: recorder)

        let firstReconnectAcknowledgement = try XCTUnwrap(ledger.consumeAcknowledgement(
            peripheralID: peripheralID,
            characteristicUUID: "0000FFE1-0000-1000-8000-00805F9B34FB"
        ))
        XCTAssertEqual(firstReconnectAcknowledgement, newSession)
        coordinator.didReceiveAcknowledgement(session: firstReconnectAcknowledgement, error: nil)
        await waitForWrites(3, from: recorder)

        let secondReconnectAcknowledgement = try XCTUnwrap(ledger.consumeAcknowledgement(
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID
        ))
        coordinator.didReceiveAcknowledgement(session: secondReconnectAcknowledgement, error: nil)
        try await newTask.value
    }

    private func waitForWrites(
        _ count: Int,
        from recorder: AcknowledgementLedgerTestRecorder
    ) async {
        let reached = expectation(description: "transport reached \(count) writes")
        recorder.notifyWhenWriteCountReaches(count) { reached.fulfill() }
        await fulfillment(of: [reached], timeout: 1)
    }

    private func assertThrows<E: Error & Equatable>(
        _ task: Task<Void, Error>,
        _ expected: E,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }
}

private enum AcknowledgementLedgerTestError: Error, Equatable {
    case disconnected
}

private final class AcknowledgementLedgerTestTransport: BLEWriteTransport, @unchecked Sendable {
    private let maximumLength: Int
    private let ledger: BLEWriteAcknowledgementLedger
    private let peripheralID: UUID
    private let characteristicUUID: String
    private let session: UInt64
    private let recorder: AcknowledgementLedgerTestRecorder

    init(
        maximumLength: Int,
        ledger: BLEWriteAcknowledgementLedger,
        session: UInt64,
        peripheralID: UUID,
        characteristicUUID: String,
        recorder: AcknowledgementLedgerTestRecorder
    ) {
        self.maximumLength = maximumLength
        self.ledger = ledger
        self.session = session
        self.peripheralID = peripheralID
        self.characteristicUUID = characteristicUUID
        self.recorder = recorder
    }

    func maximumWriteValueLength(for _: BLEWriteMode) -> Int { maximumLength }
    var canSendWriteWithoutResponse: Bool { true }

    func write(_ data: Data, mode _: BLEWriteMode) {
        let callbacks = ledger.recordingSubmission(
            session: session,
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID
        ) {
            recorder.record(data)
        }
        callbacks.forEach { $0() }
    }
}

private final class AcknowledgementLedgerTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedWrites: [Data] = []
    private var observers: [(count: Int, action: () -> Void)] = []

    var writes: [Data] { lock.withLock { recordedWrites } }

    func notifyWhenWriteCountReaches(_ count: Int, action: @escaping () -> Void) {
        let shouldRun = lock.withLock { () -> Bool in
            if recordedWrites.count >= count { return true }
            observers.append((count, action))
            return false
        }
        if shouldRun { action() }
    }

    func record(_ data: Data) -> [() -> Void] {
        lock.withLock {
            recordedWrites.append(data)
            let callbacks = observers
                .filter { recordedWrites.count >= $0.count }
                .map(\.action)
            observers.removeAll { recordedWrites.count >= $0.count }
            return callbacks
        }
    }
}
