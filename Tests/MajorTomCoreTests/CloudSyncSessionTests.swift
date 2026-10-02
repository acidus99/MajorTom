import XCTest
@testable import MajorTomCore

final class CloudSyncSessionTests: XCTestCase {
    func testInitialSignInForAlreadyBoundAccountDoesNotRestartEngine() {
        // Found in the first signed live run: replacing the engine for its own startup
        // sign-in event repeatedly cancelled fetches before they could make progress.
        for _ in 0..<10 {
            XCTAssertFalse(CloudSyncSession.requiresAccountActivation(reportedAccount: "a", activeAccount: "a"))
        }
        XCTAssertTrue(CloudSyncSession.requiresAccountActivation(reportedAccount: "b", activeAccount: "a"))
        XCTAssertTrue(CloudSyncSession.requiresAccountActivation(reportedAccount: "a", activeAccount: nil))
    }

    func testDuplicatePreparationCannotReplaceTheAttemptedGeneration() {
        // The old record-name dictionary could replace N with N+1 before N completed.
        var session = CloudSyncSession()
        session.begin()
        let first = CloudPendingChange(accountIdentityHash: "a", recordType: "MTBookmark", recordName: "same",
                                       operation: .delete, generation: 1)
        var next = first
        next.generation = 2
        XCTAssertTrue(session.reserve(first, token: session.token))
        XCTAssertFalse(session.reserve(next, token: session.token))
        XCTAssertEqual(session.attempts["same"]?.generation, 1)
        session.finish("same", token: session.token)
        XCTAssertTrue(session.reserve(next, token: session.token))
    }

    func testOldCallbackAndDeferredCleanupCannotTouchNewAccountAttempt() {
        // Covers cleanup as well as callback entry: an old async defer used to be able
        // to erase B's map entry after the awaited operation noticed its stale session.
        var session = CloudSyncSession()
        session.begin()
        let old = session.token
        XCTAssertTrue(session.reserve(.init(accountIdentityHash: "a", recordType: "MTBookmark", recordName: "same",
                                            operation: .delete, generation: 7), token: old))
        session.begin()
        let current = session.token
        XCTAssertTrue(session.reserve(.init(accountIdentityHash: "b", recordType: "MTBookmark", recordName: "same",
                                            operation: .delete, generation: 8), token: current))
        XCTAssertFalse(session.accepts(old))
        XCTAssertFalse(session.reserve(.init(accountIdentityHash: "a", recordType: "MTBookmark", recordName: "other",
                                             operation: .delete, generation: 9), token: old))
        session.finish("same", token: old)
        XCTAssertEqual(session.attempts["same"]?.accountIdentityHash, "b")
        XCTAssertEqual(session.attempts["same"]?.generation, 8)
        XCTAssertNil(session.attempts["other"])
    }
}
