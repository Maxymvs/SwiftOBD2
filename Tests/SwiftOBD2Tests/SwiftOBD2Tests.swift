@testable import SwiftOBD2
import XCTest

final class SwiftOBD2Tests: XCTestCase {
    func testCleanAdapterPowerOffArmsStandingReconnect() {
        XCTAssertEqual(
            BLEManager.disconnectRecoveryAction(
                hadError: false,
                wasRequested: false,
                autoReconnectEnabled: true,
                reconnectAttempts: 0,
                maxReconnectAttempts: 5
            ),
            .armStandingReconnect
        )
    }

    func testRequestedDisconnectDoesNotReconnectEvenWhenEnabled() {
        for hadError in [false, true] {
            XCTAssertEqual(
                BLEManager.disconnectRecoveryAction(
                    hadError: hadError,
                    wasRequested: true,
                    autoReconnectEnabled: true,
                    reconnectAttempts: 0,
                    maxReconnectAttempts: 5
                ),
                .none
            )
        }
    }

    func testReconnectDisabledDoesNotRecoverRemoteDisconnect() {
        for hadError in [false, true] {
            XCTAssertEqual(
                BLEManager.disconnectRecoveryAction(
                    hadError: hadError,
                    wasRequested: false,
                    autoReconnectEnabled: false,
                    reconnectAttempts: 5,
                    maxReconnectAttempts: 5
                ),
                .none
            )
        }
    }

    func testUnexpectedDisconnectRetriesBeforeStandingReconnect() {
        XCTAssertEqual(
            BLEManager.disconnectRecoveryAction(
                hadError: true,
                wasRequested: false,
                autoReconnectEnabled: true,
                reconnectAttempts: 0,
                maxReconnectAttempts: 5
            ),
            .retry
        )
    }

    func testUnexpectedDisconnectFallsBackAfterRetryBudget() {
        XCTAssertEqual(
            BLEManager.disconnectRecoveryAction(
                hadError: true,
                wasRequested: false,
                autoReconnectEnabled: true,
                reconnectAttempts: 5,
                maxReconnectAttempts: 5
            ),
            .armStandingReconnect
        )
    }
}
