import Foundation

struct BLEValidatedAdapterBinding: Codable, Equatable, Sendable {
    let profileID: String
    let profileVersion: Int
    let source: BLEAdapterProfileSource
    let serviceUUID: String
    let readCharacteristicUUID: String
    let writeCharacteristicUUID: String
    let writeType: BLEAdapterWriteType
    let fingerprint: BLEGATTFingerprint
    let validatedAt: Date

    fileprivate init(
        binding: BLEAdapterBinding,
        fingerprint: BLEGATTFingerprint,
        validatedAt: Date
    ) {
        profileID = binding.profile.id
        profileVersion = binding.profile.version
        source = binding.source
        serviceUUID = binding.profile.serviceUUID
        readCharacteristicUUID = binding.readCharacteristicUUID
        writeCharacteristicUUID = binding.writeCharacteristicUUID
        writeType = binding.writeType
        self.fingerprint = fingerprint
        self.validatedAt = validatedAt
    }
}

/// Small local cache keyed by CoreBluetooth's peripheral identifier. Cached
/// records authorize trying a previously validated unknown peripheral, but the
/// caller must still rediscover the graph, subscribe, and repeat ELM validation.
final class BLEAdapterBindingCache {
    private struct Entry: Codable {
        var record: BLEValidatedAdapterBinding
        var lastAccessedAt: Date
    }

    private struct Payload: Codable {
        var schemaVersion: Int
        var entries: [String: Entry]
    }

    private static let schemaVersion = 1
    private static let maximumEncodedBytes = 64 * 1024
    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumEntryCount: Int
    private let registry: BLEAdapterRegistry
    private let now: () -> Date
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "SwiftOBD2.BLEAdapterBindingCache",
        maximumEntryCount: Int = 8,
        registry: BLEAdapterRegistry = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.registry = registry
        self.now = now
    }

    /// Returns a validated hint only when the freshly discovered graph and the
    /// current profile version still match. Any mismatch invalidates the entry.
    func record(
        forPeripheralID peripheralID: String,
        fingerprint: BLEGATTFingerprint
    ) -> BLEValidatedAdapterBinding? {
        lock.lock()
        defer { lock.unlock() }
        var payload = loadPayload()
        guard var entry = payload.entries[peripheralID] else { return nil }
        guard entry.record.fingerprint == fingerprint,
              isCurrentProfile(entry.record) else {
            payload.entries.removeValue(forKey: peripheralID)
            savePayload(payload)
            return nil
        }

        entry.lastAccessedAt = now()
        payload.entries[peripheralID] = entry
        savePayload(payload)
        return entry.record
    }

    /// Cheap pre-discovery hint. A true result permits collecting an unknown
    /// graph, but callers must still call `record(forPeripheralID:fingerprint:)`
    /// with the fresh fingerprint before authorizing inferred resolution.
    func hasCurrentValidatedRecord(forPeripheralID peripheralID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var payload = loadPayload()
        guard let entry = payload.entries[peripheralID] else { return false }
        guard isCurrentProfile(entry.record) else {
            payload.entries.removeValue(forKey: peripheralID)
            savePayload(payload)
            return false
        }
        return true
    }

    /// Inferred channels are never persisted until ATI and ATE0 have both
    /// succeeded. Returns false when the supplied state lacks that evidence.
    @discardableResult
    func storeValidatedBinding(
        _ binding: BLEAdapterBinding,
        forPeripheralID peripheralID: String,
        fingerprint: BLEGATTFingerprint,
        validation: BLEAdapterValidationState
    ) -> Bool {
        guard validation.isAdapterValidated else { return false }
        lock.lock()
        defer { lock.unlock() }

        return store(
            binding,
            forPeripheralID: peripheralID,
            fingerprint: fingerprint,
            timestamp: now()
        )
    }

    /// Known registry layouts use the library's established initialization
    /// sequence. This entry point is called only after that sequence succeeds;
    /// inferred bindings must use the strict ATI/ATE0 validation overload.
    @discardableResult
    func storeInitializedKnownBinding(
        _ binding: BLEAdapterBinding,
        forPeripheralID peripheralID: String,
        fingerprint: BLEGATTFingerprint
    ) -> Bool {
        guard binding.source == .known else { return false }
        lock.lock()
        defer { lock.unlock() }
        return store(
            binding,
            forPeripheralID: peripheralID,
            fingerprint: fingerprint,
            timestamp: now()
        )
    }

    func removeRecord(forPeripheralID peripheralID: String) {
        lock.lock()
        defer { lock.unlock() }
        var payload = loadPayload()
        payload.entries.removeValue(forKey: peripheralID)
        savePayload(payload)
    }

    private func isCurrentProfile(_ record: BLEValidatedAdapterBinding) -> Bool {
        switch record.source {
        case .known:
            return registry.profiles.contains {
                $0.id == record.profileID && $0.version == record.profileVersion
            }
        case .inferred:
            return record.profileID == BLEAdapterProfile.inferredProfileID
                && record.profileVersion == BLEAdapterProfile.inferredProfileVersion
        }
    }

    private func store(
        _ binding: BLEAdapterBinding,
        forPeripheralID peripheralID: String,
        fingerprint: BLEGATTFingerprint,
        timestamp: Date
    ) -> Bool {
        let record = BLEValidatedAdapterBinding(
            binding: binding,
            fingerprint: fingerprint,
            validatedAt: timestamp
        )
        var payload = loadPayload()
        payload.entries[peripheralID] = Entry(record: record, lastAccessedAt: timestamp)
        trimToMaximumEntryCount(&payload)
        savePayload(payload)
        return true
    }

    private func loadPayload() -> Payload {
        guard let data = defaults.data(forKey: storageKey) else {
            return Payload(schemaVersion: Self.schemaVersion, entries: [:])
        }
        guard data.count <= Self.maximumEncodedBytes else {
            defaults.removeObject(forKey: storageKey)
            return Payload(schemaVersion: Self.schemaVersion, entries: [:])
        }
        do {
            var payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.schemaVersion == Self.schemaVersion else {
                defaults.removeObject(forKey: storageKey)
                return Payload(schemaVersion: Self.schemaVersion, entries: [:])
            }
            let previousCount = payload.entries.count
            trimToMaximumEntryCount(&payload)
            if payload.entries.count != previousCount {
                savePayload(payload)
            }
            return payload
        } catch {
            defaults.removeObject(forKey: storageKey)
            return Payload(schemaVersion: Self.schemaVersion, entries: [:])
        }
    }

    private func savePayload(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload),
              data.count <= Self.maximumEncodedBytes else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private func trimToMaximumEntryCount(_ payload: inout Payload) {
        while payload.entries.count > maximumEntryCount,
              let oldestKey = payload.entries.min(by: {
                  if $0.value.lastAccessedAt != $1.value.lastAccessedAt {
                      return $0.value.lastAccessedAt < $1.value.lastAccessedAt
                  }
                  return $0.key < $1.key
              })?.key {
            payload.entries.removeValue(forKey: oldestKey)
        }
    }
}
