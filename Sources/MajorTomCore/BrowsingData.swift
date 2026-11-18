import Foundation

public enum BrowsingDataAction: String, CaseIterable, Identifiable, Sendable {
    case clearBrowsingData
    case emptyCaches

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .clearBrowsingData: "Clear Browsing Data"
        case .emptyCaches: "Empty Caches"
        }
    }
}

public enum BrowsingDataTimeRange: String, CaseIterable, Identifiable, Sendable {
    case last24Hours
    case everything

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .last24Hours: "Last 24 Hours"
        case .everything: "Everything"
        }
    }

    public func cutoff(at date: Date) -> Date? {
        self == .last24Hours ? date.addingTimeInterval(-24 * 60 * 60) : nil
    }
}

/// Unknown dates from older sessions are cleared conservatively, rather than
/// allowing undated browsing traces to survive a time-limited privacy operation.
public enum BrowsingDataSelection {
    public static func includes(_ date: Date?, since cutoff: Date?) -> Bool {
        guard let cutoff, let date else { return true }
        return date >= cutoff
    }
}
