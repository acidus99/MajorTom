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

/// Bridges durable user TOFU decisions to private CloudKit while leaving observations,
/// certificate copies, counters, and seed policy in the local JSON store.
@MainActor
final class TrustedIdentityCloudCoordinator: ObservableObject {
    static let shared = TrustedIdentityCloudCoordinator()

    @Published private(set) var conflictingEndpoints: Set<CapsuleEndpoint> = []

    private let defaults = UserDefaults.standard
    private let storageKey = "server-trust-cloud-metadata-v1"
    private let store = SharedTrustedIdentityStore.shared
    private var state = SyncedServerTrust()
    private var cloudObserver: AnyCancellable?

    private init() {
        if let data = defaults.data(forKey: storageKey),
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

    /// Migration only: reads a session written by a release that predates native
    /// window tabs. `saveApplication(_:)` is the only writer of session state now.
    func load() -> RestoredWindowState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RestoredWindowState.self, from: data)
    }

    func loadApplication() -> RestoredApplicationState? {
        if let data = defaults.data(forKey: applicationKey),
           let state = try? JSONDecoder().decode(RestoredApplicationState.self, from: data) {
            return state
        }
        // Migrate the old single-window format instead of discarding its tab caches.
        guard let legacy = load() else { return nil }
        return RestoredApplicationState(
            windows: [RestoredBrowserWindowState(
                frame: nil,
                tabs: legacy.tabs,
                selectedIndex: legacy.selectedIndex
            )],
            keyWindowIndex: 0
        )
    }

    func saveApplication(_ state: RestoredApplicationState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: applicationKey)
    }

    func clear() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: applicationKey)
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
    private var persistTask: Task<Void, Never>?

    init() {
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([BrowsingHistoryRecord].self, from: data) {
            records = stored
        }
    }

    func record(_ url: URL) {
        records.insert(BrowsingHistoryRecord(id: UUID(), url: url, visitedAt: Date()), at: 0)
        if records.count > 5_000 { records.removeLast(records.count - 5_000) }
        schedulePersist()
    }

    func clear() {
        persistTask?.cancel()
        persistTask = nil
        records = []
        defaults.removeObject(forKey: key)
    }

    /// Writes any coalesced visits immediately. Call before quitting.
    func flushPendingWrites() {
        guard persistTask != nil else { return }
        persist()
    }

    /// Coalesces visits into one write.
    ///
    /// The whole list — up to five thousand records — is re-encoded on every write, so
    /// doing it per navigation meant a growing JSON encode and a UserDefaults write on
    /// every page load.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        persistTask?.cancel()
        persistTask = nil
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}
