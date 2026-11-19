import XCTest
@testable import MajorTomCore

final class CloudSyncCallbackBarrierTests: XCTestCase {
    @MainActor
    func testRetiringTransportWaitsForEveryAlreadyAcceptedCallback() async {
        // A cancelled CKSyncEngine may still have an accepted callback persisting data.
        // Its replacement must not fetch newer data until that work has drained.
        let barrier = CloudSyncCallbackBarrier()
        barrier.enter()
        barrier.enter()
        var replacementStarted = false
        let entered = expectation(description: "Replacement waiting")
        let replacement = Task { @MainActor in
            entered.fulfill()
            await barrier.waitUntilIdle()
            replacementStarted = true
        }
        _ = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(replacementStarted)
        barrier.leave()
        XCTAssertFalse(replacementStarted)
        XCTAssertEqual(barrier.count, 1)
        barrier.leave()
        await replacement.value
        XCTAssertTrue(replacementStarted)
        XCTAssertEqual(barrier.count, 0)
    }

    @MainActor
    func testIdleAndRepeatedTransitionsDoNotLeaveStrandedWaiters() async {
        let barrier = CloudSyncCallbackBarrier()
        await barrier.waitUntilIdle()
        for _ in 0..<3 {
            barrier.enter()
            let entered = expectation(description: "Both transitions waiting")
            entered.expectedFulfillmentCount = 2
            let first = Task { @MainActor in entered.fulfill(); await barrier.waitUntilIdle() }
            let second = Task { @MainActor in entered.fulfill(); await barrier.waitUntilIdle() }
            _ = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
            barrier.leave()
            await first.value
            await second.value
            XCTAssertEqual(barrier.count, 0)
        }
    }
}
