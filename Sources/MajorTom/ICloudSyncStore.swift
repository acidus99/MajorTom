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
    case failed(String)

    var label: String {
        switch self {
        case .preparing: "Preparing iCloud…"
        case .syncing: "Syncing with iCloud…"
        case .upToDate: "Up to date"
        case .unavailable(let reason): reason
        case .failed(let reason): "iCloud sync error: \(reason)"
        }
    }
}

/// The app's private CloudKit adapter. Local repositories remain the immediate source of
/// truth so a signed-out or offline Mac behaves exactly like a non-iCloud build.
/// CloudKit records contain encrypted JSON payloads and no searchable browsing data.
@MainActor
final class ICloudSyncStore: ObservableObject {
    static let shared = ICloudSyncStore()

    @Published private(set) var status: ICloudSyncStatus = .preparing
    @Published private(set) var remoteTabDevices: [CloudTabDeviceSnapshot] = []

    let receivedPreferences = PassthroughSubject<SyncedBrowserPreferences, Never>()
    let receivedClientCertificates = PassthroughSubject<ClientCertificateSyncState, Never>()
    let receivedBookmarks = PassthroughSubject<SyncedBookmarks, Never>()
    let receivedServerTrust = PassthroughSubject<SyncedServerTrust, Never>()

    let localDeviceID: UUID
    let localDeviceName: String

    private let container: CKContainer?
    private let database: CKDatabase?
    private let defaults: UserDefaults
    /// Kept indefinitely as the compatibility feed for pre-v2 clients.
    private let legacyZoneID = CKRecordZone.ID(zoneName: "MajorTomUserData")
    /// New clients isolate their records so a future data model never changes the
    /// meaning of records an older app already understands.
    private let zoneID = CKRecordZone.ID(zoneName: "MajorTomUserDataV2")
    private static let dataModelMajor = 2
    private let synchronizedRecordTypes: [CKRecord.RecordType] = [
        "MTPreferences",
        "MTDeviceTabs",
        "MTClientCertificateDescriptor",
        "MTClientCertificateAssociation",
        "MTBookmarkFolder",
        "MTBookmark",
        "MTServerTrust",
    ]
    private let preferencesRecordID: CKRecord.ID
    private let tabsRecordID: CKRecord.ID
    private let manifestRecordID: CKRecord.ID
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()
    private var localPreferences: SyncedBrowserPreferences?
    private var localClientCertificates: ClientCertificateSyncState?
    private var localBookmarks: SyncedBookmarks?
    private var localServerTrust: SyncedServerTrust?
    private var localTabs: CloudTabDeviceSnapshot?
    private var syncTask: Task<Void, Never>?
    private var pendingSync = false
    /// Set by any local mutation, cleared by a sync that completes successfully.
    private var hasLocalChangesSinceSync = true
    private var lastSuccessfulSync: Date?
    /// How long a refresh with nothing local to push will trust the last result.
    private static let refreshCoalescingInterval: TimeInterval = 5 * 60
    /// CloudKit rejects a CKModifyRecordsOperation containing more than 400 items.
    private static let maximumRecordsPerModify = 400

    private static let deviceIDKey = "icloud-device-id-v1"
    private static let cachedTabsKey = "icloud-tabs-cache-v1"

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
        if Self.hasCloudKitEntitlement {
            let container = CKContainer(identifier: "iCloud.dev.gemi.major-tom")
            self.container = container
            database = container.privateCloudDatabase
        } else {
            container = nil
            database = nil
            status = .unavailable("This build is not provisioned for Major Tom iCloud sync")
        }
        preferencesRecordID = CKRecord.ID(recordName: "preferences", zoneID: zoneID)
        tabsRecordID = CKRecord.ID(
            recordName: "tabs-\(localDeviceID.uuidString.lowercased())",
            zoneID: zoneID
        )
        manifestRecordID = CKRecord.ID(recordName: "data-model-manifest", zoneID: zoneID)

        if let data = defaults.data(forKey: Self.cachedTabsKey),
           let cached = try? decoder.decode([CloudTabDeviceSnapshot].self, from: data) {
            remoteTabDevices = cached.visibleCloudTabDevices(excluding: localDeviceID)
        }
    }

    func configure(preferences: SyncedBrowserPreferences?) {
        localPreferences = preferences
        markLocalChange()
    }

    func updatePreferences(_ snapshot: SyncedBrowserPreferences) {
        localPreferences = snapshot
        markLocalChange()
    }

    func configure(clientCertificates: ClientCertificateSyncState?) {
        localClientCertificates = clientCertificates
        markLocalChange()
    }

    func updateClientCertificates(_ snapshot: ClientCertificateSyncState) {
        localClientCertificates = snapshot
        markLocalChange()
    }

    func configure(bookmarks: SyncedBookmarks?) {
        localBookmarks = bookmarks
        markLocalChange()
    }

    func updateBookmarks(_ snapshot: SyncedBookmarks) {
        localBookmarks = snapshot
        markLocalChange()
    }

    func configure(serverTrust: SyncedServerTrust?) {
        localServerTrust = serverTrust
        markLocalChange()
    }

    func updateServerTrust(_ snapshot: SyncedServerTrust) {
        localServerTrust = snapshot
        markLocalChange()
    }

    func updateTabs(_ tabs: [CloudTabSnapshot]) {
        // Compare the tabs themselves, not the snapshot: it carries a fresh updatedAt
        // every time, so an unchanged set still looked like a change. The hourly
        // heartbeat calls straight through to here, and every title change during a page
        // load reaches it too, so this is the difference between a sync an hour and a
        // sync whenever a heading streams in.
        guard localTabs?.tabs != tabs else { return }
        localTabs = CloudTabDeviceSnapshot(
            deviceID: localDeviceID,
            deviceName: localDeviceName,
            updatedAt: Date(),
            tabs: tabs
        )
        markLocalChange()
    }

    /// Pulls anything new from CloudKit. Called on activation and on demand, so it may
    /// arrive many times in a row with nothing to contribute.
    func refresh() {
        if !hasLocalChangesSinceSync,
           let lastSuccessfulSync,
           Date().timeIntervalSince(lastSuccessfulSync) < Self.refreshCoalescingInterval {
            return
        }
        requestSync()
    }

    private func markLocalChange() {
        hasLocalChangesSinceSync = true
        requestSync()
    }

    private func requestSync() {
        guard syncTask == nil else {
            pendingSync = true
            return
        }
        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.performSync()
            self.syncTask = nil
            if self.pendingSync {
                self.pendingSync = false
                self.requestSync()
            }
        }
    }

    private func performSync() async {
        guard let container, let database else {
            status = .unavailable("This build is not provisioned for Major Tom iCloud sync")
            return
        }
        // Several stores configure themselves independently during launch, which can
        // queue a handful of very short follow-up syncs. Once CloudKit is up to date,
        // keep that stable status visible while those routine background passes run
        // instead of flashing "Syncing" between each one. Initial and recovery syncs
        // still advertise that work, and failures replace the status immediately.
        if case .upToDate = status {
            // Preserve the last successful status during a background refresh.
        } else {
            status = .syncing
        }
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                status = .unavailable(Self.accountStatusDescription(accountStatus))
                return
            }

            _ = try await database.save(CKRecordZone(zoneID: legacyZoneID))
            _ = try await database.save(CKRecordZone(zoneID: zoneID))

            let manifestRecord = try await fetchManifest(from: database)
            let v2Records: [CKRecord]
            if let manifestRecord {
                guard let data = manifestRecord.encryptedValues["payload"] as? Data,
                      let manifest = try? decoder.decode(CloudDataModelManifest.self, from: data)
                else {
                    status = .failed("The iCloud data-model manifest is unreadable")
                    return
                }
                switch manifest.compatibility(
                    readerMajor: Self.dataModelMajor,
                    writerMajor: Self.dataModelMajor
                ) {
                case .compatible:
                    break
                case .requiresNewerApp:
                    status = .unavailable("iCloud data requires a newer version of Major Tom")
                    return
                case .unexpectedOlderFormat:
                    status = .failed("The iCloud v2 zone has an unexpected data-model version")
                    return
                }
                // No model payload is queried until the manifest says this client can
                // interpret it.
                v2Records = try await fetchAllRecords(from: database, zoneID: zoneID)
            } else {
                // An empty v2 zone is safe to claim. Records without a manifest are not:
                // their encoding cannot be identified without guessing.
                v2Records = try await fetchAllRecords(from: database, zoneID: zoneID)
                guard v2Records.isEmpty else {
                    status = .failed("The iCloud v2 zone has data but no version manifest")
                    return
                }
                let manifest = CloudDataModelManifest(
                    formatMajor: Self.dataModelMajor,
                    minimumReaderMajor: Self.dataModelMajor,
                    minimumWriterMajor: Self.dataModelMajor,
                    createdAt: Date()
                )
                _ = try await database.save(try makeRecord(
                    type: "MTDataModelManifest",
                    id: manifestRecordID,
                    value: manifest
                ))
            }

            let legacyRecords = try await fetchAllRecords(
                from: database,
                zoneID: legacyZoneID
            )
            // Read both feeds during the compatibility window. That keeps changes made
            // by an older app bidirectional instead of letting the v2 mirror overwrite
            // them on its next pass.
            let fetchedRemote = v2Records + legacyRecords
            // A zone can change while CloudKit is paging through its change history,
            // so the same record ID may legitimately appear in more than one batch.
            // Dictionary(uniqueKeysWithValues:) traps on that input. Collapse repeats
            // first and retain the newest server version for decoding and conflict
            // handling below.
            let remoteRecordsByID = newestValuesByID(
                fetchedRemote,
                id: \.recordID,
                modifiedAt: \.modificationDate
            )
            let remote = Array(remoteRecordsByID.values)
            var remotePreferences: SyncedBrowserPreferences?
            var legacyClientCertificates: SyncedClientCertificates?
            var remoteCertificateRecords: [SyncedClientCertificateDescriptor] = []
            var remoteAssociationRecords: [SyncedClientCertificateAssociation] = []
            var remoteBookmarkFolders: [SyncedBookmarkFolder] = []
            var remoteBookmarks: [SyncedBookmark] = []
            var remoteTrustDecisions: [SyncedServerTrustDecision] = []
            var devices: [CloudTabDeviceSnapshot] = []

            for record in remote {
                guard let data = record.encryptedValues["payload"] as? Data else { continue }
                switch record.recordType {
                case "MTPreferences":
                    if let value = try? decoder.decode(SyncedBrowserPreferences.self, from: data),
                       value.shouldReplace(remotePreferences) {
                        remotePreferences = value
                    }
                case "MTDeviceTabs":
                    if let device = try? decoder.decode(CloudTabDeviceSnapshot.self, from: data) {
                        devices.append(device)
                    }
                case "MTClientCertificates":
                    legacyClientCertificates = try? decoder.decode(
                        SyncedClientCertificates.self,
                        from: data
                    )
                case "MTClientCertificateDescriptor":
                    if let value = try? decoder.decode(
                        SyncedClientCertificateDescriptor.self,
                        from: data
                    ) { remoteCertificateRecords.append(value) }
                case "MTClientCertificateAssociation":
                    if let value = try? decoder.decode(
                        SyncedClientCertificateAssociation.self,
                        from: data
                    ) { remoteAssociationRecords.append(value) }
                case "MTBookmarkFolder":
                    if let value = try? decoder.decode(SyncedBookmarkFolder.self, from: data) {
                        remoteBookmarkFolders.append(value)
                    }
                case "MTBookmark":
                    if let value = try? decoder.decode(SyncedBookmark.self, from: data) {
                        remoteBookmarks.append(value)
                    }
                case "MTServerTrust":
                    if let value = try? decoder.decode(SyncedServerTrustDecision.self, from: data) {
                        remoteTrustDecisions.append(value)
                    }
                default:
                    break
                }
            }

            devices = Array(newestValuesByID(
                devices,
                id: \.deviceID,
                modifiedAt: { $0.updatedAt }
            ).values)

            if let remotePreferences, remotePreferences.shouldReplace(localPreferences) {
                localPreferences = remotePreferences
                receivedPreferences.send(remotePreferences)
            }
            var remoteClientCertificates = ClientCertificateSyncState(
                certificates: remoteCertificateRecords,
                associations: remoteAssociationRecords
            )
            if remoteCertificateRecords.isEmpty, remoteAssociationRecords.isEmpty,
               let legacyClientCertificates {
                remoteClientCertificates = ClientCertificateSyncState(legacy: legacyClientCertificates)
            }
            let mergedClientCertificates = localClientCertificates.map {
                $0.merging(remoteClientCertificates)
            } ?? remoteClientCertificates
            if mergedClientCertificates != localClientCertificates,
               (!mergedClientCertificates.certificates.isEmpty
                    || !mergedClientCertificates.associations.isEmpty) {
                localClientCertificates = mergedClientCertificates
                receivedClientCertificates.send(mergedClientCertificates)
            }

            let remoteBookmarkState = SyncedBookmarks(
                folders: remoteBookmarkFolders,
                bookmarks: remoteBookmarks
            )
            let mergedBookmarks = localBookmarks.map { $0.merging(remoteBookmarkState) }
                ?? remoteBookmarkState
            if mergedBookmarks != localBookmarks,
               (!mergedBookmarks.folders.isEmpty || !mergedBookmarks.bookmarks.isEmpty) {
                localBookmarks = mergedBookmarks
                receivedBookmarks.send(mergedBookmarks)
            }

            let remoteTrust = SyncedServerTrust(decisions: remoteTrustDecisions)
            let mergedTrust = localServerTrust.map { $0.merging(remoteTrust) } ?? remoteTrust
            if mergedTrust != localServerTrust, !mergedTrust.decisions.isEmpty {
                localServerTrust = mergedTrust
                receivedServerTrust.send(mergedTrust)
            }

            hasLocalChangesSinceSync = false
            lastSuccessfulSync = Date()
            remoteTabDevices = devices.visibleCloudTabDevices(excluding: localDeviceID)
            persistCachedTabs(devices)

            var recordsToSave: [CKRecord] = []
            if let localPreferences,
               try recordNeedsUpload(
                    localPreferences,
                    id: preferencesRecordID,
                    cloudRecords: remoteRecordsByID
               ) {
                recordsToSave.append(try makeRecord(
                    type: "MTPreferences",
                    id: preferencesRecordID,
                    value: localPreferences,
                    existing: remoteRecordsByID[preferencesRecordID]
                ))
            }
            if let localClientCertificates {
                recordsToSave += try recordsNeedingUpload(
                    local: localClientCertificates.certificates,
                    type: "MTClientCertificateDescriptor",
                    prefix: "client-certificate",
                    cloudRecords: remoteRecordsByID
                )
                recordsToSave += try recordsNeedingUpload(
                    local: localClientCertificates.associations,
                    type: "MTClientCertificateAssociation",
                    prefix: "client-certificate-association",
                    cloudRecords: remoteRecordsByID
                )
            }
            if let localBookmarks {
                recordsToSave += try recordsNeedingUpload(
                    local: localBookmarks.folders,
                    type: "MTBookmarkFolder",
                    prefix: "bookmark-folder",
                    cloudRecords: remoteRecordsByID
                )
                recordsToSave += try recordsNeedingUpload(
                    local: localBookmarks.bookmarks,
                    type: "MTBookmark",
                    prefix: "bookmark",
                    cloudRecords: remoteRecordsByID
                )
            }
            if let localServerTrust {
                for decision in localServerTrust.decisions
                {
                    let id = recordID(prefix: "server-trust", stableID: decision.id)
                    if try recordNeedsUpload(decision, id: id, cloudRecords: remoteRecordsByID) {
                        recordsToSave.append(try makeRecord(
                            type: "MTServerTrust",
                            id: id,
                            value: decision,
                            existing: remoteRecordsByID[id]
                        ))
                    }
                }
            }
            if let localTabs,
               try recordNeedsUpload(
                    localTabs,
                    id: tabsRecordID,
                    cloudRecords: remoteRecordsByID
               ) {
                recordsToSave.append(try makeRecord(
                    type: "MTDeviceTabs",
                    id: tabsRecordID,
                    value: localTabs,
                    existing: remoteRecordsByID[tabsRecordID]
                ))
            }
            try await save(recordsToSave, to: database)

            // Continue publishing the old record shapes in the original zone. Older
            // Major Tom builds never see the v2 zone or manifest, but still receive
            // current bookmarks, preferences, identities, trust, and device tabs.
            let legacyByID = newestValuesByID(
                legacyRecords,
                id: \.recordID,
                modifiedAt: \.modificationDate
            )
            let compatibilityRecords = try makeLegacyCompatibilityRecords(existing: legacyByID)
            try await save(compatibilityRecords, to: database)
            status = .upToDate(Date())
        } catch {
            if Self.isConflict(error) {
                // Refetch and merge the winning server value instead of allowing a
                // stale device to overwrite it. requestSync() observes this after the
                // current task has unwound.
                pendingSync = true
            }
            status = .failed(Self.description(for: error))
        }
    }

    private func fetchAllRecords(
        from database: CKDatabase,
        zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord] {
        var records: [CKRecord] = []

        // A nil zone-change token means "from the beginning of the zone's history",
        // not "the records that exist now". Replaying that history on every sync became
        // effectively unbounded after repeated imports and deletions generated many
        // generations of the same records. A sync needs the current server snapshot for
        // merge and save-policy decisions, so query each of Major Tom's record types and
        // follow only its finite current-result cursor.
        for recordType in synchronizedRecordTypes {
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            var page = try await database.records(
                matching: query,
                inZoneWith: zoneID,
                desiredKeys: ["payload"]
            )
            while true {
                for (_, match) in page.matchResults {
                    switch match {
                    case .success(let record): records.append(record)
                    case .failure(let error): throw error
                    }
                }
                guard let cursor = page.queryCursor else { break }
                page = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: ["payload"]
                )
            }
        }
        return records
    }

    private func fetchManifest(from database: CKDatabase) async throws -> CKRecord? {
        do {
            return try await database.record(for: manifestRecordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func makeRecord<Value: Encodable>(
        type: CKRecord.RecordType,
        id: CKRecord.ID,
        value: Value,
        existing: CKRecord? = nil
    ) throws -> CKRecord {
        let record = existing ?? CKRecord(recordType: type, recordID: id)
        record.encryptedValues["payload"] = try encoder.encode(value) as CKRecordValue
        return record
    }

    private func save(_ records: [CKRecord], to database: CKDatabase) async throws {
        guard !records.isEmpty else { return }
        for batchStart in stride(
            from: 0,
            to: records.count,
            by: Self.maximumRecordsPerModify
        ) {
            let batchEnd = min(batchStart + Self.maximumRecordsPerModify, records.count)
            let result = try await database.modifyRecords(
                saving: Array(records[batchStart..<batchEnd]),
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )
            for saveResult in result.saveResults.values {
                if case .failure(let error) = saveResult { throw error }
            }
        }
    }

    private func makeLegacyCompatibilityRecords(
        existing: [CKRecord.ID: CKRecord]
    ) throws -> [CKRecord] {
        var records: [CKRecord] = []
        if let localPreferences,
           let record = try compatibilityRecord(
                type: "MTPreferences",
                id: CKRecord.ID(recordName: "preferences", zoneID: legacyZoneID),
                value: localPreferences,
                existing: existing
           ) {
            records.append(record)
        }
        if let localClientCertificates {
            records += try compatibilityRecords(
                localClientCertificates.certificates,
                type: "MTClientCertificateDescriptor",
                prefix: "client-certificate",
                stableID: { $0.id.uuidString },
                existing: existing
            )
            records += try compatibilityRecords(
                localClientCertificates.associations,
                type: "MTClientCertificateAssociation",
                prefix: "client-certificate-association",
                stableID: { $0.id.uuidString },
                existing: existing
            )
        }
        if let localBookmarks {
            records += try compatibilityRecords(
                localBookmarks.folders,
                type: "MTBookmarkFolder",
                prefix: "bookmark-folder",
                stableID: { $0.id.uuidString },
                existing: existing
            )
            records += try compatibilityRecords(
                localBookmarks.bookmarks,
                type: "MTBookmark",
                prefix: "bookmark",
                stableID: { $0.id.uuidString },
                existing: existing
            )
        }
        if let localServerTrust {
            records += try compatibilityRecords(
                localServerTrust.decisions,
                type: "MTServerTrust",
                prefix: "server-trust",
                stableID: { $0.id },
                existing: existing
            )
        }
        if let localTabs,
           let record = try compatibilityRecord(
                type: "MTDeviceTabs",
                id: CKRecord.ID(
                    recordName: "tabs-\(localDeviceID.uuidString.lowercased())",
                    zoneID: legacyZoneID
                ),
                value: localTabs,
                existing: existing
           ) {
            records.append(record)
        }
        return records
    }

    private func compatibilityRecords<Value: Encodable>(
        _ values: [Value],
        type: CKRecord.RecordType,
        prefix: String,
        stableID: (Value) -> String,
        existing: [CKRecord.ID: CKRecord]
    ) throws -> [CKRecord] {
        try values.compactMap { value in
            try compatibilityRecord(
                type: type,
                id: recordID(
                    prefix: prefix,
                    stableID: stableID(value),
                    zoneID: legacyZoneID
                ),
                value: value,
                existing: existing
            )
        }
    }

    private func compatibilityRecord<Value: Encodable>(
        type: CKRecord.RecordType,
        id: CKRecord.ID,
        value: Value,
        existing: [CKRecord.ID: CKRecord]
    ) throws -> CKRecord? {
        let payload = try encoder.encode(value)
        if existing[id]?.encryptedValues["payload"] as? Data == payload { return nil }
        let record = existing[id] ?? CKRecord(recordType: type, recordID: id)
        record.encryptedValues["payload"] = payload as CKRecordValue
        return record
    }

    private func recordsNeedingUpload<Record>(
        local: [Record],
        type: CKRecord.RecordType,
        prefix: String,
        cloudRecords: [CKRecord.ID: CKRecord]
    ) throws -> [CKRecord]
    where Record: Encodable & Identifiable & CloudModifiedRecord, Record.ID == UUID {
        return try local.compactMap { record in
            let id = recordID(prefix: prefix, stableID: record.id.uuidString)
            guard try recordNeedsUpload(record, id: id, cloudRecords: cloudRecords) else {
                return nil
            }
            return try makeRecord(
                type: type,
                id: id,
                value: record,
                existing: cloudRecords[id]
            )
        }
    }

    private func recordNeedsUpload<Value: Encodable>(
        _ value: Value,
        id: CKRecord.ID,
        cloudRecords: [CKRecord.ID: CKRecord]
    ) throws -> Bool {
        try encoder.encode(value) != (cloudRecords[id]?.encryptedValues["payload"] as? Data)
    }

    private func recordID(
        prefix: String,
        stableID: String,
        zoneID: CKRecordZone.ID? = nil
    ) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data(stableID.utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "\(prefix)-\(digest)", zoneID: zoneID ?? self.zoneID)
    }

    private func persistCachedTabs(_ devices: [CloudTabDeviceSnapshot]) {
        if let data = try? encoder.encode(devices) {
            defaults.set(data, forKey: Self.cachedTabsKey)
        }
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

    private static var hasCloudKitEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.icloud-container-identifiers" as CFString,
                  nil
              ) as? [String] else {
            return false
        }
        return identifiers.contains("iCloud.dev.gemi.major-tom")
    }

    private static func description(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain,
           let code = CKError.Code(rawValue: nsError.code) {
            switch code {
            case .notAuthenticated: return "Sign in to iCloud to sync"
            case .networkUnavailable, .networkFailure: return "Offline; changes are saved locally"
            case .permissionFailure: return "This build is not provisioned for Major Tom iCloud sync"
            default: break
            }
        }
        return error.localizedDescription
    }

    private static func isConflict(_ error: Error) -> Bool {
        let cloudError = error as? CKError
        if cloudError?.code == .serverRecordChanged { return true }
        guard cloudError?.code == .partialFailure,
              let partial = cloudError?.partialErrorsByItemID else { return false }
        return partial.values.contains { ($0 as? CKError)?.code == .serverRecordChanged }
    }
}
