# Cloud Sync Refactor

Status: Approved implementation design
Baseline commit: `380df18`

This document specifies every code-level change required to replace Major Tom's
snapshot-polling CloudKit adapter with `CKSyncEngine`, retire the v1 compatibility zone,
and stop synchronizing server-trust decisions.

It is written to be implemented directly. Where a decision has already been made it is
stated as a requirement, not an option. Where something must be verified against the
running system it is called out explicitly.

The disposable page cache is a separate change; see
[`browser-cache-refactor.md`](browser-cache-refactor.md).

---

## 1. Decisions this implements

These were settled during design review. Do not re-open them while implementing.

1. **Server trust does not synchronize.** `MTServerTrust` is removed from the schema, its
   existing records are physically deleted from both zones, and `server_trust_sync` is
   dropped. TOFU is per device.
2. **No bidirectional v1 compatibility.** A one-shot v1 → v2 migration runs once per iCloud
   account, then the v1 zone is never read or written again by current builds. The v1 zone
   itself is never deleted.
3. **Preferences move to `NSUbiquitousKeyValueStore`.** `MTPreferences` leaves the CloudKit
   schema.
4. **Physical deletion replaces tombstones**, using CloudKit's incremental deletion
   tracking.
5. **Delete wins over concurrent edit**, except that a *remote* folder deletion never
   cascades — orphaned bookmarks are re-parented.
6. **Bookmark and folder ordering uses fractional index keys**, not integer positions.
7. **The CloudKit schema is frozen at one encrypted field, `payload`, per record type.**
8. **Record names are opaque random UUIDs.** Nothing is derived from user content.
9. **Payloads preserve unknown fields** across decode/mutate/encode.
10. **Cloud tabs are a deduplicated, unordered set keyed by normalized URL**, published on a
    lazy schedule and fetched on demand.
11. **Referential ordering:** a child arriving before its parent is attached to a default
    parent and re-attached when the real parent arrives.
12. **One sync control.** "Sync Now" performs a full bidirectional sync; the same action
    backs the Cloud Tabs view's refresh control.

### 1.1 Review amendments

The following requirements supersede any older wording later in this document:

1. Existing records and the existing manifest in `MajorTomUserDataV2` are disposable. The
   cutover replaces them; it does not attempt to translate their record names or payloads.
2. The original `MajorTomUserData` zone is read once per account. A ready manifest is the
   account-wide cutoff: later writes by a v1 build are ignored forever and cannot affect v2.
3. Synchronized local data is account-scoped. Signing out keeps the last account's data and
   pending edits. Switching accounts changes the active dataset without deleting, merging, or
   cross-uploading another account's data.
4. Strict delete-wins requires persisted `CKRecord` system fields. The implementation stores
   those fields and the last server payload for conflict retries, deletion detection, and
   unknown-field preservation.
5. The SQLite outbox is generation-aware and uses
   `CKSyncEngine.State.hasPendingUntrackedChanges`. A send may acknowledge only the exact
   generation it attempted.
6. Bookmark favicon observations continue to synchronize. The newer `fetchedAt` observation
   wins independently of the rest of a bookmark payload.
7. Cloud Tabs accept every committed URL except `about:` and `data:` URLs. Their payload has
   an optional emoji favicon and is forward-compatible with future presentation fields.
8. Sync is automatic. When it is unavailable, Settings explains that data remains saved on
   this Mac but is not syncing.
9. Legacy SQLite tables are not dropped merely because a later release is installed. Runtime
   cleanup must first prove that no account migration or recovery path needs them.

---

## 2. Target state

### 2.1 What synchronizes

| Data | Transport | Record type | Sent | Fetched |
| --- | --- | --- | --- | --- |
| Bookmarks | CloudKit | `MTBookmark` | On edit, via outbox, immediately | Push; also on activate and Sync Now |
| Bookmark folders | CloudKit | `MTBookmarkFolder` | On edit, via outbox, immediately | Same |
| Certificate descriptors | CloudKit | `MTClientCertificateDescriptor` | On edit, via outbox, immediately | Same |
| Certificate scopes | CloudKit | `MTClientCertificateAssociation` | On edit, via outbox, immediately | Same |
| Cloud tabs | CloudKit | `MTDeviceTabs` | Lazy; see §9 | Push, plus on Cloud Tabs view appear |
| Data model manifest | CloudKit | `MTDataModelManifest` | Once at zone init | Push |
| Reading/Gemtext preferences | `NSUbiquitousKeyValueStore` | — | On change | System notification |
| Certificate private keys | iCloud Keychain | — | Never by us | Never by us |

### 2.2 What does not synchronize

Browsing history, window/tab session and Back/Forward lists, input drafts, trusted server
identities, page cache and its index, application appearance, Gemini proxy configuration,
Favorites-bar visibility.

### 2.3 Zone

`MajorTomUserDataV2` in the user's private database. Permanent. There will be no v3 zone;
breaking changes create a new *record type* in this zone (§4.5).

---

## 3. New Core types

All of these belong in `Sources/MajorTomCore`. None may import CloudKit, SwiftUI, or AppKit —
Core stays framework-free, and the CloudKit adapter in `Sources/MajorTom` converts between
these types and `CKRecord`.

### 3.1 `JSONValue.swift` — new file

A minimal JSON tree used to preserve unknown fields.

```swift
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}
```

Implement `init(from:)` and `encode(to:)` by trying each case in the order: `null`, `bool`,
`number`, `string`, `array`, `object`. Throw `DecodingError.dataCorrupted` if none match.

**Required tests** (`JSONValueTests.swift`):
- Round-trips every case.
- Round-trips a nested object containing all cases.
- Encoding with `.sortedKeys` produces byte-identical output for two equal values built in
  different key orders.

### 3.2 `CloudPayload.swift` — new file

The envelope that makes forward compatibility possible. **This is the single most important
new type in the refactor.** Without it, an older build silently destroys fields written by a
newer build.

```swift
/// A model that can be carried inside a CloudKit record payload.
public protocol CloudSyncPayload: Codable, Sendable {
    /// Incremented only when this type's payload shape changes incompatibly.
    static var payloadSchemaVersion: Int { get }
}

/// A decoded payload plus every key the current build did not recognise.
public struct CloudRecordPayload<Model: CloudSyncPayload>: Sendable {
    public var model: Model
    public private(set) var unknownFields: [String: JSONValue]
    public private(set) var storedSchemaVersion: Int

    public init(model: Model)
    public init(decoding data: Data) throws
    public func encoded() throws -> Data
}
```

Implementation requirements:

**`init(decoding:)`**
1. Decode `data` into `[String: JSONValue]`.
2. Read `t` (Int) as `storedSchemaVersion`; if absent, treat as `1`.
3. Decode `Model` from the same `data`.
4. Compute `unknownFields`: re-encode the freshly decoded `Model`, collect its top-level
   keys, and retain every key of the original object that is neither one of those nor `"t"`.

**`encoded()`**
1. Encode `model` to `[String: JSONValue]`.
2. Merge in `unknownFields` for keys the model did not produce. **Model keys always win** —
   an unknown field never overwrites a field this build understands.
3. Set `t` to `Model.payloadSchemaVersion`.
4. Serialize with a `JSONEncoder` whose `outputFormatting` includes `.sortedKeys`.

Byte-stability matters: the "does this differ from the server copy?" comparison depends on
it.

**Required tests** (`CloudPayloadTests.swift`) — the second one is the reason this type
exists:
- Round-trips a model with no unknown fields, byte-identically.
- **Injects an unknown key into encoded JSON, decodes with the current model, mutates a
  known field, re-encodes, and asserts the unknown key survived with its original value.**
- Asserts a model field with the same name as an unknown field wins.
- Asserts a missing `t` decodes as version 1.

### 3.3 `OrderKey.swift` — new file

Fractional index keys. Replaces integer `position` for bookmarks and folders so that moving
one item changes one record.

```swift
public enum OrderKey {
    /// A key that sorts strictly between `lower` and `upper`.
    /// `nil` means "no bound on that side".
    public static func between(_ lower: String?, _ upper: String?, deviceSalt: String) -> String

    /// `count` evenly spaced keys, for seeding an existing ordered collection.
    public static func initial(count: Int) -> [String]
}
```

Use a canonical fractional-index encoding over an ordered base-62 alphabet. Only keys emitted
by `OrderKey` are valid bounds; canonical keys exclude prefix-adjacent forms for which no
finite string can exist between two values. Entropy derived from `deviceSalt` is selected as
part of a valid fractional digit, never appended after the bounded key. Invalid bounds throw.

If an insertion would exceed 64 characters, rebalance that one sibling collection with
`initial(count:)` in the same transaction, enqueueing the affected records. This is an
explicit exceptional maintenance path, not the normal move implementation.

**Sorting is always `ORDER BY order_key, id`.** The `id` tiebreak makes the order total even
if two devices produce an identical key.

**Required tests** (`OrderKeyTests.swift`):
- `between(nil, nil, …)` is non-empty and contains only `a`–`z`.
- For a large table of pairs, `lower < result < upper` under plain string comparison.
- 1,000 successive inserts at the *same* position all sort correctly and no key exceeds 64
  characters.
- 1,000 successive inserts at the *front* and at the *back* likewise.
- `initial(count:)` returns strictly ascending keys.
- Invalid and prefix-adjacent noncanonical bounds are rejected.
- Rebalancing preserves visible order and returns keys no longer than 64 characters.

### 3.4 `CloudPendingChange.swift` — new file

```swift
public struct CloudPendingChange: Equatable, Sendable {
    public enum Operation: String, Sendable { case save, delete }
    public let recordType: String
    public let recordName: String      // the record's UUID string
    public let operation: Operation
}
```

### 3.5 `CloudSyncState.swift` — new file

```swift
public struct CloudSyncState: Equatable, Sendable {
    public var engineState: Data?      // CKSyncEngine.State.Serialization, opaque
    public var modelMajor: Int
    public var accountIdentityHash: String?
    public var migratedFromV1: Bool
    public var updatedAt: Date
}
```

---

## 4. CloudKit record model

### 4.1 The frozen shape

Every record of every type has:

```
recordType : one of the six type names
recordName : a lowercase UUID string, nothing else
fields     : exactly one — encryptedValues["payload"], type Data
```

**This never changes.** Because the CloudKit schema is one field per type, no dashboard edit,
index change, or production schema deploy is ever required again.

### 4.2 Record names

Replace the current `recordID(prefix:stableID:)` (`ICloudSyncStore.swift:704-711`), which
takes any `String` and SHA-256s it. Change the signature so a non-UUID cannot be passed:

```swift
private func recordID(_ id: UUID, zoneID: CKRecordZone.ID? = nil) -> CKRecord.ID {
    CKRecord.ID(recordName: id.uuidString.lowercased(), zoneID: zoneID ?? self.zoneID)
}
```

Drop the SHA-256 and the type prefix. `CKRecord.ID` is unique within the zone regardless of
record type, so UUIDs are generated from one global random namespace.

`recordName` is CloudKit system metadata and is **not** covered by field encryption. That is
why it must carry no user content. The current `MTServerTrust` names are
`sha256("host:port|fingerprint")` over a fully public preimage; those records are deleted
outright in §11.

The two fixed names stay: `"data-model-manifest"` and the per-device tabs record, which
becomes plain `localDeviceID.uuidString.lowercased()`.

### 4.3 Payload conformance

Make each synchronized model conform to `CloudSyncPayload` in
`Sources/MajorTomCore/CloudSyncModels.swift`:

| Model | `payloadSchemaVersion` |
| --- | --- |
| `SyncedBookmark` | 1 |
| `SyncedBookmarkFolder` | 1 |
| `SyncedClientCertificateDescriptor` | 1 |
| `SyncedClientCertificateAssociation` | 1 |
| `CloudTabDeviceSnapshot` | 1 |
| `MTDataModelManifest` payload | 1 |

The target payloads do not emit `deletedAt`. Their decoders continue accepting the old field
during migration. Deletion is now physical; a tombstone field is
dead weight and, worse, an invitation to reintroduce tombstone semantics.

### 4.4 Payload field changes

**`SyncedBookmark`**
- Remove `position: Int`. Add `orderKey: String`.
- Keep the favicon snapshot and synchronize changed observations. Resolve it by `fetchedAt`.
- Add `certificateFingerprint`-style stability only where already present; no new fields.

**`SyncedBookmarkFolder`**
- Remove `position: Int`. Add `orderKey: String`.

**`SyncedClientCertificateDescriptor`**
- Ensure `certificateSHA256` is present in the payload (it already exists on the model at
  `ClientCertificate.swift:443-444`). It becomes a secondary join key for late-arriving
  Keychain identities (§10.3).

**`CloudTabDeviceSnapshot`**
- `tabs` becomes a deduplicated, unordered set keyed by normalized URL. See §9.1.

### 4.5 Evolving the model later

Written here so the rule survives the implementer:

1. Never remove a payload field; deprecate and keep emitting it.
2. Never repurpose a field name or change its type.
3. New fields are optional with a defined default for absence.
4. Unknown fields are always preserved (§3.2).
5. A genuinely incompatible change to one type introduces a **new record type in the same
   zone** (`MTBookmark2` beside `MTBookmark`), dual-written for a compatibility window. Never
   a new zone.

---

## 5. Local schema changes

All in `Sources/MajorTomCore/MajorTomDatabase.swift`. Core sync state and bookmark columns
ship in `v6-cloud-sync-refactor`; certificate table changes ship in the following
`v7-cloud-certificate-metadata` migration so running an intermediate refactor commit and then
updating remains safe. GRDB migrations are transactional and safe to interrupt.

### 5.1 New tables

```sql
CREATE TABLE cloud_sync_state (
    account_identity_hash TEXT PRIMARY KEY,
    engine_state         BLOB,
    model_major          INTEGER NOT NULL,
    migrated_from_v1     INTEGER NOT NULL DEFAULT 0,
    migration_phase      TEXT NOT NULL,
    zone_state           TEXT NOT NULL,
    favorites_folder_id  TEXT,
    last_fetched_at      DATETIME,
    last_sent_at         DATETIME,
    updated_at           DATETIME NOT NULL
);

CREATE TABLE cloud_pending_changes (
    account_identity_hash TEXT NOT NULL,
    record_type  TEXT NOT NULL,
    record_name  TEXT NOT NULL,
    operation    TEXT NOT NULL CHECK (operation IN ('save','delete')),
    generation   INTEGER NOT NULL,
    payload_digest TEXT,
    enqueued_at  DATETIME NOT NULL,
    PRIMARY KEY (account_identity_hash, record_name)
);

CREATE TABLE cloud_record_state (
    account_identity_hash TEXT NOT NULL,
    record_type           TEXT NOT NULL,
    record_name           TEXT NOT NULL,
    system_fields         BLOB,
    server_payload        BLOB,
    payload_digest        TEXT,
    last_seen_epoch       INTEGER,
    updated_at            DATETIME NOT NULL,
    PRIMARY KEY (account_identity_hash, record_name)
);
```

The primary key gives idempotency while `generation` prevents an older in-flight send from
acknowledging a newer edit. `cloud_record_state` is required: conflict retries must use the
server record's current change tag, and its payload is the durable source of unknown fields.

### 5.2 Changed tables

```sql
ALTER TABLE bookmarks        ADD COLUMN order_key TEXT;
ALTER TABLE bookmark_folders ADD COLUMN order_key TEXT;
ALTER TABLE bookmarks        ADD COLUMN account_identity_hash TEXT;
ALTER TABLE bookmark_folders ADD COLUMN account_identity_hash TEXT;
ALTER TABLE bookmarks        ADD COLUMN pending_folder_id TEXT;
```

Backfill inside the same migration: read each folder's bookmarks ordered by the existing
`position`, call `OrderKey.initial(count:)`, and write the results. Do the same for folders.
Then:

```sql
CREATE INDEX bookmarks_folder_order ON bookmarks (folder_id, order_key);
```

The `v8-remove-unused-local-storage` migration drops the old `position` columns and their
index after the order-key cutover. Repositories read and write only `order_key`.

### 5.3 Renamed tables

These changes are the `v7-cloud-certificate-metadata` migration.

```sql
ALTER TABLE client_certificate_sync_descriptors  RENAME TO client_certificates;
ALTER TABLE client_certificate_sync_associations RENAME TO client_certificate_associations;
```

These were never sync-shadow tables despite the names; they are the only durable local store
for certificate descriptors and scopes.

### 5.4 Dropped tables

```sql
DROP TABLE bookmark_sync_folders;
DROP TABLE bookmark_sync_bookmarks;
DROP TABLE server_trust_sync;
ALTER TABLE bookmark_folders DROP COLUMN position;
ALTER TABLE bookmarks DROP COLUMN position;
```

These tables were retained during the refactor so an intermediate development build could not
lose a recovery path. They are removed by the `v8-remove-unused-local-storage` migration:
no GitHub release contained `MajorTom.sqlite`, so no downloaded build can require them.

### 5.5 Unchanged

`trusted_server_identities` keeps its shape and becomes purely local. It is now the single
authority for both the trust decision and the local observation, which removes the
decision/observation split the old design needed.

`client_certificate_local_flags` stays. Fix its write path to update only the affected row
(§10.2).

---

## 6. New repository: `CloudSyncRepository`

New file `Sources/MajorTomCore/CloudSyncRepository.swift`. Owns both new tables. Follows the
existing repository pattern (a struct holding a `MajorTomDatabase`).

```swift
public struct CloudSyncRepository: Sendable {
    public init(database: MajorTomDatabase)

    // Sync state
    public func state() throws -> CloudSyncState
    public func saveEngineState(_ data: Data?) throws
    public func saveAccountIdentityHash(_ hash: String?) throws
    public func markMigratedFromV1() throws

    // Outbox
    public func enqueue(_ change: CloudPendingChange, in db: Database) throws
    public func pendingChanges(limit: Int) throws -> [CloudPendingChange]
    public func hasPendingChanges() throws -> Bool
    public func removePending(_ changes: [CloudPendingChange]) throws
    public func removeAllPending() throws
}
```

Note `enqueue` takes a `Database` rather than opening its own transaction. **That is the
whole point** — it must be callable from inside another repository's write block so the
domain row and the outbox row commit together.

**Required tests** (`CloudSyncRepositoryTests.swift`):
- Enqueueing the same `(type, name)` twice leaves one row with the latest operation.
- A `save` followed by a `delete` for the same record leaves only the `delete`.
- `pendingChanges(limit:)` respects the limit and returns oldest-first.
- Engine state round-trips, including `nil`.
- A throwing domain write rolls back the outbox row too. *This is the test that proves the
  atomicity claim; do not skip it.*

---

## 7. The CloudKit adapter

`Sources/MajorTom/ICloudSyncStore.swift` is substantially rewritten. It is 763 lines today;
expect it to shrink considerably, because change tokens, batching, retry, and subscription
management all move into `CKSyncEngine`.

### 7.1 Delete outright

- `performSync()` and everything it calls — the full-zone query, the two-zone merge, the
  compatibility mirror writes.
- `recordNeedsUpload`, `compatibilityRecord`, `recordsNeedingUpload`.
- `refresh()`'s five-minute coalescing gate (`refreshCoalescingInterval` at line 82, and its
  use at lines 179-186). It exists because a fetch currently means querying every record in
  the zone. An incremental fetch that finds nothing is nearly free.
- All `MTServerTrust` handling.
- All `MTPreferences` handling.
- The legacy zone constant and every write to it, once §11's migration code has been moved to
  its own file.

### 7.2 Engine setup

```swift
private func makeSyncEngine() -> CKSyncEngine {
    var configuration = CKSyncEngine.Configuration(
        database: container.privateCloudDatabase,
        stateSerialization: loadedState.engineState.flatMap { ... },
        delegate: self
    )
    return CKSyncEngine(configuration)
}
```

Create it once, early, regardless of account status — the engine stays dormant with no
account and starts on its own when one appears. Configure it for `MajorTomUserDataV2` only.
The v1 zone is never handed to the engine.

### 7.3 `CKSyncEngineDelegate`

Two methods.

**`nextRecordZoneChangeBatch(_:syncEngine:)`**

```
1. Set `syncEngine.state.hasPendingUntrackedChanges` whenever the SQLite outbox is nonempty.
2. Read up to 200 rows from `cloud_pending_changes` for the active account and allowed scope.
3. Build a `CKSyncEngine.RecordZoneChangeBatch`.
   - For 'save': load the domain row, encode CloudRecordPayload, set
     record.encryptedValues["payload"].
   - For 'delete': the batch carries the deletion; no record body needed.
   - If a 'save' row's domain row no longer exists, drop the pending row and skip it.
4. Record the attempted generation and digest before returning the batch.
5. Return nil and clear `hasPendingUntrackedChanges` only when the durable outbox is empty.
```

The batch limit is 250 records (saves plus deletes combined) per request;
`init(pendingChanges:recordProvider:)` stops when full and leaves the rest for the next call.
Requesting 200 leaves headroom.

Only include changes within the scope given by `context.options`; returning out-of-scope
changes fails the send with `invalidArguments`.

**`handleEvent(_:syncEngine:)`** — handle these cases:

| Event | Action |
| --- | --- |
| `.stateUpdate` | Persist `event.stateSerialization` to `cloud_sync_state.engine_state`. Do this every time; it is how change tokens survive relaunch. |
| `.accountChange` | See §7.5. |
| `.fetchedRecordZoneChanges` | Apply modifications and deletions; see §8. |
| `.fetchedDatabaseChanges` | Handle zone deletion/purge as a destructive event; see §7.6. |
| `.sentRecordZoneChanges` | For each success, remove its outbox row. For each failure, see §7.4. |
| `.sentDatabaseChanges` | Log only. |
| `.willFetchChanges` / `.didFetchChanges` | Update the "last synced" timestamp shown by Sync Now. |
| `.willSendChanges` / `.didSendChanges` | Log only. |

Unhandled future cases must be a no-op with a log line, never a crash.

### 7.4 Send failures

- `.serverRecordChanged` — merge into the supplied server record so its current change tag is
  retained, persist its system fields and payload, and retry the still-current generation.
- `.unknownItem` on a delete — the record is already gone. Treat as success and remove the
  outbox row.
- `.zoneNotFound` — create automatically only when local state says the zone was never
  established. A previously active missing zone follows §7.6.
- Anything in the engine's auto-retry list (`networkFailure`, `requestRateLimited`,
  `serviceUnavailable`, `zoneBusy`, `notAuthenticated`, `accountTemporarilyUnavailable`) —
  do nothing; the engine retries.
- Anything else — log, leave the outbox row, surface a failure state to Sync Now.

**Never remove an outbox row except on confirmed success or `unknownItem`-on-delete.**

### 7.5 Account changes

Store `accountIdentityHash` = SHA-256 of the container's user record ID.

| Transition | Action |
| --- | --- |
| `.signIn` | If the stored hash is nil or matches, resume. If it differs, treat as `.switchAccounts`. |
| `.signOut` | **Keep all local data.** Stop syncing. Clear nothing. |
| `.switchAccounts` | Switch to the new account's local dataset and engine state. Preserve the previous account's rows and outbox. Never upload one account's rows to another. |

Edits made while signed out remain owned by the previous account and resume only when it
returns. Certificate private keys in the Keychain are *not* deleted on account switch — they belong to
the Keychain's own account model, not to ours.

### 7.6 Zone deleted or purged

If `fetchedDatabaseChanges` reports our zone deleted — the user reset encrypted CloudKit data,
or deleted the app's iCloud data — this is destructive and must not silently re-upload.

Required behavior: stop syncing, clear the engine state, and surface a distinct status
("iCloud data for Major Tom was removed") with an explicit user action to re-upload this
Mac's data as a fresh zone. Do not decide this automatically.

---

## 8. Applying fetched changes

New file `Sources/MajorTom/CloudChangeApplier.swift` keeps this logic out of the transport.

### 8.1 Ordering gate

Before applying any model record, check the manifest. Under `CKSyncEngine` you cannot gate
the *fetch* — the engine hands you every changed record including the manifest — so the gate
moves to apply time:

1. If the fetched batch contains a manifest, decode it first and store the declared minimum
   reader version.
2. If this build's reader version is below the manifest's minimum for a given record type,
   **quarantine** records of that type: do not decode them into domain rows, do not delete
   anything, and return `nil` from `nextRecordZoneChangeBatch` so this build stops writing.
3. Surface "a newer version of Major Tom is required" in Settings.

Per-record-type minimums, rather than one global gate, mean an unreadable type does not stop
bookmarks and certificates from syncing.

### 8.2 Referential ordering

Incremental fetch does not guarantee a parent arrives before its child. Three cases:

**Bookmark arrives before its folder.** Attach the bookmark to the Favorites folder (the
existing default) and record the intended `folder_id` in a new column:

```sql
ALTER TABLE bookmarks ADD COLUMN pending_folder_id TEXT;
```

When a folder is later created — by any path — scan for bookmarks whose `pending_folder_id`
matches, move them, and clear the column. Do this inside the same transaction that inserts
the folder.

**Association arrives before its certificate descriptor.** Same pattern: hold the association
with a `pending_certificate_id` column and re-attach on descriptor arrival. An association
with no resolvable certificate is never offered to a capsule.

**Descriptor arrives before its Keychain identity.** This is not an ordering bug — the two
travel over completely different channels on independent schedules and may never converge.
See §10.3.

### 8.3 Per-record application rules

| Record type | On modification | On deletion |
| --- | --- | --- |
| `MTBookmarkFolder` | Upsert by UUID. Then resolve any bookmarks whose `pending_folder_id` matches. | Delete the folder row. **Re-parent its bookmarks to Favorites; do not cascade.** |
| `MTBookmark` | Upsert by UUID. If the folder is unknown, apply §8.2. Resolve favicon observations by `fetchedAt`. | Delete the row. |
| `MTClientCertificateDescriptor` | Upsert by UUID. Do not touch the Keychain. | Delete the descriptor row. See §10.4 before deleting key material. |
| `MTClientCertificateAssociation` | Upsert by UUID; apply §8.2 if the certificate is unknown. | Delete the row. |
| `MTDeviceTabs` | Replace the whole record for that device ID. Ignore our own device. | Remove that device from the list. |
| `MTDataModelManifest` | Store; apply §8.1. | Should never happen; log and ignore. |

**The re-parent rule is the important one.** The SQL `ON DELETE CASCADE` on
`bookmarks.folder_id` (`MajorTomDatabase.swift:122`) stays for *local* deletions, where the
user saw the folder's contents and confirmed. It must not fire for a remote deletion. In
practice: when applying a remote folder delete, first `UPDATE bookmarks SET folder_id =
<favorites> WHERE folder_id = <deleted>`, then delete the folder row.

Without this, Mac A deleting a folder while offline Mac B adds twenty bookmarks to it
destroys twenty bookmarks nobody deleted.

### 8.4 Conflict rules

Reached via `.serverRecordChanged`, which supplies the server's record.

| Type | Rule |
| --- | --- |
| Bookmark, folder | Last server-accepted writer wins for known payload fields. Preserve unknown fields from both sides; resolve favicon by observation time. |
| Ordering | No conflict by construction — a move changes one record's `orderKey`. |
| Certificate descriptor, association | Last writer wins. |
| Device tabs | Ours always wins for our own device; other devices' records are never written by us. |
| Any delete vs. edit | Delete wins. Re-creating produces a new UUID and is a genuinely new record. |

Delete-wins avoids adjudicating "which happened later" using device wall clocks, which are
not trustworthy across machines.

### 8.5 Local mutation ordering

Fetched changes, local edits, and debounced flushes now complete out of order. Two rules:

1. **One owning actor per domain.** All bookmark mutations serialize through the bookmark
   store; all certificate mutations through the certificate store.
2. **A monotonic local revision.** Each in-memory domain model carries a counter incremented
   on every local mutation. An async completion carrying a stale revision is discarded rather
   than published. Without this, a slow local write can overwrite a newer remote apply.

Replace silent `try?` specifically on state-changing persistence calls with surfaced or logged
error handling. Optional decoding, best-effort legacy probing, and nullable reads are audited
individually rather than changed mechanically.

---

## 9. Cloud tabs

### 9.1 Payload shape

Cloud tabs are a **deduplicated, unordered set keyed by normalized URL**. The same page open
in three tabs appears once.

```swift
public struct CloudTabSnapshot: Codable, Equatable, Sendable {
    public var url: URL        // normalized; this is the identity
    public var title: String
    public var favicon: String?
}
```

Remove the per-tab `id`. Two tabs with the same normalized URL but different titles: take the
first and move on — it is the same page.

Extract browser URL identity normalization into Core and have both this type and
`GeminiRequestTarget` reuse the applicable Gemini rules. Accept future schemes and opaque
URLs; exclude `about:` and `data:` URLs.

Cap the set at 200 entries; CloudKit limits record size, and a pathological session should
degrade rather than fail to sync.

Full URLs including query strings are published. State this in
`major-tom-specification.md` — the current text describes the record as privacy-conscious and
is silent about the query component.

### 9.2 Publishing

Replace `scheduleCloudTabPublish()` and its 750 ms task (`MajorTomApp.swift:955-962`) with a
single entry point:

```swift
func publishCloudTabsIfNeeded(reason: CloudTabPublishReason)
```

```
1. Build the deduplicated set from all registered tabs in all windows.
2. If it equals the last set sent to iCloud, return. (This eliminates most calls —
   navigations that land back where they started, reloads, re-arriving titles.)
3. If reason is a departure event, publish now.
4. Otherwise publish only if >= 5 minutes have elapsed since the last publish.
5. Register the change with syncEngine.state.add(pendingRecordZoneChanges:).
```

Callers:

| Reason | Source | Bypasses the 5-minute gate |
| --- | --- | --- |
| `.heartbeat` | 5-minute repeating timer | No |
| `.piggyback` | Any other sync is already happening | No |
| `.idle` | `NSWorkspace.screensDidSleepNotification` | Yes |
| `.sleep` | `NSWorkspace.willSleepNotification` | Yes |
| `.terminating` | `applicationWillTerminate` | Yes |
| `.launch` | After session restoration completes | Yes |
| `.manual` | Sync Now | Yes |

`.launch` fires **after** session restoration, never before — publishing an empty list would
hide this Mac from every other one until the next tick. It is normally a no-op, and exists
for the case where the Mac was shut down before a publish completed.

### 9.3 Cloud tabs bypass the outbox

Register them directly with the engine's own pending list. They are ephemeral and
self-replacing: losing one across a crash costs nothing because the next publish supersedes
it, and it is not worth a SQLite transaction on the navigation path.

This is not a second source of truth. The rule is: **durable user intent goes through the
outbox; ephemeral device state does not.** The same applies to the manifest.

### 9.4 Fetching and display

`ICloudTabsView.onAppear` calls the full-sync action (§12). Render the cached list from
UserDefaults immediately with a subtle refreshing indicator, then update in place — never a
spinner over an empty view.

Display rules, in `visibleCloudTabDevices` (`CloudSyncModels.swift:469-480`):
- Hide our own device.
- Hide devices with an empty set.
- Hide devices not updated within 7 days.

Lifecycle:
- Physically delete device records not updated within **30 days**, during deferred
  maintenance only.
- Add a **"Remove Device"** command in the row's context menu with a destructive confirmation
  defaulting to Cancel, for the sold-or-wiped Mac case.

---

## 10. Certificates and Keychain

### 10.1 Table renames

Rename the two tables (§5.3) and rename the repository accordingly:
`SecuritySyncRepository` → `ClientCertificateRepository`. Remove all tombstone handling and
`deletedAt` fields; deletion is physical.

### 10.2 Local flags

`client_certificate_local_flags` currently deletes and re-inserts every row whenever any
certificate state is persisted. Change to a single-row upsert for the affected id only.

### 10.3 The two-channel problem

A descriptor arrives over CloudKit in seconds; its private key arrives over iCloud Keychain
whenever the OS decides, or never. **"Known certificate, key not available" is a normal
steady state, not an error.**

Requirements:
- Model availability separately from existence. Never delete a descriptor because its key is
  absent.
- Show an explicit "not available on this Mac" status rather than an error or a repeated
  prompt.
- Match a descriptor to a Keychain item by UUID **and**, as a fallback, by the certificate's
  SHA-256 fingerprint stored in the payload (§4.4). The current code matches only by UUID
  (`ClientCertificateKeychain.swift:677-704`) and uses the fingerprint solely for import-time
  duplicate detection.
- Never offer an identity whose association resolves to a descriptor with no available key.

### 10.4 Deletion is the dangerous path

`ClientCertificateStore.swift:391-399` computes removed IDs from merged remote state and
calls `keychain.delete(id:)`, and the delete path uses `kSecAttrSynchronizableAny` — so it
removes the synchronizable item and propagates that deletion to every device.

Under physical deletion this becomes reachable from more code paths. Required:

- A remote descriptor deletion removes the **descriptor row** immediately, but does **not**
  destroy Keychain material without an explicit local confirmation.
- Present the certificate as "removed on another Mac — delete the private key here?" with a
  destructive-styled confirmation defaulting to Cancel.
- Never destroy key material as a side effect of a token-expiry resync or a transient fetch
  anomaly.

A private key is the only genuinely unrecoverable thing in this system.

### 10.5 Keychain constraints to preserve

Existing behavior that is already correct — do not regress it:
- `kSecAttrSynchronizable` is set only at creation. It **cannot** be changed by
  `SecItemUpdate`; changing it requires delete-and-re-add, which needs an exportable key. The
  UI correctly presents storage as read-only status, not a toggle.
- `kSecUseDataProtectionKeychain: true` on all preferred paths. The legacy fallbacks that
  pass `false` should get a one-time migration that promotes those items, after which the
  legacy probing can be removed.
- `errSecDuplicateItem` is currently treated as success in `storeImportedPrivateKey`
  (`ClientCertificateKeychain.swift:657-669`), so an import silently binds to a pre-existing
  item with the same tag. Change this to a real error.

---

## 11. Migration

### 11.1 The one-shot v1 read

New file `Sources/MajorTom/LegacyZoneMigration.swift`, deliberately self-contained so it can
be deleted in a later release without touching sync.

**The migration marker lives in CloudKit, not in local `persistence_metadata`.** This is the
correctness-critical detail. v1 → v2 is a once-per-*account* event; a local marker is
per-device by construction, so each Mac would run its own v1 read at its own time and a Mac
upgrading months later would merge stale v1 state forward, resurrecting exactly what the
cutover retired.

```
On launch, before the engine syncs model records:
1. Fetch the v2 manifest record by ID.
2. If it is the ready target manifest, do nothing and never inspect v1.
3. Otherwise claim a change-tag-guarded migration lease and write a higher model major. This
   makes existing v2 builds stop before writing incompatible data.
4. Delete the disposable old-v2 model records, including old tabs, preferences, and trust.
5. Query v1 once. Merge its active result with this Mac's unclaimed local data, respecting v1
   tombstones without copying tombstones forward.
6. Adopt one canonical Favorites folder ID stored in the manifest.
7. Commit domain rows and durable outbox changes, upload them idempotently, and mark the
   manifest ready only after required records are confirmed.
8. Mirror completion locally. A crashed lease may be taken over and the migration rerun.
```

Never write to the v1 zone. Never delete the v1 zone — an un-upgraded Mac may still be using
it, it costs nothing in the user's own storage, and deleting user data to tidy up is not
worth the risk.

An un-upgraded Mac silently stops syncing with upgraded ones. That is the accepted cost and
belongs in the release notes.

### 11.2 The `MTServerTrust` deletion sweep

Also in `LegacyZoneMigration.swift`, deleted in the same later release.

A tombstone would not help here: a tombstone keeps the same record name, and the record name
*is* the leak. These require physical deletion.

```
1. Query BOTH zones for records of type MTServerTrust.
2. Delete every returned record ID.
3. No completion marker is required — "the query returns zero records" is itself
   the signal, and re-running is harmless.
```

Delete by query, not by names recomputed from local rows: recomputation misses records for
endpoints this Mac no longer trusts, whose removal wrote a tombstone that still sits under a
name derived from a host now forgotten locally.

### 11.3 Bookmark merge on a Mac with existing cloud data

There are no default bookmark entries, but every local collection has a synthesized Favorites
folder. Migration selects one canonical Favorites folder deterministically and reparents any
provisional local Favorites contents into it.

---

## 12. Preferences via `NSUbiquitousKeyValueStore`

New file `Sources/MajorTom/PreferenceSyncStore.swift`. Remove `MTPreferences` from CloudKit
entirely.

### 12.1 Why

The current design is one replaceable CloudKit record, so the conflict unit is the whole
settings blob: change the theme on one Mac and the homepage on another while both are
offline, and one edit is silently lost. `NSUbiquitousKeyValueStore` resolves **per key**.

It also needs no record type, no zone, no queryable index, and no schema deployment.

### 12.2 Synchronized keys

Homepage, search provider, custom search endpoint, content theme, content width, Gemtext rendering options, inline
`data:` image display, automatic same-capsule images, favicon visibility.

**Not synchronized** — these stay in local `UserDefaults`: application appearance, Gemini
proxy configuration, Favorites-bar visibility, the device ID, migration markers, the cached
remote-tabs display list.

### 12.3 Applying a received change

**A preference arriving from iCloud must take the same code path as the user changing it in
Settings on this Mac.** No separate "apply remote" branch.

`BrowserSettingsStore` already has the receive hook at line 70. What matters is that setting
the value there fires the same `@Published` propagation a local edit does, so every open
`BrowserModel` re-renders from its cached source — with no network request. The specification
already promises this for local changes; remote reuses it.

Two settings classes:

| Class | Settings | Effect on apply |
| --- | --- | --- |
| Presentation | theme, width, inline formatting, image options, favicon visibility | Re-render every open document from its cached source. No network. |
| Deferred | homepage, search provider | Update the stored value; affects the next Home press or search only. |

**Suppress the echo.** Remote value arrives → you set it locally → your local-change observer
fires → you publish it back → the other Mac receives it. With `NSUbiquitousKeyValueStore` this
genuinely loops, because your own writes and external changes both surface through the same
store. Applying a remote value must not mark it dirty for publishing. Use an explicit
`isApplyingRemoteChange` guard around the assignment.

Observe `NSUbiquitousKeyValueStore.didChangeExternallyNotification` and reconcile only the
keys named in the notification's `changedKeys` payload.

The synchronized subset is cached per iCloud account. Existing v1 `MTPreferences` participates
in the one-shot migration; existing v2 preferences are disposable. Add the
`com.apple.developer.ubiquity-kvstore-identifier` entitlement.

---

## 13. Sync Now

One control, one action. Both Settings and the Cloud Tabs view's refresh call it.

```
1. publishCloudTabsIfNeeded(reason: .manual)
2. syncEngine.fetchChanges()
3. Apply and reconcile fetched changes, including deletions.
4. syncEngine.sendChanges()
5. Perform a final fetch when conflict retries changed server state.
6. Update lastSyncedAt on success; set a failure state on error.
```

Show a last-synced timestamp and a visible failure state when iCloud is unavailable.
Do not build separate "sync tabs" and "sync everything" controls.

---

## 14. Entitlements and project configuration

### 14.1 Remote notifications

`CKSyncEngine` requires the CloudKit **and remote-notification** entitlements. Both files
currently carry only `com.apple.application-identifier`,
`com.apple.developer.team-identifier`, and the iCloud/CloudKit keys.

Add to `Entitlements/MajorTom.development.entitlements` and
`Entitlements/MajorTom.release.entitlements`:

```xml
<key>aps-environment</key>
<string>development</string>   <!-- "production" in the release file -->
```

**Verify first:** confirm whether `CKSyncEngine` initializes without this. Apple's
documentation says it is required. If the engine fails to start, check this before debugging
sync logic.

### 14.2 CloudKit dashboard

Because every record type has exactly one field, no schema changes are needed after the
initial deploy. Specifically:

- **Remove** the `QUERYABLE` index requirement on `recordName` documented in
  `how-to-build.md:39-49`. The engine uses change tokens, not queries. The only remaining
  query is the one-shot v1 read and the trust sweep, both of which target the *legacy*
  types.
- `MTServerTrust` and `MTPreferences` are no longer written. Leave the types in the deployed
  schema; a production CloudKit schema is append-only and there is no benefit to trying.

Update `how-to-build.md` accordingly.

### 14.3 Encryption constraint

Every field must be **born** encrypted. An existing unencrypted field can never be converted,
and encrypted fields cannot be indexed. Never add a plaintext field "just for sorting or
filtering". The current code is correct — every write uses
`record.encryptedValues["payload"]` and there is not a single plain `record[...]` field write
in the codebase. Preserve that absolutely.

---

## 15. Implementation stages

Each stage ends with `make test` green. Do not begin a stage until the previous one is
committed.

| # | Stage | Notes |
| --- | --- | --- |
| 1 | Test fixtures: a **file-backed `DatabasePool`** helper alongside the existing in-memory `DatabaseQueue` | `MajorTomDatabase.swift:41` uses `DatabaseQueue` for tests while production uses `DatabasePool` at line 28. The test database serializes everything, so every concurrency bug this refactor risks is currently invisible. Do this first. |
| 2 | `JSONValue`, `CloudPayload`, `OrderKey` with their full test suites | Pure Core, no dependencies, no behavior change. |
| 3 | Migration `v6`: new tables, `order_key` columns and backfill, table renames | Schema only; nothing reads the new columns yet. |
| 4 | `CloudSyncRepository` and its tests | Including the rollback test. |
| 5 | Switch bookmark ordering to `order_key`; `recordID` takes a `UUID` | Payload-affecting; must precede cutover. |
| 6 | Domain mutations enqueue outbox rows in their existing write transactions | Nothing consumes the outbox yet — safe to land alone. |
| 7 | `CKSyncEngine` integration: delegate, event handling, `CloudChangeApplier` | The core replacement. Remove `performSync` and the two-zone merge here. |
| 8 | Cloud tabs rework: dedup by normalized URL, new publish triggers, engine registration | Delete `scheduleCloudTabPublish`. |
| 9 | Preferences to `NSUbiquitousKeyValueStore`; remove `MTPreferences` | Independent of the engine. |
| 10 | `LegacyZoneMigration`: v1 one-shot read plus the `MTServerTrust` sweep | Self-contained file. |
| 11 | Remove trust sync: drop `server_trust_sync` usage, delete the record type | `trusted_server_identities` becomes purely local. |
| 12 | Certificate changes: renames, single-row flags, fingerprint fallback, deletion confirmation | |
| 13 | Entitlements, `how-to-build.md`, `architecture.md`, `major-tom-specification.md` | Including the frozen rules in §4.5 and the query-string disclosure in §9.1. |
| 14 | *(One release later)* Migration `v7`: drop `bookmark_sync_*`, `server_trust_sync`, `position` columns | Never in the same release as the migration that populates their replacements. |

---

## 16. Verification

### 16.1 Automated

Core tests must cover, at minimum:

- **Unknown-field preservation** through decode → mutate → encode. (§3.2)
- Order keys: strict betweenness, 1,000 same-position inserts, front and back insertion.
- Outbox: idempotent enqueue, save-then-delete collapses, **domain rollback rolls back the
  outbox row**.
- Conflict rules: one test per row of §8.4's table.
- **Remote folder deletion re-parents rather than cascades.** Construct the exact scenario:
  folder deleted remotely, local children present, assert children survive in Favorites.
- Referential ordering: a bookmark applied before its folder lands in Favorites and moves
  when the folder arrives; an association applied before its descriptor likewise.
- Migration `v6` runs on a database populated with realistic v5 data and produces correct
  `order_key` values.
- Cloud tabs dedupe: the same normalized URL in three tabs yields one entry.

### 16.2 Manual, requires two Macs and a development signing identity

The ad-hoc development build intentionally lacks iCloud entitlements, so none of this can be
automated:

- A physical deletion propagates and does not resurrect after the other Mac comes back
  online.
- Offline pending changes survive a restart and upload on reconnect.
- A kill between the domain commit and the engine's state update loses no pending change.
- Token expiry preserves outbox rows and removes only clean stale rows.
- Reading preferences applied on Mac A re-render open documents on Mac B without a reload.
- Cloud tabs appear on the other Mac after sleep, and after Sync Now.
- Account switch clears synchronized data and preserves local-only data.
- Local-only data — history, drafts, session, cache, trust — never appears on the other Mac.

### 16.3 Performance

- No SQL blocks `MainActor` during navigation, scroll, or address-field typing.
- Time from launch to first restored window is unchanged.
- The v1 migration does not delay first-window rendering.
