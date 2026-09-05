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
}
