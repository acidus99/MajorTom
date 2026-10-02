import Foundation

/// Drains delegate work already accepted by a retiring transport before its successor
/// reads a checkpoint or applies records. The coordinator must reject new callbacks
/// from that transport before waiting here; cancellation alone is not a drain guarantee.
@MainActor
public final class CloudSyncCallbackBarrier {
    public private(set) var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func enter() { count += 1 }

    public func leave() {
        precondition(count > 0)
        count -= 1
        guard count == 0 else { return }
        let completed = waiters
        waiters.removeAll()
        for waiter in completed { waiter.resume() }
    }

    public func waitUntilIdle() async {
        guard count > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
