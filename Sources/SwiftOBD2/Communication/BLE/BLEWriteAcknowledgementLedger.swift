import Foundation

/// Preserves the write-session provenance that CoreBluetooth omits from
/// `didWriteValueFor` callbacks.
///
/// Entries intentionally survive a handler reset: `cancelPeripheralConnection`
/// is asynchronous and an acknowledgement from the old session may still be
/// delivered while the same cached peripheral is being prepared again. A
/// confirmed local disconnect callback is the boundary where CoreBluetooth has
/// ended this app's connection and abandoned entries can safely be cleared.
final class BLEWriteAcknowledgementLedger: @unchecked Sendable {
    private struct Entry {
        let peripheralID: UUID
        let characteristicUUID: String
        let session: UInt64
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func recordSubmission(
        session: UInt64,
        peripheralID: UUID,
        characteristicUUID: String
    ) {
        let normalizedUUID = BLECharacteristicDescriptor.normalize(characteristicUUID)
        lock.withLock {
            entries.append(Entry(
                peripheralID: peripheralID,
                characteristicUUID: normalizedUUID,
                session: session
            ))
        }
    }

    /// Records provenance at the same boundary as the physical write. If the
    /// transport rejects the write synchronously, remove that unsent entry.
    func recordingSubmission<T>(
        session: UInt64,
        peripheralID: UUID,
        characteristicUUID: String,
        operation: () throws -> T
    ) rethrows -> T {
        let normalizedUUID = BLECharacteristicDescriptor.normalize(characteristicUUID)
        recordSubmission(
            session: session,
            peripheralID: peripheralID,
            characteristicUUID: normalizedUUID
        )
        do {
            return try operation()
        } catch {
            lock.withLock {
                if let index = entries.lastIndex(where: {
                    $0.peripheralID == peripheralID
                        && $0.characteristicUUID == normalizedUUID
                        && $0.session == session
                }) {
                    entries.remove(at: index)
                }
            }
            throw error
        }
    }

    func consumeAcknowledgement(
        peripheralID: UUID,
        characteristicUUID: String
    ) -> UInt64? {
        let normalizedUUID = BLECharacteristicDescriptor.normalize(characteristicUUID)
        return lock.withLock {
            guard let index = entries.firstIndex(where: {
                $0.peripheralID == peripheralID && $0.characteristicUUID == normalizedUUID
            }) else { return nil }
            return entries.remove(at: index).session
        }
    }

    func confirmedDisconnect(peripheralID: UUID) {
        lock.withLock {
            entries.removeAll { $0.peripheralID == peripheralID }
        }
    }
}
