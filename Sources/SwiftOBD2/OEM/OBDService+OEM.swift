//
//  OBDService+OEM.swift
//  SwiftOBD2
//
//  The public entry point for manufacturer (Mode 22) live data. The only way in is a typed
//  `OEMReadBatch` built from catalog definitions; there is no raw request here.
//

import Foundation

/// Transport-level reasons a batch can't run.
enum OEMTransportError: Error, Equatable {
    /// The transport can't hold its command channel for a whole batch.
    case unsupportedTransport
    /// The batch's deadline passed while waiting for the command channel. Nothing was sent.
    case deadlineExpired
}

extension OBDService {
    /// Whether the adapter with this Bluetooth peripheral id is unresolved **right now**: a
    /// manufacturer batch left its addressing unverified and no verified recovery (reset,
    /// re-initialization, functional probe) has completed on it since. The transport refuses
    /// vehicle requests to it while this is true.
    ///
    /// A batch result that says "unresolved" describes the moment the batch ended. Ask this
    /// before acting on such a result later: the adapter may have recovered in between.
    public func isManufacturerAddressingUnresolved(adapterID: UUID) -> Bool {
        OEMAddressingGate.shared.isUnresolved(adapterID)
    }

    /// Reads up to four manufacturer data identifiers from one module, under one exclusive
    /// acquisition of the adapter: configure, read, restore functional addressing, verify.
    ///
    /// Never throws. Every read gets a typed outcome; `failure` says why a batch stopped early or
    /// never started; `adapterState == .unresolved` means the adapter needs a verified recovery
    /// before vehicle requests work again (the transport refuses them until then).
    ///
    /// The batch's budget is one absolute deadline that starts here: waiting for the adapter,
    /// setup, every write and every answer all spend it. Cancelling the calling task stops the
    /// reads; only the restore is shielded.
    ///
    /// - Parameter admission: Asked once the adapter is held and again before every read. Return
    ///   `false` when the caller no longer owns this work (its request ended, the link or the car
    ///   changed, the module is no longer served); the batch then stops and restores.
    public func readManufacturerData(
        _ batch: OEMReadBatch,
        admission: OEMBatchAdmission? = nil
    ) async -> OEMBatchResult {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + batch.budget
        func notStarted(_ failure: OEMBatchFailure, state: OEMAdapterState = .functional) -> OEMBatchResult {
            let reason: OEMSkipReason
            switch failure {
            case .cancelled: reason = .cancelled
            case .linkLost: reason = .linkLost
            default: reason = .batchNotStarted
            }
            return OEMBatchResult(
                reads: batch.commands.map { OEMReadResult(commandID: $0.id, outcome: .notAttempted(reason)) },
                adapterState: state,
                failure: failure,
                elapsed: ProcessInfo.processInfo.systemUptime - started
            )
        }

        guard connectionState == .connectedToVehicle,
              let connection = manufacturerDataConnection else { return notStarted(.notConnected) }
        switch connection.obdProtocol {
        case .protocol6, .protocol8:
            break
        default:
            return notStarted(.unsupportedProtocol)
        }
        // The batch was validated when it was built; check again at the point of sending.
        do {
            try OEMRequestPolicy.validate(
                target: batch.module.target,
                dataIdentifiers: batch.commands.map(\.dataIdentifier)
            )
        } catch let violation as OEMPolicyViolation {
            return notStarted(.policy(violation))
        } catch {
            return notStarted(.policy(.targetNotAllowed))
        }
        if Task.isCancelled { return notStarted(.cancelled) }

        let executor = OEMBatchExecutor(batch: batch)
        do {
            return try await connection.transport.withExclusiveCommandChannel(deadline: deadline) { channel in
                await executor.run(on: channel, deadline: deadline, admission: admission, isLinkCurrent: {
                    self.vehicleLink == connection.link
                })
            }
        } catch OEMTransportError.unsupportedTransport {
            return notStarted(.unsupportedTransport)
        } catch OEMTransportError.deadlineExpired {
            return notStarted(.deadlineExpired)
        } catch OEMAddressingGateError.addressingUnresolved {
            return notStarted(.adapterUnresolved, state: .unresolved)
        } catch is CancellationError {
            return notStarted(.cancelled)
        } catch {
            return notStarted(.linkLost)
        }
    }
}
