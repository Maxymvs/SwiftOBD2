// MARK: - BLEManager Class Documentation

/// The BLEManager class is a wrapper around the CoreBluetooth framework. It is responsible for managing the connection to the OBD2 adapter,
/// scanning for peripherals, and handling the communication with the adapter.
///
/// **Key Responsibilities:**
/// - Scanning for peripherals
/// - Connecting to peripherals
/// - Managing the connection state
/// - Handling the communication with the adapter
/// - Processing the characteristics of the adapter
/// - Sending messages to the adapter
/// - Receiving messages from the adapter
/// - Parsing the received messages
/// - Handling errors

import Combine
import CoreBluetooth
import Foundation

public enum ConnectionState: Sendable {
    case disconnected
    case connecting
    case connectedToAdapter
    case connectedToVehicle
    case error

    public var description: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connectedToAdapter: return "Connected to Adapter"
        case .connectedToVehicle: return "Connected to Vehicle"
        case .error: return "Error"
        }
    }

    public var isConnected: Bool {
        switch self {
        case .connectedToAdapter, .connectedToVehicle:
            return true
        default:
            return false
        }
    }
}

// MARK: - Constants
enum BLEConstants {
    static let defaultTimeout: TimeInterval = 3.0
    static let scanDuration: TimeInterval = 10.0
    static let connectionTimeout: TimeInterval = 10.0
    static let retryDelay: TimeInterval = 0.5
    /// Longest response kept before the prompt. A UDS DTC list can run to dozens of CAN frames
    /// (about 20 characters each): a VW central electrics `19 02` reply overflowed the old 1024
    /// and arrived with its start cut off (2026-11-05 capture). An ISO-TP message tops out at
    /// 4095 bytes, roughly 12 KB of ELM text.
    static let maxBufferSize = 16_384
    static let bluetoothPowerOnTimeout: TimeInterval = 30.0
    static let pollingInterval: UInt64 = 100_000_000 // 100ms in nanoseconds
}

/// One-shot ownership for a CoreBluetooth cancellation callback after the
/// compatibility attempt that initiated the connection has been invalidated.
/// This state authorizes cleanup only; setup remains fenced by its old token.
struct BLERequestedTeardownState: Equatable {
    private(set) var attempt: UInt64?
    private(set) var shouldRearmStandingReconnect = false

    mutating func begin(attempt: UInt64, ownsPeripheral: Bool, rearmAfterCleanup: Bool) {
        self.attempt = ownsPeripheral ? attempt : nil
        shouldRearmStandingReconnect = ownsPeripheral && rearmAfterCleanup
    }

    mutating func requestStandingReconnect(activeAttempt: UInt64) -> Bool {
        guard attempt == activeAttempt else { return false }
        shouldRearmStandingReconnect = true
        return true
    }

    mutating func consumeRearm(activeAttempt: UInt64, autoReconnectEnabled: Bool) -> Bool {
        guard attempt == activeAttempt else { return false }
        let shouldRearm = shouldRearmStandingReconnect && autoReconnectEnabled
        clear()
        return shouldRearm
    }

    mutating func clear() {
        attempt = nil
        shouldRearmStandingReconnect = false
    }
}

class BLEManager: NSObject, CommProtocol, BLEPeripheralManagerDelegate {
    enum DisconnectRecoveryAction: Equatable {
        case none
        case retry
        case armStandingReconnect
    }

    enum CompatibilityCallbackOwnership: Equatable {
        case current
        case expectedCleanup
        case stale
    }

    private let peripheralSubject = PassthroughSubject<CBPeripheral, Never>()
    private let peripheralDiscoverySubject = PassthroughSubject<BLEPeripheralDiscovery, Never>()
    // Replaced with centralized logging - see connectionStateDidChange for usage

    static let RestoreIdentifierKey: String = "OBD2Adapter"

    // MARK: Properties

    @Published var connectionState: ConnectionState = .disconnected

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    public weak var obdDelegate: OBDServiceDelegate?

    // MARK: - Auto-Reconnect Properties
    var autoReconnectEnabled: Bool = false
    var lastConnectedPeripheralUUID: UUID?
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 5
    private var reconnectTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    /// Distinguishes a local recovery/user cancellation from the adapter
    /// disappearing cleanly when the ignition powers it down.
    private var disconnectWasRequested = false

    // Focused components
    private var centralManager: CBCentralManager!
    private var messageProcessor: BLEMessageProcessor!
    var isWireRedactionHeld: Bool { messageProcessor?.wireLog.isRedactionHeld ?? false }
    private var characteristicHandler: BLECharacteristicHandler!
    private var peripheralManager: BLEPeripheralManager!
    private var peripheralScanner: BLEPeripheralScanner!
    private let adapterRegistry = BLEAdapterRegistry.standard
    private let bindingCache = BLEAdapterBindingCache()

    private let compatibilityLock = NSRecursiveLock()
    private let compatibilitySubject = CurrentValueSubject<BLECompatibilityReport?, Never>(nil)
    private let compatibilityAttemptFence = BLECompatibilityAttemptFence()
    private var activeCompatibilityAttempt: UInt64 = 0
    private var compatibilityReportStorage: BLECompatibilityReport?
    private var channelValidationTask: Task<Void, Error>?
    private var channelValidationAttempt: UInt64?
    private var compatibilityAttemptPreservedDuringReset: UInt64?
    private var preparedPeripheralAttempt: UInt64?
    /// Owns the terminal CoreBluetooth callback after an explicit cancellation
    /// advances the compatibility generation. It never authorizes setup or a
    /// late didConnect callback for the cancelled attempt.
    private var requestedTeardown = BLERequestedTeardownState()

    var currentCompatibilityReport: BLECompatibilityReport? {
        compatibilityLock.withLock { compatibilityReportStorage }
    }

    var compatibilityReportPublisher: AnyPublisher<BLECompatibilityReport?, Never> {
        compatibilitySubject.eraseToAnyPublisher()
    }

    var currentCompatibilityAttemptToken: UInt64 {
        compatibilityLock.withLock { activeCompatibilityAttempt }
    }

    /// The connection this transport is on now. The peripheral and the epoch that identifies
    /// its connection come from the peripheral manager in one read under one lock; the epoch
    /// advances there on every prepare and every reset, so a connection that was torn down never
    /// compares equal to a later one, even to the same peripheral under the same attempt.
    var adapterConnection: OBDAdapterConnectionSnapshot {
        compatibilityLock.withLock {
            let identity = peripheralManager.connectionIdentity
            return OBDAdapterConnectionSnapshot(
                attempt: activeCompatibilityAttempt,
                peripheralID: identity.peripheralID,
                epoch: identity.epoch
            )
        }
    }

    /// See `CommProtocol.requiresReconnect`: the stream is dirty and no probe can prove it on
    /// this connection. Clears by itself on a reconnect, a proof, or a late probe answer.
    var requiresReconnect: Bool {
        OBDStreamResynchronizer.isExhausted(messageProcessor)
    }

    /// Serializes all sendCommand calls — ELM327 can only handle one command at a time
    private let commandSemaphore = AsyncSemaphore(value: 1)

    /// Refuses vehicle requests after a manufacturer batch couldn't restore the adapter's
    /// addressing. Consulted in `sendCommandLocked`, so with the command mutex held.
    let oemAddressingGate = OEMAddressingGate.shared

    private var cancellables = Set<AnyCancellable>()
    
    deinit {
        // Clean up resources
        reconnectTask?.cancel()
        connectTimeoutTask?.cancel()
        cancellables.removeAll()
        disconnectPeripheral()
        obdDebug("BLEManager deinitialized", category: .bluetooth)
    }

    // MARK: - Initialization

    override init() {
        super.init()
        // Use background queue for better performance, but dispatch UI updates to main queue
        let bleQueue = DispatchQueue(label: "com.swiftobd2.ble", qos: .userInitiated)
        
        centralManager = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: BLEManager.RestoreIdentifierKey,
            ]
        )

        messageProcessor = BLEMessageProcessor()
        characteristicHandler = BLECharacteristicHandler(
            messageProcessor: messageProcessor,
            adapterRegistry: adapterRegistry
        )
        peripheralManager = BLEPeripheralManager(
            characteristicHandler: characteristicHandler,
            adapterRegistry: adapterRegistry,
            bindingCache: bindingCache
        )
        peripheralScanner = BLEPeripheralScanner(adapterRegistry: adapterRegistry)
    }

    @discardableResult
    private func beginCompatibilityAttempt() -> UInt64 {
        let attempt = compatibilityLock.withLock { () -> UInt64 in
            let attempt = compatibilityAttemptFence.begin()
            channelValidationTask?.cancel()
            channelValidationTask = nil
            channelValidationAttempt = nil
            preparedPeripheralAttempt = nil
            requestedTeardown.clear()
            activeCompatibilityAttempt = attempt
            return attempt
        }
        publishCompatibilityReport(
            stage: .discovery,
            subscription: .notRequested,
            attempt: attempt
        )
        return attempt
    }

    private func publishCompatibilityReport(
        stage: BLECompatibilityStage,
        subscription: BLESubscriptionStatus,
        failure: BLECompatibilityFailure? = nil,
        attempt: UInt64
    ) {
        guard compatibilityAttemptFence.isCurrent(attempt) else { return }
        let mayUseResolvedIdentity = compatibilityLock.withLock {
            preparedPeripheralAttempt == attempt
        }
        let binding = mayUseResolvedIdentity
            ? peripheralManager?.resolutionSnapshot()?.binding
            : nil
        let report = BLECompatibilityReport(
            binding: binding,
            stage: stage,
            subscription: subscription,
            failure: failure
        )
        compatibilityLock.withLock {
            guard activeCompatibilityAttempt == attempt,
                  compatibilityAttemptFence.isCurrent(attempt) else { return }
            compatibilityReportStorage = report
            compatibilitySubject.send(report)
        }
    }

    private func publishCompatibilityFailure(_ error: Error, attempt: UInt64) {
        let failure: BLECompatibilityFailure
        if error is CancellationError {
            failure = .cancelled
        } else if let writeError = error as? BLEWriteCoordinatorError {
            failure = writeError.isDeadlineExpiry ? .writeTimedOut : .writeFailed
        } else if let processorError = error as? BLEMessageProcessorError {
            switch processorError {
            case .responseTimeout:
                failure = .adapterResponseTimedOut
            case .staleRequestToken:
                failure = .disconnected
            case .characteristicNotWritable, .writeOperationFailed:
                failure = .writeFailed
            case .invalidResponseData:
                failure = .transportUnavailable
            }
        } else if let managerError = error as? BLEManagerError {
            switch managerError {
            case let .adapterProfileResolution(resolution):
                switch resolution {
                case .ambiguousProfiles, .ambiguousCharacteristic, .ambiguousServices,
                     .ambiguousInferredCharacteristics:
                    failure = .ambiguousGATT
                default:
                    failure = .unsupportedGATT
                }
            case .adapterIdentificationRejected:
                failure = .adapterIdentificationRejected
            case .adapterConfigurationRejected:
                failure = .adapterConfigurationRejected
            case .notificationSubscriptionFailed:
                failure = .notificationSubscriptionFailed
            case .sendMessageTimeout, .timeout:
                failure = .adapterResponseTimedOut
            case .peripheralNotConnected:
                failure = .disconnected
            default:
                failure = .transportUnavailable
            }
        } else {
            failure = .transportUnavailable
        }
        let currentSubscription = compatibilityLock.withLock {
            compatibilityReportStorage?.subscription ?? .notRequested
        }
        publishCompatibilityReport(
            stage: .failed,
            subscription: failure == .notificationSubscriptionFailed ? .failed : currentSubscription,
            failure: failure,
            attempt: attempt
        )
    }

    /// Maps only terminal command-channel failures. Vehicle-level outcomes such
    /// as `NO DATA` remain available to the caller without replacing a valid
    /// adapter compatibility report.
    static func commandCompatibilityFailure(for error: Error) -> BLECompatibilityFailure? {
        if error is CancellationError {
            return .cancelled
        }
        if let streamError = error as? OBDStreamError {
            // No probe was answered and none is left to try: the adapter stopped answering, as
            // far as the report is concerned (what this was before it had its own outcome).
            // Otherwise the manufacturer channel didn't write, which says nothing about the
            // adapter's channel.
            return streamError == .reconnectRequired ? .adapterResponseTimedOut : nil
        }
        if let writeError = error as? BLEWriteCoordinatorError {
            return writeError.isDeadlineExpiry ? .writeTimedOut : .writeFailed
        }
        if let processorError = error as? BLEMessageProcessorError {
            switch processorError {
            case .responseTimeout:
                return .adapterResponseTimedOut
            case .staleRequestToken:
                return .disconnected
            case .characteristicNotWritable, .writeOperationFailed:
                return .writeFailed
            case .invalidResponseData:
                return nil
            }
        }
        if let managerError = error as? BLEManagerError {
            switch managerError {
            case .peripheralNotConnected, .missingPeripheralOrCharacteristic:
                return .disconnected
            case .sendMessageTimeout, .timeout:
                return .adapterResponseTimedOut
            case .notificationSubscriptionFailed:
                return .notificationSubscriptionFailed
            case .noData, .adapterIdentificationRejected, .adapterConfigurationRejected,
                 .adapterProfileResolution:
                return nil
            default:
                return .transportUnavailable
            }
        }
        return nil
    }

    private func publishCommandFailure(_ error: Error, attempt: UInt64) {
        guard let failure = Self.commandCompatibilityFailure(for: error) else { return }
        compatibilityLock.withLock {
            guard activeCompatibilityAttempt == attempt,
                  compatibilityAttemptFence.isCurrent(attempt) else { return }
            // A pending command is failed when the channel is torn down. Keep
            // the earlier, more specific terminal cause (for example lost
            // notifications) instead of replacing it with generic disconnect.
            if compatibilityReportStorage?.stage == .failed,
               compatibilityReportStorage?.failure != nil {
                return
            }
            let binding = preparedPeripheralAttempt == attempt
                ? peripheralManager.resolutionSnapshot()?.binding
                : nil
            let report = BLECompatibilityReport(
                binding: binding,
                stage: .failed,
                subscription: failure == .notificationSubscriptionFailed
                    ? .failed
                    : compatibilityReportStorage?.subscription ?? .notRequested,
                failure: failure
            )
            compatibilityReportStorage = report
            compatibilitySubject.send(report)
        }
    }

    private func isCurrentCompatibilityAttempt(_ attempt: UInt64) -> Bool {
        compatibilityLock.withLock {
            activeCompatibilityAttempt == attempt
                && compatibilityAttemptFence.isCurrent(attempt)
        }
    }

    static func callbackOwnership(
        preparedAttempt: UInt64?,
        activeAttempt: UInt64,
        preservedCleanupAttempt: UInt64?,
        requestedTeardownAttempt: UInt64? = nil
    ) -> CompatibilityCallbackOwnership {
        if preparedAttempt == activeAttempt { return .current }
        if preservedCleanupAttempt == activeAttempt
            || requestedTeardownAttempt == activeAttempt {
            return .expectedCleanup
        }
        return .stale
    }

    private func callbackOwnership() -> CompatibilityCallbackOwnership {
        compatibilityLock.withLock {
            Self.callbackOwnership(
                preparedAttempt: preparedPeripheralAttempt,
                activeAttempt: activeCompatibilityAttempt,
                preservedCleanupAttempt: compatibilityAttemptPreservedDuringReset,
                requestedTeardownAttempt: requestedTeardown.attempt
            )
        }
    }

    enum StandingReconnectDisposition: Equatable {
        case alreadyTracked
        case adopt
        case deferUntilTeardown
    }

    static func standingReconnectDisposition(
        isOwnedByCurrentAttempt: Bool,
        disconnectWasRequested: Bool
    ) -> StandingReconnectDisposition {
        if disconnectWasRequested { return .deferUntilTeardown }
        return isOwnedByCurrentAttempt ? .alreadyTracked : .adopt
    }

    static func shouldProcessConnectTimeout(
        capturedAttempt: UInt64,
        activeAttempt: UInt64,
        preparedAttempt: UInt64?,
        fenceIsCurrent: Bool,
        isConnecting: Bool,
        matchesPeripheral: Bool
    ) -> Bool {
        capturedAttempt == activeAttempt
            && preparedAttempt == capturedAttempt
            && fenceIsCurrent
            && isConnecting
            && matchesPeripheral
    }

    static func shouldWaitForDisconnectCleanup(
        connectionState _: ConnectionState,
        stillOwnsPeripheral: Bool
    ) -> Bool {
        // A standing reconnect is deliberately invisible in connectionState.
        // Only releasing PM ownership proves its cancellation callback ran.
        stillOwnsPeripheral
    }

    func recordAdapterInitializationStarted(expectedAttempt attempt: UInt64) {
        publishCompatibilityReport(
            stage: .adapterConfiguration,
            subscription: .confirmed,
            attempt: attempt
        )
    }

    func recordAdapterInitialized(expectedAttempt attempt: UInt64) {
        let didRecord = compatibilityLock.withLock { () -> Bool in
            guard activeCompatibilityAttempt == attempt,
                  compatibilityAttemptFence.isCurrent(attempt),
                  let snapshot = peripheralManager.resolutionSnapshot() else { return false }
            if snapshot.binding.source == .known {
                _ = bindingCache.storeInitializedKnownBinding(
                    snapshot.binding,
                    forPeripheralID: snapshot.peripheralID,
                    fingerprint: snapshot.fingerprint
                )
            }
            return true
        }
        guard didRecord else { return }
        publishCompatibilityReport(
            stage: .adapterValidated,
            subscription: .confirmed,
            attempt: attempt
        )
    }

    func recordVehicleProbeStarted(expectedAttempt attempt: UInt64) {
        publishCompatibilityReport(
            stage: .vehicleProbe,
            subscription: .confirmed,
            attempt: attempt
        )
    }

    func recordVehicleValidated(expectedAttempt attempt: UInt64) {
        publishCompatibilityReport(
            stage: .compatible,
            subscription: .confirmed,
            attempt: attempt
        )
    }

    func recordVehicleUnavailable(expectedAttempt attempt: UInt64) {
        publishCompatibilityReport(
            stage: .adapterValidated,
            subscription: .confirmed,
            failure: .vehicleECUUnavailable,
            attempt: attempt
        )
    }

    func recordFailure(
        _ failure: BLECompatibilityFailure,
        stage: BLECompatibilityStage,
        subscription: BLESubscriptionStatus,
        expectedAttempt attempt: UInt64
    ) {
        publishCompatibilityReport(
            stage: stage,
            subscription: subscription,
            failure: failure,
            attempt: attempt
        )
    }

    func recordDisconnected(expectDisconnectCallback: Bool = false) {
        recordDisconnected(
            expectDisconnectCallback: expectDisconnectCallback,
            armStandingReconnectAfterTeardown: false
        )
    }

    private func recordDisconnected(
        expectDisconnectCallback: Bool,
        armStandingReconnectAfterTeardown: Bool
    ) {
        compatibilityLock.withLock {
            let attempt = compatibilityAttemptFence.begin()
            channelValidationTask?.cancel()
            channelValidationTask = nil
            channelValidationAttempt = nil
            activeCompatibilityAttempt = attempt
            let ownsPeripheral = peripheralManager.connectedPeripheral != nil
            requestedTeardown.begin(
                attempt: attempt,
                ownsPeripheral: expectDisconnectCallback && ownsPeripheral,
                rearmAfterCleanup: armStandingReconnectAfterTeardown
            )
            if requestedTeardown.attempt != nil {
                disconnectWasRequested = true
            }
            let previous = compatibilityReportStorage
            let report = Self.compatibilityReportAfterDisconnect(previous)
            compatibilityReportStorage = report
            compatibilitySubject.send(report)
        }
    }

    /// Cleanup after a terminal failure must retain the actionable cause. A
    /// normal disconnect from a nonfailed session records generic link loss.
    static func compatibilityReportAfterDisconnect(
        _ previous: BLECompatibilityReport?
    ) -> BLECompatibilityReport {
        if let previous, previous.stage == .failed, previous.failure != nil {
            return previous
        }
        return BLECompatibilityReport(
            profileID: previous?.profileID,
            profileVersion: previous?.profileVersion,
            source: previous?.source,
            stage: .disconnected,
            subscription: .notRequested,
            failure: .disconnected
        )
    }

    // MARK: - Central Manager Control Methods

    func startScanning(_ serviceUUIDs: [CBUUID]?, reportingSignalUpdates: Bool = false) {
        guard centralManager.state == .poweredOn else { 
            obdWarning("Cannot start scanning - Bluetooth not powered on", category: .bluetooth)
            return 
        }
        
        obdDebug("Starting BLE scan for services: \(serviceUUIDs?.map { $0.uuidString } ?? ["All"])", category: .bluetooth)
        
        // Duplicates only for the user-facing picker, which needs live RSSI to rank devices by
        // distance; reconnect scans just need the first sighting.
        let scanOptions = [CBCentralManagerScanOptionAllowDuplicatesKey: reportingSignalUpdates]
        centralManager.scanForPeripherals(withServices: serviceUUIDs, options: scanOptions)
    }

    func stopScan() {
        if centralManager.isScanning {
            obdDebug("Stopping BLE scan", category: .bluetooth)
            centralManager.stopScan()
        }
    }

    func disconnectPeripheral() {
        guard let peripheral = peripheralManager.connectedPeripheral else { return }
        guard centralManager.state == .poweredOn else {
            obdWarning("Skipping disconnect request while Bluetooth is not powered on", category: .bluetooth)
            resetAllState()
            return
        }
        disconnectWasRequested = true
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Central Manager Delegate Methods

    func didUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            centralManagerDidPowerOn()
        case .poweredOff:
            obdWarning("Bluetooth powered off", category: .bluetooth)
            disconnectWasRequested = false
            recordDisconnected()
            peripheralManager.failCurrentSetup(BLEManagerError.peripheralNotConnected)
            if let peripheral = peripheralManager.connectedPeripheral {
                peripheralManager.confirmedDisconnect(peripheral)
            }
            peripheralManager.reset()
            let oldState = connectionState
            connectionState = .disconnected
            OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)
        case .unsupported:
            obdError("Device does not support Bluetooth Low Energy", category: .bluetooth)
        case .unauthorized:
            obdError("App not authorized to use Bluetooth Low Energy", category: .bluetooth)
        case .resetting:
            obdWarning("Bluetooth is resetting", category: .bluetooth)
        default:
            obdError("Bluetooth in unexpected state: \(central.state.rawValue)", category: .bluetooth)
            connectionState = .error
            obdDelegate?.connectionStateChanged(state: .error)
        }
    }

    func centralManagerDidPowerOn() {
        if let device = peripheralManager.connectedPeripheral {
            switch device.state {
            case .connecting:
                obdInfo("Power on: restored peripheral is already connecting, waiting for callback", category: .bluetooth)
                scheduleConnectTimeout(for: device)
            case .connected:
                obdInfo("Power on: restored peripheral is already connected", category: .bluetooth)
                cancelConnectTimeout()
            case .disconnecting:
                obdInfo("Power on: restored peripheral is disconnecting, waiting for cleanup", category: .bluetooth)
            case .disconnected:
                obdInfo("Power on: cleared stale restored peripheral reference", category: .bluetooth)
                cancelConnectTimeout()
                peripheralManager.reset()
                connectionState = .disconnected
            @unknown default:
                obdWarning("Power on: restored peripheral in unknown state, clearing", category: .bluetooth)
                cancelConnectTimeout()
                peripheralManager.reset()
                connectionState = .disconnected
            }
            return
        }

        obdDebug("Bluetooth powered on; waiting for reconnect orchestration", category: .bluetooth)
    }

    func didDiscover(_: CBCentralManager, peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        peripheralScanner.addDiscoveredPeripheral(peripheral, advertisementData: advertisementData, rssi: rssi)
        peripheralSubject.send(peripheral)
        peripheralDiscoverySubject.send(
            BLEPeripheralDiscovery(peripheral: peripheral, advertisementData: advertisementData, rssi: rssi)
        )
    }

    @discardableResult
    func connect(
        to peripheral: CBPeripheral,
        scope requestedScope: BLEPeripheralManager.DiscoveryScope? = nil,
        compatibilityAttempt requestedAttempt: UInt64? = nil
    ) -> UInt64 {
        let compatibilityAttempt = requestedAttempt ?? beginCompatibilityAttempt()
        guard compatibilityAttemptFence.isCurrent(compatibilityAttempt) else {
            return compatibilityAttempt
        }
        guard centralManager.state == .poweredOn else {
            obdWarning("Ignoring connect request while Bluetooth is not powered on", category: .bluetooth)
            publishCompatibilityFailure(BLEManagerError.peripheralNotConnected, attempt: compatibilityAttempt)
            return compatibilityAttempt
        }

        let scope = requestedScope ?? (
            bindingCache.hasCurrentValidatedRecord(forPeripheralID: peripheral.identifier.uuidString)
                ? .validatedCacheHint
                : .knownProfilesOnly
        )

        let peripheralName = peripheral.name ?? "Unnamed"
        obdInfo("Attempting connection to peripheral: \(peripheralName)", category: .bluetooth)

        lastConnectedPeripheralUUID = peripheral.identifier
        peripheralManager.prepareConnection(peripheral, scope: scope)
        compatibilityLock.withLock {
            guard activeCompatibilityAttempt == compatibilityAttempt else { return }
            preparedPeripheralAttempt = compatibilityAttempt
        }
        
        let oldState = connectionState
        connectionState = .connecting
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)
        
        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .connecting)
        }
        
        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        scheduleConnectTimeout(for: peripheral, attempt: compatibilityAttempt)
        if centralManager.isScanning {
            centralManager.stopScan()
        }
        return compatibilityAttempt
    }

    func didConnect(_: CBCentralManager, peripheral: CBPeripheral) {
        compatibilityLock.lock()
        defer { compatibilityLock.unlock() }
        guard peripheralManager.connectedPeripheral === peripheral else {
            obdDebug("Ignoring connect callback for a superseded peripheral", category: .bluetooth)
            return
        }
        guard callbackOwnership() == .current else {
            obdDebug("Ignoring connect callback for a noncurrent compatibility attempt", category: .bluetooth)
            return
        }
        obdInfo("Connected to peripheral: \(peripheral.name ?? "Unnamed")", category: .bluetooth)
        disconnectWasRequested = false
        cancelConnectTimeout()
        reconnectAttempts = 0 // Reset on successful connection
        lastConnectedPeripheralUUID = peripheral.identifier
        peripheralManager.startServiceDiscovery(on: peripheral)
        // Note: connectionState will be set to .connectedToAdapter in peripheralManager delegate
    }

    func didFailToConnect(_: CBCentralManager, peripheral: CBPeripheral, error: Error?) {
        compatibilityLock.lock()
        defer { compatibilityLock.unlock() }
        guard peripheralManager.connectedPeripheral === peripheral else {
            obdDebug("Ignoring failed-connect callback for a superseded peripheral", category: .bluetooth)
            return
        }
        switch callbackOwnership() {
        case .expectedCleanup:
            let preservedAttempt = compatibilityLock.withLock { activeCompatibilityAttempt }
            let shouldRearm = requestedTeardown.consumeRearm(
                activeAttempt: preservedAttempt,
                autoReconnectEnabled: autoReconnectEnabled
            )
            cancelConnectTimeout()
            disconnectWasRequested = false
            peripheralManager.confirmedDisconnect(peripheral)
            resetAllState(preservingCompatibilityAttempt: preservedAttempt)
            if shouldRearm {
                armStandingReconnect()
            }
            return
        case .stale:
            obdDebug("Ignoring failed-connect callback for a noncurrent compatibility attempt", category: .bluetooth)
            return
        case .current:
            break
        }
        let peripheralName = peripheral.name ?? "Unnamed"
        let errorMsg = error?.localizedDescription ?? "Unknown error"
        obdError("Connection failed to peripheral: \(peripheralName) - \(errorMsg)", category: .bluetooth)
        cancelConnectTimeout()
        let attempt = compatibilityLock.withLock { activeCompatibilityAttempt }
        let failure = error ?? BLEManagerError.unknownError
        peripheralManager.failCurrentSetup(failure)
        publishCompatibilityFailure(failure, attempt: attempt)

        // didFailToConnect is terminal for this CoreBluetooth request. Release
        // PM ownership now so a later public stop cannot wait for a second
        // callback that CoreBluetooth will never send. Publish first so the
        // resolved adapter identity remains available in the failure report.
        peripheralManager.confirmedDisconnect(peripheral)
        let failedPeripheralID = peripheral.identifier
        peripheralManager.reset()
        messageProcessor.reset()
        releaseRedactionUnlessUnresolved(failedPeripheralID)
        requestedTeardown.clear()
        disconnectWasRequested = false

        let oldState = connectionState
        connectionState = .error
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)
        
        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .error)
        }
    }

    func didDisconnect(_: CBCentralManager, peripheral: CBPeripheral, error: Error?) {
        compatibilityLock.lock()
        defer { compatibilityLock.unlock() }
        guard peripheralManager.connectedPeripheral === peripheral else {
            obdDebug("Ignoring disconnect callback for a superseded peripheral", category: .bluetooth)
            return
        }
        let ownership = callbackOwnership()
        guard ownership == .current || ownership == .expectedCleanup else {
            obdDebug("Ignoring disconnect callback for a noncurrent compatibility attempt", category: .bluetooth)
            return
        }
        peripheralManager.confirmedDisconnect(peripheral)
        let peripheralName = peripheral.name ?? "Unnamed"
        let wasUnexpected = error != nil
        let wasRequested = disconnectWasRequested
        let preservedAttempt = ownership == .expectedCleanup ? activeCompatibilityAttempt : nil
        let shouldRearm = requestedTeardown.consumeRearm(
            activeAttempt: activeCompatibilityAttempt,
            autoReconnectEnabled: autoReconnectEnabled
        )
        disconnectWasRequested = false
        cancelConnectTimeout()

        if wasUnexpected {
            obdWarning("Unexpected disconnection from \(peripheralName): \(error!.localizedDescription)", category: .bluetooth)
        } else {
            obdInfo("Disconnected from peripheral: \(peripheralName)", category: .bluetooth)
        }

        // Store UUID BEFORE reset clears peripheral reference
        let peripheralUUID = peripheral.identifier
        if lastConnectedPeripheralUUID == nil {
            lastConnectedPeripheralUUID = peripheralUUID
        }

        // Full reset of all BLE state
        resetAllState(preservingCompatibilityAttempt: preservedAttempt)

        if shouldRearm {
            armStandingReconnect()
            return
        }

        switch disconnectRecoveryAction(hadError: wasUnexpected, wasRequested: wasRequested) {
        case .none:
            break
        case .retry:
            obdInfo("Scheduling auto-reconnect attempt \(reconnectAttempts + 1)/\(maxReconnectAttempts)", category: .bluetooth)
            scheduleAutoReconnect(peripheralUUID: peripheralUUID)
        case .armStandingReconnect:
            if wasUnexpected {
                obdWarning("Max reconnect attempts reached, falling back to standing reconnect", category: .bluetooth)
            } else {
                obdInfo("Adapter powered off cleanly, arming standing reconnect for the next ignition", category: .bluetooth)
            }
            reconnectAttempts = 0
            armStandingReconnect()
        }
    }

    func disconnectRecoveryAction(
        hadError: Bool,
        wasRequested: Bool
    ) -> DisconnectRecoveryAction {
        Self.disconnectRecoveryAction(
            hadError: hadError,
            wasRequested: wasRequested,
            autoReconnectEnabled: autoReconnectEnabled,
            reconnectAttempts: reconnectAttempts,
            maxReconnectAttempts: maxReconnectAttempts
        )
    }

    static func disconnectRecoveryAction(
        hadError: Bool,
        wasRequested: Bool,
        autoReconnectEnabled: Bool,
        reconnectAttempts: Int,
        maxReconnectAttempts: Int
    ) -> DisconnectRecoveryAction {
        guard !wasRequested, autoReconnectEnabled else { return .none }
        if hadError && reconnectAttempts < maxReconnectAttempts {
            return .retry
        }
        return .armStandingReconnect
    }

    /// Leave an OS-level pending connection to the saved adapter, with no
    /// app-side timeout. CoreBluetooth keeps the request alive while the app
    /// is suspended or terminated (via state restoration) and completes it
    /// whenever the adapter powers on — typically at the next ignition. This
    /// is what allows trips to start without the user opening the app.
    ///
    /// Only call this when the adapter is unreachable. Arming after a
    /// disconnect from a reachable-but-misbehaving adapter would create an
    /// instant connect/fail loop.
    @discardableResult
    func armStandingReconnect() -> Bool {
        compatibilityLock.lock()
        defer { compatibilityLock.unlock() }
        guard autoReconnectEnabled else { return false }
        guard centralManager.state == .poweredOn else {
            obdDebug("Standing reconnect not armed: Bluetooth is not powered on", category: .bluetooth)
            return false
        }

        if requestedTeardown.attempt == activeCompatibilityAttempt {
            return requestedTeardown.requestStandingReconnect(
                activeAttempt: activeCompatibilityAttempt
            )
        }
        guard !disconnectWasRequested else { return false }
        guard let uuid = lastConnectedPeripheralUUID,
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            obdDebug("Standing reconnect not armed: no saved peripheral in system cache", category: .bluetooth)
            return false
        }

        switch peripheral.state {
        case .connected, .connecting:
            let isOwnedByCurrentAttempt = peripheralManager.connectedPeripheral === peripheral
                && preparedPeripheralAttempt == activeCompatibilityAttempt
                && compatibilityAttemptFence.isCurrent(activeCompatibilityAttempt)
            switch Self.standingReconnectDisposition(
                isOwnedByCurrentAttempt: isOwnedByCurrentAttempt,
                disconnectWasRequested: disconnectWasRequested
            ) {
            case .alreadyTracked:
                return true
            case .deferUntilTeardown:
                return requestedTeardown.requestStandingReconnect(
                    activeAttempt: activeCompatibilityAttempt
                )
            case .adopt:
                let compatibilityAttempt = beginCompatibilityAttempt()
                let scope: BLEPeripheralManager.DiscoveryScope =
                    bindingCache.hasCurrentValidatedRecord(forPeripheralID: peripheral.identifier.uuidString)
                        ? .validatedCacheHint
                        : .knownProfilesOnly
                peripheralManager.prepareConnection(peripheral, scope: scope)
                preparedPeripheralAttempt = compatibilityAttempt
                if peripheral.state == .connected {
                    peripheralManager.startServiceDiscovery(on: peripheral)
                }
                return true
            }
        default:
            break
        }

        obdInfo("Arming standing reconnect to \(peripheral.name ?? uuid.uuidString) — pending connect with no timeout", category: .bluetooth)
        let compatibilityAttempt = beginCompatibilityAttempt()
        let scope: BLEPeripheralManager.DiscoveryScope =
            bindingCache.hasCurrentValidatedRecord(forPeripheralID: peripheral.identifier.uuidString)
                ? .validatedCacheHint
                : .knownProfilesOnly
        peripheralManager.prepareConnection(peripheral, scope: scope)
        compatibilityLock.withLock { preparedPeripheralAttempt = compatibilityAttempt }
        // Deliberately no scheduleConnectTimeout and no .connecting state:
        // the request waits silently at the OS level until the adapter appears.
        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        return true
    }

    func willRestoreState(_: CBCentralManager, dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first {
            obdDebug("Restoring peripheral: \(peripheral.name ?? "Unnamed"), state: \(peripheral.state.rawValue)", category: .bluetooth)
            lastConnectedPeripheralUUID = peripheral.identifier

            // Check peripheral state before restoring
            if peripheral.state == .connected {
                // Peripheral still connected - rediscover and wait for the
                // notification subscription before publishing adapter readiness.
                let scope: BLEPeripheralManager.DiscoveryScope =
                    bindingCache.hasCurrentValidatedRecord(forPeripheralID: peripheral.identifier.uuidString)
                        ? .validatedCacheHint
                        : .knownProfilesOnly
                let compatibilityAttempt = beginCompatibilityAttempt()
                peripheralManager.prepareConnection(peripheral, scope: scope)
                compatibilityLock.withLock { preparedPeripheralAttempt = compatibilityAttempt }
                peripheralManager.startServiceDiscovery(on: peripheral)
                cancelConnectTimeout()
                obdInfo("Restored connected peripheral; validating adapter channel", category: .bluetooth)
            } else if peripheral.state == .connecting {
                // A pending connect survived app termination (standing
                // reconnect). Leave it pending with no timeout — iOS completes
                // it when the adapter powers on. State stays .disconnected so
                // the app treats the standing request as invisible.
                let scope: BLEPeripheralManager.DiscoveryScope =
                    bindingCache.hasCurrentValidatedRecord(forPeripheralID: peripheral.identifier.uuidString)
                        ? .validatedCacheHint
                        : .knownProfilesOnly
                let compatibilityAttempt = beginCompatibilityAttempt()
                peripheralManager.prepareConnection(peripheral, scope: scope)
                compatibilityLock.withLock { preparedPeripheralAttempt = compatibilityAttempt }
                connectionState = .disconnected
                obdInfo("Restored pending peripheral connection — leaving it standing", category: .bluetooth)
            } else {
                // Peripheral not connected - clear stale reference
                obdWarning("Restored peripheral not connected, clearing state", category: .bluetooth)
                cancelConnectTimeout()
                peripheralManager.reset()
                connectionState = .disconnected
            }
        }
    }

    func connectionEventDidOccur(_: CBCentralManager, event: CBConnectionEvent, peripheral _: CBPeripheral) {
        obdError("Unexpected connection event: \(event.rawValue)", category: .bluetooth)
    }

    // MARK: - CommProtocol Scanning & State

    /// Publisher for discovered peripherals during scanning
    var discoveredPeripheralPublisher: AnyPublisher<CBPeripheral, Never> {
        peripheralSubject.eraseToAnyPublisher()
    }

    /// Advertisement sightings with RSSI, for ranking devices in a picker
    var peripheralDiscoveryPublisher: AnyPublisher<BLEPeripheralDiscovery, Never> {
        peripheralDiscoverySubject.eraseToAnyPublisher()
    }

    /// Current CBManagerState for BT permission/power checking
    var bluetoothState: CBManagerState {
        centralManager.state
    }

    /// Retrieve a peripheral by UUID from iOS cache (same CBCentralManager that will connect)
    func retrievePeripheral(uuid: UUID) -> CBPeripheral? {
        guard centralManager.state == .poweredOn else { return nil }
        return centralManager.retrievePeripherals(withIdentifiers: [uuid]).first
    }

    /// Start scanning for peripherals and publish discoveries
    func startPeripheralScanning() {
        startScanning(nil, reportingSignalUpdates: true)
    }

    /// Stop peripheral scanning
    func stopPeripheralScanning() {
        stopScan()
    }

    // MARK: - Async Methods

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        let compatibilityAttempt = beginCompatibilityAttempt()
        do {
            try await waitForPoweredOn()
            guard compatibilityAttemptFence.isCurrent(compatibilityAttempt) else {
                throw CancellationError()
            }

            // ALWAYS disconnect and reset before any new connection attempt.
            if connectionState != .disconnected || peripheralManager.connectedPeripheral != nil {
                obdInfo("Resetting connection state before new connection", category: .bluetooth)
                compatibilityLock.withLock {
                    compatibilityAttemptPreservedDuringReset = compatibilityAttempt
                }
                _ = await disconnectPeripheralAsync()
                compatibilityLock.withLock {
                    if compatibilityAttemptPreservedDuringReset == compatibilityAttempt {
                        compatibilityAttemptPreservedDuringReset = nil
                    }
                }
                guard compatibilityAttemptFence.isCurrent(compatibilityAttempt) else {
                    throw CancellationError()
                }
                resetAllState(preservingCompatibilityAttempt: compatibilityAttempt)
                try await Task.sleep(nanoseconds: 300_000_000)
            }

            let targetPeripheral: CBPeripheral
            if let peripheral {
                targetPeripheral = peripheral
            } else {
                startScanning(peripheralScanner.supportedServices)
                targetPeripheral = try await peripheralScanner.waitForFirstPeripheral(timeout: timeout)
            }
            guard compatibilityAttemptFence.isCurrent(compatibilityAttempt) else {
                throw CancellationError()
            }

            let scope: BLEPeripheralManager.DiscoveryScope = peripheral == nil
                ? .knownProfilesOnly
                : .explicitSelection
            _ = connect(
                to: targetPeripheral,
                scope: scope,
                compatibilityAttempt: compatibilityAttempt
            )
            guard compatibilityAttemptFence.isCurrent(compatibilityAttempt) else {
                throw CancellationError()
            }
            try await peripheralManager.waitForCharacteristicsSetup(timeout: timeout)
            guard compatibilityAttemptFence.isCurrent(compatibilityAttempt) else {
                throw CancellationError()
            }
            try await awaitChannelValidation(attempt: compatibilityAttempt)
        } catch {
            publishCompatibilityFailure(error, attempt: compatibilityAttempt)
            throw error
        }
    }

    private func validateInferredChannelIfNeeded(attempt: UInt64) async throws {
        guard let snapshot = peripheralManager.resolutionSnapshot(),
              snapshot.binding.source == .inferred else { return }

        var validation = BLEAdapterValidationState()
        publishCompatibilityReport(
            stage: .adapterIdentification,
            subscription: .confirmed,
            attempt: attempt
        )
        let identityResponse = try await sendCommand(
            BLEAdapterValidationCommand.identifyAdapter.rawValue,
            retries: 1
        )
        guard compatibilityAttemptFence.isCurrent(attempt) else { throw CancellationError() }
        validation.receive(identityResponse)
        guard validation.stage == .awaitingEchoDisable else {
            throw BLEManagerError.adapterIdentificationRejected
        }

        publishCompatibilityReport(
            stage: .adapterConfiguration,
            subscription: .confirmed,
            attempt: attempt
        )
        let configurationResponse = try await sendCommand(
            BLEAdapterValidationCommand.disableEcho.rawValue,
            retries: 1
        )
        guard compatibilityAttemptFence.isCurrent(attempt) else { throw CancellationError() }
        validation.receive(configurationResponse)
        guard validation.isAdapterValidated else {
            throw BLEManagerError.adapterConfigurationRejected
        }

        let didRecord = compatibilityLock.withLock { () -> Bool in
            guard activeCompatibilityAttempt == attempt,
                  compatibilityAttemptFence.isCurrent(attempt),
                  let current = peripheralManager.resolutionSnapshot(),
                  current.generation == snapshot.generation,
                  current.peripheralID == snapshot.peripheralID,
                  current.fingerprint == snapshot.fingerprint else { return false }
            return bindingCache.storeValidatedBinding(
                current.binding,
                forPeripheralID: current.peripheralID,
                fingerprint: current.fingerprint,
                validation: validation
            )
        }
        guard didRecord else { throw CancellationError() }
        publishCompatibilityReport(
            stage: .adapterValidated,
            subscription: .confirmed,
            attempt: attempt
        )
    }

    private func awaitChannelValidation(attempt: UInt64) async throws {
        startChannelValidationIfNeeded(attempt: attempt)
        let task = compatibilityLock.withLock { () -> Task<Void, Error>? in
            guard channelValidationAttempt == attempt else { return nil }
            return channelValidationTask
        }
        if let task {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await task.value
                try Task.checkCancellation()
            } onCancel: {
                self.compatibilityLock.withLock {
                    guard self.activeCompatibilityAttempt == attempt,
                          self.channelValidationAttempt == attempt else { return }
                    self.channelValidationTask?.cancel()
                }
            }
        } else {
            try Task.checkCancellation()
            guard compatibilityAttemptFence.isCurrent(attempt) else {
                throw CancellationError()
            }
        }
    }

    private func startChannelValidationIfNeeded(attempt: UInt64) {
        guard compatibilityAttemptFence.isCurrent(attempt),
              let binding = peripheralManager.resolutionSnapshot()?.binding else { return }

        let shouldStartKnown = compatibilityLock.withLock { () -> Bool in
            guard activeCompatibilityAttempt == attempt,
                  channelValidationAttempt != attempt else { return false }
            channelValidationAttempt = attempt
            guard binding.source == .inferred else { return true }
            channelValidationTask = Task { [weak self] in
                guard let self else { throw CancellationError() }
                self.messageProcessor.reset()
                self.applyRedactionForNewLink()
                self.publishCompatibilityReport(
                    stage: .gattResolved,
                    subscription: .confirmed,
                    attempt: attempt
                )
                do {
                    try await self.validateInferredChannelIfNeeded(attempt: attempt)
                    guard self.compatibilityAttemptFence.isCurrent(attempt) else {
                        throw CancellationError()
                    }
                    self.publishConnectedToAdapter(attempt: attempt)
                } catch {
                    self.publishCompatibilityFailure(error, attempt: attempt)
                    if self.compatibilityAttemptFence.isCurrent(attempt) {
                        let oldState = self.connectionState
                        self.connectionState = .error
                        OBDLogger.shared.logConnectionChange(from: oldState, to: .error)
                    }
                    throw error
                }
            }
            return false
        }
        guard shouldStartKnown else { return }
        messageProcessor.reset()
        applyRedactionForNewLink()
        publishCompatibilityReport(
            stage: .gattResolved,
            subscription: .confirmed,
            attempt: attempt
        )
        publishConnectedToAdapter(attempt: attempt)
    }

    /// Sets the wire log's redaction for the link that is starting.
    ///
    /// An old link's late bytes can't arrive on a new one, so normally the hold ends here. But an
    /// adapter a manufacturer batch left unresolved keeps that configuration across the
    /// reconnect, and until its verified recovery completes whatever it answers (to the reset,
    /// to re-initialization) is logged without content. The hold then ends when the addressing
    /// gate opens (`BLECommandExchange.noteAnswered`).
    private func applyRedactionForNewLink() {
        Self.applyRedaction(
            forLinkTo: peripheralManager.connectedPeripheral?.identifier,
            gate: oemAddressingGate,
            wireLog: messageProcessor.wireLog
        )
    }

    /// Ends the redaction hold at a link teardown, unless the adapter that link ran on is still
    /// unresolved: its recovery hasn't happened yet, and the hold stays attached to it.
    private func releaseRedactionUnlessUnresolved(_ peripheralID: UUID?) {
        if let peripheralID, oemAddressingGate.isUnresolved(peripheralID) { return }
        messageProcessor.wireLog.releaseRedaction()
    }

    /// The rule behind `applyRedactionForNewLink`, without CoreBluetooth.
    static func applyRedaction(forLinkTo peripheralID: UUID?, gate: OEMAddressingGate, wireLog: OBDWireLog) {
        if let peripheralID, gate.isUnresolved(peripheralID) {
            wireLog.holdRedaction()
        } else {
            wireLog.releaseRedaction()
        }
    }

    private func publishConnectedToAdapter(attempt: UInt64) {
        guard compatibilityAttemptFence.isCurrent(attempt) else { return }
        let oldState = connectionState
        connectionState = .connectedToAdapter
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)
        DispatchQueue.main.async {
            guard self.compatibilityAttemptFence.isCurrent(attempt) else { return }
            self.obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
        }
        obdInfo("Validated adapter channel is ready", category: .bluetooth)
    }

    func peripheralManager(
        _ manager: BLEPeripheralManager,
        didSetupCharacteristics peripheral: CBPeripheral,
        token: BLESetupToken
    ) {
        let attempt = compatibilityLock.withLock { activeCompatibilityAttempt }
        guard manager.matchesCurrentSetup(token: token, peripheral: peripheral) else { return }
        startChannelValidationIfNeeded(attempt: attempt)
    }

    func peripheralManager(
        _ manager: BLEPeripheralManager,
        didResolve _: BLEAdapterBinding,
        token: BLESetupToken,
        peripheral: CBPeripheral
    ) {
        let attempt = compatibilityLock.withLock { activeCompatibilityAttempt }
        let isPreparedAttempt = compatibilityLock.withLock {
            preparedPeripheralAttempt == attempt
        }
        guard isPreparedAttempt,
              manager.matchesCurrentSetup(token: token, peripheral: peripheral),
              manager.connectedPeripheral === peripheral else { return }
        publishCompatibilityReport(
            stage: .subscription,
            subscription: .pending,
            attempt: attempt
        )
    }

    func peripheralManager(
        _ manager: BLEPeripheralManager,
        didLoseNotificationSubscription error: Error,
        token: BLESetupToken,
        peripheral: CBPeripheral
    ) {
        compatibilityLock.lock()
        defer { compatibilityLock.unlock() }
        let attempt = compatibilityLock.withLock { activeCompatibilityAttempt }
        let ownsAttempt = compatibilityLock.withLock {
            preparedPeripheralAttempt == attempt
                && compatibilityAttemptFence.isCurrent(attempt)
        }
        guard ownsAttempt,
              manager.matchesCurrentSetup(token: token, peripheral: peripheral) else { return }

        obdError("Adapter notification subscription was lost: \(error.localizedDescription)", category: .bluetooth)
        publishCompatibilityReport(
            stage: .failed,
            subscription: .failed,
            failure: .notificationSubscriptionFailed,
            attempt: attempt
        )
        let oldState = connectionState
        connectionState = .error
        OBDLogger.shared.logConnectionChange(from: oldState, to: .error)
        DispatchQueue.main.async {
            guard self.compatibilityAttemptFence.isCurrent(attempt) else { return }
            self.obdDelegate?.connectionStateChanged(state: .error)
        }

        guard centralManager.state == .poweredOn,
              peripheral.state != .disconnected else {
            resetAllState()
            return
        }
        // Keep `disconnectWasRequested` unchanged so a concurrent user-requested
        // disconnect stays user-owned; otherwise normal recovery policy applies.
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func waitForPoweredOn() async throws {
        let maxWaitTime = BLEConstants.bluetoothPowerOnTimeout
        let startTime = CFAbsoluteTimeGetCurrent()
        
        while centralManager.state != .poweredOn {
            // Check for timeout
            if CFAbsoluteTimeGetCurrent() - startTime > maxWaitTime {
                obdError("Bluetooth failed to power on within \(maxWaitTime) seconds", category: .bluetooth)
                throw BLEManagerError.timeout
            }
            
            // Check for terminal states
            switch centralManager.state {
            case .unsupported:
                throw BLEManagerError.unsupported
            case .unauthorized:
                throw BLEManagerError.unauthorized
            case .poweredOff:
                obdWarning("Bluetooth is powered off - waiting...", category: .bluetooth)
            case .resetting:
                obdDebug("Bluetooth is resetting - waiting...", category: .bluetooth)
            default:
                break
            }
            
            try await Task.sleep(nanoseconds: BLEConstants.pollingInterval)
        }
        
        obdDebug("Bluetooth powered on successfully", category: .bluetooth)
    }


    /// Sends a command to the connected peripheral and returns the response.
    ///
    /// Serialized by `commandSemaphore` — only one command is in-flight at a time.
    /// Uses a deterministic 3-step protocol: `beginRequest()` → BLE write → `awaitResponse()`.
    func sendCommand(_ command: String, retries: Int = 3) async throws -> [String] {
        try await sendCommand(command, retries: retries, responseTimeout: BLEConstants.defaultTimeout)
    }

    /// `sendCommand` with a caller-chosen wait for the adapter's `>` prompt. For exchanges a
    /// module needs longer than the default to answer, e.g. a long `19 02` DTC list after a
    /// "response pending" (`7F 19 78`).
    func sendCommand(_ command: String, retries: Int, responseTimeout: TimeInterval) async throws -> [String] {
        try await sendCommand(command, retries: retries, responseTimeout: responseTimeout, authorization: nil)
    }

    /// See `CommProtocol.sendCommand(_:retries:authorization:)`. The check runs once the
    /// mutex is held (so a stale binding reports itself, not a stale attempt) and again inside
    /// every attempt's target resolution.
    func sendCommand(_ command: String, retries: Int, authorization: OBDWriteAuthorization) async throws -> [String] {
        try await sendCommand(command, retries: retries, responseTimeout: BLEConstants.defaultTimeout, authorization: authorization)
    }

    private func sendCommand(
        _ command: String,
        retries: Int,
        responseTimeout: TimeInterval,
        authorization: OBDWriteAuthorization?
    ) async throws -> [String] {
        let compatibilityAttempt = compatibilityLock.withLock { activeCompatibilityAttempt }
        let acquired = await commandSemaphore.wait()
        guard acquired else {
            let error = CancellationError()
            publishCommandFailure(error, attempt: compatibilityAttempt)
            throw error
        }
        defer { commandSemaphore.signal() }
        do {
            try authorization?.check()
            guard isCurrentCompatibilityAttempt(compatibilityAttempt) else {
                throw CancellationError()
            }
            return try await sendCommandLocked(
                command,
                retries: retries,
                responseTimeout: responseTimeout,
                authorization: authorization
            )
        } catch {
            publishCommandFailure(error, attempt: compatibilityAttempt)
            throw error
        }
    }

    /// One attempt, under the same command mutex, for a command whose silence says nothing
    /// about the channel (`ATI`/`AT@1`/`STI` identity queries). Only terminal channel
    /// failures (disconnect, write failure, lost notifications) reach the compatibility
    /// report; a timeout or cancellation leaves the verified report alone.
    func sendOptionalCommand(_ command: String) async throws -> [String] {
        let compatibilityAttempt = compatibilityLock.withLock { activeCompatibilityAttempt }
        let acquired = await commandSemaphore.wait()
        guard acquired else { throw CancellationError() }
        defer { commandSemaphore.signal() }
        do {
            guard isCurrentCompatibilityAttempt(compatibilityAttempt) else {
                throw CancellationError()
            }
            return try await sendCommandLocked(command, retries: 1)
        } catch {
            if Self.optionalCommandFailure(for: error) != nil {
                publishCommandFailure(error, attempt: compatibilityAttempt)
            }
            throw error
        }
    }

    /// The terminal failure an optional command may report: never a timeout or cancellation.
    static func optionalCommandFailure(for error: Error) -> BLECompatibilityFailure? {
        switch commandCompatibilityFailure(for: error) {
        case .adapterResponseTimedOut, .cancelled, nil:
            return nil
        case let failure:
            return failure
        }
    }

    /// The write-and-await body of `sendCommand`, with the command mutex **already held**.
    ///
    /// Split out so a multi-window transaction can send and then keep listening under a single
    /// acquisition; `AsyncSemaphore` is not reentrant, so a transaction must never call
    /// `sendCommand` itself.
    ///
    /// Every write in this transport goes through here (`characteristicHandler.writeCommand` has
    /// no other caller), so the addressing gate consulted inside covers telemetry, scans,
    /// optional commands, transactions, connection setup and the manufacturer channel alike,
    /// always for the peripheral actually being written to.
    ///
    /// - Parameters:
    ///   - deadline: Absolute (`systemUptime`). Manufacturer channel only: one attempt; the
    ///     write and the response share it. Nil keeps the ordinary timing.
    ///   - expectedPeripheralID: When set, an attempt whose connected peripheral is a different
    ///     one fails as a stale link instead of writing to it.
    ///   - authorization: When set, its check runs before every attempt's write: once when the
    ///     peripheral is resolved and again immediately before the write, after any
    ///     resynchronization; its error ends the command with nothing (more) written.
    private func sendCommandLocked(
        _ command: String,
        retries: Int,
        responseTimeout: TimeInterval = BLEConstants.defaultTimeout,
        deadline: TimeInterval? = nil,
        expectedPeripheralID: UUID? = nil,
        logPolicy: OBDWireLogPolicy = .full,
        authorization: OBDWriteAuthorization? = nil
    ) async throws -> [String] {
        try await commandExchange.send(
            command,
            retries: retries,
            responseTimeout: responseTimeout,
            deadline: deadline,
            policy: logPolicy
        ) {
            try commandTarget(expectedPeripheralID: expectedPeripheralID, authorization: authorization)
        }
    }

    /// Resolves where one attempt goes. Called per attempt (the connection may drop between
    /// retries). The peripheral object and its write session are captured together; the write
    /// goes out on that session or not at all, and `revalidate` (run by the exchange right
    /// before the write, after any resynchronization) checks that both, and the request's
    /// binding, still hold.
    ///
    /// A bound request's `authorization.whileAuthorized` is the command's first-write gate: the
    /// first chunk's hand-off to CoreBluetooth runs inside the binding owner's lock, after any
    /// wait for flow control, so a revocation either comes first (nothing written,
    /// `BLEFirstWriteRefused`) or returns only after the hand-off. The exchange passes the gate
    /// to the command's write only; resynchronization probes on this target are written ungated.
    private func commandTarget(
        expectedPeripheralID: UUID?,
        authorization: OBDWriteAuthorization?
    ) throws -> BLECommandExchange.Target {
        let manager: BLEPeripheralManager = peripheralManager
        let handler: BLECharacteristicHandler = characteristicHandler
        guard let peripheral = manager.connectedPeripheral,
              let session = handler.currentWriteSession(for: peripheral) else {
            obdError("Missing peripheral or ECU characteristic", category: .bluetooth)
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }
        if let expectedPeripheralID, peripheral.identifier != expectedPeripheralID {
            throw BLEMessageProcessorError.staleRequestToken
        }
        try authorization?.check()
        return BLECommandExchange.Target(
            peripheralID: peripheral.identifier,
            revalidate: {
                try authorization?.check()
                guard manager.connectedPeripheral === peripheral,
                      handler.currentWriteSession(for: peripheral) == session else {
                    // A bound request reports its binding; anything else, the stale link.
                    if authorization != nil { throw OBDVehicleLinkError.linkChanged }
                    throw BLEMessageProcessorError.staleRequestToken
                }
            },
            firstWriteGate: authorization?.whileAuthorized
        ) { command, deadlineAt, firstWriteGate in
            // The exchange's absolute instant goes to the write as it is: no timer restarts.
            try await handler.writeCommand(
                command, to: peripheral, session: session, deadlineAt: deadlineAt, firstWriteGate: firstWriteGate
            )
        }
    }

    private var commandExchange: BLECommandExchange {
        BLECommandExchange(processor: messageProcessor, gate: oemAddressingGate)
    }


    /// Sends once, then re-arms the response handler for as many windows as the exchange needs —
    /// **never writing again** — with the command mutex held across the whole transaction.
    ///
    /// Holding the mutex is the point: releasing it between windows would let telemetry polling
    /// write into the middle of the exchange and swallow the ECU's final message. Each window is
    /// armed with `beginContinuationRequest()`, which keeps the buffer, so a final message that
    /// landed in the gap since the last `>` is drained instead of lost.
    ///
    /// A window that times out (or reports `NO DATA`) ends the transaction with whatever arrived;
    /// cancellation and link loss are rethrown, so the caller can treat them as the terminal
    /// interruptions they are instead of publishing a report built on stale interim evidence.
    /// The body is `BLECommandExchange.transaction`.
    func sendCommandTransaction(
        _ command: String,
        retries: Int,
        shouldContinueListening: @escaping @Sendable ([String]) -> Bool,
        listenDeadline: TimeInterval
    ) async throws -> [String] {
        try await sendCommandTransaction(
            command,
            retries: retries,
            responseTimeout: nil,
            shouldContinueListening: shouldContinueListening,
            listenDeadline: listenDeadline
        )
    }

    /// See `CommProtocol.sendCommandTransaction(_:retries:responseTimeout:shouldContinueListening:listenDeadline:)`.
    /// `responseTimeout` is the first send's wait for its answer; nil is the default.
    func sendCommandTransaction(
        _ command: String,
        retries: Int,
        responseTimeout: TimeInterval?,
        shouldContinueListening: @escaping @Sendable ([String]) -> Bool,
        listenDeadline: TimeInterval
    ) async throws -> [String] {
        let compatibilityAttempt = compatibilityLock.withLock { activeCompatibilityAttempt }
        let acquired = await commandSemaphore.wait()
        guard acquired else {
            let error = CancellationError()
            publishCommandFailure(error, attempt: compatibilityAttempt)
            throw error
        }
        defer { commandSemaphore.signal() }

        do {
            guard isCurrentCompatibilityAttempt(compatibilityAttempt) else {
                throw CancellationError()
            }
            return try await commandExchange.transaction(
                command,
                retries: retries,
                responseTimeout: responseTimeout ?? BLEConstants.defaultTimeout,
                shouldContinueListening: shouldContinueListening,
                listenDeadline: listenDeadline,
                checkAttempt: {
                    guard isCurrentCompatibilityAttempt(compatibilityAttempt) else {
                        throw CancellationError()
                    }
                },
                checkLink: {
                    guard peripheralManager.connectedPeripheral != nil else {
                        throw BLEManagerError.peripheralNotConnected
                    }
                }
            ) {
                try commandTarget(expectedPeripheralID: nil, authorization: nil)
            }
        } catch {
            publishCommandFailure(error, attempt: compatibilityAttempt)
            throw error
        }
    }

    /// One acquisition of the command mutex around a whole manufacturer batch. See
    /// `CommProtocol.withExclusiveCommandChannel`.
    ///
    /// `deadline` (absolute, `systemUptime`) bounds the wait for the mutex too: if it passes
    /// first, `OEMTransportError.deadlineExpired` is thrown and `body` never runs. Cancellation
    /// while waiting throws `CancellationError`.
    ///
    /// Wire logging is redacted from the moment the channel opens. It stays redacted after the
    /// channel closes unless `body` returned normally without marking the adapter unresolved:
    /// only then was the stream proven clean (a verified restore resynchronized it). Otherwise a
    /// late manufacturer answer may still arrive, and the hold lasts until the addressing gate
    /// opens after a verified recovery or the link is torn down.
    func withExclusiveCommandChannel<T>(
        deadline: TimeInterval,
        _ body: @escaping (OEMCommandChannel) async throws -> T
    ) async throws -> T {
        try await withExclusiveCommandChannel(deadline: deadline, now: { ProcessInfo.processInfo.systemUptime }, body)
    }

    func withExclusiveCommandChannel<T>(
        deadline: TimeInterval,
        now: @escaping @Sendable () -> TimeInterval,
        _ body: @escaping (OEMCommandChannel) async throws -> T
    ) async throws -> T {
        let compatibilityAttempt = compatibilityLock.withLock { activeCompatibilityAttempt }
        switch await commandSemaphore.wait(until: deadline, now: now) {
        case .acquired:
            break
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw OEMTransportError.deadlineExpired
        }
        defer { commandSemaphore.signal() }

        // A newer connection attempt took over while we waited: this channel's link is gone.
        guard isCurrentCompatibilityAttempt(compatibilityAttempt) else {
            throw BLEMessageProcessorError.staleRequestToken
        }
        try Task.checkCancellation()
        // The free-permit fast path doesn't look at the clock.
        guard now() < deadline else {
            throw OEMTransportError.deadlineExpired
        }
        // Captured once: the gate is bound to the adapter this batch runs on, whatever happens
        // to the connection afterwards.
        guard let peripheralID = peripheralManager.connectedPeripheral?.identifier else {
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }
        guard !oemAddressingGate.isUnresolved(peripheralID) else {
            throw OEMAddressingGateError.addressingUnresolved
        }

        let wireLog = messageProcessor.wireLog
        wireLog.holdRedaction()
        let channel = BLEExclusiveCommandChannel(manager: self, attempt: compatibilityAttempt, peripheralID: peripheralID)
        let result: T
        do {
            result = try await body(channel)
        } catch {
            channel.close()
            throw error
        }
        channel.close()
        // Proven clean, not assumed: a batch can end functional without ever configuring the
        // adapter and still leave a late answer outstanding.
        if !channel.markedUnresolved, !messageProcessor.isStreamDirty {
            wireLog.releaseRedaction()
        }
        return result
    }

    /// A send on the exclusive channel, with the mutex already held by
    /// `withExclusiveCommandChannel`. One attempt, never retransmitted; `deadline` covers write
    /// readiness, the write's acknowledgement and the response. Like an optional command, only
    /// terminal channel failures reach the compatibility report: a module that doesn't answer in
    /// time says nothing about the adapter.
    fileprivate func sendExclusiveLocked(
        _ command: String,
        deadline: TimeInterval,
        attempt: UInt64,
        peripheralID: UUID
    ) async throws -> [String] {
        guard isCurrentCompatibilityAttempt(attempt) else {
            throw BLEMessageProcessorError.staleRequestToken
        }
        do {
            return try await sendCommandLocked(
                command,
                retries: 1,
                deadline: deadline,
                expectedPeripheralID: peripheralID,
                logPolicy: .redacted
            )
        } catch {
            if Self.optionalCommandFailure(for: error) != nil {
                publishCommandFailure(error, attempt: attempt)
            }
            throw error
        }
    }

    /// One more prompt-terminated answer on the exclusive channel, without writing. See
    /// `BLECommandExchange.listen`.
    fileprivate func listenExclusiveLocked(
        deadline: TimeInterval,
        attempt: UInt64,
        peripheralID: UUID
    ) async throws -> [String] {
        guard isCurrentCompatibilityAttempt(attempt) else {
            throw BLEMessageProcessorError.staleRequestToken
        }
        guard peripheralManager.connectedPeripheral?.identifier == peripheralID else {
            throw BLEManagerError.peripheralNotConnected
        }
        return try await commandExchange.listen(deadline: deadline, policy: .redacted)
    }

    /// Proves the stream in sync on the exclusive channel. See `BLECommandExchange.resynchronize`.
    fileprivate func resynchronizeExclusiveLocked(
        deadline: TimeInterval,
        attempt: UInt64,
        peripheralID: UUID
    ) async throws -> Bool {
        guard isCurrentCompatibilityAttempt(attempt) else {
            throw BLEMessageProcessorError.staleRequestToken
        }
        guard let peripheral = peripheralManager.connectedPeripheral, peripheral.identifier == peripheralID else {
            throw BLEManagerError.peripheralNotConnected
        }
        let handler: BLECharacteristicHandler = characteristicHandler
        // Probes are bound to the write session current now, like commands.
        guard let session = handler.currentWriteSession(for: peripheral) else {
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }
        let target = BLECommandExchange.Target(peripheralID: peripheralID) { command, deadlineAt in
            try await handler.writeCommand(command, to: peripheral, session: session, deadlineAt: deadlineAt)
        }
        return try await commandExchange.resynchronize(deadline: deadline, policy: .redacted, target: target) == .synchronized
    }

    /// See `OEMCommandChannel.requireResynchronization`.
    fileprivate func requireStreamResynchronization() {
        messageProcessor.markStreamDirty()
    }

    /// Arms the addressing gate for the adapter the batch ran on.
    fileprivate func markOEMAddressingUnresolved(peripheralID: UUID) {
        oemAddressingGate.markUnresolved(peripheralID)
    }

    func scanForPeripherals() async throws {
        startScanning(nil)
        try await Task.sleep(nanoseconds: UInt64(BLEConstants.scanDuration * 1_000_000_000))
        stopScan()
    }

    private func resetConfigure() {
        characteristicHandler.reset()

        let oldState = connectionState
        connectionState = .disconnected
        if oldState != connectionState {
            OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

            DispatchQueue.main.async {
                self.obdDelegate?.connectionStateChanged(state: .disconnected)
            }
        }
    }

    // MARK: - Auto-Reconnect

    /// Schedule an auto-reconnect with exponential backoff
    private func scheduleAutoReconnect(peripheralUUID: UUID) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self = self else { return }
            // Exponential backoff: 1s, 2s, 4s, 8s, 16s
            let delay = min(pow(2.0, Double(self.reconnectAttempts)), 16.0)
            self.reconnectAttempts += 1
            obdInfo("Auto-reconnect: waiting \(delay)s before attempt \(self.reconnectAttempts)", category: .bluetooth)

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self.autoReconnectEnabled else {
                obdInfo("Auto-reconnect disabled during wait, aborting", category: .bluetooth)
                return
            }
            guard self.centralManager.state == .poweredOn else {
                obdInfo("Auto-reconnect skipped because Bluetooth is not powered on", category: .bluetooth)
                return
            }

            // Try to retrieve peripheral from iOS cache
            if let peripheral = self.centralManager.retrievePeripherals(withIdentifiers: [peripheralUUID]).first {
                obdInfo("Auto-reconnect: found peripheral in cache, connecting...", category: .bluetooth)
                self.connect(to: peripheral)
            } else {
                obdWarning("Auto-reconnect: peripheral not in cache, skipping generic scan", category: .bluetooth)
            }
        }
    }

    // MARK: - Full State Reset

    /// Complete reset of all BLE state for reconnection
    /// Call this AFTER disconnection is confirmed
    public func resetAllState(preservingCompatibilityAttempt: UInt64? = nil) {
        cancelConnectTimeout()
        let preservedAttempt = preservingCompatibilityAttempt ?? compatibilityLock.withLock {
            compatibilityAttemptPreservedDuringReset ?? requestedTeardown.attempt
        }
        let currentAttempt = compatibilityLock.withLock { activeCompatibilityAttempt }
        if BLECompatibilityResetPolicy.shouldRecordDisconnected(
            preservedAttempt: preservedAttempt,
            currentAttempt: currentAttempt
        ) {
            recordDisconnected()
        }
        let oldState = connectionState

        // Reset characteristic handler with notification unsubscription
        // Pass peripheral so it can unsubscribe from notifications before clearing
        let tornDownPeripheralID = peripheralManager.connectedPeripheral?.identifier
        if let peripheral = peripheralManager.connectedPeripheral {
            characteristicHandler.reset(peripheral: peripheral)
        } else {
            characteristicHandler.reset()
        }

        // Reset message processor buffer (clears stale data)
        messageProcessor.reset()
        releaseRedactionUnlessUnresolved(tornDownPeripheralID)

        // Clear discovered peripherals list
        peripheralScanner.reset()

        // Reset peripheral manager (clears pending continuations and peripheral reference)
        peripheralManager.reset()

        compatibilityLock.withLock {
            if requestedTeardown.attempt == currentAttempt {
                requestedTeardown.clear()
                disconnectWasRequested = false
            }
        }

        // Reset connection state with delegate notification
        connectionState = .disconnected

        if oldState != connectionState {
            OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

            DispatchQueue.main.async {
                self.obdDelegate?.connectionStateChanged(state: .disconnected)
            }
        }

        obdInfo("BLE state fully reset", category: .bluetooth)
    }

    private func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    private func scheduleConnectTimeout(for peripheral: CBPeripheral, attempt: UInt64? = nil) {
        cancelConnectTimeout()

        let timeout = BLEConstants.connectionTimeout + 2.0
        let capturedAttempt = attempt ?? compatibilityLock.withLock { activeCompatibilityAttempt }

        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }

            self.compatibilityLock.withLock {
                guard Self.shouldProcessConnectTimeout(
                    capturedAttempt: capturedAttempt,
                    activeAttempt: self.activeCompatibilityAttempt,
                    preparedAttempt: self.preparedPeripheralAttempt,
                    fenceIsCurrent: self.compatibilityAttemptFence.isCurrent(capturedAttempt),
                    isConnecting: self.connectionState == .connecting,
                    matchesPeripheral: self.peripheralManager.connectedPeripheral === peripheral
                ) else { return }

                obdWarning("Connect attempt timed out for peripheral \(peripheral.name ?? peripheral.identifier.uuidString), forcing cleanup", category: .bluetooth)

                if self.centralManager.state == .poweredOn {
                    self.peripheralManager.failCurrentSetup(BLEManagerError.peripheralNotConnected)
                    self.recordDisconnected(
                        expectDisconnectCallback: true,
                        armStandingReconnectAfterTeardown: true
                    )
                    self.disconnectWasRequested = true
                    self.centralManager.cancelPeripheralConnection(peripheral)
                } else {
                    obdWarning("Bluetooth not powered on while timing out connect attempt", category: .bluetooth)
                    self.resetAllState()
                }
            }
        }
    }

    /// Disconnect and wait for completion
    /// - Parameter timeout: Maximum time to wait for disconnect
    /// - Returns: True if disconnect confirmed, false if timed out
    @discardableResult
    func disconnectPeripheralAsync(timeout: TimeInterval = 3.0) async -> Bool {
        guard let peripheral = peripheralManager.connectedPeripheral else {
            return true // Already disconnected
        }
        guard centralManager.state == .poweredOn else {
            obdWarning("Disconnect requested while Bluetooth is not powered on, forcing cleanup", category: .bluetooth)
            resetAllState()
            return false
        }

        disconnectWasRequested = true
        centralManager.cancelPeripheralConnection(peripheral)

        // Silent standing reconnects intentionally keep the public state at
        // .disconnected. The PM identity is released only by the terminal
        // CoreBluetooth callback, so it is the reliable completion signal.
        let startTime = Date()
        while Self.shouldWaitForDisconnectCleanup(
            connectionState: connectionState,
            stillOwnsPeripheral: peripheralManager.connectedPeripheral === peripheral
        ) {
            if Date().timeIntervalSince(startTime) > timeout {
                obdWarning("Disconnect timed out, forcing state cleanup", category: .bluetooth)
                // FORCE cleanup on timeout - don't leave in half-connected state
                peripheralManager.reset()
                connectionState = .disconnected
                disconnectWasRequested = false
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        return true
    }
}

// MARK: - CBCentralManagerDelegate, CBPeripheralDelegate

/// Extension to conform to CBCentralManagerDelegate and CBPeripheralDelegate
/// and handle the delegate methods.
extension BLEManager: CBCentralManagerDelegate {

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        didDiscover(central, peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        didConnect(central, peripheral: peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        didUpdateState(central)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        didFailToConnect(central, peripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        didDisconnect(central, peripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        willRestoreState(central, dict: dict)
    }
}

/// The channel `BLEManager.withExclusiveCommandChannel` hands to a manufacturer batch. Valid only
/// while that call holds the mutex: once closed, every send fails as a stale link.
private final class BLEExclusiveCommandChannel: OEMCommandChannel {
    private let manager: BLEManager
    private let attempt: UInt64
    /// The adapter the batch runs on, captured when the channel opened.
    let peripheralID: UUID
    private let lock = NSLock()
    private var closed = false
    private var unresolved = false

    init(manager: BLEManager, attempt: UInt64, peripheralID: UUID) {
        self.manager = manager
        self.attempt = attempt
        self.peripheralID = peripheralID
    }

    func close() {
        lock.withLock { closed = true }
    }

    var markedUnresolved: Bool {
        lock.withLock { unresolved }
    }

    func send(_ command: String, deadline: TimeInterval) async throws -> [String] {
        guard !lock.withLock({ closed }) else { throw BLEMessageProcessorError.staleRequestToken }
        return try await manager.sendExclusiveLocked(command, deadline: deadline, attempt: attempt, peripheralID: peripheralID)
    }

    func listen(deadline: TimeInterval) async throws -> [String] {
        guard !lock.withLock({ closed }) else { throw BLEMessageProcessorError.staleRequestToken }
        return try await manager.listenExclusiveLocked(deadline: deadline, attempt: attempt, peripheralID: peripheralID)
    }

    func resynchronize(deadline: TimeInterval) async throws -> Bool {
        guard !lock.withLock({ closed }) else { throw BLEMessageProcessorError.staleRequestToken }
        return try await manager.resynchronizeExclusiveLocked(deadline: deadline, attempt: attempt, peripheralID: peripheralID)
    }

    func requireResynchronization() {
        guard !lock.withLock({ closed }) else { return }
        manager.requireStreamResynchronization()
    }

    /// Fails closed: marks the captured adapter even if the channel was already closed or a newer
    /// connection attempt has started meanwhile.
    func markAddressingUnresolved() {
        lock.withLock { unresolved = true }
        manager.markOEMAddressingUnresolved(peripheralID: peripheralID)
    }
}

enum BLEManagerError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case missingPeripheralOrCharacteristic
    case unknownCharacteristic
    case scanTimeout
    case sendMessageTimeout
    case stringConversionFailed
    case noData
    case incorrectDataConversion
    case peripheralNotConnected
    case sendingMessagesInProgress
    case timeout
    case peripheralNotFound
    case unknownError
    case unsupported
    case unauthorized
    case setupWaitAlreadyRegistered
    case adapterProfileResolution(BLEAdapterProfileResolutionError)
    case adapterIdentificationRejected
    case adapterConfigurationRejected
    case notificationSubscriptionFailed

    public var description: String {
        switch self {
        case .missingPeripheralOrCharacteristic:
            return "Error: Device not connected. Make sure the device is correctly connected."
        case .scanTimeout:
            return "Error: Scan timed out. Please try to scan again or check the device's Bluetooth connection."
        case .sendMessageTimeout:
            return "Error: Send message timed out. Please try to send the message again or check the device's Bluetooth connection."
        case .stringConversionFailed:
            return "Error: Failed to convert string. Please make sure the string is in the correct format."
        case .noData:
            return "Error: No Data"
        case .unknownCharacteristic:
            return "Error: Unknown characteristic"
        case .incorrectDataConversion:
            return "Error: Incorrect data conversion"
        case .peripheralNotConnected:
            return "Error: Peripheral not connected"
        case .sendingMessagesInProgress:
            return "Error: Sending messages in progress"
        case .timeout:
            return "Error: Timeout"
        case .peripheralNotFound:
            return "Error: Peripheral not found"
        case .unknownError:
            return "Unknown Error"
        case .unsupported:
            return "Error: Device does not support Bluetooth Low Energy"
        case .unauthorized:
            return "Error: App not authorized to use Bluetooth Low Energy"
        case .setupWaitAlreadyRegistered:
            return "Error: Adapter setup is already being awaited"
        case .adapterProfileResolution:
            return "Error: Adapter GATT layout is unsupported or ambiguous"
        case .adapterIdentificationRejected:
            return "Error: Adapter identification response was not recognized"
        case .adapterConfigurationRejected:
            return "Error: Adapter configuration was rejected"
        case .notificationSubscriptionFailed:
            return "Error: Adapter notification subscription failed"
        }
    }

    var errorDescription: String? {
        description
    }
}
