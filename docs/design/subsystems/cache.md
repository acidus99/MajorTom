# Cache

[Architecture](../architecture.md)

## Purpose and ownership

Decide whether a stored response can satisfy a request, and manage reusable response
lifetimes, capacity, eviction, and invalidation. Cache is optional and passive: it
never initiates a request. Data Persistence owns its files, database, and storage I/O.

## Boundary

Networking supplies the URL and relevant request context: protocol, identity scope,
resource purpose, and reuse/bypass intent. Cache returns a fresh eligible response
or a miss, and accepts completed responses for policy evaluation. It supports removal
by entry, resource class, time range, or all content. Storage failures remain
distinguishable from misses even when a caller can safely continue with retrieval.

A stored response retains status/meta, exact body bytes, original receipt time,
completion, and the context required to judge reuse. Receipt time does not change
when replayed. Never mix anonymous and authenticated contexts or treat interrupted
bytes as a complete reusable response.

## Reuse and retention

- Successful complete Gemini images are fresh for 24 hours. Valid favicon observations
  and confirmed completed unacceptable favicon answers are remembered for 30 days;
  failed or interrupted checks are not negative observations.
- Do not retain client-certificate-authenticated response bodies. Request context
  still matters for deciding eligibility; a broader key is not permission to cache
  personalized content.
- Reload bypasses and invalidates the main response's reusable entry. Inline images
  may still use fresh entries; clearing content is the explicit way to force their
  next transfer. Replayed responses follow the live content pipeline.
- Bound retained reusable entries to 16 MiB each and total body storage to 256 MiB,
  evicting least-recently-used entries as needed. Maintenance must not delay startup.
- Clearing advances an invalidation generation. Results obtained before that boundary
  cannot repopulate cleared content through a late write.

## Relationship to history

A reusable response is not a saved visit. Browser owns exact per-visit snapshots for
Back/Forward, even when two visits share a URL. Those snapshots preserve completion
and reading state and use Data Persistence's session storage. Cache freshness must
not silently replace a historical visit with different content.

Both kinds of retained response bytes are included in Clear Content Cache. Browser
coordinates live-state fencing; Data Persistence performs deletion. Open pages remain
displayable, while cleared bytes cannot return through session autosave. Cache content
is local-only, disposable, and excluded from remote synchronization.

## Verification

Use a controllable clock and supplied request contexts to test expiry, bypass,
identity exclusion, negative favicon observations, size limits, eviction, and
invalidation during retrieval. Test real storage separately through Data Persistence.

Code landmarks: `ContentResponse` and `ContentCache` in `ContentCache.swift`,
`GeminiCacheDecider.swift`, and `GeminiFavicon.swift` in `Sources/MajorTomCore`.
