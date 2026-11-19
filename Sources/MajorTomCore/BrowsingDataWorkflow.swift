import Combine
import Foundation

public enum BrowsingDataClearingStage: Sendable {
    case reusableResponses, pendingWrites, liveSession, savedVisits, history, inputDrafts
}

public enum BrowsingDataWorkflowError: Error {
    case operationInProgress
    case storageUnavailable
    case failed(stage: BrowsingDataClearingStage, underlying: any Error)
}

@MainActor
public struct BrowsingDataServices {
    public var clearReusableResponses: (Date?) async throws -> Void
    public var persistLiveSession: () async throws -> Void
    public var clearSavedVisits: (BrowsingDataAction, Date?) async throws -> Void
    public var clearHistory: (Date?) async throws -> Void
    public var clearInputDrafts: (Date?) async throws -> Void
    public var now: () -> Date

    public init(
        clearReusableResponses: @escaping (Date?) async throws -> Void,
        persistLiveSession: @escaping () async throws -> Void,
        clearSavedVisits: @escaping (BrowsingDataAction, Date?) async throws -> Void,
        clearHistory: @escaping (Date?) async throws -> Void,
        clearInputDrafts: @escaping (Date?) async throws -> Void,
        now: @escaping () -> Date = { Date() }
    ) {
        self.clearReusableResponses = clearReusableResponses
        self.persistLiveSession = persistLiveSession
        self.clearSavedVisits = clearSavedVisits
        self.clearHistory = clearHistory
        self.clearInputDrafts = clearInputDrafts
        self.now = now
    }
}

/// Coordinates one confirmed clear. Sessions created while it is suspended inherit
/// the same boundary before they can restore or persist pre-clear response bytes.
@MainActor
public final class BrowsingDataWorkflow: ObservableObject {
    @Published public private(set) var isClearing = false
    private struct SessionReference { weak var session: BrowserSession? }
    private let services: BrowsingDataServices
    private var sessions: [ObjectIdentifier: SessionReference] = [:]
    private var clearing: (action: BrowsingDataAction, cutoff: Date?)?

    public init(services: BrowsingDataServices) { self.services = services }

    public func register(_ session: BrowserSession) {
        sessions = sessions.filter { $0.value.session != nil }
        let id = ObjectIdentifier(session)
        guard sessions[id]?.session == nil else { return }
        sessions[id] = SessionReference(session: session)
        if let clearing { session.prepareForClearing(clearing.action, since: clearing.cutoff) }
    }

    public func clear(_ action: BrowsingDataAction, range: BrowsingDataTimeRange) async throws {
        guard !isClearing else { throw BrowsingDataWorkflowError.operationInProgress }
        let cutoff = range.cutoff(at: services.now())
        clearing = (action, cutoff)
        isClearing = true
        for session in liveSessions { session.prepareForClearing(action, since: cutoff) }
        defer {
            for session in liveSessions { session.finishClearing() }
            clearing = nil
            isClearing = false
        }
        var stage = BrowsingDataClearingStage.reusableResponses
        do {
            // Advance the reusable-cache generation before any await on tab writes.
            try await services.clearReusableResponses(cutoff)
            stage = .pendingWrites
            var drained = Set<ObjectIdentifier>()
            while true {
                let pending = liveSessions.filter { !drained.contains(ObjectIdentifier($0)) }
                guard !pending.isEmpty else { break }
                for session in pending {
                    await session.drainWritesForClearing()
                    drained.insert(ObjectIdentifier(session))
                }
            }
            stage = .liveSession
            try await services.persistLiveSession()
            stage = .savedVisits
            try await services.clearSavedVisits(action, cutoff)
            if action == .clearBrowsingData {
                stage = .history
                try await services.clearHistory(cutoff)
                stage = .inputDrafts
                try await services.clearInputDrafts(cutoff)
            }
        } catch {
            throw BrowsingDataWorkflowError.failed(stage: stage, underlying: error)
        }
    }

    private var liveSessions: [BrowserSession] {
        sessions = sessions.filter { $0.value.session != nil }
        return sessions.values.compactMap(\.session)
    }
}
