import Foundation

/// Transport-independent bookkeeping for one requested CloudKit round trip.
///
/// The coordinator owns the user-visible status, but it must obtain the completion
/// proof from one place: a cycle has fetched, its requested send has returned without a
/// failure, and a fresh durable outbox read is empty. This intentionally contains no
/// CloudKit types so its edge cases are testable in Core.
public struct CloudSyncCycle: Equatable, Sendable {
    public private(set) var id: UUID?
    public private(set) var fetched = false
    public private(set) var sendFinished = false
    public private(set) var failed = false
    public private(set) var requiresFreshFetch = false

    public init() {}

    public var isActive: Bool { id != nil }

    public mutating func begin(requiresFreshFetch: Bool = false) {
        id = UUID()
        self.requiresFreshFetch = requiresFreshFetch
        fetched = false
        sendFinished = false
        failed = false
    }

    public mutating func markFetched(freshServerCheck: Bool = true) {
        guard isActive, !requiresFreshFetch || freshServerCheck else { return }
        fetched = true
    }

    public mutating func markSendFinished() {
        guard isActive else { return }
        sendFinished = true
    }

    public mutating func invalidateSendProof() {
        sendFinished = false
    }

    public mutating func markFailed() {
        guard isActive else { return }
        failed = true
    }

    /// Returns true exactly once when the durable completion proof is satisfied.
    @discardableResult
    public mutating func completeIfDrained(
        outboxIsEmpty: Bool,
        accountAvailable: Bool = true,
        zoneActive: Bool = true,
        hasUnappliedIncoming: Bool = false,
        engineStatePersistenceFailed: Bool = false,
        hasInFlightAttempts: Bool = false,
        hasPendingLocalWrites: Bool = false
    ) -> Bool {
        guard isActive, fetched, sendFinished, !failed, outboxIsEmpty,
              accountAvailable, zoneActive, !hasUnappliedIncoming,
              !engineStatePersistenceFailed, !hasInFlightAttempts,
              !hasPendingLocalWrites else { return false }
        id = nil
        return true
    }
}
