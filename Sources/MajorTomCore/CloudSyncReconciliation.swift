import Foundation

/// Transport-neutral decisions for reconciling a fetched server model with durable
/// local intent. CloudKit supplies records and change tags; this type deliberately
/// knows only canonical model bytes, so its conflict policy is unit-testable without
/// a CloudKit account or network.
public enum CloudFetchedModificationDisposition: Equatable, Sendable {
    /// The domain repository may apply the fetched model without creating an echo save.
    case applyRemote
    /// Preserve the immutable local save snapshot and retry it against the newly saved
    /// server metadata.
    case retainPendingSave(generation: Int64)
    /// A local delete remains authoritative until the server confirms deletion.
    case retainPendingDelete(generation: Int64)
}

public enum CloudSyncReconciliation {
    public static func fetchedModification(
        pending: CloudPendingChange?,
        serverModelPayload: Data
    ) -> CloudFetchedModificationDisposition {
        guard let pending else { return .applyRemote }
        switch pending.operation {
        case .delete:
            return .retainPendingDelete(generation: pending.generation)
        case .save:
            // Equality alone is not a barrier against an earlier generation already
            // in flight. Retain intent until its own save/conflict result proves it.
            return .retainPendingSave(generation: pending.generation)
        }
    }
}
