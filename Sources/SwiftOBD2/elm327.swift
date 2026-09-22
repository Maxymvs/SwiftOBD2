// MARK: - ELM327 Class Documentation

/// `Author`: Kemo Konteh
/// The `ELM327` class provides a comprehensive interface for interacting with an ELM327-compatible
/// OBD-II adapter. It handles adapter setup, vehicle connection, protocol detection, and
/// communication with the vehicle's ECU.
///
/// **Key Responsibilities:**
/// * Manages communication with a BLE OBD-II adapter
/// * Automatically detects and establishes the appropriate OBD-II protocol
/// * Sends commands to the vehicle's ECU
/// * Parses and decodes responses from the ECU
/// * Retrieves vehicle information (e.g., VIN)
/// * Monitors vehicle status and retrieves diagnostic trouble codes (DTCs)

import Combine
import CoreBluetooth
import Foundation
import OSLog

enum ELM327Error: Error, LocalizedError {
    case noProtocolFound
    case invalidResponse(message: String)
    case adapterInitializationFailed
    case ignitionOff
    case invalidProtocol
    case timeout
    case connectionFailed(reason: String)
    case unknownError

    var errorDescription: String? {
        switch self {
        case .noProtocolFound:
            return "No compatible OBD protocol found."
        case let .invalidResponse(message):
            return "Invalid response received: \(message)"
        case .adapterInitializationFailed:
            return "Failed to initialize adapter."
        case .ignitionOff:
            return "Vehicle ignition is off."
        case .invalidProtocol:
            return "Invalid or unsupported OBD protocol."
        case .timeout:
            return "Operation timed out."
        case let .connectionFailed(reason):
            return "Connection failed: \(reason)"
        case .unknownError:
            return "An unknown error occurred."
        }
    }
}

class ELM327 {
    //    private var obdProtocol: PROTOCOL = .NONE
    var canProtocol: CANProtocol?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.com", category: "ELM327")
    private var comm: CommProtocol

    private var cancellables = Set<AnyCancellable>()

    weak var obdDelegate: OBDServiceDelegate? {
        didSet {
            comm.obdDelegate = obdDelegate
        }
    }

    /// Internal accessor for the communication manager (used by OBDService pass-throughs)
    var commManager: CommProtocol {
        get { comm }
        set { comm = newValue }
    }

    private var r100: [String] = []

    /// The vehicle the current session is talking to (its VIN when the adapter gave us one).
    var vehicleIdentifier: String?

    /// Identity of the current connection, regenerated on every reset.
    ///
    /// Stands in for the VIN when the adapter never gave us one, so advisory evidence gathered
    /// from a VIN-less vehicle can never be attributed to the *next* VIN-less vehicle.
    private var connectionSessionID = UUID()

    /// The scope advisory unsupported-service evidence is keyed by: the VIN when known — shared
    /// across reconnects to the same car — otherwise this connection's session id.
    var dtcEvidenceScope: String {
        if let vin = vehicleIdentifier, !vin.isEmpty {
            return DTCUnsupportedServiceKey.vin(vin)
        }
        return DTCUnsupportedServiceKey.session(connectionSessionID)
    }

    /// Advisory record of terminal service-not-supported refusals (D10). Injectable; never
    /// consulted to suppress a request.
    var unsupportedServiceStore: DTCUnsupportedServiceStore = InMemoryDTCUnsupportedServiceStore()

    var connectionState: ConnectionState = .disconnected {
        didSet {
            obdDelegate?.connectionStateChanged(state: connectionState)
        }
    }

    init(comm: CommProtocol) {
        self.comm = comm
        setupConnectionStateSubscriber()
    }

    private func setupConnectionStateSubscriber() {
        comm.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.obdDelegate?.connectionStateChanged(state: state)
                self?.logger.debug("Connection state updated: \(state.description)")
            }
            .store(in: &cancellables)
    }

    // MARK: - Adapter and Vehicle Setup

    /// Sets up the vehicle connection, including automatic protocol detection.
    /// - Parameter preferedProtocol: An optional preferred protocol to attempt first.
    /// - Returns: A tuple containing the established OBD protocol and the vehicle's VIN (if available).
    /// - Throws:
    ///     - `SetupError.noECUCharacteristic` if the required OBD characteristic is not found.
    ///     - `SetupError.invalidResponse(message: String)` if the adapter's response is unexpected.
    ///     - `SetupError.noProtocolFound` if no compatible protocol can be established.
    ///     - `SetupError.adapterInitFailed` if initialization of adapter failed.
    ///     - `SetupError.timeout` if a response times out.
    ///     - `SetupError.peripheralNotFound` if the peripheral could not be found.
    ///     - `SetupError.ignitionOff` if the vehicle's ignition is not on.
    ///     - `SetupError.invalidProtocol` if the protocol is not recognized.
    func setupVehicle(preferredProtocol: PROTOCOL?) async throws -> OBDInfo {
        let detectedProtocol = try await detectProtocol(preferredProtocol: preferredProtocol)
        canProtocol = try detectedProtocol.parserImplementation()
        // Validate before optional metadata requests, using the same reply that
        // established the protocol. No second 0100 can mask a failed first probe.
        let messages = try validatedSupportedPIDMessages(r100, protocol: detectedProtocol)
        let vin = try await requestVin()
        vehicleIdentifier = vin
        let supportedPIDs = try await getSupportedPIDs(duringSetup: true)
        try Task.checkCancellation()
        connectionState = .connectedToVehicle
        return OBDInfo(vin: vin, supportedPIDs: supportedPIDs, obdProtocol: detectedProtocol,
                       ecuMap: populateECUMap(messages))
    }

    // MARK: - Protocol Selection

    /// One request establishes ECU evidence and lets the adapter search. A verified
    /// reconnect hint is tried first with automatic fallback (ATTP A<n>); unlike
    /// ATSP it does not immediately overwrite the adapter's stored preference.
    func detectProtocol(preferredProtocol: PROTOCOL? = nil) async throws -> PROTOCOL {
        r100 = []
        canProtocol = nil
        try Task.checkCancellation()
        if let preferredProtocol, Self.genericProtocols.contains(preferredProtocol) {
            let selection = try await setupCommand("ATTPA" + preferredProtocol.rawValue)
            if selection != ["OK"] {
                // Only a completed, explicit unsupported-command reply allows a
                // fallback write. Timeout/cancellation/link loss must escape.
                guard selection == ["?"] else { throw ELM327Error.noProtocolFound }
                _ = try await setupOK("ATSP0")
            }
        } else {
            _ = try await setupOK("ATSP0")
        }

        let response = try await setupCommand("0100", timeout: OBDConnectionTiming.protocolSearch)
        guard BLEELMResponseValidator.hasVehicleResponse(response) else { throw ELM327Error.noProtocolFound }
        let description = try await setupCommand("ATDPN")
        let detected = try Self.parseProtocolNumber(description)
        _ = try validatedSupportedPIDMessages(response, protocol: detected)
        r100 = response
        return detected
    }

    private static let genericProtocols: Set<PROTOCOL> = [
        .protocol1, .protocol2, .protocol3, .protocol4, .protocol5,
        .protocol6, .protocol7, .protocol8, .protocol9,
    ]

    static func parseProtocolNumber(_ response: [String]) throws -> PROTOCOL {
        let lines = response.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && $0 != "ATDPN" }
        guard lines.count == 1, let line = lines.first else { throw ELM327Error.invalidProtocol }
        let number = line.hasPrefix("A") ? String(line.dropFirst()) : line
        guard let result = PROTOCOL(rawValue: number), genericProtocols.contains(result) else {
            throw ELM327Error.invalidProtocol
        }
        return result
    }

    private func validatedSupportedPIDMessages(_ response: [String], protocol detected: PROTOCOL) throws -> [MessageProtocol] {
        // Check the service as well as the parsed PID and complete 32-bit bitmap.
        // Parsers strip the service byte, so checking parsed data alone is insufficient.
        guard BLEELMResponseValidator.hasVehicleResponse(response) else {
            throw ELM327Error.noProtocolFound
        }
        let messages = try detected.parserImplementation().parse(response)
        guard messages.contains(where: { message in
            guard let data = message.data else { return false }
            return data.count >= 5 && data.first == 0x00
        }) else { throw ELM327Error.noProtocolFound }
        return messages
    }

    private func setupCommand(_ command: String, timeout: TimeInterval = OBDConnectionTiming.commandResponse) async throws -> [String] {
        try Task.checkCancellation()
        let response = try await comm.sendSetupCommand(command, responseTimeout: timeout)
        try Task.checkCancellation()
        return response
    }

    private func setupOK(_ command: String) async throws -> [String] {
        let response = try await setupCommand(command)
        let lines = response.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && $0 != command }
        guard lines == ["OK"] else { throw ELM327Error.adapterInitializationFailed }
        return response
    }

    // MARK: - Adapter Initialization

    func connectToAdapter(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        try await comm.connectAsync(timeout: timeout, peripheral: peripheral)
    }

    /// Initializes the adapter by sending a series of commands.
    /// - Parameter setupOrder: A list of commands to send in order.
    /// - Throws: Various setup-related errors.
    func adapterInitialization() async throws {
        //        [.ATZ, .ATD, .ATL0, .ATE0, .ATH1, .ATAT1, .ATRV, .ATDPN]
        logger.info("Initializing ELM327 adapter...")
        // Clear stale protocol/response state from previous connection
        resetState()
        do {
            _ = try await setupCommand("ATZ") // Reset adapter
            // ELM327 needs time to complete reset (adapter reboots)
            try await Task.sleep(for: .seconds(OBDConnectionTiming.adapterResetDelay))
            _ = try await setupOK("ATE0") // Echo off
            _ = try await setupOK("ATL0") // Linefeeds off
            _ = try await setupOK("ATS0") // Spaces off
            _ = try await setupOK("ATH1") // Headers on
            // Protocol selection belongs to detectProtocol, including reconnect hints.
            logger.info("ELM327 adapter initialized successfully.")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Adapter initialization failed: \(error.localizedDescription)")
            throw ELM327Error.adapterInitializationFailed
        }
    }

    private func setHeader(header: String) async throws {
        _ = try await okResponse("AT SH " + header)
    }

    func stopConnection() {
        comm.disconnectPeripheral()
        connectionState = .disconnected
    }

    /// Reset all cached protocol and response state
    func resetState() {
        canProtocol = nil
        r100 = []
        vehicleIdentifier = nil
        // A new connection is a new vehicle until proven otherwise: never let the previous
        // (possibly VIN-less) car's advisory evidence apply to this one.
        connectionSessionID = UUID()
    }

    // MARK: - Message Sending

    func sendCommand(_ message: String, retries: Int = 1) async throws -> [String] {
        try await comm.sendCommand(message, retries: retries)
    }

    private func okResponse(_ message: String) async throws -> [String] {
        let response = try await sendCommand(message)
        if response.contains("OK") {
            return response
        } else {
            logger.error("Invalid response: \(response)")
            throw ELM327Error.invalidResponse(message: "message: \(message), \(String(describing: response.first))")
        }
    }

    func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        logger.info("Getting status")
        let statusCommand = OBDCommand.Mode1.status
        let statusResponse = try await sendCommand(statusCommand.properties.command)
        logger.debug("Status response: \(statusResponse)")
        guard let statusData = try canProtocol?.parse(statusResponse).first?.data else {
            return .failure(.noData)
        }
        return statusCommand.properties.decode(data: statusData)
    }

    /// Clears stored trouble codes and freeze-frame data, **verifying** the `44` positive
    /// response.
    ///
    /// The response used to be discarded (`_ = try await sendCommand`), so an ECU that refused
    /// the request — or an adapter that answered nothing at all — looked exactly like a
    /// successful clear. A clear is now a success only when at least one responder returned a
    /// verified `44`; a refusal or an unverifiable response throws.
    func clearTroubleCodes() async throws {
        let command = OBDCommand.Mode4.CLEAR_DTC
        let response = try await sendCommand(command.properties.command)
        switch DTCResponseParser.clearOutcome(lines: response, family: dtcProtocolFamily) {
        case .verified:
            obdInfo("Clear codes verified by a 44 positive response", category: .service)
        case let .refused(nrc):
            obdError("Clear codes refused by the vehicle (NRC \(nrc))", category: .service)
            throw ELM327Error.invalidResponse(message: "Vehicle refused mode 04 (NRC \(nrc))")
        case .unverified:
            obdError("Clear codes unverified — no 44 response", category: .service)
            throw ELM327Error.invalidResponse(message: "No 44 response to mode 04")
        }
    }

    func scanForPeripherals() async throws {
        try await comm.scanForPeripherals()
    }

    func requestVin() async throws -> String? {
        let command = OBDCommand.Mode9.VIN
        let vinResponse: [String]
        do {
            vinResponse = try await setupCommand(command.properties.command)
        } catch {
            if Self.isNoData(error) { return nil }
            throw error
        }

        guard let data = try? canProtocol?.parse(vinResponse).first?.data,
              var vinString = String(bytes: data, encoding: .utf8)
        else {
            return nil
        }

        vinString = vinString
            .replacingOccurrences(of: "[^a-zA-Z0-9]",
                                  with: "",
                                  options: .regularExpression)

        return vinString
    }
}

extension ELM327 {
    private func populateECUMap(_ messages: [MessageProtocol]) -> [UInt8: ECUID]? {
        let engineTXID = 0
        let transmissionTXID = 1
        var ecuMap: [UInt8: ECUID] = [:]

        // If there are no messages, return an empty map
        guard !messages.isEmpty else {
            return nil
        }

        // If there is only one message, assume it's from the engine
        if messages.count == 1 {
            ecuMap[messages.first?.ecu.rawValue ?? 0] = .engine
            return ecuMap
        }

        // Find the engine and transmission ECU based on TXID
        var foundEngine = false

        for message in messages {
            let txID = message.ecu.rawValue

            if txID == engineTXID {
                ecuMap[txID] = .engine
                foundEngine = true
            } else if txID == transmissionTXID {
                ecuMap[txID] = .transmission
            }
        }

        // If engine ECU is not found, choose the one with the most bits
        if !foundEngine {
            var bestBits = 0
            var bestTXID: UInt8?

            for message in messages {
                guard let bits = message.data?.bitCount() else {
                    logger.error("parse_frame failed to extract data")
                    continue
                }
                if bits > bestBits {
                    bestBits = bits
                    bestTXID = message.ecu.rawValue
                }
            }

            if let bestTXID = bestTXID {
                ecuMap[bestTXID] = .engine
            }
        }

        // Assign transmission ECU to messages without an ECU assignment
        for message in messages where ecuMap[message.ecu.rawValue] == nil {
            ecuMap[message.ecu.rawValue] = .transmission
        }

        return ecuMap
    }
}

extension ELM327 {
    /// Get the supported PIDs
    /// - Returns: Array of supported PIDs
    func getSupportedPIDs() async -> [OBDCommand] {
        (try? await getSupportedPIDs(duringSetup: false)) ?? []
    }

    private func getSupportedPIDs(duringSetup: Bool) async throws -> [OBDCommand] {
        let pidGetters = OBDCommand.pidGetters
        var supportedPIDs: [OBDCommand] = []

        for pidGetter in pidGetters {
            do {
                logger.info("Getting supported PIDs for \(pidGetter.properties.command)")
                try Task.checkCancellation()
                let response: [String]
                if duringSetup && pidGetter.properties.command == "0100" {
                    response = r100
                } else if duringSetup {
                    response = try await setupCommand(pidGetter.properties.command)
                } else {
                    response = try await sendCommand(pidGetter.properties.command)
                }
                // find first instance of 41 plus command sent, from there we determine the position of everything else
                // Ex.
                //        || ||
                // 7E8 06 41 00 BE 7F B8 13
                guard let supportedPidsByECU = parseResponse(response) else {
                    continue
                }

                let supportedCommands = OBDCommand.allCommands
                    .filter { supportedPidsByECU.contains(String($0.properties.command.dropFirst(2))) }
                    .map { $0 }

                supportedPIDs.append(contentsOf: supportedCommands)
            } catch {
                if error is CancellationError || (duringSetup && !Self.isNoData(error)) { throw error }
                logger.error("\(error.localizedDescription)")
            }
        }
        // filter out pidGetters
        supportedPIDs = supportedPIDs.filter { !pidGetters.contains($0) }

        // remove duplicates
        return Array(Set(supportedPIDs))
    }

    private static func isNoData(_ error: Error) -> Bool {
        if let error = error as? BLEManagerError, case .noData = error { return true }
        if let error = error as? CommunicationError, case .noData = error { return true }
        return false
    }

    private func parseResponse(_ response: [String]) -> Set<String>? {
        guard let ecuData = try? canProtocol?.parse(response).first?.data else {
            return nil
        }
        let binaryData = BitArray(data: ecuData.dropFirst()).binaryArray
        return extractSupportedPIDs(binaryData)
    }

    func extractSupportedPIDs(_ binaryData: [Int]) -> Set<String> {
        var supportedPIDs: Set<String> = []

        for (index, value) in binaryData.enumerated() {
            if value == 1 {
                let pid = String(format: "%02X", index + 1)
                supportedPIDs.insert(pid)
            }
        }
        return supportedPIDs
    }
}

struct BatchedResponse {
    private var response: Data
    private var unit: MeasurementUnit
    init(response: Data, _ unit: MeasurementUnit) {
        self.response = response
        self.unit = unit
    }

    mutating func extractValue(_ cmd: OBDCommand) -> MeasurementResult? {
        let properties = cmd.properties
        let size = properties.bytes
        guard response.count >= size else { return nil }
        let valueData = response.prefix(size)

        response.removeFirst(size)
        //        print("Buffer: \(buffer.compactMap { String(format: "%02X ", $0) }.joined())")
        let result = cmd.properties.decode(data: valueData, unit: unit)

        

        switch result {
        case let .success(measurementResult):
            return measurementResult.measurementResult
        case let .failure(error):
            obdError("Failed to decode command \(cmd.properties.command): \(error.localizedDescription) | Data: \(valueData.map { String(format: "%02X", $0) }.joined(separator: " "))", category: .parsing)
            return nil
        }
    }
}

extension String {
    var hexBytes: [UInt8] {
        var position = startIndex
        return (0 ..< count / 2).compactMap { _ in
            defer { position = index(position, offsetBy: 2) }
            return UInt8(self[position ... index(after: position)], radix: 16)
        }
    }

    var isHex: Bool {
        !isEmpty && allSatisfy(\.isHexDigit)
    }
}

extension Data {
    func bitCount() -> Int {
        count * 8
    }
}

enum ECUHeader {
    static let ENGINE = "7E0"
}

// Possible setup errors
// enum SetupError: Error {
//    case noECUCharacteristic
//    case invalidResponse(message: String)
//    case noProtocolFound
//    case adapterInitFailed
//    case timeout
//    case peripheralNotFound
//    case ignitionOff
//    case invalidProtocol
// }

public struct OBDInfo: Codable, Hashable {
    public var vin: String?
    public var supportedPIDs: [OBDCommand]?
    public var obdProtocol: PROTOCOL?
    public var ecuMap: [UInt8: ECUID]?
}
