import Combine
import Foundation

/// The single-window session format written by releases before native window tabs.
///
/// Nothing writes this any more. It is retained so `loadApplication()` can migrate a
/// session saved by an older build instead of discarding its tab caches.
private struct RestoredWindowState: Codable {
    public var tabs: [RestoredTabState]
    public var selectedIndex: Int
}

public struct RestoredBrowserWindowState: Codable {
    public init(frame: CGRect?, tabs: [RestoredTabState], selectedIndex: Int) {
        self.frame = frame; self.tabs = tabs; self.selectedIndex = selectedIndex
    }
    public var frame: CGRect?
    public var tabs: [RestoredTabState]
    public var selectedIndex: Int
}

public struct RestoredApplicationState: Codable {
    public init(windows: [RestoredBrowserWindowState], keyWindowIndex: Int) {
        self.windows = windows; self.keyWindowIndex = keyWindowIndex
    }
    public var windows: [RestoredBrowserWindowState]
    public var keyWindowIndex: Int
}

@MainActor
public final class SessionRestorationStore {
    private let defaults: UserDefaults
    private let key = "last-window-session-v1"
    private let applicationKey = "last-application-session-v2"
    private let sessionRepository: SessionRepository?

    public init(defaults: UserDefaults, repository: SessionRepository?) {
        self.defaults = defaults
        sessionRepository = repository
    }

    /// Migration only: reads a session written by a release that predates native
    /// window tabs. `saveApplication(_:)` is the only writer of session state now.
    private func load() -> RestoredWindowState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RestoredWindowState.self, from: data)
    }

    public func loadApplication() -> RestoredApplicationState? {
        if let repository = sessionRepository,
           let persisted = try? repository.load() {
            return Self.applicationState(persisted)
        }
        if let data = defaults.data(forKey: applicationKey),
           let state = try? JSONDecoder().decode(RestoredApplicationState.self, from: data) {
            saveApplication(state)
            return state
        }
        // Migrate the old single-window format instead of discarding its tab caches.
        guard let legacy = load() else { return nil }
        let state = RestoredApplicationState(
            windows: [RestoredBrowserWindowState(
                frame: nil,
                tabs: legacy.tabs,
                selectedIndex: legacy.selectedIndex
            )],
            keyWindowIndex: 0
        )
        saveApplication(state)
        return state
    }

    public func saveApplication(_ state: RestoredApplicationState) {
        if let sessionRepository {
            do {
                try sessionRepository.save(Self.persistedSession(state))
                // The normalized rows are now authoritative. Removing both legacy
                // formats prevents future saves from rewriting cached bodies as JSON.
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: applicationKey)
                return
            } catch {
                // A session is best-effort state. Keep the prior format as a fallback if
                // opening or writing the local database fails.
            }
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: applicationKey)
    }

    public func clearBrowsingData(_ action: BrowsingDataAction, since cutoff: Date?) throws {
        if let sessionRepository {
            try sessionRepository.clearBrowsingData(action, since: cutoff)
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: applicationKey)
        } else if let state = loadApplication() {
            var windows = state.windows
            for window in windows.indices {
                for tab in windows[window].tabs.indices {
                    let old = windows[window].tabs[tab]
                    var navigation = NavigationState(restoring: old)
                    navigation.clearBrowsingData(action, since: cutoff)
                    windows[window].tabs[tab] = navigation.restorationState(
                        zoom: old.zoom, title: old.title, documentTitle: old.documentTitle
                    )
                }
            }
            let updated = RestoredApplicationState(windows: windows, keyWindowIndex: state.keyWindowIndex)
            defaults.set(try JSONEncoder().encode(updated), forKey: applicationKey)
            defaults.removeObject(forKey: key)
        }
    }

    public func saveApplicationAfterClearing(_ state: RestoredApplicationState) throws {
        if let sessionRepository {
            try sessionRepository.save(Self.persistedSession(state))
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: applicationKey)
        } else {
            defaults.set(try JSONEncoder().encode(state), forKey: applicationKey)
            defaults.removeObject(forKey: key)
        }
    }

    public func clear() {
        try? sessionRepository?.clear()
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: applicationKey)
    }

    private static func persistedSession(
        _ state: RestoredApplicationState
    ) -> PersistedApplicationSession {
        PersistedApplicationSession(
            windows: state.windows.map { window in
                PersistedBrowserWindow(
                    frame: window.frame.map {
                        PersistedWindowFrame(
                            x: $0.origin.x,
                            y: $0.origin.y,
                            width: $0.width,
                            height: $0.height
                        )
                    },
                    tabs: window.tabs,
                    selectedIndex: window.selectedIndex
                )
            },
            keyWindowIndex: state.keyWindowIndex
        )
    }

    private static func applicationState(
        _ state: PersistedApplicationSession
    ) -> RestoredApplicationState {
        RestoredApplicationState(
            windows: state.windows.map { window in
                RestoredBrowserWindowState(
                    frame: window.frame.map {
                        CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                    },
                    tabs: window.tabs,
                    selectedIndex: window.selectedIndex
                )
            },
            keyWindowIndex: state.keyWindowIndex
        )
    }
}

private struct LegacyBrowsingHistoryRecord: Codable {
    var id: UUID
    var url: URL
    var visitedAt: Date
    var title: String?
}

@MainActor
public final class BrowsingHistoryStore: ObservableObject {
    @Published public private(set) var records: [BrowsingHistoryEntry] = []

    private let defaults: UserDefaults
    private let key = "browsing-history-v1"
    private let repository: BrowsingHistoryRepository?

    public init(defaults: UserDefaults, repository: BrowsingHistoryRepository?) {
        self.defaults = defaults
        self.repository = repository

        if let repository {
            // Import is additive and transactional. The legacy blob remains available to
            // older builds until every row is safely in SQLite, then is removed locally.
            if let data = defaults.data(forKey: key),
               let stored = try? JSONDecoder().decode([LegacyBrowsingHistoryRecord].self, from: data),
               (try? repository.importLegacyVisits(stored.map { ($0.url, $0.visitedAt) })) != nil {
                defaults.removeObject(forKey: key)
            }
            records = (try? repository.entries()) ?? []
        } else if let data = defaults.data(forKey: key),
                  let stored = try? JSONDecoder().decode([LegacyBrowsingHistoryRecord].self, from: data) {
            records = stored.map {
                BrowsingHistoryEntry(
                    url: $0.url,
                    title: $0.title,
                    visitedAt: $0.visitedAt,
                    visitCount: 1
                )
            }
        }
    }

    public func record(_ url: URL, title: String? = nil) {
        let now = Date()
        if let repository {
            guard (try? repository.record(url, title: title, at: now)) != nil else { return }
            let existing = records.first(where: { $0.url == url })
            records.removeAll {
                $0.url == url
                    || $0.visitedAt < now.addingTimeInterval(-BrowsingHistoryRepository.retention)
            }
            records.insert(
                BrowsingHistoryEntry(
                    url: url,
                    title: title ?? existing?.title,
                    visitedAt: now,
                    visitCount: (existing?.visitCount ?? 0) + 1
                ),
                at: 0
            )
            return
        }

        let existing = records.first(where: { $0.url == url })
        records.removeAll { $0.url == url }
        records.insert(
            BrowsingHistoryEntry(
                url: url,
                title: title ?? existing?.title,
                visitedAt: now,
                visitCount: (existing?.visitCount ?? 0) + 1
            ),
            at: 0
        )
        persistLegacyFallback()
    }

    public func remove(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        if let repository {
            do {
                try repository.remove(urls: urls)
            } catch {
                return
            }
        }
        records.removeAll { urls.contains($0.url) }
        if repository == nil { persistLegacyFallback() }
    }

    public func clear(since cutoff: Date? = nil) throws {
        if let repository {
            try repository.clear(since: cutoff)
            records = try repository.entries()
            defaults.removeObject(forKey: key)
        } else {
            records.removeAll { BrowsingDataSelection.includes($0.visitedAt, since: cutoff) }
            persistLegacyFallback()
        }
    }

    private func persistLegacyFallback() {
        let legacy = records.map {
            LegacyBrowsingHistoryRecord(
                id: UUID(),
                url: $0.url,
                visitedAt: $0.visitedAt,
                title: $0.title
            )
        }
        guard let data = try? JSONEncoder().encode(legacy) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
public final class GeminiInputDraftStore {

    private let repository: GeminiInputDraftRepository?
    public init(repository: GeminiInputDraftRepository?) { self.repository = repository }
    private var memoryFallback: [URL: (text: String, updatedAt: Date)] = [:]

    public func text(for promptURL: URL) -> String {
        if let repository {
            return (try? repository.draft(for: promptURL)?.text) ?? ""
        }
        return memoryFallback[promptURL]?.text ?? ""
    }

    public func save(_ text: String, for promptURL: URL) {
        if let repository {
            try? repository.save(text, for: promptURL)
        } else if text.isEmpty {
            memoryFallback.removeValue(forKey: promptURL)
        } else {
            memoryFallback[promptURL] = (text, Date())
        }
    }

    public func clear(since cutoff: Date?) throws {
        try repository?.removeAll(since: cutoff)
        memoryFallback = memoryFallback.filter { !BrowsingDataSelection.includes($0.value.updatedAt, since: cutoff) }
    }

    public func remove(for promptURL: URL) {
        try? repository?.remove(for: promptURL)
        memoryFallback.removeValue(forKey: promptURL)
    }
}
