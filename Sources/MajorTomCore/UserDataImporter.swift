import Combine
import Foundation

public enum ParsedUserDataExport: Sendable {
    case lagrange(LagrangeUserDataExport)
    case alhena(AlhenaUserDataExport)
    public var version: String {
        switch self { case .lagrange(let value): value.version; case .alhena(let value): value.version }
    }
}

@MainActor
public struct UserDataImportServices {
    public var accountToken: @MainActor () -> UInt64
    public var canImport: @MainActor () -> Bool
    public var certificates: @MainActor () -> [ClientCertificateDescriptor]
    public var associations: @MainActor () -> [ClientCertificateAssociation]
    public var importIdentity: @MainActor (ClientCertificateImport) async throws -> ClientCertificateDescriptor
    public var associate: @MainActor (UUID, URL) async -> Bool
    public var importTrust: @MainActor ([PresentedServerIdentity]) async throws -> Int
    public var importBookmarks: @MainActor (ParsedUserDataExport) async throws -> Int
    public var preferences: @MainActor () -> BrowserPreferences
    public var savePreferences: @MainActor (BrowserPreferences) -> Void

    public init(accountToken: @escaping @MainActor () -> UInt64, canImport: @escaping @MainActor () -> Bool,
        certificates: @escaping @MainActor () -> [ClientCertificateDescriptor],
        associations: @escaping @MainActor () -> [ClientCertificateAssociation],
        importIdentity: @escaping @MainActor (ClientCertificateImport) async throws -> ClientCertificateDescriptor,
        associate: @escaping @MainActor (UUID, URL) async -> Bool,
        importTrust: @escaping @MainActor ([PresentedServerIdentity]) async throws -> Int,
        importBookmarks: @escaping @MainActor (ParsedUserDataExport) async throws -> Int,
        preferences: @escaping @MainActor () -> BrowserPreferences,
        savePreferences: @escaping @MainActor (BrowserPreferences) -> Void) {
        self.accountToken = accountToken; self.canImport = canImport
        self.certificates = certificates; self.associations = associations
        self.importIdentity = importIdentity; self.associate = associate
        self.importTrust = importTrust; self.importBookmarks = importBookmarks
        self.preferences = preferences; self.savePreferences = savePreferences
    }
}

public enum UserDataImportError: Error { case operationInProgress, accountChanged, assignmentFailed }

/// Applies validated archives through domain services. No native panels or global stores.
@MainActor
public final class UserDataImporter: ObservableObject {
    @Published public private(set) var isImporting = false
    @Published public private(set) var resultItems: [String]?
    @Published public private(set) var importProgress: (completed: Int, total: Int, message: String)?
    private let lifetime: AcceptedLocalWork
    private let services: UserDataImportServices
    private var account: UInt64?
    public init(services: UserDataImportServices, lifetime: AcceptedLocalWork? = nil) {
        self.services = services
        self.lifetime = lifetime ?? AcceptedLocalWork()
    }

    public func importExport(_ export: ParsedUserDataExport) async throws {
        try await lifetime.perform {
            guard !isImporting, services.canImport() else { throw UserDataImportError.operationInProgress }
            isImporting = true
            account = services.accountToken()
            resultItems = nil
            defer { isImporting = false; account = nil; importProgress = nil }
            try await apply(export)
        }
    }

    private func requireCurrentAccount() throws {
        guard services.canImport(), account == services.accountToken() else { throw UserDataImportError.accountChanged }
    }

    private func apply(_ export: ParsedUserDataExport) async throws {
        // Both formats describe the same operations; only their record shapes differ.
        let identities: [(reference: String, certificate: String, key: String)]
        let assignments: [(reference: String, url: URL)]
        let trust: [PresentedServerIdentity]
        switch export {
        case .lagrange(let value):
            identities = value.identities.map { ($0.digest, $0.certificatePEM, $0.privateKeyPEM) }
            assignments = value.identityAssignments.map { ($0.identityDigest, $0.url) }
            trust = value.trustedIdentities.map {
                PresentedServerIdentity(endpoint: $0.endpoint, publicKeySHA256: $0.publicKeySHA256)
            }
        case .alhena(let value):
            identities = value.identities.map { ($0.identifier, $0.certificatePEM, $0.privateKeyPEM) }
            assignments = value.identities.compactMap {
                guard $0.isActive, let url = $0.url else { return nil }
                return ($0.identifier, url)
            }
            trust = []
        }
        let total = identities.count + assignments.count + 2
        var completed = 0
        var certificatesByReference: [String: UUID] = [:]
        var importedCertificates = 0
        var importedAssignments = 0
        for (index, identity) in identities.enumerated() {
            try requireCurrentAccount()
            importProgress = (completed, total, "Importing client certificate \(index + 1) of \(identities.count)…")
            defer { completed += 1 }
            // Malformed/unsupported exported material does not discard other records.
            // A failure to save valid material, however, must not report success.
            guard let parsed = try? await Task.detached(priority: .userInitiated, operation: {
                try ClientCertificateImport.parse(pem: identity.certificate + "\n" + identity.key)
            }).value else { continue }
            try requireCurrentAccount()
            let digest = CertificateDetails.sha256(certificateDER: parsed.certificateDER)
            let existed = services.certificates().contains { $0.certificateSHA256 == digest }
            let descriptor = try await services.importIdentity(parsed)
            try requireCurrentAccount()
            certificatesByReference[identity.reference] = descriptor.id
            certificatesByReference[digest] = descriptor.id
            if !existed { importedCertificates += 1 }
        }
        for (index, assignment) in assignments.enumerated() {
            try requireCurrentAccount()
            importProgress = (completed, total, "Importing identity assignment \(index + 1) of \(assignments.count)…")
            defer { completed += 1 }
            guard let id = certificatesByReference[assignment.reference],
                  let proposed = ClientCertificateAssociation.pathAndDescendants(certificateID: id, url: assignment.url),
                  !services.associations().contains(where: {
                      $0.endpoint == proposed.endpoint && $0.scope == proposed.scope && $0.pathPrefix == proposed.pathPrefix
                  }) else { continue }
            guard await services.associate(id, assignment.url) else { throw UserDataImportError.assignmentFailed }
            try requireCurrentAccount()
            importedAssignments += 1
        }
        importProgress = (completed, total, "Saving trusted capsule identities…")
        try requireCurrentAccount()
        let importedTrust = trust.isEmpty ? 0 : try await services.importTrust(trust)
        try requireCurrentAccount()
        completed += 1
        importProgress = (completed, total, "Importing bookmarks and settings…")
        let bookmarks = try await services.importBookmarks(export)
        try requireCurrentAccount()
        var items: [String] = []
        for (count, singular, plural) in [
            (bookmarks, "Bookmark", "Bookmarks"),
            (importedCertificates, "Client-side Certificate", "Client-side Certificates"),
            (importedAssignments, "Identity Assignment", "Identity Assignments"),
            (importedTrust, "Trusted Capsule Identity", "Trusted Capsule Identities")
        ] where count > 0 { items.append("\(count) \(count == 1 ? singular : plural)") }
        items += applyPreferences(from: export)
        resultItems = items
    }

    private func applyPreferences(from export: ParsedUserDataExport) -> [String] {
        var preferences = services.preferences()
        var items: [String] = []
        switch export {
        case .lagrange(let value):
            if let homepage = value.bookmarks.first(where: \.isHomepage) {
                preferences.homepage = homepage.url.absoluteString
                items.append("Homepage")
            }
        case .alhena(let value):
            if let homepage = value.preferences["home"], URL(string: homepage) != nil {
                preferences.homepage = homepage
                items.append("Homepage")
            }
            if let search = value.preferences["searchurl"], URL(string: search) != nil {
                preferences.searchProvider = .custom
                preferences.customSearchEndpoint = search
                items.append("Search Engine")
            }
            if let rawProxy = value.preferences["httpproxy"],
               let components = URLComponents(string: "gemini://\(rawProxy)"),
               let host = components.host, !host.isEmpty,
               let port = components.port.flatMap(UInt16.init(exactly:)) {
                preferences.proxy = GeminiProxyConfiguration(host: host, port: port)
                items.append("HTTP Proxy")
            }
            if let theme = value.preferences["theme"]?.lowercased() {
                if theme.contains("dark") { preferences.applicationAppearance = .dark; items.append("UI Theme") }
                else if theme.contains("light") { preferences.applicationAppearance = .light; items.append("UI Theme") }
            }
        }
        if !items.isEmpty { services.savePreferences(preferences) }
        return items
    }
}
