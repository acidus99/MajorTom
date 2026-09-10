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
    static let shared = ClientCertificateStore(database: SharedMajorTomDatabase.shared)

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

    init(
        defaults: UserDefaults = .standard,
        keychain: ClientCertificateKeychain = ClientCertificateKeychain(),
        database: MajorTomDatabase? = nil
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.database = database
        let activeAccount = database.flatMap {
            try? CloudSyncRepository(database: $0).activeAccountIdentityHash()
        }
        repository = database.map {
            ClientCertificateSyncRepository(database: $0, accountIdentityHash: activeAccount)
        }
        localSynchronizationFlags = (defaults.dictionary(forKey: localStorageFlagsKey) ?? [:])
            .reduce(into: [:]) { result, entry in
                if let id = UUID(uuidString: entry.key), let value = entry.value as? Bool {
                    result[id] = value
                }
            }
        if let repository {
            var legacyState: ClientCertificateSyncState?
            if let data = defaults.data(forKey: syncStorageKey) {
                legacyState = try? JSONDecoder().decode(ClientCertificateSyncState.self, from: data)
            } else if let data = defaults.data(forKey: storageKey),
                      let snapshot = try? JSONDecoder().decode(SyncedClientCertificates.self, from: data) {
                legacyState = ClientCertificateSyncState(legacy: snapshot)
                for descriptor in snapshot.certificates {
                    localSynchronizationFlags[descriptor.id] = descriptor.synchronizesWithICloud
                }
            }
            if let legacyState,
               (try? repository.importLegacy(
                    legacyState,
                    localFlags: localSynchronizationFlags
               )) != nil {
                defaults.removeObject(forKey: storageKey)
                defaults.removeObject(forKey: syncStorageKey)
                defaults.removeObject(forKey: localStorageFlagsKey)
            }
            if let loaded = try? repository.load() {
                syncState = loaded.state
                localSynchronizationFlags = loaded.localFlags
                certificates = loaded.state.activeCertificates(preservingLocalStorageFrom: [])
                associations = loaded.state.activeAssociations
            }
        } else if let data = defaults.data(forKey: syncStorageKey),
                  let state = try? JSONDecoder().decode(ClientCertificateSyncState.self, from: data) {
            syncState = state
            certificates = state.activeCertificates(preservingLocalStorageFrom: [])
            associations = state.activeAssociations
        } else if let data = defaults.data(forKey: storageKey),
                  let snapshot = try? JSONDecoder().decode(SyncedClientCertificates.self, from: data) {
            syncState = ClientCertificateSyncState(legacy: snapshot)
            certificates = snapshot.certificates
            associations = snapshot.associations
            for descriptor in snapshot.certificates {
                localSynchronizationFlags[descriptor.id] = descriptor.synchronizesWithICloud
            }
        }
        applyLocalStorageFlags()
        cloudObserver = ICloudSyncStore.shared.receivedClientCertificates.sink { [weak self] state in
            self?.apply(state)
        }
        accountObserver = ICloudSyncStore.shared.activeAccountChanged.sink { [weak self] account in
            self?.switchAccount(to: account)
        }
        repairDuplicateMetadata()
        persist(syncState)
        ICloudSyncStore.shared.configure(
            clientCertificates: syncState.certificates.isEmpty && syncState.associations.isEmpty
                ? nil
                : syncState
        )
        refreshAvailability()
    }

    private func switchAccount(to account: String) {
        guard let database else { return }
        let next = ClientCertificateSyncRepository(
            database: database, accountIdentityHash: account
        )
        repository = next
        guard let loaded = try? next.load() else { return }
        syncState = loaded.state
        localSynchronizationFlags = loaded.localFlags
        certificates = loaded.state.activeCertificates(preservingLocalStorageFrom: certificates)
        associations = loaded.state.activeAssociations
        applyLocalStorageFlags()
        repairDuplicateMetadata()
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
        let keychain = self.keychain
        let descriptor = try await Task.detached(priority: .userInitiated) {
            try keychain.create(request)
        }.value
        certificates.append(descriptor)
        localSynchronizationFlags[descriptor.id] = descriptor.synchronizesWithICloud
        availability[descriptor.id] = true
        signingValidated.insert(descriptor.id)
        changed()
        return descriptor
    }

    func importIdentity(_ imported: ClientCertificateImport) async throws -> ClientCertificateDescriptor {
        let digest = CertificateDetails.sha256(certificateDER: imported.certificateDER)
        if let existing = certificates.first(where: { $0.certificateSHA256 == digest }) {
            let keychain = self.keychain
            if (try? keychain.certificateDER(for: existing)) != nil {
                try await Task.detached(priority: .userInitiated) {
                    try keychain.validateIdentityCanSign(for: existing)
                }.value
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
            if let index = certificates.firstIndex(where: { $0.id == existing.id }) {
                certificates[index] = descriptor
            }
            localSynchronizationFlags[descriptor.id] = descriptor.synchronizesWithICloud
            identityCache.removeValue(forKey: existing.id)
            availability[existing.id] = true
            signingValidated.insert(existing.id)
            changed()
            return descriptor
        }
        let keychain = self.keychain
        let descriptor = try await Task.detached(priority: .userInitiated) {
            try keychain.importIdentity(imported)
        }.value
        certificates.append(descriptor)
        localSynchronizationFlags[descriptor.id] = descriptor.synchronizesWithICloud
        availability[descriptor.id] = true
        signingValidated.insert(descriptor.id)
        changed()
        return descriptor
    }

    func removeFromMajorTom(_ descriptor: ClientCertificateDescriptor) {
        removeMetadata(for: descriptor)
    }

    func deleteIdentity(_ descriptor: ClientCertificateDescriptor) async throws {
        let keychain = self.keychain
        try await Task.detached(priority: .userInitiated) {
            try keychain.delete(descriptor)
        }.value
        removeMetadata(for: descriptor)
    }

    private func removeMetadata(for descriptor: ClientCertificateDescriptor) {
        let descriptorIDs = descriptor.keychainIdentifiers
        let associationIDs = associations.filter {
            $0.certificateID == descriptor.id
        }.map(\.id)
        certificates.removeAll { $0.id == descriptor.id }
        associations.removeAll { $0.certificateID == descriptor.id }
        availability.removeValue(forKey: descriptor.id)
        localSynchronizationFlags.removeValue(forKey: descriptor.id)
        identityCache.removeValue(forKey: descriptor.id)
        signingValidated.remove(descriptor.id)
        changed()
        ICloudSyncStore.shared.deleteClientCertificateRecords(
            descriptorIDs: descriptorIDs,
            associationIDs: associationIDs
        )
    }

    /// Deletes every client identity and its approval rules. The Keychain work runs off
    /// the main actor, then metadata is changed once so iCloud receives one coherent set
    /// of deletion tombstones.
    func deleteAll() async throws {
        let descriptors = certificates
        let descriptorIDs = descriptors.flatMap(\.keychainIdentifiers)
        let associationIDs = associations.map(\.id)
        let keychain = self.keychain
        try await Task.detached(priority: .userInitiated) {
            for descriptor in descriptors {
                try keychain.delete(descriptor)
            }
        }.value
        certificates = []
        associations = []
        availability = [:]
        localSynchronizationFlags = [:]
        identityCache = [:]
        signingValidated = []
        changed()
        ICloudSyncStore.shared.deleteClientCertificateRecords(
            descriptorIDs: descriptorIDs,
            associationIDs: associationIDs
        )
    }

    func associate(
        certificateID: UUID,
        with url: URL,
        scope: ClientCertificateScopeChoice
    ) {
        guard let endpoint = CapsuleEndpoint(url: url) else { return }
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
        guard let association else { return }
        // One identity per exact scope. More-specific rules may coexist with a capsule
        // root rule and take precedence when resolving a request.
        associations.removeAll {
            $0.endpoint == association.endpoint
                && ($0.scope == .entireCapsule && association.scope == .entireCapsule
                    || $0.scope == association.scope && $0.pathPrefix == association.pathPrefix)
        }
        associations.append(association)
        changed()
    }

    @discardableResult
    func stopUsing(for url: URL) -> Bool {
        guard ClientCertificateAssociation.mostSpecific(
            matching: url,
            in: associations
        ) != nil else { return false }
        // “For this capsule” means every approval for the identity and endpoint,
        // including overlapping whole-capsule and path-specific rules. Removing only
        // the most-specific rule could immediately expose a broader rule underneath it.
        associations = ClientCertificateAssociation.removingCapsuleApproval(
            matching: url,
            from: associations
        )
        changed()
        return true
    }

    func removeAssociation(id: UUID) {
        let originalCount = associations.count
        associations.removeAll { $0.id == id }
        if associations.count != originalCount { changed() }
    }

    func changeAssociationScope(id: UUID, to scope: ClientCertificateScopeChoice) {
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
        changed()
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
            guard let self else { return }
            for descriptor in descriptors {
                self.availability[descriptor.id] = found[descriptor.id] != nil
            }
            self.identityCache.merge(found) { _, refreshed in refreshed }
        }
    }

    private func changed() {
        guard !isApplyingRemote else { return }
        syncState = syncState.reconciled(
            certificates: certificates,
            associations: associations,
            at: Date()
        )
        persist(syncState)
        scheduleUpload(syncState)
    }

    private func apply(_ incoming: ClientCertificateSyncState) {
        guard incoming != syncState else { return }
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
        if !repairDuplicateMetadata() { persist(syncState) }
        refreshAvailability()
    }

    private func persist(_ state: ClientCertificateSyncState) {
        if let repository,
           (try? repository.save(state, localFlags: localSynchronizationFlags)) != nil {
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: syncStorageKey)
        defaults.set(
            Dictionary(uniqueKeysWithValues: localSynchronizationFlags.map {
                ($0.key.uuidString, $0.value)
            }),
            forKey: localStorageFlagsKey
        )
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
    private func repairDuplicateMetadata() -> Bool {
        let active = syncState.certificates.filter { $0.deletedAt == nil }
        let groups = Dictionary(grouping: active) { $0.certificateSHA256.lowercased() }
        let duplicates = groups.values.filter {
            !$0[0].certificateSHA256.isEmpty && $0.count > 1
        }
        guard !duplicates.isEmpty else { return false }

        var canonicalIDByID: [UUID: UUID] = [:]
        for group in duplicates {
            let ids = group.map(\.id).sorted { $0.uuidString < $1.uuidString }
            guard let canonicalID = ids.first else { continue }
            for id in ids { canonicalIDByID[id] = canonicalID }
            let flags = ids.compactMap { localSynchronizationFlags[$0] }
            if !flags.isEmpty {
                localSynchronizationFlags[canonicalID] = flags.contains(true)
            }
            for id in ids where id != canonicalID {
                localSynchronizationFlags.removeValue(forKey: id)
            }
        }

        let repaired = syncState.canonicalizingDuplicateCertificates(at: Date())
        guard repaired != syncState else { return false }
        let oldCertificateCount = certificates.count
        let oldAssociationCount = associations.count
        syncState = repaired
        certificates = repaired.activeCertificates(preservingLocalStorageFrom: certificates)
        associations = repaired.activeAssociations
        applyLocalStorageFlags()
        identityCache = [:]
        signingValidated = []
        if let selected = managerSelectionRequest {
            managerSelectionRequest = canonicalIDByID[selected] ?? selected
        }
        persist(syncState)
        scheduleUpload(syncState)
        clientCertificateLogger.info(
            "reconciled duplicate certificate metadata certificates=\(oldCertificateCount)->\(self.certificates.count) associations=\(oldAssociationCount)->\(self.associations.count)"
        )
        return true
    }

    private func scheduleUpload(_ snapshot: ClientCertificateSyncState) {
        uploadTask?.cancel()
        uploadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            ICloudSyncStore.shared.updateClientCertificates(snapshot)
        }
    }
}
