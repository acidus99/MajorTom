import Foundation

public struct Bookmark: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var addedAt: Date

    public init(id: UUID = UUID(), title: String, url: URL, addedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.addedAt = addedAt
    }
}

public struct BookmarkFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bookmarks: [Bookmark]

    public init(id: UUID = UUID(), name: String, bookmarks: [Bookmark] = []) {
        self.id = id
        self.name = name
        self.bookmarks = bookmarks
    }
}

/// Every bookmark, in folders.
///
/// One level of folders, as Safari's Favourites bar and bookmark list present it. Nested
/// folders would complicate every operation here and the manager's layout, for a filing
/// depth that a Gemini reading list does not need.
///
/// The first folder is always Favourites and cannot be removed or renamed: it is what the
/// Favourites bar shows, so something has to fill that role, and a bar that could lose its
/// contents to a rename would be a puzzle rather than a feature.
public struct BookmarkCollection: Codable, Equatable, Sendable {
    public static let favoritesName = "Favorites"

    public private(set) var folders: [BookmarkFolder]

    public init(folders: [BookmarkFolder] = []) {
        self.folders = folders
        ensureFavoritesFolder()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decodeIfPresent([BookmarkFolder].self, forKey: .folders) ?? []
        ensureFavoritesFolder()
    }

    public var favorites: BookmarkFolder { folders[0] }
    public var favoritesID: UUID { folders[0].id }

    /// Folders a bookmark may be filed in, Favourites first.
    public var fileableFolders: [BookmarkFolder] { folders }

    public var allBookmarks: [Bookmark] { folders.flatMap(\.bookmarks) }

    public func contains(url: URL) -> Bool {
        folders.contains { folder in folder.bookmarks.contains { $0.url == url } }
    }

    public func bookmark(with id: UUID) -> Bookmark? {
        allBookmarks.first { $0.id == id }
    }

    public func folder(containing bookmarkID: UUID) -> BookmarkFolder? {
        folders.first { $0.bookmarks.contains { $0.id == bookmarkID } }
    }

    // MARK: - Mutation

    /// Adds a bookmark, or moves and retitles the existing one for the same URL.
    ///
    /// Re-bookmarking an address the reader already saved should not silently produce two
    /// entries that then have to be cleaned up by hand.
    @discardableResult
    public mutating func add(
        title: String,
        url: URL,
        toFolderWith folderID: UUID? = nil,
        at date: Date = Date()
    ) -> Bookmark {
        let destination = folderID ?? favoritesID
        if let existing = allBookmarks.first(where: { $0.url == url }) {
            remove(bookmarkWith: existing.id)
            let updated = Bookmark(id: existing.id, title: title, url: url, addedAt: existing.addedAt)
            insert(updated, intoFolderWith: destination)
            return updated
        }
        let bookmark = Bookmark(title: title, url: url, addedAt: date)
        insert(bookmark, intoFolderWith: destination)
        return bookmark
    }

    public mutating func remove(bookmarkWith id: UUID) {
        for index in folders.indices {
            folders[index].bookmarks.removeAll { $0.id == id }
        }
    }

    public mutating func remove(urlsMatching url: URL) {
        for index in folders.indices {
            folders[index].bookmarks.removeAll { $0.url == url }
        }
    }

    public mutating func rename(bookmarkWith id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for folderIndex in folders.indices {
            for bookmarkIndex in folders[folderIndex].bookmarks.indices
            where folders[folderIndex].bookmarks[bookmarkIndex].id == id {
                folders[folderIndex].bookmarks[bookmarkIndex].title = trimmed
            }
        }
    }

    /// Replaces a bookmark's destination without disturbing its title, identity, folder,
    /// or position. Address validation belongs to the editing UI because this model also
    /// stores non-Gemini URLs that Major Tom hands to other applications.
    public mutating func updateAddress(bookmarkWith id: UUID, to url: URL) {
        for folderIndex in folders.indices {
            for bookmarkIndex in folders[folderIndex].bookmarks.indices
            where folders[folderIndex].bookmarks[bookmarkIndex].id == id {
                folders[folderIndex].bookmarks[bookmarkIndex].url = url
            }
        }
    }

    public mutating func move(bookmarkWith id: UUID, toFolderWith folderID: UUID) {
        guard let bookmark = bookmark(with: id),
              folders.contains(where: { $0.id == folderID }) else { return }
        remove(bookmarkWith: id)
        insert(bookmark, intoFolderWith: folderID)
    }

    /// Reorders one folder's contents to match `orderedIDs`.
    ///
    /// Anything the caller left out keeps its relative order at the end, so a stale drag
    /// cannot delete bookmarks.
    public mutating func reorder(folderWith folderID: UUID, to orderedIDs: [UUID]) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let existing = folders[index].bookmarks
        var reordered = orderedIDs.compactMap { id in existing.first { $0.id == id } }
        reordered += existing.filter { bookmark in !orderedIDs.contains(bookmark.id) }
        folders[index].bookmarks = reordered
    }

    @discardableResult
    public mutating func addFolder(named name: String) -> BookmarkFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = BookmarkFolder(name: trimmed)
        folders.append(folder)
        return folder
    }

    /// Removes a folder and everything in it. The Favourites folder cannot be removed.
    public mutating func removeFolder(with id: UUID) {
        guard id != favoritesID else { return }
        folders.removeAll { $0.id == id }
    }

    public mutating func renameFolder(with id: UUID, to name: String) {
        guard id != favoritesID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
    }

    // MARK: - Private

    private mutating func insert(_ bookmark: Bookmark, intoFolderWith folderID: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else {
            folders[0].bookmarks.append(bookmark)
            return
        }
        folders[index].bookmarks.append(bookmark)
    }

    private mutating func ensureFavoritesFolder() {
        if let index = folders.firstIndex(where: { $0.name == Self.favoritesName }), index != 0 {
            folders.insert(folders.remove(at: index), at: 0)
        }
        if folders.isEmpty || folders[0].name != Self.favoritesName {
            folders.insert(BookmarkFolder(name: Self.favoritesName), at: 0)
        }
    }
}
