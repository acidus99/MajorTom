import XCTest
@testable import MajorTomCore

final class CloudSyncCycleTests: XCTestCase {
    func testCachedOnlyFetchCannotCompleteAnExplicitRefresh() {
        // Live macOS 26.6.2: an automatic engine returned from fetchChanges without
        // server discovery while another Mac's acknowledged rename remained unseen.
        var cycle = CloudSyncCycle()
        cycle.begin(requiresFreshFetch: true)
        cycle.markFetched(freshServerCheck: false)
        cycle.markSendFinished()
        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true))
        cycle.markFetched(freshServerCheck: true)
        XCTAssertTrue(cycle.completeIfDrained(outboxIsEmpty: true))
    }

    func testNewExplicitRefreshCannotReuseEarlierFreshFetchProof() {
        var cycle = CloudSyncCycle()
        cycle.begin(requiresFreshFetch: true)
        cycle.markFetched(freshServerCheck: true)
        cycle.markSendFinished()
        XCTAssertTrue(cycle.completeIfDrained(outboxIsEmpty: true))
        cycle.begin(requiresFreshFetch: true)
        cycle.markFetched(freshServerCheck: false)
        cycle.markSendFinished()
        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true))
    }
    func testEditAfterSendInvalidatesTheOldCompletionProof() {
        var cycle = CloudSyncCycle()
        cycle.begin()
        cycle.markFetched()
        cycle.markSendFinished()
        cycle.invalidateSendProof()
        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true))
        cycle.markSendFinished()
        XCTAssertTrue(cycle.completeIfDrained(outboxIsEmpty: true))
    }

    func testEmptyOutboxIsNotSuccessWithUnresolvedAccountZoneJournalOrAttempts() {
        var cycle = CloudSyncCycle()
        cycle.begin()
        cycle.markFetched()
        cycle.markSendFinished()
        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true, accountAvailable: false))
        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true, zoneActive: false))
        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true, hasUnappliedIncoming: true))
        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true, engineStatePersistenceFailed: true))
        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true, hasInFlightAttempts: true))
        // The outbox is still empty while an accepted local UI edit awaits its writer.
        // Announcing completion here would reproduce a false acknowledgement window.
        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true, hasPendingLocalWrites: true))
        XCTAssertTrue(cycle.completeIfDrained(outboxIsEmpty: true))
    }

    func testCycleReachesCompletionOnlyAfterFetchSendAndDurableDrain() {
        var cycle = CloudSyncCycle()
        cycle.begin()

        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true))
        cycle.markFetched()
        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true))
        cycle.markSendFinished()
        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: false))
        XCTAssertTrue(cycle.completeIfDrained(outboxIsEmpty: true))
        XCTAssertFalse(cycle.isActive)
    }

    func testFailurePreventsUpToDateUntilANewCycleBegins() {
        var cycle = CloudSyncCycle()
        cycle.begin()
        cycle.markFetched()
        cycle.markSendFinished()
        cycle.markFailed()

        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true))
        XCTAssertTrue(cycle.isActive)

        cycle.begin()
        cycle.markFetched()
        cycle.markSendFinished()
        XCTAssertTrue(cycle.completeIfDrained(outboxIsEmpty: true))
    }

    func testAutomaticRetryMustStartANewCycleAfterAnOfflineFailure() {
        // A recoverable offline failure may be retried by CKSyncEngine without another
        // user action. Reusing the failed cycle would leave the UI stuck on Offline
        // after the retry has durably sent its outbox.
        var cycle = CloudSyncCycle()
        cycle.begin()
        cycle.markFailed()

        cycle.begin()
        cycle.markFetched()
        cycle.markSendFinished()

        XCTAssertTrue(cycle.completeIfDrained(outboxIsEmpty: true))
    }

    func testRepeatedCallbacksCannotCompleteAnInactiveCycle() {
        var cycle = CloudSyncCycle()
        cycle.markFetched()
        cycle.markSendFinished()

        XCTAssertFalse(cycle.completeIfDrained(outboxIsEmpty: true))
    }
}
