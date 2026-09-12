@testable import SwiftOBD2
import XCTest

final class BLEAdapterValidationTests: XCTestCase {
    func testCommandFailureMappingKeepsTransportFailuresPreciseAndIgnoresNoData() {
        XCTAssertEqual(
            BLEManager.commandCompatibilityFailure(for: BLEWriteCoordinatorError.deadlineExceeded),
            .writeTimedOut
        )
        XCTAssertEqual(
            BLEManager.commandCompatibilityFailure(for: BLEWriteCoordinatorError.acknowledgementFailed("rejected")),
            .writeFailed
        )
        XCTAssertEqual(
            BLEManager.commandCompatibilityFailure(for: BLEMessageProcessorError.responseTimeout),
            .adapterResponseTimedOut
        )
        XCTAssertEqual(
            BLEManager.commandCompatibilityFailure(for: BLEMessageProcessorError.staleRequestToken),
            .disconnected
        )
        XCTAssertEqual(
            BLEManager.commandCompatibilityFailure(for: BLEManagerError.peripheralNotConnected),
            .disconnected
        )
        XCTAssertEqual(
            BLEManager.commandCompatibilityFailure(for: CancellationError()),
            .cancelled
        )
        XCTAssertNil(BLEManager.commandCompatibilityFailure(for: BLEManagerError.noData))
        XCTAssertNil(BLEManager.commandCompatibilityFailure(for: BLEManagerError.adapterIdentificationRejected))
    }

    func testDisconnectPreservesTerminalFailureButReplacesSuccessfulState() {
        let graph = BLECompatibilityService(
            uuid: "FFE0",
            characteristics: [
                BLECompatibilityCharacteristic(
                    uuid: "FFE1",
                    properties: [.notify, .writeWithResponse]
                ),
            ]
        )
        let channel = BLECompatibilityChannel(
            serviceUUID: "FFE0",
            readCharacteristic: graph.characteristics[0],
            writeCharacteristic: graph.characteristics[0],
            writeMode: .withResponse
        )
        let timings = [BLECompatibilityStageDuration(stage: .discovery, durationMilliseconds: 42)]
        let failed = BLECompatibilityReport(
            profileID: "inferred-gatt",
            profileVersion: 1,
            source: .inferred,
            stage: .failed,
            subscription: .failed,
            failure: .notificationSubscriptionFailed,
            selectedChannel: channel,
            discoveredServices: [graph],
            stageDurations: timings
        )
        XCTAssertEqual(BLEManager.compatibilityReportAfterDisconnect(failed), failed)

        let vehicleUnavailable = BLECompatibilityReport(
            profileID: "known",
            profileVersion: 1,
            source: .known,
            stage: .adapterValidated,
            subscription: .confirmed,
            failure: .vehicleECUUnavailable,
            selectedChannel: channel,
            discoveredServices: [graph],
            stageDurations: timings
        )
        XCTAssertEqual(
            BLEManager.compatibilityReportAfterDisconnect(vehicleUnavailable),
            vehicleUnavailable,
            "Cleanup must retain the actionable no-ECU outcome and its evidence"
        )

        let compatible = BLECompatibilityReport(
            profileID: "known",
            profileVersion: 1,
            source: .known,
            stage: .compatible,
            subscription: .confirmed,
            failure: nil,
            selectedChannel: channel,
            discoveredServices: [graph],
            stageDurations: timings
        )
        let disconnected = BLEManager.compatibilityReportAfterDisconnect(compatible)
        XCTAssertEqual(disconnected.stage, .disconnected)
        XCTAssertEqual(disconnected.failure, .disconnected)
        XCTAssertEqual(disconnected.profileID, compatible.profileID)
        XCTAssertEqual(disconnected.selectedChannel, compatible.selectedChannel)
        XCTAssertEqual(disconnected.discoveredServices, compatible.discoveredServices)
    }

    func testCompatibilityCallbackOwnershipAllowsOnlyCurrentOrExpectedCleanup() {
        XCTAssertEqual(
            BLEManager.callbackOwnership(
                preparedAttempt: 4,
                activeAttempt: 4,
                preservedCleanupAttempt: nil
            ),
            .current
        )
        XCTAssertEqual(
            BLEManager.callbackOwnership(
                preparedAttempt: 3,
                activeAttempt: 4,
                preservedCleanupAttempt: 4
            ),
            .expectedCleanup
        )
        XCTAssertEqual(
            BLEManager.callbackOwnership(
                preparedAttempt: 3,
                activeAttempt: 4,
                preservedCleanupAttempt: nil
            ),
            .stale
        )
    }

    func testRequestedDisconnectOwnsCleanupWithoutMakingOldSetupCurrent() {
        // A connected setup belongs to attempt 3. Explicit stop advances the
        // public compatibility state to 4 while retaining only teardown
        // ownership for the CoreBluetooth cancellation callback.
        let ownership = BLEManager.callbackOwnership(
            preparedAttempt: 3,
            activeAttempt: 4,
            preservedCleanupAttempt: nil,
            requestedTeardownAttempt: 4
        )
        XCTAssertEqual(ownership, .expectedCleanup)
        XCTAssertNotEqual(ownership, .current)

        // Once a foreground connection supersedes teardown, the same old
        // callback cannot clean up the new attempt.
        XCTAssertEqual(
            BLEManager.callbackOwnership(
                preparedAttempt: 3,
                activeAttempt: 5,
                preservedCleanupAttempt: nil,
                requestedTeardownAttempt: 4
            ),
            .stale
        )
    }

    func testStandingReconnectAdoptsUnownedSystemConnectionAndDefersCancellation() {
        XCTAssertEqual(
            BLEManager.standingReconnectDisposition(
                isOwnedByCurrentAttempt: true,
                disconnectWasRequested: false
            ),
            .alreadyTracked
        )
        XCTAssertEqual(
            BLEManager.standingReconnectDisposition(
                isOwnedByCurrentAttempt: false,
                disconnectWasRequested: false
            ),
            .adopt
        )
        XCTAssertEqual(
            BLEManager.standingReconnectDisposition(
                isOwnedByCurrentAttempt: false,
                disconnectWasRequested: true
            ),
            .deferUntilTeardown
        )
    }

    func testRequestedTeardownThenAutomaticArmRearmsExactlyOnce() {
        var teardown = BLERequestedTeardownState()
        teardown.begin(attempt: 9, ownsPeripheral: true, rearmAfterCleanup: false)

        XCTAssertTrue(teardown.requestStandingReconnect(activeAttempt: 9))
        XCTAssertTrue(teardown.consumeRearm(activeAttempt: 9, autoReconnectEnabled: true))
        XCTAssertNil(teardown.attempt)
        XCTAssertFalse(teardown.consumeRearm(activeAttempt: 9, autoReconnectEnabled: true))
    }

    func testExplicitStopAndNewForegroundAttemptCancelDeferredRearm() {
        var teardown = BLERequestedTeardownState()

        // Explicit stop owns cleanup but does not request automatic recovery.
        teardown.begin(attempt: 10, ownsPeripheral: true, rearmAfterCleanup: false)
        XCTAssertFalse(teardown.consumeRearm(activeAttempt: 10, autoReconnectEnabled: true))
        XCTAssertNil(teardown.attempt)

        // A new foreground attempt clears an older timeout's deferred rearm.
        teardown.begin(attempt: 11, ownsPeripheral: true, rearmAfterCleanup: true)
        teardown.clear()
        XCTAssertFalse(teardown.consumeRearm(activeAttempt: 11, autoReconnectEnabled: true))
    }

    func testTerminalConnectFailureDoesNotWaitForAnotherCleanupCallback() {
        var teardown = BLERequestedTeardownState()

        // didFailToConnect has already confirmed the channel end and released
        // PM ownership. A subsequent service-level stop therefore retains no
        // teardown token and cannot defer standing reconnect indefinitely.
        teardown.begin(attempt: 12, ownsPeripheral: false, rearmAfterCleanup: false)
        XCTAssertNil(teardown.attempt)
        XCTAssertFalse(teardown.requestStandingReconnect(activeAttempt: 12))
    }

    func testStaleCleanupCannotConsumeNewerRequestedTeardown() {
        var teardown = BLERequestedTeardownState()
        teardown.begin(attempt: 12, ownsPeripheral: true, rearmAfterCleanup: true)

        XCTAssertFalse(teardown.consumeRearm(activeAttempt: 11, autoReconnectEnabled: true))
        XCTAssertEqual(teardown.attempt, 12)
        XCTAssertFalse(teardown.consumeRearm(activeAttempt: 12, autoReconnectEnabled: false))
        XCTAssertNil(teardown.attempt)
    }

    func testConnectTimeoutRejectsSupersededAttemptEvenForSamePeripheral() {
        XCTAssertTrue(BLEManager.shouldProcessConnectTimeout(
            capturedAttempt: 5,
            activeAttempt: 5,
            preparedAttempt: 5,
            fenceIsCurrent: true,
            isConnecting: true,
            matchesPeripheral: true
        ))
        XCTAssertFalse(BLEManager.shouldProcessConnectTimeout(
            capturedAttempt: 4,
            activeAttempt: 5,
            preparedAttempt: 5,
            fenceIsCurrent: false,
            isConnecting: true,
            matchesPeripheral: true
        ))
    }

    func testSilentStandingConnectionWaitsForOwnedDisconnectCleanup() {
        XCTAssertTrue(
            BLEManager.shouldWaitForDisconnectCleanup(
                connectionState: .disconnected,
                stillOwnsPeripheral: true
            )
        )
        XCTAssertFalse(
            BLEManager.shouldWaitForDisconnectCleanup(
                connectionState: .connecting,
                stillOwnsPeripheral: false
            )
        )
    }

    func testReconnectCleanupPreservesOnlyTheExplicitCurrentAttempt() {
        XCTAssertFalse(BLECompatibilityResetPolicy.shouldRecordDisconnected(
            preservedAttempt: 7,
            currentAttempt: 7
        ))
        XCTAssertTrue(BLECompatibilityResetPolicy.shouldRecordDisconnected(
            preservedAttempt: nil,
            currentAttempt: 7
        ))
        XCTAssertTrue(BLECompatibilityResetPolicy.shouldRecordDisconnected(
            preservedAttempt: 6,
            currentAttempt: 7
        ))
    }

    func testCompatibilityTimelineUsesMonotonicDurationsAndStopsAtOutcome() {
        var timeline = BLECompatibilityTimeline()
        timeline.begin(atNanoseconds: 1_000_000)

        XCTAssertEqual(
            timeline.snapshot(transitioningTo: .discovery, atNanoseconds: 11_000_000),
            [BLECompatibilityStageDuration(stage: .discovery, durationMilliseconds: 10)]
        )
        XCTAssertEqual(
            timeline.snapshot(transitioningTo: .discovery, atNanoseconds: 21_000_000),
            [BLECompatibilityStageDuration(stage: .discovery, durationMilliseconds: 20)],
            "Repeated snapshots must measure from the stage start, not double count"
        )

        _ = timeline.snapshot(transitioningTo: .subscription, atNanoseconds: 31_000_000)
        let terminal = timeline.snapshot(
            transitioningTo: .adapterValidated,
            atNanoseconds: 81_000_000,
            terminalOutcome: true
        )
        XCTAssertEqual(terminal, [
            BLECompatibilityStageDuration(stage: .discovery, durationMilliseconds: 30),
            BLECompatibilityStageDuration(stage: .subscription, durationMilliseconds: 50),
            BLECompatibilityStageDuration(stage: .adapterValidated, durationMilliseconds: 0),
        ])
        XCTAssertEqual(
            timeline.snapshot(transitioningTo: .disconnected, atNanoseconds: 3_600_081_000_000),
            terminal,
            "A finished compatibility attempt must not count later driving time"
        )
    }

    func testAttemptFenceRejectsTimingUpdateFromSupersededAttempt() {
        let fence = BLECompatibilityAttemptFence()
        let oldAttempt = fence.begin()
        let currentAttempt = fence.begin()

        XCTAssertFalse(fence.isCurrent(oldAttempt))
        XCTAssertTrue(fence.isCurrent(currentAttempt))
    }

    func testReportEvidenceFallbackIsFencedToTheSameAttempt() {
        let previous = BLECompatibilityReport(
            profileID: "ffe0-shared",
            profileVersion: 1,
            source: .known,
            stage: .subscription,
            subscription: .confirmed,
            failure: nil,
            selectedChannel: BLECompatibilityChannel(
                serviceUUID: "FFE0",
                readCharacteristic: BLECompatibilityCharacteristic(
                    uuid: "FFE1",
                    properties: [.notify]
                ),
                writeCharacteristic: BLECompatibilityCharacteristic(
                    uuid: "FFE1",
                    properties: [.writeWithResponse]
                ),
                writeMode: .withResponse
            ),
            discoveredServices: [
                BLECompatibilityService(uuid: "FFE0", characteristics: []),
            ]
        )

        XCTAssertEqual(
            BLEManager.sameAttemptCompatibilityReport(
                previous,
                reportAttempt: 8,
                expectedAttempt: 8
            ),
            previous
        )
        XCTAssertNil(BLEManager.sameAttemptCompatibilityReport(
            previous,
            reportAttempt: 7,
            expectedAttempt: 8
        ))
    }

    func testATIRequiresRecognizedBoundedELMOrSTNIdentity() {
        XCTAssertTrue(BLEELMResponseValidator.isAdapterIdentification(["ATI", "ELM327 v1.5", "> "]))
        XCTAssertTrue(BLEELMResponseValidator.isAdapterIdentification(["STN1110 v4.3"]))

        XCTAssertFalse(BLEELMResponseValidator.isAdapterIdentification(["OK"]))
        XCTAssertFalse(BLEELMResponseValidator.isAdapterIdentification(["Serial bridge ready"]))
        XCTAssertFalse(BLEELMResponseValidator.isAdapterIdentification(["ELM327 v1.5", "extra text"]))
        XCTAssertFalse(BLEELMResponseValidator.isAdapterIdentification([String(repeating: "A", count: 513)]))
        XCTAssertFalse(BLEELMResponseValidator.isAdapterIdentification(["ELM327 v1.5 🚗"]))
    }

    func testATE0RequiresAnExactOKResponse() {
        XCTAssertTrue(BLEELMResponseValidator.isOK(["ATE0", "OK", ">"], echoing: .disableEcho))
        XCTAssertFalse(BLEELMResponseValidator.isOK(["ATE0"], echoing: .disableEcho))
        XCTAssertFalse(BLEELMResponseValidator.isOK(["OKAY"], echoing: .disableEcho))
        XCTAssertFalse(BLEELMResponseValidator.isOK(["OK", "READY"], echoing: .disableEcho))
    }

    func testValidationStateEnforcesATIThenATE0() {
        var validation = BLEAdapterValidationState()
        XCTAssertEqual(validation.nextCommand, .identifyAdapter)

        validation.receive(["ATI", "ELM327 v2.2", ">"])
        XCTAssertEqual(validation.stage, .awaitingEchoDisable)
        XCTAssertEqual(validation.nextCommand, .disableEcho)

        validation.receive(["OK"])
        XCTAssertEqual(validation.stage, .adapterValidated)
        XCTAssertTrue(validation.isAdapterValidated)
        XCTAssertFalse(validation.hasVehicleEvidence)
    }

    func testArbitraryPrintableResponseFailsValidation() {
        var validation = BLEAdapterValidationState()

        validation.receive(["Wireless serial adapter"])

        XCTAssertEqual(validation.stage, .failed)
        XCTAssertEqual(validation.failure, .invalidAdapterIdentification)
        XCTAssertFalse(validation.isAdapterValidated)
    }

    func testVehicleEvidenceRequiresCompletePIDBitmap() {
        XCTAssertTrue(BLEELMResponseValidator.hasVehicleResponse(["4100BE3FA813"]))
        XCTAssertTrue(BLEELMResponseValidator.hasVehicleResponse(["7E8064100BE3FA813"]))
        XCTAssertTrue(BLEELMResponseValidator.hasVehicleResponse(["7E8 06 41 00 BE 3F A8 13"]))
        XCTAssertTrue(BLEELMResponseValidator.hasVehicleResponse(["18DAF110064100BE3FA813"]))

        XCTAssertFalse(BLEELMResponseValidator.hasVehicleResponse(["41 00"]))
        XCTAssertFalse(BLEELMResponseValidator.hasVehicleResponse(["vehicle says 41 00 BE 3F A8 13"]))
        XCTAssertFalse(BLEELMResponseValidator.hasVehicleResponse(["NO DATA"]))
        XCTAssertFalse(BLEELMResponseValidator.hasVehicleResponse(["OK"]))
    }

    func testFailedVehicleProbePreservesAdapterValidationEvidence() {
        var validation = validatedState()
        validation.beginVehicleProbe()

        validation.receive(["NO DATA"])

        XCTAssertEqual(validation.stage, .adapterValidated)
        XCTAssertEqual(validation.failure, .vehicleECUUnavailable)
        XCTAssertTrue(validation.isAdapterValidated)
        XCTAssertFalse(validation.hasVehicleEvidence)
    }

    func testVehicleProbeTimeoutPreservesAdapterValidationEvidence() {
        var validation = validatedState()
        validation.beginVehicleProbe()

        validation.fail(.responseTimedOut)

        XCTAssertEqual(validation.stage, .adapterValidated)
        XCTAssertEqual(validation.failure, .responseTimedOut)
        XCTAssertTrue(validation.isAdapterValidated)
    }

    private func validatedState() -> BLEAdapterValidationState {
        var validation = BLEAdapterValidationState()
        validation.receive(["ELM327 v1.5"])
        validation.receive(["OK"])
        return validation
    }
}

final class BLEAdapterBindingCacheTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "BLEAdapterBindingCacheTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testInferredBindingIsNotStoredBeforeAdapterValidation() throws {
        let cache = BLEAdapterBindingCache(defaults: defaults)
        let (binding, fingerprint) = try inferredFixture(serviceUUID: "ABCD")
        var timedOut = BLEAdapterValidationState()
        timedOut.fail(.responseTimedOut)

        XCTAssertFalse(cache.storeValidatedBinding(
            binding,
            forPeripheralID: "peripheral-a",
            fingerprint: fingerprint,
            validation: timedOut
        ))
        XCTAssertFalse(cache.hasCurrentValidatedRecord(forPeripheralID: "peripheral-a"))

        var cancelled = BLEAdapterValidationState()
        cancelled.fail(.cancelled)
        XCTAssertFalse(cache.storeValidatedBinding(
            binding,
            forPeripheralID: "peripheral-a",
            fingerprint: fingerprint,
            validation: cancelled
        ))
    }

    func testValidatedBindingRoundTripsOnlyForFreshFingerprint() throws {
        let cache = BLEAdapterBindingCache(defaults: defaults)
        let (binding, fingerprint) = try inferredFixture(serviceUUID: "ABCD")
        let validation = validatedState()

        XCTAssertTrue(cache.storeValidatedBinding(
            binding,
            forPeripheralID: "peripheral-a",
            fingerprint: fingerprint,
            validation: validation
        ))
        XCTAssertTrue(cache.hasCurrentValidatedRecord(forPeripheralID: "peripheral-a"))
        XCTAssertEqual(
            cache.record(forPeripheralID: "peripheral-a", fingerprint: fingerprint)?.profileID,
            BLEAdapterProfile.inferredProfileID
        )

        let changedFingerprint = BLEGATTFingerprint(services: [
            service("ABCD", [characteristic("A002", [.notify, .writeWithResponse])]),
        ])
        XCTAssertNil(cache.record(
            forPeripheralID: "peripheral-a",
            fingerprint: changedFingerprint
        ))
        XCTAssertFalse(cache.hasCurrentValidatedRecord(forPeripheralID: "peripheral-a"))
    }

    func testProfileVersionChangeInvalidatesCachedRecord() throws {
        let fingerprint = BLEGATTFingerprint(services: [
            service("FFE0", [characteristic("FFE1", [.notify, .writeWithResponse])]),
        ])
        let binding = try BLEAdapterRegistry.standard.resolve(
            serviceUUID: "FFE0",
            characteristics: [characteristic("FFE1", [.notify, .writeWithResponse])]
        ).get()
        let original = BLEAdapterBindingCache(defaults: defaults)
        XCTAssertTrue(original.storeInitializedKnownBinding(
            binding,
            forPeripheralID: "peripheral-a",
            fingerprint: fingerprint
        ))

        let revisedProfile = BLEAdapterProfile(
            id: binding.profile.id,
            displayName: binding.profile.displayName,
            serviceUUID: binding.profile.serviceUUID,
            readCharacteristicUUID: binding.profile.readCharacteristicUUID,
            writeCharacteristicUUID: binding.profile.writeCharacteristicUUID,
            supportedWriteTypes: binding.profile.supportedWriteTypes,
            version: binding.profile.version + 1
        )
        let revised = BLEAdapterBindingCache(
            defaults: defaults,
            registry: BLEAdapterRegistry(profiles: [revisedProfile])
        )

        XCTAssertFalse(revised.hasCurrentValidatedRecord(forPeripheralID: "peripheral-a"))
        XCTAssertNil(revised.record(forPeripheralID: "peripheral-a", fingerprint: fingerprint))
    }

    func testCacheIsBoundedAndCorruptionSafe() throws {
        var currentTime = Date(timeIntervalSince1970: 1)
        let cache = BLEAdapterBindingCache(
            defaults: defaults,
            maximumEntryCount: 2,
            now: { currentTime }
        )

        for index in 0..<3 {
            currentTime = Date(timeIntervalSince1970: TimeInterval(index + 1))
            let (binding, fingerprint) = try inferredFixture(serviceUUID: "A00\(index)")
            XCTAssertTrue(cache.storeValidatedBinding(
                binding,
                forPeripheralID: "peripheral-\(index)",
                fingerprint: fingerprint,
                validation: validatedState()
            ))
        }

        XCTAssertFalse(cache.hasCurrentValidatedRecord(forPeripheralID: "peripheral-0"))
        XCTAssertTrue(cache.hasCurrentValidatedRecord(forPeripheralID: "peripheral-1"))
        XCTAssertTrue(cache.hasCurrentValidatedRecord(forPeripheralID: "peripheral-2"))

        defaults.set(Data("not-json".utf8), forKey: "SwiftOBD2.BLEAdapterBindingCache")
        XCTAssertFalse(cache.hasCurrentValidatedRecord(forPeripheralID: "peripheral-1"))
        XCTAssertNil(defaults.data(forKey: "SwiftOBD2.BLEAdapterBindingCache"))
    }

    func testPublicReportContainsOnlyRedactedCompatibilityState() throws {
        let capturedAt = Date(timeIntervalSince1970: 42)
        let report = BLECompatibilityReport(
            profileID: "inferred-gatt",
            profileVersion: 1,
            source: .inferred,
            stage: .adapterValidated,
            subscription: .confirmed,
            failure: .vehicleECUUnavailable,
            capturedAt: capturedAt
        )
        let data = try JSONEncoder().encode(report)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(try JSONDecoder().decode(BLECompatibilityReport.self, from: data), report)
        XCTAssertFalse(encoded.contains("peripheral"))
        XCTAssertFalse(encoded.contains("VIN"))
        XCTAssertFalse(encoded.contains("NO DATA"))
    }

    func testReportDecodesLegacyJSONWithEmptyDiagnosticDefaults() throws {
        let legacyJSON = Data("""
        {
          "profileID": "ffe0-shared",
          "profileVersion": 1,
          "source": "known",
          "stage": "compatible",
          "subscription": "confirmed",
          "capturedAt": 42
        }
        """.utf8)

        let report = try JSONDecoder().decode(BLECompatibilityReport.self, from: legacyJSON)

        XCTAssertNil(report.selectedChannel)
        XCTAssertTrue(report.discoveredServices.isEmpty)
        XCTAssertFalse(report.discoveredGraphWasTruncated)
        XCTAssertTrue(report.stageDurations.isEmpty)
    }

    func testReportSanitizesAndBoundsDiscoveredGraph() throws {
        let services = (0..<20).map { serviceIndex in
            BLECompatibilityService(
                uuid: String(format: "%04X", serviceIndex),
                characteristics: (0..<40).map { characteristicIndex in
                    BLECompatibilityCharacteristic(
                        uuid: characteristicIndex == 0
                            ? "VIN secret value"
                            : String(format: "%04X", characteristicIndex),
                        properties: [.writeWithoutResponse, .notify, .notify]
                    )
                }
            )
        }

        let report = BLECompatibilityReport(
            profileID: nil,
            profileVersion: nil,
            source: nil,
            stage: .failed,
            subscription: .notRequested,
            failure: .unsupportedGATT,
            discoveredServices: services
        )
        let encoded = try XCTUnwrap(String(
            data: JSONEncoder().encode(report),
            encoding: .utf8
        ))

        XCTAssertEqual(report.discoveredServices.count, 16)
        XCTAssertTrue(report.discoveredServices.allSatisfy { $0.characteristics.count == 32 })
        XCTAssertTrue(report.discoveredGraphWasTruncated)
        XCTAssertEqual(
            BLECompatibilityCharacteristic(uuid: "VIN secret value", properties: []).uuid,
            "INVALID"
        )
        XCTAssertFalse(encoded.contains("VIN secret value"))
    }

    func testFailureReportRetainsGraphWithoutResolvedBinding() {
        let graph = [service("ABCD", [
            characteristic("A001", [.read]),
            characteristic("A002", [.writeWithResponse]),
        ])]

        let report = BLECompatibilityReport(
            binding: nil,
            discoveredGraph: graph,
            discoveredGraphWasTruncated: true,
            stage: .failed,
            subscription: .notRequested,
            failure: .unsupportedGATT
        )

        XCTAssertNil(report.selectedChannel)
        XCTAssertEqual(report.discoveredServices.map(\.uuid), ["ABCD"])
        XCTAssertEqual(report.discoveredServices[0].characteristics.map(\.uuid), ["A001", "A002"])
        XCTAssertTrue(report.discoveredGraphWasTruncated)
    }

    func testResolvedBindingExportsSelectedChannelPropertiesAndWriteMode() throws {
        let graph = [service("FFE0", [
            characteristic("FFE1", [.notify, .writeWithResponse, .writeWithoutResponse]),
        ])]
        let binding = try BLEAdapterRegistry.standard.resolve(
            services: graph,
            inferenceAuthorization: .denied
        ).get()

        let report = BLECompatibilityReport(
            binding: binding,
            discoveredGraph: graph,
            stage: .subscription,
            subscription: .confirmed
        )

        XCTAssertEqual(report.selectedChannel?.serviceUUID, "FFE0")
        XCTAssertEqual(report.selectedChannel?.readCharacteristic.uuid, "FFE1")
        XCTAssertEqual(
            report.selectedChannel?.readCharacteristic.properties,
            [.notify, .writeWithResponse, .writeWithoutResponse]
        )
        XCTAssertEqual(report.selectedChannel?.writeCharacteristic.uuid, "FFE1")
        XCTAssertEqual(report.selectedChannel?.writeMode, .withResponse)
    }

    private func inferredFixture(
        serviceUUID: String
    ) throws -> (BLEAdapterBinding, BLEGATTFingerprint) {
        let graph = [service(
            serviceUUID,
            [characteristic("A001", [.notify, .writeWithResponse])]
        )]
        let binding = try BLEAdapterRegistry.standard.resolve(
            services: graph,
            inferenceAuthorization: .explicitPeripheralSelection
        ).get()
        return (binding, BLEGATTFingerprint(services: graph))
    }

    private func validatedState() -> BLEAdapterValidationState {
        var validation = BLEAdapterValidationState()
        validation.receive(["ELM327 v1.5"])
        validation.receive(["OK"])
        return validation
    }

    private func service(
        _ uuid: String,
        _ characteristics: [BLECharacteristicDescriptor]
    ) -> BLEGATTServiceDescriptor {
        BLEGATTServiceDescriptor(uuid: uuid, characteristics: characteristics)
    }

    private func characteristic(
        _ uuid: String,
        _ capabilities: BLECharacteristicCapabilities
    ) -> BLECharacteristicDescriptor {
        BLECharacteristicDescriptor(uuid: uuid, capabilities: capabilities)
    }
}
