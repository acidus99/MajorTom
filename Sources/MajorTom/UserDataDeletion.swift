import MajorTomCore

@MainActor
enum UserDataDeletion {
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
