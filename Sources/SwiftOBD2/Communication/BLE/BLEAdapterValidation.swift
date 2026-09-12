import Foundation

enum BLEAdapterValidationCommand: String, Codable, Equatable, Sendable {
    case identifyAdapter = "ATI"
    case disableEcho = "ATE0"
    case probeVehicle = "0100"
}

enum BLEAdapterValidationFailure: String, Codable, Equatable, Sendable {
    case invalidAdapterIdentification
    case echoDisableRejected
    case vehicleECUUnavailable
    case responseTimedOut
    case cancelled
    case writeFailed
}

enum BLEAdapterValidationStage: String, Codable, Equatable, Sendable {
    case awaitingAdapterIdentification
    case awaitingEchoDisable
    case adapterValidated
    case awaitingVehicleResponse
    case vehicleValidated
    case failed
}

/// Pure validation state used by the BLE transport. It enforces ATI before
/// ATE0 and keeps the later ECU probe separate from adapter validation.
struct BLEAdapterValidationState: Equatable, Sendable {
    private(set) var stage: BLEAdapterValidationStage = .awaitingAdapterIdentification
    private(set) var failure: BLEAdapterValidationFailure?

    var nextCommand: BLEAdapterValidationCommand? {
        switch stage {
        case .awaitingAdapterIdentification: return .identifyAdapter
        case .awaitingEchoDisable: return .disableEcho
        case .awaitingVehicleResponse: return .probeVehicle
        case .adapterValidated, .vehicleValidated, .failed: return nil
        }
    }

    var isAdapterValidated: Bool {
        switch stage {
        case .adapterValidated, .awaitingVehicleResponse, .vehicleValidated:
            return true
        default:
            return false
        }
    }

    var hasVehicleEvidence: Bool {
        stage == .vehicleValidated
    }

    mutating func receive(_ response: [String]) {
        switch stage {
        case .awaitingAdapterIdentification:
            guard BLEELMResponseValidator.isAdapterIdentification(response) else {
                fail(.invalidAdapterIdentification)
                return
            }
            stage = .awaitingEchoDisable
        case .awaitingEchoDisable:
            guard BLEELMResponseValidator.isOK(response, echoing: .disableEcho) else {
                fail(.echoDisableRejected)
                return
            }
            stage = .adapterValidated
        case .awaitingVehicleResponse:
            if BLEELMResponseValidator.hasVehicleResponse(response) {
                stage = .vehicleValidated
            } else {
                stage = .adapterValidated
                failure = .vehicleECUUnavailable
            }
        case .adapterValidated, .vehicleValidated, .failed:
            break
        }
    }

    mutating func beginVehicleProbe() {
        guard stage == .adapterValidated else { return }
        failure = nil
        stage = .awaitingVehicleResponse
    }

    mutating func fail(_ failure: BLEAdapterValidationFailure) {
        if stage == .awaitingVehicleResponse || (failure == .vehicleECUUnavailable && isAdapterValidated) {
            stage = .adapterValidated
            self.failure = failure
            return
        }
        stage = .failed
        self.failure = failure
    }
}

/// Strict, bounded recognition for the initial unknown-channel probe. Printable
/// text alone is never evidence that the selected characteristic speaks ELM.
enum BLEELMResponseValidator {
    static let maximumResponseBytes = 512
    static let maximumResponseLines = 12

    static func isAdapterIdentification(_ response: [String]) -> Bool {
        guard let lines = normalizedLines(response, echoing: .identifyAdapter),
              lines.count == 1,
              let line = lines.first else {
            return false
        }

        let pattern = #"^(ELM327|STN[0-9]{3,4})(?: +V?[0-9]+(?:\.[0-9]+){0,2}[A-Z0-9._-]*)?$"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    static func isOK(
        _ response: [String],
        echoing command: BLEAdapterValidationCommand
    ) -> Bool {
        guard let lines = normalizedLines(response, echoing: command) else {
            return false
        }
        return lines == ["OK"]
    }

    static func hasVehicleResponse(_ response: [String]) -> Bool {
        guard let lines = normalizedLines(response, echoing: .probeVehicle), !lines.isEmpty else {
            return false
        }
        return lines.contains(where: isSupportedPIDBitmapResponse)
    }

    private static func normalizedLines(
        _ response: [String],
        echoing command: BLEAdapterValidationCommand
    ) -> [String]? {
        guard response.count <= maximumResponseLines else { return nil }
        let byteCount = response.reduce(0) { partial, line in
            partial + line.lengthOfBytes(using: .utf8)
        }
        guard byteCount <= maximumResponseBytes else { return nil }

        var result: [String] = []
        for responseLine in response {
            guard responseLine.unicodeScalars.allSatisfy({ scalar in
                scalar.value == 0x0A || scalar.value == 0x0D
                    || (scalar.value >= 0x20 && scalar.value <= 0x7E)
            }) else {
                return nil
            }

            let fragments = responseLine.components(separatedBy: CharacterSet.newlines)
            for fragment in fragments {
                var line = fragment.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                while line.hasSuffix(">") {
                    line.removeLast()
                    line = line.trimmingCharacters(in: .whitespaces)
                }
                guard !line.isEmpty, line != command.rawValue else { continue }
                result.append(line)
                guard result.count <= maximumResponseLines else { return nil }
            }
        }
        return result
    }

    private static func isSupportedPIDBitmapResponse(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty,
              compact.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 0x30 && scalar.value <= 0x39)
                      || (scalar.value >= 0x41 && scalar.value <= 0x46)
              }) else {
            return false
        }

        // No header, 11-bit header + DLC, ISO/KWP three-byte header, and
        // 29-bit header + DLC. Each candidate must include the full four-byte
        // PID support bitmap following 41 00.
        for payloadOffset in [0, 5, 6, 10] {
            guard compact.count >= payloadOffset + 12 else { continue }
            let start = compact.index(compact.startIndex, offsetBy: payloadOffset)
            let end = compact.index(start, offsetBy: 12)
            let payload = compact[start..<end]
            if payload.hasPrefix("4100") {
                return true
            }
        }
        return false
    }
}
