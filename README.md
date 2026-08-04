# Major Tom

This directory contains the Swift/SwiftUI implementation of Major Tom. It is being developed alongside the existing C#/Avalonia application until native feature parity and product acceptance make the legacy implementation unnecessary.

The product requirements are in [`docs/design/major-tom-specification.md`](docs/design/major-tom-specification.md). The proposed native architecture is in [`docs/design/architecture.md`](docs/design/architecture.md).

## Current implementation

- Native multiwindow SwiftUI application with independent tabs and durable session restoration.
- Unified capsule-address and configurable Kennedy, TLGS, or custom search.
- Live Gemini navigation with redirects, input prompts, cancellation, and status pages.
- Implicit trust on first use, with persistent public-key fingerprints and warnings for later identity changes.
- macOS 26 SwiftUI WebKit streaming renderer with Gemini-link interception and controlled resources.
- Gemini URL normalization and request serialization.
- Network.framework Gemini transport with TLS 1.2+, cancellation, and incremental response events.
- Strict incremental response-header decoder.
- Chunk-safe UTF-8 decoder and Gemtext parser.
- Safe streaming HTML presentation with a restrictive content security policy.
- SHA-256 Subject Public Key Info fingerprint extraction.
- Seed, first-use, changed-key, seed-mismatch, and certificate-date trust decisions.
- Atomic persistent trusted-identity store.
- Per-tab history/cache/zoom, persistent browsing history, source viewing, saving, and downloads.
- Application/content themes, inline formatting controls, and bounded same-capsule image loading.
- Gemini proxy for web links, idle timeout, response-size limits, find, native commands, and browsing-data controls.
- Bookmarks with folders, a Favourites bar, and a manager at `about:bookmarks`.
- Capsule favicons per the favicon RFC, cached for a week and never prefetched.
- Page Info with domain, expiry and trust checks, and copyable certificate and public-key fingerprints.
- Link hints for destination and type, and image links that expand in place on click.
- Archived captures offered through Delorean when a capsule is gone or unreachable.
- Seeded capsule identities read from `certs.csv` in Application Support.
- Request-budget feedback and retained drafts when answering a capsule's input prompt.
- `view-source:` and `about:` addresses, and local files opened by drag or from Finder.

## Build and test

From this directory:

```bash
swift test
```

Run the development executable directly:

```bash
swift run MajorTom
```

Or build an ad-hoc signed development application bundle:

```bash
Scripts/build-app.sh
open ".build/Major Tom.app"
```

The restricted Codex environment needs its Swift caches redirected to a writable location; normal local Terminal and Xcode use do not.

The live transport test is opt-in:

```bash
MAJOR_TOM_LIVE_TEST=1 swift test --filter GeminiTransportIntegrationTests
```

The Swift package can also be opened directly in Xcode. Major Tom currently targets macOS 26 because its renderer uses the native SwiftUI WebKit streaming APIs introduced in that release. The application-bundle script is intended for local development; Developer ID signing, notarization, and distributable packaging remain release work.
