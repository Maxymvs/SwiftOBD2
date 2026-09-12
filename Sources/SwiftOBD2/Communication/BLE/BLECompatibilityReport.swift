import Foundation

public enum BLECompatibilityStage: String, Codable, Equatable, Sendable {
    case discovery
    case gattResolved
    case subscription
    case adapterIdentification
    case adapterConfiguration
    case adapterValidated
    case vehicleProbe
    case compatible
    case failed
    case disconnected
}

public enum BLESubscriptionStatus: String, Codable, Equatable, Sendable {
    case notRequested
    case pending
    case confirmed
    case failed
}

/// Redacted failure categories suitable for app diagnostics. Associated raw
/// errors, peripheral identifiers, adapter responses, and vehicle data stay out
/// of this boundary.
public enum BLECompatibilityFailure: String, Codable, Equatable, Sendable {
    case transportUnavailable
    case unsupportedGATT
    case ambiguousGATT
    case notificationSubscriptionFailed
    case adapterIdentificationRejected
    case adapterConfigurationRejected
    case adapterResponseTimedOut
    case vehicleECUUnavailable
    case writeFailed
    case writeTimedOut
    case cancelled
    case disconnected
}

/// Fences async stage updates so an earlier connection attempt cannot replace
/// the report for a newer attempt.
final class BLECompatibilityAttemptFence {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == candidate
    }
}

enum BLECompatibilityResetPolicy {
    static func shouldRecordDisconnected(
        preservedAttempt: UInt64?,
        currentAttempt: UInt64
    ) -> Bool {
        preservedAttempt != currentAttempt
    }
}

/// Latest compatibility attempt exposed to the host app. This is a value
/// snapshot: callers cannot mutate it and it contains no device or vehicle ID.
public struct BLECompatibilityReport: Codable, Equatable, Sendable {
    public let profileID: String?
    public let profileVersion: Int?
    public let source: BLEAdapterProfileSource?
    public let stage: BLECompatibilityStage
    public let subscription: BLESubscriptionStatus
    public let failure: BLECompatibilityFailure?
    public let capturedAt: Date

    public init(
        profileID: String?,
        profileVersion: Int?,
        source: BLEAdapterProfileSource?,
        stage: BLECompatibilityStage,
        subscription: BLESubscriptionStatus,
        failure: BLECompatibilityFailure?,
        capturedAt: Date = Date()
    ) {
        self.profileID = profileID
        self.profileVersion = profileVersion
        self.source = source
        self.stage = stage
        self.subscription = subscription
        self.failure = failure
        self.capturedAt = capturedAt
    }
}

extension BLECompatibilityReport {
    init(
        binding: BLEAdapterBinding?,
        stage: BLECompatibilityStage,
        subscription: BLESubscriptionStatus,
        failure: BLECompatibilityFailure? = nil,
        capturedAt: Date = Date()
    ) {
        self.init(
            profileID: binding?.profile.id,
            profileVersion: binding?.profile.version,
            source: binding?.source,
            stage: stage,
            subscription: subscription,
            failure: failure,
            capturedAt: capturedAt
        )
    }
}
