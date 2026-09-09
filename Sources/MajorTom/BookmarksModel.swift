import Combine
import Foundation
import MajorTomCore
import OSLog

private let bookmarkSyncLogger = Logger(
    subsystem: "dev.gemi.major-tom",
    category: "BookmarkSync"
)

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

    private var store: BookmarkStore?
    private let database: MajorTomDatabase?
    private let legacyFileURL: URL?
    private var syncState: SyncedBookmarks?
    private var cachedFaviconObservations: [CapsuleEndpoint: BookmarkFaviconSnapshot] = [:]
    private var faviconRefreshTask: Task<Void, Never>?
    private var faviconAttachmentInFlight = false
    private var cloudObserver: AnyCancellable?
    private var accountObserver: AnyCancellable?

    init() {
        let database = SharedMajorTomDatabase.shared
        self.database = database
        if let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            let fileURL = root
                .appendingPathComponent("Major Tom", isDirectory: true)
                .appendingPathComponent("bookmarks.json")
            legacyFileURL = fileURL
            if let database {
                let account = try? CloudSyncRepository(database: database)
                    .activeAccountIdentityHash()
                store = try? BookmarkStore(database: database, accountIdentityHash: account)
            } else {
                store = BookmarkStore(fileURL: fileURL)
            }
        } else {
            store = nil
            legacyFileURL = nil
        }
        cloudObserver = ICloudSyncStore.shared.receivedBookmarks.sink { [weak self] state in
            Task { await self?.applyCloudState(state) }
        }
        accountObserver = ICloudSyncStore.shared.activeAccountChanged.sink { [weak self] account in
            guard let self, let database = self.database else { return }
            self.store = try? BookmarkStore(database: database, accountIdentityHash: account)
            Task { await self.reload() }
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
        if let snapshot = collection.allBookmarks.first(where: { $0.url == url })?.favicon {
            return snapshot.emoji
        }
        return CapsuleEndpoint(url: url).flatMap { favicons[$0] }
    }

    func refreshFavicons() {
        guard faviconRefreshTask == nil else { return }
        faviconRefreshTask = Task { [weak self] in
            defer { self?.faviconRefreshTask = nil }
            let responses = (try? await SharedContentCache.shared?.freshResponses(ofType: .favicon)) ?? []
            var known: [CapsuleEndpoint: String] = [:]
            var observations: [CapsuleEndpoint: BookmarkFaviconSnapshot] = [:]
            for response in responses {
                guard let endpoint = CapsuleEndpoint(url: response.url),
                      let emoji = GeminiFavicon.parse(response: response) else { continue }
                known[endpoint] = emoji
                observations[endpoint] = BookmarkFaviconSnapshot(
                    emoji: emoji, fetchedAt: response.receivedAt
                )
            }
            guard let self else { return }
            self.favicons = known
            self.cachedFaviconObservations = observations
            bookmarkSyncLogger.info(
                "favicon cache loaded responses=\(responses.count) endpoints=\(known.count)"
            )
            await self.attachCachedFaviconObservationsIfNeeded()
        }
    }

    // MARK: - Writing

    func add(title: String, url: URL, toFolderWith folderID: UUID? = nil) {
        Task { [weak self] in
            let snapshot: BookmarkFaviconSnapshot?
            if let endpoint = CapsuleEndpoint(url: url),
               let faviconURL = GeminiFavicon.url(for: endpoint),
               let response = try? await SharedContentCache.shared?.freshResponse(for: faviconURL) {
                snapshot = BookmarkFaviconSnapshot(
                    emoji: GeminiFavicon.parse(response: response),
                    fetchedAt: response.receivedAt
                )
            } else {
                snapshot = nil
            }
            self?.mutate {
                $0.add(
                    title: title,
                    url: url,
                    toFolderWith: folderID,
                    favicon: snapshot
                )
            }
        }
    }

    /// Attaches a changed favicon observation to every bookmark on this capsule. A
    /// confirmed absence is as meaningful as an emoji and synchronizes the same way.
    func updateFavicon(
        _ emoji: String?,
        for endpoint: CapsuleEndpoint,
        fetchedAt: Date
    ) {
        let snapshot = BookmarkFaviconSnapshot(emoji: emoji, fetchedAt: fetchedAt)
        guard collection.allBookmarks.contains(where: {
            CapsuleEndpoint(url: $0.url) == endpoint
                && ($0.favicon == nil || $0.favicon?.emoji != emoji)
        }) else { return }
        bookmarkSyncLogger.info(
            "bookmark favicon observation queued hasEmoji=\(emoji != nil)"
        )
        mutate { $0.updateFavicon(for: endpoint, to: snapshot) }
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
    func importLagrangeBookmarks(_ bookmarks: [LagrangeUserDataExport.Bookmark]) async -> Int {
        await importBookmarks(
            bookmarks.map { (title: $0.title, url: $0.url) },
            intoFolderNamed: "Lagrange"
        )
    }

    func importAlhenaBookmarks(_ bookmarks: [AlhenaUserDataExport.Bookmark]) async -> Int {
        await importBookmarks(
            bookmarks.map { (title: $0.title, url: $0.url) },
            intoFolderNamed: "Alhena"
        )
    }

    private func importBookmarks(
        _ bookmarks: [(title: String, url: URL)],
        intoFolderNamed folderName: String
    ) async -> Int {
        var seen = Set(collection.allBookmarks.map(\.url))
        let additions = bookmarks.filter { seen.insert($0.url).inserted }
        guard !additions.isEmpty else { return 0 }
        do {
            try await mutateAndWait { collection in
                let folderID = collection.folders.first(where: { $0.name == folderName })?.id
                    ?? collection.addFolder(named: folderName)?.id
                    ?? collection.favoritesID
                for bookmark in additions {
                    // Never retitle or move a bookmark already saved in Major Tom.
                    guard !collection.contains(url: bookmark.url) else { continue }
                    collection.add(title: bookmark.title, url: bookmark.url, toFolderWith: folderID)
                }
            }
            return additions.count
        } catch {
            return 0
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
        if let legacyFileURL,
           (try? await store.importLegacyJSON(at: legacyFileURL)) == true {
            try? FileManager.default.removeItem(at: legacyFileURL)
        }
        let localCollection = await store.collection()
        collection = localCollection

        syncState = SyncedBookmarks(collection: localCollection, modifiedAt: Date())
        ICloudSyncStore.shared.configure(bookmarks: syncState)
        await attachCachedFaviconObservationsIfNeeded()
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

    private func mutateAndWait(
        _ change: @escaping @Sendable (inout BookmarkCollection) -> Void
    ) async throws {
        guard let store else {
            change(&collection)
            return
        }
        let updated = try await store.update(change)
        collection = updated
        let previous = syncState
            ?? SyncedBookmarks(collection: updated, modifiedAt: .distantPast)
        let next = previous.reconciled(with: updated, at: Date())
        syncState = next
        persistSyncState()
        ICloudSyncStore.shared.updateBookmarks(next)
    }

    private func applyCloudState(_ incoming: SyncedBookmarks) async {
        // The incremental transport publishes the complete active account dataset after
        // applying each batch, so absence is an authoritative server deletion.
        let merged = incoming
        let mergedCollection = incoming.collection
        let faviconCount = mergedCollection.allBookmarks.filter { $0.favicon != nil }.count
        bookmarkSyncLogger.info(
            "cloud bookmarks received folders=\(mergedCollection.folders.count) bookmarks=\(mergedCollection.allBookmarks.count) faviconObservations=\(faviconCount)"
        )
        if let store {
            _ = try? await store.replace(with: mergedCollection)
        }
        syncState = merged.reconciled(with: mergedCollection, at: Date())
        collection = mergedCollection
        persistSyncState()
        if syncState != merged, let syncState {
            ICloudSyncStore.shared.updateBookmarks(syncState)
        }
        await attachCachedFaviconObservationsIfNeeded()
    }

    private func attachCachedFaviconObservationsIfNeeded() async {
        guard !faviconAttachmentInFlight else { return }
        let missing = cachedFaviconObservations.filter { endpoint, snapshot in
            collection.allBookmarks.contains {
                CapsuleEndpoint(url: $0.url) == endpoint
                    && ($0.favicon == nil || $0.favicon?.emoji != snapshot.emoji)
            }
        }
        bookmarkSyncLogger.info(
            "favicon reconciliation bookmarks=\(self.collection.allBookmarks.count) updates=\(missing.count)"
        )
        guard !missing.isEmpty else { return }
        faviconAttachmentInFlight = true
        defer { faviconAttachmentInFlight = false }
        do {
            try await mutateAndWait { collection in
                for (endpoint, snapshot) in missing {
                    collection.updateFavicon(for: endpoint, to: snapshot)
                }
            }
        } catch {
            bookmarkSyncLogger.error(
                "favicon reconciliation failed description=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistSyncState() {
        // Record-level rows and the transactional outbox are the durable sync state.
    }
}
