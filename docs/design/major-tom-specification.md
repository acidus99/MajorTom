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

When a visited capsule provides a favicon, its full-color emoji appears on the Page Information control and the tab. Without a favicon, the Page Information control uses the standard information-in-a-circle symbol.

Navigation distinguishes the page currently being read from the destination being loaded. Stop cancels the request. Back and Forward behave predictably, redirects commit only their final location, and failures are clearly browser-generated pages. The navigation bar uses native Liquid Glass controls: Back and Forward form one connected group, Home and Page Information form another connected group, and standalone actions use the same system material and interaction treatment. Connected controls reveal each individual circular action on hover. Document content continues beneath the navigation and Favorites bars, while the scroll thumb begins below them rather than crossing the browser chrome. The native tab bar includes Safari-style Add Tab and Show Tab Overview controls; the latter enters AppKit's Tab Overview, whose top-right icon-only Hide Tab Overview button and Escape key return to the selected tab. In the File menu, holding Option changes New Tab (⌘T) to New Tab at the End (⌥⌘T), which appends and selects a tab, and changes Close Tab (⌘W) to Close Other Tabs (⌥⌘W), which keeps only the selected tab in its window. The Favorites Bar bookmark menu includes a destructive Delete command. Browser commands, shortcuts, menus, gestures, context menus, saving, find, zoom, and source viewing use normal Mac conventions.

## Progressive, faithful content

Major Tom begins presenting safe displayable content while it is still arriving. Readers can select, scroll, and use already available links without disruptive layout or scroll jumps. Partial, stopped, and failed responses remain distinguishable from complete content.

Gemtext receives a polished semantic reading presentation. Other text remains selectable and faithful to its line structure; images display directly; unsupported content explains what happened and offers appropriate user-initiated actions.

Reading preferences control application appearance separately from the document theme and width. Changes to appearance-only preferences update open content without another request. Optional enhancements—such as conservative inline formatting and automatic same-capsule images—must be individually controllable, bounded, and fail without disrupting the original document or link. Automatic same-capsule images are off by default; this default is applied once to existing installations too. General settings provides Restore Default Settings, which restores browser preferences but preserves trusted capsule identities and client certificates.

View Source and Save Page As always use the original response body. Caching must preserve response metadata, completion state, and enough source to reproduce a page under changed reading preferences.

## Trust, security, and privacy

Gemini connections use TLS and trust on first use, keyed by host, port, and the server's SHA-256 SPKI fingerprint. Changed identities and invalid certificate dates require clear, deliberate user decisions that identify the capsule, explain the risk in plain language, expose relevant details, and always provide a safe cancellation path.

Client certificates are offered only after a user has explicitly approved a matching capsule or path scope. Private keys remain in the Keychain; they are never placed in preferences or CloudKit. A capsule's identity must never be sent to another capsule through a redirect or overly broad rule.

Major Tom works offline. Local state is immediately authoritative. When iCloud synchronization is enabled, it syncs only the user choices that should follow them between Macs; it never makes CloudKit a launch dependency or transfers cached page bodies, browsing history, network configuration, or private keys.

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
