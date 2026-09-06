import CloudKit
import Combine
import CryptoKit
import Foundation
import MajorTomCore
import Security

enum ICloudSyncStatus: Equatable {
    case preparing
    case syncing
    case upToDate(Date)
    case unavailable(String)
    case removed
    case requiresNewerApp
    case failed(String)

    var label: String {
        switch self {
        case .preparing: "Preparing iCloud…"
        case .syncing: "Syncing with iCloud…"
        case .upToDate: "Up to date"
        case .unavailable(let reason): reason
        case .removed: "iCloud data for Major Tom was removed"
        case .requiresNewerApp: "A newer version of Major Tom is required to sync"
        case .failed(let reason): "iCloud sync error: \(reason)"
        }
    }
}

/// Incremental, outbox-backed private CloudKit synchronization.
@MainActor
final class ICloudSyncStore: NSObject, ObservableObject, @preconcurrency CKSyncEngineDelegate {
    static let shared = ICloudSyncStore()

    @Published private(set) var status: ICloudSyncStatus = .preparing
    @Published private(set) var remoteTabDevices: [CloudTabDeviceSnapshot] = []

    let receivedPreferences = PassthroughSubject<SyncedBrowserPreferences, Never>()
    let receivedAccountPreferences = PassthroughSubject<SyncedBrowserPreferences, Never>()
    let activeAccountChanged = PassthroughSubject<String, Never>()
    let receivedClientCertificates = PassthroughSubject<ClientCertificateSyncState, Never>()
    let receivedBookmarks = PassthroughSubject<SyncedBookmarks, Never>()

    let localDeviceID: UUID
    let localDeviceName: String

    private static let cloudModelMajor = 3
    private static let deviceIDKey = "icloud-device-id-v1"
    private static let cachedTabsKey = "icloud-tabs-cache-v2"
    private static let manifestRecordName = "data-model-manifest"
    private let zoneID = CKRecordZone.ID(zoneName: "MajorTomUserDataV2")
    private let legacyZoneID = CKRecordZone.ID(zoneName: "MajorTomUserData")
    private let defaults: UserDefaults
    private let localDatabase: MajorTomDatabase?
    private let repository: CloudSyncRepository?
    private let container: CKContainer?
    private let cloudDatabase: CKDatabase?
    private var engine: CKSyncEngine?
    private var activeAccount: String?
    private var attemptedGenerations: [String: Int64] = [:]
    private var writesBlocked = false
    private var localPreferences: SyncedBrowserPreferences?
    private var localClientCertificates: ClientCertificateSyncState?
    private var localBookmarks: SyncedBookmarks?
    private var localTabs: CloudTabDeviceSnapshot?
    private var migrationTask: Task<Void, Never>?
    private var keyValueObserver: AnyCancellable?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let value = defaults.string(forKey: Self.deviceIDKey), let id = UUID(uuidString: value) {
            localDeviceID = id
        } else {
            let id = UUID()
            localDeviceID = id
            defaults.set(id.uuidString, forKey: Self.deviceIDKey)
        }
        localDeviceName = Host.current().localizedName ?? "Mac"
        localDatabase = SharedMajorTomDatabase.shared
        repository = localDatabase.map(CloudSyncRepository.init(database:))
        if Self.hasRequiredEntitlements {
            let value = CKContainer(identifier: "iCloud.dev.gemi.major-tom")
            container = value
            cloudDatabase = value.privateCloudDatabase
        } else {
            container = nil
            cloudDatabase = nil
            status = .unavailable(Self.unsavedWarning(
                "This build is not provisioned for Major Tom iCloud sync"
            ))
        }
        super.init()
        activeAccount = try? repository?.activeAccountIdentityHash()

        if let data = defaults.data(forKey: Self.cachedTabsKey),
           let cached = try? decoder.decode([CloudTabDeviceSnapshot].self, from: data) {
            remoteTabDevices = cached.visibleCloudTabDevices(excluding: localDeviceID)
        }
        if container != nil, localDatabase != nil {
            migrationTask = Task { [weak self] in await self?.bootstrap() }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        keyValueObserver = NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        ).sink { [weak self] _ in
            Task { @MainActor in self?.applyUbiquitousPreferences() }
        }
        applyUbiquitousPreferences()
    }

    func configure(preferences: SyncedBrowserPreferences?) {
        localPreferences = preferences
    }

    func updatePreferences(_ snapshot: SyncedBrowserPreferences) {
        localPreferences = snapshot
        if let data = try? encoder.encode(snapshot) {
            NSUbiquitousKeyValueStore.default.set(data, forKey: "browser-preferences-v2")
            if let account = activeAccount {
                defaults.set(data, forKey: "browser-preferences-v2-\(account)")
            }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    func configure(clientCertificates: ClientCertificateSyncState?) {
        localClientCertificates = clientCertificates
        persistCertificatesIfReady()
    }

    func updateClientCertificates(_ snapshot: ClientCertificateSyncState) {
        localClientCertificates = snapshot
        persistCertificatesIfReady()
    }

    func configure(bookmarks: SyncedBookmarks?) {
        localBookmarks = bookmarks
        persistBookmarksIfReady()
    }

    func updateBookmarks(_ snapshot: SyncedBookmarks) {
        localBookmarks = snapshot
        persistBookmarksIfReady()
    }

    func updateTabs(_ tabs: [CloudTabSnapshot]) {
        let normalized = CloudTabURL.deduplicated(tabs)
        guard localTabs?.tabs != normalized else { return }
        localTabs = CloudTabDeviceSnapshot(
            deviceID: localDeviceID,
            deviceName: localDeviceName,
            updatedAt: Date(),
            tabs: normalized
        )
        guard let account = activeAccount, let repository else { return }
        try? repository.enqueue(CloudPendingChange(
            accountIdentityHash: account,
            recordType: "MTDeviceTabs",
            recordName: localDeviceID.uuidString.lowercased(),
            operation: .save
        ))
        requestSend()
    }

    func refresh() {
        guard let engine, !writesBlocked else { return }
        status = .syncing
        Task { [weak self] in
            do {
                try await engine.fetchChanges()
                try await engine.sendChanges()
            } catch {
                await MainActor.run { self?.status = .failed(Self.description(for: error)) }
            }
        }
    }

    func reuploadAfterCloudDataRemoval() {
        guard status == .removed, let account = activeAccount else { return }
        writesBlocked = false
        do {
            var state = try repository?.state(for: account) ?? CloudSyncState(accountIdentityHash: account)
            state.zoneState = .neverEstablished
            state.engineState = nil
            try repository?.save(state)
            configureEngine(for: account, serializedState: nil, createZone: true)
            enqueueAllLocalData(for: account)
            refresh()
        } catch {
            status = .failed(Self.description(for: error))
        }
    }

    private func bootstrap() async {
        guard let container else { return }
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                status = .unavailable(Self.unsavedWarning(Self.accountStatusDescription(accountStatus)))
                return
            }
            let userID = try await container.userRecordID()
            try await activateAccount(Self.identityHash(for: userID))
        } catch {
            status = .failed(Self.description(for: error))
        }
    }

    private func activateAccount(_ account: String) async throws {
        guard let repository, let cloudDatabase else { return }
        let priorActive = try repository.activeAccountIdentityHash()
        var state = try repository.state(for: account)

        if state.migrationPhase != .ready {
            status = .syncing
            if priorActive == nil {
                try BookmarkRepository(database: localDatabase!, accountIdentityHash: account)
                    .claimUnownedRows()
                try ClientCertificateSyncRepository(database: localDatabase!, accountIdentityHash: account)
                    .claimUnownedRows()
            }
            try await importV1Once(account: account)
            let bookmarkRepository = BookmarkRepository(
                database: localDatabase!, accountIdentityHash: account
            )
            try bookmarkRepository.replace(with: bookmarkRepository.collection())
            // Existing experimental v2 data is intentionally disposable. Reset this zone
            // before publishing the new manifest so older v2 builds can never alter it.
            _ = try? await cloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
            _ = try await cloudDatabase.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: []
            )
            state = try repository.state(for: account)
            state.modelMajor = Self.cloudModelMajor
            state.migratedFromV1 = true
            state.migrationPhase = .ready
            state.zoneState = .active
            state.engineState = nil
            state.updatedAt = Date()
            try repository.save(state)
            try repository.enqueue(CloudPendingChange(
                accountIdentityHash: account,
                recordType: "MTDataModelManifest",
                recordName: Self.manifestRecordName,
                operation: .save
            ))
            enqueueAllLocalData(for: account)
        }
        activeAccount = account
        try repository.saveActiveAccountIdentityHash(account)
        activeAccountChanged.send(account)
        if priorActive != nil, priorActive != account {
            publishAccountDataset(account)
        }
        publishAccountPreferences(account, isSwitch: priorActive != nil && priorActive != account)

        let restored = try repository.state(for: account).engineState.flatMap {
            try? decoder.decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        configureEngine(for: account, serializedState: restored, createZone: false)
        status = .syncing
        refresh()
    }

    private func configureEngine(
        for account: String,
        serializedState: CKSyncEngine.State.Serialization?,
        createZone: Bool
    ) {
        guard account == activeAccount, let cloudDatabase else { return }
        var configuration = CKSyncEngine.Configuration(
            database: cloudDatabase,
            stateSerialization: serializedState,
            delegate: self
        )
        configuration.automaticallySync = true
        let value = CKSyncEngine(configuration)
        if createZone {
            value.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        value.state.hasPendingUntrackedChanges = true
        engine = value
    }

    private func importV1Once(account: String) async throws {
        guard let cloudDatabase, let localDatabase else { return }
        let records = try await fetchLegacyRecords(from: cloudDatabase)
        var folders: [SyncedBookmarkFolder] = []
        var bookmarks: [SyncedBookmark] = []
        var certificates: [SyncedClientCertificateDescriptor] = []
        var associations: [SyncedClientCertificateAssociation] = []
        for record in records {
            guard let data = record.encryptedValues["payload"] as? Data else { continue }
            switch record.recordType {
            case "MTBookmarkFolder":
                if let value = try? decoder.decode(SyncedBookmarkFolder.self, from: data) { folders.append(value) }
            case "MTBookmark":
                if let value = try? decoder.decode(SyncedBookmark.self, from: data) { bookmarks.append(value) }
            case "MTClientCertificateDescriptor":
                if let value = try? decoder.decode(SyncedClientCertificateDescriptor.self, from: data) { certificates.append(value) }
            case "MTClientCertificateAssociation":
                if let value = try? decoder.decode(SyncedClientCertificateAssociation.self, from: data) { associations.append(value) }
            case "MTClientCertificates":
                if let value = try? decoder.decode(SyncedClientCertificates.self, from: data) {
                    let state = ClientCertificateSyncState(legacy: value)
                    certificates += state.certificates
                    associations += state.associations
                }
            case "MTPreferences":
                if let value = try? decoder.decode(SyncedBrowserPreferences.self, from: data) {
                    receivedPreferences.send(value)
                }
            default: break
            }
        }
        if !folders.isEmpty || !bookmarks.isEmpty {
            let incoming = SyncedBookmarks(folders: folders, bookmarks: bookmarks)
            let repository = BookmarkRepository(database: localDatabase, accountIdentityHash: account)
            let local = SyncedBookmarks(collection: try repository.collection(), modifiedAt: .distantPast)
            let merged = local.merging(incoming)
            try repository.replace(with: merged.collection)
            localBookmarks = merged
        }
        if !certificates.isEmpty || !associations.isEmpty {
            let incoming = ClientCertificateSyncState(
                certificates: certificates,
                associations: associations
            )
            let repository = ClientCertificateSyncRepository(
                database: localDatabase,
                accountIdentityHash: account
            )
            let loaded = try repository.load()
            let merged = loaded.state.merging(incoming)
            try repository.save(merged, localFlags: loaded.localFlags)
            localClientCertificates = merged
        }
    }

    private func fetchLegacyRecords(from database: CKDatabase) async throws -> [CKRecord] {
        let types = ["MTPreferences", "MTClientCertificates", "MTClientCertificateDescriptor",
                     "MTClientCertificateAssociation", "MTBookmarkFolder", "MTBookmark"]
        var records: [CKRecord] = []
        do {
            for type in types {
                var page = try await database.records(
                    matching: CKQuery(recordType: type, predicate: NSPredicate(value: true)),
                    inZoneWith: legacyZoneID,
                    desiredKeys: ["payload"]
                )
                while true {
                    for (_, result) in page.matchResults {
                        if case .success(let record) = result { records.append(record) }
                    }
                    guard let cursor = page.queryCursor else { break }
                    page = try await database.records(continuingMatchFrom: cursor, desiredKeys: ["payload"])
                }
            }
        } catch let error as CKError where error.code == .zoneNotFound {
            return []
        }
        return records
    }

    private func enqueueAllLocalData(for account: String) {
        guard let repository, let localDatabase else { return }
        if let collection = try? BookmarkRepository(
            database: localDatabase, accountIdentityHash: account
        ).collection() {
            for folder in collection.folders {
                try? repository.enqueue(CloudPendingChange(
                    accountIdentityHash: account,
                    recordType: BookmarkRepository.folderRecordType,
                    recordName: folder.id.uuidString,
                    operation: .save
                ))
                for bookmark in folder.bookmarks {
                    try? repository.enqueue(CloudPendingChange(
                        accountIdentityHash: account,
                        recordType: BookmarkRepository.bookmarkRecordType,
                        recordName: bookmark.id.uuidString,
                        operation: .save
                    ))
                }
            }
        }
        if let loaded = try? ClientCertificateSyncRepository(
            database: localDatabase, accountIdentityHash: account
        ).load().state {
            for descriptor in loaded.certificates where descriptor.deletedAt == nil {
                try? repository.enqueue(CloudPendingChange(
                    accountIdentityHash: account,
                    recordType: "MTClientCertificateDescriptor",
                    recordName: descriptor.id.uuidString,
                    operation: .save
                ))
            }
            for association in loaded.associations where association.deletedAt == nil {
                try? repository.enqueue(CloudPendingChange(
                    accountIdentityHash: account,
                    recordType: "MTClientCertificateAssociation",
                    recordName: association.id.uuidString,
                    operation: .save
                ))
            }
        }
    }

    private func publishAccountDataset(_ account: String) {
        guard let localDatabase else { return }
        if let collection = try? BookmarkRepository(database: localDatabase, accountIdentityHash: account).collection() {
            let value = SyncedBookmarks(collection: collection, modifiedAt: Date())
            localBookmarks = value
            receivedBookmarks.send(value)
        }
        if let value = try? ClientCertificateSyncRepository(
            database: localDatabase, accountIdentityHash: account
        ).load().state {
            localClientCertificates = value
            receivedClientCertificates.send(value)
        }
    }

    private func persistBookmarksIfReady() {
        guard let value = localBookmarks, let account = activeAccount else { return }
        persistBookmarks(value, account: account)
    }

    private func persistBookmarks(_ value: SyncedBookmarks, account: String) {
        guard let localDatabase else { return }
        do {
            try BookmarkRepository(database: localDatabase, accountIdentityHash: account)
                .replace(with: value.collection)
            requestSend()
        } catch { status = .failed(Self.description(for: error)) }
    }

    private func persistCertificatesIfReady() {
        guard let value = localClientCertificates, let account = activeAccount else { return }
        persistCertificates(value, account: account)
    }

    private func persistCertificates(_ value: ClientCertificateSyncState, account: String) {
        guard let localDatabase else { return }
        do {
            let repository = ClientCertificateSyncRepository(
                database: localDatabase, accountIdentityHash: account
            )
            let flags = (try? repository.load().localFlags) ?? [:]
            try repository.save(value, localFlags: flags)
            requestSend()
        } catch { status = .failed(Self.description(for: error)) }
    }

    private func requestSend() {
        guard let engine, !writesBlocked else { return }
        engine.state.hasPendingUntrackedChanges = true
        Task { try? await engine.sendChanges() }
    }

    // MARK: CKSyncEngineDelegate

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !writesBlocked, let account = activeAccount, let repository,
              let changes = try? repository.pendingChanges(for: account), !changes.isEmpty else {
            syncEngine.state.hasPendingUntrackedChanges = false
            return nil
        }
        var saves: [CKRecord] = []
        var deletes: [CKRecord.ID] = []
        attemptedGenerations.removeAll(keepingCapacity: true)
        for change in changes {
            let id = CKRecord.ID(recordName: change.recordName, zoneID: zoneID)
            let pending: CKSyncEngine.PendingRecordZoneChange = change.operation == .save
                ? .saveRecord(id) : .deleteRecord(id)
            guard context.options.scope.contains(pending) else { continue }
            switch change.operation {
            case .save:
                if let record = makeRecord(for: change) { saves.append(record) }
                else {
                    _ = try? repository.acknowledge(recordName: change.recordName,
                                                    generation: change.generation, for: account)
                    continue
                }
            case .delete:
                deletes.append(id)
            }
            attemptedGenerations[change.recordName] = change.generation
        }
        syncEngine.state.hasPendingUntrackedChanges = changes.count >= 200
        guard !saves.isEmpty || !deletes.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: saves,
            recordIDsToDelete: deletes,
            atomicByZone: false
        )
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            if case .accountChange = event {
                // Account events are allowed to replace the current engine below.
            } else if engine !== syncEngine {
                return
            }
            switch event {
            case .stateUpdate(let update):
                guard let account = activeAccount else { return }
                try repository?.saveEngineState(try encoder.encode(update.stateSerialization), for: account)
            case .accountChange(let change):
                let id: CKRecord.ID?
                switch change.changeType {
                case .signIn(let current): id = current
                case .switchAccounts(_, let current): id = current
                case .signOut:
                    engine = nil
                    status = .unavailable(Self.unsavedWarning("Sign in to iCloud to sync"))
                    return
                @unknown default:
                    id = nil
                }
                if let id {
                    let hash = Self.identityHash(for: id)
                    if hash != activeAccount { try await activateAccount(hash) }
                }
            case .fetchedRecordZoneChanges(let changes):
                try applyFetched(changes)
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                    writesBlocked = true
                    status = .removed
                    if let account = activeAccount {
                        var state = try repository?.state(for: account)
                        state?.zoneState = .removed
                        state?.engineState = nil
                        if let state { try repository?.save(state) }
                    }
                }
            case .sentRecordZoneChanges(let sent):
                try handleSent(sent)
            case .sentDatabaseChanges(let sent):
                if sent.savedZones.contains(where: { $0.zoneID == zoneID }), let account = activeAccount {
                    var state = try repository?.state(for: account)
                    state?.zoneState = .active
                    if let state { try repository?.save(state) }
                }
            case .willFetchChanges:
                status = .syncing
            case .didFetchChanges:
                if let account = activeAccount {
                    var state = try repository?.state(for: account)
                    state?.lastFetchedAt = Date()
                    state?.updatedAt = Date()
                    if let state { try repository?.save(state) }
                }
                status = .upToDate(Date())
            case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
                 .willSendChanges, .didSendChanges:
                break
            @unknown default:
                break
            }
        } catch {
            status = .failed(Self.description(for: error))
        }
    }

    private func makeRecord(for change: CloudPendingChange) -> CKRecord? {
        guard let localDatabase, let account = activeAccount else { return nil }
        let id = CKRecord.ID(recordName: change.recordName, zoneID: zoneID)
        let record = restoredRecord(named: change.recordName, account: account)
            ?? CKRecord(recordType: change.recordType, recordID: id)
        do {
            let payload: Data
            switch change.recordType {
            case "MTDataModelManifest":
                payload = try envelope(CloudDataModelManifest(
                    formatMajor: Self.cloudModelMajor,
                    minimumReaderMajor: Self.cloudModelMajor,
                    minimumWriterMajor: Self.cloudModelMajor,
                    createdAt: Date(timeIntervalSince1970: 0)
                ), prior: change.recordName)
            case BookmarkRepository.folderRecordType:
                guard let uuid = UUID(uuidString: change.recordName),
                      let value = try BookmarkRepository(database: localDatabase, accountIdentityHash: account)
                        .folderPayload(id: uuid) else { return nil }
                payload = try envelope(value, prior: change.recordName)
            case BookmarkRepository.bookmarkRecordType:
                guard let uuid = UUID(uuidString: change.recordName),
                      let value = try BookmarkRepository(database: localDatabase, accountIdentityHash: account)
                        .bookmarkPayload(id: uuid) else { return nil }
                payload = try envelope(value, prior: change.recordName)
            case "MTClientCertificateDescriptor":
                guard let uuid = UUID(uuidString: change.recordName),
                      let value = try ClientCertificateSyncRepository(database: localDatabase, accountIdentityHash: account)
                        .certificatePayload(id: uuid) else { return nil }
                payload = try envelope(value, prior: change.recordName)
            case "MTClientCertificateAssociation":
                guard let uuid = UUID(uuidString: change.recordName),
                      let value = try ClientCertificateSyncRepository(database: localDatabase, accountIdentityHash: account)
                        .associationPayload(id: uuid) else { return nil }
                payload = try envelope(value, prior: change.recordName)
            case "MTDeviceTabs":
                guard let localTabs else { return nil }
                payload = try envelope(localTabs, prior: change.recordName)
            default: return nil
            }
            record.encryptedValues["payload"] = payload as CKRecordValue
            return record
        } catch {
            status = .failed(Self.description(for: error))
            return nil
        }
    }

    private func envelope<Value: CloudSyncPayload>(_ value: Value, prior recordName: String) throws -> Data {
        if let account = activeAccount,
           let prior = try repository?.recordState(recordName: recordName, for: account)?.serverPayload,
           var decoded = try? CloudRecordPayload<Value>(decoding: prior) {
            decoded.model = value
            return try decoded.encoded()
        }
        return try CloudRecordPayload(model: value).encoded()
    }

    private func restoredRecord(named name: String, account: String) -> CKRecord? {
        guard let state = try? repository?.recordState(recordName: name, for: account),
              let data = state.systemFields else { return nil }
        let coder = try? NSKeyedUnarchiver(forReadingFrom: data)
        coder?.requiresSecureCoding = true
        defer { coder?.finishDecoding() }
        return coder.flatMap(CKRecord.init(coder:))
    }

    private func applyFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) throws {
        guard let account = activeAccount, let localDatabase else { return }
        let pendingDeletes = Set((try repository?.pendingChanges(for: account) ?? [])
            .filter { $0.operation == .delete }.map(\.recordName))
        if let manifestRecord = changes.modifications.map(\.record).first(where: {
            $0.recordType == "MTDataModelManifest"
        }), let manifest: CloudDataModelManifest = decodeRecord(manifestRecord) {
            guard manifest.compatibility(readerMajor: Self.cloudModelMajor,
                                         writerMajor: Self.cloudModelMajor) == .compatible else {
                writesBlocked = true
                status = .requiresNewerApp
                return
            }
        }
        try applyBookmarkChanges(changes, account: account, database: localDatabase,
                                 pendingDeletes: pendingDeletes)
        try applyCertificateChanges(changes, account: account, database: localDatabase,
                                    pendingDeletes: pendingDeletes)
        applyTabChanges(changes)
        for record in changes.modifications.map(\.record) {
            try saveRecordMetadata(record, account: account)
        }
        for deletion in changes.deletions {
            if deletion.recordType == "MTDeviceTabs" {
                remoteTabDevices.removeAll { $0.deviceID.uuidString.lowercased() == deletion.recordID.recordName }
            }
        }
    }

    private func applyBookmarkChanges(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
        account: String,
        database: MajorTomDatabase,
        pendingDeletes: Set<String>
    ) throws {
        let repository = BookmarkRepository(database: database, accountIdentityHash: account)
        var folders = try repository.collection().folders
        guard !folders.isEmpty else { return }
        let favoriteID = folders[0].id
        var pendingFolders = try repository.pendingFolderIDs()
        var folderOrder = Dictionary(uniqueKeysWithValues: folders.enumerated().map {
            ($0.element.id, String(format: "%08d", $0.offset))
        })
        var bookmarkOrder: [UUID: String] = [:]
        for folder in folders {
            for (index, bookmark) in folder.bookmarks.enumerated() {
                bookmarkOrder[bookmark.id] = String(format: "%08d", index)
            }
        }
        for record in changes.modifications.map(\.record) where record.recordID.zoneID == zoneID {
            guard !pendingDeletes.contains(record.recordID.recordName) else { continue }
            if record.recordType == BookmarkRepository.folderRecordType,
               let payload: CloudBookmarkFolderPayload = decodeRecord(record) {
                if let index = folders.firstIndex(where: { $0.id == payload.id }) {
                    folders[index].name = payload.id == favoriteID ? BookmarkCollection.favoritesName : payload.name
                } else {
                    folders.append(BookmarkFolder(id: payload.id, name: payload.name))
                }
                folderOrder[payload.id] = payload.orderKey
                let resolvedBookmarks = pendingFolders.compactMap {
                    $0.value == payload.id ? $0.key : nil
                }
                for bookmarkID in resolvedBookmarks {
                    guard let bookmark = folders.flatMap(\.bookmarks).first(where: { $0.id == bookmarkID }),
                          let destination = folders.firstIndex(where: { $0.id == payload.id }) else { continue }
                    for index in folders.indices { folders[index].bookmarks.removeAll { $0.id == bookmarkID } }
                    folders[destination].bookmarks.append(bookmark)
                    pendingFolders[bookmarkID] = nil
                }
            }
        }
        for deletion in changes.deletions where deletion.recordType == BookmarkRepository.folderRecordType {
            guard let id = UUID(uuidString: deletion.recordID.recordName), id != favoriteID,
                  let index = folders.firstIndex(where: { $0.id == id }) else { continue }
            let children = folders[index].bookmarks
            folders.remove(at: index)
            folders[0].bookmarks.append(contentsOf: children)
            pendingFolders = pendingFolders.filter { $0.value != id }
        }
        for record in changes.modifications.map(\.record)
        where record.recordType == BookmarkRepository.bookmarkRecordType {
            guard !pendingDeletes.contains(record.recordID.recordName) else { continue }
            guard let payload: CloudBookmarkPayload = decodeRecord(record) else { continue }
            for index in folders.indices { folders[index].bookmarks.removeAll { $0.id == payload.id } }
            let destination = folders.firstIndex { $0.id == payload.folderID }
            if destination == nil { pendingFolders[payload.id] = payload.folderID }
            else { pendingFolders[payload.id] = nil }
            bookmarkOrder[payload.id] = payload.orderKey
            folders[destination ?? 0].bookmarks.append(Bookmark(
                id: payload.id, title: payload.title, url: payload.url,
                addedAt: payload.addedAt, favicon: payload.favicon
            ))
        }
        for deletion in changes.deletions where deletion.recordType == BookmarkRepository.bookmarkRecordType {
            guard let id = UUID(uuidString: deletion.recordID.recordName) else { continue }
            for index in folders.indices { folders[index].bookmarks.removeAll { $0.id == id } }
            pendingFolders[id] = nil
        }
        for index in folders.indices {
            folders[index].bookmarks.sort {
                (bookmarkOrder[$0.id] ?? "~") < (bookmarkOrder[$1.id] ?? "~")
            }
        }
        folders.sort { (folderOrder[$0.id] ?? "~") < (folderOrder[$1.id] ?? "~") }
        if let favorite = folders.firstIndex(where: { $0.id == favoriteID }), favorite != 0 {
            folders.insert(folders.remove(at: favorite), at: 0)
        }
        let collection = BookmarkCollection(folders: folders)
        try repository.replaceFromCloud(with: collection)
        try repository.savePendingFolderIDs(pendingFolders)
        let value = SyncedBookmarks(collection: collection, modifiedAt: Date())
        localBookmarks = value
        receivedBookmarks.send(value)
    }

    private func applyCertificateChanges(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
        account: String,
        database: MajorTomDatabase,
        pendingDeletes: Set<String>
    ) throws {
        let repository = ClientCertificateSyncRepository(database: database, accountIdentityHash: account)
        let loaded = try repository.load()
        var descriptors = Dictionary(uniqueKeysWithValues: loaded.state.certificates.map { ($0.id, $0) })
        var associations = Dictionary(uniqueKeysWithValues: loaded.state.associations.map { ($0.id, $0) })
        let now = Date()
        for record in changes.modifications.map(\.record) {
            guard !pendingDeletes.contains(record.recordID.recordName) else { continue }
            if record.recordType == "MTClientCertificateDescriptor",
               let payload: CloudClientCertificateDescriptorPayload = decodeRecord(record) {
                descriptors[payload.id] = SyncedClientCertificateDescriptor(
                    descriptor: payload.descriptor, modifiedAt: now
                )
            } else if record.recordType == "MTClientCertificateAssociation",
                      let payload: CloudClientCertificateAssociationPayload = decodeRecord(record) {
                associations[payload.association.id] = SyncedClientCertificateAssociation(
                    association: payload.association, modifiedAt: now
                )
            }
        }
        for deletion in changes.deletions {
            guard let id = UUID(uuidString: deletion.recordID.recordName) else { continue }
            if deletion.recordType == "MTClientCertificateDescriptor" {
                descriptors[id] = nil
                associations = associations.filter { $0.value.association.certificateID != id }
            } else if deletion.recordType == "MTClientCertificateAssociation" {
                associations[id] = nil
            }
        }
        let value = ClientCertificateSyncState(
            certificates: Array(descriptors.values), associations: Array(associations.values)
        )
        try repository.saveFromCloud(value, localFlags: loaded.localFlags)
        localClientCertificates = value
        receivedClientCertificates.send(value)
    }

    private func applyTabChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        var devices = Dictionary(uniqueKeysWithValues: remoteTabDevices.map { ($0.deviceID, $0) })
        for record in changes.modifications.map(\.record) where record.recordType == "MTDeviceTabs" {
            guard let value: CloudTabDeviceSnapshot = decodeRecord(record),
                  value.deviceID != localDeviceID else { continue }
            devices[value.deviceID] = value
        }
        for deletion in changes.deletions where deletion.recordType == "MTDeviceTabs" {
            if let id = UUID(uuidString: deletion.recordID.recordName) { devices[id] = nil }
        }
        let values = Array(devices.values)
        remoteTabDevices = values.visibleCloudTabDevices(excluding: localDeviceID)
        if let data = try? encoder.encode(values) { defaults.set(data, forKey: Self.cachedTabsKey) }
    }

    private func decodeRecord<Value: CloudSyncPayload>(_ record: CKRecord) -> Value? {
        guard let data = record.encryptedValues["payload"] as? Data,
              let envelope = try? CloudRecordPayload<Value>(decoding: data) else { return nil }
        return envelope.model
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) throws {
        guard let account = activeAccount, let repository else { return }
        for record in sent.savedRecords {
            if let generation = attemptedGenerations[record.recordID.recordName] {
                try repository.acknowledge(recordName: record.recordID.recordName,
                                           generation: generation, for: account)
            }
            try saveRecordMetadata(record, account: account)
        }
        for id in sent.deletedRecordIDs {
            if let generation = attemptedGenerations[id.recordName] {
                try repository.acknowledge(recordName: id.recordName,
                                           generation: generation, for: account)
            }
        }
        for (id, error) in sent.failedRecordDeletes where error.code == .unknownItem {
            if let generation = attemptedGenerations[id.recordName] {
                try repository.acknowledge(recordName: id.recordName,
                                           generation: generation, for: account)
            }
        }
        for failure in sent.failedRecordSaves where failure.error.code == .serverRecordChanged {
            if let server = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                try saveRecordMetadata(server, account: account)
            }
        }
        var state = try repository.state(for: account)
        state.lastSentAt = Date()
        state.updatedAt = Date()
        try repository.save(state)
        syncPendingFlag()
    }

    private func saveRecordMetadata(_ record: CKRecord, account: String) throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        try repository?.saveRecordState(CloudRecordState(
            accountIdentityHash: account,
            recordType: record.recordType,
            recordName: record.recordID.recordName,
            systemFields: archiver.encodedData,
            serverPayload: record.encryptedValues["payload"] as? Data,
            payloadDigest: nil,
            lastSeenEpoch: nil,
            updatedAt: Date()
        ))
    }

    private func syncPendingFlag() {
        guard let engine, let account = activeAccount else { return }
        engine.state.hasPendingUntrackedChanges =
            (try? repository?.hasPendingChanges(for: account)) ?? false
    }

    private static func identityHash(for recordID: CKRecord.ID) -> String {
        SHA256.hash(data: Data(recordID.recordName.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func applyUbiquitousPreferences() {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: "browser-preferences-v2"),
              let value = try? decoder.decode(SyncedBrowserPreferences.self, from: data),
              value.shouldReplace(localPreferences) else { return }
        localPreferences = value
        if let account = activeAccount {
            defaults.set(data, forKey: "browser-preferences-v2-\(account)")
        }
        receivedPreferences.send(value)
    }

    private func publishAccountPreferences(_ account: String, isSwitch: Bool) {
        let cached = defaults.data(forKey: "browser-preferences-v2-\(account)")
            .flatMap { try? decoder.decode(SyncedBrowserPreferences.self, from: $0) }
        if let cached {
            localPreferences = cached
            if isSwitch { receivedAccountPreferences.send(cached) }
            else { receivedPreferences.send(cached) }
        } else if isSwitch {
            let value = SyncedBrowserPreferences(
                preferences: BrowserPreferences(), modifiedAt: .distantPast
            )
            localPreferences = value
            receivedAccountPreferences.send(value)
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private static func accountStatusDescription(_ status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: "Sign in to iCloud to sync"
        case .restricted: "iCloud access is restricted"
        case .couldNotDetermine: "iCloud status is unavailable"
        case .temporarilyUnavailable: "iCloud is temporarily unavailable"
        case .available: "Up to date"
        @unknown default: "iCloud is unavailable"
        }
    }

    private static func unsavedWarning(_ reason: String) -> String {
        "\(reason). Bookmarks and identities are saved on this Mac but are not syncing."
    }

    private static var hasRequiredEntitlements: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
              ) as? [String],
              SecTaskCopyValueForEntitlement(task, "aps-environment" as CFString, nil) != nil,
              SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil
              ) != nil else { return false }
        return identifiers.contains("iCloud.dev.gemi.major-tom")
    }

    private static func description(for error: Error) -> String {
        let cloudError = error as? CKError
        switch cloudError?.code {
        case .notAuthenticated: return unsavedWarning("Sign in to iCloud to sync")
        case .networkUnavailable, .networkFailure: return "Offline; changes are saved locally"
        case .permissionFailure: return unsavedWarning(
            "This build is not provisioned for Major Tom iCloud sync"
        )
        default: return error.localizedDescription
        }
    }
}
