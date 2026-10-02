import Foundation
import GRDB
import XCTest
@testable import MajorTomCore

final class BookmarkRepositoryTests: XCTestCase {
    func testCollectionRoundTripsFoldersOrderAndFaviconStates() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BookmarkRepository(database: database)
        var collection = BookmarkCollection()
        let reading = collection.addFolder(named: "Reading")!
        collection.add(
            title: "Emoji",
            url: URL(string: "gemini://emoji.example/")!,
            toFolderWith: reading.id,
            favicon: BookmarkFaviconSnapshot(
                emoji: "🚀",
                fetchedAt: Date(timeIntervalSince1970: 100)
            )
        )
        collection.add(
            title: "None",
            url: URL(string: "gemini://none.example/")!,
            favicon: BookmarkFaviconSnapshot(
                emoji: nil,
                fetchedAt: Date(timeIntervalSince1970: 200)
            )
        )

        try repository.replace(with: collection)
        let loaded = try repository.collection()

        XCTAssertEqual(loaded.folders.map(\.name), ["Favorites", "Reading"])
        XCTAssertEqual(loaded.folders[1].bookmarks.first?.favicon?.emoji, "🚀")
        XCTAssertNotNil(loaded.favorites.bookmarks.first?.favicon)
        XCTAssertNil(loaded.favorites.bookmarks.first?.favicon?.emoji)
    }

    func testChangingOneTitleWritesOnlyOneRow() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BookmarkRepository(database: database)
        var collection = BookmarkCollection()
        let first = collection.add(title: "One", url: URL(string: "gemini://one.example/")!)
        collection.add(title: "Two", url: URL(string: "gemini://two.example/")!)
        try repository.replace(with: collection)
        let before = try database.read { try Int.fetchOne($0, sql: "SELECT total_changes()")! }

        collection.rename(bookmarkWith: first.id, to: "Renamed")
        try repository.replace(with: collection)
        let after = try database.read { try Int.fetchOne($0, sql: "SELECT total_changes()")! }

        XCTAssertEqual(after - before, 1)
    }

    func testPersistedOrderKeysPreserveVisibleOrderForPartialCloudBatch() throws {
        // Prevents partial CloudKit batches from mixing fabricated numeric positions with
        // the repository's fractional keys and reordering untouched bookmarks.
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BookmarkRepository(database: database)
        var collection = BookmarkCollection()
        let first = collection.add(title: "First", url: URL(string: "gemini://first.example/")!)
        let second = collection.add(title: "Second", url: URL(string: "gemini://second.example/")!)
        let third = collection.add(title: "Third", url: URL(string: "gemini://third.example/")!)

        try repository.replace(with: collection)

        let keys = try repository.bookmarkOrderKeys()
        XCTAssertEqual(
            [first.id, second.id, third.id].sorted { keys[$0]! < keys[$1]! },
            [first.id, second.id, third.id]
        )
        XCTAssertTrue(keys.values.allSatisfy { !$0.allSatisfy(\.isNumber) })
    }

    func testLegacyImportIsIdempotent() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BookmarkRepository(database: database)
        var collection = BookmarkCollection()
        collection.add(title: "Saved", url: URL(string: "gemini://example.com/")!)

        try repository.importLegacyCollection(collection)
        try repository.importLegacyCollection(collection)

        XCTAssertEqual(try repository.collection().allBookmarks.count, 1)
    }

    func testRemovingFolderCascadesItsBookmarks() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BookmarkRepository(database: database)
        var collection = BookmarkCollection()
        let folder = collection.addFolder(named: "Reading")!
        collection.add(
            title: "Saved",
            url: URL(string: "gemini://example.com/")!,
            toFolderWith: folder.id
        )
        try repository.replace(with: collection)

        collection.removeFolder(with: folder.id)
        try repository.replace(with: collection)

        XCTAssertTrue(try repository.collection().allBookmarks.isEmpty)
        try database.validate()
    }

    func testAccountsHaveIndependentBookmarkCollectionsAndOutboxes() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let first = BookmarkRepository(database: database, accountIdentityHash: "first")
        let second = BookmarkRepository(database: database, accountIdentityHash: "second")
        var firstCollection = BookmarkCollection()
        firstCollection.add(title: "First", url: URL(string: "gemini://first.example/")!)
        var secondCollection = BookmarkCollection()
        secondCollection.add(title: "Second", url: URL(string: "https://second.example/path?q=1")!)

        try first.replace(with: firstCollection)
        try second.replace(with: secondCollection)

        XCTAssertEqual(try first.collection().allBookmarks.map(\.title), ["First"])
        XCTAssertEqual(try second.collection().allBookmarks.map(\.title), ["Second"])
        let cloud = CloudSyncRepository(database: database)
        XCTAssertEqual(try cloud.pendingChanges(for: "first").count, 2)
        XCTAssertEqual(try cloud.pendingChanges(for: "second").count, 2)
    }

    func testRemoteReplacementDoesNotEchoIntoOutbox() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BookmarkRepository(database: database, accountIdentityHash: "account")
        var collection = BookmarkCollection()
        collection.add(title: "Remote", url: URL(string: "spartan://example/path")!)

        try repository.replaceFromCloud(with: collection)

        XCTAssertFalse(try CloudSyncRepository(database: database)
            .hasPendingChanges(for: "account"))
    }

    func testLocalRenameKeepsCommittedCloudSnapshotWhenOldServerValueIsApplied() throws {
        // Prevents the production-prefix bug: the old server value arrived after a
        // local rename and previously changed the value later uploaded to CloudKit.
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BookmarkRepository(database: database, accountIdentityHash: "account")
        var original = BookmarkCollection()
        let bookmark = original.add(
            title: "Station", url: URL(string: "gemini://station.example/")!
        )
        try repository.replace(with: original)
        let oldServerCollection = try repository.collection()

        var renamed = try repository.collection()
        renamed.rename(bookmarkWith: bookmark.id, to: "PRODUCTION - Station")
        try repository.replace(with: renamed)

        // This emulates receipt of an older fetched value. The coordinator normally
        // retains local pending intent; this assertion protects the deeper invariant
        // that even an accidental replacement cannot rewrite the durable send payload.
        try repository.replaceFromCloud(with: oldServerCollection)

        let pending = try XCTUnwrap(try CloudSyncRepository(database: database)
            .pendingChange(recordName: bookmark.id.uuidString, for: "account"))
        let payload = try XCTUnwrap(pending.modelPayload)
        let encoded = try JSONDecoder().decode(CloudBookmarkPayload.self, from: payload)
        XCTAssertEqual(encoded.title, "PRODUCTION - Station")
    }

    func testClaimingRowsMovesUnownedCollectionToFirstAccount() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let unowned = BookmarkRepository(database: database)
        var collection = BookmarkCollection()
        collection.add(title: "Existing", url: URL(string: "gemini://existing.example/")!)
        try unowned.replace(with: collection)

        let account = BookmarkRepository(database: database, accountIdentityHash: "account")
        try account.claimUnownedRows()

        XCTAssertEqual(try account.collection().allBookmarks.map(\.title), ["Existing"])
        XCTAssertTrue(try unowned.collection().allBookmarks.isEmpty)
    }
}
