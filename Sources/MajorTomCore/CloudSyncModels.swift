import Foundation

/// Coalesces paged cloud results without assuming that a changing server returns each
/// identifier only once. Package-visible so the CloudKit adapter and its model tests
/// share the exact duplicate-resolution rule.
package func newestValuesByID<Value, ID: Hashable>(
    _ values: [Value],
    id: (Value) -> ID,
    modifiedAt: (Value) -> Date?
) -> [ID: Value] {
    var result: [ID: Value] = [:]
    for candidate in values {
        let identifier = id(candidate)
        guard let existing = result[identifier] else {
            result[identifier] = candidate
            continue
        }
        if (modifiedAt(candidate) ?? .distantPast) >= (modifiedAt(existing) ?? .distantPast) {
            result[identifier] = candidate
        }
    }
    return result
}

/// A versioned, conflict-resolvable preferences snapshot for private iCloud sync.
///
/// The timestamp belongs to the payload rather than CloudKit's record metadata so the
/// same merge rule can be exercised locally and in tests. A device that has never saved
/// preferences uses no snapshot at all; it therefore cannot replace an established
/// remote configuration with freshly-created defaults.
public struct SyncedBrowserPreferenceValues: Codable, Equatable, Sendable {
    public var homepage: String
    public var searchProvider: SearchProvider
    public var customSearchEndpoint: String
    public var contentTheme: ContentTheme
    public var contentWidth: ContentWidth
    public var automaticallyLoadsSameCapsuleImages: Bool
    public var automaticallyLoadsDataImages: Bool
    public var renderingOptions: HTMLRenderingOptions
    public var showsFavicons: Bool

    public init(preferences: BrowserPreferences) {
        homepage = preferences.homepage
        searchProvider = preferences.searchProvider
        customSearchEndpoint = preferences.customSearchEndpoint
        contentTheme = preferences.contentTheme
        contentWidth = preferences.contentWidth
        automaticallyLoadsSameCapsuleImages = preferences.automaticallyLoadsSameCapsuleImages
        automaticallyLoadsDataImages = preferences.automaticallyLoadsDataImages
        renderingOptions = preferences.renderingOptions
        showsFavicons = preferences.showsFavicons
    }

    public func applying(to local: BrowserPreferences) -> BrowserPreferences {
        var result = local
        result.homepage = homepage
        result.searchProvider = searchProvider
        result.customSearchEndpoint = customSearchEndpoint
        result.contentTheme = contentTheme
        result.contentWidth = contentWidth
        result.automaticallyLoadsSameCapsuleImages = automaticallyLoadsSameCapsuleImages
        result.automaticallyLoadsDataImages = automaticallyLoadsDataImages
        result.renderingOptions = renderingOptions
        result.showsFavicons = showsFavicons
        return result
    }
}

public struct SyncedBrowserPreferences: Codable, Equatable, Sendable {
    public var values: SyncedBrowserPreferenceValues
    public var modifiedAt: Date

    public init(preferences: BrowserPreferences, modifiedAt: Date) {
        values = SyncedBrowserPreferenceValues(preferences: preferences)
        self.modifiedAt = modifiedAt
    }

    public func applying(to local: BrowserPreferences) -> BrowserPreferences {
        values.applying(to: local)
    }

    public func shouldReplace(_ local: SyncedBrowserPreferences?) -> Bool {
        guard let local else { return true }
        return modifiedAt > local.modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case values
        // Present in the first CloudKit implementation. Decoding it migrates the
        // synchronized fields without importing its machine-local proxy and chrome.
        case preferences
        case modifiedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        if let values = try container.decodeIfPresent(
            SyncedBrowserPreferenceValues.self,
            forKey: .values
        ) {
            self.values = values
        } else {
            let legacy = try container.decode(BrowserPreferences.self, forKey: .preferences)
            values = SyncedBrowserPreferenceValues(preferences: legacy)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}

// MARK: - Record-level bookmarks

public struct SyncedBookmarkFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var order: Int
    public var modifiedAt: Date
    public var deletedAt: Date?

    public init(id: UUID, name: String, order: Int, modifiedAt: Date, deletedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.order = order
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }
}

public struct SyncedBookmark: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var addedAt: Date
    public var folderID: UUID
    public var order: Int
    public var modifiedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID,
        title: String,
        url: URL,
        addedAt: Date,
        folderID: UUID,
        order: Int,
        modifiedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.addedAt = addedAt
        self.folderID = folderID
        self.order = order
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }
}

public struct SyncedBookmarks: Codable, Equatable, Sendable {
    public var folders: [SyncedBookmarkFolder]
    public var bookmarks: [SyncedBookmark]

    public init(folders: [SyncedBookmarkFolder] = [], bookmarks: [SyncedBookmark] = []) {
        self.folders = folders
        self.bookmarks = bookmarks
    }

    public init(collection: BookmarkCollection, modifiedAt: Date) {
        folders = collection.folders.enumerated().map { index, folder in
            SyncedBookmarkFolder(
                id: folder.id,
                name: folder.name,
                order: index,
                modifiedAt: modifiedAt
            )
        }
        bookmarks = collection.folders.flatMap { folder in
            folder.bookmarks.enumerated().map { index, bookmark in
                SyncedBookmark(
                    id: bookmark.id,
                    title: bookmark.title,
                    url: bookmark.url,
                    addedAt: bookmark.addedAt,
                    folderID: folder.id,
                    order: index,
                    modifiedAt: modifiedAt
                )
            }
        }
    }

    public func reconciled(with collection: BookmarkCollection, at date: Date) -> Self {
        let current = Self(collection: collection, modifiedAt: date)
        let oldFolders = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let oldBookmarks = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.id, $0) })

        var nextFolders = current.folders.map { incoming in
            guard let old = oldFolders[incoming.id], old.deletedAt == nil,
                  old.name == incoming.name, old.order == incoming.order else { return incoming }
            return old
        }
        let currentFolderIDs = Set(current.folders.map(\.id))
        nextFolders += folders.filter { !currentFolderIDs.contains($0.id) }.map { old in
            guard old.deletedAt == nil else { return old }
            var tombstone = old
            tombstone.modifiedAt = date
            tombstone.deletedAt = date
            return tombstone
        }

        var nextBookmarks = current.bookmarks.map { incoming in
            guard let old = oldBookmarks[incoming.id], old.deletedAt == nil,
                  old.title == incoming.title, old.url == incoming.url,
                  old.addedAt == incoming.addedAt, old.folderID == incoming.folderID,
                  old.order == incoming.order else { return incoming }
            return old
        }
        let currentBookmarkIDs = Set(current.bookmarks.map(\.id))
        nextBookmarks += bookmarks.filter { !currentBookmarkIDs.contains($0.id) }.map { old in
            guard old.deletedAt == nil else { return old }
            var tombstone = old
            tombstone.modifiedAt = date
            tombstone.deletedAt = date
            return tombstone
        }
        return Self(folders: nextFolders, bookmarks: nextBookmarks)
    }

    public func merging(_ other: Self) -> Self {
        Self(
            folders: Self.latest(folders + other.folders),
            bookmarks: Self.latest(bookmarks + other.bookmarks)
        )
    }

    public var collection: BookmarkCollection {
        var activeFolders = folders.filter { $0.deletedAt == nil }.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id.uuidString < $1.id.uuidString
        }
        // A previously-unsynchronized Mac starts with its own synthesized Favorites
        // folder. On first merge prefer the oldest cloud folder and suppress duplicates;
        // the next reconciliation writes tombstones for the extras.
        let favorites = activeFolders.filter { $0.name == BookmarkCollection.favoritesName }
        if let canonical = favorites.min(by: { $0.modifiedAt < $1.modifiedAt }) {
            activeFolders.removeAll {
                $0.name == BookmarkCollection.favoritesName && $0.id != canonical.id
            }
        }
        let activeBookmarks = bookmarks.filter { $0.deletedAt == nil }
        return BookmarkCollection(folders: activeFolders.map { folder in
            BookmarkFolder(
                id: folder.id,
                name: folder.name,
                bookmarks: activeBookmarks.filter { $0.folderID == folder.id }.sorted {
                    if $0.order != $1.order { return $0.order < $1.order }
                    return $0.id.uuidString < $1.id.uuidString
                }.map {
                    Bookmark(id: $0.id, title: $0.title, url: $0.url, addedAt: $0.addedAt)
                }
            )
        })
    }

    private static func latest<Record: Identifiable>(_ records: [Record]) -> [Record]
    where Record.ID == UUID, Record: CloudModifiedRecord {
        var result: [UUID: Record] = [:]
        for record in records where result[record.id]?.cloudModifiedAt ?? .distantPast < record.cloudModifiedAt {
            result[record.id] = record
        }
        return Array(result.values)
    }
}

public protocol CloudModifiedRecord {
    var cloudModifiedAt: Date { get }
}

extension SyncedBookmarkFolder: CloudModifiedRecord {
    public var cloudModifiedAt: Date { modifiedAt }
}

extension SyncedBookmark: CloudModifiedRecord {
    public var cloudModifiedAt: Date { modifiedAt }
}

// MARK: - Conflict-safe server trust

public struct SyncedServerTrustDecision: Codable, Equatable, Identifiable, Sendable {
    public var endpoint: CapsuleEndpoint
    public var publicKeySHA256: String
    public var firstTrustedAt: Date
    public var modifiedAt: Date
    public var deletedAt: Date?

    public var id: String {
        "\(endpoint.host.lowercased()):\(endpoint.port)|\(publicKeySHA256.lowercased())"
    }

    public init(
        endpoint: CapsuleEndpoint,
        publicKeySHA256: String,
        firstTrustedAt: Date,
        modifiedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.endpoint = endpoint
        self.publicKeySHA256 = publicKeySHA256.lowercased()
        self.firstTrustedAt = firstTrustedAt
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }
}

public struct SyncedServerTrust: Codable, Equatable, Sendable {
    public var decisions: [SyncedServerTrustDecision]

    public init(decisions: [SyncedServerTrustDecision] = []) {
        self.decisions = decisions
    }

    public func reconciled(with identities: [TrustedServerIdentity], at date: Date) -> Self {
        let userIdentities = identities.filter { $0.source == .user }
        let current = userIdentities.map {
            SyncedServerTrustDecision(
                endpoint: $0.endpoint,
                publicKeySHA256: $0.publicKeySHA256,
                firstTrustedAt: $0.firstTrustedAt,
                modifiedAt: date
            )
        }
        let currentIDs = Set(current.map(\.id))
        let oldByID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.id, $0) })
        var next = current.map { incoming -> SyncedServerTrustDecision in
            guard let old = oldByID[incoming.id], old.deletedAt == nil else { return incoming }
            return old
        }
        next += decisions.filter { !currentIDs.contains($0.id) }.map { old in
            guard old.deletedAt == nil else { return old }
            var tombstone = old
            tombstone.modifiedAt = date
            tombstone.deletedAt = date
            return tombstone
        }
        return Self(decisions: next)
    }

    public func merging(_ other: Self) -> Self {
        var latest: [String: SyncedServerTrustDecision] = [:]
        for decision in decisions + other.decisions
        where latest[decision.id]?.modifiedAt ?? .distantPast < decision.modifiedAt {
            latest[decision.id] = decision
        }
        return Self(decisions: Array(latest.values))
    }

    public var activeByEndpoint: [CapsuleEndpoint: [SyncedServerTrustDecision]] {
        Dictionary(grouping: decisions.filter { $0.deletedAt == nil }, by: \.endpoint)
    }

    public var conflictingEndpoints: Set<CapsuleEndpoint> {
        Set(activeByEndpoint.compactMap { endpoint, decisions in
            Set(decisions.map(\.publicKeySHA256)).count > 1 ? endpoint : nil
        })
    }
}

/// The small, privacy-conscious representation published for Safari-like iCloud Tabs.
/// It intentionally excludes history, cached response bodies, scroll position and
/// back/forward state: opening a remote tab is a new navigation on this Mac.
public struct CloudTabSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL

    public init(id: UUID, title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// One device owns one CloudKit record and replaces only that record as its tabs change.
public struct CloudTabDeviceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var deviceID: UUID
    public var deviceName: String
    public var updatedAt: Date
    public var tabs: [CloudTabSnapshot]

    public var id: UUID { deviceID }

    public init(
        deviceID: UUID,
        deviceName: String,
        updatedAt: Date,
        tabs: [CloudTabSnapshot]
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.updatedAt = updatedAt
        self.tabs = tabs
    }

    /// Old records can survive an ungraceful shutdown. Keeping the age policy in the
    /// model makes the UI deterministic and prevents a long-dead Mac looking live.
    public func isRecent(at date: Date = Date(), maximumAge: TimeInterval = 7 * 24 * 60 * 60) -> Bool {
        updatedAt <= date && date.timeIntervalSince(updatedAt) <= maximumAge
    }
}

public extension Array where Element == CloudTabDeviceSnapshot {
    func visibleCloudTabDevices(
        excluding localDeviceID: UUID,
        at date: Date = Date(),
        maximumAge: TimeInterval = 7 * 24 * 60 * 60
    ) -> [CloudTabDeviceSnapshot] {
        filter {
            $0.deviceID != localDeviceID
                && !$0.tabs.isEmpty
                && $0.isRecent(at: date, maximumAge: maximumAge)
        }
        .sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending
        }
    }
}
