import Foundation

/// What is known about one capsule's favicon.
public struct FaviconRecord: Codable, Equatable, Sendable {
    public var endpoint: CapsuleEndpoint
    /// `nil` records a capsule that offers no favicon, so it is not probed again until
    /// the record goes stale. The RFC asks clients to remember this case explicitly.
    public var emoji: String?
    public var fetchedAt: Date

    public init(endpoint: CapsuleEndpoint, emoji: String?, fetchedAt: Date) {
        self.endpoint = endpoint
        self.emoji = emoji
        self.fetchedAt = fetchedAt
    }
}

public enum FaviconLookup: Equatable, Sendable {
    /// Never probed, or the record has expired: the caller may fetch.
    case unknown
    case known(String)
    /// Known to offer none, and still fresh: do not probe.
    case absent
}

/// Remembers each capsule's favicon for a while, so one glyph is not re-fetched on every
/// page view.
///
/// The RFC sets a floor of one hour and asks that the absence of a favicon be remembered
/// too. The default here is a week: a capsule's emoji is part of its identity and changes
/// about as often as its name, and re-probing every hour would put a request onto every
/// server a reader visits regularly for no benefit.
public actor FaviconStore {
    public static let defaultLifetime: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL
    private let lifetime: TimeInterval
    private var records: [CapsuleEndpoint: FaviconRecord]

    public init(fileURL: URL, lifetime: TimeInterval = FaviconStore.defaultLifetime) {
        self.fileURL = fileURL
        self.lifetime = lifetime
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.faviconStore.decode([FaviconRecord].self, from: data) {
            records = Dictionary(decoded.map { ($0.endpoint, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            // A corrupt or absent file is not an error: favicons are decoration, and
            // starting empty simply means everything is probed once more.
            records = [:]
        }
    }

    public func favicon(for endpoint: CapsuleEndpoint, now: Date = Date()) -> FaviconLookup {
        guard let record = records[endpoint],
              now.timeIntervalSince(record.fetchedAt) < lifetime else { return .unknown }
        guard let emoji = record.emoji else { return .absent }
        return .known(emoji)
    }

    /// Records what a probe found. `nil` means the capsule offers no favicon.
    public func record(_ emoji: String?, for endpoint: CapsuleEndpoint, at date: Date = Date()) throws {
        records[endpoint] = FaviconRecord(endpoint: endpoint, emoji: emoji, fetchedAt: date)
        try persist()
    }

    /// Every fresh favicon currently known, for callers that may display but not fetch.
    public func knownFavicons(now: Date = Date()) -> [CapsuleEndpoint: String] {
        var result: [CapsuleEndpoint: String] = [:]
        for (endpoint, record) in records {
            guard now.timeIntervalSince(record.fetchedAt) < lifetime,
                  let emoji = record.emoji else { continue }
            result[endpoint] = emoji
        }
        return result
    }

    public func removeAll() throws {
        records = [:]
        try persist()
    }

    public func recordCount() -> Int { records.count }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sorted = records.values.sorted {
            ($0.endpoint.host, $0.endpoint.port) < ($1.endpoint.host, $1.endpoint.port)
        }
        try JSONEncoder.faviconStore.encode(sorted).write(to: fileURL, options: [.atomic])
    }
}

private extension JSONEncoder {
    static var faviconStore: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var faviconStore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
