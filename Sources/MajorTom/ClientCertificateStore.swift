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
    private var modifiedAt: Date = .distantPast
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
        let stored: SyncedClientCertificates?
        if let data = defaults.data(forKey: storageKey),
           let snapshot = try? JSONDecoder().decode(SyncedClientCertificates.self, from: data) {
            stored = snapshot
            certificates = snapshot.certificates
            associations = snapshot.associations
            modifiedAt = snapshot.modifiedAt
        } else {
            stored = nil
        }
        cloudObserver = ICloudSyncStore.shared.receivedClientCertificates.sink { [weak self] snapshot in
            self?.apply(snapshot)
        }
        ICloudSyncStore.shared.configure(clientCertificates: stored)
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

    func resolvedCertificate(for url: URL) -> ResolvedClientCertificate? {
        guard let association = ClientCertificateAssociation.mostSpecific(
            matching: url,
            in: associations
        ), let descriptor = descriptor(id: association.certificateID) else { return nil }
        let identity: ClientTLSIdentity?
        if descriptor.isValid() {
            do {
                if !signingValidated.contains(descriptor.id) {
                    try keychain.validateIdentityCanSign(for: descriptor.id)
                    signingValidated.insert(descriptor.id)
                }
                identity = cachedIdentity(for: descriptor.id)
            } catch {
                identity = nil
            }
        } else {
            identity = nil
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

    func refreshAvailability() {
        for certificate in certificates {
            availability[certificate.id] = cachedIdentity(for: certificate.id) != nil
        }
    }

    private func cachedIdentity(for certificateID: UUID) -> ClientTLSIdentity? {
        if let identity = identityCache[certificateID] { return identity }
        guard let identity = try? keychain.identity(for: certificateID) else { return nil }
        identityCache[certificateID] = identity
        return identity
    }

    private func changed() {
        guard !isApplyingRemote else { return }
        modifiedAt = Date()
        let snapshot = currentSnapshot
        persist(snapshot)
        scheduleUpload(snapshot)
    }

    private var currentSnapshot: SyncedClientCertificates {
        SyncedClientCertificates(
            certificates: certificates,
            associations: associations,
            modifiedAt: modifiedAt
        )
    }

    private func apply(_ snapshot: SyncedClientCertificates) {
        guard snapshot.shouldReplace(currentSnapshot) else { return }
        uploadTask?.cancel()
        isApplyingRemote = true
        certificates = snapshot.certificates
        identityCache = identityCache.filter { id, _ in
            snapshot.certificates.contains { $0.id == id }
        }
        signingValidated = signingValidated.filter { id in
            snapshot.certificates.contains { $0.id == id }
        }
        associations = snapshot.associations.filter { association in
            snapshot.certificates.contains { $0.id == association.certificateID }
        }
        modifiedAt = snapshot.modifiedAt
        isApplyingRemote = false
        persist(currentSnapshot)
        refreshAvailability()
    }

    private func persist(_ snapshot: SyncedClientCertificates) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func scheduleUpload(_ snapshot: SyncedClientCertificates) {
        uploadTask?.cancel()
        uploadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            ICloudSyncStore.shared.updateClientCertificates(snapshot)
        }
    }
}
