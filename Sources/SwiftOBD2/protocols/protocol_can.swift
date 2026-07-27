//
//  protocol_can.swift
//
//
//  Created by kemo konteh on 5/15/24.
//

import Foundation

protocol CANProtocol {
    var elmID: String { get }
    var name: String { get }

    func parse(_ lines: [String]) throws -> [MessageProtocol]
}

extension CANProtocol {
    /// The CAN id width this protocol frames its responses with, taken from
    /// ``PROTOCOL/idBits`` instead of being hardcoded per class.
    ///
    /// The 29-bit ISO 15765-4 classes used to pass `idBits: 11`, which shifts every byte
    /// boundary of a 4-byte header (`18 DA F1 10`) and makes `Frame.init` throw — so *nothing*
    /// parsed on a 29-bit vehicle, vehicle setup included.
    var idBits: Int {
        PROTOCOL(rawValue: elmID)?.idBits ?? 11
    }

    func parseDefault(_ lines: [String], idBits: Int) throws -> [MessageProtocol] {
        try CANParser(lines, idBits: idBits).messages
    }

    func parseLegacy(_ lines: [String]) throws -> [MessageProtocol] {
        let messages = try LegacyParcer(lines).messages
        return messages
    }
}

class ISO_15765_4_11bit_500k: CANProtocol {
    let elmID = "6"
    let name = "ISO 15765-4 (CAN 11/500)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: idBits)
    }
}

class ISO_15765_4_29bit_500k: CANProtocol {
    let elmID = "7"
    let name = "ISO 15765-4 (CAN 29/500)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: idBits)
    }
}

class ISO_15765_4_11bit_250K: CANProtocol {
    let elmID = "8"
    let name = "ISO 15765-4 (CAN 11/250)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: idBits)
    }
}

class ISO_15765_4_29bit_250k: CANProtocol {
    let elmID = "9"
    let name = "ISO 15765-4 (CAN 29/250)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: idBits)
    }
}

class SAE_J1939: CANProtocol {
    let elmID = "A"
    let name = "SAE J1939 (CAN 29/250)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        // Deliberately left at 11: J1939 reports faults through DM1/DM2 (SPN/FMI), not services
        // 03/07/0A, so widening the id here would not make DTCs work — it is a separate proposal.
        try parseDefault(lines, idBits: 11)
    }
}
