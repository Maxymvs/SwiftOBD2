@testable import SwiftOBD2
import XCTest

final class BLESubscriptionPublicationStateTests: XCTestCase {
    func testLossCannotPublishBeforeReadyAndPublishesOnlyOnceAfterReady() {
        var state = BLESubscriptionPublicationState()

        XCTAssertFalse(state.claimLoss())
        XCTAssertTrue(state.claimReady())
        XCTAssertFalse(state.claimReady())
        XCTAssertTrue(state.claimLoss())
        XCTAssertFalse(state.claimLoss())
    }

    func testNewConnectionStateCanPublishReadyAndLossAgain() {
        var oldState = BLESubscriptionPublicationState()
        XCTAssertTrue(oldState.claimReady())
        XCTAssertTrue(oldState.claimLoss())

        var newState = BLESubscriptionPublicationState()
        XCTAssertTrue(newState.claimReady())
        XCTAssertTrue(newState.claimLoss())
    }
}
