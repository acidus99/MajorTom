# Major Tom Product Specification

Status: Current product direction

This document defines Major Tom's user-facing contract. It deliberately describes outcomes, not framework choices or implementation plans. The architecture document records the current technical design.

## Vision

Major Tom is the Gemini browser that feels at home on a Mac: fast, calm, beautiful, and unmistakably native. It should make Gemini's text-first culture enjoyable without trying to turn capsules into conventional websites.

Success means that browsing, reading, trust decisions, keyboard interaction, windows, menus, and accessibility feel coherent with macOS and familiar to Safari users. A feature is not finished just because it works; it must also feel native.

## Product principles

- **Mac first.** Follow established macOS and Safari conventions where they apply. Gemini-specific needs may justify a different interaction, but not a generic or cross-platform one.
- **Reading matters.** Typography, layout, selection, scrolling, image presentation, and accessibility are product behavior.
- **Source is authoritative.** The received response body is preserved exactly. Reading enhancements never alter View Source, saved output, or the cached source.
- **Gemini stays Gemini.** Major Tom supports the protocol and its culture without importing unnecessary web-browser complexity.
- **Fast and legible.** Local interaction is immediate; network activity and failures are clear but never dominate the page.
- **Private by design.** Trust, identities, cached content, and synchronization must be deliberate, comprehensible, and conservative.

## Core browsing experience

Major Tom is a multiwindow, tabbed macOS browser. Each tab independently owns its committed page, pending navigation, history, scroll position, zoom, and loading state. Closing a tab cancels only its work; background tabs may continue loading.

The unified address field accepts Gemini locations and searches. A submitted explicit Gemini URL navigates; probable hostnames are normalized as Gemini locations; allowed external URLs are handed to macOS; other text is sent to the selected Gemini search provider. Invalid explicit Gemini URLs must produce useful feedback rather than silently becoming searches.

Document themes are independent of application appearance. Dracula Dark is the default document theme. On first launch, Major Tom opens `gemini://gemi.dev/major-tom/` as its homepage.

When a visited capsule provides a valid favicon, its full-color emoji appears on the Page Information control and the tab. Without a favicon, the Page Information control uses the standard information-in-a-circle symbol. Major Tom remembers both valid favicons and confirmed absence for 30 days; failed or interrupted favicon checks are tried again later.

A bookmark carries the most recently observed favicon state for its capsule, including a
confirmed absence. This snapshot synchronizes with the bookmark so a newly installed Mac can
render Favorites before building a local favicon cache. When a visited capsule's favicon value
changes, every bookmark for the same host and port is updated and that change synchronizes.

Navigation distinguishes the page currently being read from the destination being loaded. Stop cancels the request. Back and Forward behave predictably, redirects commit only their final location, and failures are clearly browser-generated pages. Two-finger Back and Forward swipes traverse the same tab history as the navigation controls, including history restored after relaunch. Clicking and holding an enabled Back or Forward control shows its tab's history in nearest-first order; each item shows the page title and, when available, its favicon. The navigation bar uses native Liquid Glass controls: Back and Forward form one connected group, Home and Page Information form another connected group, and standalone actions use the same system material and interaction treatment. Connected and standalone controls reveal each individual circular action on hover. Document content continues beneath the navigation and Favorites bars, while the scroll thumb begins below them rather than crossing the browser chrome. The native tab bar spans the window and contains only tabs; new tabs are created with File > New Tab or Command-T. Show Tab Overview appears immediately after Reload or Stop in the navigation bar and enters AppKit's Tab Overview, whose top-right icon-only Hide Tab Overview button and Escape key return to the selected tab. In the File menu, holding Option changes New Tab (⌘T) to New Tab at the End (⌥⌘T), which appends and selects a tab, and changes Close Tab (⌘W) to Close Other Tabs (⌥⌘W), which keeps only the selected tab in its window. The Favorites Bar bookmark menu includes a destructive Delete command. Browser commands, shortcuts, menus, gestures, context menus, saving, find, zoom, and source viewing use normal Mac conventions.

A qualifying two-finger swipe moves exactly one history entry, follows the reader's fingers interactively, reveals the adjacent page over or beneath the current page, and completes or reverses smoothly when released.

## Progressive, faithful content

Major Tom begins presenting safe displayable content while it is still arriving. Readers can select, scroll, and use already available links without disruptive layout or scroll jumps. Partial, stopped, and failed responses remain distinguishable from complete content.

Gemtext receives a polished semantic reading presentation. Other text remains selectable and faithful to its line structure; images display directly; unsupported content explains what happened and offers appropriate user-initiated actions.

Reading preferences control application appearance separately from the document theme and width. Changes to appearance-only preferences update open content without another request. Optional enhancements—such as conservative inline formatting and automatic same-capsule images—must be individually controllable, bounded, and fail without disrupting the original document or link. Automatic same-capsule images are off by default; this default is applied once to existing installations too. General settings provides Restore Default Settings, which restores browser preferences but preserves trusted capsule identities and client certificates. General settings also shows whether Major Tom is the default handler for `gemini://` URLs and provides a button to make it the default; the button is disabled and a confirmation label is shown when it already is the default.

Gemtext rendering choices synchronize between Macs, including embedded `data:` images,
automatic same-capsule images, and inline rendering enhancements. Application appearance,
proxy configuration, and Favorites-bar visibility remain local to each Mac.

View Source and Save Page As always use the original response body. Caching must preserve response metadata, completion state, and enough source to reproduce a page under changed reading preferences.

Major Tom avoids repeated Gemini image transfers with a local response cache. A completed,
successful Gemini image may be reused for 24 hours whether it was first displayed inline,
opened directly, or fetched for a user action. Reload always requests the page and its inline
images again instead of consulting that cache. Cache reuse never initiates a request itself,
and cached responses follow the same parsing and presentation path as live responses. Page
Information identifies content as Live or Cached and shows when the response was originally
received. This cache remains on one Mac and does not synchronize.

## History and unfinished input

Browsing history is one local list with one entry per URL, independent of the Back and
Forward list in any tab. A successful new navigation or reload updates that URL's most recent
title, last-visited time and visit count, moving it to the top of the global list. Back and
Forward traversal does not update global history. Redirect responses and browser-generated
error pages are excluded; a successful redirected navigation records only its final
destination. A submitted Gemini input response is an ordinary URL with a query and follows
the same history and caching rules as every other navigation. Global history remains on one
Mac and retains at most one year of visits.

History > Show All History (Command-Y) opens `about:history` in a new selected tab. The
native history view has sortable Title, Last Visited and URL columns and initially sorts by
Last Visited, newest first. Search filters titles and URLs without grouping results by date.
Double-click or Return opens the selected entry in the current tab. The table supports native
multiple selection and deletion, and its context menu can open selected entries in new tabs
or windows, copy their links, or delete them.

Text typed into a Gemini input prompt but cancelled or dismissed is an unfinished local draft,
not history. It survives quitting and is offered again when the same prompt URL returns. The
draft is deleted when the response is successfully formed for submission, when the user
empties it, or after fourteen days. Drafts never synchronize to another Mac.

Window restoration is separate from global history. Major Tom restores each window's frame,
tab order and selection, and each tab's Back/Forward list, cursor, zoom, titles, and per-entry
scroll position. Every visit can retain its URL, title, favicon, exact response status, meta
and bytes, plus expanded image-link URLs and collapsed preformatted sections. Back and Forward
reconstruct that exact visit with current rendering preferences and restore its reading state.
When saved response bytes are unavailable, Major Tom reloads the entry without changing the
tab's Back/Forward structure. Client-certificate-authenticated response bodies are not retained.

Back/Forward response snapshots are local browser data and never synchronize. Each tab keeps
at most 32 MiB of response bodies in memory; the active session's entries remain in its
standalone SQLite file so older entries can be loaded on demand. Clear Browsing Data removes
global history and the complete saved Back/Forward session.

## Trust, security, and privacy

Gemini connections use TLS and trust on first use, keyed by host, port, and the server's SHA-256 SPKI fingerprint. Changed identities and invalid certificate dates require clear, deliberate user decisions that identify the capsule, explain the risk in plain language, expose relevant details, and always provide a safe cancellation path.

Client certificates are offered only after a user has explicitly approved a matching capsule or path scope. Private keys remain in the Keychain; they are never placed in preferences or CloudKit. A capsule's identity must never be sent to another capsule through a redirect or overly broad rule.

Major Tom works offline. Local state is immediately authoritative. When iCloud synchronization is enabled, it syncs only the user choices that should follow them between Macs; it never makes CloudKit a launch dependency or transfers cached page bodies, browsing history, network configuration, or private keys.

Cloud data is explicitly versioned. Major Tom validates a data-model manifest before applying
versioned records and stops with an upgrade message if that model requires a newer app. A v1
account is imported once; current experimental v2 data is disposable, and no new build writes
the original zone. iCloud accounts have separate local datasets. Signing out keeps local data;
switching accounts never uploads one account's rows to another.

Deleting synchronized user intent physically deletes its CloudKit record and wins over a
concurrent edit. Clearing local browsing data removes history, session restoration, and cached
pages only from this Mac. Removing a client identity locally deletes its Keychain material and
publishes descriptor and association deletions. A remote metadata deletion does not erase
Keychain material; private key bytes are never copied into the app database or CloudKit.

Cloud Tabs are an unordered, deduplicated set of URL, title, and optional favicon values per Mac.
All committed URL schemes are eligible except `about:` and `data:`. Cloud Tabs never include
Back/Forward state or browsing history.

## Native quality and accessibility

All primary actions must work with the keyboard and VoiceOver. Controls have meaningful labels, state, and focus order. Document structure exposes usable semantics for headings, links, lists, quotations, images, and preformatted text.

Major Tom respects system appearance and relevant accessibility settings. Color is never the sole signal for loading, failure, trust, or selection. Text selection, clipboard behavior, drag and drop, context menus, focus rings, and standard system commands should feel native rather than simulated.

## Scope and decisions

The native app includes Gemini navigation, streaming, redirects, input prompts, trust management, client certificates, reading and source views, themes, history, bookmarks, downloads, session restoration, and private synchronization.

## Importing client data

File > Import Data from Other Clients opens a native import wizard. It accepts Lagrange User
Data ZIP exports (format major version 1) and Alhena exports (format major version 2), and
verifies the selected archive before any user data changes. Lagrange import adds bookmarks to
a Lagrange folder, uses the first bookmark tagged as its homepage as Major Tom's homepage,
imports usable RSA client identities into the Keychain, restores their exported path
assignments, and imports trusted capsule public-key identities. Alhena import adds bookmarks
to an Alhena folder; imports client identities and active path assignments; and restores the
exported homepage, application appearance, HTTP proxy, and search URL when present. Alhena's
favicon and link-hint preferences are intentionally not imported. Alhena's whole-certificate trust hashes cannot be safely converted
to Major Tom's public-key trust identities and are not imported. Existing Major Tom records
always win, so an import never duplicates or replaces bookmarks, certificate rules, or trust
decisions. The wizard is a stable, closable three-step setup panel: each client's instructions
include a silent looping demonstration that starts from the beginning when its screen appears
and stops when that screen leaves. A successfully validated archive is identified by client
and format version. Import opens a dedicated, responsive progress screen. Completion
uses the standard success symbol and reports each imported data type separately, including
counts for collections and individual rows for imported settings. It never executes exported
SQL or extracts an archive to disk, and does not manufacture settings that the source client
did not include in its export. The source-selection screen explains that available data varies
by client and shows a client-specific summary of the data Major Tom can import without
repeating support status. For Lagrange, a bookmark carrying the `.homepage` tag supplies the
homepage; for Alhena, the optional `home` preference supplies it.

General Settings provides Delete User Data beside Restore Default Settings. It presents a
warning alert whose default action is Cancel; confirmation permanently deletes bookmarks, the
homepage, client certificates and their capsule assignments, and user-trusted capsule
identities. Bundled trust policy remains in place.

Potential future work belongs in the working backlog until it has a user-facing purpose and acceptance criteria. Product requirements remain implementation-neutral unless a platform technology is itself part of the user experience.
