import Combine
import Foundation

/// Local commits and account claiming share this boundary. Sync observes activity;
/// feature models never call a remote transport to make a local write durable.
@MainActor
public final class LocalPersistenceActivity {
    @Published public private(set) var activeWrites = 0
    @Published public private(set) var failure: (any Error)?
    public var isPreparingAccount = false

    public init() {}
    public func begin() { activeWrites += 1 }
    public func end() { precondition(activeWrites > 0); activeWrites -= 1 }
    public func report(_ error: any Error) { failure = error }
}
