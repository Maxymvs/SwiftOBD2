//
//  OBDWriteAuthorization.swift
//  SwiftOBD2
//
//  What a bound request hands a transport: a request that may only be written while something
//  outside the transport still holds (a Mode 04 clear bound to one vehicle link).
//
//  Two checks, because they answer different questions:
//
//  - `check` is cheap and may be asked often: when an attempt starts, and again once the stream
//    is proven, before the command is handed to the writer. It saves work and reports the
//    binding's own error early. It is NOT what makes the write safe: a write can wait after it
//    (Bluetooth flow control, a socket), and the binding can be revoked meanwhile.
//  - `whileAuthorized` is what makes it safe. The transport runs the hand-off of the command's
//    first bytes to the system inside it. The owner of the binding holds, across the check and
//    the hand-off, the same lock every revocation takes. So a revocation either comes first, and
//    nothing is written, or returns only after the bytes were handed over.
//

import Foundation

struct OBDWriteAuthorization {
    /// Throws when the binding no longer holds. Called with the transport's command mutex held.
    let check: () throws -> Void

    /// Runs `submit` only while the binding holds, atomically with everything that revokes it.
    /// Throws, without running `submit`, when it no longer holds; rethrows what `submit` throws.
    ///
    /// `submit` is the transport's hand-off of the first bytes (the first Bluetooth chunk, the
    /// start of the socket send). It must be short and must not wait: it runs under the binding
    /// owner's lock.
    let whileAuthorized: (_ submit: () throws -> Void) throws -> Void

    init(
        check: @escaping () throws -> Void,
        whileAuthorized: @escaping (_ submit: () throws -> Void) throws -> Void
    ) {
        self.check = check
        self.whileAuthorized = whileAuthorized
    }

    /// A binding with nothing to serialize against: the check runs immediately before the
    /// hand-off, on the same thread. For tests and for bindings no other thread can revoke.
    init(check: @escaping () throws -> Void) {
        self.init(check: check, whileAuthorized: { submit in
            try check()
            try submit()
        })
    }
}
