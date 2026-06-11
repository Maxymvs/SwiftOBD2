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
    static let maxBufferSize = 1024
    static let bluetoothPowerOnTimeout: TimeInterval = 30.0
    static let pollingInterval: UInt64 = 100_000_000 // 100ms in nanoseconds
}

class BLEManager: NSObject, CommProtocol, BLEPeripheralManagerDelegate {
    private let peripheralSubject = PassthroughSubject<CBPeripheral, Never>()
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

    // Focused components
    private var centralManager: CBCentralManager!
    private var messageProcessor: BLEMessageProcessor!
    private var characteristicHandler: BLECharacteristicHandler!
    private var peripheralManager: BLEPeripheralManager!
    private var peripheralScanner: BLEPeripheralScanner!

    /// Serializes all sendCommand calls — ELM327 can only handle one command at a time
    private let commandSemaphore = AsyncSemaphore(value: 1)

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
        characteristicHandler = BLECharacteristicHandler(messageProcessor: messageProcessor)
        peripheralManager = BLEPeripheralManager(characteristicHandler: characteristicHandler)
        peripheralScanner = BLEPeripheralScanner()
    }

    // MARK: - Central Manager Control Methods

    func startScanning(_ serviceUUIDs: [CBUUID]?) {
        guard centralManager.state == .poweredOn else { 
            obdWarning("Cannot start scanning - Bluetooth not powered on", category: .bluetooth)
            return 
        }
        
        obdDebug("Starting BLE scan for services: \(serviceUUIDs?.map { $0.uuidString } ?? ["All"])", category: .bluetooth)
        
        // Use allowDuplicates: false for better performance - we don't need duplicate discovery events
        let scanOptions = [CBCentralManagerScanOptionAllowDuplicatesKey: false]
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
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Central Manager Delegate Methods

    func didUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            centralManagerDidPowerOn()
        case .poweredOff:
            obdWarning("Bluetooth powered off", category: .bluetooth)
            peripheralManager.connectedPeripheral = nil
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
    }

    func connect(to peripheral: CBPeripheral) {
        guard centralManager.state == .poweredOn else {
            obdWarning("Ignoring connect request while Bluetooth is not powered on", category: .bluetooth)
            return
        }

        let peripheralName = peripheral.name ?? "Unnamed"
        obdInfo("Attempting connection to peripheral: \(peripheralName)", category: .bluetooth)

        lastConnectedPeripheralUUID = peripheral.identifier
        peripheralManager.setPeripheral(peripheral, discoverServices: false)
        
        let oldState = connectionState
        connectionState = .connecting
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)
        
        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .connecting)
        }
        
        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        scheduleConnectTimeout(for: peripheral)
        if centralManager.isScanning {
            centralManager.stopScan()
        }
    }

    func didConnect(_: CBCentralManager, peripheral: CBPeripheral) {
        obdInfo("Connected to peripheral: \(peripheral.name ?? "Unnamed")", category: .bluetooth)
        cancelConnectTimeout()
        reconnectAttempts = 0 // Reset on successful connection
        lastConnectedPeripheralUUID = peripheral.identifier
        peripheralManager.setPeripheral(peripheral, discoverServices: true)
        // Note: connectionState will be set to .connectedToAdapter in peripheralManager delegate
    }

    func didFailToConnect(_: CBCentralManager, peripheral: CBPeripheral, error: Error?) {
        let peripheralName = peripheral.name ?? "Unnamed"
        let errorMsg = error?.localizedDescription ?? "Unknown error"
        obdError("Connection failed to peripheral: \(peripheralName) - \(errorMsg)", category: .bluetooth)
        cancelConnectTimeout()
        
        let oldState = connectionState
        connectionState = .error
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)
        
        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .error)
        }
    }

    func didDisconnect(_: CBCentralManager, peripheral: CBPeripheral, error: Error?) {
        let peripheralName = peripheral.name ?? "Unnamed"
        let wasUnexpected = error != nil
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
        resetAllState()

        // Auto-reconnect on unexpected disconnect if enabled
        if wasUnexpected && autoReconnectEnabled && reconnectAttempts < maxReconnectAttempts {
            obdInfo("Scheduling auto-reconnect attempt \(reconnectAttempts + 1)/\(maxReconnectAttempts)", category: .bluetooth)
            scheduleAutoReconnect(peripheralUUID: peripheralUUID)
        } else if reconnectAttempts >= maxReconnectAttempts {
            obdWarning("Max reconnect attempts reached, falling back to standing reconnect", category: .bluetooth)
            reconnectAttempts = 0
            armStandingReconnect()
        }
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
        guard autoReconnectEnabled else { return false }
        guard centralManager.state == .poweredOn else {
            obdDebug("Standing reconnect not armed: Bluetooth is not powered on", category: .bluetooth)
            return false
        }
        guard let uuid = lastConnectedPeripheralUUID,
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            obdDebug("Standing reconnect not armed: no saved peripheral in system cache", category: .bluetooth)
            return false
        }

        switch peripheral.state {
        case .connected, .connecting:
            // Already connected or a connect is already pending at the OS level.
            return true
        default:
            break
        }

        obdInfo("Arming standing reconnect to \(peripheral.name ?? uuid.uuidString) — pending connect with no timeout", category: .bluetooth)
        peripheralManager.setPeripheral(peripheral, discoverServices: false)
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
                // Peripheral still connected - set up properly
                peripheralManager.setPeripheral(peripheral, discoverServices: true)
                connectionState = .connectedToAdapter
                cancelConnectTimeout()
                obdInfo("Restored connected peripheral", category: .bluetooth)
            } else if peripheral.state == .connecting {
                // A pending connect survived app termination (standing
                // reconnect). Leave it pending with no timeout — iOS completes
                // it when the adapter powers on. State stays .disconnected so
                // the app treats the standing request as invisible.
                peripheralManager.setPeripheral(peripheral, discoverServices: false)
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
        startScanning(nil)
    }

    /// Stop peripheral scanning
    func stopPeripheralScanning() {
        stopScan()
    }

    // MARK: - Async Methods

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        try await waitForPoweredOn()

        // ALWAYS disconnect and reset before any new connection attempt
        // This handles stale state after force quit, timeouts, or partial connections
        // Never skip cleanup even for the same peripheral - stale BLE state causes
        // corrupted communication after reconnection
        if connectionState != .disconnected || peripheralManager.connectedPeripheral != nil {
            obdInfo("Resetting connection state before new connection", category: .bluetooth)
            _ = await disconnectPeripheralAsync()
            resetAllState()
            // Brief delay for reliable Bluetooth cleanup
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        }

        let targetPeripheral: CBPeripheral
        if let peripheral = peripheral {
            targetPeripheral = peripheral
        } else {
            startScanning(BLEPeripheralScanner.supportedServices)
            targetPeripheral = try await peripheralScanner.waitForFirstPeripheral(timeout: timeout)
        }

        connect(to: targetPeripheral)

        try await peripheralManager.waitForCharacteristicsSetup(timeout: timeout)

        // Clear any stale data from connection handshake
        messageProcessor.reset()
    }

    func peripheralManager(_ manager: BLEPeripheralManager, didSetupCharacteristics peripheral: CBPeripheral) {
        let oldState = connectionState
        connectionState = .connectedToAdapter
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)
        
        // Dispatch delegate call to main queue since it might update UI
        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
        }
        
        obdInfo("Characteristics setup complete, connected to adapter", category: .bluetooth)
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
        let acquired = await commandSemaphore.wait()
        guard acquired else { throw CancellationError() }
        defer { commandSemaphore.signal() }
        try Task.checkCancellation()

        for attempt in 1...retries {
            // Validate peripheral per attempt (connection may drop between retries)
            guard let peripheral = peripheralManager.connectedPeripheral else {
                obdError("Missing peripheral or ECU characteristic", category: .bluetooth)
                throw BLEManagerError.missingPeripheralOrCharacteristic
            }

            do {
                let token = messageProcessor.beginRequest()
                try characteristicHandler.writeCommand(command, to: peripheral)
                let response = try await messageProcessor.awaitResponse(for: token, timeout: BLEConstants.defaultTimeout)
                obdDebug("Command response: \(response.joined(separator: " | "))", category: .communication)
                return response
            } catch {
                // Non-retryable errors — exit immediately
                if error is CancellationError { throw error }
                if let processorError = error as? BLEMessageProcessorError,
                   processorError == .staleRequestToken { throw error }
                if attempt == retries {
                    obdError("Command failed after \(retries) attempts: \(command) - \(error.localizedDescription)", category: .communication)
                    throw error
                }
                obdDebug("Attempt \(attempt)/\(retries) failed for \(command): \(error.localizedDescription), retrying...", category: .communication)
                messageProcessor.reset()
                try? await Task.sleep(nanoseconds: UInt64(BLEConstants.retryDelay * 1_000_000_000))
            }
        }
        throw BLEManagerError.noData
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
    public func resetAllState() {
        cancelConnectTimeout()
        let oldState = connectionState

        // Reset characteristic handler with notification unsubscription
        // Pass peripheral so it can unsubscribe from notifications before clearing
        if let peripheral = peripheralManager.connectedPeripheral {
            characteristicHandler.reset(peripheral: peripheral)
        } else {
            characteristicHandler.reset()
        }

        // Reset message processor buffer (clears stale data)
        messageProcessor.reset()

        // Clear discovered peripherals list
        peripheralScanner.reset()

        // Reset peripheral manager (clears pending continuations and peripheral reference)
        peripheralManager.reset()

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

    private func scheduleConnectTimeout(for peripheral: CBPeripheral) {
        cancelConnectTimeout()

        let timeout = BLEConstants.connectionTimeout + 2.0
        let targetIdentifier = peripheral.identifier

        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }

            guard self.connectionState == .connecting,
                  self.peripheralManager.connectedPeripheral?.identifier == targetIdentifier else {
                return
            }

            obdWarning("Connect attempt timed out for peripheral \(peripheral.name ?? peripheral.identifier.uuidString), forcing cleanup", category: .bluetooth)

            if self.centralManager.state == .poweredOn {
                self.centralManager.cancelPeripheralConnection(peripheral)
            } else {
                obdWarning("Bluetooth not powered on while timing out connect attempt", category: .bluetooth)
            }

            self.resetAllState()

            // The adapter is unreachable (engine off, out of range). Replace
            // the cancelled attempt with a standing pending connect so the
            // next ignition reconnects without any app-side wake signal.
            self.armStandingReconnect()
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

        centralManager.cancelPeripheralConnection(peripheral)

        // Wait for connectionState to become .disconnected
        let startTime = Date()
        while connectionState != .disconnected {
            if Date().timeIntervalSince(startTime) > timeout {
                obdWarning("Disconnect timed out, forcing state cleanup", category: .bluetooth)
                // FORCE cleanup on timeout - don't leave in half-connected state
                peripheralManager.reset()
                connectionState = .disconnected
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

enum BLEManagerError: Error, CustomStringConvertible, LocalizedError {
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
        }
    }

    var errorDescription: String? {
        description
    }
}
