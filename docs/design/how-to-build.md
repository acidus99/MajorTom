# Build Major Tom

Major Tom is a Swift package targeting macOS 26. You need macOS 26 and Xcode 26 (or its matching Swift toolchain).

All development commands use SwiftPM's standard `.build` directory, so tests,
direct executable builds, and application packaging reuse one build cache. The one
exception is a checkout on a network volume, where `make test` builds outside the share
instead: a `.build` written over SMB embeds the mount's absolute paths and fails for
whichever machine did not write it.

## Development

Build the development app from the repository root:

```bash
make dev
open "Build/Development/Major Tom.app"
```

`make dev` and `make release major|minor|patch` run their required checks internally;
there is no separate test step for either workflow. The `make test` target remains
an engineering convenience. `Scripts/run-tests.sh` gates compilation on
`swift build --build-tests`, whose exit code is reliable, and falls back to an
installed Xcode (located by bundle identifier) when the selected toolchain has no
XCTest. Set `DEVELOPER_DIR` to choose a specific one.

Run the development executable directly:

```bash
swift run MajorTom
```

Or build an ad-hoc-signed application bundle:

```bash
Scripts/build-app.sh
open "Build/Development/Major Tom.app"
```

`make dev` runs the tests and packages the development app. It uses the orange
DEVELOPMENT icon and displays `Development Build N` in About. Every packaged build
gets a new number, including builds of uncommitted changes. Detailed diagnostics
remain in bundle metadata: packaging time in UTC, commit, branch, and modified state.
About shows only the development build number. `swift run`
has no stamped app bundle and reports Local Development Build instead.

`make dev` and `make test` show stage progress and a combined test summary. Complete
compiler, test, and packaging output is retained in a private log under
`/tmp/MajorTom`; the command prints its path. Failures stop the command, show error
details, and point to the full log. For raw test output or test filters, run
`Scripts/run-tests.sh` directly. The runner compiles once, then executes the built
XCTest suites; the unused Swift Testing runner is disabled.

Build counters live outside the checkout and disposable build output, in
`~/Library/Application Support/Major Tom Builds`. Development and production have
separate counters shared by this Mac's checkouts. Counter allocation is locked and
atomic; failed packaging may leave gaps. The historical commit count is only a
minimum when allocating a number, not the build identity. Set
`MAJOR_TOM_BUILD_STATE_DIRECTORY` to use a different persistent directory, for
example a temporary directory during packaging tests. Copying a built app to another
Mac preserves its build number; independently building development apps on different
Macs does not coordinate their counters.

The ad-hoc build intentionally excludes iCloud entitlements. To exercise CloudKit and iCloud Keychain, provide an Apple Development identity and provisioning profile authorized for `iCloud.dev.gemi.major-tom`:

```bash
MAJOR_TOM_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
MAJOR_TOM_PROVISIONING_PROFILE="/absolute/path/to/Major Tom Development.provisionprofile" \
Scripts/build-app.sh
```

For debug builds with no signing configuration, the packaging script creates an ad-hoc-signed,
launchable app without iCloud sync. Once either development-signing variable is configured, the
script requires both a valid signing identity and a profile authorizing the requested APNs,
CloudKit container, and iCloud Key-Value Store entitlements. It also verifies those entitlements
on the final signed app. A setup error fails the build instead of silently producing a build
without iCloud sync. Release builds have the same requirement.

For a reusable local development-signing setup, create `private/env/build-local.env` with those same two variables. The `private/env/` directory is ignored by Git; the release setup below shows how to create it from scratch.

The first development use creates Major Tom's private CloudKit zone and record types. Every
record type has one encrypted `payload` field. `CKSyncEngine` uses durable change tokens and
record IDs, so no `QUERYABLE` indexes are required. The synchronized record types are:

- `MTDeviceTabs`
- `MTClientCertificateDescriptor`
- `MTClientCertificateAssociation`
- `MTBookmarkFolder`
- `MTBookmark`
- `MTDataModelManifest`

The development and release provisioning profiles must include CloudKit, remote notifications,
iCloud Key-Value Store, and iCloud Keychain. The checked-in entitlements use development and
production APNs environments respectively. Deploy the development CloudKit schema to production
before distributing a production build.

Production keeps the established `~/Library/Application Support/Major Tom` directory and standard
preferences domain. Development-signed and ad-hoc builds use `Major Tom Development`, a separate
preferences suite, a separate client-certificate Keychain namespace, and environment-specific
ubiquitous-preference keys. This lets both builds run on one Mac without sharing restored windows,
tabs, history, bookmarks, trust, identities, caches, or CloudKit state.

To trace synchronization on a development Mac without exposing tab URLs, titles, account IDs, or
certificate contents, stream Major Tom's structured CloudKit and bookmark diagnostics:

```bash
log stream --level debug --style compact \
  --predicate 'subsystem == "dev.gemi.major-tom" AND (category == "ICloudSync" OR category == "BookmarkSync")'
```

The log includes lifecycle and status transitions, record-type counts, opaque record IDs, favicon
observation counts, visible remote-device/tab counts, and complete CloudKit error codes and server
descriptions. Use `log show --last 15m` with the same predicate to collect a recent trace.

For a bug report, `Scripts/create-support-bundle.sh --last 2h` writes a ZIP archive to the
Desktop. It contains Major Tom's recent unified-log entries plus a redacted local CloudKit state
summary (database integrity, migration state, outbox and record-type counts). It deliberately
does not copy bookmark data, page bodies, preferences, certificates, or Keychain material. The
log itself can contain URLs involved in browser activity, so review the archive before sharing.

The ordinary TLS tests use macOS’s Python and OpenSSL to host a localhost server
with temporary synthetic keys. They do not use user Keychain items or remote capsules.

Performance characterization is separate from the functional suite. Run it explicitly:

```bash
MAJOR_TOM_PERFORMANCE_TESTS=1 Scripts/run-tests.sh --filter OmnibarIndexTests.testLargeHistorySearchPerformance
```

The live transport test is opt-in:

```bash
MAJOR_TOM_LIVE_TEST=1 swift test --disable-index-store --filter GeminiTransportIntegrationTests
```

## Notarized release

Distribution happens locally; this repository does not use GitHub Actions. There
are two app workflows: `make dev` for personal development, and
`make release major|minor|patch` for production candidates. Release preparation needs
Python 3 and an authenticated GitHub CLI in addition to the signing setup below.

One-time setup:

1. In CloudKit Console, deploy the `iCloud.dev.gemi.major-tom` development schema to production and enable the container for `dev.gemi.major-tom`.
2. Create and export a password-protected **Developer ID Application** certificate. Create and download a Developer ID provisioning profile with CloudKit, remote notifications, iCloud Key-Value Store, and iCloud Keychain capabilities.
3. In App Store Connect, create a notarization API key and securely store its one-time-downloadable `.p8` private key, Key ID, and Issuer ID.
4. Create the ignored local configuration directory and file. `private/` is ignored by Git, so it is safe for machine-local paths and credentials but must never be committed:

   ```bash
   mkdir -p private/env # also holds the optional build-local.env development config
   touch private/env/release-local.env
   ```

   Then add the following values to `private/env/release-local.env`:

   ```bash
   MAJOR_TOM_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
   MAJOR_TOM_PROVISIONING_PROFILE="/absolute/path/to/MajorTom.provisionprofile"
   MAJOR_TOM_NOTARY_KEY_PATH="/absolute/path/to/AuthKey_KEYID.p8"
   MAJOR_TOM_NOTARY_KEY_ID="YOUR_KEY_ID"
   MAJOR_TOM_NOTARY_ISSUER_ID="YOUR_ISSUER_ID"
   ```

The first production build stores the notary credential in the login keychain as
`major-tom-notary`. You can then remove the three `MAJOR_TOM_NOTARY_*` variables from
the local file if desired.

Commit the intended source changes and use a clean, named branch. Authenticate the
GitHub CLI with `gh auth login`, then choose exactly one version increment:

```bash
make release major
make release minor
make release patch
```

These are alternatives, not three steps. There is no default increment and no
manually maintained version file. The greatest numbered published full release on
GitHub supplies the current version; drafts and prereleases do not advance it.
From `1.8.2`, major produces `2.0`, minor produces `1.9`, and patch produces `1.8.3`.
Numbers are integer components: `1.9` advances to `1.10`. Unknown public version
formats and GitHub lookup failures stop preparation instead of guessing.

The command runs tests, builds, signs, notarizes, staples, and creates the ZIP and
checksum in `Build/Release/`. It pushes the source commit to the current branch on
`origin`, creates the version tag, and uploads a draft GitHub Release. Public titles
and About omit a zero patch component (`1.4`); tags and the app's
`CFBundleShortVersionString` always use three components (`v1.4.0` and `1.4.0`).
Normal releases increment minor; small corrections can increment patch; major is
an explicit product or compatibility decision. This is a desktop-app numbering
convention, not a claim of strict API-based Semantic Versioning.

If the same candidate version already has a draft, preparation first finishes the
replacement build and verifies that neither the source nor GitHub state changed.
It then deletes and recreates that draft, replaces its assets, and moves its tag to
the new source commit. Every rebuilt candidate gets a higher production build
number, even when the public version stays the same. Published releases are never
replaced. Tags without a matching draft require manual resolution. Build, signing,
notarization, and pre-upload validation failures leave the existing draft intact;
network failures during the final replacement can require inspecting GitHub and
resolving a leftover tag before retrying.

Production build numbers continue increasing across public versions. A hidden
`major-tom-build` comment in generated release notes records the number so another
Mac, or a Mac with missing local state, can allocate above existing public and draft
builds. Preserve that comment when editing notes. About shows only the public
version; the build number remains in bundle diagnostics. Future Mac App Store
distribution must also consult App Store Connect's build floor and coordinate the
same public version across channels; uploading and sandbox compatibility are not
part of the current GitHub release workflow.

Review the draft's notes and test its downloadable app, then publish manually on
GitHub. A draft contains the production app and uses production local and cloud
data. Personal development builds retain their separate local stores, Keychain
namespace, and CloudKit Development environment. Packaging rejects a signed build
whose CloudKit environment does not match its development or production channel.

The five historical releases are retrospectively named `1.0`, `1.1`, `1.1.1`, `1.2`,
and `1.3`, in publication order. Their original date tags, downloads, publication
dates, and binary metadata remain intact. Their release titles own the retrospective
version; future tags and titles agree. The next minor release after `1.3` is `1.4`.

### Content theme resources

The Core target's SwiftPM resource bundle contains `Base.css`, `Print.css`, the
built-in `Themes/*.css` files, and the separate `ThemeTemplates/*.css` starters.
The [theme-authoring reference](content-themes.md) owns their behavior. `Scripts/build-app.sh` copies
`MajorTom_MajorTomCore.bundle` into the app's `Contents/Resources` before signing.
Keep this bundle with the executable when packaging; built-in themes are never copied
into the editable Application Support Themes directory.

## Engineering and verification rules

- Use XCTest, not Swift Testing. Match surrounding code; there is no configured
  linter or formatter.
- Add tests for changed Core behavior in `Tests/MajorTomCoreTests`. Test observable
  behavior and invariants: source fidelity, escaping, round-trips, chunk boundaries,
  limits, cancellation, and readable contrast. A regression test names the bug it
  prevents in a comment.
- Never pin generated HTML/CSS to exact literals copied from implementation. Such
  tests restate constants rather than prove behavior; remove them instead of
  maintaining change detectors.
- Run `make test` after code changes. For changes to the app target, bundle resources,
  signing, or packaging, also run `Scripts/build-app.sh` or `make dev` (tests plus an
  ad-hoc bundle). Native UI changes need relevant keyboard/accessibility checks and
  light/dark verification. Documentation-only changes need link and consistency checks.
- Prefer controlled services and clocks for subsystem tests. Use actual temporary
  databases for repository/migration tests and focused WebKit/AppKit tests for
  platform behavior. Avoid live accounts or servers in the ordinary suite.
- Always pass `--disable-index-store` to direct `swift build` and `swift test`
  commands so an editor's indexer cannot collide with build records.
- Before building, run `df -P .`. If the checkout is on a `//server/share` SMB device,
  pass `--scratch-path "$HOME/Library/Caches/MajorTom/build"` to every direct
  `swift build`, `swift test`, and `swift run`; never write `.build` to that share.
  Remove a poisoned network `.build` before rebuilding. `make test` handles this
  automatically through its runner.
- `make release` and its notarization helper sign/notarize/publish and are human-run only.

The [UI design](subsystems/ui.md) records the native-control constraints that must
survive changes. The [Data Persistence design](subsystems/data-persistence.md) owns
storage and synchronization policy; this guide owns setup and operational commands.
