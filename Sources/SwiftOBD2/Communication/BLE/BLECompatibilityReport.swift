import Foundation

public enum BLECompatibilityStage: String, Codable, Equatable, Hashable, Sendable {
    case discovery
    case gattResolved
    case subscription
    case adapterIdentification
    case adapterConfiguration
    case adapterValidated
    case vehicleProbe
    case compatible
    case failed
    case disconnected
}

public enum BLESubscriptionStatus: String, Codable, Equatable, Sendable {
    case notRequested
    case pending
    case confirmed
    case failed
}

/// Redacted failure categories suitable for app diagnostics. Associated raw
/// errors, peripheral identifiers, adapter responses, and vehicle data stay out
/// of this boundary.
public enum BLECompatibilityFailure: String, Codable, Equatable, Sendable {
    case transportUnavailable
    case unsupportedGATT
    case ambiguousGATT
    case notificationSubscriptionFailed
    case adapterIdentificationRejected
    case adapterConfigurationRejected
    case adapterResponseTimedOut
    case vehicleECUUnavailable
    case writeFailed
    case writeTimedOut
    case cancelled
    case disconnected
}

public enum BLECompatibilityCharacteristicProperty: String, Codable, CaseIterable, Equatable, Sendable {
    case read
    case notify
    case indicate
    case writeWithResponse
    case writeWithoutResponse
}

public enum BLECompatibilityWriteMode: String, Codable, Equatable, Sendable {
    case withResponse
    case withoutResponse
}

/// UUID and capability evidence for one characteristic. UUID input is reduced
/// to normalized Bluetooth UUID syntax before it crosses the report boundary.
public struct BLECompatibilityCharacteristic: Codable, Equatable, Sendable {
    public let uuid: String
    public let properties: [BLECompatibilityCharacteristicProperty]

    public init(uuid: String, properties: [BLECompatibilityCharacteristicProperty]) {
        self.uuid = BLECompatibilityEvidenceSanitizer.uuid(uuid)
        let selected = Set(properties.map(\.rawValue))
        self.properties = BLECompatibilityCharacteristicProperty.allCases.filter {
            selected.contains($0.rawValue)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case uuid
        case properties
    }

    public init(from decoder: any Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            uuid: try values.decode(String.self, forKey: .uuid),
            properties: try values.decodeIfPresent(
                [BLECompatibilityCharacteristicProperty].self,
                forKey: .properties
            ) ?? []
        )
    }
}

public struct BLECompatibilityService: Codable, Equatable, Sendable {
    public let uuid: String
    public let characteristics: [BLECompatibilityCharacteristic]

    public init(uuid: String, characteristics: [BLECompatibilityCharacteristic]) {
        self.uuid = BLECompatibilityEvidenceSanitizer.uuid(uuid)
        self.characteristics = characteristics.sorted(by: Self.characteristicOrder)
    }

    private enum CodingKeys: String, CodingKey {
        case uuid
        case characteristics
    }

    public init(from decoder: any Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            uuid: try values.decode(String.self, forKey: .uuid),
            characteristics: try values.decodeIfPresent(
                [BLECompatibilityCharacteristic].self,
                forKey: .characteristics
            ) ?? []
        )
    }

    fileprivate static func characteristicOrder(
        _ lhs: BLECompatibilityCharacteristic,
        _ rhs: BLECompatibilityCharacteristic
    ) -> Bool {
        if lhs.uuid != rhs.uuid { return lhs.uuid < rhs.uuid }
        return lhs.properties.map(\.rawValue).joined(separator: ",")
            < rhs.properties.map(\.rawValue).joined(separator: ",")
    }
}

public struct BLECompatibilityChannel: Codable, Equatable, Sendable {
    public let serviceUUID: String
    public let readCharacteristic: BLECompatibilityCharacteristic
    public let writeCharacteristic: BLECompatibilityCharacteristic
    public let writeMode: BLECompatibilityWriteMode

    public init(
        serviceUUID: String,
        readCharacteristic: BLECompatibilityCharacteristic,
        writeCharacteristic: BLECompatibilityCharacteristic,
        writeMode: BLECompatibilityWriteMode
    ) {
        self.serviceUUID = BLECompatibilityEvidenceSanitizer.uuid(serviceUUID)
        self.readCharacteristic = BLECompatibilityCharacteristic(
            uuid: readCharacteristic.uuid,
            properties: readCharacteristic.properties
        )
        self.writeCharacteristic = BLECompatibilityCharacteristic(
            uuid: writeCharacteristic.uuid,
            properties: writeCharacteristic.properties
        )
        self.writeMode = writeMode
    }

    private enum CodingKeys: String, CodingKey {
        case serviceUUID
        case readCharacteristic
        case writeCharacteristic
        case writeMode
    }

    public init(from decoder: any Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            serviceUUID: try values.decode(String.self, forKey: .serviceUUID),
            readCharacteristic: try values.decode(BLECompatibilityCharacteristic.self, forKey: .readCharacteristic),
            writeCharacteristic: try values.decode(BLECompatibilityCharacteristic.self, forKey: .writeCharacteristic),
            writeMode: try values.decode(BLECompatibilityWriteMode.self, forKey: .writeMode)
        )
    }
}

public struct BLECompatibilityStageDuration: Codable, Equatable, Sendable {
    public let stage: BLECompatibilityStage
    public let durationMilliseconds: Int

    public init(stage: BLECompatibilityStage, durationMilliseconds: Int) {
        self.stage = stage
        self.durationMilliseconds = max(0, durationMilliseconds)
    }
}

private enum BLECompatibilityEvidenceSanitizer {
    static let maximumServiceCount = 16
    static let maximumCharacteristicsPerService = 32

    static func uuid(_ value: String) -> String {
        let normalized = BLECharacteristicDescriptor.normalize(value)
        let isASCIIHex = normalized.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value)
        }
        let isShortUUID = (normalized.count == 4 || normalized.count == 8)
            && isASCIIHex
        let isFullUUID = normalized.count == 36
            && UUID(uuidString: normalized) != nil
        guard isShortUUID || isFullUUID else {
            return "INVALID"
        }
        return normalized
    }
}

/// Fences async stage updates so an earlier connection attempt cannot replace
/// the report for a newer attempt.
final class BLECompatibilityAttemptFence {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == candidate
    }
}

/// Accumulates stage durations from monotonic time. A snapshot includes the
/// current stage without consuming it, so repeated publications cannot double
/// count elapsed time. Terminal stages finalize the attempt exactly once.
struct BLECompatibilityTimeline: Equatable, Sendable {
    private var activeStage: BLECompatibilityStage?
    private var activeStageStartedAtNanoseconds: UInt64 = 0
    private var completedNanoseconds: [BLECompatibilityStage: UInt64] = [:]
    private var stageOrder: [BLECompatibilityStage] = []
    private var isTerminal = false

    mutating func begin(atNanoseconds now: UInt64) {
        activeStage = .discovery
        activeStageStartedAtNanoseconds = now
        completedNanoseconds = [:]
        stageOrder = [.discovery]
        isTerminal = false
    }

    mutating func snapshot(
        transitioningTo stage: BLECompatibilityStage,
        atNanoseconds now: UInt64,
        terminalOutcome: Bool = false
    ) -> [BLECompatibilityStageDuration] {
        if isTerminal { return durations(currentTimeNanoseconds: nil) }

        if activeStage == nil {
            activeStage = stage
            activeStageStartedAtNanoseconds = now
            appendStageIfNeeded(stage)
        } else if activeStage != stage {
            finalizeActiveStage(atNanoseconds: now)
            activeStage = stage
            activeStageStartedAtNanoseconds = now
            appendStageIfNeeded(stage)
        }

        if Self.isTerminal(stage) || terminalOutcome {
            finalizeActiveStage(atNanoseconds: now)
            activeStage = nil
            isTerminal = true
            return durations(currentTimeNanoseconds: nil)
        }
        return durations(currentTimeNanoseconds: now)
    }

    private static func isTerminal(_ stage: BLECompatibilityStage) -> Bool {
        stage == .compatible || stage == .failed || stage == .disconnected
    }

    private mutating func appendStageIfNeeded(_ stage: BLECompatibilityStage) {
        if !stageOrder.contains(stage) { stageOrder.append(stage) }
    }

    private mutating func finalizeActiveStage(atNanoseconds now: UInt64) {
        guard let activeStage else { return }
        let elapsed = now >= activeStageStartedAtNanoseconds
            ? now - activeStageStartedAtNanoseconds
            : 0
        completedNanoseconds[activeStage, default: 0] += elapsed
    }

    private func durations(currentTimeNanoseconds now: UInt64?) -> [BLECompatibilityStageDuration] {
        stageOrder.map { stage in
            var duration = completedNanoseconds[stage, default: 0]
            if stage == activeStage, let now {
                duration += now >= activeStageStartedAtNanoseconds
                    ? now - activeStageStartedAtNanoseconds
                    : 0
            }
            let milliseconds = min(duration / 1_000_000, UInt64(Int.max))
            return BLECompatibilityStageDuration(
                stage: stage,
                durationMilliseconds: Int(milliseconds)
            )
        }
    }
}

enum BLECompatibilityResetPolicy {
    static func shouldRecordDisconnected(
        preservedAttempt: UInt64?,
        currentAttempt: UInt64
    ) -> Bool {
        preservedAttempt != currentAttempt
    }
}

/// Latest compatibility attempt exposed to the host app. This is a value
/// snapshot: callers cannot mutate it and it contains no device or vehicle ID.
public struct BLECompatibilityReport: Codable, Equatable, Sendable {
    public let profileID: String?
    public let profileVersion: Int?
    public let source: BLEAdapterProfileSource?
    public let stage: BLECompatibilityStage
    public let subscription: BLESubscriptionStatus
    public let failure: BLECompatibilityFailure?
    public let selectedChannel: BLECompatibilityChannel?
    public let discoveredServices: [BLECompatibilityService]
    public let discoveredGraphWasTruncated: Bool
    public let stageDurations: [BLECompatibilityStageDuration]
    public let capturedAt: Date

    public init(
        profileID: String?,
        profileVersion: Int?,
        source: BLEAdapterProfileSource?,
        stage: BLECompatibilityStage,
        subscription: BLESubscriptionStatus,
        failure: BLECompatibilityFailure?,
        selectedChannel: BLECompatibilityChannel? = nil,
        discoveredServices: [BLECompatibilityService] = [],
        discoveredGraphWasTruncated: Bool = false,
        stageDurations: [BLECompatibilityStageDuration] = [],
        capturedAt: Date = Date()
    ) {
        self.profileID = profileID
        self.profileVersion = profileVersion
        self.source = source
        self.stage = stage
        self.subscription = subscription
        self.failure = failure
        self.selectedChannel = selectedChannel.map {
            BLECompatibilityChannel(
                serviceUUID: $0.serviceUUID,
                readCharacteristic: $0.readCharacteristic,
                writeCharacteristic: $0.writeCharacteristic,
                writeMode: $0.writeMode
            )
        }

        let normalizedServices = discoveredServices.map {
            BLECompatibilityService(uuid: $0.uuid, characteristics: $0.characteristics)
        }.sorted {
            if $0.uuid != $1.uuid { return $0.uuid < $1.uuid }
            return $0.characteristics.count < $1.characteristics.count
        }
        let graphExceededBounds = normalizedServices.count > BLECompatibilityEvidenceSanitizer.maximumServiceCount
            || normalizedServices.contains {
                $0.characteristics.count > BLECompatibilityEvidenceSanitizer.maximumCharacteristicsPerService
            }
        self.discoveredServices = normalizedServices
            .prefix(BLECompatibilityEvidenceSanitizer.maximumServiceCount)
            .map {
                BLECompatibilityService(
                    uuid: $0.uuid,
                    characteristics: Array($0.characteristics.prefix(
                        BLECompatibilityEvidenceSanitizer.maximumCharacteristicsPerService
                    ))
                )
            }
        self.discoveredGraphWasTruncated = discoveredGraphWasTruncated || graphExceededBounds
        self.stageDurations = stageDurations.map {
            BLECompatibilityStageDuration(
                stage: $0.stage,
                durationMilliseconds: $0.durationMilliseconds
            )
        }
        self.capturedAt = capturedAt
    }

    private enum CodingKeys: String, CodingKey {
        case profileID
        case profileVersion
        case source
        case stage
        case subscription
        case failure
        case selectedChannel
        case discoveredServices
        case discoveredGraphWasTruncated
        case stageDurations
        case capturedAt
    }

    public init(from decoder: any Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            profileID: try values.decodeIfPresent(String.self, forKey: .profileID),
            profileVersion: try values.decodeIfPresent(Int.self, forKey: .profileVersion),
            source: try values.decodeIfPresent(BLEAdapterProfileSource.self, forKey: .source),
            stage: try values.decode(BLECompatibilityStage.self, forKey: .stage),
            subscription: try values.decode(BLESubscriptionStatus.self, forKey: .subscription),
            failure: try values.decodeIfPresent(BLECompatibilityFailure.self, forKey: .failure),
            selectedChannel: try values.decodeIfPresent(BLECompatibilityChannel.self, forKey: .selectedChannel),
            discoveredServices: try values.decodeIfPresent(
                [BLECompatibilityService].self,
                forKey: .discoveredServices
            ) ?? [],
            discoveredGraphWasTruncated: try values.decodeIfPresent(
                Bool.self,
                forKey: .discoveredGraphWasTruncated
            ) ?? false,
            stageDurations: try values.decodeIfPresent(
                [BLECompatibilityStageDuration].self,
                forKey: .stageDurations
            ) ?? [],
            capturedAt: try values.decode(Date.self, forKey: .capturedAt)
        )
    }
}

extension BLECompatibilityReport {
    init(
        binding: BLEAdapterBinding?,
        discoveredGraph: [BLEGATTServiceDescriptor],
        discoveredGraphWasTruncated: Bool = false,
        stage: BLECompatibilityStage,
        subscription: BLESubscriptionStatus,
        failure: BLECompatibilityFailure? = nil,
        stageDurations: [BLECompatibilityStageDuration] = [],
        capturedAt: Date = Date()
    ) {
        let services = discoveredGraph.map { service in
            BLECompatibilityService(
                uuid: service.uuid,
                characteristics: service.characteristics.map(BLECompatibilityCharacteristic.init)
            )
        }
        self.init(
            profileID: binding?.profile.id,
            profileVersion: binding?.profile.version,
            source: binding?.source,
            stage: stage,
            subscription: subscription,
            failure: failure,
            selectedChannel: binding.flatMap { BLECompatibilityChannel(binding: $0, graph: discoveredGraph) },
            discoveredServices: services,
            discoveredGraphWasTruncated: discoveredGraphWasTruncated,
            stageDurations: stageDurations,
            capturedAt: capturedAt
        )
    }

    init(
        binding: BLEAdapterBinding?,
        stage: BLECompatibilityStage,
        subscription: BLESubscriptionStatus,
        failure: BLECompatibilityFailure? = nil,
        capturedAt: Date = Date()
    ) {
        self.init(
            binding: binding,
            discoveredGraph: [],
            stage: stage,
            subscription: subscription,
            failure: failure,
            capturedAt: capturedAt
        )
    }
}

private extension BLECompatibilityCharacteristic {
    init(_ descriptor: BLECharacteristicDescriptor) {
        var properties: [BLECompatibilityCharacteristicProperty] = []
        if descriptor.capabilities.contains(.read) { properties.append(.read) }
        if descriptor.capabilities.contains(.notify) { properties.append(.notify) }
        if descriptor.capabilities.contains(.indicate) { properties.append(.indicate) }
        if descriptor.capabilities.contains(.writeWithResponse) { properties.append(.writeWithResponse) }
        if descriptor.capabilities.contains(.writeWithoutResponse) { properties.append(.writeWithoutResponse) }
        self.init(uuid: descriptor.uuid, properties: properties)
    }
}

private extension BLECompatibilityChannel {
    init?(binding: BLEAdapterBinding, graph: [BLEGATTServiceDescriptor]) {
        guard let service = graph.first(where: { $0.uuid == binding.profile.serviceUUID }),
              let read = service.characteristics.first(where: {
                  $0.uuid == binding.readCharacteristicUUID
              }),
              let write = service.characteristics.first(where: {
                  $0.uuid == binding.writeCharacteristicUUID
              }) else { return nil }
        self.init(
            serviceUUID: service.uuid,
            readCharacteristic: BLECompatibilityCharacteristic(read),
            writeCharacteristic: BLECompatibilityCharacteristic(write),
            writeMode: binding.writeType == .withResponse ? .withResponse : .withoutResponse
        )
    }
}
