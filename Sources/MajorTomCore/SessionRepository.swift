import Foundation
import GRDB

public struct PersistedWindowFrame: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PersistedBrowserWindow: Equatable, Sendable {
    public var frame: PersistedWindowFrame?
    public var tabs: [RestoredTabState]
    public var selectedIndex: Int

    public init(frame: PersistedWindowFrame?, tabs: [RestoredTabState], selectedIndex: Int) {
        self.frame = frame
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }
}

public struct PersistedApplicationSession: Equatable, Sendable {
    public var windows: [PersistedBrowserWindow]
    public var keyWindowIndex: Int

    public init(windows: [PersistedBrowserWindow], keyWindowIndex: Int) {
        self.windows = windows
        self.keyWindowIndex = keyWindowIndex
    }
}

/// Normalized, local-only window/tab/Back-Forward restoration state.
public struct SessionRepository: Sendable {
    private let database: MajorTomDatabase
    private let cache: PageCacheRepository

    public init(database: MajorTomDatabase) {
        self.database = database
        cache = PageCacheRepository(database: database)
    }

    public func save(_ session: PersistedApplicationSession, at date: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM browser_windows")
            try db.execute(sql: "DELETE FROM browser_session")
            try db.execute(
                sql: "INSERT INTO browser_session (singleton, key_window_index, updated_at) VALUES (1, ?, ?)",
                arguments: [session.keyWindowIndex, date]
            )
            for (windowPosition, window) in session.windows.enumerated() {
                let windowID = UUID().uuidString
                try db.execute(
                    sql: """
                        INSERT INTO browser_windows (
                            id, position, frame_x, frame_y, frame_width, frame_height, selected_tab_index
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        windowID, windowPosition, window.frame?.x, window.frame?.y,
                        window.frame?.width, window.frame?.height, window.selectedIndex
                    ]
                )
                for (tabPosition, tab) in window.tabs.enumerated() {
                    let tabID = UUID().uuidString
                    try db.execute(
                        sql: """
                            INSERT INTO browser_tabs (
                                id, window_id, position, history_index, zoom, title, document_title
                            ) VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            tabID, windowID, tabPosition, tab.historyIndex,
                            tab.zoom, tab.title, tab.documentTitle
                        ]
                    )
                    for (historyPosition, url) in tab.history.enumerated() {
                        try db.execute(
                            sql: """
                                INSERT INTO browser_tab_history (
                                    tab_id, position, url, scroll_offset
                                ) VALUES (?, ?, ?, ?)
                                """,
                            arguments: [
                                tabID, historyPosition, url.absoluteString,
                                tab.scrollOffsets?[historyPosition] ?? 0
                            ]
                        )
                    }
                }
            }
        }
    }

    public func load(accessedAt: Date = Date()) throws -> PersistedApplicationSession? {
        let snapshot: (keyWindowIndex: Int, windows: [PersistedBrowserWindow])? = try database.read { db in
            guard let keyWindowIndex = try Int.fetchOne(
                db,
                sql: "SELECT key_window_index FROM browser_session WHERE singleton = 1"
            ) else { return nil }
            let windowRows = try Row.fetchAll(db, sql: "SELECT * FROM browser_windows ORDER BY position")
            let windows = try windowRows.map { windowRow -> PersistedBrowserWindow in
                let windowID: String = windowRow["id"]
                let tabRows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM browser_tabs WHERE window_id = ? ORDER BY position",
                    arguments: [windowID]
                )
                let tabs = try tabRows.map { tabRow -> RestoredTabState in
                    let tabID: String = tabRow["id"]
                    let historyRows = try Row.fetchAll(
                        db,
                        sql: "SELECT position, url, scroll_offset FROM browser_tab_history WHERE tab_id = ? ORDER BY position",
                        arguments: [tabID]
                    )
                    let history = historyRows.compactMap { (row: Row) -> URL? in URL(string: row["url"]) }
                    var offsets: [Int: Double] = [:]
                    for (position, row) in historyRows.enumerated() {
                        let offset: Double = row["scroll_offset"]
                        if offset > 0 { offsets[position] = offset }
                    }
                    return RestoredTabState(
                        history: history,
                        historyIndex: tabRow["history_index"],
                        cachedPages: [],
                        zoom: tabRow["zoom"],
                        title: tabRow["title"],
                        documentTitle: tabRow["document_title"],
                        scrollOffsets: offsets
                    )
                }
                let frame: PersistedWindowFrame?
                if let x: Double = windowRow["frame_x"],
                   let y: Double = windowRow["frame_y"],
                   let width: Double = windowRow["frame_width"],
                   let height: Double = windowRow["frame_height"] {
                    frame = PersistedWindowFrame(x: x, y: y, width: width, height: height)
                } else {
                    frame = nil
                }
                return PersistedBrowserWindow(
                    frame: frame,
                    tabs: tabs,
                    selectedIndex: windowRow["selected_tab_index"]
                )
            }
            return (keyWindowIndex, windows)
        }
        guard var snapshot else { return nil }
        // Startup needs only the representation currently visible in each tab. Older
        // Back/Forward entries remain cheap URL rows and are fetched from the shared
        // cache lazily if the reader traverses to them.
        let urls = Set(snapshot.windows.flatMap(\.tabs).compactMap { tab in
            tab.history.indices.contains(tab.historyIndex) ? tab.history[tab.historyIndex] : nil
        })
        let pages = try cache.pages(for: urls, accessedAt: accessedAt)
        for windowIndex in snapshot.windows.indices {
            for tabIndex in snapshot.windows[windowIndex].tabs.indices {
                let tab = snapshot.windows[windowIndex].tabs[tabIndex]
                snapshot.windows[windowIndex].tabs[tabIndex].cachedPages =
                    tab.history.indices.contains(tab.historyIndex)
                    ? [tab.history[tab.historyIndex]].compactMap { pages[$0] }
                    : []
            }
        }
        return PersistedApplicationSession(
            windows: snapshot.windows,
            keyWindowIndex: snapshot.keyWindowIndex
        )
    }

    public func clear() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM browser_windows")
            try db.execute(sql: "DELETE FROM browser_session")
        }
    }
}
