import Foundation
import GRDB
import XCTest
@testable import MajorTomCore

final class SessionRepositoryTests: XCTestCase {
    func testSessionRoundTripsWindowsTabsHistoryCursorZoomAndScroll() throws {
        let database = try BackForwardCacheDatabase(inMemory: ())
        let repository = SessionRepository(database: database)
        let one = URL(string: "gemini://example.com/one")!
        let two = URL(string: "gemini://example.com/two")!
        let session = PersistedApplicationSession(
            windows: [PersistedBrowserWindow(
                frame: PersistedWindowFrame(x: 10, y: 20, width: 900, height: 700),
                tabs: [RestoredTabState(
                    history: [one, two],
                    historyIndex: 0,
                    cachedPages: [],
                    zoom: 1.4,
                    title: "One",
                    documentTitle: "Heading",
                    scrollOffsets: [0: 140, 1: 900]
                )],
                selectedIndex: 0
            )],
            keyWindowIndex: 0
        )

        try repository.save(session)
        let loaded = try XCTUnwrap(repository.load())

        XCTAssertEqual(loaded.windows[0].frame, session.windows[0].frame)
        XCTAssertEqual(loaded.windows[0].tabs[0].history, [one, two])
        XCTAssertEqual(loaded.windows[0].tabs[0].historyIndex, 0)
        XCTAssertEqual(loaded.windows[0].tabs[0].title, "Heading")
        XCTAssertEqual(loaded.windows[0].tabs[0].scrollOffsets, [0: 140, 1: 900])
        XCTAssertEqual(loaded.keyWindowIndex, 0)
    }

    func testLoadHydratesCurrentPageFromStandaloneCache() throws {
        let database = try BackForwardCacheDatabase(inMemory: ())
        let repository = SessionRepository(database: database)
        let url = URL(string: "gemini://example.com/cached")!
        let page = CachedPage(
            url: url,
            mimeType: "text/gemini",
            body: Data("cached source".utf8),
            completion: .complete,
            receivedAt: Date()
        )
        try repository.save(PersistedApplicationSession(
            windows: [PersistedBrowserWindow(
                frame: nil,
                tabs: [RestoredTabState(history: [url], historyIndex: 0, cachedPages: [page], zoom: 1)],
                selectedIndex: 0
            )],
            keyWindowIndex: 0
        ))

        let loaded = try XCTUnwrap(repository.load())

        let loadedPage = try XCTUnwrap(loaded.windows[0].tabs[0].cachedPages.first)
        XCTAssertEqual(loadedPage.url, page.url)
        XCTAssertEqual(loadedPage.mimeType, page.mimeType)
        XCTAssertEqual(loadedPage.body, page.body)
        XCTAssertEqual(loadedPage.completion, page.completion)
        XCTAssertEqual(loadedPage.receivedAt.timeIntervalSince1970,
                       page.receivedAt.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testLoadHydratesOnlyCurrentPageAndLeavesOtherHistoryLazy() throws {
        let database = try BackForwardCacheDatabase(inMemory: ())
        let repository = SessionRepository(database: database)
        let one = URL(string: "gemini://example.com/one")!
        let two = URL(string: "gemini://example.com/two")!
        let pages = [one, two].map { url in
            CachedPage(
                url: url,
                mimeType: "text/gemini",
                body: Data(url.absoluteString.utf8),
                completion: .complete,
                receivedAt: Date()
            )
        }
        try repository.save(PersistedApplicationSession(
            windows: [PersistedBrowserWindow(
                frame: nil,
                tabs: [RestoredTabState(history: [one, two], historyIndex: 1, cachedPages: pages, zoom: 1)],
                selectedIndex: 0
            )],
            keyWindowIndex: 0
        ))

        let loaded = try XCTUnwrap(repository.load())

        XCTAssertEqual(loaded.windows[0].tabs[0].cachedPages.map(\.url), [two])
    }

    func testSavingReplacementSessionRemovesOldRowsAtomically() throws {
        let database = try BackForwardCacheDatabase(inMemory: ())
        let repository = SessionRepository(database: database)
        let first = URL(string: "gemini://example.com/first")!
        let second = URL(string: "gemini://example.com/second")!
        func session(_ url: URL) -> PersistedApplicationSession {
            PersistedApplicationSession(
                windows: [PersistedBrowserWindow(
                    frame: nil,
                    tabs: [RestoredTabState(history: [url], historyIndex: 0, cachedPages: [], zoom: 1)],
                    selectedIndex: 0
                )],
                keyWindowIndex: 0
            )
        }
        try repository.save(session(first))
        try repository.save(session(second))

        XCTAssertEqual(try repository.load()?.windows[0].tabs[0].history, [second])
        let oldCount = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM browser_tab_history WHERE url = ?", arguments: [first.absoluteString])
        }
        XCTAssertEqual(oldCount, 0)
    }

    func testRepeatedURLVisitsKeepIndependentRowsAndLoadOlderResponseLazily() async throws {
        let database = try BackForwardCacheDatabase(inMemory: ())
        let repository = SessionRepository(database: database)
        let store = BackForwardCacheStore(database: database)
        let url = URL(string: "gemini://example.com/changing")!
        let tabID = UUID()
        let older = BackForwardEntry(
            url: url,
            title: "Earlier",
            favicon: "🕰️",
            page: page(url: url, source: "earlier"),
            presentation: HistoryPresentationState(scrollY: 125, collapsedPreformatted: [1])
        )
        let newer = BackForwardEntry(
            url: url,
            title: "Later",
            favicon: "✨",
            page: page(url: url, source: "later"),
            presentation: HistoryPresentationState(scrollY: 900, expandedImages: [
                URL(string: "gemini://example.com/image.png")!
            ])
        )
        let tab = RestoredTabState(
            tabID: tabID,
            entries: [older, newer],
            history: [url, url],
            historyIndex: 1,
            cachedPages: [older.page!, newer.page!],
            zoom: 1
        )
        try repository.save(PersistedApplicationSession(
            windows: [PersistedBrowserWindow(frame: nil, tabs: [tab], selectedIndex: 0)],
            keyWindowIndex: 0
        ))

        let loaded = try XCTUnwrap(repository.load()).windows[0].tabs[0]
        XCTAssertNil(loaded.entries[0].page)
        XCTAssertEqual(String(decoding: try XCTUnwrap(loaded.entries[1].page).body, as: UTF8.self), "later")
        XCTAssertEqual(loaded.entries.map(\.title), ["Earlier", "Later"])
        XCTAssertEqual(loaded.entries.map(\.favicon), ["🕰️", "✨"])
        XCTAssertEqual(loaded.entries[0].presentation.collapsedPreformatted, [1])

        let storedEntry = try await store.entry(id: older.id)
        let lazilyLoaded = try XCTUnwrap(storedEntry)
        XCTAssertEqual(String(decoding: try XCTUnwrap(lazilyLoaded.page).body, as: UTF8.self), "earlier")
    }

    func testClientCertificateReloadRemovesPreviouslySavedResponse() throws {
        let database = try BackForwardCacheDatabase(inMemory: ())
        let repository = SessionRepository(database: database)
        let url = URL(string: "gemini://example.com/private")!
        let entryID = UUID()
        let tabID = UUID()

        func session(page: CachedPage) -> PersistedApplicationSession {
            let entry = BackForwardEntry(id: entryID, url: url, page: page)
            let tab = RestoredTabState(
                tabID: tabID,
                entries: [entry],
                history: [url],
                historyIndex: 0,
                cachedPages: [page],
                zoom: 1
            )
            return PersistedApplicationSession(
                windows: [PersistedBrowserWindow(frame: nil, tabs: [tab], selectedIndex: 0)],
                keyWindowIndex: 0
            )
        }

        try repository.save(session(page: page(url: url, source: "public")))
        var authenticated = page(url: url, source: "private")
        authenticated.clientCertificateID = UUID()
        try repository.save(session(page: authenticated))

        let response = try database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT response_meta, response_body FROM browser_tab_history WHERE id = ?",
                arguments: [entryID.uuidString.lowercased()]
            )
        }
        XCTAssertNil(response?["response_meta"] as String?)
        XCTAssertNil(response?["response_body"] as Data?)
        XCTAssertNil(try repository.load()?.windows[0].tabs[0].entries[0].page)
    }

    func testClearRemovesSessionAndHistoryEntries() throws {
        let database = try BackForwardCacheDatabase(inMemory: ())
        let repository = SessionRepository(database: database)
        let url = URL(string: "gemini://example.com/one")!
        try repository.save(PersistedApplicationSession(
            windows: [PersistedBrowserWindow(
                frame: nil,
                tabs: [RestoredTabState(history: [url], historyIndex: 0, cachedPages: [], zoom: 1)],
                selectedIndex: 0
            )],
            keyWindowIndex: 0
        ))

        try repository.clear()

        XCTAssertNil(try repository.load())
        XCTAssertEqual(try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM browser_tab_history")
        }, 0)
    }

    private func page(url: URL, source: String) -> CachedPage {
        CachedPage(
            url: url,
            mimeType: "text/gemini",
            body: Data(source.utf8),
            completion: .complete,
            receivedAt: Date(),
            responseStatus: 20,
            responseMeta: "text/gemini; charset=utf-8"
        )
    }
}
