//
//  OEMBatchResult.swift
//  SwiftOBD2
//
//  What one manufacturer batch produced: an outcome per read, and whether the adapter is back
//  in its normal (functional) addressing. Every outcome is typed; nothing here is ever a guess.
//

import Foundation

public struct OEMBatchResult: Sendable {
    /// One per command, in the batch's order.
    public let reads: [OEMReadResult]
    public let adapterState: OEMAdapterState
    /// Why the batch stopped early or never started; nil when it ran to the end.
    public let failure: OEMBatchFailure?
    /// Wall time from the start of the batch through restore.
    public let elapsed: TimeInterval
}

public enum OEMAdapterState: Sendable, Equatable {
    /// Never left functional addressing, or was restored and verified with a `41 00` answer.
    case functional
    /// Restore failed or couldn't be verified. The transport refuses vehicle requests to this
    /// adapter until a verified recovery (see `OEMAddressingGate`).
    case unresolved
}

public enum OEMBatchFailure: Sendable, Equatable {
    case notConnected
    /// The session isn't 11-bit CAN (protocols 6 and 8).
    case unsupportedProtocol
    /// The transport can't hold its command channel for a whole batch (WiFi, demo).
    case unsupportedTransport
    case policy(OEMPolicyViolation)
    /// The adapter answered `?` to a configuration command.
    case configurationRejected(command: String)
    /// A configuration command timed out or answered something other than `OK`.
    case configurationFailed
    case cancelled
    case linkLost
    /// An earlier batch left the adapter unresolved and it hasn't been through a verified
    /// recovery since, so this one didn't start.
    case adapterUnresolved
    /// The batch's deadline passed before the adapter was free, so nothing was sent.
    case deadlineExpired
    /// The caller's admission check said no once the adapter was held, or between reads.
    case admissionRevoked
}

public struct OEMReadResult: Sendable, Equatable {
    public let commandID: String
    public let outcome: OEMReadOutcome
}

public enum OEMReadOutcome: Sendable, Equatable {
    case values([OEMSignalValue])
    /// `7F 22 <code>`, e.g. 0x31 "request out of range" or 0x33 "security access denied".
    case negativeResponse(code: UInt8)
    /// Nothing came back (`NO DATA`, an empty reply, or no answer in time).
    case noAnswer
    /// The module answered "response pending" (`7F 22 78`) and its real answer didn't arrive
    /// while the batch kept listening. Never a value, and never asked a second time.
    case responsePendingOnly
    /// Frames arrived, but none from the module that was asked.
    case wrongResponder
    case malformed(OEMMalformedReply)
    case notAttempted(OEMSkipReason)
}

public enum OEMMalformedReply: Sendable, Equatable {
    /// A frame was out of sequence, over-long, not hex, or otherwise damaged.
    case corruptedFrame
    /// A multi-frame reply stopped before its declared length.
    case incomplete
    /// The reply wasn't `62` (or `7F 22 …`).
    case unexpectedService
    /// `62` echoed a different identifier.
    case identifierMismatch
    /// The payload length isn't one the catalog has seen from a real car.
    case unexpectedLength
    /// A signal's bits run past the end of the payload.
    case payloadTooShort
}

public enum OEMSkipReason: Sendable, Equatable {
    case budgetExhausted
    case cancelled
    case configurationFailed
    case linkLost
    /// An earlier command in the batch got no prompt, so its answer could still arrive and be
    /// mistaken for this read's. This read was never sent.
    case streamOutOfSync
    /// The caller's admission check said no before this read was sent.
    case admissionRevoked
    /// The batch never started (not connected, wrong protocol or transport, policy, or an
    /// unresolved adapter); `OEMBatchResult.failure` says which.
    case batchNotStarted
}

public struct OEMSignalValue: Sendable, Equatable {
    public let signalID: String
    public let value: OEMDecodedValue
}
