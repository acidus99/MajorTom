import Foundation

/// Serializes bookmark mutations and delegates persistence to JSON (legacy/tests) or the
/// row-level SQLite repository used by the application.
///
/// Mutations live on ``BookmarkCollection`` so they can be tested without touching a file;
/// this type is only the reader, the writer, and the serialisation point.
public actor BookmarkStore {
    private enum Backend: Sendable {
        case json(URL)
        case sqlite(BookmarkRepository)
    }

    private let backend: Backend
    private var current: BookmarkCollection

    public init(fileURL: URL) {
        backend = .json(fileURL)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.bookmarkStore.decode(BookmarkCollection.self, from: data) {
            current = decoded
        } else {
            current = BookmarkCollection()
        }
    }

    public init(database: MajorTomDatabase, accountIdentityHash: String? = nil) throws {
        let repository = BookmarkRepository(
            database: database,
            accountIdentityHash: accountIdentityHash
        )
        backend = .sqlite(repository)
        current = try repository.collection()
    }

    public func collection() -> BookmarkCollection { current }

    /// Applies a change and writes the result.
    ///
    /// One funnel for every mutation, so no operation can forget to persist, and callers
    /// get the updated collection back to publish.
    @discardableResult
    public func update(_ change: @Sendable (inout BookmarkCollection) -> Void) throws -> BookmarkCollection {
        var updated = current
        change(&updated)
        try persist(updated)
        current = updated
        return current
    }

    /// Replaces the local cache after CloudKit records have been merged. The local file
    /// remains complete and immediately usable while offline.
    @discardableResult
    public func replace(with collection: BookmarkCollection) throws -> BookmarkCollection {
        try persist(collection)
        current = collection
        return current
    }

    /// Transactionally imports the old JSON file into SQLite. Returns true when the file
    /// was decoded and SQLite either imported it or had already completed that import.
    public func importLegacyJSON(at fileURL: URL) throws -> Bool {
        guard case .sqlite(let repository) = backend,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.bookmarkStore.decode(
                BookmarkCollection.self,
                from: data
              ) else { return false }
        try repository.importLegacyCollection(decoded)
        current = try repository.collection()
        return true
    }

    private func persist(_ collection: BookmarkCollection) throws {
        switch backend {
        case .json(let fileURL):
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder.bookmarkStore.encode(collection).write(to: fileURL, options: [.atomic])
        case .sqlite(let repository):
            try repository.replace(with: collection)
        }
    }
}

private extension JSONEncoder {
    static var bookmarkStore: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var bookmarkStore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
