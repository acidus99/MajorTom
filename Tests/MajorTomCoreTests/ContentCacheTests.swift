import GRDB
import XCTest
@testable import MajorTomCore

final class ContentCacheTests: XCTestCase {
    func testDefaultFileUsesContentCacheFilename() throws {
        let manager = ContentCacheStubFileManager(applicationSupport: URL(fileURLWithPath: "/tmp"))
        let url = try ContentCacheDatabase.defaultFileURL(fileManager: manager)

        XCTAssertEqual(ContentCacheDatabase.filename, "ContentCache.db")
        XCTAssertEqual(url.path, "/tmp/Major Tom/ContentCache.db")
    }

    func testSchemaUsesURLAsOnlyPrimaryKeyAndIncludesMIMEType() throws {
        let database = try ContentCacheDatabase(inMemory: ())
        let columns = try database.read { try $0.columns(in: "content_cache") }
        let primaryKeys = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('content_cache') WHERE pk > 0 ORDER BY pk"
            )
        }

        XCTAssertEqual(primaryKeys, ["url"])
        XCTAssertTrue(columns.map(\.name).contains("resource_type"))
        XCTAssertTrue(columns.map(\.name).contains("mime_type"))
    }

    func testFreshResponseRoundTripsAndIgnoresFragment() async throws {
        let database = try ContentCacheDatabase(inMemory: ())
        let cache = ContentCache(database: database)
        let receivedAt = Date(timeIntervalSince1970: 1_000)
        let response = makeResponse(
            url: "gemini://example.com/image.png#one",
            receivedAt: receivedAt
        )

        let result = try await cache.store(
            response,
            resourceType: .image,
            lifetime: 60,
            now: receivedAt
        )
        XCTAssertEqual(result, .stored)
        let loaded = try await cache.freshResponse(
            for: URL(string: "gemini://example.com/image.png#two")!,
            now: receivedAt.addingTimeInterval(59)
        )

        XCTAssertEqual(loaded?.url.absoluteString, "gemini://example.com/image.png")
        XCTAssertEqual(loaded?.status, 20)
        XCTAssertEqual(loaded?.meta, Data("image/png".utf8))
        XCTAssertEqual(loaded?.mimeType, "image/png")
        XCTAssertEqual(loaded?.body, Data([1, 2, 3]))
        XCTAssertEqual(loaded?.receivedAt, receivedAt)
    }

    func testExpiredResponseIsDeletedAndNeverReturned() async throws {
        let database = try ContentCacheDatabase(inMemory: ())
        let cache = ContentCache(database: database)
        let receivedAt = Date(timeIntervalSince1970: 1_000)
        let response = makeResponse(receivedAt: receivedAt)
        try await cache.store(response, resourceType: .image, lifetime: 60, now: receivedAt)

        let loaded = try await cache.freshResponse(
            for: response.url,
            now: receivedAt.addingTimeInterval(60)
        )
        XCTAssertNil(loaded)
        XCTAssertEqual(try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM content_cache")
        }, 0)
    }

    func testStoreReplacesClassificationForSameURL() async throws {
        let database = try ContentCacheDatabase(inMemory: ())
        let cache = ContentCache(database: database)
        let response = makeResponse()

        try await cache.store(response, resourceType: .favicon, lifetime: 60)
        try await cache.store(response, resourceType: .image, lifetime: 60)

        let rows = try database.read {
            try Row.fetchAll($0, sql: "SELECT url, resource_type FROM content_cache")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["resource_type"] as String?, ResourceType.image.rawValue)
    }

    func testRemoveAllOnlyRemovesRequestedResourceType() async throws {
        let database = try ContentCacheDatabase(inMemory: ())
        let cache = ContentCache(database: database)
        try await cache.store(makeResponse(url: "gemini://example.com/favicon.txt"), resourceType: .favicon, lifetime: 60)
        try await cache.store(makeResponse(url: "gemini://example.com/image.png"), resourceType: .image, lifetime: 60)

        try await cache.removeAll(ofType: .favicon)

        let favicon = try await cache.freshResponse(for: URL(string: "gemini://example.com/favicon.txt")!)
        let image = try await cache.freshResponse(for: URL(string: "gemini://example.com/image.png")!)
        XCTAssertNil(favicon)
        XCTAssertNotNil(image)
    }

    func testEntryLimitRejectsAndRemovesExistingResponse() async throws {
        let database = try ContentCacheDatabase(inMemory: ())
        let cache = ContentCache(database: database, maximumEntryBytes: 3)
        let small = makeResponse(body: Data([1, 2, 3]))
        let large = makeResponse(body: Data([1, 2, 3, 4]))
        try await cache.store(small, resourceType: .image, lifetime: 60)

        let result = try await cache.store(large, resourceType: .image, lifetime: 60)
        let loaded = try await cache.freshResponse(for: small.url)
        XCTAssertEqual(result, .tooLarge)
        XCTAssertNil(loaded)
    }

    func testTotalLimitEvictsLeastRecentlyAccessedResponse() async throws {
        let database = try ContentCacheDatabase(inMemory: ())
        let cache = ContentCache(database: database, maximumTotalBytes: 5)
        let first = makeResponse(url: "gemini://example.com/first.png", body: Data([1, 2, 3]))
        let second = makeResponse(url: "gemini://example.com/second.png", body: Data([4, 5, 6]))
        let start = Date(timeIntervalSince1970: 1_000)

        try await cache.store(first, resourceType: .image, lifetime: 60, now: start)
        try await cache.store(second, resourceType: .image, lifetime: 60, now: start.addingTimeInterval(1))

        let firstLoaded = try await cache.freshResponse(for: first.url, now: start.addingTimeInterval(2))
        let secondLoaded = try await cache.freshResponse(for: second.url, now: start.addingTimeInterval(2))
        XCTAssertNil(firstLoaded)
        XCTAssertNotNil(secondLoaded)
    }

    func testCheckpointAndCloseRemovesCompanionFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MajorTomContentCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(ContentCacheDatabase.filename)
        let database = try ContentCacheDatabase(fileURL: fileURL)
        let cache = ContentCache(database: database)
        try await cache.store(makeResponse(), resourceType: .image, lifetime: 60)

        try database.checkpointAndClose()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path + "-shm"))
    }

    private func makeResponse(
        url: String = "gemini://example.com/image.png",
        body: Data = Data([1, 2, 3]),
        receivedAt: Date = Date()
    ) -> ContentResponse {
        ContentResponse(
            url: URL(string: url)!,
            status: 20,
            meta: Data("image/png".utf8),
            mimeType: "image/png",
            body: body,
            receivedAt: receivedAt
        )
    }
}

private final class ContentCacheStubFileManager: FileManager, @unchecked Sendable {
    private let applicationSupport: URL

    init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [applicationSupport] : []
    }
}
