# Major Tom Architecture

Status: Proposed engineering design for the native MVP

This document describes how engineering intends to satisfy the product specification. Product behavior is authoritative in `major-tom-specification.md`; architecture may change when testing shows that a different implementation better satisfies it.

## 1. Architecture Goals

- Make the Mac experience native, fast, accessible, and maintainable.
- Keep Gemini protocol behavior independent from document rendering.
- Stream bytes, parsed content, and visible presentation incrementally.
- Preserve exact source bytes alongside derived state.
- Make trust decisions before untrusted Gemini content is consumed.
- Keep each tab's navigation and presentation state isolated.
- Support durable state for 1.0 without coupling persistence to UI objects.
- Avoid cross-platform abstractions and bundled browser engines.

## 2. Major Components

### 2.1 SwiftUI application shell

SwiftUI owns the application lifecycle, scenes, browser windows, tab presentation, toolbar, menus and commands, settings, sheets, alerts, and browser-owned interface.

The shell observes domain state and sends user intents to tab and application controllers. It does not perform Gemini parsing, TLS validation, or direct persistence.

### 2.2 Application and tab state

An application-level model owns shared settings, trusted identities, browsing data, window sessions, and services.

Each tab owns a navigation controller with distinct pending and committed state, history position, active task, response progress, document model, scroll state, zoom, and attention requirements.

Tab state is UI-framework-neutral and serializable where 1.0 restoration requires it.

### 2.3 Gemini networking

A native Swift networking service owns DNS resolution, proxy negotiation, TCP, TLS, request transmission, incremental receipt, cancellation, timeouts, and connection diagnostics.

It emits a typed asynchronous event stream rather than returning one completed response blob. Events distinguish connection progress, server identity, response header, body data, clean completion, truncation, cancellation, and failure.

### 2.4 Trust service

The trust service computes SHA-256 SPKI fingerprints, queries seed and local trust, produces typed trust decisions, and records approved identities and audit metadata.

The networking layer pauses at the server-authentication boundary when a user decision is required. UI presents the decision; the trust service, not the view, applies it.

### 2.5 Incremental response decoder

The response decoder consumes network bytes and emits a validated Gemini header followed by body chunks. It enforces line and request limits, tracks completeness, decodes text without splitting multibyte characters, and retains exact source bytes.

### 2.6 Incremental document parser

The Gemtext parser is a deterministic state machine that consumes decoded text fragments and emits semantic document changes. It retains incomplete lines and open constructs between chunks.

The semantic model represents paragraphs, headings, links, lists, quotations, preformatted blocks, inline presentation spans, images, and browser-generated notices without referring to HTML, CSS, WebKit, `NSAttributedString`, or SwiftUI views.

Quality-of-life transformations operate on this semantic model or during parsing under explicit settings. They never modify authoritative source bytes.

### 2.7 Document renderer

Engineering recommends WebKit as the initial document renderer. The renderer receives safe semantic changes and presents them incrementally. It does not own Gemini navigation, history, trust, caching, or source.

The renderer boundary is narrow enough to permit a TextKit implementation if performance testing demonstrates that WebKit cannot meet the product bar. This is a risk-control boundary, not a generalized plug-in system.

### 2.8 Persistence

Persistence stores settings, trust records, seeds, cached responses, browsing history, and 1.0 session restoration through repositories expressed in domain types.

Database records never contain live views, WebKit objects, networking tasks, or framework-specific attributed strings. Schema migrations and explicit completeness metadata are required for durable data.

## 3. Recommended WebKit Presentation

### 3.1 Why WebKit

WebKit provides the same native text and graphics engine family used by Safari while avoiding a bundled Chromium or Electron runtime. It gives Major Tom mature document layout, CSS, selection, accessibility, link interaction, images, find, zoom, printing potential, source presentation, and future Markdown output.

CSS maps naturally to the independent content-theme system and allows themes to change without reparsing source. Semantic parsers can produce sanitized HTML fragments for Gemtext, Markdown, and future displayable formats without placing format logic in the view.

### 3.2 Controlled content, not arbitrary webpages

Capsules do not supply HTML or executable script to the renderer. Major Tom escapes capsule text, validates destinations, generates the document structure, and owns any small script used for controlled interaction.

The rendered document uses a restrictive content security policy. WebKit is prevented from initiating arbitrary network loads. Gemini links are intercepted and returned to the tab navigation controller. Inline resources are served only through Major Tom-controlled data or scheme handlers.

Web storage, cookies, service workers, permissions, media capture, popups, and unrelated web-platform behavior are disabled or made unavailable unless a later product requirement explicitly needs them.

### 3.3 Streaming strategy

The preferred design uses a Major Tom-controlled URL scheme. The scheme handler yields a local HTML response followed by incremental HTML data derived from completed semantic blocks. WebKit parses and lays out the document as data arrives, just as it does for a progressively delivered webpage.

Apple's current SwiftUI WebKit scheme handler is an asynchronous sequence of response and data values; data values may contain all or only part of a resource. Earlier `WKURLSchemeHandler` APIs also support repeated incremental data delivery. The exact API is selected after the deployment target is decided.

An initial document shell contains metadata, the restrictive content security policy, theme variables, and browser-owned behavior. Each emitted fragment is complete, escaped, and safe to append to the streaming document. Completion closes the document; cancellation or failure adds or records an incomplete-state notice without mislabeling the response as complete.

Images use controlled resource identifiers rather than exposing filesystem paths. Image bytes may also be delivered incrementally where the format and WebKit support progressive display.

### 3.4 Interaction bridge

Navigation decisions, context-menu targets, link hover, scroll restoration, and other browser interaction cross a small typed boundary. Unstructured strings and general capsule-controlled messages are not accepted as commands.

Where the WebKit API already supplies native interaction hooks, those hooks are preferred over custom JavaScript.

## 4. Jimmy Evaluation

Jimmy demonstrates a viable native-text alternative. Its SwiftUI shell parses Gemtext into `NSAttributedString` and displays it through an `NSViewRepresentable` wrapper around `NSTextView`.

That approach is lightweight for completed text documents, but Jimmy's current network connection accumulates all received data and invokes parsing only when the connection ends. Updating the view replaces the text storage with a complete attributed string. It therefore does not provide Major Tom's required progressive response pipeline.

Adopting a comparable TextKit design would require Major Tom to build and maintain more custom behavior for incremental block layout, cross-document selection, inline media, theme changes, source gutters, Markdown, context menus, find, accessibility semantics, and scroll stability.

Jimmy remains a useful reference for native networking and text-rendering experiments, but its architecture should not be copied wholesale.

References:

- [Jimmy repository](https://github.com/jfoucher/Jimmy)
- [Jimmy attributed-text view](https://github.com/jfoucher/Jimmy/blob/main/jimmy/Views/AttributedTextImpl.swift)
- [Jimmy response accumulation](https://github.com/jfoucher/Jimmy/blob/main/jimmy/Network/ClientConnection.swift)
- [Jimmy Gemtext parser](https://github.com/jfoucher/Jimmy/blob/main/jimmy/Utils/ContentParser.swift)

## 5. Performance Validation

WebKit is an engineering recommendation subject to measurement, not an exemption from Major Tom's lightweight requirement.

The first renderer milestone will measure:

- Time from the first parseable response block to visible content.
- Continuous layout behavior during a long streaming response.
- Main-thread responsiveness during parsing and rendering.
- Memory with one active tab and with representative multi-tab sessions.
- Behavior when inactive tabs retain or release presentation objects.
- Scrolling, selection, link interaction, theme switching, and cancellation during streaming.
- Large Gemtext, plain-text, image, and source documents.
- Energy impact during active streaming and while idle.

If WebKit fails the product bar after reasonable optimization, engineering will implement the same semantic document stream using TextKit 2. Networking, parsing, trust, caching, and product state will not need to change.

## 6. Security Boundaries

- TLS identity is decided before response content is trusted.
- Capsule bytes are data, never executable application instructions.
- Parser output is encoded safely for the renderer.
- External schemes leave Major Tom only through explicit policy decisions.
- Automatic image retrieval obeys same-capsule, trust, redirect, and resource limits.
- Cached complete and incomplete responses remain distinguishable.
- Trust replacement is an auditable user action.
- Renderer compromise is limited by an ephemeral, network-restricted WebKit configuration and the macOS application sandbox where applicable.

## 7. Testing Strategy

Core URL, protocol, trust, parser, history, filename, and persistence behavior is tested without launching UI or WebKit.

Streaming tests divide valid input at every meaningful byte boundary, including UTF-8 sequences, CRLF, Gemtext delimiters, link lines, and preformatted fences. The final semantic model must be invariant under chunk boundaries.

Renderer integration tests cover incremental fragment delivery, navigation interception, source safety, content security policy, link modifiers, theme changes, selection stability, partial completion, cancellation, and resource loading.

End-to-end Mac tests cover windows, tabs, menus, commands, sheets, focus, accessibility, restoration, saving, and trust decisions.

## 8. Open Engineering Decisions

- Minimum macOS deployment target.
- Exact SwiftUI WebKit API versus compatibility wrapper, based on the deployment target.
- Native networking API details and proxy implementation.
- Persistence store technology and schema.
- WebKit lifecycle policy for inactive tabs.
- Quantitative performance thresholds after the first baseline measurements.
