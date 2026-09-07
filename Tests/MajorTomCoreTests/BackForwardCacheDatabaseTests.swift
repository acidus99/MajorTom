import GRDB
import XCTest
@testable import MajorTomCore

final class BackForwardCacheDatabaseTests: XCTestCase {
    func testSchemaHasOneTitleAndNoMIMETypeColumn() throws {
        let database = try BackForwardCacheDatabase(inMemory: ())
        let columns = try database.read { db in
            try db.columns(in: "browser_tab_history").map(\.name)
        }

        XCTAssertTrue(columns.contains("title"))
        XCTAssertFalse(columns.contains("document_title"))
        XCTAssertFalse(columns.contains("mime_type"))
    }

    func testDefaultFileUsesItsOwnDatabaseFilename() throws {
        let base = URL(fileURLWithPath: "/tmp")
        let manager = StubFileManager(applicationSupport: base)
        let url = try BackForwardCacheDatabase.defaultFileURL(fileManager: manager)

        XCTAssertEqual(BackForwardCacheDatabase.filename, "MajorTomBackForward.db")
        XCTAssertEqual(url.lastPathComponent, BackForwardCacheDatabase.filename)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Major Tom")
    }

    func testStoreRoundTripsResponseAndPresentationWithoutMIMEColumn() async throws {
        let database = try BackForwardCacheDatabase(inMemory: ())
        let store = BackForwardCacheStore(database: database)
        let image = URL(string: "gemini://example.com/photo.png")!
        let page = CachedPage(
            url: URL(string: "gemini://example.com/page")!,
            mimeType: "text/gemini",
            body: Data("# Page".utf8),
            completion: .complete,
            receivedAt: Date(timeIntervalSince1970: 123),
            title: "Page",
            documentTitle: "Ignored second title",
            responseStatus: 20,
            responseMeta: "text/gemini; charset=utf-8"
        )
        let entry = BackForwardEntry(
            url: page.url,
            title: "Page",
            favicon: "🚀",
            page: page,
            presentation: HistoryPresentationState(
                scrollY: 42,
                expandedImages: [image],
                collapsedPreformatted: [1, 3]
            )
        )

        try await store.save(entry, tabID: UUID(), position: 0)
        let stored = try await store.entry(id: entry.id)
        let loaded = try XCTUnwrap(stored)

        XCTAssertEqual(loaded.title, "Page")
        XCTAssertEqual(loaded.favicon, "🚀")
        XCTAssertEqual(loaded.page?.mimeType, "text/gemini")
        XCTAssertEqual(loaded.page?.body, page.body)
        XCTAssertEqual(loaded.presentation.scrollY, 42)
        XCTAssertEqual(loaded.presentation.expandedImages, [image])
        XCTAssertEqual(loaded.presentation.collapsedPreformatted, [1, 3])
    }

    func testCheckpointAndCloseFoldsWALIntoMainDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MajorTomBackForwardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent(BackForwardCacheDatabase.filename)
        let database = try BackForwardCacheDatabase(fileURL: fileURL)
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO browser_session (singleton, key_window_index, updated_at) VALUES (1, 0, ?)",
                arguments: [Date()]
            )
        }

        try database.checkpointAndClose()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path + "-shm"))

        let reopened = try BackForwardCacheDatabase(fileURL: fileURL)
        XCTAssertEqual(try reopened.read {
            try Int.fetchOne($0, sql: "SELECT key_window_index FROM browser_session")
        }, 0)
        try reopened.checkpointAndClose()
    }
}

private final class StubFileManager: FileManager, @unchecked Sendable {
    private let applicationSupport: URL

    init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [applicationSupport] : []
    }
}
