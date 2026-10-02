# Cloud sync adversarial review — 2026-09-15

Release status: **blocked pending integration validation**. The earlier handoff's claim
that only live validation remained was incorrect. The counterexamples below were repaired
in the working tree, without committing. A signed first-Mac check has passed; the two-Mac
matrix has not. Passing repository tests alone is not release certification.

## Confirmed counterexamples in the reviewed working tree

1. **P0 — empty Mac deletes the shared zone.** A finishes syncing; B opens a new database.
   B's local migration marker is absent, so `activateAccount` reads stale v1 and deletes
   `MajorTomUserDataV2` without checking the server manifest. This erases A's accepted data.
   Missing test: fresh-device activation against an existing ready manifest.
2. **P1 — account filters do not isolate primary keys.** A owns UUID X. B imports X with
   different content. `ON CONFLICT(id)` updates the row's account to B, removing A's local
   data. Bookmark folder foreign keys can also cross account boundaries. Missing test:
   identical folder/bookmark/certificate UUIDs in two accounts.
3. **P1 — fetched data and tokens are not atomic.** Apply bookmarks, fail certificate decode
   or metadata write, then accept a subsequent engine state update. Part of the event is
   committed, the rest can be skipped permanently. Missing test: a failing delivered batch,
   followed by state update, crash and reopen.
4. **P1 — asynchronous bookmark publication replays stale snapshots.** Remote apply commits R
   and queues a model task; a local edit commits L; that task calls `store.replace(R)`, which
   is a local write that enqueues R. There is also a second local replacement through
   `updateBookmarks`. Missing test: production model/store delivery interleaved with edits.
5. **P1 — session protection omits outgoing callbacks and detached tasks.** Replace A's
   engine with B's; delayed A `nextRecordZoneChangeBatch` reads B's active account and returns
   B's payloads to A's engine. Delayed `refresh` completion changes B's cycle/status.
   Missing test: both callbacks after account replacement.
6. **P1 — false completion and hidden failures.** Ignore `didFetchRecordZoneChanges.error`,
   treat `didFetchChanges`/`didSendChanges` as success, and allow completion while writes are
   blocked or zone removed. Independent status assignments erase failures. Missing tests:
   failed zone fetch and zone removal followed by completion callbacks.
7. **P1 — in-flight attempt can be overwritten under overlapping preparation.** Build generation N; build N+1 for the same
   record before N's callback; the name-only map now acknowledges N+1 for N's result.
   Missing test: overlapping preparation and reversed callbacks using production code.
   This is an adapter counterexample, not a claim that the installed SDK was observed
   overlapping those calls. The shared session ledger now rejects this schedule regardless.
8. **P1 — retries can spin or starve.** Repeated conflicts requeue without a limit; an invalid
   early item remains in every first-200 read with `hasPendingUntrackedChanges` set. Missing
   tests: persistent conflict and corrupt item ahead of a healthy later batch.
9. **P1 — fetched ordering is rewritten.** A partial batch's server fractional keys are used
   for in-memory sorting, then `replaceFromCloud` regenerates all keys with `initial(count:)`.
   The next partial batch compares server keys against fabricated local keys. Missing test:
   successive partial batches with nonuniform server order keys.
10. **P1 — deletion and publication gaps.** Fetched folder deletion preserves children in
    SQLite but their pending payloads can still reference the deleted folder. Successful
    deletes retain obsolete system fields. Missing tests: parent deletion with pending
    child edits, delete/recreate and delayed old metadata.
11. **P1 — corruption and migration failures remain silent.** Legacy decoding skips failures;
    engine-state decoding falls back to nil; certificate persistence falls back to defaults;
    nonpositive generations are accepted on read and Int64 overflow can trap on enqueue.
    Missing tests: each fault followed by restart and Sync Now.
12. **P1 — tabs cache leaks across accounts.** One unscoped defaults cache is loaded at
    startup and merged after account switch. Missing test: A tabs followed by B sign-in.
13. **P1 — lost create callback resurrects a confirmed deletion.** Prepare a create with
    no server change tag; receive deletion; the already-dispatched create reaches the server;
    crash before acknowledgement; fetch its echo after restart. Merely removing pending intent
    does not cancel an in-flight create. Local deletion fences now compensate both late save
    callbacks and fetched echoes where this Mac had pending intent. An uninvolved observer
    still accepts later genuine recreations, including owner-published Cloud Tabs.
14. **P1 — legacy import body and marker have a crash gap.** Import bookmarks, crash before
    certificate import/marker, edit locally, restart. Reimport treated local rows as ancient
    and could reapply v1. The body and marker now commit together and local pending intent
    is excluded from legacy replacement.
15. **P1 — certificate publication races local edits.** Commit incoming certificate B while
    the UI still shows only A; edit A; whole-catalogue save removes B. A stale UI object could
    also recreate a remotely deleted identity. Local edits now patch only changed records
    against current rows in one writer transaction; alias deletes are in that transaction.
16. **P1 — initial sign-in creates an engine restart loop (observed live).** Construct an
    engine for A; it reports its initial sign-in for A; the handler constructs another engine;
    repeat. The first signed run logged repeated cancellations and never drained. Same-account
    initial events now leave the bound engine in place; the rerun fetched and acknowledged.
17. **P2 — current sync fetches every legacy zone (observed live).** The first successful
    fetch downloaded hundreds of legacy trust records before reaching send. Manual and
    scheduled fetch options now restrict record fetching to `MajorTomUserDataV2`.
18. **P2 — shutdown publishes tabs after closing SQLite (observed live).** Window teardown
    queued smaller tab snapshots after the database closed. Shutdown now drains queued
    bookmark writes, stops new tab publications, invalidates the engine, and awaits operation
    cancellation before closing the pool. It does not drain the network outbox.
19. **P1 — an overtaken journal worker replays an already-consumed batch.** Two workers
    decode N; the fast one applies N and N+1; the slow one then applies N again, rolling
    clean rows backward. Replay now checks that its batch still exists inside the writer
    transaction. A semaphore-controlled test forces this exact interleaving.
20. **P1 — a newer fetched server version does not invalidate an older success.** Send N
    succeeds; another Mac writes R; fetch R while N is pending; finally receive N's success.
    Previously it cleared the only intent even though the known server now contained R.
    A different fetched server version now rebases retained intent to a fresh generation;
    the older callback cannot acknowledge it. A named two-device test covers both the late
    callback and the conditional retry. Exact duplicate observations do not keep rebasing.
21. **P1 — fetched equality is not an in-flight-write barrier.** Server contains X; prepare
    a save of N; locally revert to X; fetch X and clear pending intent; then N reaches the
    server using X's still-valid change tag. The desired X is lost. Fetched equality no
    longer acknowledges pending saves: an exact-generation save or equal conflict result
    must confirm them. The guide permits, but does not require, the equality shortcut.
22. **P1 — startup ownership claim can overtake local import/writes.** A queued unowned
    import/edit finishes after the claim transaction, leaving unsynced rows behind. The
    first-account claim now waits for model initialization and accepted writes, briefly
    rejects new edits during claim, and binds model ownership before releasing that barrier.
    Transaction rollback tests cover the claim; a fresh signed-device restore is the app-level
    validation for initialization ordering.

## Coverage limitation

The old simulator uses a fake-only whole-collection apply path, infers deletion from missing
records, has no conditional saves/change tokens, does not reopen a database in its crash
test, and never invokes production status. Its three passing tests cannot prove the 22
required scenarios, seeded scheduling, or phase 3–6 gates. No signed two-Mac evidence was
recorded. Every remaining gap must be tracked explicitly before this project is called
complete.

## Verification and fixes

The previous fake-only merge simulator was replaced. Its replacement uses production
`preparedChanges`, `acceptSave`, `journal`, and `replayIncoming`, with independent file-backed
databases, actual close/reopen, conditional server versions, explicit deletion events, and
duplicate deliveries. Ordinary tests run 24 seeds; the local stress gate runs 150 seeds with
30 operations each, including rename, delete, recreate, send, fetch, reopen, and replay.

| Finding / guide boundary | Repair and regression evidence |
| --- | --- |
| Original prefix loss, stale fetch, crash before/after acceptance | `CloudSyncReliabilitySimulationTests`: production-prefix restore, immutable intent, real reopen, conflict/unknown-field, both deletion directions |
| Generation reuse, corruption, exact acknowledgement | Independent ledger, immutable payload/digest validation, overflow/high-water tests, late-N acknowledgement test |
| Account UUID collision and foreign parent | v12 account-qualified unique keys and composite FK; identical bookmark/certificate UUID and cross-account FK tests |
| Partial receive / advanced token | v13 incoming journal; injected transaction failure retains batch, domain/metadata/ack roll back together; malformed certificate rejects entire batch |
| Late-create resurrection | v14 local deletion fences; both callback and lost-callback/fetched-echo schedules tested after reopen |
| Stale publication / local mutation | Bookmark and certificate operations read latest rows under the writer lock; async certificate commits publish only durable results; named stale catalogue, stale deleted-object, and transaction-failure tests |
| Stale engine / overlapping attempt / old async cleanup | Production `CloudSyncSession` used by adapter; duplicate reservation and old-session cleanup tests |
| False Up to Date | Awaited fetch/send proof, invalidation on new work, outbox/journal/zone/checkpoint/in-flight guards; cycle tests reject every missing condition |
| Checkpoint persistence failure | Injected engine-state write failure retains previous checkpoint; adapter freezes token persistence and reports failure |
| Overtaken replay / delayed success / unsafe fetched equality | Forced-interleaving journal test and two named conditional-server schedules; only own-generation save/conflict results acknowledge saves |
| Parent order / pending-parent repair | Direct per-record SQL preserves fractional keys; child-before-parent, title edit with missing parent, and parent deletion rebasing tests |
| Favicon conflicts | Pending title retained, newer favicon rebased on conflict/fetch; SQLite timestamp rounding cannot create echo uploads |
| Migration / recovery | One transactional ownership claim and v1 body/marker; ready marker/export snapshot transaction; zone recreation clears old system fields and advances generations; fault-injection tests |
| Payload versions | Invalid versions rejected, future schema tag and unknown top-level fields retained; existing payload round-trip tests |
| Diagnostics / batching | Read-only aggregate script, typed runtime diagnostic snapshot, bounded 200-record preparation and large-batch characterization |

The signed Development app on Mac #1 restored bookmarks, certificate metadata, and remote
tabs from the existing v2 zone. It then created a disposable Favorites bookmark, synced its
baseline, renamed it to **PRODUCTION - Station - Sync Reliability**, and completed Sync Now.
At 2026-09-15 15:04:52 UTC, the UI said Up to date, the active-account outbox and incoming
journal were empty, and persisted server payload metadata matched the renamed local title.
This is evidence of this Mac's acknowledgement, **not** independent proof of Mac #2 restore.

## Remaining validation limits

Final local commands passed: ordinary `make test` and a separate
`MAJOR_TOM_SYNC_SEEDS=150 make test` run: **536 Core tests (one opt-in live-network test
skipped), 20 AppKit tests, zero failures**. `Scripts/build-app.sh`, strict code-signature
verification, diagnostics-script syntax checking, and `git diff --check` passed. The final
signed artifact's hash and final post-relaunch acknowledgement check are in the validation
document. At 2026-09-15 15:45:25 UTC the final binary showed Up to date, empty outbox/journal,
and the intact prefixed bookmark matching saved server metadata. No production
release/notarization/publishing command was run.

- Run the two-Mac checklist in `cloud-sync-validation.md`; none of its cross-device results
  may be inferred from the first-Mac result. Account changes, network loss, explicit zone
  recovery, and Keychain behavior still need signed-device exercises.
- Session/cycle tests use the same production Core logic, but are not an exhaustive model
  of CKSyncEngine callback ordering. The live initial-sign-in finding demonstrates that
  limitation. CKRecord reconstruction failure is caught in production; its full SDK path
  is not injected by the transport-neutral simulator.
- The 200-record characterization is a generous regression bound, not a profile of every
  workload. Transport construction, received/save-result serialization, checkpoint encoding,
  certificate mutation/import encoding, snapshot exports, preference encoding, and tab writes
  now run off the main actor. Small catalogue reads/decodes and checkpoint database commits
  still run synchronously; large real-world UI workloads remain worth profiling. Shutdown
  drains local writes, not network propagation. Completion also checks accepted local writes
  that have not yet entered the outbox.
- Missing/incompatible manifests in an existing zone fail closed. There is no automatic
  destructive experimental-zone cutover or cloud migration-lease takeover. Performing such
  a reset would require explicit authorization; a fresh database never supplies it.
- No production zone was reset, no private keys were deleted, and no commit was made.

The guide therefore remains **not fully complete**, even though the concrete correctness
counterexamples above have fixes and final Mac #1 validation passed. The second-Mac test
and the remaining signed-device matrix are the next gate, not inferred successes.

Update at 2026-09-15 16:07:55 UTC: the user's intended second-Mac screenshot shows the
prefixed test bookmark and Up to date. Mac #1 then completed another Sync Now without
reversion, with empty outbox/journal and matching server metadata. Confirmation that the
empty-cache setup was repeated on that intended Mac is still required; the user initially
attempted launch on a different Mac. This evidence does not complete the broader matrix.

Update at 2026-09-15 16:12:20 UTC: after repeating the setup on the correct Mac, the user
reported initially empty Favorites followed by restoration of the prefixed bookmark.
Mac #1's subsequent Sync Now retained the title, showed Up to date, and had empty
outbox/journal. Fresh-restore behavior and non-reversion passed; Mac #2's final status on
this fresh run is still to be confirmed. The broader matrix remains open.

The user then confirmed Mac #2 was Up to date, completing the original fresh-restore and
non-reversion scenario. A subsequent B-to-A reorder check is unresolved: after B reported
moving the fixture first, A's Sync Now at 16:16:48 UTC still showed it last (sixth of six),
with unchanged title/membership and empty outbox/journal. Obtain B's actual position/status
before attributing this discrepancy to persistence, transport, or the drag action.

Reorder follow-up: B's screenshot confirmed first position and Up to date. A subsequently
received six bookmark records in its 16:17:32 UTC activation fetch (about 45 seconds after
the earlier manual fetch). The fixture is now first in both A's menu and SQLite; its title
and all 11 bookmark IDs/titles/URLs are unchanged, with empty queues. This is delayed
convergence, not a demonstrated permanent ordering failure. B's acknowledgement timeline
was not captured, so the cause of the delay/first fetch miss remains unproven.

### Open live finding: manual fetch can return without server discovery

The next B-to-A rename exposed a separate completion/receive concern. Mac #2's supplied
SQL proves its renamed fixture and saved server payload both contain
`MAC2 - Station - Sync Reliability`, with no pending operation. Mac #1 retained the old
title after manual fetches and showed Up to date. A live framework trace later showed a
foreground notification initiating database discovery, followed by receipt and successful
application of the rename at 2026-09-15 16:37:39 UTC. No pending local rename was lost.

A subsequent explicit Sync Now at 16:39:00 UTC again completed without making a database
or zone request. The awaited SDK call and lifecycle callbacks therefore cannot be used as
independent proof of a fresh server check on this observed runtime. The root fetch-scope
experiment (`.all` instead of the user zone) did not fix it and was removed. Do not blame
the conflict resolver or claim a framework defect without a smaller SDK reproduction.

Missing test: with an initialized receiver whose engine has no known dirty zones, withhold
its remote-change notification, acknowledge a new bookmark version on a second device,
then click Sync Now while the receiver stays foreground. Verify actual receipt, completion
status, and what requests were made. A fake transport that simply returns the latest records
does not cover this schedule. Also test relaunch with the saved clean engine checkpoint.

The rename eventually converged, but this manual-refresh validation issue remains open.
Detailed timeline and the experiment's binary identity are in `cloud-sync-validation.md`.

Follow-up implementation: a separately signed SDK-only probe reproduced no database
request with `automaticallySync = true` and a clean checkpoint. The identical checkpoint
with `automaticallySync = false` made database requests on both repeated fetches. The probe
has no GRDB, model publication, or record writes; user-initiated QoS did not fix the automatic
case. See `Scripts/run-cloud-sync-fetch-probe.sh` and its Swift source; run only with the
Development app quit and its database fully checkpointed, capturing CloudKit operation logs.

Explicit/activation refreshes now retire and drain the old transport, load its last durable
checkpoint into a nonautomatic engine, await the requested cycle, then restore automatic
scheduling. No opaque state is reset and there is no competing incoming cursor. Delegate
draining includes already-started receive/acknowledgement work and checkpoint work; account
changes and shutdown invalidate the handoff. Shutdown also drains inter-engine journal
recovery. Outbox reads fail closed. Queued clicks request another fresh cycle, and explicit
cycles cannot complete with a cached-only fetch proof. Zone recovery creates the explicitly
authorized zone before fetching it, rather than depending on an automatic create racing the
fetch. The durable never-established state retains crash recovery authority.

Signed Mac #1 checks at 17:38:00 and 17:38:18 UTC each issued a database request and restored
automatic mode afterward; empty queues and Up to date followed, without an ongoing loop.
Those checks establish the clean-checkpoint request behavior, not completion of the entire
two-device matrix. New barrier/cycle tests plus the 150-seed suite pass (540 Core tests,
one opt-in live test skipped; 20 AppKit tests). The next gate is a new acknowledged B rename
received while A stays foreground, followed by the remaining signed-device schedules.

One-click receive gate passed at 2026-09-15 17:53:26 UTC on the final replacement build:
A still had the old title before the click; a single `trigger=user` cycle made database
and zone requests, received the newly renamed fixture, and restored automatic mode in
about one second. Local/server payloads agree, order is unchanged, and queues are empty.
No activation-triggered fetch preceded receipt. See the validation document for precise
timestamps. Offline conflicts, deletion races, and the remaining device matrix are still open.

An additional signed schedule passed at 2026-09-15 18:05:37 UTC: B edited the fixture
offline, A made and acknowledged a conflicting rename, then B reconnected with its pending
edit. B's screenshot retained that edit and reported Up to date; one explicit fetch on A
independently received the B title with matching local/server payload and empty queues.
The pending edit was not clobbered by A's acknowledged version. This covers pending local
intent versus an acknowledged remote edit, not both-offline conflicts in both delivery
orders or automatic delivery latency. The broader matrix remains open.
