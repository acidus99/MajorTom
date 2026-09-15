# Cloud Sync Reliability Implementation Guide

Status: Approved implementation plan; not yet fully implemented

This document is the execution contract for production-hardening Major Tom's existing
**custom CloudKit sync over GRDB**. It supplements `cloud-sync-refactor.md` and supersedes
that document where this guide is more specific about outbox durability, transaction
boundaries, conflict reconciliation, status reporting, and testing.

The objective is not to replace `CKSyncEngine`, GRDB, record-level synchronization, the
encrypted one-field CloudKit schema, or account-scoped local databases. The objective is to
make the bridge between them deterministic, crash-safe, observable, and testable.

Normative terms are used deliberately:

- **MUST** is required before this project is complete.
- **SHOULD** is the expected implementation unless code inspection proves a materially
  better equivalent.
- **MAY** is optional.

---

## 1. Instructions to the implementing agent

Read this entire guide, `AGENTS.md`, `architecture.md`, `cloud-sync-refactor.md`, and the
iCloud section of `major-tom-specification.md` before editing production code.

1. Preserve all existing user changes. At the start, inspect `git status` and the current
   diff. In particular, the working tree may already contain a provisional fix that prevents
   fetched modifications from overwriting records with pending local saves or deletes.
2. Implement the phases in order. Do not make one giant rewrite.
3. Keep CloudKit types out of `MajorTomCore`. Core MUST remain transport-neutral and MUST
   not import CloudKit, SwiftUI, AppKit, or WebKit.
4. Keep every local domain mutation and its outgoing sync intent in one SQLite transaction.
5. Never convert a database, decode, serialization, or record-construction failure into
   “no changes,” success, or an acknowledged outbox item.
6. Do not change the CloudKit zone or record schema merely to complete this project. The
   existing private zone and encrypted `payload` field remain authoritative.
7. Do not delete legacy tables, reset a production zone, run `make prod`, run `make release`,
   or commit unless the user explicitly asks.
8. Tests use XCTest. Test behavior and invariants, not copied implementation literals.
9. After every phase, run the focused tests named in that phase. Before handoff, run
   `make test` and `Scripts/build-app.sh`.
10. If implementation reveals a product-policy ambiguity that changes user-visible conflict
    behavior, stop at the phase boundary and document the exact competing outcomes. Do not
    silently invent a new policy.

The implementation may use different private names where Swift or GRDB requires it, but the
data model, invariants, transaction boundaries, and observable behaviors in this guide are
requirements.

---

## 2. Why the observed bookmark failure was possible

The current outbox records only a record identity and operation. When a send batch is built,
`ICloudSyncStore` rereads the current domain row to construct the CloudKit record. A fetched
server value can therefore overwrite a locally edited row before the pending save is encoded.
The outbox still says “save this bookmark,” but the value it later reads is the old server
value. That stale value can be uploaded and can then converge onto every Mac.

The provisional pending-change guard prevents that exact overwrite. It is necessary as an
immediate regression fix, but it is not sufficient for production reliability because the
outbox still does not durably contain the value the user intended to upload.

The current “Up to Date” status is also too weak. It can be assigned after a fetch event or
after observing an empty outbox; neither fact alone proves that a requested fetch/send cycle
completed successfully. Some repository reads use `try?`, so a database failure can be
mistaken for an empty queue. In addition, the displayed row covers CloudKit records, not
necessarily KVS preferences or iCloud Keychain propagation.

This project fixes the class of failure rather than adding another timing workaround.

---

## 3. Scope and non-goals

### 3.1 In scope

- Bookmark and bookmark-folder records.
- Client-certificate descriptor and association records. Private keys remain owned by
  iCloud Keychain.
- Device-tabs records.
- The data-model manifest.
- Account isolation, sign-in, sign-out, switching accounts, zone deletion, and v1 import as
  they interact with reliability.
- Durable outgoing intent, incoming reconciliation, conflict policy, retries, status,
  diagnostics, deterministic simulation, and release validation.

### 3.2 Non-goals

- Replacing GRDB with Core Data or SwiftData.
- Replacing `CKSyncEngine`.
- Synchronizing history, session state, trust decisions, cache data, or local UI settings.
- Building cross-record collaborative editing or a general CRDT framework.
- Claiming that “Sync Now” can force another offline Mac to receive data immediately.
- Showing Keychain propagation as transactionally complete; Apple does not expose that as
  part of this CloudKit engine's completion boundary.

---

## 4. Required user-visible semantics

### 4.1 What “Up to Date” means

For the active iCloud account, CloudKit data may display **Up to Date** only when all of the
following are true:

1. Account status is available and the v2 zone is active.
2. The most recently requested sync cycle completed a successful fetch phase.
3. Every local CloudKit mutation known by the coordinator has either been acknowledged by
   CloudKit or was proven already present/deleted on the server.
4. The durable outbox is empty for that account.
5. There is no unresolved persistence, payload, engine-state, account, zone, or CloudKit
   error.

“Up to Date” means this Mac has no known CloudKit work at the end of a completed cycle. It
does not mean every other device is online or has fetched the result.

The Settings label SHOULD be scoped as **CloudKit Data** or otherwise make this boundary
clear. Preferences use `NSUbiquitousKeyValueStore`, and certificate private keys use iCloud
Keychain; neither is part of the CloudKit completion proof.

### 4.2 Conflict policy

The project keeps the policies already chosen in `cloud-sync-refactor.md`:

| Situation | Required result |
| --- | --- |
| Remote modification, no local pending intent | Apply the remote value. |
| Remote modification, local pending save | Keep the immutable local pending value, store the newest server metadata, and retry against it. |
| Remote modification, local pending delete | Do not resurrect the local row; retain the delete. |
| Confirmed remote deletion | Delete wins. Remove the local record and any pending intent for that record. |
| Save rejected with `serverRecordChanged` | If server content already equals the pending snapshot, acknowledge it. Otherwise preserve local pending content, update server metadata, and retry. |
| Delete returns `unknownItem` | Desired state is already achieved; acknowledge that exact delete generation. |
| Child arrives before parent | Attach to the default parent and retain the desired parent ID for later repair. |
| Remote folder deletion | Do not cascade locally merely because the folder record arrived before child changes. Re-parent or retain pending-parent metadata according to the existing design, then allow later bookmark records/deletions to settle independently. |
| Bookmark favicon conflict | The newer `fetchedAt` observation wins independently of other bookmark fields, as already specified. |

There is intentionally no wall-clock last-writer-wins rule for bookmark titles. Device clocks
are not a reliable total ordering, and the current record payload does not contain a durable
per-field causal history. A local pending edit wins over a fetched modification until the
server confirms the local desired value; otherwise the fetched server value is authoritative.

### 4.3 Delete semantics

A fetched CloudKit deletion is a server-confirmed deletion, not merely another competing
value. It MUST win over a pending local edit. This is the existing product policy.

All record types MUST use the same deletion rule. The application MUST NOT infer a remote
deletion merely because a fetch omitted a record; only a CloudKit deletion event or a
successful/`unknownItem` delete result is proof.

---

## 5. System invariants

These invariants are the acceptance criteria for the implementation and its tests.

### 5.1 Durability

1. A local mutation and its outgoing representation commit atomically.
2. After that transaction commits, the outgoing value does not depend on a future read of a
   mutable domain row.
3. A process crash at any instruction boundary may cause a retry, but MUST NOT lose an
   acknowledged-or-unacknowledged local mutation.
4. A pending generation for an account and record name is never reused, even after an older
   generation is acknowledged and removed.
5. Only the exact generation attempted may be acknowledged.
6. A failed payload encode/decode, database read/write, or `CKRecord` construction leaves the
   outbox item pending and makes status failed.

### 5.2 Reconciliation

1. An incoming batch's domain changes, server metadata changes, and outbox acknowledgements
   commit in one SQLite transaction.
2. A fetched modification never overwrites a pending local save or recreates a pending local
   delete.
3. A fetched server value equal to the pending desired value may satisfy and acknowledge that
   pending generation.
4. Unknown payload fields received from a newer app version survive a local edit and retry.
5. Replaying the same fetched event or sent result is idempotent.
6. Events for account A never read, write, acknowledge, publish, or display account B's data.

### 5.3 Progress and reporting

1. Sync makes progress in bounded batches without starving records later in the queue.
2. Retriable errors retain durable intent and use bounded backoff supplied by CloudKit or the
   coordinator.
3. Terminal/local errors remain visible until a later successful cycle clears them.
4. The UI never reports Up to Date merely because an error path returned an empty array.
5. Logs identify account, record type, operation, generation, phase, and error category but
   never include decrypted user content, URLs, bookmark titles, certificate material, or
   unhashed account identifiers.

---

## 6. Target architecture

The target is three explicit layers:

```text
Domain repositories                 Sync coordinator                 CloudKit adapter
-------------------                 ----------------                 ----------------
GRDB rows + immutable outbox  <-->  pure reconciliation rules  <--> CKSyncEngine / CKRecord
single transactions                 cycle/status state               system-field archives
```

### 6.1 Domain repositories

`BookmarkRepository` and `ClientCertificateSyncRepository` own domain SQL. Every local
insert/update/delete MUST also enqueue the exact outgoing model payload in the same
`MajorTomDatabase.write` closure.

Fetched changes MUST enter through new transaction-scoped repository functions. Do not
implement reconciliation by loading an entire model, mutating it in memory, then calling a
public replacement method in a separate transaction.

### 6.2 Transport-neutral sync repository/coordinator

`MajorTomCore` SHOULD define transport-neutral values similar to:

```swift
public struct CloudOutgoingIntent: Equatable, Sendable {
    public let accountIdentityHash: String
    public let recordType: String
    public let recordName: String
    public let operation: CloudPendingOperation
    public let generation: Int64
    public let modelPayload: Data?
    public let payloadDigest: String?
    public let serverSystemFields: Data?
    public let serverPayload: Data?
}

public struct CloudIncomingRecord: Equatable, Sendable {
    public let recordType: String
    public let recordName: String
    public let modelPayload: Data
    public let serverPayload: Data
    public let systemFields: Data
}
```

Exact visibility and names are not important. These properties and semantics are.

The coordinator owns pure decisions such as “apply remote,” “retain local and rebase,” or
“server already equals pending.” It MUST be unit-testable without CloudKit or a network.

### 6.3 CloudKit adapter

`ICloudSyncStore` becomes an adapter and lifecycle owner. It SHOULD be made smaller by
extracting transport-neutral behavior, but a file split alone is not a reliability fix.

The adapter:

- translates `CKSyncEngine.Event` values into Core input values;
- archives and restores CKRecord system fields;
- rebuilds `CKRecord` from an immutable pending model payload plus the latest stored server
  envelope/system fields;
- preserves unknown envelope fields;
- reports explicit success/failure outcomes to the coordinator;
- drives the cycle state machine and publishes UI status.

It MUST NOT reread a bookmark/certificate row to decide what a previously committed outbox
item means.

---

## 7. SQLite schema and migration

Add a new immutable migration after `v10`; do not edit an already-shipped migration.
Suggested identifier: `v11-durable-cloud-outbox-payloads`.

### 7.1 `cloud_pending_changes`

Add:

- `model_payload BLOB NULL`
- retain `payload_digest TEXT NULL`, but begin populating it for every save

For all newly enqueued operations:

- save: `model_payload` and `payload_digest` MUST be non-null;
- delete: both MUST be null.

The payload is canonical sorted-key JSON for the typed **model**, not a final CloudKit
envelope. Keeping the model separate allows a retry to merge it into the newest server
envelope and preserve unknown fields after `serverRecordChanged`.

`payload_digest` is lowercase SHA-256 hex of `model_payload`. It is an integrity and semantic
comparison aid, not a secret and not a conflict clock.

SQLite cannot safely add a non-null column for old rows without an invented default. Keep the
column nullable at schema level and enforce the invariant in repository APIs after legacy
materialization.

### 7.2 Durable generation ledger

Create:

```text
cloud_record_generations
    account_identity_hash TEXT NOT NULL
    record_name           TEXT NOT NULL
    last_generation       INTEGER NOT NULL
    PRIMARY KEY (account_identity_hash, record_name)
```

When enqueuing, increment this ledger and upsert the outbox using the returned value in the
same transaction. Never derive the next generation only from the current outbox row: that row
is deleted after acknowledgement, which allows generation reuse.

Do not delete a generation-ledger row during ordinary acknowledgement or server deletion.
Account-wide destructive cleanup may remove it only when all data and sync state for that
account are intentionally removed.

### 7.3 Legacy outbox materialization

Rows created before v11 have no `model_payload`.

1. Migration itself only adds schema and seeds `cloud_record_generations.last_generation`
   from existing pending generations.
2. Before such a save may be sent, a typed materializer MUST encode the current domain value
   in a database transaction, assign a new non-reused generation, and store payload/digest.
3. Manifest payloads can be materialized deterministically.
4. Device tabs are ephemeral. If the old pending row lacks a durable payload, discard that
   particular legacy save only while atomically replacing it with a freshly captured current
   device-tabs payload and a new generation.
5. If a required domain row is absent or encoding fails, do not acknowledge or delete the
   pending save. Record an actionable local failure. Human-visible content must not be guessed.

Tests MUST cover migration from a hand-built v10 database containing pending save and delete
rows, including a generation greater than one.

### 7.4 Indexes and constraints

Add or verify an index supporting:

```sql
WHERE account_identity_hash = ? ORDER BY enqueued_at, record_name
```

Repository code MUST reject invalid combinations (save without payload, delete with payload,
non-positive generation, mismatched digest). Add SQLite checks only if the installed SQLite
version and migration behavior are verified across supported macOS versions.

---

## 8. Outgoing write path

### 8.1 Local domain mutation

For each changed record inside one `database.write` transaction:

1. Normalize and validate the domain value.
2. Write the domain row.
3. Construct its typed Cloud payload from the value being written, not from a later query.
4. Encode canonical sorted-key JSON.
5. Compute its digest.
6. Increment the durable generation ledger.
7. Upsert the outbox row with operation, generation, exact model payload, digest, and time.

For deletion, delete the domain row and enqueue a payload-less delete in that same
transaction.

If any step throws, the whole transaction rolls back. The UI/model layer must not update its
published in-memory value as if persistence succeeded. Remove `try?` from write paths where
failure would otherwise create UI/database divergence.

### 8.2 Coalescing

There remains at most one pending row per account and record name. Later local edits replace
the earlier pending snapshot and receive a new generation. This is safe coalescing because
only the latest desired record state must reach CloudKit.

The generation ledger means:

```text
save g=8 is sent -> user edits -> outbox becomes save g=9
late success for g=8 -> acknowledgement predicate does not remove g=9
```

A save followed by delete becomes a new delete generation. A delete followed by recreation
becomes a new save generation.

### 8.3 Batch preparation

One consistent database read MUST return each pending row together with its latest stored
server metadata. Invalid rows are explicit errors, not omitted by `compactMap` or `try?`.

For a save:

1. Decode the immutable typed model payload.
2. Decode the latest `server_payload` envelope when present.
3. Replace only known model fields, retaining unknown envelope fields.
4. Restore `CKRecord` from stored system fields when available; otherwise create it from the
   stable record ID.
5. Store the attempted `(account, recordName, generation, digest)` until the corresponding
   sent event is reconciled.

For a delete, submit the stable record ID and store its attempted generation.

Failure in steps 1–4 MUST keep the item pending and transition status to failed. A function
that cannot build a save MUST return a failure result, never `nil` meaning “acknowledge it.”

### 8.4 Sent results

For each successful save, atomically:

- persist returned system fields and the exact server envelope;
- update its digest/last-seen metadata;
- acknowledge only the attempted generation;
- update the account's sent timestamp.

For successful or `unknownItem` delete, atomically acknowledge only the attempted generation
and remove obsolete record metadata as appropriate.

For `serverRecordChanged`, see §9.4. Other retriable failures retain the item. Terminal
failures retain the item and publish a user-actionable failure; they MUST NOT spin in a tight
retry loop.

If the process crashes after CloudKit accepted a save but before local acknowledgement, the
outbox remains. On retry, a matching server payload is recognized as already committed and is
acknowledged without losing intent.

---

## 9. Incoming and conflict reconciliation

### 9.1 One transaction per delivered batch

Decode and validate transport records before opening the SQLite write when possible. Then
apply all domain changes, outbox acknowledgements, record metadata, pending-parent repairs,
and account timestamps for that delivered batch in one database transaction.

If one record is malformed, do not silently drop it. Prefer rejecting the batch and retaining
the change token so it can be retried after a fix. If CKSyncEngine semantics require advancing
engine state, persist a durable quarantine record with enough non-sensitive metadata to make
the failure visible and recoverable before advancing. Never advance and forget a record.

The serialized `CKSyncEngine.State` supplied through state-update events MUST be stored
durably. Errors saving it are sync failures, not log-only warnings.

### 9.2 Fetched modification with no pending intent

- Decode and validate identity: payload UUID MUST equal record-name UUID.
- Apply the typed domain record without enqueueing an echo upload.
- Save server system fields, full server envelope, and canonical known-model digest.
- Repair parent relationships deterministically.

### 9.3 Fetched modification with pending intent

If pending operation is delete, retain the local deletion, save the newest server metadata,
and keep the delete queued.

If pending operation is save:

- compare the canonical known-model payload/digest, not raw envelope bytes;
- if equal, server state already satisfies local intent: save metadata and acknowledge that
  exact generation;
- if different, do not apply the remote known fields to the domain row; save metadata and
  retain the immutable pending snapshot for retry.

The existing `CloudPendingChangeSet` guard may remain during refactoring, but the completed
implementation SHOULD replace broad pre-filtering with this per-record transactional rule.

### 9.4 `serverRecordChanged`

Treat the returned server record as new metadata and content:

1. Validate and decode the server envelope.
2. If its known-model payload equals the attempted pending snapshot, atomically persist
   metadata and acknowledge the exact generation.
3. Otherwise persist the server metadata/envelope, leave the pending snapshot unchanged, and
   request another send. The next CKRecord is based on the new change tag and preserves
   unknown fields.
4. Do not apply the conflicting server known fields over the locally pending domain value.

Bound retries. Repeated identical conflicts beyond a small threshold SHOULD surface a
diagnostic with record type/name hash and generation rather than loop continuously. The
pending intent remains durable.

### 9.5 Fetched deletion

Atomically:

- remove the typed domain record according to delete-wins policy;
- remove pending intent for that record regardless of operation;
- remove obsolete server metadata;
- perform deterministic orphan/pending-parent repair;
- update fetch metadata.

Deletion events are idempotent. Replaying one against an already-absent row succeeds.

### 9.6 Payload and identity validation

Every record MUST validate:

- known record type;
- valid UUID record name where that type requires UUID names;
- payload identity equals record identity;
- supported envelope shape and reasonable payload size;
- referential IDs are syntactically valid;
- decoded URLs satisfy the domain model's rules.

Do not use `compactMap { try? decode(...) }` for synchronized durable data. A malformed row
or record is a visible error with context, not an absent value.

---

## 10. Sync-cycle and status state machine

Replace scattered status assignments with one coordinator-owned state machine. Suggested
internal phases:

```swift
enum CloudSyncCyclePhase: Equatable, Sendable {
    case unavailable(reason: CloudUnavailableReason)
    case preparing
    case idle(lastSuccessfulCompletion: Date?)
    case fetching(cycleID: UUID)
    case sending(cycleID: UUID, remaining: Int)
    case waitingForRetry(cycleID: UUID, retryAt: Date)
    case failed(cycleID: UUID?, error: CloudSyncFailure)
}
```

The public UI status can stay simpler, but it MUST be derived from this state plus an actual
outbox query. It must not be assigned independently from multiple event handlers.

### 10.1 Sync Now

One invocation:

1. Creates or joins one cycle; repeated clicks do not create overlapping cycles.
2. Verifies account and zone readiness.
3. Requests a fetch.
4. Materializes any legacy outbox rows.
5. Requests sends and continues until the durable outbox is empty or an error/retry boundary
   is reached.
6. Rechecks the outbox after acknowledgements to catch edits made during the cycle.
7. Enters idle/Up to Date only after §4.1 is satisfied.

Concurrent automatic triggers may join or request another pass. They MUST NOT race separate
mutable `attemptedGenerations` maps or cause an older cycle to mark a newer one complete.

### 10.2 Error classification

Create a small, typed, testable error taxonomy:

- unavailable/account;
- zone removed or permission;
- transport/retriable with retry date;
- persistence;
- payload validation/serialization;
- conflict retry exhausted;
- engine-state persistence.

The UI can use concise wording. Diagnostics retain the typed category and underlying error.
Successful completion of a later cycle may clear an old transient error; merely receiving an
unrelated event may not.

### 10.3 Scope of Settings status

Either rename the row to communicate CloudKit scope or add separate passive descriptions for:

- CloudKit records: bookmarks, certificate metadata, Cloud Tabs;
- iCloud preferences: system-managed, no exact “all devices received” acknowledgement;
- certificate keys: iCloud Keychain-managed, no CloudKit-cycle acknowledgement.

Do not claim a single transactional completion across these three Apple services.

---

## 11. Account, zone, migration, and lifecycle requirements

### 11.1 Accounts

- Every domain query, outbox row, generation row, record-state row, and sync-state row is
  scoped by the hashed iCloud account identity.
- Signing out keeps that account's local rows and pending edits but stops transport.
- Signing into another account publishes only that account's dataset.
- First-account claiming of unowned rows remains one-time and transactional.
- An engine event from an obsolete account/session MUST be ignored or routed to that account;
  it may never mutate the newly active account.

Add a monotonically increasing in-memory session token or equivalent to reject callbacks from
an engine instance that has been replaced during account switching.

### 11.2 Zone deletion

Zone deletion sets writes blocked and reports a visible recovery state. Re-upload remains an
explicit user action. Recovery MUST create a new engine session, preserve local data/outbox,
recreate the zone, publish the manifest, and enqueue a fresh snapshot without reusing
generations.

### 11.3 v1 migration

Keep the existing one-shot account-scoped migration behavior. Make each phase idempotent and
ensure its phase marker advances in the same transaction as the local data it certifies.

Audit helper functions such as certificate `importOnce`: the imported body and marker MUST
share one transaction, or the body itself must be proven idempotent and tested across a crash
between body and marker.

### 11.4 Lifecycle

App activation and push notifications may request automatic cycles. App termination does not
need to drain the network, but all domain intent and engine state already delivered to the app
must be durable. Cloud Tabs payloads MUST be captured into the outbox at enqueue time so a
relaunch does not depend on reconstructing the prior in-memory tab snapshot.

---

## 12. Testing strategy

Testing only repository CRUD is insufficient. Build a deterministic, transport-neutral
multi-device simulation in `MajorTomCoreTests`.

### 12.1 Fake server

Implement a small in-memory server with:

- record ID, type, full envelope, and monotonically changing server version/change tag;
- ordered modification/deletion log and per-device fetch token;
- conditional save that can return `serverRecordChanged`;
- delete and `unknownItem` behavior;
- controllable batching, duplicated delivery, delayed delivery, reordering, and injected
  failures.

This is not a reimplementation of CloudKit. It models only the contract the coordinator
depends on.

### 12.2 Simulated device

Each test device owns:

- an independent in-memory or temporary-file `MajorTomDatabase`;
- the real repositories and reconciliation coordinator;
- a stable account hash and device ID;
- explicit `fetchOneBatch`, `sendOneBatch`, `syncToQuiescence`, crash/reopen, and account-switch
  operations.

The same coordinator methods used by production MUST be exercised. Avoid a fake-only merge
implementation.

### 12.3 Required deterministic scenarios

At minimum:

1. Mac A renames a bookmark, Sync Now completes, empty Mac B downloads the renamed value,
   and a later fetch on A cannot revert it. This test names the production-prefix bug.
2. A fetch of the old server value occurs between A's local commit and send-batch creation;
   the immutable outbox still sends the edited value.
3. A edits while generation N is in flight; late success for N does not remove N+1.
4. App crashes after local commit but before send; reopen sends exact payload.
5. App crashes after server save but before local acknowledgement; retry recognizes server
   equality and converges.
6. Incoming domain apply and metadata update fail halfway; transaction rolls back and event is
   retryable.
7. Engine-state persistence fails; status is failed and the failure is not reported as Up to
   Date.
8. Save encode/decode/record-construction failure retains outbox item.
9. Local save versus remote edit: local pending value wins and rebases on newest change tag.
10. Local delete versus remote edit: delete wins without resurrection.
11. Remote delete versus local edit: confirmed remote delete wins.
12. Server already contains pending desired value: pending generation is acknowledged.
13. Duplicate fetched modification and duplicate deletion are idempotent.
14. Child-before-parent and folder-delete-before-child-delete converge deterministically.
15. Unknown future payload field survives edit, conflict, retry, and another device fetch.
16. Two accounts with identical record UUIDs remain isolated.
17. Switch accounts while an old engine callback is delayed; it cannot touch the new account.
18. Zone deletion and explicit re-upload retain local data and converge.
19. v10 database migrates with pending rows and never reuses its highest generation.
20. Device-tabs snapshot survives a process restart before send.
21. Malformed synchronized certificate metadata produces a visible failure rather than being
   silently dropped.
22. Sync Now cannot reach Up to Date after any injected database or payload failure.

### 12.4 Schedule exploration

Add seeded randomized tests that generate short operation histories across two or three
devices, including edits, deletes, recreations, sends, fetches, crashes, and duplicates.

For every seed:

- run all devices to quiescence;
- assert server and devices converge according to delete/conflict policy;
- assert no outbox acknowledgement removed a newer generation;
- assert account isolation;
- assert unknown-field preservation;
- print the seed on failure so the schedule is reproducible.

Keep these tests deterministic and bounded for `make test`. A longer stress count MAY be
enabled through an environment variable for pre-release runs.

### 12.5 Real CloudKit validation

The simulator proves application logic, not Apple service integration. Before release, use
two signed production-like builds on separate Macs with the same iCloud account and run the
manual matrix in §15. Live tests remain opt-in and must never be required by ordinary
`make test`.

---

## 13. Diagnostics and performance

### 13.1 Structured diagnostics

Add privacy-safe signposts/logs for:

- cycle start/end and trigger;
- fetch/send batch counts and durations;
- outbox depth before/after;
- record type, operation, generation, and result category;
- conflict retry count;
- migration/account/zone transitions;
- persistence and decode failure categories.

Use hashed/redacted identifiers. Never log payload bytes or decrypted fields.

Provide enough state for a support report to answer: active account hash prefix, zone state,
migration phase, engine initialized, last successful fetch/send, current cycle phase, outbox
counts by type/operation, oldest pending age, and last failure category. A user-facing export
UI is optional; a testable diagnostic snapshot type is required.

### 13.2 Performance requirements

- Keep batches bounded (current 200-record scale is reasonable).
- Fetch pending rows and metadata without N+1 database reads.
- Compare canonical digests before decoding/reapplying unchanged known models where safe.
- Never scan all domain rows for an ordinary single-record send.
- Do not perform JSON encoding or CloudKit archive work while holding the main actor unless an
  Apple API requires it.
- Do not introduce per-keystroke CloudKit sends; repository coalescing remains authoritative.

Add a non-flaky performance characterization for preparing 200 records and reconciling a
large batch. It may record generous regression ceilings rather than microbenchmarking exact
wall time in CI.

---

## 14. Implementation phases and gates

### Phase 0 — Freeze the contract

- Add this guide to the repository.
- Record any discovered contradictions as amendments here before implementing them.
- Preserve the existing production-prefix regression fix and tests.

Gate: `git diff --check`; no production behavior changes in this phase.

### Phase 1 — Remove silent failure paths

- Replace sync-critical `try?`, decode-dropping `compactMap`, and ambiguous optional returns
  with typed outcomes.
- Ensure persistence failure does not update published domain/UI state as though it succeeded.
- Make database and payload failures drive failed status and retain pending work.
- Add focused failure-injection tests.

Gate: focused repository/model tests, then `make test`.

### Phase 2 — Durable payloads and non-reused generations

- Add v11 migration, `model_payload`, generation ledger, canonical digests, and legacy
  materialization.
- Change every local mutation path, including device tabs and manifest, to enqueue an exact
  snapshot in the same transaction.
- Prepare batches from outbox snapshots, never mutable domain rereads.
- Add migration, crash/reopen, coalescing, and late-ack tests.

Gate: all Core sync tests and migration tests, then `make test`.

### Phase 3 — Atomic reconciliation

- Add transport-neutral incoming/outgoing values and transaction-scoped reconcile APIs.
- Atomically apply fetched modifications/deletions with metadata and acknowledgements.
- Atomically process sent results.
- Enforce identity/payload validation and unknown-field preservation.
- Add idempotency and transaction-rollback tests.

Gate: deterministic scenarios 1–15, then `make test`.

### Phase 4 — Coordinator and truthful status

- Centralize cycle ownership, account-session token, triggers, retry state, and status.
- Make Sync Now perform and await the defined cycle.
- Scope Settings wording to the actual completion boundary.
- Add state-machine tests for overlap, edits during sync, errors, account switches, and stale
  callbacks.

This phase changes user-visible status semantics, so update
`major-tom-specification.md` and `architecture.md` in the same change.

Gate: status/coordinator tests, `make test`, and `Scripts/build-app.sh`.

### Phase 5 — Multi-device simulator and schedule tests

- Implement fake server and simulated devices.
- Add all deterministic scenarios and seeded schedule exploration.
- Run a larger local seed count and preserve every discovered bug as a small named regression
  test.

Gate: required scenarios 1–22 and `make test`.

### Phase 6 — Diagnostics and performance hardening

- Add structured privacy-safe logging and diagnostic snapshot.
- Remove N+1 work and main-actor CPU work found by profiling/code inspection.
- Add bounded batch/performance characterization.
- Audit v1 migration, zone recovery, KVS wording, and Keychain boundary.

Gate: `make test`, `Scripts/build-app.sh`, database `validate()`, and no privacy-sensitive test
logs.

### Phase 7 — Production-like validation

- Use signed builds with iCloud entitlements.
- Run the manual matrix in §15 on two Macs.
- Capture diagnostic snapshots when anything diverges.
- Do not ship while any data-loss, cross-account, false-success, or non-convergence issue is
  unresolved.

Gate: completed checklist with build identifiers and outcomes recorded in the release notes
or issue tracker.

---

## 15. Manual two-Mac validation matrix

For every scenario, record timestamps, build ID, initial account/zone state, final values on
both Macs, outbox depth, and displayed status.

1. **Original regression:** A renames `Station` to `PRODUCTION - Station`, clicks Sync Now,
   sees Up to Date, then an empty B restores from iCloud. B must show the renamed title and A
   must never revert.
2. A and B concurrently rename the same bookmark while offline; reconnect in both delivery
   orders and verify the documented pending-local policy without oscillation.
3. A deletes while B edits; test both reconnect orders. Delete wins.
4. A moves/reorders bookmarks while B edits titles/favicons.
5. Folder and children arrive/delete in separate batches and orders.
6. Quit immediately after an edit, relaunch, then sync.
7. Force loss of connectivity during fetch, during send, and after server acceptance; status
   must not falsely show Up to Date.
8. Repeatedly click Sync Now while editing.
9. Sign out with pending edits, use the app locally, sign back into the same account, and
   converge without losing pending intent.
10. Switch between two iCloud accounts with distinct bookmarks; no cross-publication.
11. Remove/recreate the custom zone through the supported recovery path.
12. Empty-database restore of bookmarks, certificate metadata, and Cloud Tabs.
13. Verify KVS preferences and iCloud Keychain behavior separately; do not use the CloudKit
    Up to Date label as proof of their completion.

---

## 16. Completion definition

This reliability project is complete only when:

- all invariants in §5 are represented by automated tests;
- all deterministic scenarios in §12.3 pass;
- seeded multi-device schedules pass with reproducible seeds;
- `make test` and `Scripts/build-app.sh` pass;
- architecture and product documentation describe the implemented status/conflict semantics;
- the two-Mac matrix passes using signed production-like builds;
- no sync-critical error is swallowed or translated into success;
- an independent final review finds no known data-loss, false-acknowledgement, cross-account,
  stale-callback, or false-Up-to-Date path.

An external final reviewer should concentrate on counterexamples rather than style: enumerate
every crash boundary, every event ordering, generation rollover/reuse, transaction separation,
payload corruption, stale account callback, zone reset, and retry loop. Any credible failure
schedule becomes a regression test before release.

---

## 17. Recommended economical execution

The implementation can be completed in one Terra High task if it follows the phase gates and
keeps this document in context. It should report after each phase with changed files, tests
run, and remaining risks, but continue unless a genuine product decision is required.

Use a more expensive model only for the final independent adversarial review. The reviewer
should inspect the completed diff and tests without being asked to rewrite the system, then
return a prioritized list of concrete correctness gaps. Fix any substantive finding and rerun
the relevant gates before release.
