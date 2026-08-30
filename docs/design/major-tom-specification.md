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

When a visited capsule provides a favicon, its full-color emoji appears on the Page Information control and the tab. Without a favicon, the Page Information control uses the standard information-in-a-circle symbol.

Navigation distinguishes the page currently being read from the destination being loaded. Stop cancels the request. Back and Forward behave predictably, redirects commit only their final location, and failures are clearly browser-generated pages. Browser commands, shortcuts, menus, gestures, context menus, saving, find, zoom, and source viewing use normal Mac conventions.

## Progressive, faithful content

Major Tom begins presenting safe displayable content while it is still arriving. Readers can select, scroll, and use already available links without disruptive layout or scroll jumps. Partial, stopped, and failed responses remain distinguishable from complete content.

Gemtext receives a polished semantic reading presentation. Other text remains selectable and faithful to its line structure; images display directly; unsupported content explains what happened and offers appropriate user-initiated actions.

Reading preferences control application appearance separately from the document theme and width. Changes to appearance-only preferences update open content without another request. Optional enhancements—such as conservative inline formatting and automatic same-capsule images—must be individually controllable, bounded, and fail without disrupting the original document or link.

View Source and Save Page As always use the original response body. Caching must preserve response metadata, completion state, and enough source to reproduce a page under changed reading preferences.

## Trust, security, and privacy

Gemini connections use TLS and trust on first use, keyed by host, port, and the server's SHA-256 SPKI fingerprint. A seeded match may proceed quietly. First use, changed identities, and invalid certificate dates require clear, deliberate user decisions that identify the capsule, explain the risk in plain language, expose relevant details, and always provide a safe cancellation path.

Client certificates are offered only after a user has explicitly approved a matching capsule or path scope. Private keys remain in the Keychain; they are never placed in preferences or CloudKit. A capsule's identity must never be sent to another capsule through a redirect or overly broad rule.

Major Tom works offline. Local state is immediately authoritative. When iCloud synchronization is enabled, it syncs only the user choices that should follow them between Macs; it never makes CloudKit a launch dependency or transfers cached page bodies, browsing history, network configuration, or private keys.

## Native quality and accessibility

All primary actions must work with the keyboard and VoiceOver. Controls have meaningful labels, state, and focus order. Document structure exposes usable semantics for headings, links, lists, quotations, images, and preformatted text.

Major Tom respects system appearance and relevant accessibility settings. Color is never the sole signal for loading, failure, trust, or selection. Text selection, clipboard behavior, drag and drop, context menus, focus rings, and standard system commands should feel native rather than simulated.

## Scope and decisions

The native app includes Gemini navigation, streaming, redirects, input prompts, trust management, client certificates, reading and source views, themes, history, bookmarks, downloads, session restoration, and private synchronization.

Potential future work belongs in the working backlog until it has a user-facing purpose and acceptance criteria. Product requirements remain implementation-neutral unless a platform technology is itself part of the user experience.
