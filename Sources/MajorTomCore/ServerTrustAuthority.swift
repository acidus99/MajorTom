import Foundation

public struct ServerTrustDecision: Identifiable, Sendable {
    public let id: UUID
    public let challenge: ServerTrustChallenge
}

public enum ServerTrustAuthorityError: Error, Sendable {
    case storeUnavailable
}

/// One application-wide authority. Requests for an endpoint are evaluated serially
/// so concurrent first visits cannot silently replace each other's pins. Equal
/// identities share work; cancellation removes only that requester's interest.
@MainActor
public final class ServerTrustAuthority {
    public typealias Read = @Sendable (CapsuleEndpoint) async throws -> TrustedServerIdentity?
    public typealias Save = @Sendable (PresentedServerIdentity, TrustedServerIdentity.Source) async throws -> Void

    private final class Request {
        let id = UUID()
        let identity: PresentedServerIdentity
        var waiters: [UUID: CheckedContinuation<Bool, any Error>] = [:]
        init(_ identity: PresentedServerIdentity) { self.identity = identity }
    }
    private struct PendingDecision {
        let decision: ServerTrustDecision
        let continuation: CheckedContinuation<Bool, Never>
    }
    private struct DateException: Hashable {
        let endpoint: CapsuleEndpoint
        let key: String
        let notBefore: Date?
        let notAfter: Date?
        init(_ identity: PresentedServerIdentity) {
            endpoint = identity.endpoint
            key = identity.publicKeySHA256
            notBefore = identity.certificateNotBefore
            notAfter = identity.certificateNotAfter
        }
    }

    public var decisionChanged: ((ServerTrustDecision?) -> Void)?
    public var pendingDecision: ServerTrustDecision? { decisions.first?.decision }
    private let read: Read
    private let save: Save
    private let now: @Sendable () -> Date
    private var requests: [Request] = []
    private var workers: [CapsuleEndpoint: Task<Void, Never>] = [:]
    private var decisions: [PendingDecision] = []
    private var dateExceptions = Set<DateException>()
    private var isSuspended = false
    private var authorizationGeneration: UInt64 = 0

    public init(read: @escaping Read, save: @escaping Save, now: @escaping @Sendable () -> Date = { Date() }) {
        self.read = read
        self.save = save
        self.now = now
    }

    public func authorize(_ identity: PresentedServerIdentity) async throws -> Bool {
        guard !isSuspended else { throw CancellationError() }
        let generation = authorizationGeneration
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !isSuspended, generation == authorizationGeneration else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let request = requests.first { $0.identity == identity } ?? Request(identity)
                if !requests.contains(where: { $0.id == request.id }) { requests.append(request) }
                request.waiters[waiterID] = continuation
                startWorker(for: identity.endpoint)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(waiterID) }
        }
    }

    public func respond(to id: UUID, allow: Bool) {
        guard decisions.first?.decision.id == id else { return }
        let pending = decisions.removeFirst()
        decisionChanged?(pendingDecision)
        pending.continuation.resume(returning: allow)
    }

    /// Destructive trust changes wait for accepted writes, including stores that
    /// cannot cancel a transaction already running. No old write can follow deletion.
    public func suspendAndDrain() async {
        isSuspended = true
        authorizationGeneration &+= 1
        let active = Array(workers.values)
        let waiterIDs = requests.flatMap { $0.waiters.keys }
        for waiterID in waiterIDs { cancel(waiterID) }
        for worker in active { worker.cancel() }
        for worker in active { await worker.value }
        dateExceptions.removeAll()
    }

    public func resumeAuthorization() { isSuspended = false }

    private func startWorker(for endpoint: CapsuleEndpoint) {
        guard workers[endpoint] == nil else { return }
        workers[endpoint] = Task {
            while let request = requests.first(where: { $0.identity.endpoint == endpoint }) {
                do {
                    let approved = try await evaluate(request)
                    finish(request, result: .success(approved))
                } catch {
                    finish(request, result: .failure(error))
                }
                if Task.isCancelled { break }
            }
            workers[endpoint] = nil
            if requests.contains(where: { $0.identity.endpoint == endpoint }) { startWorker(for: endpoint) }
        }
    }

    private func evaluate(_ request: Request) async throws -> Bool {
        let identity = request.identity
        let trusted = try await read(identity.endpoint)
        try Task.checkCancellation()
        let evaluation = ServerTrustPolicy().evaluate(presented: identity, locallyTrusted: trusted, seeds: [], now: now())
        let source: TrustedServerIdentity.Source
        var dateException: DateException?
        switch evaluation {
        case .allowSilently(let existingSource):
            source = existingSource
        case .requiresApproval(.firstUse):
            source = .user
        case .requiresApproval(let challenge):
            if case .invalidCertificateDates = challenge {
                let key = DateException(identity)
                if trusted != nil, dateExceptions.contains(key) { return true }
                dateException = key
            }
            let approved = await withCheckedContinuation { continuation in
                decisions.append(PendingDecision(
                    decision: ServerTrustDecision(id: request.id, challenge: challenge),
                    continuation: continuation
                ))
                decisionChanged?(pendingDecision)
            }
            try Task.checkCancellation()
            guard approved, !request.waiters.isEmpty else { return false }
            source = .user
        }
        try Task.checkCancellation()
        try await save(identity, source)
        try Task.checkCancellation()
        if let dateException { dateExceptions.insert(dateException) }
        return true
    }

    private func cancel(_ waiterID: UUID) {
        guard let request = requests.first(where: { $0.waiters[waiterID] != nil }),
              let waiter = request.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        guard request.waiters.isEmpty else { return }
        let wasActive = requests.first(where: { $0.identity.endpoint == request.identity.endpoint })?.id == request.id
        requests.removeAll { $0.id == request.id }
        if let index = decisions.firstIndex(where: { $0.decision.id == request.id }) {
            let pending = decisions.remove(at: index)
            pending.continuation.resume(returning: false)
            decisionChanged?(pendingDecision)
        }
        if wasActive { workers[request.identity.endpoint]?.cancel() }
    }

    private func finish(_ request: Request, result: Result<Bool, any Error>) {
        requests.removeAll { $0.id == request.id }
        let waiters = request.waiters.values
        request.waiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }
}
