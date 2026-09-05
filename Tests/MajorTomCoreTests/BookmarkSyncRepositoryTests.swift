import Foundation
import GRDB
import XCTest
@testable import MajorTomCore

final class BookmarkSyncRepositoryTests: XCTestCase {
    func testStateRoundTripsPerRecordIncludingFaviconAndTombstone() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BookmarkSyncRepository(database: database)
        var collection = BookmarkCollection()
        let bookmark = collection.add(
            title: "Saved",
            url: URL(string: "gemini://example.com/")!,
            favicon: BookmarkFaviconSnapshot(
                emoji: nil,
                fetchedAt: Date(timeIntervalSince1970: 100)
            )
        )
        let original = SyncedBookmarks(collection: collection, modifiedAt: Date(timeIntervalSince1970: 10))
        collection.remove(bookmarkWith: bookmark.id)
        let tombstoned = original.reconciled(with: collection, at: Date(timeIntervalSince1970: 20))

        try repository.replace(with: tombstoned)

        XCTAssertEqual(try repository.state(), tombstoned)
    }

    func testOneChangedCloudRecordWritesOneSQLiteRow() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BookmarkSyncRepository(database: database)
        var collection = BookmarkCollection()
        collection.add(title: "One", url: URL(string: "gemini://one.example/")!)
        collection.add(title: "Two", url: URL(string: "gemini://two.example/")!)
        let original = SyncedBookmarks(collection: collection, modifiedAt: Date(timeIntervalSince1970: 10))
        try repository.replace(with: original)
        let before = try database.read { try Int.fetchOne($0, sql: "SELECT total_changes()")! }

        var changed = original
        changed.bookmarks[0].title = "Renamed"
        changed.bookmarks[0].modifiedAt = Date(timeIntervalSince1970: 20)
        try repository.replace(with: changed)
        let after = try database.read { try Int.fetchOne($0, sql: "SELECT total_changes()")! }

        XCTAssertEqual(after - before, 1)
    }

    func testLegacyMetadataImportIsIdempotent() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BookmarkSyncRepository(database: database)
        var collection = BookmarkCollection()
        collection.add(title: "Saved", url: URL(string: "gemini://example.com/")!)
        let state = SyncedBookmarks(collection: collection, modifiedAt: Date())

        try repository.importLegacyState(state)
        try repository.importLegacyState(state)

        XCTAssertEqual(try repository.state(), state)
    }
}
