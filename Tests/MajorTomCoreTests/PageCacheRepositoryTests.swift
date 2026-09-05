import Foundation
import GRDB
import XCTest
@testable import MajorTomCore

final class PageCacheRepositoryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private let one = URL(string: "gemini://example.com/one")!
    private let two = URL(string: "gemini://example.com/two")!

    func testPageRoundTripsAndReadTouchesLRU() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = PageCacheRepository(database: database)
        try repository.store(page(one, body: "hello"), accessedAt: epoch)

        let loaded = try repository.page(for: one, accessedAt: epoch.addingTimeInterval(10))

        XCTAssertEqual(loaded, page(one, body: "hello"))
        let accessedAt = try database.read { db in
            try Date.fetchOne(db, sql: "SELECT last_accessed_at FROM page_cache WHERE url = ?", arguments: [one.absoluteString])
        }
        XCTAssertEqual(accessedAt, epoch.addingTimeInterval(10))
    }

    func testTouchUpdatesLRUWithoutReadingTheBody() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = PageCacheRepository(database: database)
        try repository.store(page(one, body: "hello"), accessedAt: epoch)

        try repository.touch(one, accessedAt: epoch.addingTimeInterval(20))

        let accessedAt = try database.read { db in
            try Date.fetchOne(db, sql: "SELECT last_accessed_at FROM page_cache WHERE url = ?", arguments: [one.absoluteString])
        }
        XCTAssertEqual(accessedAt, epoch.addingTimeInterval(20))
    }

    func testOversizedRepresentationIsNotCached() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = PageCacheRepository(database: database, maximumEntryBytes: 4)

        XCTAssertEqual(try repository.store(page(one, body: "12345"), accessedAt: epoch), .tooLarge)
        XCTAssertNil(try repository.page(for: one))
    }

    func testLeastRecentlyUsedPagesAreEvictedToTotalBudget() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = PageCacheRepository(database: database, maximumTotalBytes: 10)
        try repository.store(page(one, body: "123456"), accessedAt: epoch)
        try repository.store(page(two, body: "abcdef"), accessedAt: epoch.addingTimeInterval(1))

        XCTAssertNil(try repository.page(for: one))
        XCTAssertNotNil(try repository.page(for: two))
    }

    func testMaintenanceRemovesPagesPastMaximumAge() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = PageCacheRepository(database: database, maximumAge: 100)
        try repository.store(page(one, body: "old"), accessedAt: epoch)

        try repository.performMaintenance(now: epoch.addingTimeInterval(101))

        XCTAssertNil(try repository.page(for: one))
    }

    func testFullTextSearchFindsCachedPageContentAndTitle() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = PageCacheRepository(database: database)
        try repository.store(page(one, body: "A capsule about telescope mirrors", title: "Astronomy"), accessedAt: epoch)
        try repository.store(page(two, body: "Cooking notes", title: "Kitchen"), accessedAt: epoch)

        XCTAssertEqual(try repository.search("telescope").map(\.url), [one])
        XCTAssertEqual(try repository.search("Astro").map(\.url), [one])
    }

    private func page(_ url: URL, body: String, title: String? = nil) -> CachedPage {
        CachedPage(
            url: url,
            mimeType: "text/gemini",
            body: Data(body.utf8),
            completion: .complete,
            receivedAt: epoch,
            title: title,
            documentTitle: title,
            responseStatus: 20,
            responseMeta: "text/gemini"
        )
    }
}
