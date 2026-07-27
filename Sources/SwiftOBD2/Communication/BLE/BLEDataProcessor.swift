//
//  BLEDataProcessor.swift
//  SwiftOBD2
//
//  The BLE-facing names for the shared request/response slot.
//
//  The implementation moved to `OBDMessageProcessor` when the WiFi transport gained a continuous
//  receive pump: the buffering, `>` framing, request-slot lifecycle and gap retention are the
//  same problem on both transports, and a second hand-rolled copy would have drifted. These
//  aliases keep every BLE call site — and the processor's tests — byte-for-byte unchanged.
//

typealias BLEMessageProcessor = OBDMessageProcessor
typealias BLEMessageProcessorError = OBDMessageProcessorError
