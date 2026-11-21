# Architecture

Major Tom is a native macOS 26 Gemini browser. Its architecture keeps browser
behavior testable without windows, network connections, or a signed iCloud account.
The goal and working principles live in [AGENTS.md](../../AGENTS.md).

## Subsystems

- [UI](subsystems/ui.md): Native windows, tabs, menus, controls, accessibility, and all
  dialogs.
- [Browser](subsystems/browser.md): User actions, feature workflows, per-tab navigation,
  and coordination.
- [Networking](subsystems/networking.md): Requests, protocol framing, streaming
  responses, and resource scheduling.
- [Security and Identity](subsystems/security-and-identity.md): Server trust, client
  identities, and destination scope.
- [Parsing](subsystems/parsing.md): Response bodies interpreted as structured content.
- [Content Presentation](subsystems/content-presentation.md): Safe WebKit rendering,
  themes, and document interactions.
- [Cache](subsystems/cache.md): Response reuse, freshness, limits, and invalidation.
- [Data Persistence](subsystems/data-persistence.md): Local storage, repositories,
  migrations, and remote synchronization.

These are responsibility boundaries, not a requirement for eight Swift targets.
Browser contains focused feature components, not one application-wide coordinator.
Application startup composes live services; testable components accept supplied
dependencies and clocks rather than obtaining global instances themselves.

## How they connect

UI sends actions to Browser and observes its state. Browser coordinates Networking,
Security and Identity, Parsing, Content Presentation, Cache, and Data Persistence.
UI hosts the presentation surface and supplies native geometry and appearance.

Networking consults Security and Identity and optionally Cache. Cache owns its
disposable response store. Security and Identity uses Data Persistence for trust and
identity metadata repositories. Parsing has no service
dependencies. Content Presentation consumes parsed content and settings; it reports
link activation and resource needs to Browser instead of making requests itself.
Data Persistence contains its own synchronization adapters, separate from browsing
Networking, and publishes committed changes through repository observations.

A navigation flows from request metadata and body chunks, through Parsing, to
incremental presentation. Cached responses enter that same content pipeline.
Decision requests travel back to UI through Browser; replies resume only the
workflow that requested them. Notifications and replies do not reverse ownership.

## Boundary rules

- Each kind of state has one authoritative owner. Persistence holds durable copies;
  UI observes state rather than maintaining competing domain records.
- Cross-subsystem contracts describe intent and results using plain data. They do
  not expose SQL, storage paths, CloudKit records, SwiftUI views, or WebKit objects.
  UI and Content Presentation necessarily use native objects at their hosting seam.
- Only UI presents dialogs and performs native window or application actions.
  Services report typed failures and decisions; UI owns localized wording.
- Preserve received bytes. Parsing and presentation never rewrite source or saved
  output. Capsule content is untrusted data, never executable app instructions.
- Streaming distinguishes completion, cancellation, and failure. Request, document,
  and account identities prevent late work from changing newer state.
- Storage I/O and expensive work stay off the UI actor. Startup requires local
  session state, not cloud access or cache maintenance.
- Depend on narrow interfaces at external and subsystem boundaries. Avoid forwarding
  layers, universal event buses, and speculative protocol or sync plugin frameworks.

## Verification and code navigation

Use controlled services and clocks for workflow tests, real temporary databases for
storage tests, and focused WebKit/AppKit tests for native behavior. A small number of
integration tests connect the boundaries. Each subsystem document names its key
guarantees and testing approach; [the build guide](how-to-build.md) gives commands.

`Sources/MajorTomCore` contains testable browser rules, protocol/content logic, and
storage services; it does not import SwiftUI, AppKit, or WebKit.
`Sources/MajorTomAppKitSupport` contains narrow native bridges.
`Sources/MajorTom` contains the native application shell and platform integration.
File and type inventories belong in code, not in this document.

Future work belongs in [TODO](TODOs.txt).
