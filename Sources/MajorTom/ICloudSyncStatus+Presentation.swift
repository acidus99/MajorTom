import MajorTomCore

extension ICloudSyncStatus {
    var label: String {
        switch self {
        case .preparing: "Preparing iCloud…"
        case .syncing: "Syncing with iCloud…"
        case .upToDate: "Up to date"
        case .unavailable(let reason): reason
        case .removed: "iCloud data for Major Tom was removed"
        case .requiresNewerApp: "A newer version of Major Tom is required to sync"
        case .failed(let reason): "iCloud sync error: \(reason)"
        }
    }
}
