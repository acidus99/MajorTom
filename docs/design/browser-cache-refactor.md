# Back/Forward Cache

Status: Implemented first milestone

This design is intentionally limited to fast, faithful Back/Forward traversal. Reusable image
and favicon responses now live in the separate `ContentCache.db` system described by the
architecture document. Omnibar indexing, purposeful offline browsing, and scheduled downloads
remain separate future work.

## User-visible behavior

Every visit in every tab has its own saved response and reading state. Back and Forward
prefer that exact saved visit, so revisiting an entry does not normally contact the capsule
and does not silently replace the page with newer content.

Each visit preserves:

- URL, one title, and favicon
- Gemini response status and meta
- exact response bytes and completion state
- vertical scroll offset
- image-link URLs expanded by the reader
- one-based indexes of preformatted sections collapsed by the reader

Major Tom regenerates the document from the saved response using current rendering
preferences, applies the saved interaction state, restores the scroll position, and then
reveals the page. Associated image bytes are outside this milestone.

Client-certificate-authenticated response bodies are not retained or served from this cache.
An entry without saved bytes reloads through its normal navigation path without changing the
tab's Back/Forward structure.

## Storage

Back/Forward data lives only in its own SQLite file:

`~/Library/Application Support/Major Tom/BFCache.db`

It does not use `MajorTom.sqlite`. The standalone database owns the normalized application
session, windows, tabs, and history entries.

`browser_tab_history` has one row per visit, not one row per URL. Its columns are:

```text
id, tab_id, position, url, title, favicon,
response_status, response_meta, response_body, completion, received_at,
client_certificate_id, presentation_state
```

There is deliberately no `mime_type` column. The content type is reconstructed from the
stored response meta. There is deliberately only one title column.

`presentation_state` is versioned JSON:

```json
{
  "version": 1,
  "scrollY": 1842,
  "expandedImages": ["gemini://example.com/photo.jpg"],
  "collapsedPreformatted": [1, 3]
}
```

Image links begin collapsed and preformatted sections begin expanded. The arrays therefore
contain only reader-made exceptions.

## Navigation ownership

Each window owns an ordered list of tabs and its selected tab index. Each tab has a stable
UUID, an ordered list of entry UUIDs, and a cursor into that list.

- New navigation truncates the forward branch and appends a new entry.
- Back and Forward move only the cursor.
- Reload replaces the current entry's response and does not append an entry.
- Closing a tab removes its entries when the application session is reconciled.
- Repeated visits to one URL are distinct and may retain different bytes and reading state.

The active tab keeps a bounded in-memory hot set. A traversal that misses that set reads the
exact entry lazily from `BFCache.db`. Startup loads response bytes only for
the current entry in each restored tab.

## Persistence and presentation

Response snapshots are written after a complete, stopped, failed, or otherwise displayable
response is captured. SQLite access is serialized away from the main actor. Scroll and
interaction-state writes are coalesced, with the page being left flushed before the cursor
moves.

Image links use their absolute URL as the saved identity. Preformatted sections use their
one-based source order. Both are deterministic when Major Tom regenerates the exact saved
response.

On orderly application termination, Major Tom flushes every tab's coalesced state, saves the
window/session rows, checkpoints the WAL into the main database, closes the pool, and removes
the disconnected `-wal` and `-shm` companion files before allowing AppKit to finish quitting.
A crash or forced termination may still leave those SQLite recovery files, as expected.

The stored response is authoritative. Generated HTML and the live WebKit DOM are never
persisted.

## Required invariants

- Two visits to one URL retain independent response bytes and state.
- A new branch cannot inherit state from the forward entry it replaces.
- A stale asynchronous read or write cannot replace the current entry.
- Back/Forward does not issue a network request when that entry has saved bytes.
- Scroll events do not execute synchronous SQLite work on the main actor.
- The schema has one title column and no MIME-type column.
- Clearing browsing data removes the standalone Back/Forward database's logical contents.
