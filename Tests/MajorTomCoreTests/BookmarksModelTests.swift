import XCTest
@testable import MajorTomCore

final class BookmarksModelTests: XCTestCase {
    @MainActor
    func testFirstAccountClaimDrainsAlreadyAcceptedBookmarkAdd() async throws {
        let database = try MajorTomDatabase(inMemory: ())
        let store = try BookmarkStore(database: database)
        let activity = LocalPersistenceActivity()
        let model = BookmarksModel(store: store, cache: nil, activity: activity)
        await model.flushPendingWrites()
        let url = URL(string: "gemini://example.invalid/accepted")!
        model.add(title: "Accepted fixture", url: url)
        activity.isPreparingAccount = true
        try await model.prepareForFirstAccountClaim()
        let committed = try await store.reload()
        XCTAssertTrue(committed.contains(url: url), "Claim preparation must not discard an action accepted before its boundary")
        XCTAssertTrue(model.isBookmarked(url))
        XCTAssertEqual(activity.activeWrites, 0)
    }

    @MainActor
    func testReloadPublishesCommittedRepositoryWithoutManufacturingOutgoingIntent() async throws {
        let database = try MajorTomDatabase(inMemory: ())
        let account = "synthetic-account"
        let store = try BookmarkStore(database: database, accountIdentityHash: account)
        let model = BookmarksModel(store: store, cache: nil, activity: LocalPersistenceActivity())
        await model.flushPendingWrites()
        let repository = BookmarkRepository(database: database, accountIdentityHash: account)
        let url = URL(string: "gemini://example.invalid/committed")!
        _ = try repository.update { $0.add(title: "Committed fixture", url: url) }
        let cloud = CloudSyncRepository(database: database)
        let outgoing = try cloud.pendingChanges(for: account)
        await model.reload()
        XCTAssertTrue(model.isBookmarked(url))
        XCTAssertEqual(try cloud.pendingChanges(for: account), outgoing)
    }
}
