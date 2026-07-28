//
//  DTCScanRequest.swift
//  SwiftOBD2
//
//  The report-producing DTC scan: one request per service, outcome extraction in the DTC
//  layer, and a throwing boundary that only ever lets ``DTCScanError`` escape.
//
//  Every profile is implemented: `.storedOnly` (03), `.quickConnect` (03 + 07) and `.full`
//  (03 + 07 + 0A). Services are requested sequentially, each through the same extraction, and
//  interruption is observed at service boundaries — so a link that dies mid-scan throws while
//  carrying the services that already answered, and a scan whose last service resolved always
//  publishes its report.
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
    /// Recoverable and request-scoped: retried, then recorded as this service's outcome.
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
            case .connectionLost:
                // The socket is gone — terminal, and never mistaken for a quiet vehicle.
                self = .connectionLost
            case .timeout:
                self = Self.recoverable(.requestTimeout, linkIsUp: linkIsUp)
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

// MARK: - Evidence lattice

extension DTCResponderOutcome {
    /// How strong this outcome is as evidence about one responder.
    ///
    /// The ordering is what makes a multi-attempt merge **monotonic**: evidence only ever gets
    /// stronger, so a re-send can never take away what an earlier attempt proved.
    /// - `0` an interim NRC (`0x21` busy / `0x78` pending): the exchange never resolved — the
    ///   weakest thing a responder can say.
    /// - `1` malformed: bytes arrived, unusable.
    /// - `2` a terminal negative response: a definitive answer, but no data obtained.
    /// - `3` `.responded`: verified data (an empty code list included).
    var evidenceRank: Int {
        switch self {
        case let .negativeResponse(nrc):
            return nrc.isTerminal ? 2 : 0
        case .malformed:
            return 1
        case .responded:
            return 3
        }
    }

    /// Combines what one responder said across attempts of the **same** request, monotonically.
    ///
    /// Pure, and the single place the retry-merge policy lives. A flat "latest wins" merge
    /// silently erased verified codes — attempt 1 reports `P0104`, the busy-driven re-send is
    /// answered `43 00`, and the code disappears. The lattice guarantees instead:
    /// - **verified codes are sticky and union**: once a responder reported codes, later answers
    ///   may only *add* to them (deduplicated by code, order-stable), and no later clean, busy,
    ///   malformed or refusal removes or downgrades them;
    /// - **verified clean is sticky against noise**, but upgraded by codes;
    /// - **busy upgrades to anything non-busy** — the whole point of the re-send — and survives as
    ///   the last NRC only when the responder never gave a verified answer;
    /// - **malformed is repaired** by a later verified answer (`.responded`, or a terminal refusal)
    ///   from a fresh exchange, and otherwise stays;
    /// - **a terminal refusal followed by codes yields the codes**: a new exchange is new evidence.
    ///
    /// - Parameters:
    ///   - previous: What this responder had already said, or `nil` on its first appearance.
    ///   - latest: What it said on the newest attempt.
    static func merging(previous: DTCResponderOutcome?, latest: DTCResponderOutcome) -> DTCResponderOutcome {
        guard let previous else { return latest }

        if previous.evidenceRank != latest.evidenceRank {
            return previous.evidenceRank > latest.evidenceRank ? previous : latest
        }

        switch (previous, latest) {
        case let (.responded(previousCodes), .responded(latestCodes)):
            // Union with the previous order first: codes only ever accumulate.
            var codes = previousCodes
            let known = Set(previousCodes.map(\.code))
            codes.append(contentsOf: latestCodes.filter { !known.contains($0.code) })
            return .responded(codes: codes)
        case (.malformed, .malformed):
            return .malformed
        default:
            // Two NRCs of equal rank: the newest is the observed evidence (D15's "last NRC").
            return latest
        }
    }
}

// MARK: - Profiles

extension DTCScanProfile {
    /// The services this profile requests, in the order they are sent.
    ///
    /// `.quickConnect` stops at 07, permanently: the auto-scan work resolved RFC §7 Q1 as
    /// "the connect-time check never requests Mode 0A — on any cadence", and
    /// ``DTCScanProfile/allowedServices`` was tightened to match, so a quick-check report
    /// claiming permanent-code coverage is now unconstructible rather than merely unproduced.
    var requestOrder: [DTCService] {
        switch self {
        case .storedOnly: return [.stored]
        case .quickConnect: return [.stored, .pending]
        case .full: return [.stored, .pending, .permanent]
        }
    }
}

// MARK: - Non-throwing construction

extension DTCPartialScan {
    /// The evidence carried out of an interruption, degrading to the empty partial rather than
    /// letting an undeclared error escape.
    ///
    /// Validation can only reject a service outside the profile or a misattributed observation —
    /// neither of which the scan flow can produce, since it keys results by the service it asked
    /// for and the parser stamps every observation from the responder it decoded.
    static func evidence(
        profile: DTCScanProfile,
        services: [DTCService: DTCServiceResult],
        statusRead: DTCStatusReadResult
    ) -> DTCPartialScan {
        if let partial = try? DTCPartialScan(profile: profile, services: services, statusRead: statusRead) {
            return partial
        }
        obdError("Discarding misattributed partial-scan evidence", category: .parsing)
        return .empty(profile: profile, statusRead: statusRead)
    }

    /// The evidence carried out of an interruption that happened before any service completed.
    ///
    /// Provably valid: an empty service map cannot claim a service outside the profile and
    /// carries no observation to misattribute, so the validating initialiser cannot reject it.
    static func empty(
        profile: DTCScanProfile,
        statusRead: DTCStatusReadResult = .notAttempted
    ) -> DTCPartialScan {
        // swiftlint:disable:next force_try
        try! DTCPartialScan(profile: profile, services: [:], statusRead: statusRead)
    }
}

extension DTCScanReport {
    /// Builds the report for a completed scan, degrading loudly instead of leaking an
    /// undeclared error.
    ///
    /// The flow guarantees validity — it requests exactly the profile's services and the parser
    /// stamps lineage and address from the responder it decoded — so a rejection means the
    /// evidence itself is inconsistent. In that case every required service degrades to
    /// `.invalidResponse`: never clean, never silently short.
    static func evidence(
        profile: DTCScanProfile,
        services: [DTCService: DTCServiceResult],
        statusRead: DTCStatusReadResult = .notAttempted
    ) -> DTCScanReport {
        if let report = try? DTCScanReport(profile: profile, services: services, statusRead: statusRead) {
            return report
        }
        obdError("Discarding a misattributed DTC scan result", category: .parsing)
        var degraded: [DTCService: DTCServiceResult] = [:]
        for service in profile.requestOrder {
            degraded[service] = .invalidResponse
        }
        // Required services are all present and carry no observations, so this cannot throw.
        // swiftlint:disable:next force_try
        return try! DTCScanReport(profile: profile, services: degraded, statusRead: statusRead)
    }

    /// A `.storedOnly` report around a single Mode 03 result.
    static func storedOnly(
        _ result: DTCServiceResult,
        statusRead: DTCStatusReadResult = .notAttempted
    ) -> DTCScanReport {
        evidence(profile: .storedOnly, services: [.stored: result], statusRead: statusRead)
    }
}

// MARK: - Scan

extension ELM327 {
    /// Transport attempts per DTC request, matching `requestPIDs`' three.
    ///
    /// Owned here rather than delegated to the comm layer's own retry loop so the disposition
    /// classifier still decides: a terminal error throws immediately instead of being re-sent.
    static let dtcTransportAttempts = 3
    /// Extra re-sends allowed for a `0x21` busy response — 2 extra, 3 total (D15).
    static let dtcBusyExtraAttempts = 2
    /// Delay before a re-send, long enough for a busy ECU to become ready.
    static let dtcRetryDelay: UInt64 = 250_000_000
    /// Total budget for the extra listen windows a `0x78` response-pending earns.
    static let dtcPendingListenDeadline: TimeInterval = 8.0
    /// The status request that accompanies a scan.
    static let dtcStatusRequest = "0101"

    /// The addressing family the vehicle's current protocol frames responses in.
    var dtcProtocolFamily: DTCProtocolFamily {
        DTCProtocolFamily(elmID: canProtocol?.elmID)
    }

    /// Scans for trouble codes and reports per-responder outcomes.
    ///
    /// Requests the profile's services sequentially, each through the same outcome extraction,
    /// and reads `0101` first as advisory context. A failed status read never fails the scan.
    ///
    /// - Parameter profile: Which services to request.
    /// - Returns: A report covering exactly the requested services, with the per-responder
    ///   `0101` read in `statusRead`.
    /// - Throws: Only ``DTCScanError``: `.cancelled`/`.connectionLost` for terminal
    ///   interruptions, each carrying a ``DTCPartialScan`` with the services that had already
    ///   resolved. Recoverable, request-scoped transport failures are per-service outcomes in a
    ///   published report instead.
    func scanForTroubleCodes(profile: DTCScanProfile) async throws -> DTCScanReport {
        let requested = profile.requestOrder
        obdInfo(
            "Scanning for trouble codes (\(profile.rawValue): \(requested.map(\.requestMode).joined(separator: ", ")))",
            category: .service
        )

        var completed: [DTCService: DTCServiceResult] = [:]
        let statusRead = try await readStatus(profile: profile)

        for (index, service) in requested.enumerated() {
            // Interruption is observed at service *boundaries* — once a service has resolved its
            // evidence is kept, and once the last one resolves the report publishes.
            try checkInterruption(
                isFirstService: index == 0,
                evidence: .evidence(profile: profile, services: completed, statusRead: statusRead)
            )
            let result = try await requestDTCService(
                service,
                profile: profile,
                completed: completed,
                statusRead: statusRead
            )
            recordUnsupportedEvidence(for: service, result: result)
            completed[service] = result
        }

        return DTCScanReport.evidence(profile: profile, services: completed, statusRead: statusRead)
    }

    /// Throws when the scan must stop: an explicit cancellation, or a link that is gone.
    ///
    /// The link is only checked *between* services. Before the first request the connection
    /// state can still be catching up (it is republished on the main queue), and the send itself
    /// classifies link loss anyway — whereas between services the link has already been proven,
    /// so a disconnected state there is real.
    private func checkInterruption(isFirstService: Bool, evidence: DTCPartialScan) throws {
        if Task.isCancelled {
            throw DTCScanError.cancelled(evidence)
        }
        if !isFirstService, !connectionState.isConnected {
            throw DTCScanError.connectionLost(evidence)
        }
    }

    /// Reads `0101` for the report: every responder preserved with its own outcome.
    ///
    /// Advisory context (D17) — a refusal, silence or a recoverable failure is recorded and the
    /// scan continues. Only terminal interruptions throw, and those are not the read failing.
    private func readStatus(profile: DTCScanProfile) async throws -> DTCStatusReadResult {
        if Task.isCancelled {
            throw DTCScanError.cancelled(.empty(profile: profile))
        }
        do {
            let lines = try await sendCommand(Self.dtcStatusRequest)
            return DTCResponseParser.parseStatus(lines: lines, family: dtcProtocolFamily)
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
    }

    /// Sends one DTC service request and extracts its outcome, applying the NRC dispositions.
    ///
    /// The request format is unchanged (a bare `"03"`/`"07"`/`"0A"`); only the response handling
    /// and the re-send rules live here:
    /// - a thrown *recoverable* error is retried up to ``dtcTransportAttempts`` times;
    /// - `0x78` response-pending is **never** retransmitted — the transport keeps listening
    ///   inside one exclusive transaction until the exchange resolves or its budget runs out;
    /// - `0x21` busy re-sends the same request, at most twice more, and every attempt's evidence
    ///   is **merged per responder** rather than replacing the previous one.
    private func requestDTCService(
        _ service: DTCService,
        profile: DTCScanProfile,
        completed: [DTCService: DTCServiceResult],
        statusRead: DTCStatusReadResult
    ) async throws -> DTCServiceResult {
        var transportAttempts = 0
        var busyAttempts = 0
        /// Evidence accumulated across busy re-sends, combined per responder through the
        /// monotonic lattice: a responder is never dropped because a later buffer omitted it, and
        /// never downgraded because a later buffer said something weaker.
        var merged: [ECUAddress: DTCResponderOutcome] = [:]

        while true {
            let evidence = DTCPartialScan.evidence(
                profile: profile,
                services: completed,
                statusRead: statusRead
            )

            let lines: [String]
            do {
                lines = try await sendDTCRequest(service)
            } catch {
                switch DTCTransportDisposition(error: error, linkIsUp: connectionState.isConnected) {
                case .cancelled:
                    throw DTCScanError.cancelled(evidence)
                case .connectionLost:
                    throw DTCScanError.connectionLost(evidence)
                case .noResponse:
                    // Silence on a re-send never erases what an earlier attempt proved.
                    if let accumulated = Self.answered(merged) { return accumulated }
                    return .noResponse
                case let .transportFailure(failure):
                    transportAttempts += 1
                    guard transportAttempts < Self.dtcTransportAttempts else {
                        if let accumulated = Self.answered(merged) { return accumulated }
                        return .transportFailure(failure)
                    }
                    obdDebug(
                        "Mode \(service.requestMode): recoverable \(failure), attempt \(transportAttempts + 1)",
                        category: .communication
                    )
                    try await pauseBeforeResend(evidence: evidence)
                    continue
                }
            }

            let result = DTCResponseParser.parse(lines: lines, service: service, family: dtcProtocolFamily)

            // The first attempt's request-level answer stands on its own; a *re-send* that
            // produces no responders must not discard the evidence already gathered.
            guard let responders = result.responders else {
                if let accumulated = Self.answered(merged) { return accumulated }
                return result
            }
            // Monotonic per responder: a re-send may only strengthen the evidence, never erase a
            // verified answer an earlier attempt already obtained.
            for address in responders.addresses {
                guard let latest = responders[address] else { continue }
                merged[address] = DTCResponderOutcome.merging(previous: merged[address], latest: latest)
            }

            let busyResponders = Self.busyResponders(in: merged)
            guard !busyResponders.isEmpty, busyAttempts < Self.dtcBusyExtraAttempts else {
                return Self.answered(merged) ?? result
            }
            busyAttempts += 1
            obdDebug(
                "Mode \(service.requestMode): ECU(s) \(busyResponders.map(\.description).joined(separator: ", ")) "
                    + "busy (0x21), re-sending (attempt \(busyAttempts + 1))",
                category: .communication
            )
            try await pauseBeforeResend(evidence: evidence)
        }
    }

    /// Sends one DTC request as an **exclusive transaction**: the write, and every extra listen
    /// window a `7F … 78` earns, happen under a single hold of the transport's command mutex.
    ///
    /// D15 forbids retransmitting a response-pending — the ECU is working on the answer — and the
    /// ELM327 itself extends its timeout on `7F xx 78` in most firmwares, so the final message
    /// usually lands in the same buffered read and the parser's supersede rule handles it with no
    /// extra window at all. When it does not, the transport keeps listening (repeatedly, while any
    /// responder is still pending) without ever sending again, and no other caller's command can
    /// slip in and consume the ECU's final message. Cancellation and link loss propagate as thrown
    /// errors so the caller maps them to terminal interruptions rather than publishing a report
    /// built on stale interim evidence.
    ///
    /// If a transport cannot listen again without sending, its default transaction is a plain
    /// single-shot send: the `0x78` simply stays the recorded evidence, never upgraded, never
    /// invented.
    private func sendDTCRequest(_ service: DTCService) async throws -> [String] {
        let family = dtcProtocolFamily
        return try await commManager.sendCommandTransaction(
            service.requestMode,
            retries: 1,
            shouldContinueListening: { lines in
                DTCResponseParser.awaitsPendingResponse(lines: lines, service: service, family: family)
            },
            listenDeadline: Self.dtcPendingListenDeadline
        )
    }

    /// Waits between re-sends, honouring cancellation as a terminal interruption.
    private func pauseBeforeResend(evidence: DTCPartialScan) async throws {
        try? await Task.sleep(nanoseconds: Self.dtcRetryDelay)
        if Task.isCancelled {
            throw DTCScanError.cancelled(evidence)
        }
    }

    /// The accumulated evidence as a request-level result, or `nil` when nothing accumulated.
    private static func answered(_ merged: [ECUAddress: DTCResponderOutcome]) -> DTCServiceResult? {
        DTCResponders(merged).map { .answered($0) }
    }

    /// The responders whose **latest** answer is `0x21` busy.
    ///
    /// Only these justify another send, and they justify it regardless of what the other
    /// responders did: another module being malformed or refusing must not veto a busy ECU's
    /// second chance, and a module that already answered keeps its answer either way.
    private static func busyResponders(in merged: [ECUAddress: DTCResponderOutcome]) -> [ECUAddress] {
        merged.keys.sorted { $0.raw < $1.raw }.filter { address in
            if case let .negativeResponse(nrc) = merged[address] { return nrc == .busyRepeatRequest }
            return false
        }
    }

    /// Populates the **advisory** unsupported cache from terminal `0x11`/`0x12` refusals only.
    ///
    /// Never read back to suppress a request: a functional broadcast can reach modules that do
    /// support the service even when one module refuses it.
    private func recordUnsupportedEvidence(for service: DTCService, result: DTCServiceResult) {
        guard let responders = result.responders else { return }
        for address in responders.addresses {
            guard let outcome = responders[address],
                  case let .negativeResponse(nrc) = outcome,
                  nrc.derivesUnsupported
            else { continue }
            unsupportedServiceStore.record(
                DTCUnsupportedServiceKey(
                    vehicleScope: dtcEvidenceScope,
                    ecuAddress: address,
                    protocolID: canProtocol?.elmID,
                    service: service
                ),
                nrc: nrc
            )
        }
    }
}
