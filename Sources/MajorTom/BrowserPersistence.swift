import Combine
import Foundation

enum PageCompletionState: String, Codable {
    case complete
    case incomplete
    case stopped
    case failed
}

struct CachedPage: Codable {
    var url: URL
    var mimeType: String
    var body: Data
    var completion: PageCompletionState
    var receivedAt: Date
    var title: String? = nil
}

struct RestoredTabState: Codable {
    var history: [URL]
    var historyIndex: Int
    var cachedPages: [CachedPage]
    var zoom: Double
}

struct RestoredWindowState: Codable {
    var tabs: [RestoredTabState]
    var selectedIndex: Int
}

@MainActor
final class SessionRestorationStore {
    static let shared = SessionRestorationStore()
    private let defaults = UserDefaults.standard
    private let key = "last-window-session-v1"

    func load() -> RestoredWindowState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RestoredWindowState.self, from: data)
    }

    func save(_ state: RestoredWindowState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

struct BrowsingHistoryRecord: Codable, Identifiable {
    var id: UUID
    var url: URL
    var visitedAt: Date
}

@MainActor
final class BrowsingHistoryStore: ObservableObject {
    static let shared = BrowsingHistoryStore()
    @Published private(set) var records: [BrowsingHistoryRecord] = []

    private let defaults = UserDefaults.standard
    private let key = "browsing-history-v1"

    init() {
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([BrowsingHistoryRecord].self, from: data) {
            records = stored
        }
    }

    func record(_ url: URL) {
        records.insert(BrowsingHistoryRecord(id: UUID(), url: url, visitedAt: Date()), at: 0)
        if records.count > 5_000 { records.removeLast(records.count - 5_000) }
        persist()
    }

    func clear() {
        records = []
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}
