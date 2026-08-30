# Major Tom

Major Tom is a native macOS 26 Gemini browser. Native Mac quality is part of correctness.

## Source of truth

- Product behavior: `docs/design/major-tom-specification.md`.
- Engineering decisions: `docs/design/architecture.md`.
- Update the relevant document when a change alters user-visible behavior or an architectural decision.

## UI

- Follow established macOS and Safari conventions unless Gemini-specific behavior requires otherwise.
- Use public SwiftUI controls first. Bridge AppKit controls when SwiftUI has no appropriate native control.
- Keep custom UI for Major Tom-specific concepts only.
- Preserve accessibility, keyboard navigation, focus, selection, and system-appearance behavior.
- Document intentional departures from native conventions.

## Engineering

- Keep protocol, trust, parsing, persistence, and rendering independent of SwiftUI views.
- Preserve received source bytes; presentation enhancements must not alter source, View Source, or saved output.
- Prefer small, focused changes with tests for Core behavior.

## Verification

- Run `swift test` after code changes.
- Run `Scripts/build-app.sh` for changes affecting the app target, bundle resources, signing, or packaging.
