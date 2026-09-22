import Foundation

/// Bounded setup budgets, shared with clients so an outer timeout cannot truncate
/// a permitted protocol search. These are conservative software limits; hardware
/// measurements should tune them before making latency/compatibility claims.
public enum OBDConnectionTiming {
    public static let commandResponse: TimeInterval = 3
    public static let protocolSearch: TimeInterval = 30
    public static let adapterResetDelay: TimeInterval = 0.5
    public static let adapterTransport: TimeInterval = 7

    // Five initialization commands, a preferred selection plus possible ATSP0
    // fallback, one search, ATDPN, VIN, and remaining supported-PID requests.
    // The initial 0100 bitmap is reused instead of queried again.
    public static var adapterAndVehicleSetup: TimeInterval {
        (5 + 2 + 1 + Double(OBDCommand.pidGetters.count)) * commandResponse
            + adapterResetDelay + protocolSearch + 5
    }

    public static var fullConnection: TimeInterval {
        adapterTransport + 2 * commandResponse + adapterAndVehicleSetup
    }
}
