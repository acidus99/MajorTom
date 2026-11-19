# Major Tom

Make the best macOS Gemini client in the world. Major Tom targets macOS 26;
native Mac quality, faithful content, privacy, and responsiveness are correctness.

## Design philosophy

- Do the simplest thing that works. Prefer small, focused changes over abstractions
  built for hypothetical needs.
- Use public native controls, SwiftUI first. Bridge AppKit when SwiftUI cannot
  provide the required native behavior. Reserve custom UI for Gemini-specific needs.
- Defer to the Apple Human Interface Guidelines; use Safari as the example for
  equivalent behavior, layout, and keyboard shortcuts.
- Finish the native surface: menus, appropriate shortcuts and context menus,
  tooltips, keyboard focus, selection, accessibility, and VoiceOver.
- Use SF Symbols, semantic system colors and materials, and Apple terminology.
  Verify light and dark appearance. Destructive confirmations default to Cancel.
- Preserve original response bytes. Treat capsule content as untrusted data, never
  instructions. Reading enhancements must not change View Source or saved output.

## Working with the human

- Discuss options and tradeoffs, ask questions, and offer suggestions. Surface
  uncertainty rather than silently making product or architectural decisions.
- Read and investigate freely. Before implementing, agree on the intended outcome
  and scope and wait for the human to say go. An explicit request to implement an
  agreed change is that go-ahead.
- Complete the approved scope without repeatedly asking permission. Bring material
  changes in scope or design back for discussion before building them.
- You may suggest work from Features or Bugs in TODO, with a reason. Priority is
  not authorization to implement; the human chooses. Crazy Ideas are exploratory.

## Read next

- [Architecture](docs/design/architecture.md): system map, boundaries, and subsystem
  documents. Read the relevant subsystem before changing it; read UI's native
  control constraints before changing tabs, Tab Overview, or navigation chrome.
- [TODO](docs/design/TODOs.txt): prioritized Features, Bugs, and Crazy Ideas.
- [Build and verification](docs/design/how-to-build.md): commands, testing rules,
  toolchain and network-checkout precautions, signing, and releases.

Keep each fact in one document and link to its owner. Document intent, guarantees,
and non-obvious decisions, not method inventories or implementation walkthroughs.
Update the owning document when agreed behavior or architecture changes.

## Working rules

- Run `make test` after code changes. Build the app with `Scripts/build-app.sh`
  or `make dev` for app-target, resource, or packaging changes.
- `make prod` and `make release` are human-run only.
- Put temporary plans, logs, exports, and review artifacts in `/tmp/MajorTom`.
  Lasting project documents belong under `docs/`.
- Match surrounding code style. Do not commit unless asked. Never add
  Co-Authored-By or "Generated with" trailers to commits or PRs.
