# Build Major Tom

Major Tom is a Swift package targeting macOS 26. You need macOS 26 and Xcode 26 (or its matching Swift toolchain).

All development commands use SwiftPM's standard `.build` directory, so tests,
direct executable builds, and application packaging reuse one build cache.

## Development

Run the test suite from the repository root:

```bash
swift test
```

Run the development executable directly:

```bash
swift run MajorTom
```

Or build an ad-hoc-signed application bundle:

```bash
Scripts/build-app.sh
open "Build/Development/Major Tom.app"
```

The ad-hoc build intentionally excludes iCloud entitlements. To exercise CloudKit and iCloud Keychain, provide an Apple Development identity and provisioning profile authorized for `iCloud.dev.gemi.major-tom`:

```bash
MAJOR_TOM_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
MAJOR_TOM_PROVISIONING_PROFILE="/absolute/path/to/Major Tom Development.provisionprofile" \
Scripts/build-app.sh
```

For a reusable local development-signing setup, create `private/env/build-local.env` with those same two variables. The `private/env/` directory is ignored by Git; the release setup below shows how to create it from scratch.

The first development use creates Major Tom's private CloudKit zone and record types. In CloudKit Console, add a `QUERYABLE` index for the `recordName` field of every synchronized record type before testing sync:

- `MTPreferences`
- `MTDeviceTabs`
- `MTClientCertificateDescriptor`
- `MTClientCertificateAssociation`
- `MTBookmarkFolder`
- `MTBookmark`
- `MTServerTrust`

Major Tom queries these types to retrieve the current contents of its custom zone without replaying the zone's complete change history. Deploy the indexed development schema to production before distributing a production build.

The live transport test is opt-in:

```bash
MAJOR_TOM_LIVE_TEST=1 swift test --filter GeminiTransportIntegrationTests
```

## Notarized release

Distribution happens locally; this repository does not use GitHub Actions. `make prod` builds, signs, notarizes, staples, and zips the app. `make release` additionally creates a draft GitHub Release for human review.

One-time setup:

1. In CloudKit Console, deploy the `iCloud.dev.gemi.major-tom` development schema to production and enable the container for `dev.gemi.major-tom`.
2. Create and export a password-protected **Developer ID Application** certificate. Create and download a Developer ID provisioning profile with the iCloud/CloudKit capability.
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

The first production build stores the notary credential in the login keychain as `major-tom-notary`. You can then remove the three `MAJOR_TOM_NOTARY_*` variables from the local file if desired.

Build and test a release:

```bash
make prod VERSION=v2026.08.30
```

The ZIP and checksum are written to `Build/Release/`. Test the unzipped app before release.

When the release is ready for review, authenticate the GitHub CLI and create a draft:

```bash
gh auth login
make release VERSION=v2026.08.30
```

For a second release on the same day, append a numeric suffix to the GitHub tag:

```bash
make release VERSION=v2026.08.30-2
```

The app continues to use `2026.8.30` as its marketing version; its monotonically increasing build number distinguishes the builds.

Review the generated notes and assets in GitHub, then publish the draft manually.
