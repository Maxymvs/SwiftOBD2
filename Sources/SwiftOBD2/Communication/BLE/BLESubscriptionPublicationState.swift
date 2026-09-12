import Foundation

/// Tracks the externally published part of one notification subscription.
/// The owner supplies connection-token fencing before mutating this value.
struct BLESubscriptionPublicationState: Equatable, Sendable {
    private(set) var didPublishReady = false
    private(set) var didPublishLoss = false

    mutating func claimReady() -> Bool {
        guard !didPublishReady else { return false }
        didPublishReady = true
        return true
    }

    mutating func claimLoss() -> Bool {
        guard didPublishReady, !didPublishLoss else { return false }
        didPublishLoss = true
        return true
    }
}
