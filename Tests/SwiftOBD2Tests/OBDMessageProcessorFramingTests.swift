//
//  OBDMessageProcessorFramingTests.swift
//
//  Response framing across arbitrary transport boundaries. A callback carries whatever the wire
//  delivered — part of a response, exactly one, or one and a bit — and the buffer must take at
//  most one complete response per drain, keeping the remainder for the next arm.
//
//  The regression: consuming the *whole* buffer whenever any `>` was present destroyed the
//  beginning of the following response, so a `7F … 78` immediately followed by the first bytes of
//  the real answer left that answer unreconstructable — codes hidden behind a response-pending.
//
//  Shared component, so both transports are covered here.
//

@testable import SwiftOBD2
import XCTest

final class OBDMessageProcessorFramingTests: XCTestCase {
    /// The reviewer's exact scenario: one callback carries the interim response, its prompt, and
    /// the *prefix* of the final response; a later callback carries the rest.
    func testAPartialFollowingResponseSurvivesTheDrain() async throws {
        let processor = OBDMessageProcessor()

        let first = processor.beginRequest()
        processor.processReceivedData(Data("7E8 03 7F 03 78\r>\r7E8 04 43 01".utf8))
        let interim = try await processor.awaitResponse(for: first, timeout: 1)
        XCTAssertEqual(interim, ["7E8 03 7F 03 78"], "Only the interim response may be delivered")

        // The continuation arms over the retained prefix, then the rest of the answer lands.
        let continuation = processor.beginContinuationRequest()
        processor.processReceivedData(Data(" 01 04\r\r>".utf8))
        let final = try await processor.awaitResponse(for: continuation, timeout: 1)

        XCTAssertEqual(final, ["7E8 04 43 01 01 04"], "The full final message must be reconstructed")
    }

    /// The same, when the remainder arrives *before* the continuation arms — the gap case.
    func testAPartialFollowingResponseCompletedInTheGapIsDeliveredOnTheNextArm() async throws {
        let processor = OBDMessageProcessor()

        let first = processor.beginRequest()
        processor.processReceivedData(Data("7E8 03 7F 03 78\r>\r7E8 04 43 01".utf8))
        _ = try await processor.awaitResponse(for: first, timeout: 1)

        processor.processReceivedData(Data(" 01 04\r\r>".utf8)) // no slot armed yet

        let continuation = processor.beginContinuationRequest()
        let final = try await processor.awaitResponse(for: continuation, timeout: 1)
        XCTAssertEqual(final, ["7E8 04 43 01 01 04"])
    }

    /// Two complete responses in one callback: the first is delivered, the second retained intact
    /// for the next arm — never merged into one delivery.
    func testTwoCompleteResponsesInOneCallbackAreDeliveredSeparately() async throws {
        let processor = OBDMessageProcessor()

        let first = processor.beginRequest()
        processor.processReceivedData(Data("7E8 03 7F 03 78\r>\r7E8 06 43 02 01 04 05 00\r>".utf8))
        let interim = try await processor.awaitResponse(for: first, timeout: 1)
        XCTAssertEqual(interim, ["7E8 03 7F 03 78"])

        let continuation = processor.beginContinuationRequest()
        let second = try await processor.awaitResponse(for: continuation, timeout: 1)
        XCTAssertEqual(second, ["7E8 06 43 02 01 04 05 00"])
    }

    /// Three responses, one callback, three arms — the buffer is drained one response at a time.
    func testResponsesAreDrainedOneAtATime() async throws {
        let processor = OBDMessageProcessor()

        let first = processor.beginRequest()
        processor.processReceivedData(Data("A1\r>\rB2\r>\rC3\r>".utf8))
        let a = try await processor.awaitResponse(for: first, timeout: 1)
        let b = try await processor.awaitResponse(for: processor.beginContinuationRequest(), timeout: 1)
        let c = try await processor.awaitResponse(for: processor.beginContinuationRequest(), timeout: 1)
        XCTAssertEqual([a, b, c], [["A1"], ["B2"], ["C3"]])
    }

    /// A multi-line response split mid-line across callbacks still assembles, and the following
    /// response's prefix is not eaten.
    func testAResponseSplitMidLineAssembles() async throws {
        let processor = OBDMessageProcessor()

        let token = processor.beginRequest()
        processor.processReceivedData(Data("7E8 10 08 43 03 01 04 05\r7E8 21 00 01".utf8))
        processor.processReceivedData(Data(" 15 00 00 00\r\r>\r7E9 02".utf8))
        let lines = try await processor.awaitResponse(for: token, timeout: 1)

        XCTAssertEqual(lines, ["7E8 10 08 43 03 01 04 05", "7E8 21 00 01 15 00 00 00"])

        let continuation = processor.beginContinuationRequest()
        processor.processReceivedData(Data(" 43 00\r\r>".utf8))
        let trailing = try await processor.awaitResponse(for: continuation, timeout: 1)
        XCTAssertEqual(trailing, ["7E9 02 43 00"])
    }

    /// Retention stays bounded: an unterminated flood is dropped rather than growing forever.
    func testRetainedSuffixRespectsTheBufferBound() async {
        let processor = OBDMessageProcessor(maxBufferSize: 64)

        let first = processor.beginRequest()
        processor.processReceivedData(Data("7E8 02 43 00\r>".utf8))
        _ = try? await processor.awaitResponse(for: first, timeout: 1)

        // A long suffix with no prompt of its own: over the cap, so it must be dropped.
        processor.processReceivedData(Data(String(repeating: "7E8 02 43 00\r", count: 20).utf8))

        let continuation = processor.beginContinuationRequest()
        do {
            let lines = try await processor.awaitResponse(for: continuation, timeout: 0.3)
            XCTFail("An oversized retained suffix must be dropped, got \(lines)")
        } catch {
            XCTAssertTrue(
                error as? OBDMessageProcessorError == .responseTimeout,
                "Unexpected error: \(error)"
            )
        }
    }

    /// A retained suffix that is under the cap survives the bound check untouched.
    func testASmallRetainedSuffixIsKept() async throws {
        let processor = OBDMessageProcessor(maxBufferSize: 64)

        let first = processor.beginRequest()
        processor.processReceivedData(Data("7E8 02 43 00\r>\r7E9 04 43".utf8))
        _ = try await processor.awaitResponse(for: first, timeout: 1)

        let continuation = processor.beginContinuationRequest()
        processor.processReceivedData(Data(" 01 01 04\r\r>".utf8))
        let rest = try await processor.awaitResponse(for: continuation, timeout: 1)
        XCTAssertEqual(rest, ["7E9 04 43 01 01 04"])
    }

    // MARK: - Timeout / cancellation before the awaiting task suspends

    /// The regression, pinned deterministically: a timeout or cancellation reaching the slot
    /// **before** the awaiting task has suspended must still terminate the wait.
    ///
    /// It used to find the slot merely "waiting", do nothing, and leave the body to suspend on a
    /// slot nobody would ever resume — and because `withTimeout`'s task group waits for its
    /// (already cancelled) child, the whole call hung *past its own timeout*. That is exactly the
    /// intermittent hang this suite caught. The generous 30 s wait is the discriminator: with the
    /// bug the call sits there for all of it and the 3 s watchdog fails; with the fix it throws at
    /// once. Racing a real timeout against task scheduling is not reproducible, so the handlers'
    /// shared entry point is driven directly.
    func testASlotFailedBeforeItSuspendsThrowsImmediately() async {
        let processor = OBDMessageProcessor()
        let token = processor.beginRequest()

        processor.fail(token, with: OBDMessageProcessorError.responseTimeout)

        let resolved = expectation(description: "the wait resolves")
        Task {
            do {
                _ = try await processor.awaitResponse(for: token, timeout: 30)
                XCTFail("Expected the wait to fail")
            } catch {
                XCTAssertTrue(
                    error as? OBDMessageProcessorError == .responseTimeout,
                    "Unexpected error: \(error)"
                )
            }
            resolved.fulfill()
        }

        await fulfillment(of: [resolved], timeout: 3)
    }

    /// A slot already suspended is still failed the same way.
    func testASuspendedSlotIsFailedByTheSameEntryPoint() async {
        let processor = OBDMessageProcessor()
        let token = processor.beginRequest()

        let resolved = expectation(description: "the wait resolves")
        Task {
            do {
                _ = try await processor.awaitResponse(for: token, timeout: 30)
                XCTFail("Expected the wait to fail")
            } catch {
                XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
            }
            resolved.fulfill()
        }
        // Let the body reach the continuation, then fail it.
        try? await Task.sleep(nanoseconds: 100_000_000)
        processor.fail(token, with: CancellationError())

        await fulfillment(of: [resolved], timeout: 3)
    }

    /// The same for cancellation landing before the body runs.
    func testCancellationBeforeSuspensionStillFails() async {
        let processor = OBDMessageProcessor()
        let token = processor.beginRequest()

        let resolved = expectation(description: "the wait resolves")
        let task = Task {
            do {
                _ = try await processor.awaitResponse(for: token, timeout: 30)
                XCTFail("Expected the wait to fail")
            } catch {
                XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
            }
            resolved.fulfill()
        }
        task.cancel()

        await fulfillment(of: [resolved], timeout: 5)
    }

    /// After such a timeout the slot is dead, not silently reusable: bytes that arrive late are
    /// retained for the next arm instead of being handed to the abandoned request.
    func testAResponseArrivingAfterAPreSuspensionTimeoutIsRetained() async throws {
        let processor = OBDMessageProcessor()
        let token = processor.beginRequest()

        processor.fail(token, with: OBDMessageProcessorError.responseTimeout)
        let resolved = expectation(description: "the wait resolves")
        Task {
            _ = try? await processor.awaitResponse(for: token, timeout: 30)
            resolved.fulfill()
        }
        await fulfillment(of: [resolved], timeout: 3)

        processor.processReceivedData(Data("7E8 02 43 00\r>".utf8))
        let continuation = processor.beginContinuationRequest()
        let lines = try await processor.awaitResponse(for: continuation, timeout: 1)
        XCTAssertEqual(lines, ["7E8 02 43 00"])
    }

    /// Undecodable bytes inside a completed response no longer block it forever: the response is
    /// delivered (with replacement characters) instead of the slot hanging on a partial decode.
    func testGarbageBytesDoNotBlockACompletedResponse() async throws {
        let processor = OBDMessageProcessor()

        let token = processor.beginRequest()
        var data = Data("7E8 02 43 00\r".utf8)
        data.append(contentsOf: [0xFF, 0xFE]) // not valid UTF-8
        data.append(contentsOf: Data("\r>".utf8))
        processor.processReceivedData(data)

        let lines = try await processor.awaitResponse(for: token, timeout: 1)
        XCTAssertEqual(lines.first, "7E8 02 43 00")
    }
}
