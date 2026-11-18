import Foundation
import GRDB
import XCTest
@testable import MajorTomCore

final class BrowsingDataClearingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var cutoff: Date { now.addingTimeInterval(-86_400) }
    private var old: Date { now.addingTimeInterval(-172_800) }

    private func entry(_ name: String, at date: Date) -> BackForwardEntry {
        let url = URL(string: "gemini://example.com/\(name)")!
        return BackForwardEntry(
            url: url, title: name, favicon: "🌎",
            page: CachedPage(url: url, mimeType: "text/gemini", body: Data(name.utf8),
                             completion: .complete, receivedAt: date),
            presentation: HistoryPresentationState(scrollY: 123, expandedImages: [url]),
            visitedAt: date, lastAccessedAt: date
        )
    }

    private func tab(_ entries: [BackForwardEntry], cursor: Int) -> RestoredTabState {
        RestoredTabState(entries: entries, history: entries.map(\.url), historyIndex: cursor,
                         cachedPages: entries.compactMap(\.page), zoom: 1.3)
    }

    func testClearRecentVisitsPreservesEarlierBackAndForwardAndCurrentAnchor() {
        let entries = [entry("old-back", at: old), entry("recent-back", at: cutoff),
                       entry("current", at: now), entry("recent-forward", at: now),
                       entry("old-forward", at: old)]
        var navigation = NavigationState(restoring: tab(entries, cursor: 2))
        navigation.clearBrowsingData(.clearBrowsingData, since: cutoff)

        XCTAssertEqual(navigation.entries.map(\.id), [entries[0].id, entries[2].id, entries[4].id])
        XCTAssertEqual(navigation.historyIndex, 1)
        XCTAssertEqual(navigation.committedURL, entries[2].url)
        XCTAssertTrue(navigation.canGoBack)
        XCTAssertTrue(navigation.canGoForward)
        XCTAssertNil(navigation.currentEntry?.page)
        XCTAssertEqual(navigation.currentEntry?.presentation, entries[2].presentation)
    }

    func testEverythingLeavesOnlyCurrentPageAndDisablesTraversal() {
        let entries = [entry("one", at: old), entry("two", at: now), entry("three", at: now)]
        var navigation = NavigationState(restoring: tab(entries, cursor: 1))
        navigation.clearBrowsingData(.clearBrowsingData, since: nil)

        XCTAssertEqual(navigation.entries.map(\.id), [entries[1].id])
        XCTAssertFalse(navigation.canGoBack)
        XCTAssertFalse(navigation.canGoForward)
        XCTAssertEqual(navigation.cachedByteCount, 0)
    }

    func testEmptyCachesPreservesDestinationsCursorReadingStateAndEarlierResponses() {
        let entries = [entry("old", at: old), entry("current", at: now), entry("forward", at: now)]
        var navigation = NavigationState(restoring: tab(entries, cursor: 1))
        navigation.clearBrowsingData(.emptyCaches, since: cutoff)

        XCTAssertEqual(navigation.history, entries.map(\.url))
        XCTAssertEqual(navigation.historyIndex, 1)
        XCTAssertEqual(navigation.entries.map(\.presentation), entries.map(\.presentation))
        XCTAssertEqual(navigation.entries[0].page, entries[0].page)
        XCTAssertNil(navigation.entries[1].page)
        XCTAssertNil(navigation.entries[2].page)
    }

    func testUndatedLegacyVisitsAreClearedConservatively() {
        let entries = [BackForwardEntry(url: entry("legacy", at: old).url, visitedAt: nil),
                       entry("current", at: now)]
        var navigation = NavigationState(restoring: tab(entries, cursor: 1))
        navigation.clearBrowsingData(.clearBrowsingData, since: cutoff)
        XCTAssertEqual(navigation.history, [entries[1].url])
    }

    func testRecentGlobalVisitsCanBeRemovedWithoutErasingEarlierVisitsOrTheirTitle() throws {
        let repository = BrowsingHistoryRepository(database: try MajorTomDatabase(inMemory: ()))
        let url = entry("revisited", at: now).url
        try repository.record(url, title: "Earlier title", at: old)
        try repository.record(url, title: "Today's title", at: now)
        try repository.record(entry("today-only", at: now).url, at: cutoff)
        try repository.clear(since: cutoff)

        let kept = try XCTUnwrap(repository.entries().first)
        XCTAssertEqual(try repository.entries().count, 1)
        XCTAssertEqual(kept.url, url)
        XCTAssertEqual(kept.visitCount, 1)
        XCTAssertEqual(kept.title, "Earlier title")
        XCTAssertEqual(kept.visitedAt, old)
        try repository.clear()
        XCTAssertTrue(try repository.entries().isEmpty)
    }

    func testClearingDraftsUsesTheirLastEditTime() throws {
        let repository = GeminiInputDraftRepository(database: try MajorTomDatabase(inMemory: ()))
        let earlier = entry("earlier", at: old).url
        let edited = entry("edited", at: old).url
        try repository.save("keep", for: earlier, at: old)
        try repository.save("before", for: edited, at: old)
        try repository.save("after", for: edited, at: now)
        try repository.removeAll(since: cutoff)

        XCTAssertEqual(try repository.draft(for: earlier, at: now)?.text, "keep")
        XCTAssertNil(try repository.draft(for: edited, at: now))
    }

    func testContentClearingIncludesOlderResponsesUsedRecentlyAndBothResourceTypes() async throws {
        let cache = ContentCache(database: try ContentCacheDatabase(inMemory: ()))
        let untouched = entry("untouched", at: old).url
        let used = entry("used", at: old).url
        let icon = entry("favicon.txt", at: now).url
        for (url, date, type) in [(untouched, old, ResourceType.image), (used, old, .image), (icon, now, .favicon)] {
            _ = try await cache.store(ContentResponse(url: url, status: 20, meta: Data(), mimeType: nil,
                body: Data([1]), receivedAt: date), resourceType: type, lifetime: 1_000_000, now: date)
        }
        _ = try await cache.freshResponse(for: used, now: now)
        try await cache.removeResponses(since: cutoff)
        let kept = try await cache.freshResponse(for: untouched, now: now)
        let removed = try await cache.freshResponse(for: used, now: now)
        let removedIcon = try await cache.freshResponse(for: icon, now: now)
        XCTAssertNotNil(kept)
        XCTAssertNil(removed)
        XCTAssertNil(removedIcon)
    }

    func testPreClearFetchCannotRepopulateContentCacheButNewFetchCan() async throws {
        // Prevents a queued image/favicon response from undoing Empty Caches.
        let cache = ContentCache(database: try ContentCacheDatabase(inMemory: ()))
        let generation = await cache.writeGeneration
        let response = ContentResponse(url: entry("image", at: now).url, status: 20,
            meta: Data(), mimeType: "image/png", body: Data([1]), receivedAt: now)
        try await cache.removeResponses(since: nil)
        let stale = try await cache.store(response, resourceType: .image, lifetime: 100,
                                           now: now, generation: generation)
        XCTAssertEqual(stale, .discarded)
        let missing = try await cache.freshResponse(for: response.url, now: now)
        XCTAssertNil(missing)
        let currentGeneration = await cache.writeGeneration
        _ = try await cache.store(response, resourceType: .image, lifetime: 100,
                                  now: now, generation: currentGeneration)
        let present = try await cache.freshResponse(for: response.url, now: now)
        XCTAssertEqual(present, response)
    }

    func testTwoWindowsWithThreeTabsAreFilteredAndStayClearedAfterSavingAgain() async throws {
        // Prevents quitting from reconstructing cleared responses or navigation lists.
        let database = try BackForwardCacheDatabase(inMemory: ())
        let repository = SessionRepository(database: database)
        let cache = BackForwardCacheStore(database: database)
        let entries = [entry("old", at: old), entry("today", at: now), entry("current", at: now)]
        let windows = (0..<2).map { _ in
            PersistedBrowserWindow(frame: nil, tabs: (0..<3).map { _ in tab(entries.map {
                BackForwardEntry(url: $0.url, title: $0.title, page: $0.page,
                    presentation: $0.presentation, visitedAt: $0.visitedAt, lastAccessedAt: $0.lastAccessedAt)
            }, cursor: 2) }, selectedIndex: 1)
        }
        try repository.save(PersistedApplicationSession(windows: windows, keyWindowIndex: 1))
        try repository.clearBrowsingData(.clearBrowsingData, since: cutoff)
        let session = try XCTUnwrap(repository.load())
        XCTAssertEqual(session.windows.count, 2)
        XCTAssertEqual(session.keyWindowIndex, 1)
        for window in session.windows {
            XCTAssertEqual(window.tabs.count, 3)
            XCTAssertEqual(window.selectedIndex, 1)
            for tab in window.tabs {
                XCTAssertEqual(tab.history, [entries[0].url, entries[2].url])
                XCTAssertEqual(tab.historyIndex, 1)
                XCTAssertEqual(tab.zoom, 1.3)
                XCTAssertEqual(tab.entries[0].presentation, entries[0].presentation)
                let previous = try await cache.entry(id: tab.entries[0].id)
                XCTAssertNotNil(previous?.page)
                XCTAssertNil(tab.entries[1].page)
            }
        }
        try repository.save(session)
        for tab in try XCTUnwrap(repository.load()).windows.flatMap(\.tabs) {
            let current = try await cache.entry(id: tab.entries[1].id)
            XCTAssertNil(current?.page)
        }
    }

    func testHistoryUpgradePreservesKnownAggregateWithoutInventingVisitDates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.db")
        let url = entry("legacy", at: old).url
        let original = try MajorTomDatabase(fileURL: file)
        try original.write { db in
            try db.execute(sql: "DROP TABLE history_visits")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                           arguments: ["v15-individual-history-visits"])
            try db.execute(sql: "INSERT INTO history_entries (url, title, visited_at, visit_count) VALUES (?, ?, ?, ?)",
                           arguments: [url.absoluteString, "Legacy", old, 7])
        }
        try original.checkpointAndClose()
        let upgraded = try MajorTomDatabase(fileURL: file)
        let repository = BrowsingHistoryRepository(database: upgraded)
        try repository.record(url, title: "Today", at: now)
        try repository.clear(since: cutoff)
        let kept = try XCTUnwrap(repository.entries().first)
        XCTAssertEqual(kept.visitCount, 7)
        XCTAssertEqual(kept.visitedAt, old)
        XCTAssertEqual(kept.title, "Legacy")
        try upgraded.checkpointAndClose()
    }

    func testLegacySessionUpgradeAndNewMetadataSaveKeepResponseDeletionPermanent() throws {
        // Prevents a metadata-only autosave from reviving a cleared older response.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.db")
        let original = try BackForwardCacheDatabase(fileURL: file)
        let item = entry("legacy", at: old)
        try SessionRepository(database: original).save(PersistedApplicationSession(windows: [
            PersistedBrowserWindow(frame: nil, tabs: [tab([item], cursor: 0)], selectedIndex: 0)
        ], keyWindowIndex: 0))
        try original.write { db in
            try db.execute(sql: "ALTER TABLE browser_tab_history DROP COLUMN visited_at")
            try db.execute(sql: "ALTER TABLE browser_tab_history DROP COLUMN last_accessed_at")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                           arguments: ["v2-visit-and-access-dates"])
        }
        try original.checkpointAndClose()
        let upgraded = try BackForwardCacheDatabase(fileURL: file)
        let repository = SessionRepository(database: upgraded)
        var session = try XCTUnwrap(repository.load())
        XCTAssertEqual(session.windows[0].tabs[0].entries[0].visitedAt, old)
        var navigation = NavigationState(restoring: session.windows[0].tabs[0])
        navigation.recordCurrentAccess(at: now)
        navigation.clearBrowsingData(.emptyCaches, since: cutoff)
        session.windows[0].tabs[0] = navigation.restorationState(zoom: 1.3, title: nil, documentTitle: nil)
        try repository.save(session)
        try repository.clearBrowsingData(.emptyCaches, since: cutoff)
        try repository.save(session)
        XCTAssertNil(try repository.load()?.windows[0].tabs[0].entries[0].page)
        try upgraded.checkpointAndClose()
    }

    func testEmptyingPersistentCachesKeepsLazyHistoryButDeletesBodies() async throws {
        let database = try BackForwardCacheDatabase(inMemory: ())
        let repository = SessionRepository(database: database)
        let entries = [entry("old", at: old), entry("current", at: now)]
        try repository.save(PersistedApplicationSession(windows: [PersistedBrowserWindow(
            frame: nil, tabs: [tab(entries, cursor: 1)], selectedIndex: 0)], keyWindowIndex: 0))
        try repository.clearBrowsingData(.emptyCaches, since: nil)
        let loaded = try XCTUnwrap(repository.load()).windows[0].tabs[0]
        XCTAssertEqual(loaded.history, entries.map(\.url))
        XCTAssertEqual(loaded.historyIndex, 1)
        for entry in loaded.entries {
            let stored = try await BackForwardCacheStore(database: database).entry(id: entry.id)
            XCTAssertNil(stored?.page)
            XCTAssertEqual(stored?.presentation.scrollY, 123)
        }
    }
}
