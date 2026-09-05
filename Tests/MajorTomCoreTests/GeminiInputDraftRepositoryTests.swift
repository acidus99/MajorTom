import Foundation
import XCTest
@testable import MajorTomCore

final class GeminiInputDraftRepositoryTests: XCTestCase {
    func testDraftSurvivesDatabaseReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(MajorTomDatabase.filename)
        let promptURL = URL(string: "gemini://example.com/post")!
        let savedAt = Date(timeIntervalSince1970: 1_000_000)

        do {
            let database = try MajorTomDatabase(fileURL: fileURL)
            try GeminiInputDraftRepository(database: database).save(
                "unfinished post",
                for: promptURL,
                at: savedAt
            )
        }

        let reopened = try MajorTomDatabase(fileURL: fileURL)
        let draft = try GeminiInputDraftRepository(database: reopened).draft(
            for: promptURL,
            at: savedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(draft?.text, "unfinished post")
        XCTAssertEqual(draft?.updatedAt, savedAt)
    }

    func testSavingAgainReplacesTheDraft() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = GeminiInputDraftRepository(database: database)
        let promptURL = URL(string: "gemini://example.com/post")!
        let start = Date(timeIntervalSince1970: 1_000_000)

        try repository.save("first", for: promptURL, at: start)
        try repository.save("second", for: promptURL, at: start.addingTimeInterval(10))

        XCTAssertEqual(
            try repository.draft(for: promptURL, at: start.addingTimeInterval(20))?.text,
            "second"
        )
    }

    func testExpiredDraftIsDiscarded() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = GeminiInputDraftRepository(database: database)
        let promptURL = URL(string: "gemini://example.com/post")!
        let start = Date(timeIntervalSince1970: 1_000_000)

        try repository.save("old", for: promptURL, at: start)

        XCTAssertNil(try repository.draft(
            for: promptURL,
            at: start.addingTimeInterval(GeminiInputDraftRepository.lifetime)
        ))
    }

    func testEmptyDraftRemovesStoredText() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = GeminiInputDraftRepository(database: database)
        let promptURL = URL(string: "gemini://example.com/post")!

        try repository.save("text", for: promptURL)
        try repository.save("", for: promptURL)

        XCTAssertNil(try repository.draft(for: promptURL))
    }
}
