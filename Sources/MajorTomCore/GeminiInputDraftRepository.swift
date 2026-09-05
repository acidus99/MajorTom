import Foundation
import GRDB

public struct GeminiInputDraft: Equatable, Sendable {
    public let promptURL: URL
    public let text: String
    public let updatedAt: Date
    public let expiresAt: Date
}

/// Durable, local-only text that was typed into a Gemini input prompt but not submitted.
public struct GeminiInputDraftRepository: Sendable {
    public static let lifetime: TimeInterval = 14 * 24 * 60 * 60

    private let database: MajorTomDatabase

    public init(database: MajorTomDatabase) {
        self.database = database
    }

    public func save(_ text: String, for promptURL: URL, at date: Date = Date()) throws {
        guard !text.isEmpty else {
            try remove(for: promptURL)
            return
        }
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO gemini_input_drafts
                        (prompt_url, text, updated_at, expires_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(prompt_url) DO UPDATE SET
                        text = excluded.text,
                        updated_at = excluded.updated_at,
                        expires_at = excluded.expires_at
                    """,
                arguments: [
                    promptURL.absoluteString,
                    text,
                    date,
                    date.addingTimeInterval(Self.lifetime)
                ]
            )
            try Self.pruneExpired(at: date, in: db)
        }
    }

    public func draft(for promptURL: URL, at date: Date = Date()) throws -> GeminiInputDraft? {
        try database.write { db in
            try Self.pruneExpired(at: date, in: db)
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT prompt_url, text, updated_at, expires_at
                    FROM gemini_input_drafts
                    WHERE prompt_url = ?
                    """,
                arguments: [promptURL.absoluteString]
            ), let storedURL = URL(string: row["prompt_url"]) else { return nil }
            return GeminiInputDraft(
                promptURL: storedURL,
                text: row["text"],
                updatedAt: row["updated_at"],
                expiresAt: row["expires_at"]
            )
        }
    }

    public func remove(for promptURL: URL) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM gemini_input_drafts WHERE prompt_url = ?",
                arguments: [promptURL.absoluteString]
            )
        }
    }

    public func removeAll() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM gemini_input_drafts")
        }
    }

    private static func pruneExpired(at date: Date, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM gemini_input_drafts WHERE expires_at <= ?",
            arguments: [date]
        )
    }
}
