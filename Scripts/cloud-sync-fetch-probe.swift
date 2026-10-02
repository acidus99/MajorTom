// Read-only SDK probe. Run via run-cloud-sync-fetch-probe.sh with Major Tom quit.
// Checkpoint bytes enter via stdin; neither they nor record payloads are logged or saved.
import Foundation
import CloudKit

final class ProbeDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    let zone = CKRecordZone.ID(zoneName: "MajorTomUserDataV2")
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .willFetchChanges: print("event willFetch")
        case .didFetchChanges: print("event didFetch")
        case .fetchedDatabaseChanges(let value):
            print("event database modifications=\(value.modifications.count) deletions=\(value.deletions.count)")
        case .fetchedRecordZoneChanges(let value):
            print("event records modifications=\(value.modifications.count) deletions=\(value.deletions.count)")
        case .willFetchRecordZoneChanges: print("event willFetchZone")
        case .didFetchRecordZoneChanges(let value):
            print("event didFetchZone error=\(value.error?.code.rawValue ?? 0)")
        case .accountChange: print("event accountChange")
        case .stateUpdate: break // Never persist probe checkpoints into Major Tom.
        default: print("event other")
        }
    }
    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        print("options manual=\(context.reason == .manual) includesZone=\(context.options.scope.contains(zone))")
        var options = context.options
        options.scope = .zoneIDs([zone])
        return options
    }
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                  syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        return nil // No record writes from this diagnostic.
    }
}

@main struct Probe {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Probe failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let checkpoint = FileHandle.standardInput.readDataToEndOfFile()
        let serialization = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: checkpoint)
        let delegate = ProbeDelegate()
        var config = CKSyncEngine.Configuration(
            database: CKContainer(identifier: "iCloud.dev.gemi.major-tom").privateCloudDatabase,
            stateSerialization: serialization, delegate: delegate)
        config.automaticallySync = CommandLine.arguments.contains("--automatic")
        let engine = CKSyncEngine(config)
        print("probe automatic=\(config.automaticallySync)")
        for attempt in 1...2 {
            print("fetch \(attempt) start dirtyZones=\(engine.state.zoneIDsWithUnfetchedServerChanges.count)")
            let group = CKOperationGroup()
            group.defaultConfiguration.qualityOfService = .userInitiated
            try await engine.fetchChanges(.init(scope: .zoneIDs([delegate.zone]), operationGroup: group))
            print("fetch \(attempt) complete dirtyZones=\(engine.state.zoneIDsWithUnfetchedServerChanges.count)")
        }
        await engine.cancelOperations()
        print("probe finished; no local state persisted")
    }
}
