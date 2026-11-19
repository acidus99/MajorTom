import Foundation
import MajorTomCore

/// Live services for the confirmed operation; the settings view owns only its dialog.
@MainActor
enum UserDataDeletion {
    static let workflow = makeWorkflow()

    private static func makeWorkflow() -> UserDataDeletionWorkflow {
        UserDataDeletionWorkflow(services: UserDataDeletionServices(
        accountToken: { ClientCertificateStore.shared.accountToken },
        prepare: {
            guard !BrowsingDataController.shared.isClearing else {
                throw BrowsingDataWorkflowError.operationInProgress
            }
            await ServerTrustPresentation.shared.suspendAndDrain()
            await BrowsingDataController.shared.workflow.cancelAndDrainRequests()
            for browser in NativeTabCoordinator.shared.browsingDataModels {
                await browser.cancelAndDrainNativeRequests()
            }
        },
        finish: { ServerTrustPresentation.shared.resumeAuthorization() },
        deleteClientIdentities: { try await ClientCertificateStore.shared.deleteAll() },
        deleteBookmarks: { try await BookmarksModel.shared.deleteAll() },
        deleteCapsuleTrust: {
            guard let store = SharedTrustedIdentityStore.shared else {
                throw ServerTrustAuthorityError.storeUnavailable
            }
            try await store.removeAllUserTrust()
        },
        resetHomepage: {
            var preferences = BrowserSettingsStore.shared.preferences
            preferences.homepage = BrowserPreferences().homepage
            BrowserSettingsStore.shared.preferences = preferences
        }
        ))
    }

    static func message(for error: any Error) -> String {
        guard case UserDataDeletionError.failed(let stage, let completed, let underlying) = error else {
            return "Another user-data operation is already running."
        }
        if case UserDataDeletionError.accountChanged = underlying {
            return "The iCloud account changed. Deletion stopped; review the data in the current account before trying again."
        }
        let item: String
        switch stage {
        case .preparation: item = "preparing open requests"
        case .clientIdentities: item = "deleting client identities"
        case .bookmarks: item = "deleting bookmarks"
        case .capsuleTrust: item = "clearing capsule trust"
        case .homepage: item = "resetting the homepage"
        }
        return "Deletion stopped while \(item). \(completed.isEmpty ? "Try again." : "Earlier deletions have already completed. Review the remaining data before trying again.")"
    }
}
