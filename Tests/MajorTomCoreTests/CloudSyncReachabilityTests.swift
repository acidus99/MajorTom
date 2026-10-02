import XCTest
@testable import MajorTomCore

final class CloudSyncReachabilityTests: XCTestCase {
    func testOnlyAnOfflineToOnlineEdgeRequestsRecovery() {
        var reachability = CloudSyncReachability()

        XCTAssertFalse(reachability.observe(available: true))
        XCTAssertFalse(reachability.observe(available: true))
        XCTAssertFalse(reachability.observe(available: false))
        XCTAssertTrue(reachability.observe(available: true))
        XCTAssertFalse(reachability.observe(available: true))
    }

    func testEachSeparateReconnectionRequestsExactlyOneRecovery() {
        var reachability = CloudSyncReachability()

        XCTAssertFalse(reachability.observe(available: false))
        XCTAssertTrue(reachability.observe(available: true))
        XCTAssertFalse(reachability.observe(available: false))
        XCTAssertTrue(reachability.observe(available: true))
    }
}
