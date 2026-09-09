import Foundation
import XCTest
@testable import MajorTomCore

final class BrowsingHistoryRepositoryTests: XCTestCase {
    func testRecordUpsertsOneRowPerURLAndMovesItToTheTop() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BrowsingHistoryRepository(database: database)
        let first = URL(string: "gemini://example.com/first")!
        let second = URL(string: "gemini://example.com/second")!
        let start = Date(timeIntervalSince1970: 1_000_000)

        try repository.record(first, title: "First title", at: start)
        try repository.record(second, title: "Second title", at: start.addingTimeInterval(10))
        try repository.record(first, title: "Updated title", at: start.addingTimeInterval(20))

        let entries = try repository.entries()
        XCTAssertEqual(entries.map(\.url), [first, second])
        XCTAssertEqual(entries.map(\.visitCount), [2, 1])
        XCTAssertEqual(entries.map(\.title), ["Updated title", "Second title"])
        XCTAssertEqual(entries.first?.visitedAt, start.addingTimeInterval(20))
    }

    func testRecordWithoutATitlePreservesTheLastObservedTitle() throws {
        let repository = BrowsingHistoryRepository(database: try MajorTomDatabase(inMemory: ()))
        let url = URL(string: "gemini://example.com/page")!

        try repository.record(url, title: "A Page", at: Date(timeIntervalSince1970: 1))
        try repository.record(url, at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(try repository.entries().first?.title, "A Page")
    }

    func testRemoveDeletesOnlySelectedURLs() throws {
        let repository = BrowsingHistoryRepository(database: try MajorTomDatabase(inMemory: ()))
        let kept = URL(string: "gemini://example.com/kept")!
        let removed = URL(string: "gemini://example.com/removed")!
        try repository.record(kept)
        try repository.record(removed)

        try repository.remove(urls: [removed])

        XCTAssertEqual(try repository.entries().map(\.url), [kept])
    }

    func testRecordingPrunesEntriesOlderThanOneYear() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BrowsingHistoryRepository(database: database)
        let now = Date(timeIntervalSince1970: 100_000_000)
        let old = URL(string: "gemini://example.com/old")!
        let current = URL(string: "gemini://example.com/current")!

        try repository.record(
            old,
            at: now.addingTimeInterval(-BrowsingHistoryRepository.retention - 1)
        )
        try repository.record(current, at: now)

        XCTAssertEqual(try repository.entries().map(\.url), [current])
    }

    func testLegacyImportCollapsesDuplicateURLsAndKeepsLatestVisit() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BrowsingHistoryRepository(database: database)
        let url = URL(string: "gemini://example.com/")!
        let recent = Date()

        try repository.importLegacyVisits([
            (url, recent.addingTimeInterval(-10)),
            (url, recent)
        ])

        let entry = try XCTUnwrap(repository.entries().first)
        XCTAssertEqual(entry.url, url)
        XCTAssertEqual(entry.visitCount, 2)
        XCTAssertEqual(entry.visitedAt.timeIntervalSince(recent), 0, accuracy: 0.001)
    }

    func testLegacyImportIsIdempotentAcrossARemovalCrashWindow() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = BrowsingHistoryRepository(database: database)
        let url = URL(string: "gemini://example.com/")!
        let visits = [(url: url, visitedAt: Date())]

        try repository.importLegacyVisits(visits)
        try repository.importLegacyVisits(visits)

        XCTAssertEqual(try repository.entries().first?.visitCount, 1)
    }
}
