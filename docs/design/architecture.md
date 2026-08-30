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

The trust service computes SHA-256 SPKI fingerprints and resolves seed, first-use, changed-key, and certificate-date decisions before content is accepted. The UI presents a decision; the trust service records it.

Persistent records use domain types, never views, WebKit objects, or network tasks. Local stores are authoritative while offline. CloudKit mirrors selected durable user intent; Keychain holds client identities and their private keys. Complete and incomplete responses remain distinct throughout persistence and caching.

## Presentation boundary

WebKit renders Major Tom-controlled HTML derived from semantic document changes. Capsule text is escaped, destinations are validated, and the browser controls the document shell, stylesheet, and interaction bridge. Capsule content does not supply executable HTML or script.

The presentation environment uses a restrictive content-security policy and intercepts Gemini links for normal tab navigation. Browser-owned interactions cross a small typed boundary; native WebKit hooks take precedence over custom script.

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
