import CloudKit
import Combine
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
    let receivedClientCertificates = PassthroughSubject<SyncedClientCertificates, Never>()

    let localDeviceID: UUID
    let localDeviceName: String

    private let container: CKContainer?
    private let database: CKDatabase?
    private let defaults: UserDefaults
    private let zoneID = CKRecordZone.ID(zoneName: "MajorTomUserData")
    private let preferencesRecordID: CKRecord.ID
    private let clientCertificatesRecordID: CKRecord.ID
    private let tabsRecordID: CKRecord.ID
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var localPreferences: SyncedBrowserPreferences?
    private var localClientCertificates: SyncedClientCertificates?
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
        clientCertificatesRecordID = CKRecord.ID(
            recordName: "client-certificates",
            zoneID: zoneID
        )
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

    func configure(clientCertificates: SyncedClientCertificates?) {
        localClientCertificates = clientCertificates
        requestSync()
    }

    func updateClientCertificates(_ snapshot: SyncedClientCertificates) {
        localClientCertificates = snapshot
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
        status = .syncing
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                status = .unavailable(Self.accountStatusDescription(accountStatus))
                return
            }

            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            let remote = try await fetchAllRecords(from: database)
            var remotePreferences: SyncedBrowserPreferences?
            var remoteClientCertificates: SyncedClientCertificates?
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
                    remoteClientCertificates = try? decoder.decode(
                        SyncedClientCertificates.self,
                        from: data
                    )
                default:
                    break
                }
            }

            if let remotePreferences, remotePreferences.shouldReplace(localPreferences) {
                localPreferences = remotePreferences
                receivedPreferences.send(remotePreferences)
            }
            if let remoteClientCertificates,
               remoteClientCertificates.shouldReplace(localClientCertificates) {
                localClientCertificates = remoteClientCertificates
                receivedClientCertificates.send(remoteClientCertificates)
            }

            remoteTabDevices = devices.visibleCloudTabDevices(excluding: localDeviceID)
            persistCachedTabs(devices)

            var recordsToSave: [CKRecord] = []
            if let localPreferences,
               remotePreferences == nil || localPreferences.shouldReplace(remotePreferences) {
                recordsToSave.append(try makeRecord(
                    type: "MTPreferences",
                    id: preferencesRecordID,
                    value: localPreferences
                ))
            }
            if let localClientCertificates,
               remoteClientCertificates == nil
                    || localClientCertificates.shouldReplace(remoteClientCertificates) {
                recordsToSave.append(try makeRecord(
                    type: "MTClientCertificates",
                    id: clientCertificatesRecordID,
                    value: localClientCertificates
                ))
            }
            if let localTabs {
                recordsToSave.append(try makeRecord(
                    type: "MTDeviceTabs",
                    id: tabsRecordID,
                    value: localTabs
                ))
            }
            if !recordsToSave.isEmpty {
                let result = try await database.modifyRecords(
                    saving: recordsToSave,
                    deleting: [],
                    savePolicy: .allKeys,
                    atomically: false
                )
                for saveResult in result.saveResults.values {
                    if case .failure(let error) = saveResult { throw error }
                }
            }
            status = .upToDate(Date())
        } catch {
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
        value: Value
    ) throws -> CKRecord {
        let record = CKRecord(recordType: type, recordID: id)
        record.encryptedValues["payload"] = try encoder.encode(value) as CKRecordValue
        return record
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
}
