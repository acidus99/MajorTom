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
        let replacement = Task { @MainActor in
            await barrier.waitUntilIdle()
            replacementStarted = true
        }
        await Task.yield()
        XCTAssertFalse(replacementStarted)
        barrier.leave()
        await Task.yield()
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
            let first = Task { @MainActor in await barrier.waitUntilIdle() }
            let second = Task { @MainActor in await barrier.waitUntilIdle() }
            await Task.yield()
            barrier.leave()
            await first.value
            await second.value
            XCTAssertEqual(barrier.count, 0)
        }
    }
}
