import Foundation
import XCTest
@testable import MajorTomCore

final class CloudSyncReconciliationTests: XCTestCase {
    func testRemoteModificationAppliesWithoutPendingIntent() {
        XCTAssertEqual(
            CloudSyncReconciliation.fetchedModification(pending: nil, serverModelPayload: Data([1])),
            .applyRemote
        )
    }

    func testMatchingFetchedValueRetainsIntentUntilItsOwnSendResult() {
        // Equality cannot cancel an earlier, different generation already in flight.
        let pending = CloudPendingChange(
            accountIdentityHash: "account", recordType: "MTBookmark", recordName: "bookmark",
            operation: .save, generation: 7, modelPayload: Data([1]), payloadDigest: "digest"
        )

        XCTAssertEqual(
            CloudSyncReconciliation.fetchedModification(pending: pending, serverModelPayload: Data([1])),
            .retainPendingSave(generation: 7)
        )
    }

    func testDifferentFetchedValueRetainsPendingSave() {
        let pending = CloudPendingChange(
            accountIdentityHash: "account", recordType: "MTBookmark", recordName: "bookmark",
            operation: .save, generation: 8, modelPayload: Data([1]), payloadDigest: "digest"
        )

        XCTAssertEqual(
            CloudSyncReconciliation.fetchedModification(pending: pending, serverModelPayload: Data([2])),
            .retainPendingSave(generation: 8)
        )
    }

    func testFetchedModificationCannotResurrectPendingDelete() {
        let pending = CloudPendingChange(
            accountIdentityHash: "account", recordType: "MTBookmark", recordName: "bookmark",
            operation: .delete, generation: 9
        )

        XCTAssertEqual(
            CloudSyncReconciliation.fetchedModification(pending: pending, serverModelPayload: Data([1])),
            .retainPendingDelete(generation: 9)
        )
    }
}
