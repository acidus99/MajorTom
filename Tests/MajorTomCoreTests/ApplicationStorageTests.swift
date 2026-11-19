import XCTest
@testable import MajorTomCore

final class ApplicationStorageTests: XCTestCase {
    func testProductionCompositionReopensHistoricalFilesWithDurableData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ApplicationStorage(directory: directory)
        XCTAssertTrue(first.failures.isEmpty)
        let database = try XCTUnwrap(first.durable)
        let bookmarks = try BookmarkStore(database: database)
        let url = URL(string: "gemini://example.invalid/saved")!
        try await bookmarks.update { $0.add(title: "Saved fixture", url: url) }
        try database.checkpointAndClose()
        try first.session?.checkpointAndClose()
        try first.content?.checkpointAndClose()
        // This checks the actual composition path, not constants in isolation.
        for filename in ["MajorTom.db", "BFCache.db", "ContentCache.db"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path))
        }
        let reopened = ApplicationStorage(directory: directory)
        XCTAssertTrue(reopened.failures.isEmpty)
        let store = try BookmarkStore(database: XCTUnwrap(reopened.durable))
        let collection = await store.collection()
        XCTAssertTrue(collection.contains(url: url))
    }

    func testCorruptDurableStoreReportsFailureAndCannotCreateEmptyFallbackTrust() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid SQLite fixture".utf8).write(to: directory.appendingPathComponent("MajorTom.db"))
        let opened = ApplicationStorage(directory: directory)
        XCTAssertNil(opened.durable)
        XCTAssertNil(opened.trust)
        XCTAssertNotNil(opened.session)
        XCTAssertNotNil(opened.content)
        XCTAssertEqual(opened.failures.map(\.store), [.durable, .trust])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("trusted-identities.json").path))
    }
}
