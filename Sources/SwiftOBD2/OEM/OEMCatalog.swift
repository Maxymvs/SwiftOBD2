//
//  OEMCatalog.swift
//  SwiftOBD2
//
//  The manufacturer (OEM) live-data catalog: which modules a vehicle has, which Mode 22 data
//  identifiers each module answers, and how every signal in a reply is decoded. The catalog is
//  adapted from OBDb (CC BY-SA 4.0) by the catalog pipeline; this side only loads it, strictly.
//
//  Instances come only from `OEMCatalog(data:)`, so every value the transport ever sees went
//  through the loader's checks. The memberwise initializers stay internal for tests.
//

import Foundation

/// A loaded manufacturer live-data catalog.
public struct OEMCatalog: Sendable {
    public let formatVersion: Int
    public let license: String
    public let licenseURL: String
    public let attribution: String
    public let changes: String
    public let vehicles: [OEMCatalogVehicle]
    /// Commands the loader refused, with the reason. Never sent, never decoded.
    public let rejectedCommands: [OEMCatalogRejection]

    /// The vehicle with `id`, if the catalog has it.
    public func vehicle(id: String) -> OEMCatalogVehicle? {
        vehicles.first { $0.id == id }
    }
}

/// One vehicle (make, model, model year) and the modules and commands it supports.
public struct OEMCatalogVehicle: Sendable, Equatable {
    public let id: String
    public let make: String
    public let model: String
    public let modelYear: Int
    public let source: OEMCatalogSource
    public let modules: [OEMCatalogModule]
    public let commands: [OEMCatalogCommand]

    public func module(id: String) -> OEMCatalogModule? {
        modules.first { $0.id == id }
    }

    public func commands(inModule moduleID: String) -> [OEMCatalogCommand] {
        commands.filter { $0.moduleID == moduleID }
    }
}

/// Where a vehicle's definitions came from upstream, for attribution and audit.
public struct OEMCatalogSource: Sendable, Equatable {
    public let repository: String
    public let commit: String
    public let url: String
    public let signalset: String
    public let support: String
}

/// A diagnostic module and how the adapter reaches it.
public struct OEMCatalogModule: Sendable, Equatable {
    public let id: String
    public let name: String
    /// Whether the app reads this module without the user asking for it.
    public let servedByDefault: Bool
    /// A known limitation worth telling the user (e.g. catalog names that don't fit the car).
    public let caveat: String?
    public let target: OEMTarget
}

/// How a module is addressed on an 11-bit CAN bus.
public enum OEMTarget: Hashable, Sendable {
    /// Physical 11-bit addressing: requests on `request`, replies on `response` (e.g. 7E0 → 7E8).
    case standard11Bit(request: UInt16, response: UInt16)
    /// BMW ISO-TP extended addressing: requests on 6F1 with the module address as the first data
    /// byte; replies on `0x600 | address` with F1 as the first data byte.
    case bmwExtended(address: UInt8)

    /// The CAN id the module answers on.
    var responseID: UInt16 {
        switch self {
        case let .standard11Bit(_, response): return response
        case let .bmwExtended(address): return 0x600 | UInt16(address)
        }
    }

    /// The extended-address byte every reply frame starts with, when the target uses one.
    var replyExtendedAddress: UInt8? {
        switch self {
        case .standard11Bit: return nil
        case .bmwExtended: return OEMTarget.bmwTesterAddress
        }
    }

    /// BMW's tester (diagnostic tool) address: requests go out on 0x600 | F1.
    static let bmwTesterAddress: UInt8 = 0xF1
}

/// How much evidence backs a command.
public enum OEMEvidence: String, Sendable, Equatable {
    /// We read it from a real car of this model.
    case captured
    /// Upstream says a real car of this model answered it; we haven't seen it ourselves.
    case catalog
}

/// One Mode 22 read: a data identifier on one module, and the signals packed in its reply.
public struct OEMCatalogCommand: Sendable, Equatable {
    public let id: String
    public let moduleID: String
    public let dataIdentifier: UInt16
    /// Upstream's suggested poll period, in seconds.
    public let frequency: Double
    /// Upstream's `fcm1`: the reply may need explicit flow control.
    public let usesFlowControl: Bool
    public let evidence: OEMEvidence
    /// Payload byte counts (after `62 <DID>`) a real reply has had. Empty means unknown.
    public let replyLengths: [Int]
    public let signals: [OEMCatalogSignal]
}

/// One value inside a command's reply.
public struct OEMCatalogSignal: Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let description: String?
    public let suggestedMetric: String?
    public let format: OEMSignalFormat
}

/// OBDb's `fmt` object: where a signal's bits are and how to scale them.
public struct OEMSignalFormat: Sendable, Equatable {
    /// `bix`: first bit, counted MSB-first from the start of the payload.
    public let bitOffset: Int
    /// `len`: number of bits, 1...64.
    public let bitLength: Int
    /// `blsb`: the value's bytes are little-endian (only applied when `bitLength > 8`).
    public let isLittleEndian: Bool
    /// `sign`: two's complement.
    public let isSigned: Bool
    public let multiplier: Double
    public let divisor: Double
    public let offset: Double
    public let minimum: Double
    public let maximum: Double
    public let unit: String
    /// `nullmin` / `nullmax`: values at or past these mean "no value".
    public let nullMinimum: Double?
    public let nullMaximum: Double?
    /// `map`: raw value → named state. When present the signal is an enumeration.
    public let enumeration: [UInt64: OEMEnumerationValue]?
}

/// A named state of an enumerated signal.
public struct OEMEnumerationValue: Sendable, Equatable {
    public let value: String
    public let description: String?
}

/// A command the loader refused.
public struct OEMCatalogRejection: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case unknownCommandKey(String)
        case unknownSignalKey(String)
        case unknownFormatKey(String)
        /// A required field is missing or has the wrong type or value.
        case invalidField(String)
        case invalidDataIdentifier
        case deniedDataIdentifier
        case invalidBitLayout
        case zeroDivisor
        case unknownModule
        case noSignals
        case missingMaximum
        case missingUnit
        case duplicateCommand
        case duplicateSignal
    }

    public let vehicleID: String
    public let commandID: String
    public let reason: Reason
}

/// Why the catalog as a whole couldn't be loaded.
public enum OEMCatalogError: Error, Equatable {
    case notJSONObject
    case unsupportedFormatVersion
    /// A top-level, vehicle, source, module or target field is missing, mistyped or unknown.
    case malformed(String)
}
