import Combine
import Foundation
import MajorTomCore

/// The application's bookmarks, published for SwiftUI.
///
/// The actor behind it is the durable copy and the only thing that mutates the collection;
/// this type mirrors the result so views can observe it. One shared instance, because
/// every window and the manager must see the same list.
@MainActor
final class BookmarksModel: ObservableObject {
    static let shared = BookmarksModel()

    @Published private(set) var collection = BookmarkCollection()
    /// Favicons already in the cache, for decorating bookmark lists.
    @Published private(set) var favicons: [CapsuleEndpoint: String] = [:]

    private let store: BookmarkStore?
    private let defaults = UserDefaults.standard
    private let syncStorageKey = "bookmarks-cloud-metadata-v1"
    private var syncState: SyncedBookmarks?
    private var cloudObserver: AnyCancellable?

    init() {
        if let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            store = BookmarkStore(fileURL: root
                .appendingPathComponent("Major Tom", isDirectory: true)
                .appendingPathComponent("bookmarks.json"))
        } else {
            store = nil
        }
        cloudObserver = ICloudSyncStore.shared.receivedBookmarks.sink { [weak self] state in
            Task { await self?.applyCloudState(state) }
        }
        Task { [weak self] in await self?.reload() }
    }

    // MARK: - Reading

    func isBookmarked(_ url: URL) -> Bool { collection.contains(url: url) }

    /// A bookmark's favicon, **only** if one is already cached.
    ///
    /// The favicon RFC forbids requesting a favicon before the reader has visited that
    /// server, so a bookmark list may decorate what is already known but must never fetch:
    /// a list of fifty bookmarks would otherwise touch fifty capsules on open.
    func favicon(for url: URL) -> String? {
        CapsuleEndpoint(url: url).flatMap { favicons[$0] }
    }

    func refreshFavicons() {
        Task { [weak self] in
            let known = await SharedFaviconStore.shared?.knownFavicons() ?? [:]
            self?.favicons = known
        }
    }

    // MARK: - Writing

    func add(title: String, url: URL, toFolderWith folderID: UUID? = nil) {
        mutate { $0.add(title: title, url: url, toFolderWith: folderID) }
    }

    func remove(bookmarkWith id: UUID) {
        mutate { $0.remove(bookmarkWith: id) }
    }

    func removeBookmarks(for url: URL) {
        mutate { $0.remove(urlsMatching: url) }
    }

    func rename(bookmarkWith id: UUID, to title: String) {
        mutate { $0.rename(bookmarkWith: id, to: title) }
    }

    func updateAddress(bookmarkWith id: UUID, to url: URL) {
        mutate { $0.updateAddress(bookmarkWith: id, to: url) }
    }

    func move(bookmarkWith id: UUID, toFolderWith folderID: UUID) {
        mutate { $0.move(bookmarkWith: id, toFolderWith: folderID) }
    }

    func reorder(folderWith id: UUID, to orderedIDs: [UUID]) {
        mutate { $0.reorder(folderWith: id, to: orderedIDs) }
    }

    func addFolder(named name: String) {
        mutate { $0.addFolder(named: name) }
    }

    func removeFolder(with id: UUID) {
        mutate { $0.removeFolder(with: id) }
    }

    func renameFolder(with id: UUID, to name: String) {
        mutate { $0.renameFolder(with: id, to: name) }
    }

    /// Imports a browser's bookmarks as one durable update, avoiding a race between
    /// individual asynchronous bookmark writes. Existing URLs retain their normal
    /// de-duplication behavior.
    func importLagrangeBookmarks(_ bookmarks: [LagrangeUserDataExport.Bookmark]) {
        mutate { collection in
            let folderID = collection.folders.first(where: { $0.name == "Lagrange" })?.id
                ?? collection.addFolder(named: "Lagrange")?.id
                ?? collection.favoritesID
            for bookmark in bookmarks {
                // Importing must never retitle or move a bookmark the reader already
                // has; their existing filing is more deliberate than the source's.
                guard !collection.contains(url: bookmark.url) else { continue }
                collection.add(title: bookmark.title, url: bookmark.url, toFolderWith: folderID)
            }
        }
    }

    /// Deletes every bookmark and custom folder, retaining only the required empty
    /// Favourites folder. The corresponding cloud snapshot carries deletion tombstones.
    func deleteAll() async throws {
        let empty = BookmarkCollection()
        if let store {
            collection = try await store.replace(with: empty)
        } else {
            collection = empty
        }
        let previous = syncState ?? SyncedBookmarks(collection: collection, modifiedAt: .distantPast)
        let next = previous.reconciled(with: collection, at: Date())
        syncState = next
        persistSyncState()
        ICloudSyncStore.shared.updateBookmarks(next)
    }

    private func reload() async {
        guard let store else { return }
        let localCollection = await store.collection()
        collection = localCollection
        if let data = defaults.data(forKey: syncStorageKey),
           let stored = try? JSONDecoder().decode(SyncedBookmarks.self, from: data) {
            syncState = stored.reconciled(with: localCollection, at: Date())
        } else {
            syncState = SyncedBookmarks(collection: localCollection, modifiedAt: Date())
        }
        persistSyncState()
        ICloudSyncStore.shared.configure(bookmarks: syncState)
    }

    /// Every change goes through the store, which applies it and returns the result, so no
    /// operation can forget to persist and the published copy can never drift from disk.
    private func mutate(_ change: @escaping @Sendable (inout BookmarkCollection) -> Void) {
        guard let store else {
            change(&collection)
            return
        }
        Task { [weak self] in
            guard let updated = try? await store.update(change) else { return }
            self?.collection = updated
            guard let self else { return }
            let previous = self.syncState
                ?? SyncedBookmarks(collection: updated, modifiedAt: .distantPast)
            let next = previous.reconciled(with: updated, at: Date())
            self.syncState = next
            self.persistSyncState()
            ICloudSyncStore.shared.updateBookmarks(next)
        }
    }

    private func applyCloudState(_ incoming: SyncedBookmarks) async {
        let merged = syncState.map { $0.merging(incoming) } ?? incoming
        let mergedCollection = merged.collection
        if let store {
            _ = try? await store.replace(with: mergedCollection)
        }
        syncState = merged.reconciled(with: mergedCollection, at: Date())
        collection = mergedCollection
        persistSyncState()
        if syncState != merged, let syncState {
            ICloudSyncStore.shared.updateBookmarks(syncState)
        }
    }

    private func persistSyncState() {
        guard let syncState, let data = try? JSONEncoder().encode(syncState) else { return }
        defaults.set(data, forKey: syncStorageKey)
    }
}
