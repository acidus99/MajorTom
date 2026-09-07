# Major Tom Architecture

Status: Current design

Major Tom is a macOS 26 Swift application. This document records the durable boundaries in the implementation. User-facing behavior is defined by the [product specification](major-tom-specification.md).

## Design goals

- Keep protocol, trust, parsing, persistence, and presentation independently testable.
- Stream content from the network to the reader without losing source fidelity or UI responsiveness.
- Keep state isolated per tab and durable state independent of UI objects.
- Use macOS frameworks and avoid cross-platform browser abstractions.
- Treat untrusted capsule content as data, never as application instructions.

## Modules

| Module | Responsibility |
| --- | --- |
| `MajorTomCore` | Gemini protocol, URL handling, response streaming, trust, parsing, document models, persistence types, and testable browser rules. |
| `MajorTomAppKitSupport` | Narrow AppKit bridges used where SwiftUI does not provide the required native behavior. |
| `MajorTom` | SwiftUI application shell, windows, tabs, menus, settings, browser views, and composition of Core services. |

The application shell observes state and sends user intent. It does not parse Gemini, make trust decisions, or embed persistence policy in views.

### Native tab controls

AppKit owns Major Tom's window tabs and Tab Overview. When AppKit lazily creates its
native tab bar after a second window joins the group, Major Tom hides AppKit's Add Tab
button and reconnects the native tab track directly to the tab bar's normal trailing
inset. The tab bar remains full-width and contains only tabs; it is never resized. New
tabs remain available through the File menu and Command-T. Show Tab Overview is a
SwiftUI navigation-bar action immediately after Reload or Stop. The full-width tab-track
layout remains installed while Tab Overview is visible so AppKit's exit animation never
reveals the removed Add Tab slot. The private `NSTabBar` and `NSTabBarTrackView` class names and native
Add Tab action are used only to locate the relevant views; Major Tom invokes no private
selectors. A permanent nonactivating panel supplies the overview's top-right icon-only
Hide Tab Overview button and is ordered in or out as overview visibility changes.

### Native navigation controls

SwiftUI composes the navigation bar and its connected functional groups. Standalone
actions such as Reload and Stop use one compact circular interactive-glass surface. A
pointer hover subtly tints that surface, while SwiftUI retains its pressed state, keyboard
focus, and accessibility behavior. Connected groups use SwiftUI glass containers with
compact independent actions because neither SwiftUI nor AppKit provides a public
equivalent connected-pill control.

## Navigation and content flow

```text
User intent
  → tab navigation controller
  → Gemini transport
  → TLS trust decision
  → response decoder
  → UTF-8 decoder and content parser
  → semantic document stream
  → controlled WebKit presentation
```

The transport emits typed progress, server-identity, header, body, completion, cancellation, truncation, and failure events. The decoder retains exact response bytes and explicit completion state. Parsers tolerate arbitrary chunk boundaries and keep incomplete characters and structures until they can be interpreted safely.

The tab owns its committed page, pending destination, history position, active request, progress, scroll state, zoom, and document state. Tabs do not share live navigation state.

## Trust and persistence

The trust service computes SHA-256 SPKI fingerprints and resolves first-use, changed-key, and certificate-date decisions before content is accepted. The UI presents a decision; the trust service records it.

Persistent records use domain types, never views, WebKit objects, or network tasks. Local stores are authoritative while offline. CloudKit mirrors selected durable user intent; Keychain holds client identities and their private keys. `CKSyncEngine` incrementally fetches changes from Major Tom's private custom zone and resumes from a durable serialized token. Local edits commit their domain row and a generation-numbered outbox entry in one SQLite transaction. Confirmed server deletion wins over edits, and an in-flight send can acknowledge only the generation it actually sent. Complete and incomplete responses remain distinct throughout persistence and caching.

Major Tom's local persistence is moving behind a GRDB-backed SQLite boundary in staged,
independently migratable changes. `MajorTomDatabase` owns connection policy, transactions,
integrity checks, and ordered schema migrations; domain repositories own their tables and
queries. SwiftUI views and CloudKit adapters do not issue SQL. Existing JSON and UserDefaults
stores remain authoritative until the migration for their particular data class has committed
and been verified, so installing an intermediate build never performs a partial user-data move.

Global history and Gemini input drafts are the first domain records behind this boundary.
`history_entries` upserts by canonical URL and stores last-visited time plus a visit count;
it is pruned to one year. `gemini_input_drafts` keys unsubmitted text by prompt URL and stores
an explicit fourteen-day expiration. Both tables are local-only. A one-time transactional
import folds the former append-only UserDefaults history blob into URL rows before removing
that legacy local value. Each navigation or draft edit changes only its row rather than
rewriting an encoded collection.

Bookmarks use normalized `bookmark_folders` and `bookmarks` tables. A collection mutation is
diffed against those rows inside one transaction, so editing one title or favicon changes one
row rather than rewriting the collection. Each bookmark optionally carries a timestamped
favicon observation; an absent observation is distinct from an unknown one. The existing JSON
file is imported once with an in-transaction marker and removed only after the imported rows
can be read. The same optional snapshot travels inside the record-level bookmark CloudKit
payload; older payloads decode it as unknown.

Cloud sync state lives in `cloud_sync_state`, `cloud_pending_changes`, and
`cloud_record_state`, keyed by a SHA-256 hash of the iCloud account identity. Record metadata
includes archived CloudKit system fields and the last server payload, allowing conflict retries
to retain change tags and fields written by a newer app. Each CloudKit type has exactly one
encrypted `payload` field containing a schema-tagged JSON envelope. Record names are stable UUIDs.

Cloud data lives only in the `MajorTomUserDataV2` private custom zone. Its
`MTDataModelManifest` gates readers and writers before model records are applied. On an account's
first new-v2 launch, Major Tom reads the original `MajorTomUserData` zone once, imports supported
v1 bookmarks, preferences, and certificate metadata, resets the disposable experimental v2 zone,
publishes the new manifest, and permanently marks that account ready. It never reads or writes v1
again. Account changes select separate local datasets and outboxes; signing out retains the last
account's local data and offline edits without exposing them to another account.

Trusted capsule identity records use `trusted_server_identities`, one row per host and port.
The row retains the local decision source, fingerprint, certificate observation, first/last seen
times, and sighting count. Server trust is deliberately local-only. Client-certificate CloudKit
metadata uses one row per descriptor and association, with separate per-identity local Keychain
synchronization flags. The actual private key and certificate identity remain Keychain items;
remote metadata deletion never deletes Keychain material.

### Data ownership and storage map

| Data | Local authority | Cross-Mac behavior |
| --- | --- | --- |
| Bookmarks, folders, order, bookmark favicon snapshot | Account-scoped SQLite bookmark rows | One CloudKit record per item through a transactional outbox |
| Homepage, search provider, content theme/width, Gemtext rendering options, image-loading choices, favicon visibility | Small coalesced UserDefaults preference snapshot | iCloud Key-Value Store |
| Application appearance, Gemini proxy, Favorites-bar visibility | Same local preference snapshot | Local to one Mac |
| Client-certificate descriptors and capsule/path associations | SQLite per-record sync metadata | CloudKit records; usable identity material follows only through synchronizable Keychain |
| Client-certificate private keys and certificate identity | Keychain | iCloud Keychain when the identity is marked synchronizable; never CloudKit |
| User-approved server trust | SQLite endpoint row | Local only |
| Open-tab summaries for other Macs | Live window model plus small UserDefaults display cache | One replaceable CloudKit record per device; URL, title, and favicon only |
| Global browsing history | SQLite URL row | Local only, one-year retention |
| Window/tab session, Back/Forward entries, response snapshots, cursor, zoom, reading state | Standalone `MajorTomBackForward.db` rows | Local only |
| Cancelled Gemini input draft | SQLite prompt-URL row | Local only, fourteen-day expiry |
| Capsule favicon probe cache | Small local JSON cache | Local only; a bookmark carries its last observation separately |
| Downloads and explicitly saved pages | User-selected filesystem location | Outside app sync |

`UserDefaults` is an on-disk preferences plist owned by macOS, not a network service. Major Tom
uses it only for compact preference values, migration markers, a stable device ID, and the small
last-fetched remote-tabs display cache. Nothing enters CloudKit merely because it is in
UserDefaults; the CloudKit adapter explicitly constructs the synchronized projections listed
above. Large collections, cache bodies, security records, and tombstone sets do not use it.

Deletion of synchronized intent creates a durable delete operation in the same transaction as
the local row deletion. CloudKit records are physically deleted. Delete wins over a concurrent
edit, and a stale send completion cannot remove a newer outbox generation. Local
cache/history/session clearing remains physical local deletion because those data never sync.

Session restoration and exact Back/Forward snapshots live in the standalone
`MajorTomBackForward.db` database. Its normalized `browser_windows`, `browser_tabs`, and
`browser_tab_history` rows preserve window and tab order, each tab's cursor, and one row per
visit. A visit carries its URL, one title, favicon, response status and meta, exact source
bytes, completion state, and versioned JSON presentation state. The presentation state keeps
scroll position, expanded image-link URLs, and one-based indexes of collapsed preformatted
sections. The response meta supplies the MIME type; there is no duplicate MIME column.
New standalone SQLite databases introduced by the browser-cache refactor use the `.db`
filename extension.

Startup hydrates only the current response in each restored tab. Older entries retain their
metadata and are loaded lazily from the standalone database on traversal. Repeated visits to
one URL remain different entries and can therefore preserve different response bytes and
reading state. Client-certificate-authenticated response bodies are not retained.

Orderly application termination is deferred until pending per-tab Back/Forward writes and the
final normalized session save complete. The standalone pool then performs a truncating WAL
checkpoint, closes, and removes the disconnected `-wal` and `-shm` files; crash recovery
retains SQLite's normal companion-file behavior.

The older URL-keyed `page_cache` is not a Back/Forward source. A future resource-cache design
will decide general response reuse, associated resources, omnibar indexing, offline behavior,
and eviction independently of the per-visit history model.

## Presentation boundary

WebKit renders Major Tom-controlled HTML derived from semantic document changes. Capsule text is escaped, destinations are validated, and the browser controls the document shell, stylesheet, and interaction bridge. Capsule content does not supply executable HTML or script.

The presentation environment uses a restrictive content-security policy and intercepts Gemini links for normal tab navigation. Browser-owned interactions cross a small typed boundary; native WebKit hooks take precedence over custom script.

The WebKit document remains edge-to-edge beneath Major Tom's navigation and Favorites
chrome. Because those controls are a SwiftUI overlay rather than an AppKit toolbar or
titlebar accessory, WebKit cannot infer their geometry. The presentation bridge applies
the measured chrome height only to `NSScrollView.scrollerInsets`, keeping the scroll thumb
below the browser chrome without removing the document background from the glass context.

This boundary permits another renderer in the future without changing protocol, trust, parsing, or persistence. That is a containment boundary, not a plug-in system.

## Security boundaries

- TLS identity is decided before response content is trusted.
- Parser output is encoded before presentation.
- External schemes leave Major Tom only through explicit policy.
- Automatic resources obey the same trust, redirect, and resource limits as foreground navigation.
- The renderer cannot initiate arbitrary network activity.
- User-approved trust replacement is explicit and auditable.

## Verification

Core tests cover URL interpretation, Gemini protocol behavior, streaming boundaries, parsing, trust, history, filenames, and persistence without launching the UI.

UI and integration tests cover controlled resource delivery, navigation interception, theme changes, partial responses, cancellation, selection, native commands, window behavior, and accessibility-sensitive interactions. Performance work measures time to visible content, responsiveness while streaming, memory across multiple tabs, scrolling stability, and energy use.
