import Foundation

/// A versioned, conflict-resolvable preferences snapshot for private iCloud sync.
///
/// The timestamp belongs to the payload rather than CloudKit's record metadata so the
/// same merge rule can be exercised locally and in tests. A device that has never saved
/// preferences uses no snapshot at all; it therefore cannot replace an established
/// remote configuration with freshly-created defaults.
public struct SyncedBrowserPreferences: Codable, Equatable, Sendable {
    public var preferences: BrowserPreferences
    public var modifiedAt: Date

    public init(preferences: BrowserPreferences, modifiedAt: Date) {
        self.preferences = preferences
        self.modifiedAt = modifiedAt
    }

    public func shouldReplace(_ local: SyncedBrowserPreferences?) -> Bool {
        guard let local else { return true }
        return modifiedAt > local.modifiedAt
    }
}

/// The small, privacy-conscious representation published for Safari-like iCloud Tabs.
/// It intentionally excludes history, cached response bodies, scroll position and
/// back/forward state: opening a remote tab is a new navigation on this Mac.
public struct CloudTabSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL

    public init(id: UUID, title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// One device owns one CloudKit record and replaces only that record as its tabs change.
public struct CloudTabDeviceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var deviceID: UUID
    public var deviceName: String
    public var updatedAt: Date
    public var tabs: [CloudTabSnapshot]

    public var id: UUID { deviceID }

    public init(
        deviceID: UUID,
        deviceName: String,
        updatedAt: Date,
        tabs: [CloudTabSnapshot]
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.updatedAt = updatedAt
        self.tabs = tabs
    }

    /// Old records can survive an ungraceful shutdown. Keeping the age policy in the
    /// model makes the UI deterministic and prevents a long-dead Mac looking live.
    public func isRecent(at date: Date = Date(), maximumAge: TimeInterval = 7 * 24 * 60 * 60) -> Bool {
        updatedAt <= date && date.timeIntervalSince(updatedAt) <= maximumAge
    }
}

public extension Array where Element == CloudTabDeviceSnapshot {
    func visibleCloudTabDevices(
        excluding localDeviceID: UUID,
        at date: Date = Date(),
        maximumAge: TimeInterval = 7 * 24 * 60 * 60
    ) -> [CloudTabDeviceSnapshot] {
        filter {
            $0.deviceID != localDeviceID
                && !$0.tabs.isEmpty
                && $0.isRecent(at: date, maximumAge: maximumAge)
        }
        .sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending
        }
    }
}
