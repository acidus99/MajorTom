import Combine
import Foundation
import OSLog

private let clientCertificateLogger = Logger(
    subsystem: "dev.gemi.major-tom",
    category: "ClientCertificateSync"
)

public struct ResolvedClientCertificate: Sendable {
    public var descriptor: ClientCertificateDescriptor
    public var association: ClientCertificateAssociation
    public var tlsIdentity: ClientTLSIdentity?
}

/// The application-wide client identity catalogue and activation policy.
///
/// Metadata is cached locally and mirrored through private CloudKit. Credential material
/// remains exclusively in synchronizable Keychain items and is looked up only when a TLS
/// connection is about to be made.
@MainActor
public final class ClientCertificateStore: ObservableObject {
    @Published public private(set) var certificates: [ClientCertificateDescriptor] = []
    @Published public private(set) var associations: [ClientCertificateAssociation] = []
    @Published public private(set) var availability: [UUID: Bool] = [:]
    @Published public var lastError: String?

    private let defaults: UserDefaults
    private let keychain: any ClientIdentityMaterialStore
    private var repository: ClientCertificateSyncRepository?
    private let activity: LocalPersistenceActivity
    private let storageKey = "client-certificates-v1"
    private let syncStorageKey = "client-certificate-sync-state-v2"
    private let localStorageFlagsKey = "client-certificate-local-storage-v1"
    private var syncState = ClientCertificateSyncState()
    private var localSynchronizationFlags: [UUID: Bool] = [:]
    private var managerSelectionRequest: UUID?
    private var identityCache: [UUID: ClientTLSIdentity] = [:]
    private var signingValidated: Set<UUID> = []
    private var accountRevision: UInt64 = 0
    private var persistenceReady = true
    private var durableLocalFlags: [UUID: Bool] = [:]
    private struct PersistedCatalogue: Sendable {
        var state: ClientCertificateSyncState
        var flags: [UUID: Bool]
    }
    private var persistenceTask: Task<PersistedCatalogue, Error>?
    private var persistenceRevision = 0
    private var catalogueRevision = 0
    private var initializationTask: Task<Void, Never>?

    private var isDeletingUserData = false
    private var materialOperations = 0
    private var materialWaiters: [CheckedContinuation<Void, Never>] = []

    private func beginMaterialOperation() throws {
        guard !isDeletingUserData, persistenceReady, !activity.isPreparingAccount else { throw CancellationError() }
        materialOperations += 1
    }

    private func endMaterialOperation() {
        materialOperations -= 1
        if materialOperations == 0 {
            let waiters = materialWaiters
            materialWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func drainMaterialOperations() async {
        if materialOperations > 0 {
            await withCheckedContinuation { materialWaiters.append($0) }
        }
    }

    public var accountToken: UInt64 { accountRevision }

    /// Capture UI intent before scheduling, not when its asynchronous body starts.
    public func performAccountAction(_ action: @escaping @MainActor () async -> Void) {
        let token = accountRevision
        Task {
            guard token == accountRevision else { return }
            await action()
        }
    }

    public init(
        defaults: UserDefaults,
        keychain: any ClientIdentityMaterialStore,
        repository: ClientCertificateSyncRepository?,
        activity: LocalPersistenceActivity
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.repository = repository
        self.activity = activity
        do {
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
                            activity.report(error)
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
            activity.report(error)
        }
        applyLocalStorageFlags()
        durableLocalFlags = localSynchronizationFlags
        if repository == nil { persistenceReady = false }
        Task { await repairDuplicateMetadata() }
        refreshAvailability()
    }

    public func replaceRepository(_ next: ClientCertificateSyncRepository?) {
        accountRevision += 1
        catalogueRevision += 1
        identityCache = [:]
        signingValidated = []
        availability = [:]
        repository = next
        persistenceReady = false
        let loaded: (state: ClientCertificateSyncState, localFlags: [UUID: Bool])
        do {
            guard let next else { throw CocoaError(.fileReadUnknown) }
            loaded = try next.load()
        }
        catch {
            certificates = []
            associations = []
            localSynchronizationFlags = [:]
            syncState = ClientCertificateSyncState()
            activity.report(error)
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

    public var validCertificates: [ClientCertificateDescriptor] {
        certificates.filter { $0.isValid() }.sorted {
            $0.commonName.localizedStandardCompare($1.commonName) == .orderedAscending
        }
    }

    public func descriptor(id: UUID) -> ClientCertificateDescriptor? {
        certificates.first { $0.id == id }
    }

    public func requestManagerSelection(_ certificateID: UUID) {
        managerSelectionRequest = certificateID
    }

    public func consumeManagerSelectionRequest() -> UUID? {
        defer { managerSelectionRequest = nil }
        guard let managerSelectionRequest,
              certificates.contains(where: { $0.id == managerSelectionRequest }) else { return nil }
        return managerSelectionRequest
    }

    public func create(_ request: ClientCertificateCreationRequest) async throws -> ClientCertificateDescriptor {
        try beginMaterialOperation()
        defer { endMaterialOperation() }
        let revision = accountRevision
        let keychain = self.keychain
        let id = UUID()
        var materialWasCommitted = false
        do {
            let descriptor = try await Task.detached(priority: .userInitiated) {
                try keychain.create(request, id: id, now: Date())
            }.value
            guard revision == accountRevision else { throw CancellationError() }
            guard await commitMutation({ certificates, _, flags in
                certificates.append(descriptor)
                flags[descriptor.id] = descriptor.synchronizesWithICloud
            }, onDurableCommit: { materialWasCommitted = true }) else { throw CocoaError(.fileWriteUnknown) }
            availability[descriptor.id] = true
            signingValidated.insert(descriptor.id)
            return descriptor
        } catch {
            // Only this operation owns this newly allocated UUID. Never roll back
            // by fingerprint: that could remove an existing or synchronized key.
            if !materialWasCommitted {
                _ = try? await Task.detached { try keychain.delete(id: id) }.value
            }
            throw error
        }
    }

    public func importIdentity(_ imported: ClientCertificateImport) async throws -> ClientCertificateDescriptor {
        try beginMaterialOperation()
        defer { endMaterialOperation() }
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
        let id = UUID()
        var materialWasCommitted = false
        do {
            let descriptor = try await Task.detached(priority: .userInitiated) {
                try keychain.importIdentity(imported, id: id)
            }.value
            guard revision == accountRevision else { throw CancellationError() }
            guard await commitMutation({ certificates, _, flags in
                certificates.append(descriptor)
                flags[descriptor.id] = descriptor.synchronizesWithICloud
            }, onDurableCommit: { materialWasCommitted = true }) else { throw CocoaError(.fileWriteUnknown) }
            availability[descriptor.id] = true
            signingValidated.insert(descriptor.id)
            return descriptor
        } catch {
            if !materialWasCommitted {
                _ = try? await Task.detached { try keychain.delete(id: id) }.value
            }
            throw error
        }
    }

    public func removeFromMajorTom(_ descriptor: ClientCertificateDescriptor) async {
        guard !isDeletingUserData else { return }
        await removeMetadata(for: descriptor)
    }

    public func deleteIdentity(_ descriptor: ClientCertificateDescriptor) async throws {
        try beginMaterialOperation()
        defer { endMaterialOperation() }
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
    public func deleteAll() async throws {
        guard !isDeletingUserData else { throw CancellationError() }
        isDeletingUserData = true
        defer { isDeletingUserData = false }
        let revision = accountRevision
        await flushPendingWrites()
        guard revision == accountRevision else { throw CancellationError() }
        guard persistenceReady, !activity.isPreparingAccount else {
            throw CocoaError(.fileWriteUnknown)
        }
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
    public func associate(
        certificateID: UUID,
        with url: URL,
        scope: ClientCertificateScopeChoice
    ) async -> Bool {
        guard !isDeletingUserData, url.scheme?.lowercased() == "gemini",
              let endpoint = CapsuleEndpoint(url: url) else { return false }
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
    public func stopUsing(for url: URL) async -> Bool {
        guard !isDeletingUserData else { return false }
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

    public func removeAssociation(id: UUID) async {
        guard !isDeletingUserData else { return }
        _ = await commitMutation { _, associations, _ in associations.removeAll { $0.id == id } }
    }

    public func changeAssociationScope(id: UUID, to scope: ClientCertificateScopeChoice) async {
        guard !isDeletingUserData else { return }
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
    public func resolvedCertificate(for url: URL) async -> ResolvedClientCertificate? {
        guard !isDeletingUserData, url.scheme?.lowercased() == "gemini" else { return nil }
        let revision = accountRevision
        await flushPendingWrites()
        await reloadLatestCatalogue()
        guard !isDeletingUserData, revision == accountRevision else { return nil }
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
                guard !isDeletingUserData, revision == accountRevision,
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

    public func certificatePEM(for descriptor: ClientCertificateDescriptor) -> String? {
        guard let der = try? keychain.certificateDER(for: descriptor) else { return nil }
        return CertificateDetails.pem(certificateDER: der)
    }

    public func exportIdentityPEM(for descriptor: ClientCertificateDescriptor) async throws -> String {
        let keychain = self.keychain
        return try await Task.detached(priority: .userInitiated) {
            try keychain.exportIdentityPEM(for: descriptor)
        }.value
    }

    public func certificateDER(for descriptor: ClientCertificateDescriptor) -> Data? {
        try? keychain.certificateDER(for: descriptor)
    }

    public func associations(for descriptor: ClientCertificateDescriptor) -> [ClientCertificateAssociation] {
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
    public func refreshAvailability() {
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

    public func reloadCommittedCatalogue() async {
        await reloadLatestCatalogue()
        _ = await repairDuplicateMetadata()
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

    private func commitMutation(
        _ operation: @escaping @Sendable (inout [ClientCertificateDescriptor], inout [ClientCertificateAssociation], inout [UUID: Bool]) -> Void,
        onDurableCommit: (@MainActor () -> Void)? = nil
    ) async -> Bool {
        guard !activity.isPreparingAccount else {
            lastError = "Local data is being prepared for iCloud. Try again in a moment."
            return false
        }
        guard persistenceReady, let repository else {
            activity.report(CocoaError(.fileReadCorruptFile))
            return false
        }
        activity.begin()
        defer { activity.end() }
        let account = accountRevision
        persistenceRevision += 1
        let revision = persistenceRevision
        let publication = catalogueRevision
        let previous = persistenceTask
        let task = Task.detached(priority: .userInitiated) {
            _ = try? await previous?.value // ordering; the originating edit reports its own failure
            let result = try repository.update(operation)
            return PersistedCatalogue(state: result.state, flags: result.localFlags)
        }
        persistenceTask = task
        do {
            let committed = try await task.value
            onDurableCommit?()
            guard account == accountRevision else {
                if revision == persistenceRevision { persistenceTask = nil }
                return false
            }
            if revision == persistenceRevision {
                persistenceTask = nil
                if publication == catalogueRevision { publishCommitted(committed) }
                else { await reloadLatestCatalogue() }
            }
            guard account == accountRevision else { return false }
            return true
        } catch {
            if revision == persistenceRevision {
                persistenceTask = nil
                // An earlier queued mutation may have committed while its publication
                // was superseded by this failed edit. Reload its durable approval state.
                if account == accountRevision { await reloadLatestCatalogue() }
            }
            guard account == accountRevision else { return false }
            activity.report(error)
            lastError = error.localizedDescription
            return false
        }
    }

    private func publishCommitted(_ committed: PersistedCatalogue) {
        catalogueRevision += 1
        syncState = committed.state
        durableLocalFlags = committed.flags
        localSynchronizationFlags = committed.flags
        certificates = committed.state.activeCertificates(preservingLocalStorageFrom: certificates)
        associations = committed.state.activeAssociations
        applyLocalStorageFlags()
        availability = availability.filter { id, _ in certificates.contains { $0.id == id } }
        identityCache = identityCache.filter { id, _ in certificates.contains { $0.id == id } }
        signingValidated = signingValidated.filter { id in certificates.contains { $0.id == id } }
    }

    public func flushPendingWrites() async {
        await drainMaterialOperations()
        await initializationTask?.value
        while let task = persistenceTask {
            let account = accountRevision
            let revision = persistenceRevision
            do {
                _ = try await task.value
                guard revision == persistenceRevision else { continue }
                persistenceRevision += 1 // supersede the pending completion's publication
                persistenceTask = nil
                guard account == accountRevision else { continue }
                await reloadLatestCatalogue()
            } catch {
                if revision == persistenceRevision { persistenceTask = nil }
                if account == accountRevision { activity.report(error) }
            }
        }
    }

    public func prepareForFirstAccountClaim() async throws {
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
            if account == accountRevision { activity.report(error) }
        }
    }
}
