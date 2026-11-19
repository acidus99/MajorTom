import Foundation

/// Shutdown waits for operations already accepted locally, then rejects new work.
/// Remote delivery is deliberately outside this lifetime.
@MainActor
public final class AcceptedLocalWork {
    public private(set) var isClosing = false
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func perform<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        guard !isClosing else { throw CancellationError() }
        active += 1
        defer {
            active -= 1
            if active == 0 {
                let pending = waiters
                waiters.removeAll()
                for waiter in pending { waiter.resume() }
            }
        }
        return try await operation()
    }

    public func closeAndDrain() async {
        isClosing = true
        await drain()
    }

    public func drain() async {
        if active > 0 { await withCheckedContinuation { waiters.append($0) } }
    }
}
