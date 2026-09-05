import Foundation
import GRDB
import XCTest
@testable import MajorTomCore

final class SessionRepositoryTests: XCTestCase {
    func testSessionRoundTripsWindowsTabsHistoryCursorZoomAndScroll() throws {
        let database = try MajorTomDatabase(inMemory: ())
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

        XCTAssertEqual(loaded, session)
    }

    func testLoadHydratesBackForwardPagesFromGlobalCache() throws {
        let database = try MajorTomDatabase(inMemory: ())
        let repository = SessionRepository(database: database)
        let cache = PageCacheRepository(database: database)
        let url = URL(string: "gemini://example.com/cached")!
        let page = CachedPage(
            url: url,
            mimeType: "text/gemini",
            body: Data("cached source".utf8),
            completion: .complete,
            receivedAt: Date()
        )
        try cache.store(page)
        try repository.save(PersistedApplicationSession(
            windows: [PersistedBrowserWindow(
                frame: nil,
                tabs: [RestoredTabState(history: [url], historyIndex: 0, cachedPages: [], zoom: 1)],
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
        let database = try MajorTomDatabase(inMemory: ())
        let repository = SessionRepository(database: database)
        let cache = PageCacheRepository(database: database)
        let one = URL(string: "gemini://example.com/one")!
        let two = URL(string: "gemini://example.com/two")!
        for url in [one, two] {
            try cache.store(CachedPage(
                url: url,
                mimeType: "text/gemini",
                body: Data(url.absoluteString.utf8),
                completion: .complete,
                receivedAt: Date()
            ))
        }
        try repository.save(PersistedApplicationSession(
            windows: [PersistedBrowserWindow(
                frame: nil,
                tabs: [RestoredTabState(history: [one, two], historyIndex: 1, cachedPages: [], zoom: 1)],
                selectedIndex: 0
            )],
            keyWindowIndex: 0
        ))

        let loaded = try XCTUnwrap(repository.load())

        XCTAssertEqual(loaded.windows[0].tabs[0].cachedPages.map(\.url), [two])
    }

    func testSavingReplacementSessionRemovesOldRowsAtomically() throws {
        let database = try MajorTomDatabase(inMemory: ())
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
}
