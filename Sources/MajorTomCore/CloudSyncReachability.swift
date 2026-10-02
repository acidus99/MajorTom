import Foundation

/// Turns reachability observations into one retry request per offline-to-online edge.
///
/// This deliberately knows nothing about Network.framework or CloudKit. The app owns
/// path monitoring; Core owns the transition rule so a network flap cannot create a
/// retry loop and the initial monitor callback is never mistaken for a reconnection.
public struct CloudSyncReachability: Equatable, Sendable {
    private var lastObservedAvailability: Bool?

    public init() {}

    /// Returns true exactly when a prior unavailable observation becomes available.
    public mutating func observe(available: Bool) -> Bool {
        defer { lastObservedAvailability = available }
        return lastObservedAvailability == false && available
    }
}
