import Foundation

/// Persists bookmarks as one JSON document.
///
/// Mutations live on ``BookmarkCollection`` so they can be tested without touching a file;
/// this type is only the reader, the writer, and the serialisation point.
public actor BookmarkStore {
    private let fileURL: URL
    private var current: BookmarkCollection

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.bookmarkStore.decode(BookmarkCollection.self, from: data) {
            current = decoded
        } else {
            current = BookmarkCollection()
        }
    }

    public func collection() -> BookmarkCollection { current }

    /// Applies a change and writes the result.
    ///
    /// One funnel for every mutation, so no operation can forget to persist, and callers
    /// get the updated collection back to publish.
    @discardableResult
    public func update(_ change: @Sendable (inout BookmarkCollection) -> Void) throws -> BookmarkCollection {
        change(&current)
        try persist()
        return current
    }

    /// Replaces the local cache after CloudKit records have been merged. The local file
    /// remains complete and immediately usable while offline.
    @discardableResult
    public func replace(with collection: BookmarkCollection) throws -> BookmarkCollection {
        current = collection
        try persist()
        return current
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder.bookmarkStore.encode(current).write(to: fileURL, options: [.atomic])
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
