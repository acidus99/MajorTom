import Combine
import Foundation
import MajorTomCore

/// The one `TrustedIdentityStore` for the whole application.
///
/// `TrustedIdentityStore` snapshots the JSON file into memory once in `init` and
/// every write persists that whole snapshot. Constructing one per tab, per window
/// and again for the Settings pane therefore meant each instance overwrote the file
/// with its own stale view: trusting a capsule in one tab erased every identity
/// trusted in another tab since that tab was opened. Losing a record silently
/// downgrades a later key substitution to a first-use auto-trust, so this has to be
/// a single shared instance.
enum SharedTrustedIdentityStore {
    static let shared: TrustedIdentityStore? = {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return try? TrustedIdentityStore(fileURL: root
            .appendingPathComponent("Major Tom", isDirectory: true)
            .appendingPathComponent("trusted-identities.json"))
    }()
}

/// Capsule identities known ahead of first contact, read once per launch.
///
/// Legacy Major Tom read the same `certs.csv` from Application Support, with the path
/// overridable by `MAJOR_TOM_CERT_SEED_CSV`. A seeded capsule is trusted silently on
/// first connection and a *mismatch* against a seed is treated as a real warning rather
/// than a first-use auto-trust, which is the whole point: without seeds, the very first
/// connection to a capsule is the one moment an interception cannot be detected.
///
/// A missing or unreadable file yields no seeds, which simply restores trust-on-first-use
/// for every capsule.
enum SharedSeedIdentities {
    static let all: Set<SeedServerIdentity> = load()

    static var fileURL: URL? {
        let override = ProcessInfo.processInfo.environment["MAJOR_TOM_CERT_SEED_CSV"] ?? ""
        if !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return root
            .appendingPathComponent("Major Tom", isDirectory: true)
            .appendingPathComponent("certs.csv")
    }

    private static func load() -> Set<SeedServerIdentity> {
        guard let fileURL,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return SeedIdentityCSV.parse(text)
    }
}

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
    var documentTitle: String? = nil
}

struct RestoredTabState: Codable {
    var history: [URL]
    var historyIndex: Int
    var cachedPages: [CachedPage]
    var zoom: Double
    var title: String? = nil
    var documentTitle: String? = nil
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
