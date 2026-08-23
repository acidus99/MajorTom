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

/// The app's private CloudKit cache. Local UserDefaults remain the immediate source of
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
    private let zoneID = CKRecordZone.ID(zoneName: "MajorTomUserData")
    private let preferencesRecordID: CKRecord.ID
    private let tabsRecordID: CKRecord.ID
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var localPreferences: SyncedBrowserPreferences?
    private var localClientCertificates: ClientCertificateSyncState?
    private var localBookmarks: SyncedBookmarks?
    private var localServerTrust: SyncedServerTrust?
    private var localTabs: CloudTabDeviceSnapshot?
    private var syncTask: Task<Void, Never>?
    private var pendingSync = false

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

        if let data = defaults.data(forKey: Self.cachedTabsKey),
           let cached = try? decoder.decode([CloudTabDeviceSnapshot].self, from: data) {
            remoteTabDevices = cached.visibleCloudTabDevices(excluding: localDeviceID)
        }
    }

    func configure(preferences: SyncedBrowserPreferences?) {
        localPreferences = preferences
        requestSync()
    }

    func updatePreferences(_ snapshot: SyncedBrowserPreferences) {
        localPreferences = snapshot
        requestSync()
    }

    func configure(clientCertificates: ClientCertificateSyncState?) {
        localClientCertificates = clientCertificates
        requestSync()
    }

    func updateClientCertificates(_ snapshot: ClientCertificateSyncState) {
        localClientCertificates = snapshot
        requestSync()
    }

    func configure(bookmarks: SyncedBookmarks?) {
        localBookmarks = bookmarks
        requestSync()
    }

    func updateBookmarks(_ snapshot: SyncedBookmarks) {
        localBookmarks = snapshot
        requestSync()
    }

    func configure(serverTrust: SyncedServerTrust?) {
        localServerTrust = serverTrust
        requestSync()
    }

    func updateServerTrust(_ snapshot: SyncedServerTrust) {
        localServerTrust = snapshot
        requestSync()
    }

    func updateTabs(_ tabs: [CloudTabSnapshot]) {
        localTabs = CloudTabDeviceSnapshot(
            deviceID: localDeviceID,
            deviceName: localDeviceName,
            updatedAt: Date(),
            tabs: tabs
        )
        requestSync()
    }

    func refresh() {
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

            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            let fetchedRemote = try await fetchAllRecords(from: database)
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
                    remotePreferences = try? decoder.decode(SyncedBrowserPreferences.self, from: data)
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

            remoteTabDevices = devices.visibleCloudTabDevices(excluding: localDeviceID)
            persistCachedTabs(devices)

            var recordsToSave: [CKRecord] = []
            if let localPreferences,
               remotePreferences == nil || localPreferences.shouldReplace(remotePreferences) {
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
                    remote: remoteCertificateRecords,
                    type: "MTClientCertificateDescriptor",
                    prefix: "client-certificate",
                    cloudRecords: remoteRecordsByID
                )
                recordsToSave += try recordsNeedingUpload(
                    local: localClientCertificates.associations,
                    remote: remoteAssociationRecords,
                    type: "MTClientCertificateAssociation",
                    prefix: "client-certificate-association",
                    cloudRecords: remoteRecordsByID
                )
            }
            if let localBookmarks {
                recordsToSave += try recordsNeedingUpload(
                    local: localBookmarks.folders,
                    remote: remoteBookmarkFolders,
                    type: "MTBookmarkFolder",
                    prefix: "bookmark-folder",
                    cloudRecords: remoteRecordsByID
                )
                recordsToSave += try recordsNeedingUpload(
                    local: localBookmarks.bookmarks,
                    remote: remoteBookmarks,
                    type: "MTBookmark",
                    prefix: "bookmark",
                    cloudRecords: remoteRecordsByID
                )
            }
            if let localServerTrust {
                let remoteByID = Dictionary(uniqueKeysWithValues: remoteTrustDecisions.map { ($0.id, $0) })
                for decision in localServerTrust.decisions
                where remoteByID[decision.id]?.modifiedAt ?? .distantPast < decision.modifiedAt {
                    recordsToSave.append(try makeRecord(
                        type: "MTServerTrust",
                        id: recordID(prefix: "server-trust", stableID: decision.id),
                        value: decision,
                        existing: remoteRecordsByID[
                            recordID(prefix: "server-trust", stableID: decision.id)
                        ]
                    ))
                }
            }
            if let localTabs {
                recordsToSave.append(try makeRecord(
                    type: "MTDeviceTabs",
                    id: tabsRecordID,
                    value: localTabs,
                    existing: remoteRecordsByID[tabsRecordID]
                ))
            }
            if !recordsToSave.isEmpty {
                let result = try await database.modifyRecords(
                    saving: recordsToSave,
                    deleting: [],
                    savePolicy: .ifServerRecordUnchanged,
                    atomically: false
                )
                for saveResult in result.saveResults.values {
                    if case .failure(let error) = saveResult { throw error }
                }
            }
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

    private func fetchAllRecords(from database: CKDatabase) async throws -> [CKRecord] {
        var token: CKServerChangeToken?
        var records: [CKRecord] = []
        repeat {
            let result = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: token,
                desiredKeys: ["payload"]
            )
            for modification in result.modificationResultsByID.values {
                switch modification {
                case .success(let value): records.append(value.record)
                case .failure(let error): throw error
                }
            }
            token = result.moreComing ? result.changeToken : nil
            if !result.moreComing { break }
        } while true
        return records
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

    private func recordsNeedingUpload<Record>(
        local: [Record],
        remote: [Record],
        type: CKRecord.RecordType,
        prefix: String,
        cloudRecords: [CKRecord.ID: CKRecord]
    ) throws -> [CKRecord]
    where Record: Encodable & Identifiable & CloudModifiedRecord, Record.ID == UUID {
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        return try local.compactMap { record in
            guard remoteByID[record.id]?.cloudModifiedAt ?? .distantPast
                < record.cloudModifiedAt else {
                return nil
            }
            let id = recordID(prefix: prefix, stableID: record.id.uuidString)
            return try makeRecord(
                type: type,
                id: id,
                value: record,
                existing: cloudRecords[id]
            )
        }
    }

    private func recordID(prefix: String, stableID: String) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data(stableID.utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "\(prefix)-\(digest)", zoneID: zoneID)
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
