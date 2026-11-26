//
//  OEMCatalogLoader.swift
//  SwiftOBD2
//
//  Strict loading of the OEM catalog. The rule is "every field is understood, or the command is
//  rejected": keys are walked dynamically, so a field the decoder doesn't implement can never be
//  silently ignored and turn into a wrong number on screen.
//
//  A malformed top level, vehicle, source or module throws: those describe where requests go, so
//  there's no safe partial reading of them. A malformed command is dropped and recorded in
//  `rejectedCommands`, so one bad definition doesn't take the rest of the vehicle with it.
//

import CoreFoundation
import Foundation

extension OEMCatalog {
    public init(data: Data) throws {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OEMCatalogError.notJSONObject
        }
        guard let object = root as? [String: Any] else { throw OEMCatalogError.notJSONObject }
        let fields = OEMJSONObject(object, context: "catalog")
        try fields.allowOnly(["formatVersion", "license", "licenseURL", "attribution", "changes", "vehicles"])
        guard try fields.requiredInt("formatVersion") == 1 else {
            throw OEMCatalogError.unsupportedFormatVersion
        }

        var rejections: [OEMCatalogRejection] = []
        var vehicles: [OEMCatalogVehicle] = []
        var vehicleIDs = Set<String>()
        for (index, entry) in try fields.requiredArray("vehicles").enumerated() {
            guard let vehicleObject = entry as? [String: Any] else {
                throw OEMCatalogError.malformed("vehicles[\(index)]")
            }
            let vehicle = try OEMCatalogLoader.vehicle(vehicleObject, rejections: &rejections)
            guard vehicleIDs.insert(vehicle.id).inserted else {
                throw OEMCatalogError.malformed("duplicate vehicle \(vehicle.id)")
            }
            vehicles.append(vehicle)
        }

        self.init(
            formatVersion: 1,
            license: try fields.requiredString("license"),
            licenseURL: try fields.requiredString("licenseURL"),
            attribution: try fields.requiredString("attribution"),
            changes: try fields.requiredString("changes"),
            vehicles: vehicles,
            rejectedCommands: rejections
        )
    }
}

enum OEMCatalogLoader {
    static let commandKeys: Set<String> = ["id", "module", "did", "freq", "fcm1", "evidence", "replyLengths", "signals"]
    static let signalKeys: Set<String> = ["id", "name", "path", "fmt", "description", "suggestedMetric"]
    static let formatKeys: Set<String> = [
        "bix", "len", "blsb", "sign", "mul", "div", "add", "min", "max", "unit", "nullmin", "nullmax", "map",
    ]

    // MARK: Vehicle, source, module (malformed → throw)

    static func vehicle(_ object: [String: Any], rejections: inout [OEMCatalogRejection]) throws -> OEMCatalogVehicle {
        let fields = OEMJSONObject(object, context: "vehicle")
        try fields.allowOnly(["id", "make", "model", "modelYear", "source", "modules", "commands"])
        let id = try fields.requiredString("id")
        let vehicleFields = OEMJSONObject(object, context: "vehicle \(id)")

        guard let sourceObject = object["source"] as? [String: Any] else {
            throw OEMCatalogError.malformed("vehicle \(id): source")
        }
        let source = try self.source(OEMJSONObject(sourceObject, context: "vehicle \(id) source"))

        var modules: [OEMCatalogModule] = []
        for (index, entry) in try vehicleFields.requiredArray("modules").enumerated() {
            guard let moduleObject = entry as? [String: Any] else {
                throw OEMCatalogError.malformed("vehicle \(id): modules[\(index)]")
            }
            let module = try self.module(OEMJSONObject(moduleObject, context: "vehicle \(id) module"))
            guard !modules.contains(where: { $0.id == module.id }) else {
                throw OEMCatalogError.malformed("vehicle \(id): duplicate module \(module.id)")
            }
            modules.append(module)
        }

        var commands: [OEMCatalogCommand] = []
        for (index, entry) in try vehicleFields.requiredArray("commands").enumerated() {
            let commandID = ((entry as? [String: Any])?["id"] as? String) ?? "commands[\(index)]"
            switch command(entry, modules: modules) {
            case let .success(command):
                if commands.contains(where: { $0.id == command.id }) {
                    rejections.append(OEMCatalogRejection(vehicleID: id, commandID: commandID, reason: .duplicateCommand))
                } else {
                    commands.append(command)
                }
            case let .failure(rejection):
                rejections.append(OEMCatalogRejection(vehicleID: id, commandID: commandID, reason: rejection.reason))
            }
        }

        return OEMCatalogVehicle(
            id: id,
            make: try vehicleFields.requiredString("make"),
            model: try vehicleFields.requiredString("model"),
            modelYear: try vehicleFields.requiredInt("modelYear"),
            source: source,
            modules: modules,
            commands: commands
        )
    }

    static func source(_ fields: OEMJSONObject) throws -> OEMCatalogSource {
        try fields.allowOnly(["repository", "commit", "url", "signalset", "support"])
        return OEMCatalogSource(
            repository: try fields.requiredString("repository"),
            commit: try fields.requiredString("commit"),
            url: try fields.requiredString("url"),
            signalset: try fields.requiredString("signalset"),
            support: try fields.requiredString("support")
        )
    }

    static func module(_ fields: OEMJSONObject) throws -> OEMCatalogModule {
        try fields.allowOnly(["id", "name", "servedByDefault", "caveat", "target"])
        guard let targetObject = fields.object["target"] as? [String: Any] else {
            throw OEMCatalogError.malformed("\(fields.context): target")
        }
        return OEMCatalogModule(
            id: try fields.requiredString("id"),
            name: try fields.requiredString("name"),
            servedByDefault: try fields.requiredBool("servedByDefault"),
            caveat: try fields.optionalString("caveat"),
            target: try target(OEMJSONObject(targetObject, context: "\(fields.context) target"))
        )
    }

    static func target(_ fields: OEMJSONObject) throws -> OEMTarget {
        switch try fields.requiredString("kind") {
        case "standard11Bit":
            try fields.allowOnly(["kind", "request", "response"])
            guard let request = hex(try fields.requiredString("request"), digits: 3), request <= 0x7FF,
                  let response = hex(try fields.requiredString("response"), digits: 3), response <= 0x7FF,
                  request != response
            else {
                throw OEMCatalogError.malformed("\(fields.context): 11-bit ids")
            }
            return .standard11Bit(request: UInt16(request), response: UInt16(response))
        case "bmwExtended":
            try fields.allowOnly(["kind", "address", "request", "response"])
            guard let address = hex(try fields.requiredString("address"), digits: 2) else {
                throw OEMCatalogError.malformed("\(fields.context): address")
            }
            let target = OEMTarget.bmwExtended(address: UInt8(address))
            // The request and response ids are implied by the address; the catalog spells them
            // out, and they must agree exactly.
            guard hex(try fields.requiredString("request"), digits: 3) == 0x600 | UInt64(OEMTarget.bmwTesterAddress),
                  hex(try fields.requiredString("response"), digits: 3) == UInt64(target.responseID)
            else {
                throw OEMCatalogError.malformed("\(fields.context): BMW ids don't match the address")
            }
            return target
        default:
            throw OEMCatalogError.malformed("\(fields.context): unknown target kind")
        }
    }

    // MARK: Command and signal (malformed → reject the command)

    struct Rejected: Error {
        let reason: OEMCatalogRejection.Reason
    }

    static func command(_ entry: Any, modules: [OEMCatalogModule]) -> Result<OEMCatalogCommand, Rejected> {
        do {
            return .success(try parseCommand(entry, modules: modules))
        } catch let rejected as Rejected {
            return .failure(rejected)
        } catch {
            return .failure(Rejected(reason: .invalidField("command")))
        }
    }

    private static func parseCommand(_ entry: Any, modules: [OEMCatalogModule]) throws -> OEMCatalogCommand {
        guard let object = entry as? [String: Any] else { throw Rejected(reason: .invalidField("command")) }
        if let unknown = object.keys.sorted().first(where: { !commandKeys.contains($0) }) {
            throw Rejected(reason: .unknownCommandKey(unknown))
        }
        let fields = OEMJSONObject(object, context: "command")

        let id = try fields.rejectingString("id")
        let moduleID = try fields.rejectingString("module")
        let didText = try fields.rejectingString("did")
        guard let didValue = hex(didText, digits: 4) else { throw Rejected(reason: .invalidDataIdentifier) }
        let dataIdentifier = UInt16(didValue)
        guard !OEMRequestPolicy.deniedDataIdentifiers.contains(dataIdentifier) else {
            throw Rejected(reason: .deniedDataIdentifier)
        }
        guard modules.contains(where: { $0.id == moduleID }) else { throw Rejected(reason: .unknownModule) }

        guard let frequency = fields.number("freq"), frequency > 0, frequency.isFinite else {
            throw Rejected(reason: .invalidField("freq"))
        }
        let usesFlowControl: Bool
        if object["fcm1"] == nil {
            usesFlowControl = false
        } else if let value = fields.bool("fcm1") {
            usesFlowControl = value
        } else {
            throw Rejected(reason: .invalidField("fcm1"))
        }
        guard let evidence = OEMEvidence(rawValue: try fields.rejectingString("evidence")) else {
            throw Rejected(reason: .invalidField("evidence"))
        }
        var replyLengths: [Int] = []
        if let raw = object["replyLengths"] {
            guard let array = raw as? [Any] else { throw Rejected(reason: .invalidField("replyLengths")) }
            for item in array {
                guard let length = OEMJSONObject.integer(item), length >= 0 else {
                    throw Rejected(reason: .invalidField("replyLengths"))
                }
                replyLengths.append(length)
            }
        }

        guard let signalEntries = object["signals"] as? [Any] else { throw Rejected(reason: .noSignals) }
        guard !signalEntries.isEmpty else { throw Rejected(reason: .noSignals) }
        var signals: [OEMCatalogSignal] = []
        for entry in signalEntries {
            let signal = try self.signal(entry)
            guard !signals.contains(where: { $0.id == signal.id }) else { throw Rejected(reason: .duplicateSignal) }
            signals.append(signal)
        }

        return OEMCatalogCommand(
            id: id,
            moduleID: moduleID,
            dataIdentifier: dataIdentifier,
            frequency: frequency,
            usesFlowControl: usesFlowControl,
            evidence: evidence,
            replyLengths: replyLengths,
            signals: signals
        )
    }

    private static func signal(_ entry: Any) throws -> OEMCatalogSignal {
        guard let object = entry as? [String: Any] else { throw Rejected(reason: .invalidField("signal")) }
        if let unknown = object.keys.sorted().first(where: { !signalKeys.contains($0) }) {
            throw Rejected(reason: .unknownSignalKey(unknown))
        }
        let fields = OEMJSONObject(object, context: "signal")
        guard let formatObject = object["fmt"] as? [String: Any] else { throw Rejected(reason: .invalidField("fmt")) }
        return OEMCatalogSignal(
            id: try fields.rejectingString("id"),
            name: try fields.rejectingString("name"),
            path: try fields.rejectingString("path"),
            description: try fields.rejectingOptionalString("description"),
            suggestedMetric: try fields.rejectingOptionalString("suggestedMetric"),
            format: try format(formatObject)
        )
    }

    /// OBDb's `fmt`, with OBDb's defaults: `bix` 0, `blsb`/`sign` false, `mul` 1, `div` 1,
    /// `add` 0, `min` 0. `len` is required; `max` and `unit` are too, unless `map` is present
    /// (then a missing `max` is stored as 0 and a missing `unit` as "", both unused).
    static func format(_ object: [String: Any]) throws -> OEMSignalFormat {
        if let unknown = object.keys.sorted().first(where: { !formatKeys.contains($0) }) {
            throw Rejected(reason: .unknownFormatKey(unknown))
        }
        let fields = OEMJSONObject(object, context: "fmt")

        func integer(_ key: String, default value: Int) throws -> Int {
            guard object[key] != nil else { return value }
            guard let parsed = OEMJSONObject.integer(object[key]!) else { throw Rejected(reason: .invalidField(key)) }
            return parsed
        }
        func number(_ key: String, default value: Double?) throws -> Double? {
            guard object[key] != nil else { return value }
            guard let parsed = fields.number(key), parsed.isFinite else { throw Rejected(reason: .invalidField(key)) }
            return parsed
        }
        func flag(_ key: String) throws -> Bool {
            guard object[key] != nil else { return false }
            guard let parsed = fields.bool(key) else { throw Rejected(reason: .invalidField(key)) }
            return parsed
        }

        guard object["len"] != nil else { throw Rejected(reason: .invalidBitLayout) }
        let bitLength = try integer("len", default: 0)
        let bitOffset = try integer("bix", default: 0)
        guard (1...64).contains(bitLength), bitOffset >= 0 else { throw Rejected(reason: .invalidBitLayout) }

        let divisor = try number("div", default: 1)!
        guard divisor != 0 else { throw Rejected(reason: .zeroDivisor) }

        let enumeration = try object["map"].map { try self.enumeration($0) }

        // OBDb's reference only needs `max` and `unit` for scaled values; an enumeration is
        // decoded through its map alone.
        guard object["max"] != nil || enumeration != nil else { throw Rejected(reason: .missingMaximum) }
        let unit: String
        if let rawUnit = object["unit"] {
            guard let text = rawUnit as? String, !text.isEmpty else { throw Rejected(reason: .invalidField("unit")) }
            unit = text
        } else if enumeration != nil {
            unit = ""
        } else {
            throw Rejected(reason: .missingUnit)
        }

        return OEMSignalFormat(
            bitOffset: bitOffset,
            bitLength: bitLength,
            isLittleEndian: try flag("blsb"),
            isSigned: try flag("sign"),
            multiplier: try number("mul", default: 1)!,
            divisor: divisor,
            offset: try number("add", default: 0)!,
            minimum: try number("min", default: 0)!,
            maximum: try number("max", default: 0)!,
            unit: unit,
            nullMinimum: try number("nullmin", default: nil),
            nullMaximum: try number("nullmax", default: nil),
            enumeration: enumeration
        )
    }

    /// `map`: decimal raw value → `{"value": …, "description": …}` (or a bare string, which
    /// OBDb's reference also accepts and uses as both).
    private static func enumeration(_ raw: Any) throws -> [UInt64: OEMEnumerationValue] {
        guard let object = raw as? [String: Any], !object.isEmpty else { throw Rejected(reason: .invalidField("map")) }
        var result: [UInt64: OEMEnumerationValue] = [:]
        for (key, entry) in object {
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }), let rawValue = UInt64(key) else {
                throw Rejected(reason: .invalidField("map"))
            }
            if let text = entry as? String {
                result[rawValue] = OEMEnumerationValue(value: text, description: text)
            } else if let entryObject = entry as? [String: Any],
                      Set(entryObject.keys).isSubset(of: ["value", "description"]),
                      let value = entryObject["value"] as? String {
                let description = entryObject["description"]
                guard description == nil || description is String else { throw Rejected(reason: .invalidField("map")) }
                result[rawValue] = OEMEnumerationValue(value: value, description: description as? String)
            } else {
                throw Rejected(reason: .invalidField("map"))
            }
        }
        return result
    }

    /// Exactly `digits` hex characters (either case), nothing else.
    static func hex(_ text: String, digits: Int) -> UInt64? {
        guard text.count == digits, text.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return UInt64(text, radix: 16)
    }
}

/// Typed reads over a `JSONSerialization` object, telling JSON booleans and numbers apart
/// (both arrive as `NSNumber`).
struct OEMJSONObject {
    let object: [String: Any]
    let context: String

    init(_ object: [String: Any], context: String) {
        self.object = object
        self.context = context
    }

    func allowOnly(_ keys: Set<String>) throws {
        if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) {
            throw OEMCatalogError.malformed("\(context): unknown key \(unknown)")
        }
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw OEMCatalogError.malformed("\(context): \(key)")
        }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let text = value as? String else { throw OEMCatalogError.malformed("\(context): \(key)") }
        return text
    }

    func requiredInt(_ key: String) throws -> Int {
        guard let value = object[key], let integer = Self.integer(value) else {
            throw OEMCatalogError.malformed("\(context): \(key)")
        }
        return integer
    }

    func requiredBool(_ key: String) throws -> Bool {
        guard let value = bool(key) else { throw OEMCatalogError.malformed("\(context): \(key)") }
        return value
    }

    func requiredArray(_ key: String) throws -> [Any] {
        guard let value = object[key] as? [Any] else { throw OEMCatalogError.malformed("\(context): \(key)") }
        return value
    }

    // Command-level variants: a bad field rejects the command instead of throwing the catalog.

    func rejectingString(_ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw OEMCatalogLoader.Rejected(reason: .invalidField(key))
        }
        return value
    }

    func rejectingOptionalString(_ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let text = value as? String else { throw OEMCatalogLoader.Rejected(reason: .invalidField(key)) }
        return text
    }

    func number(_ key: String) -> Double? {
        guard let value = object[key] as? NSNumber, !Self.isBoolean(value) else { return nil }
        return value.doubleValue
    }

    func bool(_ key: String) -> Bool? {
        guard let value = object[key] as? NSNumber, Self.isBoolean(value) else { return nil }
        return value.boolValue
    }

    /// A JSON number with no fractional part (and not a boolean).
    static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
