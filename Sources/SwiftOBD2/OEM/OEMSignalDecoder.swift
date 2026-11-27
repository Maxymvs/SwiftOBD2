//
//  OEMSignalDecoder.swift
//  SwiftOBD2
//
//  Decodes one catalog signal out of a Mode 22 payload. The semantics match OBDb's reference
//  decoder (`Scaling.decode_value` / `Enumeration.decode_value`) exactly, so OBDb's own test
//  cases work as golden tests, with one deliberate difference: a signal whose bits run past the
//  payload is an error here, for enumerations too (the reference zero-fills those).
//

import Foundation

/// A decoded signal value.
public enum OEMDecodedValue: Equatable, Sendable {
    /// A number inside the signal's valid range.
    case number(Double)
    /// An enumerated state.
    case text(String)
    /// The module reported "no value" (the `nullmin`/`nullmax` sentinel).
    case null
    /// The scaled value fell outside `[min, max]`. `clamped` is what OBDb's reference reports;
    /// it's a range edge, not a reading, so don't present it as one.
    case outOfRange(clamped: Double)
    /// An enumeration with no entry for the raw value.
    case unmapped(raw: UInt64)
}

public enum OEMDecodeError: Error, Equatable {
    case payloadTooShort(neededBits: Int, haveBits: Int)
}

extension OEMSignalFormat {
    /// Decodes this signal from `payload`: the bytes after `62 <DID hi> <DID lo>`.
    public func decode(_ payload: [UInt8]) throws -> OEMDecodedValue {
        let neededBits = bitOffset + bitLength
        let haveBits = payload.count * 8
        guard bitLength >= 1, bitLength <= 64, bitOffset >= 0, neededBits <= haveBits else {
            throw OEMDecodeError.payloadTooShort(neededBits: neededBits, haveBits: haveBits)
        }

        if let enumeration {
            // The reference reads enumerations MSB-first and ignores `blsb` and `sign`.
            let raw = Self.extractBits(payload, offset: bitOffset, length: bitLength)
            if let entry = enumeration[raw] { return .text(entry.value) }
            return .unmapped(raw: raw)
        }

        var bytes = payload
        if isLittleEndian && bitLength > 8 {
            // Reverse only the bytes holding the value, as the reference does: `ceil(len / 8)`
            // bytes starting at the byte that holds the first bit.
            let start = bitOffset / 8
            let end = Swift.min(start + (bitLength + 7) / 8, bytes.count)
            bytes[start..<end].reverse()
        }
        let raw = Self.extractBits(bytes, offset: bitOffset, length: bitLength)

        let rawValue: Double
        if isSigned {
            // Sign-extend by shifting the value's top bit into bit 63 and back arithmetically.
            let shift = UInt64(64 - bitLength)
            rawValue = Double(Int64(bitPattern: raw << shift) >> Int64(shift))
        } else {
            rawValue = Double(raw)
        }

        let unclamped = rawValue * multiplier / divisor + offset
        var value = unclamped
        if maximum > minimum {
            value = Swift.max(minimum, Swift.min(value, maximum))
        }

        let epsilon = Double.ulpOfOne
        if let nullMinimum, value <= nullMinimum + epsilon { return .null }
        if let nullMaximum, value >= nullMaximum - epsilon { return .null }

        return value == unclamped ? .number(value) : .outOfRange(clamped: value)
    }

    /// `length` bits starting at bit `offset`, numbered MSB-first across the bytes.
    static func extractBits(_ bytes: [UInt8], offset: Int, length: Int) -> UInt64 {
        var result: UInt64 = 0
        for bit in offset..<(offset + length) {
            let byte = bytes[bit / 8]
            let isSet = byte & (0x80 >> UInt8(bit % 8)) != 0
            result = (result << 1) | (isSet ? 1 : 0)
        }
        return result
    }
}
