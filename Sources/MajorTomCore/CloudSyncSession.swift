import Foundation

/// Session-local send ownership. An old transport may finish its captured account's
/// durable work, but cannot consume a new session's attempted generation.
public struct CloudSyncSession: Sendable {
    public private(set) var token = 0
    public private(set) var attempts: [String: CloudPendingChange] = [:]

    public init() {}

    public mutating func begin() {
        precondition(token < Int.max, "Sync session counter exhausted")
        token += 1
        attempts.removeAll()
    }

    public func accepts(_ token: Int) -> Bool { self.token == token }

    public static func requiresAccountActivation(reportedAccount: String, activeAccount: String?) -> Bool {
        // CKSyncEngine reports its initial sign-in after construction too. Replacing
        // an engine already bound to that account would create an endless startup loop.
        reportedAccount != activeAccount
    }

    @discardableResult
    public mutating func reserve(_ change: CloudPendingChange, token: Int) -> Bool {
        guard accepts(token), attempts[change.recordName] == nil else { return false }
        attempts[change.recordName] = change
        return true
    }

    public mutating func finish(_ recordName: String, token: Int) {
        guard accepts(token) else { return }
        attempts[recordName] = nil
    }

    public mutating func clearAttempts() { attempts.removeAll() }
}
