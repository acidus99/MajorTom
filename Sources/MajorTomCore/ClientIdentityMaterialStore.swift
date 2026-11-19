import Foundation

/// Security's external material boundary. Production uses Keychain; controlled
/// implementations exercise cancellation and metadata failures without real keys.
public protocol ClientIdentityMaterialStore: Sendable {
    func create(_ request: ClientCertificateCreationRequest, id: UUID, now: Date) throws -> ClientCertificateDescriptor
    func importIdentity(_ imported: ClientCertificateImport, id: UUID) throws -> ClientCertificateDescriptor
    func delete(_ descriptor: ClientCertificateDescriptor) throws
    func delete(id: UUID) throws
    func certificateDER(for descriptor: ClientCertificateDescriptor) throws -> Data
    func validateIdentityCanSign(for descriptor: ClientCertificateDescriptor) throws
    func identity(for descriptor: ClientCertificateDescriptor) throws -> ClientTLSIdentity
    func exportIdentityPEM(for descriptor: ClientCertificateDescriptor) throws -> String
}

extension ClientCertificateKeychain: ClientIdentityMaterialStore {}
