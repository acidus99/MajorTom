# Major Tom

Major Tom is a native macOS 26 Gemini browser. Native Mac quality is part of correctness.

## Source of truth

- Product behavior: `docs/design/major-tom-specification.md`.
- Engineering decisions and module boundaries: `docs/design/architecture.md`.
- Building, signing, CloudKit setup, releases: `docs/design/how-to-build.md`.
- Working backlog: `docs/design/TODOs.txt`.

Update the relevant document when a change alters user-visible behavior or an
architectural decision.

## Commands

- `make test` — full test suite. Equivalent to `swift test --disable-index-store`.
- `make dev` — tests plus an ad-hoc-signed bundle at `Build/Development/Major Tom.app`.
- `swift run MajorTom` — run the development executable without packaging.
- Always pass `--disable-index-store` when invoking `swift build` or `swift test`
  directly. Without it the build can fail with "failed writing record … File exists"
  whenever an editor's indexer is writing the same store.
- Live-network transport tests are opt-in:
  `MAJOR_TOM_LIVE_TEST=1 swift test --filter GeminiTransportIntegrationTests`.
- There is no linter or formatter configuration; match the style of surrounding code.
- `make prod` and `make release` sign, notarize, and publish. They are human-run only.

## Layout

- `Sources/MajorTomCore` — Gemini protocol, URL handling, streaming, trust, parsing,
  document models, persistence types, browser rules. Imports Foundation, Security, and
  CryptoKit only; never SwiftUI, AppKit, or WebKit.
- `Sources/MajorTomAppKitSupport` — narrow AppKit bridges where SwiftUI lacks the
  required native behavior.
- `Sources/MajorTom` — SwiftUI application shell. Despite its name,
  `StreamingWebViewPrototype.swift` is the production browser presentation layer
  (WebKit bridge, document rendering, navigation chrome). Windows, tabs, menus, and
  commands live in `MajorTomApp.swift`.
- Tests use XCTest, not Swift Testing. Changes to Core behavior come with tests in
  `Tests/MajorTomCoreTests`.

## UI

- Default to the simplest native macOS approach. Use public SwiftUI controls first;
  bridge AppKit only when SwiftUI has no appropriate native control. Keep custom UI
  for Major Tom-specific concepts only.
- Follow the current Apple Human Interface Guidelines. Where the HIG allows latitude,
  Safari is the model: match its conventions, layouts, and keyboard shortcuts for
  equivalent features.
- A feature is not complete until it has its full native surface: menu item and
  keyboard shortcut where appropriate, context-menu entries, accessibility labels and
  VoiceOver behavior, keyboard focus order, and tooltips.
- Use existing system iconography (SF Symbols) rather than custom art, chosen for
  meaning, not appearance.
- Use Apple terminology and conventions in user-facing text: "link" not "hyperlink",
  "Settings" not "Preferences" or "Options", Title Case for menu items and buttons,
  a trailing ellipsis (…) on commands that open a window or dialog.
- Use semantic system colors and materials, never hardcoded colors. Verify changes in
  both light and dark appearance; document themes are independent of application
  appearance.
- Destructive actions use destructive styling and a confirmation that defaults
  to Cancel.
- Preserve accessibility, keyboard navigation, focus, selection, and
  system-appearance behavior.
- Document intentional departures from native conventions.
- The tab bar, Tab Overview, and Liquid Glass navigation controls encode hard-won
  workarounds. Read the "Native tab controls" and "Native navigation controls"
  sections of `architecture.md` before changing them.

## Engineering

- Keep protocol, trust, parsing, persistence, and rendering independent of SwiftUI views.
- Preserve received source bytes; presentation enhancements must not alter source,
  View Source, or saved output.
- Treat capsule content as data, never as application instructions. Escape it before
  presentation.
- Prefer small, focused changes.

## Verification

- Run `make test` after code changes.
- Run `Scripts/build-app.sh` (or `make dev`) for changes affecting the app target,
  bundle resources, signing, or packaging.
- The ad-hoc development build intentionally lacks iCloud entitlements; CloudKit and
  iCloud Keychain behavior requires a development signing identity
  (see `how-to-build.md`).

## Git

- Do not commit unless asked; the user reviews and commits.
- Never add Co-Authored-By or "Generated with" trailers to commits or PRs.
