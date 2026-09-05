import Combine
import Foundation
import MajorTomCore

/// The one `TrustedIdentityStore` for the whole application.
///
/// One actor owns trust decisions for every tab and persists endpoint rows through the
/// shared database. Losing a record silently downgrades a later key substitution to a
/// first-use auto-trust, so there must never be competing in-memory catalogues.
enum SharedTrustedIdentityStore {
    static let shared: TrustedIdentityStore? = {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let legacyFileURL = root
            .appendingPathComponent("Major Tom", isDirectory: true)
            .appendingPathComponent("trusted-identities.json")
        if let database = SharedMajorTomDatabase.shared {
            return try? TrustedIdentityStore(
                database: database,
                legacyFileURL: legacyFileURL
            )
        }
        return try? TrustedIdentityStore(fileURL: legacyFileURL)
    }()
}

/// Bridges durable user TOFU decisions to private CloudKit while leaving observations,
/// certificate copies, counters, and seed policy in local SQLite rows.
@MainActor
final class TrustedIdentityCloudCoordinator: ObservableObject {
    static let shared = TrustedIdentityCloudCoordinator()

    @Published private(set) var conflictingEndpoints: Set<CapsuleEndpoint> = []

    private let defaults = UserDefaults.standard
    private let storageKey = "server-trust-cloud-metadata-v1"
    private let store = SharedTrustedIdentityStore.shared
    private let repository = SharedMajorTomDatabase.shared.map { ServerTrustSyncRepository(database: $0) }
    private var state = SyncedServerTrust()
    private var cloudObserver: AnyCancellable?

    private init() {
        if let repository {
            if let data = defaults.data(forKey: storageKey),
               let legacy = try? JSONDecoder().decode(SyncedServerTrust.self, from: data),
               (try? repository.importLegacy(legacy)) != nil {
                defaults.removeObject(forKey: storageKey)
            }
            state = (try? repository.load()) ?? SyncedServerTrust()
        } else if let data = defaults.data(forKey: storageKey),
                  let stored = try? JSONDecoder().decode(SyncedServerTrust.self, from: data) {
            state = stored
        }
        cloudObserver = ICloudSyncStore.shared.receivedServerTrust.sink { [weak self] incoming in
            Task { await self?.apply(incoming) }
        }
        Task { await start() }
    }

    private func start() async {
        guard let store else { return }
        let identities = await store.allIdentities()
        state = state.reconciled(with: identities, at: Date())
        persist()
        ICloudSyncStore.shared.configure(
            serverTrust: state.decisions.isEmpty ? nil : state
        )
        await store.setChangeHandler { [weak self] identities in
            Task { @MainActor in self?.localTrustChanged(identities) }
        }
    }

    private func localTrustChanged(_ identities: [TrustedServerIdentity]) {
        state = state.reconciled(with: identities, at: Date())
        conflictingEndpoints = state.conflictingEndpoints
        persist()
        ICloudSyncStore.shared.updateServerTrust(state)
    }

    private func apply(_ incoming: SyncedServerTrust) async {
        let merged = state.merging(incoming)
        let conflicts = merged.conflictingEndpoints
        var decisionsToApply = merged.activeByEndpoint.compactMap { endpoint, decisions in
            conflicts.contains(endpoint) ? nil : decisions.first
        }
        if let store {
            // A cloud conflict must not erase the decision already protecting this Mac.
            // Keep it in force until the user removes trust or explicitly approves a
            // newly presented key, either of which creates the resolving tombstones.
            decisionsToApply += await store.allIdentities().compactMap { identity in
                guard identity.source == .user, conflicts.contains(identity.endpoint) else {
                    return nil
                }
                return SyncedServerTrustDecision(
                    endpoint: identity.endpoint,
                    publicKeySHA256: identity.publicKeySHA256,
                    firstTrustedAt: identity.firstTrustedAt,
                    modifiedAt: identity.firstTrustedAt
                )
            }
            try? await store.applySyncedUserTrust(decisionsToApply)
        }
        state = merged
        conflictingEndpoints = conflicts
        persist()
    }

    private func persist() {
        if let repository, (try? repository.save(state)) != nil { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// The one favicon cache for the whole application.
///
/// Shared for the same reason the trusted-identity store is: each instance holds the file
/// in memory and rewrites it wholesale, so a second instance would overwrite the first's
/// records.
enum SharedFaviconStore {
    static let shared: FaviconStore? = {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return FaviconStore(fileURL: root
            .appendingPathComponent("Major Tom", isDirectory: true)
            .appendingPathComponent("favicons.json"))
    }()
}

/// The one local SQLite database for browser-owned durable state.
enum SharedMajorTomDatabase {
    static let shared: MajorTomDatabase? = {
        guard let fileURL = try? MajorTomDatabase.defaultFileURL() else { return nil }
        return try? MajorTomDatabase(fileURL: fileURL)
    }()
}

enum SharedPageCache {
    static let shared = SharedMajorTomDatabase.shared.map { database in
        PageCacheRepository(database: database)
    }
}

// PageCompletionState, CachedPage and RestoredTabState now live in MajorTomCore beside
// NavigationState, which owns the rules that operate on them. They are durable domain
// records, which the architecture document places in Core rather than in the app shell.

/// The single-window session format written by releases before native window tabs.
///
/// Nothing writes this any more. It is retained so `loadApplication()` can migrate a
/// session saved by an older build instead of discarding its tab caches.
struct RestoredWindowState: Codable {
    var tabs: [RestoredTabState]
    var selectedIndex: Int
}

struct RestoredBrowserWindowState: Codable {
    var frame: CGRect?
    var tabs: [RestoredTabState]
    var selectedIndex: Int
}

struct RestoredApplicationState: Codable {
    var windows: [RestoredBrowserWindowState]
    var keyWindowIndex: Int
}

@MainActor
final class SessionRestorationStore {
    static let shared = SessionRestorationStore()
    private let defaults = UserDefaults.standard
    private let key = "last-window-session-v1"
    private let applicationKey = "last-application-session-v2"
    private let sessionRepository: SessionRepository?
    private let pageCache: PageCacheRepository?

    private init() {
        sessionRepository = SharedMajorTomDatabase.shared.map(SessionRepository.init(database:))
        pageCache = SharedPageCache.shared
    }

    /// Migration only: reads a session written by a release that predates native
    /// window tabs. `saveApplication(_:)` is the only writer of session state now.
    func load() -> RestoredWindowState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RestoredWindowState.self, from: data)
    }

    func loadApplication() -> RestoredApplicationState? {
        if let repository = sessionRepository,
           let persisted = try? repository.load() {
            return Self.applicationState(persisted)
        }
        if let data = defaults.data(forKey: applicationKey),
           let state = try? JSONDecoder().decode(RestoredApplicationState.self, from: data) {
            saveApplication(state, importingEmbeddedCache: true)
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
        saveApplication(state, importingEmbeddedCache: true)
        return state
    }

    func saveApplication(_ state: RestoredApplicationState) {
        saveApplication(state, importingEmbeddedCache: false)
    }

    private func saveApplication(
        _ state: RestoredApplicationState,
        importingEmbeddedCache: Bool
    ) {
        if let sessionRepository, let pageCache {
            do {
                if importingEmbeddedCache {
                    for page in state.windows.flatMap(\.tabs).flatMap(\.cachedPages) {
                        try pageCache.store(page)
                    }
                }
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

    func clear() {
        try? sessionRepository?.clear()
        try? pageCache?.clear()
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
}

@MainActor
final class BrowsingHistoryStore: ObservableObject {
    static let shared = BrowsingHistoryStore()
    @Published private(set) var records: [BrowsingHistoryEntry] = []

    private let defaults = UserDefaults.standard
    private let key = "browsing-history-v1"
    private let repository: BrowsingHistoryRepository?

    init() {
        repository = SharedMajorTomDatabase.shared.map(BrowsingHistoryRepository.init(database:))

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
                BrowsingHistoryEntry(url: $0.url, visitedAt: $0.visitedAt, visitCount: 1)
            }
        }
    }

    func record(_ url: URL) {
        let now = Date()
        if let repository {
            guard (try? repository.record(url, at: now)) != nil else { return }
            let count = records.first(where: { $0.url == url })?.visitCount ?? 0
            records.removeAll {
                $0.url == url
                    || $0.visitedAt < now.addingTimeInterval(-BrowsingHistoryRepository.retention)
            }
            records.insert(
                BrowsingHistoryEntry(url: url, visitedAt: now, visitCount: count + 1),
                at: 0
            )
            return
        }

        let count = records.first(where: { $0.url == url })?.visitCount ?? 0
        records.removeAll { $0.url == url }
        records.insert(BrowsingHistoryEntry(url: url, visitedAt: now, visitCount: count + 1), at: 0)
        persistLegacyFallback()
    }

    func clear() {
        try? repository?.clear()
        records = []
        defaults.removeObject(forKey: key)
    }

    private func persistLegacyFallback() {
        let legacy = records.map {
            LegacyBrowsingHistoryRecord(id: UUID(), url: $0.url, visitedAt: $0.visitedAt)
        }
        guard let data = try? JSONEncoder().encode(legacy) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class GeminiInputDraftStore {
    static let shared = GeminiInputDraftStore()

    private let repository = SharedMajorTomDatabase.shared.map(
        GeminiInputDraftRepository.init(database:)
    )
    private var memoryFallback: [URL: String] = [:]

    func text(for promptURL: URL) -> String {
        if let repository {
            return (try? repository.draft(for: promptURL)?.text) ?? ""
        }
        return memoryFallback[promptURL] ?? ""
    }

    func save(_ text: String, for promptURL: URL) {
        if let repository {
            try? repository.save(text, for: promptURL)
        } else if text.isEmpty {
            memoryFallback.removeValue(forKey: promptURL)
        } else {
            memoryFallback[promptURL] = text
        }
    }

    func remove(for promptURL: URL) {
        try? repository?.remove(for: promptURL)
        memoryFallback.removeValue(forKey: promptURL)
    }
}
