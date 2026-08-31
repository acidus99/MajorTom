import Combine
import Foundation
import MajorTomCore

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
    static let shared = ClientCertificateStore()

    @Published private(set) var certificates: [ClientCertificateDescriptor] = []
    @Published private(set) var associations: [ClientCertificateAssociation] = []
    @Published private(set) var availability: [UUID: Bool] = [:]
    @Published var lastError: String?

    private let defaults: UserDefaults
    private let keychain: ClientCertificateKeychain
    private let storageKey = "client-certificates-v1"
    private let syncStorageKey = "client-certificate-sync-state-v2"
    private let localStorageFlagsKey = "client-certificate-local-storage-v1"
    private var syncState = ClientCertificateSyncState()
    private var localSynchronizationFlags: [UUID: Bool] = [:]
    private var isApplyingRemote = false
    private var cloudObserver: AnyCancellable?
    private var uploadTask: Task<Void, Never>?
    private var managerSelectionRequest: UUID?
    private var identityCache: [UUID: ClientTLSIdentity] = [:]
    private var signingValidated: Set<UUID> = []

    init(
        defaults: UserDefaults = .standard,
        keychain: ClientCertificateKeychain = ClientCertificateKeychain()
    ) {
        self.defaults = defaults
        self.keychain = keychain
        localSynchronizationFlags = (defaults.dictionary(forKey: localStorageFlagsKey) ?? [:])
            .reduce(into: [:]) { result, entry in
                if let id = UUID(uuidString: entry.key), let value = entry.value as? Bool {
                    result[id] = value
                }
            }
        if let data = defaults.data(forKey: syncStorageKey),
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
        persist(syncState)
        ICloudSyncStore.shared.configure(
            clientCertificates: syncState.certificates.isEmpty && syncState.associations.isEmpty
                ? nil
                : syncState
        )
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
            if (try? keychain.certificateDER(for: existing.id)) != nil {
                try await Task.detached(priority: .userInitiated) {
                    try keychain.validateIdentityCanSign(for: existing.id)
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

    func delete(_ descriptor: ClientCertificateDescriptor) async throws {
        let keychain = self.keychain
        try await Task.detached(priority: .userInitiated) {
            try keychain.delete(id: descriptor.id)
        }.value
        certificates.removeAll { $0.id == descriptor.id }
        associations.removeAll { $0.certificateID == descriptor.id }
        availability.removeValue(forKey: descriptor.id)
        localSynchronizationFlags.removeValue(forKey: descriptor.id)
        identityCache.removeValue(forKey: descriptor.id)
        signingValidated.remove(descriptor.id)
        changed()
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
                        if needsSigningCheck { try keychain.validateIdentityCanSign(for: id) }
                        return try keychain.identity(for: id)
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
        guard let der = try? keychain.certificateDER(for: descriptor.id) else { return nil }
        return CertificateDetails.pem(certificateDER: der)
    }

    func exportIdentityPEM(for descriptor: ClientCertificateDescriptor) async throws -> String {
        let keychain = self.keychain
        return try await Task.detached(priority: .userInitiated) {
            try keychain.exportIdentityPEM(for: descriptor.id)
        }.value
    }

    func certificateDER(for descriptor: ClientCertificateDescriptor) -> Data? {
        try? keychain.certificateDER(for: descriptor.id)
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
        let identifiers = certificates.map(\.id)
        guard !identifiers.isEmpty else { return }
        let keychain = self.keychain
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                () -> [UUID: ClientTLSIdentity] in
                var result: [UUID: ClientTLSIdentity] = [:]
                for id in identifiers {
                    if let identity = try? keychain.identity(for: id) { result[id] = identity }
                }
                return result
            }.value
            guard let self else { return }
            for id in identifiers {
                self.availability[id] = found[id] != nil
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
        let merged = syncState.merging(incoming)
        guard merged != syncState else { return }
        uploadTask?.cancel()
        isApplyingRemote = true
        let activeIDs = Set(merged.certificates.filter { $0.deletedAt == nil }.map(\.id))
        let removedIDs = Set(certificates.map(\.id)).subtracting(activeIDs)
        for id in removedIDs {
            // A descriptor tombstone represents deletion of the identity, not merely
            // hiding it from this catalogue. Remove any local/synchronizable Keychain
            // material too; a missing item is harmless and needs no user-facing error.
            try? keychain.delete(id: id)
            localSynchronizationFlags.removeValue(forKey: id)
        }
        certificates = merged.activeCertificates(preservingLocalStorageFrom: certificates)
        applyLocalStorageFlags()
        identityCache = identityCache.filter { id, _ in
            certificates.contains { $0.id == id }
        }
        signingValidated = signingValidated.filter { id in
            certificates.contains { $0.id == id }
        }
        associations = merged.activeAssociations
        syncState = merged
        isApplyingRemote = false
        persist(syncState)
        refreshAvailability()
    }

    private func persist(_ state: ClientCertificateSyncState) {
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

    private func scheduleUpload(_ snapshot: ClientCertificateSyncState) {
        uploadTask?.cancel()
        uploadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            ICloudSyncStore.shared.updateClientCertificates(snapshot)
        }
    }
}
