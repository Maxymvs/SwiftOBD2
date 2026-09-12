import Foundation
import OSLog
import CoreBluetooth
import Combine

protocol BLEPeripheralManagerDelegate: AnyObject {
    func peripheralManager(
        _ manager: BLEPeripheralManager,
        didResolve binding: BLEAdapterBinding,
        token: BLESetupToken,
        peripheral: CBPeripheral
    )
    func peripheralManager(
        _ manager: BLEPeripheralManager,
        didSetupCharacteristics peripheral: CBPeripheral,
        token: BLESetupToken
    )
    func peripheralManager(
        _ manager: BLEPeripheralManager,
        didLoseNotificationSubscription error: Error,
        token: BLESetupToken,
        peripheral: CBPeripheral
    )
}

class BLEPeripheralManager: NSObject, ObservableObject {
    enum DiscoveryScope: Equatable {
        case knownProfilesOnly
        case explicitSelection
        case validatedCacheHint
    }

    @Published var connectedPeripheral: CBPeripheral?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "BLEPeripheralManager")
    private let characteristicHandler: BLECharacteristicHandler
    private let adapterRegistry: BLEAdapterRegistry
    private let bindingCache: BLEAdapterBindingCache
    private let setupGate: BLESetupGate

    weak var delegate: BLEPeripheralManagerDelegate?
    private var setupToken: BLESetupToken?
    private var handlerConfigurationToken: UInt64 = 0
    private var subscriptionPublication = BLESubscriptionPublicationState()
    private var discoveryScope: DiscoveryScope = .knownProfilesOnly
    private var pendingServiceIDs = Set<ObjectIdentifier>()
    private var discoveredServices: [ObjectIdentifier: CBService] = [:]
    private var discoveredCharacteristics: [ObjectIdentifier: [CBCharacteristic]] = [:]
    private(set) var resolvedBinding: BLEAdapterBinding?
    private(set) var resolvedFingerprint: BLEGATTFingerprint?

    /// Connection generation counter to invalidate stale callbacks from previous connections
    private var connectionGeneration: Int = 0

    /// Protects graph aggregation and the manager-side identity paired with a
    /// `BLESetupGate` generation. Setup continuations live only in the gate.
    private let stateLock = NSLock()
    /// Serializes reset, prepare, and the final handler configuration commit so
    /// an older lifecycle operation cannot resume later and wipe a newer one.
    private let lifecycleLock = NSLock()

    init(
        characteristicHandler: BLECharacteristicHandler,
        adapterRegistry: BLEAdapterRegistry = .standard,
        bindingCache: BLEAdapterBindingCache = BLEAdapterBindingCache(),
        setupGate: BLESetupGate = BLESetupGate()
    ) {
        self.characteristicHandler = characteristicHandler
        self.adapterRegistry = adapterRegistry
        self.bindingCache = bindingCache
        self.setupGate = setupGate
        super.init()
    }

    /// Reset all state for clean reconnection - resumes any pending continuation.
    func reset() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let peripheral = stateLock.withLock { () -> CBPeripheral? in
            let peripheral = connectedPeripheral
            connectedPeripheral = nil
            setupToken = nil
            subscriptionPublication = BLESubscriptionPublicationState()
            connectionGeneration += 1
            pendingServiceIDs.removeAll()
            discoveredServices.removeAll()
            discoveredCharacteristics.removeAll()
            resolvedBinding = nil
            resolvedFingerprint = nil
            return peripheral
        }
        // Invalidate both independent generations before an old resolver can
        // commit through either layer.
        setupGate.reset(with: BLEManagerError.peripheralNotConnected)
        characteristicHandler.reset()
        peripheral?.delegate = nil
    }

    func prepareConnection(_ peripheral: CBPeripheral, scope: DiscoveryScope) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let previousPeripheral = stateLock.withLock { connectedPeripheral }
        characteristicHandler.reset(peripheral: previousPeripheral)
        let configurationToken = characteristicHandler.configurationToken
        let token = setupGate.begin()
        previousPeripheral?.delegate = nil
        stateLock.withLock {
            connectedPeripheral = peripheral
            connectionGeneration += 1
            setupToken = token
            handlerConfigurationToken = configurationToken
            subscriptionPublication = BLESubscriptionPublicationState()
            discoveryScope = scope
            pendingServiceIDs.removeAll()
            discoveredServices.removeAll()
            discoveredCharacteristics.removeAll()
            resolvedBinding = nil
            resolvedFingerprint = nil
        }
        peripheral.delegate = self
    }

    func startServiceDiscovery(on peripheral: CBPeripheral) {
        let discoverAll = stateLock.withLock { () -> Bool? in
            guard connectedPeripheral === peripheral,
                  let token = setupToken,
                  setupGate.isCurrent(token) else { return nil }
            return discoveryScope != .knownProfilesOnly
        }
        guard let discoverAll else { return }
        peripheral.discoverServices(
            discoverAll ? nil : adapterRegistry.serviceUUIDs.map(CBUUID.init(string:))
        )
    }

    func resolutionSnapshot() -> (
        binding: BLEAdapterBinding,
        fingerprint: BLEGATTFingerprint,
        peripheralID: String,
        generation: Int
    )? {
        stateLock.withLock {
            guard
                  let binding = resolvedBinding,
                  let fingerprint = resolvedFingerprint,
                  let peripheral = connectedPeripheral else { return nil }
            return (binding, fingerprint, peripheral.identifier.uuidString, connectionGeneration)
        }
    }

    /// Validates delegate callbacks after the setup gate has reached success;
    /// `BLESetupGate.isCurrent` is intentionally false for terminal tokens.
    func matchesCurrentSetup(token: BLESetupToken, peripheral: CBPeripheral) -> Bool {
        stateLock.withLock {
            connectedPeripheral === peripheral && setupToken == token
        }
    }

    func setPeripheral(_ peripheral: CBPeripheral?, discoverServices: Bool = true) {
        let current = stateLock.withLock { connectedPeripheral }
        if let peripheral, current !== peripheral {
            prepareConnection(peripheral, scope: .knownProfilesOnly)
        } else if peripheral == nil {
            reset()
            return
        }

        if discoverServices, let peripheral = peripheral, peripheral.state == .connected {
            startServiceDiscovery(on: peripheral)
        }
    }

    func waitForCharacteristicsSetup(timeout: TimeInterval) async throws {
        guard let token = stateLock.withLock({ setupToken }) else {
            throw BLEManagerError.peripheralNotConnected
        }
        do {
            try await setupGate.wait(token: token, timeout: timeout)
        } catch let error as CancellationError {
            setupGate.close(token: token, with: error)
            throw error
        } catch BLESetupGateError.timedOut {
            throw BLEManagerError.timeout
        } catch BLESetupGateError.waiterAlreadyRegistered {
            throw BLEManagerError.setupWaitAlreadyRegistered
        }
    }

    /// Terminates whichever setup generation is current at the instant this is
    /// called. A concurrent `prepareConnection` mints a different token, so this
    /// failure cannot close the newer attempt.
    func failCurrentSetup(_ error: Error) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let token = stateLock.withLock({ setupToken }) else { return }
        _ = setupGate.finish(token: token, result: .failure(error))
    }

    /// Clears acknowledgement provenance only after CoreBluetooth confirms that
    /// this app's local connection ended. Ordinary reset/prepare must retain it
    /// because `cancelPeripheralConnection` is asynchronous and old callbacks
    /// may still arrive.
    func confirmedDisconnect(_ peripheral: CBPeripheral) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard stateLock.withLock({ connectedPeripheral === peripheral }) else { return }

        // `reset` synchronously invalidates the coordinator session on its
        // executor. Clear the ledger only after every earlier physical-write
        // submission has drained, so an old entry cannot be appended after the
        // confirmed-disconnect boundary.
        characteristicHandler.reset(peripheral: peripheral)
        characteristicHandler.confirmedDisconnect(peripheral)
    }

    func didDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        guard let context = activeSetupContext(for: peripheral) else {
            logger.warning("Received services for unknown peripheral \(peripheral.identifier), ignoring")
            return
        }

        if let error {
            finishSetup(token: context.token, peripheral: peripheral, error: error)
            return
        }

        let allServices = peripheral.services ?? []
        let services: [CBService]
        switch context.scope {
        case .knownProfilesOnly:
            services = allServices.filter {
                adapterRegistry.profile(forServiceUUID: $0.uuid.uuidString) != nil
            }
        case .explicitSelection, .validatedCacheHint:
            services = allServices
        }

        guard !services.isEmpty else {
            finishSetup(
                token: context.token,
                peripheral: peripheral,
                error: BLEManagerError.adapterProfileResolution(.noCompatibleCharacteristics)
            )
            return
        }

        let shouldDiscover = stateLock.withLock { () -> Bool in
            guard matches(context, peripheral: peripheral) else { return false }
            pendingServiceIDs = Set(services.map(ObjectIdentifier.init))
            discoveredServices = Dictionary(uniqueKeysWithValues: services.map {
                (ObjectIdentifier($0), $0)
            })
            discoveredCharacteristics.removeAll()
            return true
        }
        guard shouldDiscover else { return }

        for service in services {
            logger.debug("Discovering adapter characteristics")
            if context.scope == .knownProfilesOnly,
               let profile = adapterRegistry.profile(forServiceUUID: service.uuid.uuidString) {
                peripheral.discoverCharacteristics(
                    profile.characteristicUUIDs.map(CBUUID.init(string:)),
                    for: service
                )
            } else {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        guard let context = activeSetupContext(for: peripheral) else {
            logger.warning("Received characteristics for unknown peripheral \(peripheral.identifier), ignoring")
            return
        }

        let serviceID = ObjectIdentifier(service)
        let isTrackedService = stateLock.withLock {
            matches(context, peripheral: peripheral) && pendingServiceIDs.contains(serviceID)
        }
        guard isTrackedService else { return }

        if let error = error {
            logger.error("Error discovering characteristics: \(error.localizedDescription)")
            finishSetup(token: context.token, peripheral: peripheral, error: error)
            return
        }

        let shouldResolve = stateLock.withLock { () -> Bool in
            guard matches(context, peripheral: peripheral),
                  pendingServiceIDs.contains(serviceID) else { return false }
            discoveredCharacteristics[serviceID] = service.characteristics ?? []
            pendingServiceIDs.remove(serviceID)
            return pendingServiceIDs.isEmpty
        }
        guard shouldResolve else { return }
        resolveDiscoveredGraph(on: peripheral, context: context)
    }

    func didUpdateNotificationState(
        _ peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        let context = stateLock.withLock { () -> (token: BLESetupToken, wasReady: Bool)? in
            guard connectedPeripheral === peripheral, let token = setupToken else { return nil }
            guard subscriptionPublication.didPublishReady || setupGate.isCurrent(token) else { return nil }
            return (token, subscriptionPublication.didPublishReady)
        }
        guard let context else {
            logger.warning("Received notification state for unknown peripheral \(peripheral.identifier), ignoring")
            return
        }
        guard characteristicHandler.handlesNotificationState(for: characteristic) else { return }

        if let error {
            logger.error("Failed to subscribe to adapter notifications: \(error.localizedDescription)")
            characteristicHandler.handleNotificationFailure(error)
            if context.wasReady {
                publishSubscriptionLossIfNeeded(
                    token: context.token,
                    peripheral: peripheral,
                    error: error
                )
            } else {
                finishSetup(
                    token: context.token,
                    peripheral: peripheral,
                    error: BLEManagerError.notificationSubscriptionFailed
                )
            }
            return
        }

        guard characteristicHandler.handleNotificationStateUpdate(for: characteristic) else {
            if context.wasReady {
                publishSubscriptionLossIfNeeded(
                    token: context.token,
                    peripheral: peripheral,
                    error: BLEManagerError.notificationSubscriptionFailed
                )
            }
            return
        }
        completeSetupIfReady(peripheral, token: context.token)
    }

    private func publishSubscriptionLossIfNeeded(
        token: BLESetupToken,
        peripheral: CBPeripheral,
        error: Error
    ) {
        let shouldPublish = stateLock.withLock { () -> Bool in
            guard connectedPeripheral === peripheral,
                  setupToken == token,
                  subscriptionPublication.didPublishReady else { return false }
            return subscriptionPublication.claimLoss()
        }
        guard shouldPublish else { return }
        delegate?.peripheralManager(
            self,
            didLoseNotificationSubscription: error,
            token: token,
            peripheral: peripheral
        )
    }

    private func completeSetupIfReady(_ peripheral: CBPeripheral, token: BLESetupToken) {
        guard characteristicHandler.isReady else { return }
        let shouldAttempt = stateLock.withLock { () -> Bool in
            guard connectedPeripheral === peripheral,
                  setupToken == token,
                  !subscriptionPublication.didPublishReady else { return false }
            return true
        }
        guard shouldAttempt,
              setupGate.finish(token: token, result: .success(())) else { return }

        let shouldPublish = stateLock.withLock { () -> Bool in
            guard connectedPeripheral === peripheral,
                  setupToken == token,
                  !subscriptionPublication.didPublishReady else { return false }
            return subscriptionPublication.claimReady()
        }
        guard shouldPublish else { return }

        delegate?.peripheralManager(
            self,
            didSetupCharacteristics: peripheral,
            token: token
        )
    }

    private func resolveDiscoveredGraph(on peripheral: CBPeripheral, context: SetupContext) {
        let snapshot = stateLock.withLock { () -> (
            [BLEGATTServiceDescriptor],
            [ObjectIdentifier: CBService],
            [ObjectIdentifier: [CBCharacteristic]],
            DiscoveryScope,
            UInt64
        )? in
            guard matches(context, peripheral: peripheral) else { return nil }
            let graph = discoveredServices.map { serviceID, service in
                BLEGATTServiceDescriptor(
                    uuid: service.uuid.uuidString,
                    characteristics: (discoveredCharacteristics[serviceID] ?? []).map {
                        BLECharacteristicDescriptor(
                            uuid: $0.uuid.uuidString,
                            capabilities: BLECharacteristicHandler.capabilities(for: $0)
                        )
                    }
                )
            }
            return (
                graph,
                discoveredServices,
                discoveredCharacteristics,
                discoveryScope,
                handlerConfigurationToken
            )
        }
        guard let (graph, servicesByID, characteristicsByService, scope, configurationToken) = snapshot else {
            return
        }

        let fingerprint = BLEGATTFingerprint(services: graph)
        let authorization: BLEUnknownProfileInferenceAuthorization
        switch scope {
        case .knownProfilesOnly:
            authorization = .denied
        case .explicitSelection:
            authorization = .explicitPeripheralSelection
        case .validatedCacheHint:
            authorization = bindingCache.record(
                forPeripheralID: peripheral.identifier.uuidString,
                fingerprint: fingerprint
            ) == nil ? .denied : .validatedCache
        }

        switch adapterRegistry.resolve(
            services: graph,
            inferenceAuthorization: authorization
        ) {
        case let .failure(error):
            finishSetup(
                token: context.token,
                peripheral: peripheral,
                error: BLEManagerError.adapterProfileResolution(error)
            )
        case let .success(binding):
            guard let serviceEntry = servicesByID.first(where: {
                BLECharacteristicDescriptor.normalize($0.value.uuid.uuidString)
                    == binding.profile.serviceUUID
            }), let characteristics = characteristicsByService[serviceEntry.key] else {
                finishSetup(
                    token: context.token,
                    peripheral: peripheral,
                    error: BLEManagerError.adapterProfileResolution(.noCompatibleCharacteristics)
                )
                return
            }
            let didCommit = lifecycleLock.withLock { () -> Bool in
                let shouldConfigure = stateLock.withLock { () -> Bool in
                    matches(context, peripheral: peripheral)
                        && handlerConfigurationToken == configurationToken
                }
                guard shouldConfigure else { return false }
                guard characteristicHandler.setup(
                    binding: binding,
                    characteristics: characteristics,
                    on: peripheral,
                    expectedConfigurationToken: configurationToken
                ) else { return false }

                return stateLock.withLock {
                    guard matches(context, peripheral: peripheral),
                          handlerConfigurationToken == configurationToken else { return false }
                    resolvedBinding = binding
                    resolvedFingerprint = fingerprint
                    return true
                }
            }
            guard didCommit else { return }
            delegate?.peripheralManager(
                self,
                didResolve: binding,
                token: context.token,
                peripheral: peripheral
            )
            completeSetupIfReady(peripheral, token: context.token)
        }
    }

    private func finishSetup(token: BLESetupToken, peripheral: CBPeripheral, error: Error?) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let isStillCurrent = stateLock.withLock {
            connectedPeripheral === peripheral
                && setupToken == token
                && setupGate.isCurrent(token)
        }
        guard isStillCurrent else { return }
        _ = setupGate.finish(
            token: token,
            result: .failure(error ?? BLEManagerError.unknownError)
        )
    }

    func didUpdateValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        // Validate this is our connected peripheral (prevents ghost callbacks from old connections)
        guard stateLock.withLock({ connectedPeripheral === peripheral }) else {
            logger.warning("Received value update for unknown peripheral \(peripheral.identifier), ignoring")
            return
        }

        if let error = error {
            logger.error("Error reading characteristic value: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else { return }
        characteristicHandler.handleUpdatedValue(data, from: characteristic)
    }

    func didWriteValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard stateLock.withLock({ connectedPeripheral === peripheral }) else {
            logger.warning("Received write acknowledgement for unknown peripheral \(peripheral.identifier), ignoring")
            return
        }
        characteristicHandler.handleWriteAcknowledgement(
            on: peripheral,
            characteristic: characteristic,
            error: error
        )
    }

    func isReadyToSendWriteWithoutResponse(_ peripheral: CBPeripheral) {
        guard stateLock.withLock({ connectedPeripheral === peripheral }) else {
            logger.warning("Received write readiness for unknown peripheral \(peripheral.identifier), ignoring")
            return
        }
        characteristicHandler.handleReadyToSendWriteWithoutResponse(on: peripheral)
    }

    private struct SetupContext {
        let token: BLESetupToken
        let generation: Int
        let scope: DiscoveryScope
    }

    private func activeSetupContext(for peripheral: CBPeripheral) -> SetupContext? {
        stateLock.withLock {
            guard connectedPeripheral === peripheral,
                  let token = setupToken,
                  setupGate.isCurrent(token) else { return nil }
            return SetupContext(token: token, generation: connectionGeneration, scope: discoveryScope)
        }
    }

    private func matches(_ context: SetupContext, peripheral: CBPeripheral) -> Bool {
        connectedPeripheral === peripheral
            && setupToken == context.token
            && connectionGeneration == context.generation
            && setupGate.isCurrent(context.token)
    }
}

extension BLEPeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        didDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        didDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateValue(peripheral, characteristic: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateNotificationState(peripheral, characteristic: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        didWriteValue(peripheral, characteristic: characteristic, error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        isReadyToSendWriteWithoutResponse(peripheral)
    }
}
