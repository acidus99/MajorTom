# Persistence, Cache, Omnibar, and CloudKit Redesign Handoff

## Purpose

This document records the current Major Tom persistence implementation, the problems
found during review, and the proposed next architecture. It is intended for an independent
agent to challenge before more code is written.

Do not treat every item below as an approved implementation detail. The user agrees with
the broad changes listed under **Agreed direction**. The questions under **Open decisions**
still need design review.

## Product context and constraints

Major Tom is a native macOS 26 Gemini browser. Safari is the behavioral model where the
Gemini protocol does not require something different.

The important data-ownership decisions are:

- Bookmarks, bookmark folders/order, and the bookmark's most recently observed favicon
  synchronize between Macs.
- Selected reading and Gemtext rendering preferences synchronize. This includes displaying
  inline `data:` images and automatically displaying same-capsule images.
- Client-certificate descriptions and capsule/path associations synchronize through
  CloudKit. The actual identity and private key remain in Keychain and use iCloud Keychain
  only when the user requests it.
- User-approved server trust synchronizes, but certificate observations, counters, and
  cached certificate copies remain local.
- Each Mac publishes a privacy-conscious list of its open tab titles and URLs. Other Macs
  may display that list, but Back/Forward state does not synchronize.
- Global browsing history, session restoration, Back/Forward state, scroll position,
  cancelled Gemini input drafts, page cache, page-content search index, proxy configuration,
  and machine appearance remain local.
- A submitted Gemini status-10 response is an ordinary URL with a query and participates in
  history, tab state, and caching normally.
- A cancelled/dismissed status-10 draft survives quitting, remains local, is removed after
  successful submission, and expires after 14 days.
- Global URL history retains one row per URL, updates its latest visit and visit count, and
  expires after one year.
- Page cache policy is a maximum age of 120 days, a nominal total limit of 1 GiB, a maximum
  individual response of 32 MiB, and LRU eviction.
- **Startup latency is a first-class constraint.** Cache pruning, vacuuming, FTS maintenance,
  cache-size scans, and CloudKit fetches must not run on the critical path to displaying the
  initially restored windows. Startup should load only the local state and cached current
  pages needed to render those windows. Maintenance and cloud synchronization begin later.

## Agreed direction

The user has agreed that Major Tom should:

1. Move page bodies and page-content FTS out of the durable user-data database and into a
   separate disposable SQLite cache database.
2. Keep live UI state authoritative in memory.
3. Move all SQLite access off `MainActor`.
4. Persist high-frequency state asynchronously and coalesce it where exact per-event disk
   durability is unnecessary.
5. Add periodic/debounced session checkpoints instead of saving only at window close and
   termination.
6. Batch history visits and cache LRU touches.
7. Keep explicit user-intent changes durable promptly, but perform their I/O off the UI
   actor.
8. Make draft reads read-only and perform expiration outside startup and read paths.
9. Replace the current permanent-tombstone CloudKit design with native CloudKit deletion
   tracking, a bounded persisted sync-engine state, and a short-lived durable outbox if the
   review confirms that approach.
10. Build real omnibar search over bookmarks, history, URLs, page titles, and cached page
    content after the database split and persistence scheduling work.

No implementation of this follow-up redesign has been started yet.

## Current implementation

### SQLite library and database

The project uses GRDB 7.11.1 through Swift Package Manager. The durable database is:

```text
~/Library/Application Support/Major Tom/MajorTom.sqlite
```

`MajorTomDatabase` owns a GRDB `DatabasePool`, enables foreign keys, applies ordered
migrations, and exposes synchronous `read` and `write` methods. See:

- `Sources/MajorTomCore/MajorTomDatabase.swift`

The synchronous repository API is safe from data races, but it is not automatically safe
for UI responsiveness. A synchronous call made by a `@MainActor` caller does not return
until the database work finishes.

### Current tables and lifecycles

#### Framework and migration state

`grdb_migrations`

- Created and maintained by GRDB.
- Written once per applied migration.
- Never removed during normal operation.

`persistence_metadata`

- Records successful one-time imports from legacy JSON/UserDefaults storage.
- Prevents a crash or later launch from importing the same legacy material again.
- Written only by migrations/imports and retained permanently.

#### History and drafts

`history_entries`

- One row per URL, keyed by the URL string.
- Stores `visited_at` and `visit_count`.
- Upserted for every successful navigation, reload, and cached Back/Forward traversal.
- The same transaction deletes rows older than one year.
- Clear Browsing Data deletes all rows.
- `visited_at` is indexed for reverse-chronological history presentation.
- There is no history text-search index.

`gemini_input_drafts`

- One row per prompt URL.
- Written when a nonsensitive status-10 prompt is cancelled or dismissed with text.
- Deleted when the response is submitted or the stored text becomes empty.
- Expires after 14 days.
- The current read API opens a write transaction and prunes expired drafts before reading.
  This is unnecessary write amplification and must change.
- A `removeAll()` repository method exists, but no current UI command calls it.

#### Bookmarks

`bookmark_folders`

- Active local folders, with stable UUID, name, and position.
- Written for folder creation, rename, reorder, import, deletion, or incoming cloud merge.
- Removing a folder cascade-deletes its active bookmarks.

`bookmarks`

- Active local bookmarks with stable UUID, folder, title, URL, creation time, order, and
  favicon snapshot.
- Favicon state distinguishes unknown, confirmed absence, and an observed emoji.
- Written for explicit bookmark edits, incoming cloud merges, and changed favicon
  observations for the same capsule endpoint.
- The repository currently reads the complete collection and diffs it, then updates only
  changed rows. It avoids a giant blob write but is not direct single-row CRUD.

`bookmark_sync_folders`

- A second serialized representation of every synchronized folder.
- Stores a JSON payload and application-level `modifiedAt`/`deletedAt` state.
- Scanned and reconciled after local bookmark changes and incoming cloud merges.
- Folder deletion becomes a retained tombstone rather than a physical deletion.

`bookmark_sync_bookmarks`

- Equivalent sync shadow for bookmarks, including favicon data.
- Bookmark deletion becomes a retained tombstone.
- The current model retains tombstones indefinitely.

#### Session restoration

`browser_session`

- Singleton session root containing the key-window index and update time.

`browser_windows`

- Window order, frame, and selected tab.

`browser_tabs`

- Tab order, Back/Forward cursor, zoom, and titles.

`browser_tab_history`

- Ordered Back/Forward URLs and scroll positions for each tab.

Current session persistence behavior:

- `NavigationState` is in memory while the app runs.
- Back/Forward does not rewrite the session tables.
- `NativeTabCoordinator.persistSession()` currently runs primarily when a window closes and
  when the application terminates.
- Each save deletes the prior normalized session and inserts a complete new snapshot with
  new database IDs.
- This is acceptable as an off-main, infrequent snapshot, but crash recovery can lose all
  navigation since the previous close/save because there is no periodic checkpoint.
- Clear Browsing Data deletes the session root/windows, with cascades removing tabs/history.

#### Page cache and page-content FTS

`page_cache`

- Cached exact response bytes and metadata, keyed by URL.
- Includes MIME type, body, body size, completion state, response status/meta, titles,
  certificate identifier, receive time, and LRU access time.
- Written after a response completes or a stopped response has usable bytes.
- Touched on cache reads, including Back/Forward and initial-session hydration.
- Entries over 32 MiB are rejected.
- Entries older than 120 days are pruned during a subsequent store or explicit maintenance.
- The current limit sums only `body_size` and evicts LRU rows until that sum is at most
  1 GiB.
- Clear Browsing Data deletes all rows.

`page_cache_fts`

- FTS5 virtual table containing URL, title, and decoded text content.
- URL is currently declared `UNINDEXED`, so it is returned with results but cannot itself
  match a query.
- Text entries are deleted and reinserted when the corresponding page is stored.
- Matching cache removals delete the FTS row.
- SQLite creates internal FTS shadow tables such as `_data`, `_idx`, `_docsize`, and
  `_config`; application code must not edit those directly.

The nominal 1 GiB limit is not a real file-size limit. It excludes SQLite overhead, the
duplicated FTS content/index, free pages, and WAL size. Ordinary `DELETE` makes pages reusable
but generally does not return them to the filesystem. There is currently no `VACUUM`,
incremental vacuum, or explicit checkpoint policy.

#### Server trust and certificate metadata

`trusted_server_identities`

- Local effective trust record per endpoint.
- Includes local-only observations such as certificate details, last-seen time, and sighting
  count.
- New trust decisions persist immediately.
- Repeat sightings are already kept in memory and coalesced on a five-second timer.
- Explicit Forget Trust, Delete User Data, or cloud reconciliation removes rows. Bundled
  seed trust is retained where appropriate.

`server_trust_sync`

- Serialized CloudKit projection of user trust decisions.
- Does not contain local observations.
- Uses a record identity containing endpoint and fingerprint so divergent decisions can
  coexist and be detected as conflicts.
- Removed decisions become permanent tombstones.

`client_certificate_sync_descriptors`

- Despite its name, this is the only durable local table for client-certificate descriptors.
- Contains synchronized metadata and tombstones, not private keys.
- Written for create/import/edit/delete and incoming cloud merge.

`client_certificate_sync_associations`

- Durable certificate-to-capsule/path association state and tombstones.

`client_certificate_local_flags`

- Local-only indication of whether each identity was requested to use synchronizable
  Keychain storage.
- The current implementation deletes and reinserts every flag row on any certificate-state
  persistence, even if only one flag changed.

The actual certificate identity and private key remain in Keychain.

### Current UI-thread I/O

Several synchronous repository calls originate on `MainActor`:

- Every global-history record.
- Every cache store.
- Every cache fetch/touch.
- Draft read/save/remove.
- Session save on close/termination.
- Bookmark sync-shadow persistence after the actor-backed bookmark write.
- Client-certificate state persistence.

The most concerning Back/Forward path is currently approximately:

```text
Back/Forward on MainActor
  -> update in-memory NavigationState
  -> find page in tab hot set or SQLite cache
  -> synchronously touch/fetch page_cache
  -> synchronously upsert history and run one-year DELETE
  -> render
```

SQLite WAL writes are generally quick, but synchronous main-actor I/O can still stall on
FTS work, cache scans, filesystem latency, or writer contention. The database busy timeout
is five seconds, so the API shape permits a serious UI pause even if that is uncommon.

### Current omnibar status

There is no unified omnibar search implementation.

`PageCacheRepository.search()` performs FTS prefix matching over cached page title/content,
but only repository tests call it. The address field does not query it. History and bookmarks
have no text-search index, and the FTS URL column is not searchable.

## Proposed local persistence architecture

### Two databases

#### Durable database

Keep `MajorTom.sqlite` in Application Support for:

- Migration markers
- History
- Drafts
- Bookmarks/folders
- Session restoration
- Trusted server identities
- Active certificate descriptors and associations
- Local certificate flags
- Bounded CloudKit engine state, active record metadata, and pending outbox
- Durable bookmark/history omnibar metadata index

#### Disposable cache database

Create `MajorTomCache.sqlite` under the appropriate user Caches directory for:

- Cached page response bodies and metadata
- Page title/content/URL FTS
- Cache-maintenance bookkeeping

The cache database must have no foreign keys into the durable database. Certificate IDs may
be stored as opaque identifiers but must not require the durable row to exist.

Benefits:

- Clear Cache can close and recreate one disposable database, reclaiming space immediately.
- Vacuum/checkpoint policy cannot rewrite or threaten bookmarks/security state.
- Cache corruption is recoverable by discarding the cache.
- File-size accounting can include cache SQLite, WAL, and FTS rather than pretending
  `SUM(body_size)` equals disk usage.

The cache connection must be closed before deleting its database/WAL/SHM files. Recreate it
atomically through the cache actor; never remove an open SQLite file.

### Persistence actors and write policy

Introduce two non-main isolation boundaries:

```text
MainActor UI models
    |
    +-- DurableStore actor -> MajorTom.sqlite
    |
    +-- PageCacheStore actor -> MajorTomCache.sqlite
```

The actors own repository operations and serialize mutations. A `Task` created inside a
`@MainActor` context inherits the main actor unless it explicitly calls into a non-main actor;
merely wrapping the current synchronous call in `Task {}` is not sufficient.

#### Prompt, off-main persistence

Persist these user-intent changes promptly and off the main actor:

- Bookmark/folder mutation
- Trust approval/removal
- Certificate create/delete/association
- Draft cancellation and submission/removal
- Clear/delete commands

For operations whose UI claims success, await durable completion before showing success.

#### Buffered/coalesced persistence

- History: update the observable in-memory list immediately; aggregate URL visit deltas and
  latest timestamps; flush every 1-2 seconds.
- Session: mark dirty for navigation, tab/window changes, zoom, and meaningful scroll
  changes; write a full snapshot 2-5 seconds after the last change.
- Scroll: update in memory continuously, but persist only with the debounced session
  checkpoint.
- Cache LRU: retain URL-to-latest-access timestamps in memory and flush every 15-30 seconds.
- Trust sightings: preserve the existing five-second coalescing concept.
- Page body and FTS: write once after the response completes, entirely off MainActor.

Flush pending durable state when the app resigns active and before termination. Since
`applicationWillTerminate` cannot safely assume newly spawned asynchronous work will finish,
normal debounced writes should keep the dirty window small. If necessary, use AppKit's
deferred-termination flow or a small final synchronous flush only for remaining dirty state.

### Maintenance scheduling

Nothing below runs merely because the app launched:

- Cache-age pruning
- LRU size pruning
- Vacuum/incremental vacuum
- WAL checkpoint requested solely for maintenance
- FTS optimization/rebuild
- History expiration scan beyond work already required for a user-visible history operation
- Draft expiration scan
- CloudKit full fetch

Permitted triggers after initial windows render:

- An idle/background maintenance task.
- A new cache write that requires room.
- App resigning active, subject to time limits.
- An explicit Clear Cache/Clear Browsing Data action.
- A low-frequency maintenance deadline recorded from a prior run.

Startup may read the current cached page for each restored tab because that directly enables
initial rendering. It must not scan the cache or hydrate every Back/Forward entry.

## Current CloudKit design and why tombstones exist

Major Tom currently uses two custom zones:

- `MajorTomUserData`: legacy compatibility feed for older clients.
- `MajorTomUserDataV2`: new versioned feed with an `MTDataModelManifest` record.

The current adapter:

1. Queries every current record of each known type from both zones.
2. Decodes complete arrays of records.
3. Merges local and remote values by stable ID and application-level `modifiedAt`.
4. Uploads any encoded payload that differs from the server copy.
5. Mirrors the result back into the legacy zone.

Physical deletion is unsafe under this snapshot algorithm. If Mac A physically deletes a
bookmark while Mac B is offline, Mac B later sees only that the bookmark is absent remotely.
It cannot distinguish deletion from a never-uploaded local record, so its local copy can be
uploaded again. A tombstone is a surviving record with the same ID and a later timestamp that
causes the stale active record to lose the merge.

The tombstones are permanent because the implementation does not track which devices have
observed them and promises compatibility with devices that may return after an unbounded
offline interval. This is logically consistent but operationally unbounded.

## Proposed CloudKit design

### Use native incremental deletion tracking

CloudKit custom zones expose changes since a persisted server change token and explicitly
report deleted record IDs. Relevant Apple references:

- <https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation>
- <https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation/recordwithidwasdeletedblock-3z14c>
- <https://developer.apple.com/documentation/cloudkit/ckerror/changetokenexpired>

Because Major Tom targets macOS 26, prefer `CKSyncEngine` rather than manually implementing
tokens, subscriptions, batching, retry, and push scheduling:

- <https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5>
- <https://developer.apple.com/videos/play/wwdc2023/10188/>
- <https://github.com/apple/sample-cloudkit-sync-engine>

`CKSyncEngine` represents pending saves and physical deletes separately and manages
incremental server changes. Its opaque state serialization must be persisted between launches.

### Bounded local sync bookkeeping

Replace the five shadow/tombstone tables with a small generic sync layer.

`cloud_sync_state`

- Singleton containing CloudKit data-model major and the latest `CKSyncEngine` state
  serialization.
- Bounded opaque state, persisted whenever the engine supplies a state update.

`cloud_pending_changes`

- Durable transactional outbox keyed by zone/type/record ID.
- Operation is `save` or `delete`.
- Inserted in the same SQLite transaction as the corresponding local domain mutation.
- Rehydrates CKSyncEngine pending changes after a crash or launch.
- Removed after CloudKit acknowledges success.
- A row may remain while a device is offline, which is correct because delivery has not
  happened. It is not retained after acknowledgement and is therefore not a tombstone.

`cloud_record_metadata`

- At most one row per active synchronized CloudKit record.
- Stores last-known CKRecord system fields/change tag needed for conflict-safe saves.
- Updated on remote fetch and successful save.
- Removed after acknowledged record deletion.

Apple's CKSyncEngine sample retains the last known server record for this purpose.

The outbox is recommended even though CKSyncEngine serializes pending changes. The desired
atomicity is:

```text
domain mutation + pending cloud operation commit together
```

There is otherwise a crash window between committing the domain mutation, registering a
pending engine change, and receiving/persisting the engine's state-update event.

### Domain-table changes

Bookmarks:

- Remove `bookmark_sync_folders` and `bookmark_sync_bookmarks`.
- Add appropriate modification/conflict metadata to the actual folder/bookmark rows.
- A save updates the domain row and outbox in one transaction.
- A delete physically deletes the domain row and enqueues a CloudKit delete.

Client certificates:

- Rename `client_certificate_sync_descriptors` to `client_certificates`.
- Rename `client_certificate_sync_associations` to
  `client_certificate_associations`.
- Store only active domain records; physical remote deletion removes them.
- Keep private identity material solely in Keychain.
- Keep `client_certificate_local_flags`, but mutate only the affected row.

Server trust:

- Keep `trusted_server_identities` for the local effective decision and local-only
  observations.
- Remove `server_trust_sync` as a tombstone collection.
- Consider a clearly named active `cloud_trust_candidates` table. Multiple active
  endpoint/fingerprint records are actual synchronized domain state needed to detect a
  security conflict. This table contains no deleted records.
- A CloudKit deletion event removes a candidate physically.

Preferences:

- Continue using one replaceable CloudKit record, but move its transport state into the
  generic sync state/metadata rather than a separate domain shadow.

Device tabs:

- Continue one replaceable record per device.
- Remote entries older than the visibility policy remain hidden.
- Consider physically deleting sufficiently stale device records during deferred
  maintenance, without putting that maintenance on startup.

### Deletion and conflict policy

Proposed default: deletion wins over a stale or concurrent edit of the same stable record ID.

- A remote deletion removes a clean local object.
- A local pending edit does not resurrect an object deleted elsewhere.
- Recreating an object produces a new UUID and is a genuinely new CloudKit record.
- Trust conflicts remain special: multiple active fingerprints for one endpoint must be
  shown as a conflict and never auto-selected.

This avoids using device wall clocks to decide whether deletion or editing happened “later.”
The independent reviewer should challenge whether delete-wins is the desired bookmark UX.

### Expired token/full-resync policy

If CloudKit invalidates the saved sync token:

1. Preserve the durable outbox.
2. Fetch a fresh authoritative server snapshot.
3. Delete local synchronized records that are absent remotely and have no pending local
   operation.
4. Apply current server records.
5. Replay only still-pending local outbox operations.
6. Persist the new engine state.

This makes absence meaningful without retaining historical tombstones.

## Legacy compatibility problem

The v2 zone can use native physical deletion. Already-shipped clients using the legacy zone
understand only the existing snapshot/tombstone protocol.

During compatibility, a v2 deletion can enqueue two operations:

1. Physically delete the v2 record.
2. Save a legacy tombstone record in `MajorTomUserData`.

After acknowledgement, neither operation needs a local tombstone. The legacy CloudKit zone,
however, must retain its tombstone so an arbitrarily old client can understand the deletion.

There is no protocol trick that provides all three of these properties simultaneously:

- Arbitrarily old clients remain fully bidirectional forever.
- Arbitrarily long offline periods are supported.
- Legacy deletion markers can be discarded.

One constraint must be bounded.

Recommended policy:

- Keep the v2 local database and v2 zone clean and bounded.
- Isolate legacy tombstones to the legacy CloudKit zone.
- Define a compatibility window, suggested as one year or through the next major release.
- After the window, stop reading/writing the legacy zone in current releases.
- Never delete the legacy zone automatically; an old installed app may still depend on its
  data even after current releases stop mirroring it.

This policy is not yet approved. The user previously requested that older versions continue
to receive old data. Review must clarify whether that means indefinite bidirectional editing
or a bounded migration/compatibility period.

## Omnibar proposal

After separating the databases, implement a dedicated `OmnibarSearchService` that queries
and merges:

1. Durable bookmark title/URL metadata.
2. Durable history URLs with recency and visit count.
3. Disposable cached page URL/title/content FTS.

Suggested ranking:

1. Exact URL or host match.
2. URL prefix match.
3. Bookmark title match.
4. Frequently/recently visited history match.
5. Cached page-title match.
6. Cached page-content match.

Deduplicate by canonical URL and annotate sources for ranking. Do not copy cached page content
into the durable database merely to make one cross-source query. Query the durable and cache
indexes through their respective actors, then merge results in memory.

A normal B-tree primary-key index supports exact URL lookup but not arbitrary text matching.
Use FTS5 for title/content/token search and ensure URL text is actually indexed rather than
declared `UNINDEXED`.

## Why this implementation plan

The proposed plan is deliberately evolutionary rather than a rewrite. Major Tom already has
tested domain types, GRDB migrations, stable bookmark identifiers, a working Keychain layer,
and a CloudKit record vocabulary. The plan keeps those pieces and changes the boundaries that
are causing the problems: cache ownership, execution context, change tracking, and deletion
transport.

### Keep GRDB and explicit repositories

GRDB is retained because it provides predictable SQLite behavior, transactions, migrations,
and testable in-memory databases without requiring persistence objects to leak into views.
Moving to Core Data or SwiftData at the same time as changing cache, sync, and scheduling would
combine several independent migrations and make failures much harder to isolate. CloudKit
convenience alone is not enough reason to replace the local storage layer.

The repository layer should become asynchronous/actor-isolated, but the Core domain models
should remain ignorant of GRDB, CloudKit, SwiftUI, and AppKit.

### Use two databases rather than one database plus vacuuming

Durable user data and disposable page content have different ownership and recovery rules.
A single database forces cache compaction to rewrite bookmarks, trust, certificates, and
session state. It also prevents Clear Cache from reclaiming disk space cheaply.

A dedicated cache database is preferable to storing response bodies as individual files
because SQLite still gives Major Tom:

- Atomic metadata/body/FTS updates.
- One authoritative LRU catalogue.
- Consistent concurrent reads.
- Straightforward corruption checks.
- No orphan-file reconciliation after a crash.

The cost is that deleting the cache requires orderly connection shutdown, and actual disk
budgeting must include WAL and FTS. That cost is bounded inside one cache actor.

### Keep live browser state in memory and checkpoint snapshots

Windows, tabs, Back/Forward cursors, zoom, and scroll offsets are already naturally an
in-memory object graph. Treating SQLite rows as the live navigation model would add latency
and force UI behavior to conform to persistence mechanics.

A complete session snapshot every few seconds is chosen over incremental per-event SQL
because sessions are small, relationally nested, and replaceable. Snapshot transactions make
it impossible to restore half of a window arrangement. Stable incremental IDs would reduce
write volume but add bookkeeping and more crash states without a demonstrated need.

The snapshot must be built on MainActor, because it reads AppKit window state, but the SQL
transaction must run after handing an immutable `Sendable` value to the durable-store actor.

### Batch observational data, not explicit user intent

History visits, scroll updates, and LRU touches happen frequently and are advisory. Losing the
last second or two after a process crash is tolerable. Bookmarks, trust decisions, certificate
associations, and cancelled drafts are explicit user intent and deserve prompt durable writes.

This distinction avoids both extremes:

- Synchronously writing every observation in the interaction path.
- Delaying important user choices behind a generic timer that may never fire.

### Use CKSyncEngine instead of improving snapshot polling

The current implementation is rebuilding a synchronization protocol on top of CloudKit
queries: it scans complete record sets, invents permanent tombstones, compares encoded JSON,
and retries conflicts itself. This grows with historical churn rather than current user data.

CKSyncEngine is chosen because it is Apple's current private-database synchronization engine
and Major Tom's macOS 26 minimum removes deployment-version concerns. It already models
incremental changes, physical deletion, pending operations, retry, conflict events, batching,
and persisted server state. Major Tom should remain responsible for its domain merge rules,
not CloudKit transport scheduling.

### Keep a transactional outbox even with CKSyncEngine

CKSyncEngine's serialized state is necessary but is updated through engine events. A local
domain transaction cannot atomically commit a bookmark deletion and an engine callback that
has not happened yet. A small outbox makes the local invariant explicit:

```text
Every committed local cloud-visible mutation has either:
  - an acknowledged CloudKit result, or
  - a durable pending outbox operation.
```

The outbox is not intended to duplicate CKSyncEngine permanently. It closes the crash window,
repopulates missing engine pending operations after launch, and is deleted on acknowledgement.
Record IDs and operation replacement rules make retries idempotent.

### Prefer physical deletion and an authoritative resync

Permanent tombstones make cost proportional to everything the user has ever deleted. Native
CloudKit deletion makes normal cost proportional to current data plus genuinely unsent work.

When a change token expires, the server snapshot is treated as authoritative for clean local
rows. The outbox protects unsent changes. This is simpler and bounded compared with tracking
per-device deletion acknowledgements, especially because device membership is unknowable and
old Macs may never return.

### Keep omnibar indexes near the data they index

Bookmark/history metadata belongs in the durable database; cached page content belongs in the
cache database. A single materialized omnibar table containing page bodies would make cached
content durable by accident. The search service therefore queries both indexes and merges a
small result set in memory. This preserves deletion boundaries and keeps ranking policy out of
SQL schema coupling.

## Biggest challenges

### 1. Migrating sync semantics without losing or resurrecting user data

This is the highest-risk part of the plan. Existing Macs may simultaneously contain:

- Active local rows.
- Local permanent tombstones.
- V2 CloudKit tombstones.
- Legacy-zone records and tombstones.
- Changes made by an old client while the new migration is underway.
- Keychain identities that arrive before or after their CloudKit descriptors.

The migration must establish one explicit cutover state before physical deletion begins. It
must be restartable after any instruction and must never interpret “migration did not finish”
as “the user's record was deleted.” A shadow/read-compare period may be warranted before the
old local sync tables are dropped.

### 2. Making local mutation and cloud intent crash-consistent

The durable domain row and outbox operation must commit in one SQLite transaction. CKSyncEngine
state and last-known CKRecord metadata then advance in response to engine events. Incorrect
ordering can produce:

- A local edit that is never uploaded.
- A cloud save for a domain row that was rolled back.
- A delete acknowledged remotely but left pending forever locally.
- Removal of an outbox row before its server result is durable.

Every transition needs an idempotent replay rule and tests that simulate a crash between
steps.

### 3. Defining conflict behavior, especially deletion and ordering

CloudKit transport can report conflicts but cannot choose Major Tom's product semantics.
Bookmarks have mutable titles, folders, favicons, and integer ordering. Reordering a folder can
touch many records at once. Two offline Macs can reorder the same folder differently while one
also deletes a bookmark.

Delete-wins prevents stale resurrection, but it may discard a legitimate offline edit. Record-
level last-writer-wins can also lose independent field edits, and device timestamps are unsafe
under clock skew. The implementation needs deterministic, tested rules for each record type,
not one generic merge function.

### 4. Removing UI-thread I/O without introducing stale-view races

Moving work off MainActor is not just adding `Task`. UI models currently assume a repository
mutation has completed before they publish some state. After introducing actors, concurrent
local edits, remote cloud events, and delayed flushes can return out of order.

Each mutable domain needs one serialization owner and a revision/generation check so completion
of an older async operation cannot overwrite a newer in-memory state. Error reporting must also
stop using silent `try?` where failure would cause memory and disk to diverge.

### 5. Preserving fast startup during cache migration

Moving an existing large cache cannot become a one-time multi-minute launch migration. Initial
windows may refer to cached pages still stored in the old database, while new writes need to go
to the new database.

A safe approach may need a temporary dual-read strategy:

- New cache database is the only writer.
- Read new cache first.
- During a bounded transition, fall back to an old cache row only for a requested URL.
- Copy that one row lazily or render it without copying.
- Delete old cache tables during later idle maintenance after the transition is complete.

This is more complex than copying every cache row during schema migration, but it protects the
explicit first-window latency requirement.

### 6. Enforcing a real cache disk limit

SQLite database size, free pages, WAL, and FTS amplification do not move in lockstep with live
body sizes. File-size checks can also race with an active transaction or checkpoint.

The cache needs a defined invariant: whether 1 GiB means logical live content, allocated main
database bytes, or total database plus WAL/SHM bytes. The user's original wording indicates a
physical footprint expectation. The implementation should maintain headroom below 1 GiB,
evict using live estimates, checkpoint at a safe maintenance point, and recreate the cache if
fragmentation prevents reclaiming sufficient space.

### 7. Supporting old clients without making legacy cost permanent

An old app cannot understand a protocol added after it shipped. Indefinite bidirectional
compatibility forces the legacy zone to retain the deletion information that those clients
require. A bounded compatibility promise is therefore a product decision, not merely a schema
implementation detail.

### 8. Security state arriving in different channels

Certificate metadata arrives through CloudKit; the private identity arrives through iCloud
Keychain on its own schedule. Major Tom must represent “known certificate but identity not yet
available” without deleting metadata, repeatedly prompting incorrectly, or sending the wrong
identity. Trust conflicts must never be resolved by generic last-writer-wins behavior.

## Alternatives considered and rejected

### Keep the current snapshot queries and periodically purge tombstones

Rejected because deletion safety would depend on guessing how long a Mac can remain offline.
Purging after 30, 120, or 365 days still allows a stale device to resurrect data after that
period. Per-device acknowledgements would require reliable device membership and retirement,
which CloudKit does not provide as a simple primitive.

### Physically delete records but continue querying current snapshots

Rejected because absence is ambiguous. A stale clean local row and a new unsent local row both
look like “local exists, server missing” unless a durable dirty/outbox distinction and an
authoritative-resync rule are introduced. At that point an incremental engine is the clearer
solution.

### Use one SQLite database and run `VACUUM` after Clear Cache

Rejected because vacuum rewrites durable user data to compact disposable content, may require
substantial temporary space, and couples cache failure/recovery to bookmarks and trust.

### Store every cached body as a standalone file

Rejected as the default because atomic metadata/body/FTS updates become a multi-resource
transaction. Crashes can leave orphan bodies or index entries and require reconciliation.
A separate SQLite cache retains simple transactional ownership. Very large bodies are already
bounded at 32 MiB, which is a practical SQLite BLOB size.

### Persist every navigation event immediately on a background queue

Better than main-thread writes, but rejected as the complete policy because it still creates
unnecessary transactions and WAL/fsync pressure for history, scroll, and LRU observations.
Batching those observations gives equivalent product behavior with fewer writes.

### Keep everything only in memory until normal termination

Rejected because crashes, forced termination, and power loss are normal failure modes for a
browser. Explicit user intent must not depend on receiving a graceful termination callback,
and session loss should be bounded to a few seconds.

### Replace GRDB with Core Data/SwiftData for CloudKit integration

Rejected for this change because it combines a local persistence rewrite with the CloudKit
protocol migration and makes it harder to preserve exact row-level behavior. Major Tom also
needs a disposable FTS/cache database with explicit size and recreation policy; that work does
not disappear behind an object-graph framework.

### Use one giant synchronized JSON record again

Rejected because every small change rewrites the full payload, creates coarse conflicts,
prevents record-level deletion, and recreates the slow import/sync behavior that initiated this
project.

## Adversarial analysis: what could go wrong

The following cases should be treated as design inputs, not rare edge cases.

| Failure or hostile condition | What can go wrong | Required defense and test |
|---|---|---|
| Process crashes immediately after a local bookmark edit | UI showed success but no cloud operation survives | Domain mutation and outbox save occur in one transaction; kill/relaunch test before CKSyncEngine state update |
| Process crashes after CloudKit accepts a save but before local acknowledgement | Operation is retried | Stable record ID and idempotent save; server response updates metadata; duplicate retry must not duplicate domain data |
| Process crashes after CloudKit accepts a delete | Delete remains pending locally | Retried physical delete treats `unknownItem` as success, then removes outbox row |
| Outbox row is removed before acknowledgement is durable | A failed or unknown operation is lost | Commit last-known server metadata/ack result and outbox removal in one local transaction |
| CKSyncEngine serialized state is corrupt or missing | Change tokens and pending-engine operations disappear | Rebuild engine state, preserve/replay durable outbox, perform authoritative resync; never delete dirty local rows |
| CloudKit change token expires | Full remote history cannot be incrementally fetched | Fresh authoritative snapshot plus outbox replay; explicit tests with clean, dirty-save, and dirty-delete rows |
| iCloud account changes or signs out | Data from one account can leak into or merge with another account | Associate sync state with account identity; quarantine/clear cloud mirror and tokens on account change while preserving clearly local-only data according to product policy |
| User resets encrypted CloudKit data or zone disappears | App may recreate an empty zone and upload stale local state | Treat zone/account reset as a distinct destructive event; require a defined recovery policy rather than automatic blind reupload |
| Two offline Macs edit the same bookmark | One edit silently overwrites another | Deterministic per-domain conflict rule; exercise title, URL, folder, favicon, and order conflicts separately |
| One Mac deletes while another edits offline | Deleted item is resurrected or valid edit disappears unexpectedly | Implement and document delete-wins or alternative; never use untrusted wall-clock ordering alone |
| Two Macs reorder the same folder | Duplicate positions or unstable order oscillation | Deterministic normalization/tie-break; transactionally update ordering; repeated merge must converge |
| Folder deletion races with bookmark move into that folder | Orphan bookmark or unexpected cascade | Foreign keys locally; define cloud merge order and delete-wins relationship; test records arriving in either order |
| Favicon refresh races with bookmark deletion/edit | Deleted bookmark returns or stale favicon overwrites new URL | Mutations operate by stable ID and revision; favicon update verifies current endpoint inside the durable transaction |
| Old client writes to the legacy zone after v2 deletion | V2 object may be resurrected | Compatibility rule must distinguish stale legacy active data from allowed legacy edit; bounded support period strongly preferred |
| Legacy zone contains years of tombstones | New app startup/sync becomes slow again | Never query legacy zone on initial rendering; isolate compatibility sync and retire it on a defined schedule |
| CloudKit server conflict omits expected server record | Local resolver cannot safely merge | Preserve pending operation, log/report failure, refetch record/zone; do not force overwrite security-sensitive data |
| Keychain identity arrives after certificate descriptor | UI reports unusable identity or repeatedly prompts | Model descriptor availability separately and refresh Keychain asynchronously; no deletion based only on temporary absence |
| Keychain identity never arrives | Metadata persists forever without usable key | Show unavailable status and user-controlled cleanup; do not claim synchronization succeeded for usable identity |
| Conflicting trust fingerprints arrive | Generic last-writer-wins silently trusts one | Persist active candidates, block automatic import, surface conflict, retain local effective decision until explicit approval |
| Cache database is deleted while a connection is open | Undefined SQLite behavior, stale handles, WAL files left behind | Cache actor stops users, closes pool, removes database/WAL/SHM, recreates, then publishes new handle |
| Clear Cache occurs during a page write or search | Cleared data reappears or operation crashes | Actor serialization and cache generation IDs; operations from an old generation cannot commit into the recreated cache |
| Disk becomes full during cache store | Transaction or FTS update fails | Atomic rollback; UI continues with in-memory page; schedule eviction/recreation; never damage durable database |
| Disk becomes full during durable mutation | User intent exists only in memory | Surface error for explicit mutations, retain retryable dirty state where safe, never report success prematurely |
| FTS decoding/indexing a near-32-MiB page is expensive | CPU/memory spike and delayed UI | Off-main bounded work, cancellation/backpressure, exclude unsupported/binary bodies, performance test worst-case text |
| Cache WAL pushes total footprint above 1 GiB | Nominal limit is violated | Account for main file plus WAL with headroom; checkpoint/recreate only in deferred maintenance |
| Deferred maintenance never gets idle time | Expired cache/history/drafts linger | Also trigger bounded maintenance from writes and lifecycle transitions; each pass has a strict work/time budget |
| Session debounce is continually reset by scroll events | Session never reaches disk | Throttle scroll separately and impose a maximum checkpoint interval in addition to trailing debounce |
| App terminates before async checkpoint finishes | Recent session/history is lost | Regular checkpoints bound loss; deferred AppKit termination or final bounded flush handles remaining dirty state |
| Older async database completion arrives after a newer edit | UI/disk regresses to stale state | Single domain actor plus monotonic local revisions; discard stale completion publications |
| Cache migration is interrupted | Pages exist partly in old and new stores | New store is sole writer; idempotent lazy fallback/copy; migration marker only after safe completion |
| Durable schema migration is interrupted | Tables or sync state are half converted | GRDB transactional migrations, pre-migration backup where necessary, restart tests at migration boundaries |
| App is downgraded after local v2 migration | Old app cannot read new SQLite state | Old app continues using its legacy storage/zone where feasible; document downgrade limits; never overwrite legacy cloud data during migration |
| Malformed or future-version encrypted CloudKit payload arrives | Decode failure silently drops data or corrupts local state | Manifest gate before model fetch, strict decoding/logging, quarantine incompatible records, no partial destructive apply |
| Capsule-controlled data reaches SQL/FTS | Injection or pathological token input | Bound parameters exclusively, treat content as data, size limits, no dynamic SQL from URLs/content |
| Cloud push notifications are delayed or absent | Devices appear inconsistent | Manual/activation fetch remains available after first rendering; correctness cannot depend solely on push delivery |

## Conditions that would invalidate this recommendation

The reviewing agent should recommend a different design if it can demonstrate any of the
following:

- CKSyncEngine cannot preserve the required v2 manifest/zone version gate.
- Its state and event model cannot be reconciled safely with a transactional local outbox.
- Physical delete events cannot support Major Tom's required conflict semantics after an
  authoritative resync.
- A separate SQLite cache cannot be closed/recreated safely within the app's shared model
  lifetime.
- Session snapshots are empirically large enough that full transactional replacement causes
  unacceptable background or termination latency.
- The legacy compatibility guarantee is truly indefinite and bidirectional, in which case a
  bounded v2 design still works but the legacy-zone tombstone cost must be accepted and
  isolated rather than described as removable.

## Proposed implementation order after review

1. Add tests that capture current migration and behavior before changing schemas.
2. Introduce non-main durable/cache persistence actors and async repository boundaries.
3. Create the separate cache database and migrate/copy existing cache rows without delaying
   initial rendering. The migration itself may need deferred execution or a one-time strategy
   that reads the old current pages first and moves the remainder later.
4. Change Clear Cache/Clear Browsing Data to close and recreate the cache database safely.
5. Implement buffered history, session checkpoints, and cache-touch batching.
6. Move drafts, bookmark sync bookkeeping, certificate persistence, and remaining SQLite
   calls off MainActor.
7. Introduce the generic CloudKit state/metadata/outbox tables.
8. Replace v2 snapshot polling with CKSyncEngine incremental changes and physical deletion.
9. Migrate current active sync records into domain rows and remove v2 local tombstones.
10. Preserve the legacy zone according to the compatibility policy chosen after review.
11. Add durable bookmark/history search indexing, cached page URL/title/content FTS, and the
    unified omnibar search service/UI.
12. Update architecture, product specification, build/CloudKit setup, and the manual two-Mac
    test matrix.

Each stage must remain independently testable and should avoid a single destructive migration
that cannot recover after interruption.

## Verification expectations

After each code stage:

- Run `make test`.
- Run `make dev` for app-target or packaging changes.
- Do not use bare `swift test`/`swift build` without `--disable-index-store`.
- Do not run cache maintenance during startup performance tests.
- Verify no SQLite call in navigation, scroll, or address-field interaction synchronously
  blocks MainActor.
- Add behavioral XCTest coverage rather than assertions that copy implementation literals.

CloudKit verification requires a development-signed app and two Macs or equivalent instances:

- Physical deletion propagates without resurrection.
- Offline pending changes survive restart.
- A crash between domain mutation and engine notification does not lose the pending operation.
- Token-expiration/full-resync behavior preserves outbox changes and removes clean stale rows.
- Conflicting server-trust fingerprints never become silent trust.
- v1-to-v2 and v2-to-v1 behavior matches the chosen compatibility policy.
- Local-only history, drafts, session, and cache never appear on the other Mac.

Performance verification should measure:

- Time from launch to first restored window/page.
- Main-thread stalls during Back/Forward and rapid navigation.
- Session checkpoint cost with many windows/tabs/history entries.
- Cache write/FTS cost for a near-32-MiB textual response.
- Cache-file and WAL size before/after eviction and explicit Clear Cache.
- Incremental CloudKit work with a large legacy zone and many historical deletions.

## Questions for the reviewing agent

1. Is CKSyncEngine the correct macOS 26 API here, or is there a concrete reason to retain a
   hand-written change-token engine?
2. Does the proposed durable outbox correctly close the crash window around CKSyncEngine
   state updates? Is there a simpler atomic pattern with equivalent guarantees?
3. Should CKRecord system fields live in one generic `cloud_record_metadata` table or in the
   synchronized domain rows?
4. Is delete-wins correct for bookmark/folder/certificate conflicts? If not, propose a rule
   that cannot resurrect stale data through device clock skew.
5. What local representation best preserves multiple active server-trust fingerprints without
   conflating local observations and cloud decisions?
6. How should an expired-token authoritative resync distinguish clean rows from unsent local
   creations and edits?
7. What is the least disruptive migration from permanent v2 tombstones to physical deletion?
8. What exact old-client compatibility guarantee is feasible without an indefinitely growing
   legacy zone?
9. Should the cache use incremental vacuum, recreate-at-threshold, or file-size headroom plus
   periodic recreation? Account for FTS and WAL, not only body bytes.
10. How should the existing cache be moved without adding work to first-window startup?
11. Are the proposed debounce intervals reasonable, and what AppKit termination mechanism
    should guarantee the final durable flush?
12. Are there other synchronous MainActor persistence paths or full-collection scans not
    identified in this handoff?

## Important repository files

- `Sources/MajorTomCore/MajorTomDatabase.swift`
- `Sources/MajorTomCore/PageCacheRepository.swift`
- `Sources/MajorTomCore/SessionRepository.swift`
- `Sources/MajorTomCore/BrowsingHistoryRepository.swift`
- `Sources/MajorTomCore/GeminiInputDraftRepository.swift`
- `Sources/MajorTomCore/BookmarkRepository.swift`
- `Sources/MajorTomCore/BookmarkSyncRepository.swift`
- `Sources/MajorTomCore/SecuritySyncRepository.swift`
- `Sources/MajorTomCore/TrustedIdentityRepository.swift`
- `Sources/MajorTomCore/CloudSyncModels.swift`
- `Sources/MajorTom/BrowserPersistence.swift`
- `Sources/MajorTom/BookmarksModel.swift`
- `Sources/MajorTom/ClientCertificateStore.swift`
- `Sources/MajorTom/ICloudSyncStore.swift`
- `Sources/MajorTom/MajorTomApp.swift`
- `Sources/MajorTom/StreamingWebViewPrototype.swift`
- `docs/design/major-tom-specification.md`
- `docs/design/architecture.md`
- `docs/design/how-to-build.md`

## Current verification baseline

Before this follow-up design discussion, the existing implementation completed:

```text
make dev
374 tests executed
1 test skipped
0 failures
development app bundle built and ad-hoc signed
```

Those results validate the current implementation, not the redesign proposed in this file.
