import Combine
import Foundation
import MajorTomCore
import OSLog

private let clientCertificateLogger = Logger(
    subsystem: "dev.gemi.major-tom",
    category: "ClientCertificateSync"
)

struct ResolvedClientCertificate {
    var descriptor: ClientCertificateDescriptor
    var association: ClientCertificateAssociation
    var tlsIdentity: ClientTLSIdentity?
}

/// The application-wide client identity catalogue and activation policy.
///
/// Metadata is cached locally and mirrored through private CloudKit. Credential material
/// remains exclusively in synchronizable Keychain items and is looked up only when a TLS
/// connection is about to be made.
@MainActor
final class ClientCertificateStore: ObservableObject {
    static let shared = ClientCertificateStore(
        defaults: MajorTomDataScope.defaults,
        keychain: ClientCertificateKeychain(namespace: MajorTomDataScope.keychainNamespace),
        database: SharedMajorTomDatabase.shared
    )

    @Published private(set) var certificates: [ClientCertificateDescriptor] = []
    @Published private(set) var associations: [ClientCertificateAssociation] = []
    @Published private(set) var availability: [UUID: Bool] = [:]
    @Published var lastError: String?

    private let defaults: UserDefaults
    private let keychain: ClientCertificateKeychain
    private var repository: ClientCertificateSyncRepository?
    private let database: MajorTomDatabase?
    private let storageKey = "client-certificates-v1"
    private let syncStorageKey = "client-certificate-sync-state-v2"
    private let localStorageFlagsKey = "client-certificate-local-storage-v1"
    private var syncState = ClientCertificateSyncState()
    private var localSynchronizationFlags: [UUID: Bool] = [:]
    private var isApplyingRemote = false
    private var cloudObserver: AnyCancellable?
    private var accountObserver: AnyCancellable?
    private var uploadTask: Task<Void, Never>?
    private var managerSelectionRequest: UUID?
    private var identityCache: [UUID: ClientTLSIdentity] = [:]
    private var signingValidated: Set<UUID> = []
    private var accountRevision: UInt64 = 0
    private var persistenceReady = true
    private var durableLocalFlags: [UUID: Bool] = [:]
    private struct PersistedCatalogue: Sendable {
        var state: ClientCertificateSyncState
        var flags: [UUID: Bool]
        var fallbackData: Data?
    }
    private var persistenceTask: Task<PersistedCatalogue, Error>?
    private var persistenceRevision = 0
    private var catalogueRevision = 0
    private var initializationTask: Task<Void, Never>?

    var accountToken: UInt64 { accountRevision }

    /// Capture UI intent before scheduling, not when its asynchronous body starts.
    func performAccountAction(_ action: @escaping @MainActor () async -> Void) {
        let token = accountRevision
        Task {
            guard token == accountRevision else { return }
            await action()
        }
    }

    init(
        defaults: UserDefaults = .standard,
        keychain: ClientCertificateKeychain = ClientCertificateKeychain(),
        database: MajorTomDatabase? = nil
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.database = database
        do {
            let activeAccount = try database.map {
                try CloudSyncRepository(database: $0).activeAccountIdentityHash()
            } ?? nil
            repository = database.map {
                ClientCertificateSyncRepository(database: $0, accountIdentityHash: activeAccount)
            }
            localSynchronizationFlags = (defaults.dictionary(forKey: localStorageFlagsKey) ?? [:])
                .reduce(into: [:]) { result, entry in
                    if let id = UUID(uuidString: entry.key), let value = entry.value as? Bool {
                        result[id] = value
                    }
                }
            var legacyState: ClientCertificateSyncState?
            if let data = defaults.data(forKey: syncStorageKey) {
                legacyState = try JSONDecoder().decode(ClientCertificateSyncState.self, from: data)
            } else if let data = defaults.data(forKey: storageKey) {
                let snapshot = try JSONDecoder().decode(SyncedClientCertificates.self, from: data)
                legacyState = ClientCertificateSyncState(legacy: snapshot)
                for descriptor in snapshot.certificates {
                    localSynchronizationFlags[descriptor.id] = descriptor.synchronizesWithICloud
                }
            }
            if let repository {
                if let legacyState {
                    // Bootstrap awaits this task before claiming unowned rows. Never
                    // let a delayed legacy import create new unowned rows after claim.
                    persistenceReady = false
                    let flags = localSynchronizationFlags
                    initializationTask = Task { [weak self] in
                        do {
                            let loaded = try await Task.detached(priority: .utility) {
                                try repository.importLegacy(legacyState, localFlags: flags)
                                return try repository.load()
                            }.value
                            guard let self else { return }
                            self.defaults.removeObject(forKey: self.storageKey)
                            self.defaults.removeObject(forKey: self.syncStorageKey)
                            self.defaults.removeObject(forKey: self.localStorageFlagsKey)
                            self.publishCommitted(.init(state: loaded.state, flags: loaded.localFlags))
                            self.persistenceReady = true
                        } catch {
                            self?.lastError = error.localizedDescription
                            ICloudSyncStore.shared.reportLocalPersistenceFailure(error)
                        }
                    }
                }
                let loaded = try repository.load()
                syncState = loaded.state
                localSynchronizationFlags = loaded.localFlags
            } else if let legacyState {
                syncState = legacyState
            }
            certificates = syncState.activeCertificates(preservingLocalStorageFrom: [])
            associations = syncState.activeAssociations
        } catch {
            persistenceReady = false
            ICloudSyncStore.shared.reportLocalPersistenceFailure(error)
        }
        applyLocalStorageFlags()
        durableLocalFlags = localSynchronizationFlags
        cloudObserver = ICloudSyncStore.shared.receivedClientCertificates.sink { [weak self] state in
            self?.apply(state)
        }
        accountObserver = ICloudSyncStore.shared.activeAccountChanged.sink { [weak self] account in
            self?.switchAccount(to: account)
        }
        Task { await repairDuplicateMetadata() }
        ICloudSyncStore.shared.configure(
            clientCertificates: syncState.certificates.isEmpty && syncState.associations.isEmpty
                ? nil
                : syncState
        )
        refreshAvailability()
    }

    private func switchAccount(to account: String) {
        guard let database else { return }
        accountRevision += 1
        catalogueRevision += 1
        uploadTask?.cancel()
        identityCache = [:]
        signingValidated = []
        availability = [:]
        let next = ClientCertificateSyncRepository(
            database: database, accountIdentityHash: account
        )
        repository = next
        persistenceReady = false
        let loaded: (state: ClientCertificateSyncState, localFlags: [UUID: Bool])
        do { loaded = try next.load() }
        catch {
            certificates = []
            associations = []
            localSynchronizationFlags = [:]
            syncState = ClientCertificateSyncState()
            ICloudSyncStore.shared.reportLocalPersistenceFailure(error)
            return
        }
        syncState = loaded.state
        persistenceReady = true
        durableLocalFlags = loaded.localFlags
        localSynchronizationFlags = loaded.localFlags
        certificates = loaded.state.activeCertificates(preservingLocalStorageFrom: certificates)
        associations = loaded.state.activeAssociations
        applyLocalStorageFlags()
        Task { await repairDuplicateMetadata() }
        refreshAvailability()
    }

    var validCertificates: [ClientCertificateDescriptor] {
        certificates.filter { $0.isValid() }.sorted {
            $0.commonName.localizedStandardCompare($1.commonName) == .orderedAscending
        }
    }

    func descriptor(id: UUID) -> ClientCertificateDescriptor? {
        certificates.first { $0.id == id }
    }

    func requestManagerSelection(_ certificateID: UUID) {
        managerSelectionRequest = certificateID
    }

    func consumeManagerSelectionRequest() -> UUID? {
        defer { managerSelectionRequest = nil }
        guard let managerSelectionRequest,
              certificates.contains(where: { $0.id == managerSelectionRequest }) else { return nil }
        return managerSelectionRequest
    }

    func create(_ request: ClientCertificateCreationRequest) async throws -> ClientCertificateDescriptor {
        let revision = accountRevision
        let keychain = self.keychain
        let descriptor = try await Task.detached(priority: .userInitiated) {
            try keychain.create(request)
        }.value
        guard revision == accountRevision else { throw CancellationError() }
        guard await commitMutation({ certificates, _, flags in
            certificates.append(descriptor)
            flags[descriptor.id] = descriptor.synchronizesWithICloud
        }) else { throw CocoaError(.fileWriteUnknown) }
        availability[descriptor.id] = true
        signingValidated.insert(descriptor.id)
        return descriptor
    }

    func importIdentity(_ imported: ClientCertificateImport) async throws -> ClientCertificateDescriptor {
        let revision = accountRevision
        let digest = CertificateDetails.sha256(certificateDER: imported.certificateDER)
        if let existing = certificates.first(where: { $0.certificateSHA256 == digest }) {
            let keychain = self.keychain
            if (try? keychain.certificateDER(for: existing)) != nil {
                try await Task.detached(priority: .userInitiated) {
                    try keychain.validateIdentityCanSign(for: existing)
                }.value
                guard revision == accountRevision else { throw CancellationError() }
                availability[existing.id] = true
                signingValidated.insert(existing.id)
                return existing
            }
            // An ad-hoc rebuild changes the app's Keychain identity. Repair imports made
            // by an earlier development signature in place so capsule approvals and
            // synced metadata keep referring to the same certificate UUID.
            let descriptor = try await Task.detached(priority: .userInitiated) {
                return try keychain.importIdentity(imported, id: existing.id)
            }.value
            guard revision == accountRevision else { throw CancellationError() }
            guard await commitMutation({ certificates, _, flags in
                if let index = certificates.firstIndex(where: { $0.id == existing.id }) { certificates[index] = descriptor }
                flags[descriptor.id] = descriptor.synchronizesWithICloud
            }) else { throw CocoaError(.fileWriteUnknown) }
            identityCache.removeValue(forKey: existing.id)
            availability[existing.id] = true
            signingValidated.insert(existing.id)
            return descriptor
        }
        let keychain = self.keychain
        let descriptor = try await Task.detached(priority: .userInitiated) {
            try keychain.importIdentity(imported)
        }.value
        guard revision == accountRevision else { throw CancellationError() }
        guard await commitMutation({ certificates, _, flags in
            certificates.append(descriptor)
            flags[descriptor.id] = descriptor.synchronizesWithICloud
        }) else { throw CocoaError(.fileWriteUnknown) }
        availability[descriptor.id] = true
        signingValidated.insert(descriptor.id)
        return descriptor
    }

    func removeFromMajorTom(_ descriptor: ClientCertificateDescriptor) async {
        await removeMetadata(for: descriptor)
    }

    func deleteIdentity(_ descriptor: ClientCertificateDescriptor) async throws {
        let revision = accountRevision
        let keychain = self.keychain
        try await Task.detached(priority: .userInitiated) {
            try keychain.delete(descriptor)
        }.value
        guard revision == accountRevision else { throw CancellationError() }
        guard await removeMetadata(for: descriptor) else { throw CocoaError(.fileWriteUnknown) }
    }

    @discardableResult
    private func removeMetadata(for descriptor: ClientCertificateDescriptor) async -> Bool {
        guard await commitMutation({ certificates, associations, flags in
            certificates.removeAll { $0.id == descriptor.id }
            associations.removeAll { $0.certificateID == descriptor.id }
            flags[descriptor.id] = nil
        }) else { return false }
        availability.removeValue(forKey: descriptor.id)
        identityCache.removeValue(forKey: descriptor.id)
        signingValidated.remove(descriptor.id)
        return true
    }

    /// Deletes every client identity and its approval rules. The Keychain work runs off
    /// the main actor, then metadata is changed once so iCloud receives one coherent set
    /// of deletion tombstones.
    func deleteAll() async throws {
        let revision = accountRevision
        let descriptors = certificates
        let keychain = self.keychain
        try await Task.detached(priority: .userInitiated) {
            for descriptor in descriptors {
                try keychain.delete(descriptor)
            }
        }.value
        guard revision == accountRevision else { throw CancellationError() }
        guard await commitMutation({ certificates, associations, flags in
            certificates = []
            associations = []
            flags = [:]
        }) else { throw CocoaError(.fileWriteUnknown) }
        availability = [:]
        identityCache = [:]
        signingValidated = []
    }

    @discardableResult
    func associate(
        certificateID: UUID,
        with url: URL,
        scope: ClientCertificateScopeChoice
    ) async -> Bool {
        guard let endpoint = CapsuleEndpoint(url: url) else { return false }
        let association: ClientCertificateAssociation?
        switch scope {
        case .entireCapsule:
            association = .entireCapsule(
                certificateID: certificateID,
                endpoint: endpoint,
                approvedPath: ClientCertificateAssociation.requestPath(for: url)
            )
        case .pathAndDescendants:
            association = .pathAndDescendants(certificateID: certificateID, url: url)
        }
        guard let association else { return false }
        // One identity per exact scope. More-specific rules may coexist with a capsule
        // root rule and take precedence when resolving a request.
        return await commitMutation { certificates, associations, _ in
        guard certificates.contains(where: { $0.id == certificateID }) else { return }
        associations.removeAll {
            $0.endpoint == association.endpoint
                && ($0.scope == .entireCapsule && association.scope == .entireCapsule
                    || $0.scope == association.scope && $0.pathPrefix == association.pathPrefix)
        }
        associations.append(association)
        }
    }

    @discardableResult
    func stopUsing(for url: URL) async -> Bool {
        guard ClientCertificateAssociation.mostSpecific(
            matching: url,
            in: associations
        ) != nil else { return false }
        // “For this capsule” means every approval for the identity and endpoint,
        // including overlapping whole-capsule and path-specific rules. Removing only
        // the most-specific rule could immediately expose a broader rule underneath it.
        return await commitMutation { _, associations, _ in
        associations = ClientCertificateAssociation.removingCapsuleApproval(
            matching: url,
            from: associations
        )
        }
    }

    func removeAssociation(id: UUID) async {
        _ = await commitMutation { _, associations, _ in associations.removeAll { $0.id == id } }
    }

    func changeAssociationScope(id: UUID, to scope: ClientCertificateScopeChoice) async {
        _ = await commitMutation { _, associations, _ in
        guard var association = associations.first(where: { $0.id == id }),
              association.scope != scope else { return }
        associations.removeAll { $0.id == id }
        association.scope = scope
        associations.removeAll {
            $0.endpoint == association.endpoint
                && ($0.scope == .entireCapsule && scope == .entireCapsule
                    || $0.scope == scope && $0.pathPrefix == association.pathPrefix)
        }
        associations.append(association)
        }
    }

    /// Resolves the identity to offer for `url`, loading it from the Keychain if this is
    /// the first request that needs it.
    ///
    /// Async because the first resolution of a certificate performs a real Keychain
    /// signing operation to check the private key is usable, and this is called on the
    /// main actor from every navigation. create, importIdentity, delete and
    /// exportIdentityPEM have always detached the same keychain; the read path used to
    /// run it inline and block the main actor while a page was being opened.
    func resolvedCertificate(for url: URL) async -> ResolvedClientCertificate? {
        let revision = accountRevision
        await flushPendingWrites()
        await reloadLatestCatalogue()
        guard revision == accountRevision else { return nil }
        guard let association = ClientCertificateAssociation.mostSpecific(
            matching: url,
            in: associations
        ), let descriptor = descriptor(id: association.certificateID) else { return nil }

        var identity: ClientTLSIdentity?
        if descriptor.isValid() {
            let id = descriptor.id
            if let cached = identityCache[id], signingValidated.contains(id) {
                identity = cached
            } else {
                let keychain = self.keychain
                let needsSigningCheck = !signingValidated.contains(id)
                identity = await Task.detached(priority: .userInitiated) {
                    () -> ClientTLSIdentity? in
                    do {
                        if needsSigningCheck {
                            try keychain.validateIdentityCanSign(for: descriptor)
                        }
                        return try keychain.identity(for: descriptor)
                    } catch {
                        return nil
                    }
                }.value
                guard revision == accountRevision,
                      associations.contains(association), certificates.contains(descriptor) else { return nil }
                if let identity {
                    identityCache[id] = identity
                    signingValidated.insert(id)
                }
            }
        }
        availability[descriptor.id] = identity != nil
        return ResolvedClientCertificate(
            descriptor: descriptor,
            association: association,
            tlsIdentity: identity
        )
    }

    func certificatePEM(for descriptor: ClientCertificateDescriptor) -> String? {
        guard let der = try? keychain.certificateDER(for: descriptor) else { return nil }
        return CertificateDetails.pem(certificateDER: der)
    }

    func exportIdentityPEM(for descriptor: ClientCertificateDescriptor) async throws -> String {
        let keychain = self.keychain
        return try await Task.detached(priority: .userInitiated) {
            try keychain.exportIdentityPEM(for: descriptor)
        }.value
    }

    func certificateDER(for descriptor: ClientCertificateDescriptor) -> Data? {
        try? keychain.certificateDER(for: descriptor)
    }

    func associations(for descriptor: ClientCertificateDescriptor) -> [ClientCertificateAssociation] {
        associations.filter { $0.certificateID == descriptor.id }.sorted {
            if $0.endpoint.host != $1.endpoint.host { return $0.endpoint.host < $1.endpoint.host }
            if $0.endpoint.port != $1.endpoint.port { return $0.endpoint.port < $1.endpoint.port }
            return $0.pathPrefix < $1.pathPrefix
        }
    }

    /// Refreshes which identities are actually usable.
    ///
    /// One Keychain query per stored certificate. Called from `init`, so doing it inline
    /// blocked the main actor for the whole catalogue while the first tab was created.
    func refreshAvailability() {
        let revision = accountRevision
        let descriptors = certificates
        guard !descriptors.isEmpty else { return }
        let keychain = self.keychain
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                () -> [UUID: ClientTLSIdentity] in
                var result: [UUID: ClientTLSIdentity] = [:]
                for descriptor in descriptors {
                    if let identity = try? keychain.identity(for: descriptor) {
                        result[descriptor.id] = identity
                    }
                }
                return result
            }.value
            guard let self, self.accountRevision == revision else { return }
            for descriptor in descriptors where self.certificates.contains(where: { $0.id == descriptor.id }) {
                self.availability[descriptor.id] = found[descriptor.id] != nil
            }
            self.identityCache.merge(found.filter { id, _ in self.certificates.contains { $0.id == id } }) { _, refreshed in refreshed }
        }
    }


    private func apply(_ incoming: ClientCertificateSyncState) {
        guard incoming != syncState else { return }
        catalogueRevision += 1
        uploadTask?.cancel()
        isApplyingRemote = true
        let activeIDs = Set(incoming.certificates.filter { $0.deletedAt == nil }.map(\.id))
        let removedIDs = Set(certificates.map(\.id)).subtracting(activeIDs)
        for id in removedIDs {
            // A remote metadata deletion must not erase private key material. Keychain
            // has its own account and delivery lifecycle; only an explicit local delete
            // is authoritative for destructive cleanup.
            identityCache[id] = nil
        }
        certificates = incoming.activeCertificates(preservingLocalStorageFrom: certificates)
        applyLocalStorageFlags()
        identityCache = identityCache.filter { id, _ in
            certificates.contains { $0.id == id }
        }
        signingValidated = signingValidated.filter { id in
            certificates.contains { $0.id == id }
        }
        associations = incoming.activeAssociations
        syncState = incoming
        isApplyingRemote = false
        // Incoming rows were committed by the sync repository. Never turn this
        // publication back into a whole-catalogue local replacement.
        Task { await repairDuplicateMetadata() }
        refreshAvailability()
    }


    private func applyLocalStorageFlags() {
        for index in certificates.indices {
            if let value = localSynchronizationFlags[certificates[index].id] {
                certificates[index].synchronizesWithICloud = value
            }
        }
    }

    /// Repairs the legacy state where separate Macs gave identical certificate bytes
    /// different record UUIDs. This changes CloudKit metadata only; Keychain items are
    /// intentionally retained and fingerprint lookup keeps any old UUID usable.
    @discardableResult
    private func repairDuplicateMetadata() async -> Bool {
        guard persistenceReady else { return false }
        let groups = Dictionary(grouping: certificates) { $0.certificateSHA256.lowercased() }
        guard groups.values.contains(where: { !$0[0].certificateSHA256.isEmpty && $0.count > 1 }) else { return false }
        let selected = managerSelectionRequest
        let success = await commitMutation { certificates, associations, flags in
            let groups = Dictionary(grouping: certificates) { $0.certificateSHA256.lowercased() }
            for group in groups.values where !group[0].certificateSHA256.isEmpty && group.count > 1 {
                let ids = group.map(\.id).sorted { $0.uuidString < $1.uuidString }
                let values = ids.compactMap { flags[$0] }
                if !values.isEmpty { flags[ids[0]] = values.contains(true) }
                for id in ids.dropFirst() { flags[id] = nil }
            }
            let repaired = ClientCertificateSyncState().reconciled(
                certificates: certificates, associations: associations, at: Date()
            ).canonicalizingDuplicateCertificates(at: Date())
            certificates = repaired.activeCertificates(preservingLocalStorageFrom: certificates)
            associations = repaired.activeAssociations
        }
        if success {
            if let selected, let canonical = certificates.first(where: { $0.keychainIdentifiers.contains(selected) }) {
                managerSelectionRequest = canonical.id
            }
            identityCache = [:]
            signingValidated = []
            refreshAvailability()
        }
        return success
    }

    private func scheduleUpload(_ snapshot: ClientCertificateSyncState) {
        uploadTask?.cancel()
        uploadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            ICloudSyncStore.shared.updateClientCertificates(snapshot)
        }
    }

    private func commitMutation(
        _ operation: @escaping @Sendable (inout [ClientCertificateDescriptor], inout [ClientCertificateAssociation], inout [UUID: Bool]) -> Void
    ) async -> Bool {
        guard !ICloudSyncStore.shared.isClaimingLocalData else {
            lastError = "Local data is being prepared for iCloud. Try again in a moment."
            return false
        }
        guard persistenceReady else {
            ICloudSyncStore.shared.reportLocalPersistenceFailure(CocoaError(.fileReadCorruptFile))
            return false
        }
        ICloudSyncStore.shared.localPersistenceBegan()
        defer { ICloudSyncStore.shared.localPersistenceEnded() }
        let account = accountRevision
        persistenceRevision += 1
        let revision = persistenceRevision
        let publication = catalogueRevision
        let previous = persistenceTask
        let repository = self.repository
        let base = syncState
        let baseFlags = localSynchronizationFlags
        let task = Task.detached(priority: .userInitiated) {
            let previousValue = try? await previous?.value // ordering; the originating edit reports its own failure
            if let repository {
                let result = try repository.update(operation)
                return PersistedCatalogue(state: result.state, flags: result.localFlags)
            }
            let base = previousValue?.state ?? base
            var certificates = base.activeCertificates(preservingLocalStorageFrom: [])
            var associations = base.activeAssociations
            var flags = previousValue?.flags ?? baseFlags
            operation(&certificates, &associations, &flags)
            let state = base.reconciled(certificates: certificates, associations: associations, at: Date())
            return PersistedCatalogue(state: state, flags: flags, fallbackData: try JSONEncoder().encode(state))
        }
        persistenceTask = task
        do {
            let committed = try await task.value
            guard account == accountRevision else {
                if revision == persistenceRevision { persistenceTask = nil }
                return false
            }
            if revision == persistenceRevision {
                persistenceTask = nil
                if publication == catalogueRevision { publishCommitted(committed) }
                else if repository != nil { await reloadLatestCatalogue() }
            }
            guard account == accountRevision else { return false }
            ICloudSyncStore.shared.localRecordsDidChange()
            return true
        } catch {
            if revision == persistenceRevision {
                persistenceTask = nil
                // An earlier queued mutation may have committed while its publication
                // was superseded by this failed edit. Reload its durable approval state.
                if account == accountRevision { await reloadLatestCatalogue() }
            }
            guard account == accountRevision else { return false }
            ICloudSyncStore.shared.reportLocalPersistenceFailure(error)
            lastError = error.localizedDescription
            return false
        }
    }

    private func publishCommitted(_ committed: PersistedCatalogue) {
        catalogueRevision += 1
        if let data = committed.fallbackData {
            defaults.set(data, forKey: syncStorageKey)
            defaults.set(Dictionary(uniqueKeysWithValues: committed.flags.map { ($0.key.uuidString, $0.value) }), forKey: localStorageFlagsKey)
        }
        syncState = committed.state
        durableLocalFlags = committed.flags
        localSynchronizationFlags = committed.flags
        certificates = committed.state.activeCertificates(preservingLocalStorageFrom: certificates)
        associations = committed.state.activeAssociations
        applyLocalStorageFlags()
        identityCache = identityCache.filter { id, _ in certificates.contains { $0.id == id } }
        signingValidated = signingValidated.filter { id in certificates.contains { $0.id == id } }
    }

    func flushPendingWrites() async {
        await initializationTask?.value
        while let task = persistenceTask {
            let account = accountRevision
            let revision = persistenceRevision
            do {
                let committed = try await task.value
                guard revision == persistenceRevision else { continue }
                persistenceRevision += 1 // supersede the pending completion's publication
                persistenceTask = nil
                guard account == accountRevision else { continue }
                if repository != nil { await reloadLatestCatalogue() }
                else { publishCommitted(committed) }
            } catch {
                if revision == persistenceRevision { persistenceTask = nil }
                if account == accountRevision { ICloudSyncStore.shared.reportLocalPersistenceFailure(error) }
            }
        }
    }

    func prepareForFirstAccountClaim() async throws {
        await flushPendingWrites()
        guard persistenceReady else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func reloadLatestCatalogue() async {
        guard let repository else { return }
        let account = accountRevision
        let publication = catalogueRevision
        let mutation = persistenceRevision
        do {
            let latest = try await Task.detached(priority: .utility) { try repository.load() }.value
            guard account == accountRevision, publication == catalogueRevision, mutation == persistenceRevision else { return }
            publishCommitted(.init(state: latest.state, flags: latest.localFlags))
        } catch {
            if account == accountRevision { ICloudSyncStore.shared.reportLocalPersistenceFailure(error) }
        }
    }
}
