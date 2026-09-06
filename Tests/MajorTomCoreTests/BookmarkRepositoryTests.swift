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
