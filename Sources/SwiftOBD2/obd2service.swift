import Combine
import CoreBluetooth
import Foundation

public enum ConnectionType: String, CaseIterable {
    case bluetooth = "Bluetooth"
    case wifi = "Wi-Fi"
    case demo = "Demo"
}

public protocol OBDServiceDelegate: AnyObject {
    func connectionStateChanged(state: ConnectionState)
}

struct Command: Codable {
    var bytes: Int
    var command: String
    var decoder: String
    var description: String
    var live: Bool
    var maxValue: Int
    var minValue: Int
}

public class ConfigurationService {
    static var shared = ConfigurationService()
    var connectionType: ConnectionType {
        get {
            let rawValue = UserDefaults.standard.string(forKey: "connectionType") ?? "Bluetooth"
            return ConnectionType(rawValue: rawValue) ?? .bluetooth
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "connectionType")
        }
    }
}

/// A class that provides an interface to the ELM327 OBD2 adapter and the vehicle.
///
/// - Key Responsibilities:
///   - Establishing a connection to the adapter and the vehicle.
///   - Sending and receiving OBD2 commands.
///   - Providing information about the vehicle.
///   - Managing the connection state.
public class OBDService: ObservableObject, OBDServiceDelegate {
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var connectedPeripheral: CBPeripheral?
    @Published public private(set) var adapterCompatibilityReport: BLECompatibilityReport?

    // MARK: - Connection Metadata Cache
    /// Cached OBDInfo from last successful connection (survives transient reconnect failures)
    /// Cleared explicitly by caller on user-initiated disconnect, NOT on stopConnection()
    @Published public private(set) var latestOBDInfo: OBDInfo?
    /// Cached peripheral name from last successful connection
    public private(set) var latestConnectedPeripheralName: String?

    /// The vehicle link that is up right now, with the VIN read while setting it up. Unlike
    /// `latestOBDInfo` it never outlives its link: it is cleared when a setup starts and
    /// whenever the service leaves `.connectedToVehicle`, and a new id is minted by every
    /// successful setup. So a VIN taken from here was read on this link, never on an earlier
    /// one. Only a setup that still owns the connection publishes it, in the same main-actor
    /// operation that checks the ownership. Written on the main actor only.
    ///
    /// The record carries the transport's connection identity it was published on, and this
    /// getter compares it with the transport's identity now. The transport invalidates that
    /// identity itself, the moment the connection goes away, so a link never outlives its
    /// connection even before the state change that clears the record reaches the main queue.
    public var vehicleLink: OBDVehicleLink? { vehicleLinkRecord.currentLink(adapter: elm327) }

    /// Backs `vehicleLink`, with the adapter connection it was published on, so a bound request
    /// can check it with the transport's command mutex held (`clearTroubleCodes(on:)`).
    private let vehicleLinkRecord = OBDVehicleLinkRecord()

    @Published public var connectionType: ConnectionType {
        didSet {
            switchConnectionType(connectionType)
            ConfigurationService.shared.connectionType = connectionType
        }
    }

    /// The internal ELM327 object responsible for direct adapter interaction.
    private var elm327: ELM327

    private var cancellables = Set<AnyCancellable>()
    private var compatibilityReportCancellable: AnyCancellable?
    private let compatibilityAttemptFence = BLECompatibilityAttemptFence()

    /// Initializes the OBDService object.
    ///
    /// - Parameter connectionType: The desired connection type (default is Bluetooth).
    ///
    ///
    public init(connectionType: ConnectionType = .bluetooth) {
        self.connectionType = connectionType
#if targetEnvironment(simulator)
        elm327 = ELM327(comm: MOCKComm())
#else
        switch connectionType {
        case .bluetooth:
            let bleManager = BLEManager()
            elm327 = ELM327(comm: bleManager)
        case .wifi:
            elm327 = ELM327(comm: WifiManager())
        case .demo:
            elm327 = ELM327(comm: MOCKComm())
        }
#endif
        elm327.obdDelegate = self
        bindCompatibilityReporting()
    }

    /// Test seam: a service over a given transport.
    init(comm: CommProtocol, connectionType: ConnectionType) {
        self.connectionType = connectionType
        elm327 = ELM327(comm: comm)
        elm327.obdDelegate = self
        bindCompatibilityReporting()
    }

    /// Test seam: awaited by a setup after its last ownership check, right before it publishes
    /// its result. Lets a test hold one setup there while another takes over. Nil in production.
    var vehicleSetupWillPublish: (() async -> Void)?

    // MARK: - Connection Handling

    public func connectionStateChanged(state: ConnectionState) {
        DispatchQueue.main.async {
            let oldState = self.connectionState
            self.connectionState = state
            if state != .connectedToVehicle { self.vehicleLinkRecord.clear() }
            if oldState != state {
                OBDLogger.shared.logConnectionChange(from: oldState, to: state)
            }
        }
    }

    /// Initiates the connection process to the OBD2 adapter and vehicle.
    ///
    /// - Parameter preferedProtocol: The optional OBD2 protocol to use (if supported).
    /// - Returns: Information about the connected vehicle (`OBDInfo`).
    /// - Throws: Errors that might occur during the connection process.
    public func startConnection(preferedProtocol: PROTOCOL? = nil, timeout: TimeInterval = 7, peripheral: CBPeripheral? = nil) async throws -> OBDInfo {
        let compatibilityAttempt = compatibilityAttemptFence.begin()
        let adapter = elm327
        let bleManager = currentBLEManager
        var managerAttempt: UInt64?
        var adapterConnection = OBDAdapterConnectionSnapshot.none
        let startTime = CFAbsoluteTimeGetCurrent()
        var connectionStage = OBDConnectionStage.adapterTransport
        obdInfo("Starting connection with timeout: \(timeout)s", category: .connection)
        await MainActor.run { self.vehicleLinkRecord.clear() }

        do {
            obdDebug("Connecting to adapter...", category: .connection)
            try await elm327.connectToAdapter(timeout: timeout, peripheral: peripheral)
            // The connection this setup runs on: the attempt and the physical peripheral, read
            // together. The link is published only while the transport is still on it.
            adapterConnection = adapter.commManager.adapterConnection
            if let bleManager {
                let activeManagerAttempt = adapterConnection.attempt ?? bleManager.currentCompatibilityAttemptToken
                managerAttempt = activeManagerAttempt
                try ensureCurrentCompatibilityAttempt(
                    compatibilityAttempt,
                    manager: bleManager,
                    managerAttempt: activeManagerAttempt
                )
                await synchronizeCompatibilityReport(
                    from: bleManager,
                    serviceAttempt: compatibilityAttempt,
                    managerAttempt: activeManagerAttempt
                )
            } else {
                try ensureCurrentCompatibilityAttempt(compatibilityAttempt)
            }

            connectionStage = .adapterInitialization
            obdDebug("Initializing adapter...", category: .connection)
            if let bleManager, let managerAttempt {
                bleManager.recordAdapterInitializationStarted(expectedAttempt: managerAttempt)
                await synchronizeCompatibilityReport(
                    from: bleManager,
                    serviceAttempt: compatibilityAttempt,
                    managerAttempt: managerAttempt
                )
            }
            try await elm327.adapterInitialization()
            try ensureCurrentCompatibilityAttempt(
                compatibilityAttempt,
                manager: bleManager,
                managerAttempt: managerAttempt
            )
            if let bleManager, let managerAttempt {
                bleManager.recordAdapterInitialized(expectedAttempt: managerAttempt)
                await synchronizeCompatibilityReport(
                    from: bleManager,
                    serviceAttempt: compatibilityAttempt,
                    managerAttempt: managerAttempt
                )
            }

            connectionStage = .vehicleCommunication
            obdDebug("Initializing vehicle connection...", category: .connection)
            if let bleManager, let managerAttempt {
                bleManager.recordVehicleProbeStarted(expectedAttempt: managerAttempt)
                await synchronizeCompatibilityReport(
                    from: bleManager,
                    serviceAttempt: compatibilityAttempt,
                    managerAttempt: managerAttempt
                )
            }
            let vehicleInfo = try await initializeVehicle(preferedProtocol)
            try ensureCurrentCompatibilityAttempt(
                compatibilityAttempt,
                manager: bleManager,
                managerAttempt: managerAttempt
            )
            if let bleManager, let managerAttempt {
                bleManager.recordVehicleValidated(expectedAttempt: managerAttempt)
                await synchronizeCompatibilityReport(
                    from: bleManager,
                    serviceAttempt: compatibilityAttempt,
                    managerAttempt: managerAttempt
                )
            }

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            OBDLogger.shared.logPerformance("Connection established", duration: duration, success: true)
            // Never the VIN itself: it identifies the owner's car.
            obdInfo("Successfully connected to vehicle (VIN \(vehicleInfo.vin == nil ? "not reported" : "read"))", category: .connection)

            await vehicleSetupWillPublish?()
            // Cache connection metadata (overwrite with fresh data)
            let owner = VehicleSetupOwner(serviceAttempt: compatibilityAttempt, adapter: adapter, connection: adapterConnection)
            let published = await MainActor.run { () -> Bool in
                guard self.publishVehicleSetup(vehicleInfo, owner: owner) else { return false }
                // Only overwrite peripheral name when a peripheral was explicitly provided;
                // a nil peripheral (scan-based connect) should not wipe a previously cached name.
                if let name = peripheral?.name {
                    self.latestConnectedPeripheralName = name
                }
                return true
            }
            guard published else { throw CancellationError() }

            return vehicleInfo
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            OBDLogger.shared.logPerformance("Connection failed", duration: duration, success: false)
            obdError("Connection failed during \(connectionStage.rawValue): \(error.localizedDescription)", category: .connection)
            await recordCompatibilityFailure(
                error,
                connectionStage: connectionStage,
                manager: bleManager,
                managerAttempt: managerAttempt,
                serviceAttempt: compatibilityAttempt
            )
            throw OBDServiceError.connectionFailed(stage: connectionStage, underlyingError: error)
        }
    }

    /// Initializes communication with the vehicle and retrieves vehicle information.
    ///
    /// - Parameter preferedProtocol: The optional OBD2 protocol to use (if supported).
    /// - Returns: Information about the connected vehicle (`OBDInfo`).
    /// - Throws: Errors if the vehicle initialization process fails.
    func initializeVehicle(_ preferedProtocol: PROTOCOL?) async throws -> OBDInfo {
        let obd2info = try await elm327.setupVehicle(preferredProtocol: preferedProtocol)
        return obd2info
    }

    /// What a setup must still own when it publishes: its service attempt, the ELM327 (and so
    /// the transport) it ran on, and the adapter connection it captured.
    private struct VehicleSetupOwner {
        let serviceAttempt: UInt64
        let adapter: ELM327
        let connection: OBDAdapterConnectionSnapshot
    }

    /// Publishes a finished setup's `latestOBDInfo` and link, in one main-actor operation that
    /// first checks the setup still owns the connection: no newer setup began, the transport is
    /// the same, and it is still on the captured attempt and peripheral. A setup that lost
    /// ownership publishes nothing and leaves the newer setup's link alone. Returns whether it
    /// published.
    @MainActor
    private func publishVehicleSetup(_ info: OBDInfo, owner: VehicleSetupOwner) -> Bool {
        guard compatibilityAttemptFence.isCurrent(owner.serviceAttempt),
              elm327 === owner.adapter,
              owner.adapter.commManager.adapterConnection == owner.connection else {
            obdInfo("A superseded connection setup finished; publishing nothing", category: .connection)
            return false
        }
        latestOBDInfo = info
        recordVehicleLink(info, owner: owner)
        return true
    }

    /// Mints the link record for a setup that just succeeded. Main actor only. Skipped when
    /// the link already dropped again (state changes are delivered on the main queue in order,
    /// so a drop that happened first has been seen by now). The adapter is the peripheral the
    /// setup connected to, never the app's saved reconnect target.
    @MainActor
    private func recordVehicleLink(_ info: OBDInfo, owner: VehicleSetupOwner) {
        guard connectionState == .connectedToVehicle else {
            vehicleLinkRecord.clear()
            return
        }
        vehicleLinkRecord.publish(
            OBDVehicleLink(id: UUID(), vin: info.vin, adapterID: owner.connection.peripheralID),
            adapter: owner.adapter,
            connection: owner.connection,
            obdProtocol: info.obdProtocol
        )
    }

    /// Clears cached connection metadata synchronously.
    /// Call from @MainActor contexts only (DiagnosticViewModel, AppViewModel).
    /// NOT called automatically by stopConnection() to preserve metadata during recovery reconnects.
    @MainActor
    public func clearConnectionCache() {
        latestOBDInfo = nil
        latestConnectedPeripheralName = nil
    }

    /// Terminates the connection with the OBD2 adapter.
    public func stopConnection() {
        markCompatibilityDisconnected()
        elm327.stopConnection()
    }

    /// Stop connection and wait for full cleanup
    /// Use this for reliable reconnection
    public func stopConnectionAsync() async {
        markCompatibilityDisconnected()
        elm327.stopConnection()
        elm327.resetState()
        // Small delay to allow Bluetooth stack to process disconnect
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    }

    /// Switches the active connection type (between Bluetooth and Wi-Fi).
    ///
    /// - Parameter connectionType: The new desired connection type.
    private func switchConnectionType(_ connectionType: ConnectionType) {
        stopConnection()
        initializeELM327()
    }

    private func initializeELM327() {
        compatibilityReportCancellable?.cancel()
        compatibilityReportCancellable = nil

        switch connectionType {
        case .bluetooth:
            let bleManager = BLEManager()
            elm327 = ELM327(comm: bleManager)
        case .wifi:
            elm327 = ELM327(comm: WifiManager())
        case .demo:
            elm327 = ELM327(comm: MOCKComm())
        }
        elm327.obdDelegate = self
        bindCompatibilityReporting()
    }

    // MARK: - Scanning, State & Auto-Reconnect (CommProtocol Pass-throughs)

    /// Current Bluetooth state from the underlying CBCentralManager
    public var bluetoothState: CBManagerState {
        elm327.commManager.bluetoothState
    }

    /// Start scanning for BLE peripherals (uses BLEManager's CBCentralManager)
    public func startPeripheralScanning() {
        elm327.commManager.startPeripheralScanning()
    }

    /// Stop scanning for BLE peripherals
    public func stopPeripheralScanning() {
        elm327.commManager.stopPeripheralScanning()
    }

    /// Retrieve a peripheral by UUID from iOS cache (same CBCentralManager that will connect)
    public func retrievePeripheral(uuid: UUID) -> CBPeripheral? {
        elm327.commManager.retrievePeripheral(uuid: uuid)
    }

    /// Publisher for discovered peripherals during scanning
    public var discoveredPeripheralPublisher: AnyPublisher<CBPeripheral, Never> {
        elm327.commManager.discoveredPeripheralPublisher
    }

    /// Advertisement sightings with RSSI and advertised services, for ranking an adapter picker
    public var peripheralDiscoveryPublisher: AnyPublisher<BLEPeripheralDiscovery, Never> {
        elm327.commManager.peripheralDiscoveryPublisher
    }

    /// Enable/disable BLE-level auto-reconnect on unexpected disconnect
    public var autoReconnectEnabled: Bool {
        get { elm327.commManager.autoReconnectEnabled }
        set { elm327.commManager.autoReconnectEnabled = newValue }
    }

    /// Last connected peripheral UUID for auto-reconnect
    public var lastConnectedPeripheralUUID: UUID? {
        get { elm327.commManager.lastConnectedPeripheralUUID }
        set { elm327.commManager.lastConnectedPeripheralUUID = newValue }
    }

    /// Leave an OS-level pending BLE connection to the saved adapter, with no
    /// app-side timeout. iOS completes it whenever the adapter powers on,
    /// relaunching the app via CoreBluetooth state restoration if needed.
    /// Requires `autoReconnectEnabled` and a saved peripheral UUID.
    @discardableResult
    public func armStandingReconnect() -> Bool {
        elm327.commManager.armStandingReconnect()
    }

    // MARK: - Reinitialize Connection (skip BLE connect, run ELM327 init only)

    /// Reinitialize ELM327 after BLE auto-reconnect.
    /// BLE is already connected — only runs adapter init + vehicle setup.
    public func reinitializeConnection(preferedProtocol: PROTOCOL? = nil) async throws -> OBDInfo {
        let compatibilityAttempt = compatibilityAttemptFence.begin()
        let adapter = elm327
        let bleManager = currentBLEManager
        // The connection this reinitialization runs on: the attempt and the physical peripheral,
        // read together.
        let adapterConnection = adapter.commManager.adapterConnection
        let managerAttempt = bleManager.map { adapterConnection.attempt ?? $0.currentCompatibilityAttemptToken }
        var connectionStage = OBDConnectionStage.adapterInitialization
        obdInfo("Reinitializing connection (BLE already connected)...", category: .connection)
        await MainActor.run { self.vehicleLinkRecord.clear() }
        do {
            if let bleManager, let managerAttempt {
                bleManager.recordAdapterInitializationStarted(expectedAttempt: managerAttempt)
                await synchronizeCompatibilityReport(
                    from: bleManager,
                    serviceAttempt: compatibilityAttempt,
                    managerAttempt: managerAttempt
                )
            }
            try await elm327.adapterInitialization()
            try ensureCurrentCompatibilityAttempt(
                compatibilityAttempt,
                manager: bleManager,
                managerAttempt: managerAttempt
            )
            if let bleManager, let managerAttempt {
                bleManager.recordAdapterInitialized(expectedAttempt: managerAttempt)
                bleManager.recordVehicleProbeStarted(expectedAttempt: managerAttempt)
                await synchronizeCompatibilityReport(
                    from: bleManager,
                    serviceAttempt: compatibilityAttempt,
                    managerAttempt: managerAttempt
                )
            }
            connectionStage = .vehicleCommunication
            let vehicleInfo = try await initializeVehicle(preferedProtocol)
            try ensureCurrentCompatibilityAttempt(
                compatibilityAttempt,
                manager: bleManager,
                managerAttempt: managerAttempt
            )
            if let bleManager, let managerAttempt {
                bleManager.recordVehicleValidated(expectedAttempt: managerAttempt)
                await synchronizeCompatibilityReport(
                    from: bleManager,
                    serviceAttempt: compatibilityAttempt,
                    managerAttempt: managerAttempt
                )
            }

            await vehicleSetupWillPublish?()
            // Cache connection metadata (overwrite with fresh data)
            // Peripheral name unchanged on reinit — preserve existing cache
            let owner = VehicleSetupOwner(serviceAttempt: compatibilityAttempt, adapter: adapter, connection: adapterConnection)
            let published = await MainActor.run { self.publishVehicleSetup(vehicleInfo, owner: owner) }
            guard published else { throw CancellationError() }

            return vehicleInfo
        } catch {
            await recordCompatibilityFailure(
                error,
                connectionStage: connectionStage,
                manager: bleManager,
                managerAttempt: managerAttempt,
                serviceAttempt: compatibilityAttempt
            )
            throw error
        }
    }

    // MARK: - Request Handling

    var pidList: [OBDCommand] = []

    /// Sends an OBD2 command to the vehicle and returns a publisher with the result.
    /// - Parameter command: The OBD2 command to send.
    /// - Returns: A publisher with the measurement result.
    /// - Throws: Errors that might occur during the request process.
    public func startContinuousUpdates(_ pids: [OBDCommand], unit: MeasurementUnit = .metric, interval: TimeInterval = 0.3) -> AnyPublisher<[OBDCommand: MeasurementResult], Error> {
        Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .flatMap { [weak self] _ -> Future<[OBDCommand: MeasurementResult], Error> in
                Future { promise in
                    guard let self = self else {
                        promise(.failure(OBDServiceError.notConnectedToVehicle))
                        return
                    }
                    Task(priority: .userInitiated) {
                        do {
                            let results = try await self.requestPIDs(pids, unit: unit)
                            promise(.success(results))
                        } catch {
                            promise(.failure(error))
                        }
                    }
                }
            }
            .eraseToAnyPublisher()
    }

    /// Adds an OBD2 command to the list of commands to be requested.
    public func addPID(_ pid: OBDCommand) {
        pidList.append(pid)
    }

    /// Removes an OBD2 command from the list of commands to be requested.
    public func removePID(_ pid: OBDCommand) {
        pidList.removeAll { $0 == pid }
    }

    /// Sends an OBD2 command to the vehicle and returns the raw response.
    /// - Parameter command: The OBD2 command to send.
    /// - Returns: measurement result
    /// - Throws: Errors that might occur during the request process.
    public func requestPIDs(_ commands: [OBDCommand], unit: MeasurementUnit, retries: Int = 3) async throws -> [OBDCommand: MeasurementResult] {
        let boundedRetries = max(1, retries)
        // Some fuel trims carry an optional second bank. A combined reply has no length
        // for each PID, so that bank's value could look like the next PID. Read those
        // trims singly unless this vehicle's oxygen-sensor layout is known.
        guard commands.count > 1, commands.contains(where: Self.hasOptionalTrimByte) else {
            return try await requestPIDGroup(commands, unit: unit, retries: boundedRetries)
        }

        let fixedWidth = commands.filter { !Self.hasOptionalTrimByte($0) }
        let individualTrims = commands.filter(Self.hasOptionalTrimByte).map { [$0] }
        let groups = (fixedWidth.isEmpty ? [] : [fixedWidth]) + individualTrims
        var readings: [OBDCommand: MeasurementResult] = [:]
        var anyGroupAnswered = false
        var lastNoData: OBDServiceError?
        for group in groups {
            try Task.checkCancellation()
            do {
                let groupReadings = try await requestPIDGroup(group, unit: unit, retries: boundedRetries)
                readings.merge(groupReadings) { _, latest in latest }
                anyGroupAnswered = true
            } catch let failure as OBDServiceError {
                guard case let .commandFailed(_, underlying) = failure else { throw failure }
                switch underlying {
                case BLEManagerError.noData, CommunicationError.noData:
                    lastNoData = failure
                    continue
                default:
                    throw failure
                }
            }
        }
        try Task.checkCancellation()
        // Every group said NO DATA (e.g. ignition off): report it the way a single-group
        // poll does instead of an empty success.
        if !anyGroupAnswered, let lastNoData { throw lastNoData }
        return readings
    }

    private func requestPIDGroup(
        _ commands: [OBDCommand], unit: MeasurementUnit, retries: Int
    ) async throws -> [OBDCommand: MeasurementResult] {
        let response = try await sendCommandInternal(
            "01" + commands.compactMap { $0.properties.command.dropFirst(2) }.joined(),
            retries: retries
        )

        guard let results = try Self.decodePIDResponse(response, commands: commands, parser: elm327.canProtocol, unit: unit) else {
            obdDebug("requestPIDs: parse returned nil (canProtocol=\(elm327.canProtocol != nil ? "set" : "nil"), response=\(elm327.replyLogText(response)))", category: .communication)
            return [:]
        }

        return results
    }

    private static func hasOptionalTrimByte(_ command: OBDCommand) -> Bool {
        switch command {
        case .mode1(.shortFuelTrim1), .mode1(.longFuelTrim1), .mode1(.shortFuelTrim2), .mode1(.longFuelTrim2),
             .mode1(.shortO2TrimB1), .mode1(.longO2TrimB1), .mode1(.shortO2TrimB2), .mode1(.longO2TrimB2):
            return true
        default:
            return false
        }
    }

    /// Decodes the reply to a batched Mode 01 request. Nil when no responder answered `41`.
    ///
    /// Only a positive Mode 01 response is decoded, and inside it only the PIDs it echoes
    /// (``BatchedResponse/decode(_:)``): a late reply to another request that landed in
    /// this slot (`41 0C …` for `010D`, a `7F`, a `49 02 …`) gives no value, never a number.
    static func decodePIDResponse(
        _ response: [String],
        commands: [OBDCommand],
        parser: CANProtocol?,
        unit: MeasurementUnit
    ) throws -> [OBDCommand: MeasurementResult]? {
        guard let responseData = try parser?.parse(response)
            .first(where: { OBDResponseOwnership.isPositiveResponse($0, service: 0x01, pid: nil) })?.data
        else {
            return nil
        }

        return BatchedResponse(response: responseData, unit).decode(commands)
    }

    /// Sends an OBD2 command to the vehicle and returns the raw response.
    ///  - Parameter command: The OBD2 command to send.
    ///  - Returns: The raw response from the vehicle.
    ///  - Throws: Errors that might occur during the request process.
    public func sendCommand(_ command: OBDCommand) async throws -> Result<DecodeResult, DecodeError> {
        do {
            let response = try await sendCommandInternal(command.properties.command, retries: 3)
            return try Self.decodeCommandResponse(response, command: command, parser: elm327.canProtocol)
        } catch {
            throw OBDServiceError.commandFailed(command: command.properties.command, error: error)
        }
    }

    /// Decodes the reply to one `sendCommand(_:)` request: only a message that is the positive
    /// response to the command's service (`41`/`43`/`46`/`49`) and echoes its PID/MID/InfoType
    /// (Modes 01, 06, 09) is decoded. Anything else, including adapter commands, is `.noData`.
    static func decodeCommandResponse(
        _ response: [String],
        command: OBDCommand,
        parser: CANProtocol?
    ) throws -> Result<DecodeResult, DecodeError> {
        let request = command.properties.command
        guard let responseData = try parser?.parse(response)
            .first(where: { OBDResponseOwnership.isPositiveResponse($0, to: request) })?.data
        else {
            return .failure(.noData)
        }
        if OBDResponseOwnership.request(request)?.service == 0x01 {
            // Mode 01: `responseData` is `<PID> <value…>`, trimmed to the length the reply
            // declares, and the decoder drops the PID itself. A reply too short to carry the
            // whole value is no value: it must never decode as a zero (CAN padding used to be
            // read as the measurement).
            let size = command.properties.bytes
            guard size >= 1, responseData.count >= size else { return .failure(.noData) }
            return command.properties.decode(data: responseData.prefix(size))
        }
        return command.properties.decode(data: responseData.dropFirst())
    }

    /// Sends an OBD2 command to the vehicle and returns the raw response.
    ///   - Parameter command: The OBD2 command to send.
    ///   - Returns: The raw response from the vehicle.
    public func getSupportedPIDs() async -> [OBDCommand] {
        await elm327.getSupportedPIDs()
    }

    /// Scans for trouble codes and returns a per-responder report.
    ///
    /// Only a verified positive response ever reads as clean: silence, a negative response,
    /// damage and recoverable transport failures are all distinct outcomes in the report, and
    /// every claim is scoped to the profile that was requested.
    ///
    /// - Parameter profile: Which services to request — `.storedOnly` (03), `.quickConnect`
    ///   (03 + 07) or `.full` (03 + 07 + 0A).
    /// - Returns: The scan report, including the per-responder `0101` status read.
    /// - Throws: Only ``DTCScanError`` — `.cancelled`/`.connectionLost` carrying the evidence
    ///   completed so far. Raw transport errors never escape.
    public func scanForTroubleCodes(profile: DTCScanProfile) async throws -> DTCScanReport {
        try await elm327.scanForTroubleCodes(profile: profile)
    }

    // MARK: - Advisory unsupported-service evidence

    /// The advisory record of modules that answered a DTC service with a terminal
    /// service-not-supported NRC (`0x11`/`0x12`), scoped to vehicle + ECU + protocol.
    ///
    /// **Advisory only** — nothing in the scan path reads it to suppress a request, because a
    /// generic DTC request is a broadcast and one module's refusal says nothing about another's.
    /// Use it to scope wording to its evidence ("ECU 0x7EA previously rejected permanent-code
    /// reads"), never for a vehicle-wide claim.
    public var unsupportedDTCServices: Set<DTCUnsupportedServiceKey> {
        elm327.unsupportedServiceStore.unsupportedKeys
    }

    /// Replaces the advisory unsupported-service store (e.g. with a persistent implementation).
    public func setUnsupportedDTCServiceStore(_ store: DTCUnsupportedServiceStore) {
        elm327.unsupportedServiceStore = store
    }

    /// Demo/simulator only: which DTC scenario the mock transport answers with. Ignored for real
    /// transports, so demo mode can exercise the clean and pending-only paths that the old
    /// always-two-codes mock hid.
    @discardableResult
    public func setMockDTCScenario(_ scenario: MockDTCScenario) -> Bool {
        guard let mock = elm327.commManager as? MOCKComm else { return false }
        mock.ecuSettings.dtcScenario = scenario
        return true
    }

    /// Clears the trouble codes found on the vehicle, on whatever link is up when the command
    /// reaches the transport. Production clears use the bound form, `clearTroubleCodes(on:)`.
    ///  - Throws: Errors that might occur during the request process.
    ///     - `OBDServiceError.clearFailed` when the vehicle refused the request or no `44`
    ///       positive response could be verified — a failed clear no longer looks successful.
    public func clearTroubleCodes() async throws {
        do {
            try await elm327.clearTroubleCodes()
        } catch {
            throw OBDServiceError.clearFailed(underlyingError: error)
        }
    }

    /// Mode 04 on exactly this link. Throws `OBDVehicleLinkError.linkChanged` when `link` is no
    /// longer the service's current vehicle link; nothing is sent.
    ///
    /// The link is checked with the transport's command mutex held when the attempt starts and
    /// again once the stream is proven ("current" there means: `vehicleLink` is this link, and
    /// the transport is still on the adapter connection the link was published on). What makes
    /// it safe is the third check: the hand-off of `04`'s first bytes to the system runs inside
    /// the link record's lock, after checking under that lock that `link` is still the
    /// published one. Every revocation takes the same lock, so a write that was queued (behind
    /// Bluetooth flow control, behind a socket) never goes out on a revoked link. See
    /// `OBDVehicleLinkRecord.authorization(for:adapter:)`. Other failures map as in
    /// `clearTroubleCodes()`, to `OBDServiceError.clearFailed`.
    public func clearTroubleCodes(on link: OBDVehicleLink) async throws {
        let adapter = elm327
        do {
            try await adapter.clearTroubleCodes(
                authorization: vehicleLinkRecord.authorization(for: link, adapter: adapter)
            )
        } catch let error as OBDVehicleLinkError {
            throw error
        } catch {
            throw OBDServiceError.clearFailed(underlyingError: error)
        }
    }

    /// Returns the vehicle's status.
    ///  - Returns: The vehicle's status.
    ///  - Throws: Errors that might occur during the request process.
    public func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        do {
            return try await elm327.getStatus()
        } catch {
            throw error
        }
    }

    //    public func switchToDemoMode(_ isDemoMode: Bool) {
    //        elm327.switchToDemoMode(isDemoMode)
    //    }

    /// Sends a raw command to the vehicle and returns the raw response.
    /// - Parameter message: The raw command to send.
    /// - Returns: The raw response from the vehicle.
    /// - Throws: Errors that might occur during the request process.
    private var adapterIdentityCache = AdapterIdentityCache()

    /// What the connected adapter says it is (`ATI`, `AT@1`, `STI`). Call only while no other
    /// command is in flight, after vehicle setup. Stops at the first silent command, which
    /// never marks the connection failed; nil when nothing answered. Cached per BLE
    /// peripheral for the app session (see `AdapterIdentityCache`).
    @MainActor
    public func adapterIdentity() async -> AdapterIdentity? {
        let peripheralID = lastConnectedPeripheralUUID
        if let cached = adapterIdentityCache.lookup(peripheralID) {
            return cached
        }
        let probe = await elm327.probeAdapterIdentity()
        adapterIdentityCache.store(probe, for: peripheralID, currentPeripheral: lastConnectedPeripheralUUID)
        return probe.identity
    }

    public func sendCommandInternal(_ message: String, retries: Int) async throws -> [String] {
        do {
            return try await elm327.sendCommand(message, retries: retries)
        } catch {
            throw OBDServiceError.commandFailed(command: message, error: error)
        }
    }

    /// A raw command with a longer wait for the adapter's answer, for slow module exchanges.
    /// Bluetooth honors `responseTimeout`; other transports use their own read window.
    public func sendCommandInternal(_ message: String, retries: Int, responseTimeout: TimeInterval) async throws -> [String] {
        do {
            return try await elm327.sendCommand(message, retries: retries, responseTimeout: responseTimeout)
        } catch {
            throw OBDServiceError.commandFailed(command: message, error: error)
        }
    }

    /// A raw command sent once, as one exclusive transaction: while `continueListeningWhile`
    /// says the lines so far still owe a final answer (a module answered "response pending",
    /// `7F … 78`, and the adapter returned to its prompt), the transport keeps listening without
    /// writing again, holding its command mutex, for at most `listenDeadline` seconds in total.
    ///
    /// Returns every line received. If the exchange ends while `continueListeningWhile` still
    /// says an answer is owed (the budget ran out, the adapter said `NO DATA`, the caller was
    /// cancelled), the transport marks its stream as needing resynchronization before the next
    /// write, so the late answer can never be taken for the next command's.
    ///
    /// - Parameter responseTimeout: The wait for the first answer; nil uses the transport's
    ///   default. Bluetooth honors it; other transports use their own read window.
    public func sendCommandInternal(
        _ message: String,
        retries: Int,
        responseTimeout: TimeInterval?,
        continueListeningWhile: @escaping @Sendable ([String]) -> Bool,
        listenDeadline: TimeInterval
    ) async throws -> [String] {
        do {
            return try await elm327.sendCommandTransaction(
                message,
                retries: retries,
                responseTimeout: responseTimeout,
                shouldContinueListening: continueListeningWhile,
                listenDeadline: listenDeadline
            )
        } catch {
            throw OBDServiceError.commandFailed(command: message, error: error)
        }
    }

    /// Whether the adapter's stream can no longer be proven in sync on this connection: an
    /// earlier command's answer may still arrive, and every probe that could rule that out has
    /// gone unanswered itself. Commands fail without being sent until the adapter is
    /// reconnected (the reconnect resets it). Waiting does not clear this.
    public var isAdapterReconnectRequired: Bool {
        elm327.commManager.requiresReconnect
    }

    public func connectToPeripheral(peripheral: CBPeripheral) async throws {
        let compatibilityAttempt = compatibilityAttemptFence.begin()
        let bleManager = currentBLEManager
        do {
            try await elm327.connectToAdapter(timeout: 5, peripheral: peripheral)
            if let bleManager {
                let managerAttempt = bleManager.currentCompatibilityAttemptToken
                try ensureCurrentCompatibilityAttempt(
                    compatibilityAttempt,
                    manager: bleManager,
                    managerAttempt: managerAttempt
                )
                await synchronizeCompatibilityReport(
                    from: bleManager,
                    serviceAttempt: compatibilityAttempt,
                    managerAttempt: managerAttempt
                )
            } else {
                try ensureCurrentCompatibilityAttempt(compatibilityAttempt)
            }
        } catch {
            if let bleManager {
                await synchronizeTerminalCompatibilityFailure(
                    from: bleManager,
                    serviceAttempt: compatibilityAttempt
                )
            }
            throw OBDServiceError.adapterConnectionFailed(underlyingError: error)
        }
    }

    public func scanForPeripherals() async throws {
        do {
            self.isScanning = true
            try await elm327.scanForPeripherals()
            self.isScanning = false
        } catch {
            throw OBDServiceError.scanFailed(underlyingError: error)
        }
    }

//    public func test() {
//        if let resourcePath = Bundle.module.resourcePath {
//               print("Bundle resources path: \(resourcePath)")
//               let files = try? FileManager.default.contentsOfDirectory(atPath: resourcePath)
//               print("Files in bundle: \(files ?? [])")
//           }
//        // Get the path for the JSON file within the app's bundle
//        guard let path = Bundle.module.path(forResource: "commands", ofType: "json") else {
//            print("Error: commands.json file not found in the bundle.")
//            return
//        }
//
//        // Load the file data
//        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
//            print("Error: Unable to load data from commands.json.")
//            return
//        }
//
//        do {
//                // Load the JSON
//                let data = try Data(contentsOf: URL(fileURLWithPath: path))
//
//                // Decode the JSON into an array of dictionaries to handle flexible structures
//                guard var rawCommands = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
//                    print("Error: Invalid JSON format.")
//                    return
//                }
//
//                // Edit the `decoder` field
//                rawCommands = rawCommands.map { command in
//                    var updatedCommand = command
//                    if let decoder = command["decoder"] as? [String: Any], let firstKey = decoder.keys.first {
//                        updatedCommand["decoder"] = firstKey // Set the first key as the string value
//                    } else {
//                        updatedCommand["decoder"] = "none" // Default to "none" if no keys exist
//                    }
//                    return updatedCommand
//                }
//
//                // Convert back to JSON data
//                let updatedData = try JSONSerialization.data(withJSONObject: rawCommands, options: .prettyPrinted)
//
//                // Save the updated JSON to a file
//                let outputPath = FileManager.default.temporaryDirectory.appendingPathComponent("commands_updated.json")
//                try updatedData.write(to: outputPath)
//
//                print("Modified commands.json saved to: \(outputPath.path)")
//            } catch {
//                print("Error processing commands.json: \(error)")
//            }
//    }

    private var currentBLEManager: BLEManager? {
        elm327.commManager as? BLEManager
    }

    /// The link, protocol and transport captured together for a manufacturer batch.
    var manufacturerDataConnection: (link: OBDVehicleLink, obdProtocol: PROTOCOL?, transport: CommProtocol)? {
        let adapter = elm327
        guard let entry = vehicleLinkRecord.currentEntry(adapter: adapter) else { return nil }
        return (entry.link, entry.obdProtocol, adapter.commManager)
    }

    private func bindCompatibilityReporting() {
        compatibilityReportCancellable?.cancel()
        compatibilityReportCancellable = nil

        guard let manager = currentBLEManager else {
            if Thread.isMainThread {
                adapterCompatibilityReport = nil
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentBLEManager == nil else { return }
                    self.adapterCompatibilityReport = nil
                }
            }
            return
        }

        compatibilityReportCancellable = manager.compatibilityReportPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak manager] _ in
                guard let self,
                      let manager,
                      self.currentBLEManager === manager else { return }
                // Fetch the manager's current value on the delivery queue instead
                // of assigning the queued value. A delayed notification from an
                // earlier attempt therefore cannot replace a newer report.
                self.adapterCompatibilityReport = manager.currentCompatibilityReport
            }
    }

    private func synchronizeCompatibilityReport(
        from manager: BLEManager,
        serviceAttempt: UInt64,
        managerAttempt: UInt64
    ) async {
        await MainActor.run {
            guard self.compatibilityAttemptFence.isCurrent(serviceAttempt),
                  self.currentBLEManager === manager,
                  manager.currentCompatibilityAttemptToken == managerAttempt else { return }
            self.adapterCompatibilityReport = manager.currentCompatibilityReport
        }
    }

    private func synchronizeTerminalCompatibilityFailure(
        from manager: BLEManager,
        serviceAttempt: UInt64
    ) async {
        await MainActor.run {
            guard self.compatibilityAttemptFence.isCurrent(serviceAttempt),
                  self.currentBLEManager === manager,
                  let report = manager.currentCompatibilityReport,
                  report.failure != nil else { return }
            self.adapterCompatibilityReport = report
        }
    }

    private func ensureCurrentCompatibilityAttempt(
        _ serviceAttempt: UInt64,
        manager: BLEManager? = nil,
        managerAttempt: UInt64? = nil
    ) throws {
        guard compatibilityAttemptFence.isCurrent(serviceAttempt) else {
            throw CancellationError()
        }
        if let manager {
            guard currentBLEManager === manager,
                  let managerAttempt,
                  manager.currentCompatibilityAttemptToken == managerAttempt else {
                throw CancellationError()
            }
        }
        try Task.checkCancellation()
    }

    private func recordCompatibilityFailure(
        _ error: Error,
        connectionStage: OBDConnectionStage,
        manager: BLEManager?,
        managerAttempt: UInt64?,
        serviceAttempt: UInt64
    ) async {
        guard let manager,
              currentBLEManager === manager,
              compatibilityAttemptFence.isCurrent(serviceAttempt) else { return }

        guard let activeManagerAttempt = managerAttempt else {
            // A transport failure can occur before startConnection captures
            // the attempt token created inside BLEManager.connectAsync. Never
            // guess with the manager's current token: a restored/background
            // reconnect may already own it. BLEManager publishes its own
            // discovery/GATT/subscription failure before throwing, so copy
            // only an already-terminal report in this case.
            await synchronizeTerminalCompatibilityFailure(
                from: manager,
                serviceAttempt: serviceAttempt
            )
            return
        }
        guard manager.currentCompatibilityAttemptToken == activeManagerAttempt else { return }

        let currentReport = manager.currentCompatibilityReport
        if currentReport?.failure != nil {
            // The manager may already know this was an unsupported GATT
            // layout, subscription failure, write failure, or disconnect.
            // Preserve that transport evidence instead of relabeling it as
            // an adapter-setup or vehicle-ECU failure.
        } else if error is CancellationError {
            manager.recordFailure(
                .cancelled,
                stage: .failed,
                subscription: currentReport?.subscription ?? .notRequested,
                expectedAttempt: activeManagerAttempt
            )
        } else {
            switch connectionStage {
            case .adapterTransport:
                manager.recordFailure(
                    .transportUnavailable,
                    stage: .failed,
                    subscription: currentReport?.subscription ?? .notRequested,
                    expectedAttempt: activeManagerAttempt
                )
            case .adapterInitialization:
                if currentReport?.subscription == .confirmed {
                    manager.recordFailure(
                        .adapterConfigurationRejected,
                        stage: .failed,
                        subscription: .confirmed,
                        expectedAttempt: activeManagerAttempt
                    )
                } else {
                    manager.recordFailure(
                        .transportUnavailable,
                        stage: .failed,
                        subscription: currentReport?.subscription ?? .notRequested,
                        expectedAttempt: activeManagerAttempt
                    )
                }
            case .vehicleCommunication:
                if currentReport?.subscription == .confirmed {
                    manager.recordVehicleUnavailable(expectedAttempt: activeManagerAttempt)
                } else {
                    manager.recordFailure(
                        .transportUnavailable,
                        stage: .failed,
                        subscription: currentReport?.subscription ?? .notRequested,
                        expectedAttempt: activeManagerAttempt
                    )
                }
            }
        }

        await synchronizeCompatibilityReport(
            from: manager,
            serviceAttempt: serviceAttempt,
            managerAttempt: activeManagerAttempt
        )
    }

    private func markCompatibilityDisconnected() {
        // Revoke under the first-write gate before the transport starts disconnecting.
        vehicleLinkRecord.clear()
        let serviceAttempt = compatibilityAttemptFence.begin()
        // Again after the fence: a setup that published between the two lines is revoked too.
        vehicleLinkRecord.clear()
        guard let manager = currentBLEManager else { return }
        manager.recordDisconnected(expectDisconnectCallback: true)
        let managerAttempt = manager.currentCompatibilityAttemptToken
        DispatchQueue.main.async { [weak self, weak manager] in
            guard let self,
                  let manager,
                  self.compatibilityAttemptFence.isCurrent(serviceAttempt),
                  self.currentBLEManager === manager,
                  manager.currentCompatibilityAttemptToken == managerAttempt else { return }
            self.adapterCompatibilityReport = manager.currentCompatibilityReport
        }
    }

}

public enum OBDConnectionStage: String, Sendable {
    case adapterTransport = "adapter transport"
    case adapterInitialization = "adapter initialization"
    case vehicleCommunication = "vehicle communication"
}

public enum OBDServiceError: Error, LocalizedError {
    case noAdapterFound
    case notConnectedToVehicle
    case connectionFailed(stage: OBDConnectionStage, underlyingError: Error)
    case adapterConnectionFailed(underlyingError: Error)
    case scanFailed(underlyingError: Error)
    case clearFailed(underlyingError: Error)
    case commandFailed(command: String, error: Error)

    public var errorDescription: String? {
        switch self {
        case .noAdapterFound:
            return "No OBD adapter found."
        case .notConnectedToVehicle:
            return "Not connected to vehicle."
        case let .connectionFailed(stage, underlyingError):
            return "Connection failed during \(stage.rawValue): \(underlyingError.localizedDescription)"
        case .adapterConnectionFailed(let underlyingError):
            return "Adapter connection failed: \(underlyingError.localizedDescription)"
        case .scanFailed(let underlyingError):
            return "Scan failed: \(underlyingError.localizedDescription)"
        case .clearFailed(let underlyingError):
            return "Clear trouble codes failed: \(underlyingError.localizedDescription)"
        case .commandFailed(let command, let error):
            return "Command \(command) failed: \(error.localizedDescription)"
        }
    }
}

public struct MeasurementResult: Equatable {
    public var value: Double
    public let unit: Unit
	
	public init(value: Double, unit: Unit) {
		self.value = value
		self.unit = unit
	}
}

public extension MeasurementResult {
	static func mock(_ value: Double = 125, _ suffix: String = "km/h") -> MeasurementResult {
		.init(value: value, unit: .init(symbol: suffix))
	}
}

public func getVINInfo(vin: String) async throws -> VINResults {
    let endpoint = "https://vpic.nhtsa.dot.gov/api/vehicles/decodevinvalues/\(vin)?format=json"

    guard let url = URL(string: endpoint) else {
        throw URLError(.badURL)
    }

    let (data, response) = try await URLSession.shared.data(from: url)

    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(VINResults.self, from: data)
    return decoded
}

public struct VINResults: Codable {
    public let Results: [VINInfo]
}

public struct VINInfo: Codable, Hashable {
    public let Make: String
    public let Model: String
    public let ModelYear: String
    public let EngineCylinders: String
}

extension OBDServiceError {
    /// The transport rejected the response prompt because its frames could not be attributed.
    public var isAmbiguousResponse: Bool {
        guard case let .commandFailed(_, error) = self else { return false }
        return (error as? OBDStreamError) == .ambiguousResponse
    }

    /// A raw command whose answer didn't arrive before the response timeout. The adapter may
    /// still be receiving it, so a caller should let it finish before the next command.
    public var isResponseTimeout: Bool {
        guard case let .commandFailed(_, error) = self else { return false }
        // Not sent at all, and no late answer of its own to wait for.
        if isReconnectRequired { return false }
        if case CommunicationError.timeout = error { return true }
        return BLEManager.commandCompatibilityFailure(for: error) == .adapterResponseTimedOut
    }

    /// A raw command that wasn't sent because the adapter's stream can't be proven in sync on
    /// this connection any more (see `OBDService.isAdapterReconnectRequired`). Not a timeout:
    /// retrying won't help, reconnecting will.
    public var isReconnectRequired: Bool {
        switch self {
        case let .commandFailed(_, error), let .clearFailed(error):
            return (error as? OBDStreamError) == .reconnectRequired
        default:
            return false
        }
    }
}

/// Thrown, with nothing sent, when a request bound to one vehicle link finds another link (or none) current.
public enum OBDVehicleLinkError: Error, Equatable { case linkChanged }

/// The adapter connection a transport is on right now.
///
/// `epoch` is the identity: a counter the transport owns, guards with the same lock as the
/// connection it describes, and advances every time that connection is established **or** torn
/// down. Two snapshots with the same epoch describe the same physical connection, and a
/// connection that went away can never compare equal to anything read afterwards. Bluetooth
/// reads it together with the peripheral (`BLEPeripheralManager.connectionIdentity`); WiFi
/// advances it with its socket. Nil for transports with nothing to lose (the demo transport).
///
/// `attempt` (Bluetooth's connection attempt) rides along for the compatibility report and makes
/// equality stricter; it lives under another lock and is not what makes the snapshot sound.
struct OBDAdapterConnectionSnapshot: Equatable, Sendable {
    var attempt: UInt64?
    var peripheralID: UUID?
    var epoch: UInt64?

    init(attempt: UInt64?, peripheralID: UUID?, epoch: UInt64? = nil) {
        self.attempt = attempt
        self.peripheralID = peripheralID
        self.epoch = epoch
    }

    static let none = OBDAdapterConnectionSnapshot(attempt: nil, peripheralID: nil)
}

/// `OBDService.vehicleLink` with the ELM327 and adapter connection it was published on. Lock
/// protected: written on the main actor, checked by a transport with its command mutex held.
///
/// Two rules keep it sound:
///
/// - **Reading never changes it.** The entry is read first, then the transport's connection,
///   and the two are compared. Nothing is cleared from a read, so a link published between the
///   two reads can't be erased by a comparison with the connection it replaced. An expired
///   entry simply keeps reading as "no link" until the next publish or clear.
/// - **The lock is a leaf**, except for `whileCurrent`. It is never held while reading the
///   transport's connection: a Bluetooth teardown holds the transport's locks while it waits
///   for the write queue, and the write queue takes this lock to hand over a bound command.
final class OBDVehicleLinkRecord: @unchecked Sendable {
    struct Entry {
        let link: OBDVehicleLink
        let adapter: ObjectIdentifier
        let connection: OBDAdapterConnectionSnapshot
        let obdProtocol: PROTOCOL?
    }

    private let lock = NSLock()
    private var entry: Entry?

    /// The published link, or nil once `adapter`'s transport is no longer on the connection it
    /// was published on. Never changes the record.
    func currentLink(adapter: ELM327) -> OBDVehicleLink? {
        currentEntry(adapter: adapter)?.link
    }

    func currentEntry(adapter: ELM327) -> Entry? {
        // The entry first: whatever connection is read after it is at least as new, so a
        // mismatch means the entry expired, never that a newer entry is being judged by an
        // older connection.
        guard let current = lock.withLock({ entry }) else { return nil }
        guard current.adapter == ObjectIdentifier(adapter),
              current.connection == adapter.commManager.adapterConnection else { return nil }
        return current
    }

    func publish(_ link: OBDVehicleLink, adapter: ELM327, connection: OBDAdapterConnectionSnapshot,
                 obdProtocol: PROTOCOL? = nil) {
        lock.withLock {
            entry = Entry(link: link, adapter: ObjectIdentifier(adapter), connection: connection, obdProtocol: obdProtocol)
        }
    }

    func clear() {
        lock.withLock { entry = nil }
    }

    /// Whether `link` is the current link and `adapter`'s transport is still on the connection
    /// it was published on. A snapshot: the entry is read first, then the connection (see the
    /// type's comment). It can be stale the moment it returns; `whileCurrent` is what a write
    /// relies on.
    func isCurrent(_ link: OBDVehicleLink, adapter: ELM327) -> Bool {
        guard let current = lock.withLock({ entry }) else { return false }
        return current.link == link
            && current.adapter == ObjectIdentifier(adapter)
            && current.connection == adapter.commManager.adapterConnection
    }

    /// Runs `submit` while holding the record's lock, only if `link` is still the published
    /// link for `adapter`. `publish` and `clear` take the same lock, so each of them either
    /// comes first (and `submit` never runs: `linkChanged`) or returns only after `submit` did.
    ///
    /// `submit` must be short and must not wait or read the transport's connection: it is the
    /// hand-off of a command's first bytes to the system. The transport's own connection is
    /// serialized with that hand-off by the transport (the Bluetooth write session, the WiFi
    /// socket lock), not here.
    func whileCurrent(_ link: OBDVehicleLink, adapter: ELM327, _ submit: () throws -> Void) throws {
        try lock.withLock {
            guard let entry, entry.link == link, entry.adapter == ObjectIdentifier(adapter) else {
                throw OBDVehicleLinkError.linkChanged
            }
            try submit()
        }
    }

    /// The authorization a transport is handed for a request bound to `link`.
    func authorization(for link: OBDVehicleLink, adapter: ELM327) -> OBDWriteAuthorization {
        OBDWriteAuthorization(
            check: { [self] in
                guard isCurrent(link, adapter: adapter) else { throw OBDVehicleLinkError.linkChanged }
            },
            whileAuthorized: { [self] submit in
                try whileCurrent(link, adapter: adapter, submit)
            }
        )
    }
}

/// One vehicle link and what was learned while setting it up. See `OBDService.vehicleLink`.
public struct OBDVehicleLink: Equatable, Sendable {
    /// Minted by the setup that brought this link up. Two links never share one.
    public let id: UUID
    /// The VIN read during this link's setup, nil when the car didn't report one.
    public let vin: String?
    /// The Bluetooth peripheral this link runs on, nil for other transports.
    public let adapterID: UUID?

    public init(id: UUID, vin: String?, adapterID: UUID?) {
        self.id = id
        self.vin = vin
        self.adapterID = adapterID
    }
}
