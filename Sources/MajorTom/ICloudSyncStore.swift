import CloudKit
import Combine
import CryptoKit
import Foundation
import MajorTomCore
import Network
import OSLog
import Security

private let cloudSyncLogger = Logger(
    subsystem: "dev.gemi.major-tom",
    category: "ICloudSync"
)

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

    @Published private(set) var status: ICloudSyncStatus = .preparing {
        didSet {
            guard status != oldValue else { return }
            // `.upToDate` carries the time it completed, so consecutive values differ
            // while reading identically to the reader. Logging those produced a stream
            // of "status changed from=Up to date to=Up to date".
            guard status.label != oldValue.label else { return }
            cloudSyncLogger.notice(
                "status changed from=\(oldValue.label, privacy: .private) to=\(self.status.label, privacy: .private)"
            )
        }
    }
    @Published private(set) var remoteTabDevices: [CloudTabDeviceSnapshot] = [] {
        didSet {
            guard remoteTabDevices != oldValue else { return }
            let tabCount = remoteTabDevices.reduce(0) { $0 + $1.tabs.count }
            cloudSyncLogger.info(
                "visible remote tabs changed devices=\(self.remoteTabDevices.count) tabs=\(tabCount)"
            )
        }
    }

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
    private static let preferencesKey = "browser-preferences-v3"
    private static let orderAndTabsRepairKey = "cloud-full-refetch-order-and-tabs-v1"
    private static let manifestRecordName = "data-model-manifest"
    private let zoneID = CKRecordZone.ID(zoneName: "MajorTomUserDataV2")
    private let legacyZoneID = CKRecordZone.ID(zoneName: "MajorTomUserData")
    private let defaults: UserDefaults
    private let localDatabase: MajorTomDatabase?
    private let repository: CloudSyncRepository?
    private let container: CKContainer?
    private let cloudDatabase: CKDatabase?
    private let cloudEnvironment: String?
    private let ubiquitousPreferencesKey: String
    private var engine: CKSyncEngine?
    private var transportSession = CloudSyncSession()
    private var activeEngineSessionToken: Int { transportSession.token }
    private var engineSessionTokens: [ObjectIdentifier: Int] = [:]
    private var activeAccount: String?
    private var attemptedSnapshots: [String: CloudPendingChange] { transportSession.attempts }
    private var writesBlocked = false
    private var manualSyncInFlight = false
    private var manualTransport = false
    private var transportTransitionID: UUID?
    private var userRefreshQueued = false
    private var reconnectRefreshQueued = false
    private let callbackBarrier = CloudSyncCallbackBarrier()
    private var reachability = CloudSyncReachability()
    private let pathMonitor: NWPathMonitor
    private let pathMonitorQueue = DispatchQueue(label: "dev.gemi.major-tom.cloud-sync-reachability")
    private var cycle = CloudSyncCycle()
    private var lastFailureCategory: CloudSyncFailureCategory?
    private var retryAt: Date?
    private var engineStatePersistenceBlocked = false
    private var sendPaused = false
    private var transportRestartRequired = false
    private var conflictCounts: [String: Int] = [:]
    // A custom-zone atomic batch can report only batchRequestFailed for every item.
    // Let the engine retry that transient state, but never turn it into an unbounded
    // tight confirmation loop if CloudKit cannot identify the root item yet.
    private var unresolvedAtomicBatchFailures = 0
    private var lastFullSyncAt: Date?
    private var lastSendFailureWasHandled = false
    private var localPreferences: SyncedBrowserPreferences?
    private var localClientCertificates: ClientCertificateSyncState?
    private var localBookmarks: SyncedBookmarks?
    private var localTabs: CloudTabDeviceSnapshot?
    private var migrationTask: Task<Void, Never>?
    private var bootstrapInFlight = false
    private var isTerminating = false
    private var localPersistenceInFlight = 0
    private var tabWriteTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Error>?
    private var preferenceWriteTask: Task<Void, Never>?
    private(set) var isClaimingLocalData = false
    private var confirmationTask: Task<Void, Never>?
    private var keyValueObserver: AnyCancellable?
    private let decoder = JSONDecoder()

    private init(defaults: UserDefaults = MajorTomDataScope.defaults) {
        self.defaults = defaults
        pathMonitor = NWPathMonitor()
        let cloudEnvironment = Self.entitledCloudEnvironment
        self.cloudEnvironment = cloudEnvironment
        let storageScope = cloudEnvironment ?? "unentitled"
        ubiquitousPreferencesKey = "\(Self.preferencesKey)-\(storageScope)"
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
        if cloudEnvironment != nil {
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
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.observeNetworkAvailability(isAvailable)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
        cloudSyncLogger.notice(
            "store initialized entitled=\(self.container != nil)"
        )
        if let repository {
            do {
                activeAccount = try repository.activeAccountIdentityHash()
            } catch {
                Self.log(error, operation: "loading active iCloud account")
                status = .failed(Self.description(for: error))
            }
        }

        // Remote tabs are read from account-scoped record metadata after activation.
        if container != nil, localDatabase != nil {
            migrationTask = Task { [weak self] in await self?.bootstrap() }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        keyValueObserver = NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
        // SyncedDefaults posts this notification on com.apple.kvs.client.callback.
        // Deliver downstream on the main queue before entering the @MainActor-isolated
        // sink; wrapping only the body in Task is too late for Swift 6's executor check.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor in self?.applyUbiquitousPreferences() }
        }
        applyUbiquitousPreferences()
    }

    func configure(preferences: SyncedBrowserPreferences?) {
        localPreferences = preferences
    }

    func updatePreferences(_ snapshot: SyncedBrowserPreferences) {
        localPreferences = snapshot
        let previous = preferenceWriteTask
        let account = activeAccount
        preferenceWriteTask = Task { [weak self] in
            await previous?.value
            do {
                let data = try await Task.detached(priority: .utility) { try JSONEncoder().encode(snapshot) }.value
                guard let self, self.activeAccount == account else { return }
                NSUbiquitousKeyValueStore.default.set(data, forKey: self.ubiquitousPreferencesKey)
                if let account { self.defaults.set(data, forKey: "browser-preferences-v2-\(account)") }
                NSUbiquitousKeyValueStore.default.synchronize()
            } catch {
                if self?.activeAccount == account { self?.recordCycleFailure(error) }
            }
        }
    }

    func configure(clientCertificates: ClientCertificateSyncState?) {
        localClientCertificates = clientCertificates
        requestSend()
    }

    func updateClientCertificates(_ snapshot: ClientCertificateSyncState) {
        localClientCertificates = snapshot
        requestSend()
    }

    /// Fans an explicit user deletion out to every UUID that previously represented
    /// the same certificate. Automatic fingerprint reconciliation never calls this.
    func deleteClientCertificateRecords(
        descriptorIDs: some Sequence<UUID>,
        associationIDs: some Sequence<UUID>
    ) {
        guard let activeAccount, let localDatabase else { return }
        do {
            let descriptorIDs = Set(descriptorIDs)
            let associationIDs = Set(associationIDs)
            try ClientCertificateSyncRepository(
                database: localDatabase, accountIdentityHash: activeAccount
            ).enqueueExplicitDeletion(
                descriptorIDs: descriptorIDs,
                associationIDs: associationIDs
            )
            cloudSyncLogger.notice(
                "explicit certificate deletion queued descriptors=\(descriptorIDs.count) associations=\(associationIDs.count)"
            )
            status = .syncing
            requestSend()
        } catch {
            Self.log(error, operation: "queueing client certificate deletion")
            recordCycleFailure(error)
        }
    }

    func configure(bookmarks: SyncedBookmarks?) {
        localBookmarks = bookmarks
        requestSend()
    }

    func updateBookmarks(_ snapshot: SyncedBookmarks) {
        localBookmarks = snapshot
        // BookmarkStore already committed this mutation and its outbox. Replacing the
        // whole collection here can replay an older actor completion over a newer edit.
        requestSend()
    }

    func updateTabs(_ tabs: [CloudTabSnapshot]) {
        guard !isTerminating else { return }
        let normalized = CloudTabURL.deduplicated(tabs)
        guard localTabs?.tabs != normalized else {
            cloudSyncLogger.debug("tab publish skipped unchanged input=\(tabs.count) normalized=\(normalized.count)")
            return
        }
        cloudSyncLogger.info("tab publish queued input=\(tabs.count) normalized=\(normalized.count)")
        localTabs = CloudTabDeviceSnapshot(
            deviceID: localDeviceID,
            deviceName: localDeviceName,
            updatedAt: Date(),
            tabs: normalized
        )
        guard let account = activeAccount, let repository, let localTabs else {
            cloudSyncLogger.debug("tab publish deferred because sync account is not ready")
            return
        }
        let previous = tabWriteTask
        localPersistenceBegan()
        tabWriteTask = Task { [weak self] in
            await previous?.value
            defer { self?.localPersistenceEnded() }
            do {
                try await Task.detached(priority: .utility) {
                    _ = try repository.enqueueSave(accountIdentityHash: account, recordType: "MTDeviceTabs",
                        recordName: localTabs.deviceID.uuidString.lowercased(), payload: localTabs)
                }.value
            } catch {
                guard let self, self.activeAccount == account else { return }
                // Allow an unchanged tab snapshot to be queued again after a failed write.
                if self.localTabs == localTabs { self.localTabs = nil }
                Self.log(error, operation: "queueing Cloud Tabs")
                self.recordCycleFailure(error)
            }
        }
    }

    /// Why a full sync was asked for, which decides both how it is logged and whether
    /// it may be skipped as redundant.
    enum FullSyncTrigger: String {
        /// Sync Now, or opening a view that offers the current state as fact.
        case user
        /// Returning to Major Tom, where a sync is worth attempting but was not asked
        /// for.
        case activation
        /// Network.framework observed an offline-to-online transition. This requests
        /// one fresh round trip; the automatic engine remains responsible for ordinary
        /// scheduling and CloudKit's own retry policy.
        case reconnection
        case confirmation
    }

    /// Returning to the application syncs often enough that an unconditional full round
    /// trip is wasteful: switching away and back repeatedly issued a fetch and a send
    /// each time. A sync this recent has nothing to add, and CKSyncEngine keeps its own
    /// schedule besides.
    private static let activationSyncInterval: TimeInterval = 30

    private func observeNetworkAvailability(_ available: Bool) {
        guard reachability.observe(available: available), !isTerminating else { return }
        cloudSyncLogger.notice("network became available; requesting fresh sync")
        refresh(trigger: .reconnection)
    }

    func refresh(trigger: FullSyncTrigger = .user) {
        guard !isTerminating else { return }
        guard transportTransitionID == nil, !manualSyncInFlight else {
            // A click during an automatic confirmation must still request a fresh
            // server check after that work finishes, rather than silently disappearing.
            if trigger == .user { userRefreshQueued = true }
            if trigger == .reconnection { reconnectRefreshQueued = true }
            return
        }
        if engine == nil, container != nil {
            migrationTask = Task { [weak self] in await self?.bootstrap() }
            return
        }
        guard let engine, !writesBlocked else { return }
        if trigger == .activation,
           let lastFullSyncAt,
           Date().timeIntervalSince(lastFullSyncAt) < Self.activationSyncInterval {
            cloudSyncLogger.debug("activation full sync skipped because one just completed")
            return
        }
        if (!manualTransport && trigger != .confirmation) || transportRestartRequired {
            startManualTransportRefresh(trigger: trigger)
            return
        }
        manualSyncInFlight = true
        if trigger == .user || trigger == .activation {
            sendPaused = false
            conflictCounts.removeAll()
            unresolvedAtomicBatchFailures = 0
        }
        beginSyncCycle(requiresFreshFetch: trigger != .confirmation)
        let sessionToken = activeEngineSessionToken
        let cycleID = cycle.id
        let requestedZone = zoneID
        lastFullSyncAt = Date()
        lastSendFailureWasHandled = false
        // Logged as what it is: describing an activation as a "manual" sync made the log
        // report a user action nobody performed, several times an hour.
        cloudSyncLogger.notice(
            "full sync requested trigger=\(trigger.rawValue, privacy: .public)"
        )
        status = .syncing
        // Account-change handling can reach refresh() from a CKSyncEngine delegate callback.
        // A detached task prevents CloudKit operations from inheriting that callback context.
        Task.detached { [self] in
            defer {
                Task { @MainActor [self] in
                    await self.finishRequestedRefresh(sessionToken: sessionToken)
                }
            }
            do {
                try await engine.fetchChanges(.init(scope: .zoneIDs([requestedZone])))
                let canSend = try await MainActor.run {
                    guard self.engine === engine && self.activeEngineSessionToken == sessionToken,
                          self.cycle.id == cycleID, !self.cycle.failed, !self.writesBlocked else { return false }
                    self.cycle.markFetched(freshServerCheck: self.manualTransport)
                    if let account = self.activeAccount, let repository = self.repository {
                        var state = try repository.state(for: account)
                        state.lastFetchedAt = Date()
                        try repository.save(state)
                    }
                    return true
                }
                guard canSend else {
                    return
                }
                try await engine.sendChanges()
                await MainActor.run {
                    guard self.engine === engine,
                          self.activeEngineSessionToken == sessionToken, self.cycle.id == cycleID else { return }
                    self.cycle.markSendFinished()
                    self.finishCycleIfCurrentWorkIsDrained()
                }
            } catch {
                Self.log(error, operation: "full sync")
                await MainActor.run {
                    guard self.engine === engine,
                          self.activeEngineSessionToken == sessionToken, self.cycle.id == cycleID else { return }
                    let code = (error as? CKError)?.code
                    if self.lastSendFailureWasHandled,
                       code == .partialFailure || code == .serverRecordChanged || code == .unknownItem {
                        // Each per-record failure was reconciled durably. Start another
                        // bounded pass without treating the outer aggregate as success.
                        self.cycle.invalidateSendProof()
                    } else {
                        self.recordCycleFailure(error)
                        if !self.attemptedSnapshots.isEmpty { self.transportRestartRequired = true }
                    }
                }
            }
        }
    }

    private func startManualTransportRefresh(trigger: FullSyncTrigger) {
        let transition = UUID()
        transportTransitionID = transition
        status = .syncing
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.replaceTransport(automaticallySync: false, transition: transition)
                guard self.transportTransitionID == transition else { return }
                self.transportTransitionID = nil
                self.transportRestartRequired = false
                self.refresh(trigger: trigger)
            } catch {
                guard self.transportTransitionID == transition else { return }
                self.transportTransitionID = nil
                self.recordCycleFailure(error)
            }
        }
    }

    private func finishRequestedRefresh(sessionToken: Int) async {
        guard activeEngineSessionToken == sessionToken, !isTerminating else { return }
        manualSyncInFlight = false
        if manualTransport, !writesBlocked, !engineStatePersistenceBlocked {
            let transition = UUID()
            transportTransitionID = transition
            do {
                try await replaceTransport(automaticallySync: true, transition: transition, preservingCycle: true)
                guard transportTransitionID == transition else { return }
                // Mode changes do not erase an earlier error or manufacture a new
                // fetch/send proof. New local writes still gate completion below.
                transportTransitionID = nil
                finishCycleIfCurrentWorkIsDrained()
            } catch {
                guard transportTransitionID == transition else { return }
                transportTransitionID = nil
                recordCycleFailure(error)
                return
            }
        }
        if userRefreshQueued {
            userRefreshQueued = false
            refresh(trigger: .user)
        } else if reconnectRefreshQueued {
            reconnectRefreshQueued = false
            refresh(trigger: .reconnection)
        } else if lastSendFailureWasHandled {
            scheduleCompletionConfirmation()
        }
    }

    /// macOS 26.6.2's automatically scheduled engine can return from a manual fetch
    /// without discovering server changes when its dirty-zone set is empty. A signed,
    /// isolated SDK reproduction verifies that a nonautomatic engine checks the server
    /// using the very same checkpoint. Keep only one accepted transport at a time;
    /// never reset opaque state or use a second independent incoming cursor.
    private func replaceTransport(automaticallySync: Bool, transition: UUID,
                                  preservingCycle: Bool = false) async throws {
        guard let account = activeAccount, let repository else {
            throw CloudSyncRepositoryError.invalidSyncState
        }
        var retiring = engine
        engine = nil
        transportSession.begin()
        let transitionSession = activeEngineSessionToken
        confirmationTask?.cancel()
        if let retiring { await Task.detached { await retiring.cancelOperations() }.value }
        // CloudKit documents that cancellation can finish before in-progress work.
        // Every accepted delegate task must finish its durable work before replacement.
        await callbackBarrier.waitUntilIdle()
        retiring = nil
        guard transportTransitionID == transition, activeEngineSessionToken == transitionSession,
              activeAccount == account, !isTerminating else { throw CancellationError() }
        // Shutdown also drains recovery work performed between engine instances.
        callbackBarrier.enter()
        defer { callbackBarrier.leave() }
        try await Task.detached(priority: .utility) { try repository.replayIncoming(for: account) }.value
        guard transportTransitionID == transition, activeEngineSessionToken == transitionSession,
              activeAccount == account, !isTerminating else { throw CancellationError() }
        let state = try repository.state(for: account)
        let serialization = try state.engineState.map {
            try decoder.decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        try publishAccountDataset(account)
        let currentCycle = cycle
        try configureEngine(for: account, serializedState: serialization,
                            createZone: state.zoneState == .neverEstablished,
                            automaticallySync: automaticallySync)
        if preservingCycle { cycle = currentCycle }
    }

    func reuploadAfterCloudDataRemoval() async {
        guard status == .removed, let account = activeAccount, let repository, let cloudDatabase else { return }
        let session = activeEngineSessionToken
        let tabs = localTabs
        status = .syncing
        writesBlocked = false
        do {
            try await Task.detached(priority: .utility) {
                try repository.enqueueLocalSnapshot(for: account, recreatingRemovedZone: true, currentTabs: tabs)
            }.value
            guard session == activeEngineSessionToken else { return }
            // The explicit recovery action durably authorized recreation above. Create
            // the zone before fetching it; do not rely on an automatic send racing the
            // first fetch or on a not-yet-persisted engine save-zone request.
            let created = try await cloudDatabase.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            guard session == activeEngineSessionToken else { return }
            for result in created.saveResults.values { _ = try result.get() }
            var state = try repository.state(for: account)
            state.zoneState = .active
            try repository.save(state)
            try configureEngine(for: account, serializedState: nil, createZone: false)
            refresh()
        } catch {
            guard session == activeEngineSessionToken else { return }
            recordCycleFailure(error)
        }
    }

    private func bootstrap() async {
        guard !bootstrapInFlight, !isTerminating else { return }
        bootstrapInFlight = true
        defer { bootstrapInFlight = false }
        let startingSession = activeEngineSessionToken
        var startedActivation = false
        guard let container else { return }
        cloudSyncLogger.notice("bootstrap started")
        do {
            let accountStatus = try await container.accountStatus()
            guard startingSession == activeEngineSessionToken else { return }
            cloudSyncLogger.info("account status=\(accountStatus.rawValue)")
            guard accountStatus == .available else {
                status = .unavailable(Self.unsavedWarning(Self.accountStatusDescription(accountStatus)))
                return
            }
            let userID = try await container.userRecordID()
            guard startingSession == activeEngineSessionToken else { return }
            startedActivation = true
            try await activateAccount(Self.identityHash(for: userID))
        } catch {
            if !startedActivation, startingSession != activeEngineSessionToken { return }
            if error is CancellationError { return }
            Self.log(error, operation: "bootstrap")
            recordCycleFailure(error)
        }
    }

    private func activateAccount(_ account: String) async throws {
        guard let repository, let cloudDatabase, cloudEnvironment != nil else { return }
        // Invalidate the old transport before the first await. A callback from it must
        // never observe this activation's account or outbox.
        transportSession.begin()
        let activationToken = activeEngineSessionToken
        transportTransitionID = nil
        userRefreshQueued = false
        isClaimingLocalData = false
        checkpointTask = nil
        let priorEngine = engine
        engine = nil
        manualSyncInFlight = false
        transportSession.clearAttempts()
        cycle = CloudSyncCycle()
        writesBlocked = false
        sendPaused = false
        engineStatePersistenceBlocked = false
        remoteTabDevices = []
        if let priorEngine { Task.detached { await priorEngine.cancelOperations() } }
        do {
        let priorActive = try repository.activeAccountIdentityHash()
        var state = try repository.state(for: account)
        if priorActive == nil {
            isClaimingLocalData = true
            do {
                try await BookmarksModel.shared.prepareForFirstAccountClaim()
                try await ClientCertificateStore.shared.prepareForFirstAccountClaim()
                guard activationToken == activeEngineSessionToken else { throw CancellationError() }
                try await Task.detached(priority: .utility) { try repository.claimUnownedRows(for: account) }.value
                guard activationToken == activeEngineSessionToken else { throw CancellationError() }
                // Bind subsequent local writes before releasing the claim barrier.
                // The account identity is authenticated even if manifest fetch later fails.
                try repository.saveActiveAccountIdentityHash(account)
                activeAccount = account
                activeAccountChanged.send(account)
                isClaimingLocalData = false
            } catch {
                if activationToken == activeEngineSessionToken { isClaimingLocalData = false }
                throw error
            }
        }

        if state.zoneState != .removed {
            // The migration cutoff belongs to the CloudKit account. A fresh local
            // database is never permission to erase an already established zone.
            do {
                let manifestRecord = try await cloudDatabase.record(for: CKRecord.ID(
                    recordName: Self.manifestRecordName, zoneID: zoneID
                ))
                guard activationToken == activeEngineSessionToken else { throw CancellationError() }
                let manifest: CloudDataModelManifest = try decodeRecord(manifestRecord)
                guard manifest.compatibility(readerMajor: Self.cloudModelMajor,
                                             writerMajor: Self.cloudModelMajor) == .compatible else {
                    writesBlocked = true
                    status = .requiresNewerApp
                    return
                }
                state.migrationPhase = .ready
                state.migratedFromV1 = true
                state.zoneState = .active
                state.modelMajor = Self.cloudModelMajor
                try repository.save(state)
            } catch let error as CKError where error.code == .unknownItem {
                guard activationToken == activeEngineSessionToken else { throw CancellationError() }
                // A crash after zone creation but before the first manifest upload is
                // recoverable only when this device durably owns that upload.
                guard state.migrationPhase == .ready,
                      try repository.pendingChange(recordName: Self.manifestRecordName, for: account)?.operation == .save else { throw error }
            } catch let error as CKError where error.code == .zoneNotFound {
                guard activationToken == activeEngineSessionToken else { throw CancellationError() }
                if state.zoneState == .active {
                    state.zoneState = .removed
                    state.engineState = nil
                    try repository.save(state)
                }
                // Only an absent zone permits first-account initialization below.
            }
            // unknownItem with an existing zone is deliberately an error. It needs
            // recovery, not deletion of records whose format has not been established.
        }
        if state.migrationPhase != .ready, state.zoneState != .removed {
            status = .syncing
            try await importV1Once(account: account, sessionToken: activationToken)
            guard activationToken == activeEngineSessionToken else { throw CancellationError() }
            let tabs = localTabs
            // Commit the ready marker together with every outgoing snapshot before
            // creating the zone. Restart never treats a partial local export as ready.
            try await Task.detached(priority: .utility) {
                try repository.enqueueLocalSnapshot(for: account, currentTabs: tabs, completingMigration: true)
            }.value
            guard activationToken == activeEngineSessionToken else { throw CancellationError() }
            state = try repository.state(for: account)
        }
        if state.zoneState == .neverEstablished {
            // Creating an absent zone is idempotent. Never delete an existing zone
            // based on a device-local migration marker.
            let result = try await cloudDatabase.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: []
            )
            guard activationToken == activeEngineSessionToken else { throw CancellationError() }
            for result in result.saveResults.values { _ = try result.get() }
            state = try repository.state(for: account)
            state.modelMajor = Self.cloudModelMajor
            state.migratedFromV1 = true
            state.migrationPhase = .ready
            state.zoneState = .active
            state.engineState = nil
            state.updatedAt = Date()
            try repository.save(state)
        }
        activeAccount = account
        try repository.saveActiveAccountIdentityHash(account)
        if state.zoneState == .removed {
            writesBlocked = true
            activeAccountChanged.send(account)
            try publishAccountDataset(account)
            status = .removed
            return
        }
        if let localTabs {
            self.localTabs = nil
            updateTabs(localTabs.tabs)
            cloudSyncLogger.info(
                "queued current tabs after account activation tabs=\(localTabs.tabs.count)"
            )
        }
        activeAccountChanged.send(account)
        if priorActive != nil, priorActive != account {
            try publishAccountDataset(account)
        }
        publishAccountPreferences(account, isSwitch: priorActive != nil && priorActive != account)
        try await Task.detached(priority: .utility) { try repository.replayIncoming(for: account) }.value
        guard activationToken == activeEngineSessionToken else { throw CancellationError() }
        remoteTabDevices = try repository.tabSnapshots(for: account)
            .visibleCloudTabDevices(excluding: localDeviceID)

        let requiresFullRefetch = !defaults.bool(forKey: Self.orderAndTabsRepairKey)
        let restored = try repository.state(for: account).engineState.map {
            try decoder.decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        try configureEngine(
            for: account,
            serializedState: requiresFullRefetch ? nil : restored,
            createZone: false
        )
        if requiresFullRefetch {
            defaults.set(true, forKey: Self.orderAndTabsRepairKey)
            cloudSyncLogger.notice("scheduled one-time full refetch for order and Cloud Tabs repair")
        }
        cloudSyncLogger.notice(
            "account activated restoredEngineState=\(restored != nil && !requiresFullRefetch)"
        )
        status = .syncing
        refresh()
        } catch {
            guard activationToken == activeEngineSessionToken else { throw CancellationError() }
            throw error
        }
    }

    private func configureEngine(
        for account: String,
        serializedState: CKSyncEngine.State.Serialization?,
        createZone: Bool,
        automaticallySync: Bool = true
    ) throws {
        guard account == activeAccount, let cloudDatabase, let repository else { throw CancellationError() }
        let hasPendingChanges = try repository.hasPendingChanges(for: account)
        var configuration = CKSyncEngine.Configuration(
            database: cloudDatabase,
            stateSerialization: serializedState,
            delegate: self
        )
        configuration.automaticallySync = automaticallySync
        let value = CKSyncEngine(configuration)
        if createZone {
            value.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        // The outbox is authoritative. Do not manufacture work on every mode change;
        // that would create an automatic-send/confirmation loop after a manual sync.
        value.state.hasPendingUntrackedChanges = !sendPaused && hasPendingChanges
        transportSession.begin()
        engineSessionTokens = [ObjectIdentifier(value): activeEngineSessionToken]
        checkpointTask = nil
        transportSession.clearAttempts()
        cycle = CloudSyncCycle()
        manualSyncInFlight = false
        engine = value
        manualTransport = !automaticallySync
        cloudSyncLogger.notice(
            "engine configured restoredState=\(serializedState != nil) createZone=\(createZone) automatic=\(automaticallySync)"
        )
    }

    private func importV1Once(account: String, sessionToken: Int) async throws {
        guard let cloudDatabase, let repository else { return }
        let phase = try repository.state(for: account).migrationPhase
        guard phase != .publishingV2, phase != .ready else { return }
        let records = try await fetchLegacyRecords(from: cloudDatabase)
        guard sessionToken == activeEngineSessionToken else { throw CancellationError() }
        var folders: [SyncedBookmarkFolder] = []
        var bookmarks: [SyncedBookmark] = []
        var certificates: [SyncedClientCertificateDescriptor] = []
        var associations: [SyncedClientCertificateAssociation] = []
        for record in records {
            let data = try requiredPayload(record)
            switch record.recordType {
            case "MTBookmarkFolder":
                folders.append(try decoder.decode(SyncedBookmarkFolder.self, from: data))
            case "MTBookmark":
                bookmarks.append(try decoder.decode(SyncedBookmark.self, from: data))
            case "MTClientCertificateDescriptor":
                certificates.append(try decoder.decode(SyncedClientCertificateDescriptor.self, from: data))
            case "MTClientCertificateAssociation":
                associations.append(try decoder.decode(SyncedClientCertificateAssociation.self, from: data))
            case "MTClientCertificates":
                do {
                    let value = try decoder.decode(SyncedClientCertificates.self, from: data)
                    let state = ClientCertificateSyncState(legacy: value)
                    certificates += state.certificates
                    associations += state.associations
                }
            case "MTPreferences":
                receivedPreferences.send(try decoder.decode(SyncedBrowserPreferences.self, from: data))
            default: break
            }
        }
        let importedBookmarks = SyncedBookmarks(folders: folders, bookmarks: bookmarks)
        let importedCertificates = ClientCertificateSyncState(certificates: certificates, associations: associations)
        try await Task.detached(priority: .utility) {
            try repository.importLegacyData(bookmarks: importedBookmarks, certificates: importedCertificates, for: account)
        }.value
        guard sessionToken == activeEngineSessionToken else { throw CancellationError() }
    }

    private func fetchLegacyRecords(from database: CKDatabase) async throws -> [CKRecord] {
        let types = ["MTPreferences", "MTClientCertificates", "MTClientCertificateDescriptor",
                     "MTClientCertificateAssociation", "MTBookmarkFolder", "MTBookmark"]
        var records: [CKRecord] = []
        for type in types {
            do {
                var page = try await database.records(
                    matching: CKQuery(recordType: type, predicate: NSPredicate(value: true)),
                    inZoneWith: legacyZoneID,
                    desiredKeys: ["payload"]
                )
                while true {
                    for (_, result) in page.matchResults {
                        records.append(try result.get())
                    }
                    guard let cursor = page.queryCursor else { break }
                    page = try await database.records(continuingMatchFrom: cursor, desiredKeys: ["payload"])
                }
            } catch let error as CKError {
                switch error.code {
                case .zoneNotFound:
                    return []
                case .unknownItem, .serverRejectedRequest:
                    // A user's legacy schema may predate any one of these optional types.
                    // CloudKit reports an absent record type as serverRejectedRequest in
                    // development, so probe the remaining types instead of aborting migration.
                    continue
                default:
                    throw error
                }
            }
        }
        return records
    }

    private func publishAccountDataset(_ account: String) throws {
        guard let localDatabase else { return }
        let collection = try BookmarkRepository(database: localDatabase, accountIdentityHash: account).collection()
        let certificates = try ClientCertificateSyncRepository(
            database: localDatabase, accountIdentityHash: account
        ).load().state
        let bookmarks = SyncedBookmarks(collection: collection, modifiedAt: Date())
        localBookmarks = bookmarks
        localClientCertificates = certificates
        receivedBookmarks.send(bookmarks)
        receivedClientCertificates.send(certificates)
    }


    private func requestSend() {
        guard let engine, !writesBlocked, !sendPaused else { return }
        cycle.invalidateSendProof()
        // CKSyncEngine observes this flag and schedules a send because automaticallySync is
        // enabled. Do not call sendChanges() here: persistence can run from a delegate callback,
        // and awaiting an engine operation from that callback is a CloudKit client fatal error.
        engine.state.hasPendingUntrackedChanges = true
        if !cycle.isActive { beginSyncCycle() }
        if case .failed = status {
            // A new user edit must not erase an actionable earlier failure. A completed
            // successful cycle is the only path that clears it.
        } else {
            status = .syncing
        }
    }

    func prepareForTermination() async {
        let old = stopForTermination()
        await tabWriteTask?.value
        await preferenceWriteTask?.value
        _ = try? await checkpointTask?.value // originating callback reports failure
        if let old { await old.cancelOperations() }
        await callbackBarrier.waitUntilIdle()
    }

    @discardableResult
    func stopForTermination() -> CKSyncEngine? {
        isTerminating = true
        transportTransitionID = nil
        reconnectRefreshQueued = false
        confirmationTask?.cancel()
        pathMonitor.cancel()
        transportSession.begin()
        let old = engine
        engine = nil
        return old
    }

    // MARK: CKSyncEngineDelegate

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                 syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        let current = engine === syncEngine
            && engineSessionTokens[ObjectIdentifier(syncEngine)] == activeEngineSessionToken
        options.scope = .zoneIDs(current && context.options.scope.contains(zoneID) ? [zoneID] : [])
        return options
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === syncEngine,
              engineSessionTokens[ObjectIdentifier(syncEngine)] == activeEngineSessionToken else { return nil }
        callbackBarrier.enter()
        defer { callbackBarrier.leave() }
        guard !sendPaused else { syncEngine.state.hasPendingUntrackedChanges = false; return nil }
        guard !writesBlocked, let account = activeAccount, let repository else {
            syncEngine.state.hasPendingUntrackedChanges = false
            return nil
        }
        let changes: [CloudOutgoingIntent]
        let records: [String: CKRecord]
        let currentGenerations: [String: Int64]
        let session = activeEngineSessionToken
        let zone = zoneID
        let tabs = localTabs
        do {
            guard try !repository.hasUnappliedBatches(for: account) else {
                sendPaused = true
                recordCycleFailure(CloudSyncRepositoryError.invalidSyncState)
                return nil
            }
            let prepared = try await Task.detached(priority: .utility) {
                var intents = try repository.preparedChanges(for: account)
                for intent in intents where intent.change.operation == .save && intent.change.modelPayload == nil {
                    try repository.materializeLegacy(intent.change, currentTabs: tabs)
                }
                intents = try repository.preparedChanges(for: account)
                var records: [String: CKRecord] = [:]
                for intent in intents where intent.change.operation == .save {
                    records[intent.change.recordName] = try Self.makeRecord(for: intent, zoneID: zone)
                }
                return (intents, records)
            }.value
            guard engine === syncEngine, session == activeEngineSessionToken else { return nil }
            changes = prepared.0
            records = prepared.1
            currentGenerations = try repository.currentGenerations(for: account, recordNames: changes.map { $0.change.recordName })
        } catch {
            guard engine === syncEngine, session == activeEngineSessionToken else { return nil }
            Self.log(error, operation: "reading outgoing sync queue")
            recordCycleFailure(error)
            sendPaused = true
            syncEngine.state.hasPendingUntrackedChanges = false
            return nil
        }
        guard !changes.isEmpty else {
            syncEngine.state.hasPendingUntrackedChanges = false
            return nil
        }
        var saves: [CKRecord] = []
        var deletes: [CKRecord.ID] = []
        var hasDeferredWork = false
        for intent in changes {
            let change = intent.change
            let id = CKRecord.ID(recordName: change.recordName, zoneID: zoneID)
            let pending: CKSyncEngine.PendingRecordZoneChange = change.operation == .save
                ? .saveRecord(id) : .deleteRecord(id)
            guard context.options.scope.contains(pending) else {
                hasDeferredWork = true
                continue
            }
            // One outstanding attempt per record. Its generation must remain attached
            // to that send until the corresponding result has been processed.
            guard attemptedSnapshots[change.recordName]?.generation == nil else { continue }
            guard currentGenerations[change.recordName] == change.generation else { hasDeferredWork = true; continue }
            switch change.operation {
            case .save:
                if change.modelPayload == nil {
                    // Preparation already materializes legacy rows off the main actor.
                    recordCycleFailure(CloudSyncRepositoryError.saveMissingPayload)
                    sendPaused = true
                    continue
                }
                do {
                    guard let record = records[change.recordName] else { throw CloudSyncRepositoryError.saveMissingPayload }
                    saves.append(record)
                } catch {
                    Self.log(error, operation: "building outgoing CloudKit record")
                    recordCycleFailure(error)
                    sendPaused = true
                    // The exact intent remains pending. Never turn a construction
                    // failure into an acknowledgement.
                    hasDeferredWork = true
                    continue
                }
            case .delete:
                deletes.append(id)
            }
            guard transportSession.reserve(change, token: session) else { continue }
            cloudSyncLogger.debug("prepared record type=\(change.recordType, privacy: .public) idHash=\(Self.recordNameHash(change.recordName), privacy: .public) operation=\(change.operation.rawValue, privacy: .public) generation=\(change.generation)")
        }
        syncEngine.state.hasPendingUntrackedChanges = !sendPaused && (hasDeferredWork || changes.count >= 200)
        guard !saves.isEmpty || !deletes.isEmpty else {
            cloudSyncLogger.debug("outgoing batch empty pendingRows=\(changes.count)")
            return nil
        }
        let types = Dictionary(grouping: saves, by: \.recordType)
            .map { "\($0.key):\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        cloudSyncLogger.info(
            "outgoing batch saves=\(saves.count) deletes=\(deletes.count) types=\(types, privacy: .public)"
        )
        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: saves,
            recordIDsToDelete: deletes,
            atomicByZone: false
        )
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            guard engine === syncEngine,
                  engineSessionTokens[ObjectIdentifier(syncEngine)] == activeEngineSessionToken else {
                return
            }
            callbackBarrier.enter()
            defer { callbackBarrier.leave() }
            switch event {
            case .stateUpdate(let update):
                cloudSyncLogger.debug("engine state update")
                guard let account = activeAccount else { return }
                guard !engineStatePersistenceBlocked else { return }
                let session = activeEngineSessionToken
                let previous = checkpointTask
                let repository = self.repository
                // Serialize checkpoints even if delegate calls overlap while encoding.
                // A failed predecessor blocks every later checkpoint in this session.
                let task = Task.detached(priority: .utility) { [weak self] in
                    try await previous?.value
                    let data = try JSONEncoder().encode(update.stateSerialization)
                    try await MainActor.run {
                        guard let self, session == self.activeEngineSessionToken,
                              !self.engineStatePersistenceBlocked else { return }
                        try repository?.saveEngineState(data, for: account)
                    }
                }
                checkpointTask = task
                do { try await task.value }
                catch {
                    guard session == activeEngineSessionToken else { return }
                    engineStatePersistenceBlocked = true
                    throw error
                }
            case .accountChange(let change):
                let id: CKRecord.ID?
                switch change.changeType {
                case .signIn(let current): id = current
                case .switchAccounts(_, let current): id = current
                case .signOut:
                    transportTransitionID = nil
                    userRefreshQueued = false
                    reconnectRefreshQueued = false
                    transportSession.begin()
                    transportSession.clearAttempts()
                    manualSyncInFlight = false
                    cycle = CloudSyncCycle()
                    engine = nil
                    status = .unavailable(Self.unsavedWarning("Sign in to iCloud to sync"))
                    return
                @unknown default:
                    id = nil
                }
                if let id {
                    let hash = Self.identityHash(for: id)
                    if CloudSyncSession.requiresAccountActivation(reportedAccount: hash, activeAccount: activeAccount) {
                        try await activateAccount(hash)
                    }
                }
            case .fetchedRecordZoneChanges(let changes):
                let modificationTypes = Self.recordTypeSummary(changes.modifications.map(\.record))
                cloudSyncLogger.info(
                    "received record changes saves=\(changes.modifications.count) deletes=\(changes.deletions.count) types=\(modificationTypes, privacy: .public)"
                )
                try await applyFetched(changes)
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
                cloudSyncLogger.info(
                    "send completed saves=\(sent.savedRecords.count) deletes=\(sent.deletedRecordIDs.count) failedSaves=\(sent.failedRecordSaves.count) failedDeletes=\(sent.failedRecordDeletes.count)"
                )
                try await handleSent(sent)
            case .sentDatabaseChanges(let sent):
                if let failure = sent.failedZoneSaves.first { throw failure.error }
                if let failure = sent.failedZoneDeletes.values.first { throw failure }
                if sent.savedZones.contains(where: { $0.zoneID == zoneID }), let account = activeAccount {
                    var state = try repository?.state(for: account)
                    state?.zoneState = .active
                    if let state { try repository?.save(state) }
                }
            case .willFetchChanges:
                cloudSyncLogger.debug("will fetch changes")
                // CKSyncEngine retries recoverable transport failures on its own. Its
                // first successful automatic retry must not inherit the previous
                // failed cycle: doing so left the UI permanently reporting Offline
                // even after the engine had sent the durable outbox successfully.
                if !cycle.isActive || cycle.failed {
                    beginSyncCycle()
                }
                if !writesBlocked { status = .syncing }
            case .didFetchChanges:
                cloudSyncLogger.debug("did fetch changes")
                scheduleCompletionConfirmation()
            case .willSendChanges:
                cloudSyncLogger.debug("will send changes")
            case .didSendChanges:
                cloudSyncLogger.debug("did send changes")
                // During Sync Now the awaited sendChanges return is the success proof;
                // a lifecycle callback can precede its thrown error.
                scheduleCompletionConfirmation()
            case .didFetchRecordZoneChanges(let result):
                if result.zoneID == zoneID, let error = result.error { throw error }
            case .willFetchRecordZoneChanges:
                break
            @unknown default:
                break
            }
        } catch {
            if error is CancellationError { return }
            Self.log(error, operation: "handling engine event")
            recordCycleFailure(error)
        }
    }

    private func scheduleCompletionConfirmation() {
        // Lifecycle events have no success result for the database fetch. Only an
        // awaited round trip can provide the completion proof, including automatic work.
        guard transportTransitionID == nil, !manualSyncInFlight, !cycle.failed, !sendPaused, !writesBlocked else { return }
        confirmationTask?.cancel()
        let session = activeEngineSessionToken
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.activeEngineSessionToken == session else { return }
            self.refresh(trigger: .confirmation)
        }
    }

    /// A CloudKit cycle has a deliberately narrow completion proof: it fetched, its
    /// requested send returned, no local/transport failure remains, and the durable
    /// outbox is empty. An empty queue observed on an arbitrary callback is not proof.
    private func finishCycleIfCurrentWorkIsDrained() {
        guard cycle.isActive, !writesBlocked, !engineStatePersistenceBlocked, engine != nil,
              let account = activeAccount, let repository else { return }
        do {
            guard try repository.state(for: account).zoneState == .active else { return }
            guard try !repository.hasUnappliedBatches(for: account) else { return }
            if cycle.completeIfDrained(
                outboxIsEmpty: try !repository.hasPendingChanges(for: account),
                accountAvailable: engine != nil,
                zoneActive: !writesBlocked,
                hasUnappliedIncoming: try repository.hasUnappliedBatches(for: account),
                engineStatePersistenceFailed: engineStatePersistenceBlocked,
                hasInFlightAttempts: !attemptedSnapshots.isEmpty,
                hasPendingLocalWrites: localPersistenceInFlight > 0
            ) {
                status = .upToDate(Date())
                lastFailureCategory = nil
                retryAt = nil
            } else if !cycle.failed {
                status = .syncing
            }
        } catch {
            recordCycleFailure(error)
        }
    }

    private func recordCycleFailure(_ error: Error) {
        cycle.markFailed()
        lastFailureCategory = Self.failureCategory(for: error)
        retryAt = (error as? CKError)?.userInfo[CKErrorRetryAfterKey].flatMap { $0 as? Double }
            .map { Date().addingTimeInterval($0) }
        if engineStatePersistenceBlocked { lastFailureCategory = .engineState }
        cloudSyncLogger.error(
            "sync cycle failed category=\(self.lastFailureCategory?.rawValue ?? CloudSyncFailureCategory.unknown.rawValue, privacy: .public)"
        )
        if error as? CloudIncomingError == .requiresNewerApp {
            writesBlocked = true
            status = .requiresNewerApp
        } else {
            status = .failed(Self.description(for: error))
        }
    }

    func reportLocalPersistenceFailure(_ error: Error) {
        recordCycleFailure(error)
    }

    func localRecordsDidChange() { requestSend() }

    func localPersistenceBegan() {
        localPersistenceInFlight += 1
        cycle.invalidateSendProof()
        if engine != nil, !cycle.failed, !writesBlocked { status = .syncing }
    }

    func localPersistenceEnded() {
        precondition(localPersistenceInFlight > 0)
        localPersistenceInFlight -= 1
        requestSend()
    }

    /// A support-facing snapshot contains only a short hash prefix and aggregate queue
    /// information; record names, bookmarks, certificate data, and payloads stay local.
    func diagnosticSnapshot() throws -> CloudSyncRuntimeDiagnosticSnapshot? {
        guard let activeAccount, let repository else { return nil }
        return CloudSyncRuntimeDiagnosticSnapshot(
            durable: try repository.diagnosticSnapshot(for: activeAccount),
            cycleIsActive: cycle.isActive,
            lastFailureCategory: lastFailureCategory,
            engineInitialized: engine != nil,
            phase: cycle.failed ? "failed" : (cycle.isActive ? (cycle.fetched ? "sending" : "fetching") : "idle"),
            retryAt: retryAt,
            unappliedBatchCount: try repository.unappliedBatchCount(for: activeAccount)
        )
    }

    private func beginSyncCycle(requiresFreshFetch: Bool = false) {
        cycle.begin(requiresFreshFetch: requiresFreshFetch)
    }

    nonisolated private static func makeRecord(for intent: CloudOutgoingIntent, zoneID: CKRecordZone.ID) throws -> CKRecord {
        let change = intent.change
        let id = CKRecord.ID(recordName: change.recordName, zoneID: zoneID)
        let record: CKRecord
        if let data = intent.server?.systemFields {
            let coder = try NSKeyedUnarchiver(forReadingFrom: data)
            coder.requiresSecureCoding = true
            defer { coder.finishDecoding() }
            guard let restored = CKRecord(coder: coder),
                  restored.recordID == id, restored.recordType == change.recordType else {
                throw CloudSyncRepositoryError.invalidRecordIdentity
            }
            record = restored
        } else {
            record = CKRecord(recordType: change.recordType, recordID: id)
        }
        record.encryptedValues["payload"] = try intent.envelopedPayload() as CKRecordValue
        return record
    }

    private func applyFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async throws {
        guard let account = activeAccount, let repository else { return }
        let session = activeEngineSessionToken
        let zone = zoneID
        do {
        try await Task.detached(priority: .utility) {
        let batch = CloudIncomingBatch(
            modifications: changes.modifications.map(\.record)
                .filter { $0.recordID.zoneID == zone }
                .map { Self.rawRecordMetadata($0, account: account) },
            deletions: changes.deletions.filter { $0.recordID.zoneID == zone }.map {
                CloudIncomingDeletion(recordType: $0.recordType, recordName: $0.recordID.recordName)
            }
        )
        // Persist the raw batch before accepting the next engine token. If journaling
        // itself fails, freeze token persistence until this process is restarted.
        try repository.journal(batch, for: account)
        try repository.replayIncoming(for: account)
        }.value
        } catch {
            guard session == activeEngineSessionToken else { throw CancellationError() }
            // Fail closed even if the journal write itself failed; an advanced token
            // must never be saved without a durable copy of its delivered batch.
            engineStatePersistenceBlocked = true
            throw error
        }
        guard session == activeEngineSessionToken, activeAccount == account else { throw CancellationError() }
        try publishAccountDataset(account)
        remoteTabDevices = try repository.tabSnapshots(for: account)
            .visibleCloudTabDevices(excluding: localDeviceID)
    }

    nonisolated private static func rawRecordMetadata(_ record: CKRecord, account: String) -> CloudRecordState {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return CloudRecordState(
            accountIdentityHash: account, recordType: record.recordType,
            recordName: record.recordID.recordName, systemFields: archiver.encodedData,
            serverPayload: record.encryptedValues["payload"] as? Data
        )
    }
    private func decodeRecord<Value: CloudSyncPayload>(_ record: CKRecord) throws -> Value {
        try CloudRecordPayload<Value>(decoding: requiredPayload(record)).model
    }

    private func requiredPayload(_ record: CKRecord) throws -> Data {
        guard let data = record.encryptedValues["payload"] as? Data else {
            throw CloudSyncRepositoryError.saveMissingPayload
        }
        return data
    }

    private func validateRecordIdentity(_ id: UUID, record: CKRecord) throws {
        guard id.uuidString.lowercased() == record.recordID.recordName.lowercased() else {
            throw CloudSyncRepositoryError.invalidRecordIdentity
        }
    }

    private func acceptTransportSave(_ record: CKRecord, attempted: CloudPendingChange, isConflict: Bool = false) async throws -> Bool {
        guard let repository else { throw CloudSyncRepositoryError.invalidSyncState }
        let session = activeEngineSessionToken
        do {
            let accepted = try await Task.detached(priority: .utility) {
                try repository.acceptSave(Self.rawRecordMetadata(record, account: attempted.accountIdentityHash),
                                          attempted: attempted, isConflict: isConflict)
            }.value
            guard session == activeEngineSessionToken else { throw CancellationError() }
            return accepted
        } catch {
            guard session == activeEngineSessionToken else { throw CancellationError() }
            throw error
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) async throws {
        guard let account = activeAccount, let repository else { return }
        let session = activeEngineSessionToken
        cloudSyncLogger.info(
            "outgoing result saved=\(sent.savedRecords.count) deleted=\(sent.deletedRecordIDs.count) failedSaves=\(sent.failedRecordSaves.count) failedDeletes=\(sent.failedRecordDeletes.count)"
        )
        // CloudKit processes custom-zone changes atomically. Once one item has a real
        // failure, unrelated items may report batchRequestFailed. Reconcile the real
        // error first, then leave every collateral item pending for the retry.
        let hasUnderlyingAtomicFailure = sent.failedRecordSaves.contains {
            Self.errorForRecord($0.record.recordID, in: $0.error).code != .batchRequestFailed
        } || sent.failedRecordDeletes.contains {
            Self.errorForRecord($0.key, in: $0.value).code != .batchRequestFailed
        }
        let hasAtomicFailures = sent.failedRecordSaves.contains {
            Self.errorForRecord($0.record.recordID, in: $0.error).code == .batchRequestFailed
        } || sent.failedRecordDeletes.contains {
            Self.errorForRecord($0.key, in: $0.value).code == .batchRequestFailed
        }
        // Some atomic requests have no per-item root error at all: every item is
        // batchRequestFailed. They are still pending in the durable outbox. Treat
        // those as retryable rather than falsely reporting an internal CloudKit error.
        let deferAtomicFailures = hasUnderlyingAtomicFailure || (!hasUnderlyingAtomicFailure && hasAtomicFailures)
        var surfacedError: CKError?
        for record in sent.savedRecords where record.recordID.zoneID == zoneID {
            if attemptedSnapshots[record.recordID.recordName]?.generation != nil,
               let attempted = attemptedSnapshots[record.recordID.recordName] {
                _ = try await acceptTransportSave(record, attempted: attempted)
                transportSession.finish(record.recordID.recordName, token: session)
            }
        }
        for id in sent.deletedRecordIDs where id.zoneID == zoneID {
            if let generation = attemptedSnapshots[id.recordName]?.generation {
                try repository.acknowledgeDeletion(recordName: id.recordName,
                                           generation: generation, for: account)
                transportSession.finish(id.recordName, token: session)
            }
        }
        for (id, reportedError) in sent.failedRecordDeletes where id.zoneID == zoneID {
            let error = Self.errorForRecord(id, in: reportedError)
            cloudSyncLogger.error(
                "record delete failed idHash=\(Self.recordNameHash(id.recordName), privacy: .public) code=\(error.code.rawValue)"
            )
            if error.code == .unknownItem,
               let generation = attemptedSnapshots[id.recordName]?.generation {
                try repository.acknowledgeDeletion(
                    recordName: id.recordName, generation: generation, for: account
                )
            } else if error.code == .batchRequestFailed, deferAtomicFailures {
                cloudSyncLogger.notice(
                    "deferred collateral atomic delete failure idHash=\(Self.recordNameHash(id.recordName), privacy: .public)"
                )
            } else {
                surfacedError = surfacedError ?? error
            }
            transportSession.finish(id.recordName, token: session)
        }
        for failure in sent.failedRecordSaves where failure.record.recordID.zoneID == zoneID {
            let record = failure.record
            let error = Self.errorForRecord(record.recordID, in: failure.error)
            defer {
                if session == activeEngineSessionToken {
                    transportSession.finish(record.recordID.recordName, token: session)
                }
            }
            cloudSyncLogger.error(
                "record save failed type=\(record.recordType, privacy: .public) idHash=\(Self.recordNameHash(record.recordID.recordName), privacy: .public) code=\(error.code.rawValue)"
            )
            if error.code == .serverRecordChanged,
               let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                guard let pending = attemptedSnapshots[record.recordID.recordName] else { continue }
                if try await !acceptTransportSave(server, attempted: pending, isConflict: true) {
                    let key = record.recordID.recordName
                    conflictCounts[key, default: 0] += 1
                    if conflictCounts[key, default: 0] >= 3 {
                        sendPaused = true
                        surfacedError = error
                    }
                }
            } else if error.code == .unknownItem, record.recordType == "MTDeviceTabs",
                      var state = try repository.recordState(
                        recordName: record.recordID.recordName, for: account
                      ) {
                // Cloud Tabs are owned solely by this device and are self-replacing. If
                // CloudKit no longer has the record represented by cached system fields,
                // discard only those fields so the still-pending snapshot retries as new.
                state.systemFields = nil
                try repository.saveRecordState(state)
                cloudSyncLogger.notice(
                    "cleared stale Cloud Tabs system fields idHash=\(Self.recordNameHash(record.recordID.recordName), privacy: .public)"
                )
            } else if error.code == .batchRequestFailed, deferAtomicFailures {
                cloudSyncLogger.notice(
                    "deferred collateral atomic save failure type=\(record.recordType, privacy: .public) idHash=\(Self.recordNameHash(record.recordID.recordName), privacy: .public)"
                )
            } else {
                surfacedError = surfacedError ?? error
            }
        }
        var state = try repository.state(for: account)
        let hadFailures = !sent.failedRecordSaves.isEmpty || !sent.failedRecordDeletes.isEmpty
        if !hadFailures {
            unresolvedAtomicBatchFailures = 0
        } else if !hasUnderlyingAtomicFailure && hasAtomicFailures, surfacedError == nil {
            unresolvedAtomicBatchFailures += 1
            if unresolvedAtomicBatchFailures >= 3 {
                // CloudKit retains the outbox; pause only this eager confirmation
                // loop and let CKSyncEngine's normal retry policy continue. A later
                // automatic retry starts a fresh cycle and clears this status.
                surfacedError = CKError(.batchRequestFailed)
            }
        }
        lastSendFailureWasHandled = hadFailures && surfacedError == nil
        let hasPending = try repository.hasPendingChanges(for: account)
        if !hasPending { state.lastSentAt = Date() }
        state.updatedAt = Date()
        try repository.save(state)
        try syncPendingFlag()
        if let surfacedError {
            recordCycleFailure(surfacedError)
        } else {
            if !cycle.failed, !writesBlocked { status = .syncing }
            finishCycleIfCurrentWorkIsDrained()
        }
    }


    private func syncPendingFlag() throws {
        guard let engine, let account = activeAccount else { return }
        guard let repository else { return }
        engine.state.hasPendingUntrackedChanges = try !sendPaused && !writesBlocked && repository.hasPendingChanges(for: account)
    }

    private static func identityHash(for recordID: CKRecord.ID) -> String {
        recordNameHash(recordID.recordName)
    }

    nonisolated private static func recordNameHash(_ recordName: String) -> String {
        SHA256.hash(data: Data(recordName.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func applyUbiquitousPreferences() {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: ubiquitousPreferencesKey),
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

    private static var entitledCloudEnvironment: String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
              ) as? [String],
              let environment = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-environment" as CFString, nil
              ) as? String,
              SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.aps-environment" as CFString, nil
              ) != nil,
              SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil
              ) != nil,
              identifiers.contains("iCloud.dev.gemi.major-tom") else { return nil }
        return environment.lowercased()
    }

    private static func description(for error: Error) -> String {
        let cloudError = error as? CKError
        switch cloudError?.code {
        case .notAuthenticated: return unsavedWarning("Sign in to iCloud to sync")
        case .networkUnavailable, .networkFailure: return "Offline; changes are saved locally"
        case .serviceUnavailable, .requestRateLimited:
            return "iCloud is temporarily unavailable; changes are saved locally"
        case .serverRecordChanged, .partialFailure, .batchRequestFailed:
            return "iCloud is reconciling changes; they are saved locally"
        case .unknownItem:
            return "iCloud is reconciling a missing record; changes are saved locally"
        case .invalidArguments, .constraintViolation, .serverRejectedRequest:
            return "iCloud rejected a change; it is saved locally"
        case .permissionFailure: return unsavedWarning(
            "This build is not provisioned for Major Tom iCloud sync"
        )
        default: return "iCloud encountered an unexpected error; changes are saved locally"
        }
    }

    private static func failureCategory(for error: Error) -> CloudSyncFailureCategory {
        if error is CloudIncomingError || error is DecodingError || error is EncodingError { return .payload }
        if error is CloudSyncRepositoryError || error is BookmarkRepositoryError
            || error is ClientCertificateSyncRepositoryError {
            return .persistence
        }
        guard let error = error as? CKError else { return .unknown }
        switch error.code {
        case .notAuthenticated, .permissionFailure, .badDatabase:
            return .account
        case .zoneNotFound, .userDeletedZone:
            return .zone
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
                .requestRateLimited, .resultsTruncated:
            return .transport
        case .serverRecordChanged:
            return .conflict
        case .partialFailure, .batchRequestFailed, .serverRejectedRequest,
                .invalidArguments, .constraintViolation:
            return .payload
        default:
            return .unknown
        }
    }

    private static func recordTypeSummary(_ records: [CKRecord]) -> String {
        Dictionary(grouping: records, by: \.recordType)
            .map { "\($0.key):\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
    }

    /// CKSyncEngine normally provides one error per record. For a partial failure it
    /// can instead wrap that reason in CKPartialErrorsByItemIDKey. Use the matching
    /// item only; an error for a different record must never decide this record's
    /// conflict policy.
    private static func errorForRecord(_ recordID: CKRecord.ID, in error: CKError) -> CKError {
        guard error.code == .partialFailure,
              let partial = error.userInfo[CKPartialErrorsByItemIDKey]
                as? [AnyHashable: Error] else { return error }
        if let nested = partial[AnyHashable(recordID)] as? CKError {
            return nested
        }
        for (item, nested) in partial {
            guard let nested = nested as? CKError else { continue }
            if let itemID = item.base as? CKRecord.ID, itemID == recordID {
                return nested
            }
            if let itemRecord = item.base as? CKRecord, itemRecord.recordID == recordID {
                return nested
            }
        }
        return error
    }


    nonisolated private static func log(_ error: Error, operation: String) {
        let value = error as NSError
        cloudSyncLogger.error(
            "\(operation, privacy: .public) failed domain=\(value.domain, privacy: .public) code=\(value.code)"
        )
        guard let partial = value.userInfo[CKPartialErrorsByItemIDKey]
                as? [AnyHashable: Error] else { return }
        for (item, nestedError) in partial {
            let nested = nestedError as NSError
            cloudSyncLogger.error(
                "partial failure itemHash=\(Self.recordNameHash(String(describing: item)), privacy: .public) domain=\(nested.domain, privacy: .public) code=\(nested.code)"
            )
        }
    }
}
