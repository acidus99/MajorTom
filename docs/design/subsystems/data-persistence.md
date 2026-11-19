# Data Persistence

[Architecture](../architecture.md)

## Purpose and ownership

Own application databases, preferences storage, session storage, migrations,
transactions, and remote synchronization. Expose focused domain repositories, not
raw database handles or one universal storage object.

Browser owns feature behavior; Security owns authorization; Cache owns reuse policy;
Presentation owns theme interpretation. Data Persistence stores their records and
publishes committed changes. It does not decide navigation or display UI.

## Boundary and durability

Accept domain operations and return records, observations, and structured outcomes.
Callers need not know whether records live in SQLite or preferences, nor which
remote service carries them. Security owns Keychain access, Presentation owns theme
files, and import/export workflows own their selected archives and output files.

Local commits are authoritative offline and complete without waiting for remote
propagation. A synchronized mutation commits its domain change and durable outgoing
intent together. Publish committed state, retain accepted work across restart, and
report storage failure without silently claiming success. Keep I/O off the UI actor;
coalesce observation-heavy writes without losing explicit user intent.

## Data ownership and remote scope

| Data | Remote behavior |
| --- | --- |
| Bookmarks, folders, order, latest bookmark favicon observation | Account-scoped CloudKit records |
| Homepage, search provider/custom endpoint, all Quality of Life settings | iCloud Key-Value Store |
| Client identity descriptors and capsule/path assignments | Account-scoped CloudKit records |
| Actual certificate/private key | Keychain; iCloud Keychain only when requested |
| Open-tab URL/title/favicon summaries | Replaceable CloudKit summary per Mac |
| Server trust, history, input drafts, windows/tabs/Back–Forward, response bytes | Local only |
| All Appearance and Networking settings, Favorites-bar visibility, custom themes | Local only |
| Default browser registration | Per-Mac macOS state, owned by UI |
| Downloads and explicitly saved exports | User-selected destinations, outside app sync |

Keep durable user data, session/visit snapshots, and disposable responses in separate
stores. Persist domain records and exact source, never views, WebKit objects, network
tasks, or generated DOM. Store small preferences as preferences, not encoded large
collections. Private keys never enter SQLite or CloudKit payloads.

History retains one year of visits and supports URL summaries without losing older
visits during time-limited deletion. Unfinished nonsensitive input drafts expire
after fourteen days. Session startup hydrates current visit bytes and loads older
responses lazily; no cloud fetch or cache sweep belongs on the launch critical path.

## Synchronization

Synchronization is an internal component with separate service adapters. Other
subsystems use the same repositories for local and remotely received changes. Keep
service-specific records, checkpoints, conflict handling, and retries inside this
boundary; adding a provider must not require rewriting feature code.

CloudKit uses versioned encrypted payloads and a model manifest checked before
applying records. Physical deletion of synchronized intent wins over concurrent
edits. Immutable outgoing snapshots and durable generations prevent late
acknowledgements from discarding newer changes. Preserve unknown fields on retries;
apply received batches atomically before publishing. Incompatible metadata stops
sync visibly rather than resetting or erasing remote data.

Separate accounts and production/development environments, including local datasets,
outboxes, preferences, and Keychain namespaces. Sign-out preserves offline data;
switching accounts never uploads one account's data into another. Metadata absence
never authorizes deleting Keychain material. Remote tab summaries exclude `about:`
and `data:` and contain no Back/Forward state or global history.

Expose truthful status. Up to Date proves a successful fetch/send cycle with no
unresolved persistence error or pending CloudKit work, not delivery to every Mac or
completion of KVS/Keychain propagation. Sync Now requires a fresh server check;
reconnection retries recoverable offline work. Bound retries and expose actionable
failures without payloads, private data, or raw service identifiers.

## Lifecycle and verification

Migration is transactional and verified before retiring legacy data. First-account
initialization checks the server manifest before importing legacy cloud records and
never erases an existing zone merely because local state is empty. Orderly shutdown
drains accepted local writes, saves the session, and closes/checkpoints storage
without waiting for remote synchronization.

Browser coordinates confirmed deletion across live tabs and repositories. Clear
Content Cache deletes response bytes but preserves history and reading positions;
Clear Browsing Data additionally removes matching visits and drafts. Unknown legacy
dates clear conservatively. Synchronized user-data deletion is a distinct operation.

Test repositories, migrations, failure atomicity, retention, and reopen round-trips
with real temporary databases. Use controlled remote adapters and clocks for offline
edits, crash recovery, stale acknowledgements, delete-wins, account changes, and
convergence. Signed two-Mac checks cover actual CloudKit/KVS/Keychain behavior;
see [the build guide](../how-to-build.md).

Code landmarks: `MajorTomDatabase.swift`, domain `*Repository.swift` files,
`CloudIncomingBatch.swift`, and `CloudOutgoingIntent.swift` in `Sources/MajorTomCore`.
