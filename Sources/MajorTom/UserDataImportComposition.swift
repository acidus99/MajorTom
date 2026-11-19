import Foundation
import MajorTomCore

@MainActor
enum UserDataImportComposition {
    static let importer = makeImporter()

    private static func makeImporter() -> UserDataImporter {
        UserDataImporter(services: UserDataImportServices(
            accountToken: { ClientCertificateStore.shared.accountToken },
            canImport: { !UserDataDeletion.workflow.isDeleting },
            certificates: { ClientCertificateStore.shared.certificates },
            associations: { ClientCertificateStore.shared.associations },
            importIdentity: { try await ClientCertificateStore.shared.importIdentity($0) },
            associate: { await ClientCertificateStore.shared.associate(certificateID: $0, with: $1, scope: .pathAndDescendants) },
            importTrust: {
                guard let store = SharedTrustedIdentityStore.shared else { throw ServerTrustAuthorityError.storeUnavailable }
                return try await store.importTrustedIdentities($0)
            },
            importBookmarks: {
                switch $0 {
                case .lagrange(let value): try await BookmarksModel.shared.importLagrangeBookmarks(value.bookmarks)
                case .alhena(let value): try await BookmarksModel.shared.importAlhenaBookmarks(value.bookmarks)
                }
            },
            preferences: { BrowserSettingsStore.shared.preferences },
            savePreferences: { BrowserSettingsStore.shared.preferences = $0 }
        ), lifetime: ApplicationWork.lifetime)
    }
}
