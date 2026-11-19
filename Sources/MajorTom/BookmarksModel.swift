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
    @Published private(set) var collection = BookmarkCollection()
    /// Favicons already in the cache, for decorating bookmark lists.
    @Published private(set) var favicons: [CapsuleEndpoint: String] = [:]

    private var store: BookmarkStore?
    private let activity: LocalPersistenceActivity
    private let cache: ContentCache?
    private var cachedFaviconObservations: [CapsuleEndpoint: BookmarkFaviconSnapshot] = [:]
    private var faviconRefreshTask: Task<Void, Never>?
    private var faviconAttachmentInFlight = false
    private var publicationRevision = 0
    private var mutationTasks: [UUID: Task<Void, Never>] = [:]
    private var awaitedWrites = 0
    private var writeDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var initializationTask: Task<Void, Never>?
    private var didLoadDurableCollection = false

    init(store: BookmarkStore?, cache: ContentCache?, activity: LocalPersistenceActivity) {
        self.store = store
        self.cache = cache
        self.activity = activity
        initializationTask = Task { [weak self] in await self?.reload() }
    }

    func replaceStore(_ store: BookmarkStore?) {
        publicationRevision += 1
        self.store = store
        collection = BookmarkCollection()
        didLoadDurableCollection = false
        initializationTask = Task { [weak self] in await self?.reload() }
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
        faviconRefreshTask = Task { [weak self, cache] in
            defer { self?.faviconRefreshTask = nil }
            let responses = await GeminiFaviconLoader.cachedObservations(cache: cache)
            var known: [CapsuleEndpoint: String] = [:]
            var observations: [CapsuleEndpoint: BookmarkFaviconSnapshot] = [:]
            for (endpoint, response) in responses {
                guard let emoji = response.emoji else { continue }
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
        let destination = store
        let operation = UUID()
        let activity = activity
        activity.begin()
        mutationTasks[operation] = Task { [weak self, cache] in
            defer { self?.mutationTasks[operation] = nil; activity.end() }
            let snapshot: BookmarkFaviconSnapshot?
            if let endpoint = CapsuleEndpoint(url: url),
               let faviconURL = GeminiFavicon.url(for: endpoint),
               let response = await GeminiFaviconLoader.cachedObservation(for: faviconURL, cache: cache),
               response.kind != .unknown {
                snapshot = BookmarkFaviconSnapshot(
                    emoji: response.emoji,
                    fetchedAt: response.receivedAt
                )
            } else {
                snapshot = nil
            }
            guard let self, self.store === destination else { return }
            self.mutate {
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
    func importLagrangeBookmarks(_ bookmarks: [LagrangeUserDataExport.Bookmark]) async throws -> Int {
        try await importBookmarks(
            bookmarks.map { (title: $0.title, url: $0.url) },
            intoFolderNamed: "Lagrange"
        )
    }

    func importAlhenaBookmarks(_ bookmarks: [AlhenaUserDataExport.Bookmark]) async throws -> Int {
        try await importBookmarks(
            bookmarks.map { (title: $0.title, url: $0.url) },
            intoFolderNamed: "Alhena"
        )
    }

    private func importBookmarks(
        _ bookmarks: [(title: String, url: URL)],
        intoFolderNamed folderName: String
    ) async throws -> Int {
        var seen = Set(collection.allBookmarks.map(\.url))
        let additions = bookmarks.filter { seen.insert($0.url).inserted }
        guard !additions.isEmpty else { return 0 }
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
    }

    /// Deletes every bookmark and custom folder, retaining only the required empty
    /// Favourites folder. The corresponding cloud snapshot carries deletion tombstones.
    func deleteAll() async throws {
        try await mutateAndWait { $0 = BookmarkCollection() }
    }

    func reload() async {
        guard let store else { return }
        publicationRevision += 1
        let revision = publicationRevision
        do {
            let committed = try await store.reload()
            guard revision == publicationRevision, self.store === store else { return }
            didLoadDurableCollection = true
            collection = committed
            await attachCachedFaviconObservationsIfNeeded()
        } catch { activity.report(error) }
    }

    /// Every change goes through the store, which applies it and returns the result, so no
    /// operation can forget to persist and the published copy can never drift from disk.
    private func mutate(_ change: @escaping @Sendable (inout BookmarkCollection) -> Void) {
        guard !activity.isPreparingAccount else {
            activity.report(CocoaError(.fileLocking))
            return
        }
        guard let store else {
            activity.report(CocoaError(.fileWriteUnknown))
            return
        }
        publicationRevision += 1
        let revision = publicationRevision
        let operation = UUID()
        activity.begin()
        let activity = activity
        mutationTasks[operation] = Task { [weak self] in
            defer {
                self?.mutationTasks[operation] = nil
                activity.end()
            }
            let updated: BookmarkCollection
            do { updated = try await store.update(change) }
            catch { activity.report(error); return }
            guard let self, self.store === store, self.publicationRevision == revision else { return }
            self.collection = updated

        }
    }

    private func mutateAndWait(
        _ change: @escaping @Sendable (inout BookmarkCollection) -> Void
    ) async throws {
        guard !activity.isPreparingAccount else { throw CocoaError(.fileLocking) }
        guard let store else {
            throw CocoaError(.fileWriteUnknown)
        }
        publicationRevision += 1
        let revision = publicationRevision
        awaitedWrites += 1
        activity.begin()
        defer {
            activity.end()
            awaitedWrites -= 1
            if awaitedWrites == 0 {
                let waiters = writeDrainWaiters
                writeDrainWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        let updated = try await store.update(change)
        guard revision == publicationRevision, self.store === store else { return }
        collection = updated

    }

    func flushPendingWrites() async {
        await faviconRefreshTask?.value
        await initializationTask?.value
        while let task = mutationTasks.values.first { await task.value }
        if awaitedWrites > 0 {
            await withCheckedContinuation { writeDrainWaiters.append($0) }
        }
    }

    func prepareForFirstAccountClaim() async throws {
        await flushPendingWrites()
        guard didLoadDurableCollection else { throw CocoaError(.fileReadCorruptFile) }
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

}
