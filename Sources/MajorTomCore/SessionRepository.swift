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
    private let database: BackForwardCacheDatabase

    public init(database: BackForwardCacheDatabase) {
        self.database = database
    }

    public func save(_ session: PersistedApplicationSession, at date: Date = Date()) throws {
        let encoder = JSONEncoder()
        var activeEntryIDs = Set<String>()
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
                    let tabID = tab.tabID.uuidString.lowercased()
                    try db.execute(
                        sql: """
                            INSERT INTO browser_tabs (
                                id, window_id, position, history_index, zoom
                            ) VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            tabID, windowID, tabPosition, tab.historyIndex, tab.zoom
                        ]
                    )
                    var entries = tab.entries.isEmpty
                        ? tab.history.enumerated().map { index, url in
                            BackForwardEntry(
                                url: url,
                                title: tab.cachedPages.first { $0.url == url }?.documentTitle
                                    ?? tab.cachedPages.first { $0.url == url }?.title,
                                page: tab.cachedPages.first { $0.url == url },
                                presentation: HistoryPresentationState(
                                    scrollY: tab.scrollOffsets?[index] ?? 0
                                )
                            )
                        }
                        : tab.entries
                    if entries.indices.contains(tab.historyIndex), entries[tab.historyIndex].title == nil {
                        entries[tab.historyIndex].title = tab.documentTitle ?? tab.title
                    }
                    for (historyPosition, entry) in entries.enumerated() {
                        activeEntryIDs.insert(entry.id.uuidString.lowercased())
                        let usesClientCertificate = entry.page?.clientCertificateID != nil
                        let page = usesClientCertificate ? nil : entry.page
                        if usesClientCertificate {
                            // A certificate-authenticated reload must also remove an older,
                            // unauthenticated representation for this same visit.
                            try db.execute(
                                sql: """
                                    UPDATE browser_tab_history
                                    SET response_status = NULL, response_meta = NULL,
                                        response_body = NULL, completion = NULL,
                                        received_at = NULL, client_certificate_id = NULL
                                    WHERE id = ?
                                    """,
                                arguments: [entry.id.uuidString.lowercased()]
                            )
                        }
                        try db.execute(
                            sql: "DELETE FROM browser_tab_history WHERE tab_id = ? AND position = ? AND id <> ?",
                            arguments: [tabID, historyPosition, entry.id.uuidString.lowercased()]
                        )
                        let state = try encoder.encode(entry.presentation)
                        try db.execute(
                            sql: """
                                INSERT INTO browser_tab_history (
                                    id, tab_id, position, url, title, favicon,
                                    response_status, response_meta, response_body, completion,
                                    received_at, client_certificate_id, presentation_state
                                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                ON CONFLICT(id) DO UPDATE SET
                                    tab_id = excluded.tab_id,
                                    position = excluded.position,
                                    url = excluded.url,
                                    title = excluded.title,
                                    favicon = excluded.favicon,
                                    response_status = COALESCE(excluded.response_status, response_status),
                                    response_meta = COALESCE(excluded.response_meta, response_meta),
                                    response_body = COALESCE(excluded.response_body, response_body),
                                    completion = COALESCE(excluded.completion, completion),
                                    received_at = COALESCE(excluded.received_at, received_at),
                                    presentation_state = excluded.presentation_state
                                """,
                            arguments: [
                                entry.id.uuidString.lowercased(), tabID, historyPosition,
                                entry.url.absoluteString, entry.title, entry.favicon,
                                page?.responseStatus,
                                page.map { page in
                                    page.responseMeta.flatMap { $0.isEmpty ? nil : $0 } ?? page.mimeType
                                },
                                page?.body, page?.completion.rawValue, page?.receivedAt,
                                page?.clientCertificateID?.uuidString.lowercased(), state
                            ]
                        )
                    }
                }
            }
            let storedEntryIDs = try String.fetchAll(db, sql: "SELECT id FROM browser_tab_history")
            let staleEntryIDs = storedEntryIDs.filter { !activeEntryIDs.contains($0) }
            for chunkStart in stride(from: 0, to: staleEntryIDs.count, by: 500) {
                let chunk = Array(staleEntryIDs[chunkStart..<min(chunkStart + 500, staleEntryIDs.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM browser_tab_history WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
            }
        }
    }

    public func load() throws -> PersistedApplicationSession? {
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
                        sql: "SELECT * FROM browser_tab_history WHERE tab_id = ? ORDER BY position",
                        arguments: [tabID]
                    )
                    let selectedIndex: Int = tabRow["history_index"]
                    let entries = historyRows.enumerated().compactMap { position, row in
                        BackForwardCacheStore.entry(row, includePage: position == selectedIndex)
                    }
                    let history = entries.map(\.url)
                    let current = entries.indices.contains(selectedIndex)
                        ? entries[selectedIndex]
                        : nil
                    return RestoredTabState(
                        tabID: UUID(uuidString: tabID) ?? UUID(),
                        entries: entries,
                        history: history,
                        historyIndex: tabRow["history_index"],
                        cachedPages: entries.compactMap(\.page),
                        zoom: tabRow["zoom"],
                        title: current?.title,
                        documentTitle: current?.title,
                        scrollOffsets: Dictionary(uniqueKeysWithValues: entries.indices.map {
                            ($0, entries[$0].presentation.scrollY)
                        })
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
        guard let snapshot else { return nil }
        return PersistedApplicationSession(
            windows: snapshot.windows,
            keyWindowIndex: snapshot.keyWindowIndex
        )
    }

    public func clear() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM browser_tab_history")
            try db.execute(sql: "DELETE FROM browser_windows")
            try db.execute(sql: "DELETE FROM browser_session")
        }
    }

}
