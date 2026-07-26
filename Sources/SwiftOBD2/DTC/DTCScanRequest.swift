//
//  DTCScanRequest.swift
//  SwiftOBD2
//
//  The report-producing DTC scan: one request per service, outcome extraction in the DTC
//  layer, and a throwing boundary that only ever lets ``DTCScanError`` escape.
//
//  Phase 1 implements the `.storedOnly` profile (Mode 03). `.full`/`.quickConnect` are refused
//  as a capability error *before* any I/O, so a caller can never receive a report that quietly
//  covers less than it asked for.
//

import Foundation

// MARK: - Transport error disposition

/// How a thrown transport error resolves for a DTC request.
///
/// Terminal interruptions beat per-service failures: a request-scoped timeout or adapter error
/// is only a `.transportFailure` inside a published report **while the link is still up**,
/// because only then can the remaining requested services genuinely be attempted.
enum DTCTransportDisposition: Sendable, Equatable {
    /// The task was cancelled — throws ``DTCScanError/cancelled(_:)``.
    case cancelled
    /// The adapter reported `NO DATA`: silence, not a failure, and never clean.
    case noResponse
    /// The link is gone — throws ``DTCScanError/connectionLost(_:)``.
    case connectionLost
    /// Recoverable and request-scoped: recorded as this service's outcome in a published report.
    case transportFailure(DTCTransportFailure)

    /// Classifies a raw transport error so no undeclared error type can escape the report API.
    ///
    /// - Parameters:
    ///   - error: The error thrown by the comm layer.
    ///   - linkIsUp: Whether the adapter connection still stands after the failure. Recoverable
    ///     failures are per-service outcomes only while the link is up; once it is gone they are
    ///     promoted to link loss, because the remaining services could not be attempted anyway.
    ///     Silence is never *inferred* — only the two explicit `noData` signals produce it.
    init(error: Error, linkIsUp: Bool) {
        if error is CancellationError {
            self = .cancelled
            return
        }

        if let error = error as? BLEManagerError {
            switch error {
            case .noData:
                // The transport-neutral twin of the parser's `NO DATA` line detection.
                self = .noResponse
            case .peripheralNotConnected, .peripheralNotFound, .missingPeripheralOrCharacteristic,
                 .unknownCharacteristic, .unsupported, .unauthorized:
                self = .connectionLost
            case .sendMessageTimeout, .timeout, .scanTimeout:
                self = Self.recoverable(.requestTimeout, linkIsUp: linkIsUp)
            default:
                self = Self.recoverable(.adapterError, linkIsUp: linkIsUp)
            }
            return
        }

        if let error = error as? BLEMessageProcessorError {
            switch error {
            case .staleRequestToken:
                // The request slot's generation was bumped — the processor was reset by a
                // disconnect while this request was in flight.
                self = .connectionLost
            case .responseTimeout:
                self = Self.recoverable(.requestTimeout, linkIsUp: linkIsUp)
            default:
                self = Self.recoverable(.adapterError, linkIsUp: linkIsUp)
            }
            return
        }

        if let error = error as? CommunicationError {
            switch error {
            case .noData:
                // WiFi's twin of `BLEManagerError.noData`: a `NO DATA` line was actually observed.
                self = .noResponse
            case .invalidData, .errorOccurred:
                // Unusable output, a failed write, or a missing socket — never called silence.
                self = Self.recoverable(.adapterError, linkIsUp: linkIsUp)
            }
            return
        }

        if let error = error as? ELM327Error {
            switch error {
            case .timeout:
                self = Self.recoverable(.requestTimeout, linkIsUp: linkIsUp)
            case .connectionFailed:
                self = .connectionLost
            default:
                self = Self.recoverable(.adapterError, linkIsUp: linkIsUp)
            }
            return
        }

        self = Self.recoverable(.adapterError, linkIsUp: linkIsUp)
    }

    private static func recoverable(_ failure: DTCTransportFailure, linkIsUp: Bool) -> DTCTransportDisposition {
        linkIsUp ? .transportFailure(failure) : .connectionLost
    }
}

// MARK: - Non-throwing construction

extension DTCPartialScan {
    /// The evidence carried out of an interruption that happened before any service completed.
    ///
    /// Provably valid: an empty service map cannot claim a service outside the profile and
    /// carries no observation to misattribute, so the validating initialiser cannot reject it.
    static func empty(profile: DTCScanProfile) -> DTCPartialScan {
        // swiftlint:disable:next force_try
        try! DTCPartialScan(profile: profile, services: [:], statusRead: .notAttempted)
    }
}

extension DTCScanReport {
    /// A `.storedOnly` report around a single Mode 03 result.
    ///
    /// The profile requires exactly `.stored`, so validation can only fail on an observation
    /// misattributed to the wrong lineage or ECU — which the parser cannot produce, since it
    /// stamps both from the responder it decoded. Should that ever change, the report degrades
    /// to `.invalidResponse` (never clean) instead of leaking an undeclared error.
    static func storedOnly(_ result: DTCServiceResult) -> DTCScanReport {
        if let report = try? DTCScanReport(profile: .storedOnly, services: [.stored: result]) {
            return report
        }
        obdError("Discarding a misattributed Mode 03 result", category: .parsing)
        // A result with no responders has nothing left to validate, so this cannot throw.
        // swiftlint:disable:next force_try
        return try! DTCScanReport(profile: .storedOnly, services: [.stored: .invalidResponse])
    }
}

// MARK: - ECU projection

extension ECUAddress {
    /// The lossy display classification the deprecated dictionary API is keyed by: the low three
    /// address bits, `0` → engine, `1` → transmission, anything else → unknown.
    var ecuID: ECUID {
        ECUID(rawValue: UInt8(raw & 0x07)) ?? .unknown
    }
}

// MARK: - Scan

extension ELM327 {
    /// Scans for trouble codes and reports per-responder outcomes.
    ///
    /// - Parameter profile: Which services to request. Only ``DTCScanProfile/storedOnly`` is
    ///   implemented in this phase.
    /// - Returns: A report whose `statusRead` is `.notAttempted` — the `0101` read stays with
    ///   the consumer until it moves in-report.
    /// - Throws: Only ``DTCScanError``: `.profileUnsupported` before any I/O for an
    ///   unimplemented profile, `.cancelled`/`.connectionLost` (carrying the completed evidence)
    ///   for terminal interruptions. Recoverable, request-scoped transport failures are
    ///   per-service outcomes in a published report instead.
    func scanForTroubleCodes(profile: DTCScanProfile) async throws -> DTCScanReport {
        guard profile == .storedOnly else {
            throw DTCScanError.profileUnsupported(profile)
        }
        obdInfo("Scanning for stored trouble codes", category: .service)
        let result = try await requestDTCService(.stored, profile: profile)
        return DTCScanReport.storedOnly(result)
    }

    /// Sends one DTC service request and extracts its outcome.
    ///
    /// The request format is unchanged (a bare `"03"`); only the response handling moves.
    private func requestDTCService(
        _ service: DTCService,
        profile: DTCScanProfile
    ) async throws -> DTCServiceResult {
        // Interruption is observed at service boundaries — once a service has resolved, its
        // evidence is kept and the report publishes.
        if Task.isCancelled {
            throw DTCScanError.cancelled(.empty(profile: profile))
        }

        let lines: [String]
        do {
            lines = try await sendCommand(service.requestMode)
        } catch {
            switch DTCTransportDisposition(error: error, linkIsUp: connectionState.isConnected) {
            case .cancelled:
                throw DTCScanError.cancelled(.empty(profile: profile))
            case .connectionLost:
                throw DTCScanError.connectionLost(.empty(profile: profile))
            case .noResponse:
                return .noResponse
            case let .transportFailure(failure):
                return .transportFailure(failure)
            }
        }

        return DTCResponseParser.parse(
            lines: lines,
            service: service,
            family: DTCProtocolFamily(elmID: canProtocol?.elmID)
        )
    }
}

// MARK: - Deprecated dictionary projection

extension DTCScanReport {
    /// Projects a stored-code report onto the deprecated `[ECUID: [TroubleCode]]` shape.
    ///
    /// Address collisions **merge** (two non-engine modules both project to `.unknown`), so no
    /// responder's codes can be overwritten. Codes are returned only when every responder
    /// answered positively; anything else throws, mirroring the dictionary API's historic
    /// all-or-nothing behaviour. An empty dictionary therefore still means *verified clean* —
    /// which is exactly what a `7F`-only response used to fake.
    func legacyStoredCodeDictionary() throws -> [ECUID: [TroubleCode]] {
        guard let result = services[.stored] else {
            throw ELM327Error.invalidResponse(message: "Mode 03 was not attempted")
        }

        switch result {
        case .noResponse:
            throw ELM327Error.invalidResponse(message: "No data in response to mode 03")
        case .invalidResponse:
            throw ELM327Error.invalidResponse(message: "Unusable response to mode 03")
        case let .transportFailure(failure):
            switch failure {
            case .requestTimeout:
                throw ELM327Error.timeout
            case .adapterError:
                throw ELM327Error.invalidResponse(message: "Adapter error during mode 03")
            }
        case let .answered(responders):
            var dtcs: [ECUID: [TroubleCode]] = [:]
            for address in responders.addresses {
                guard let outcome = responders[address] else { continue }
                switch outcome {
                case let .responded(codes):
                    // A clean responder contributes no codes: an empty dictionary is the
                    // verified-clean answer, so no empty key is invented for it either.
                    guard !codes.isEmpty else { continue }
                    let troubleCodes = codes.map {
                        TroubleCode(code: $0.code, description: $0.description ?? "No description available.")
                    }
                    dtcs[address.ecuID, default: []].append(contentsOf: troubleCodes)
                case let .negativeResponse(nrc):
                    throw ELM327Error.invalidResponse(
                        message: "ECU \(address) refused mode 03 (NRC \(nrc))"
                    )
                case .malformed:
                    throw ELM327Error.invalidResponse(
                        message: "Malformed mode 03 response from ECU \(address)"
                    )
                }
            }
            return dtcs
        }
    }
}
