#!/bin/bash
set -euo pipefail

# Build a local Developer ID-signed, notarized ZIP. Signing material lives only
# in ignored local configuration files and the user's login keychain.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
private_config="$project_root/private/env/release-local.env"
legacy_config="$project_root/Scripts/release-local.env"
release_tag="${1:-${MAJOR_TOM_RELEASE_TAG:-}}"

if [[ -f "$private_config" ]]; then
    source "$private_config"
elif [[ -f "$legacy_config" ]]; then
    source "$legacy_config"
fi

# Local configuration may use paths relative to the repository, regardless of
# the directory from which this script was invoked.
cd "$project_root"

if [[ ! "$release_tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "Usage: $0 vMAJOR.MINOR.PATCH" >&2
    exit 2
fi

if [[ -z "${MAJOR_TOM_CODESIGN_IDENTITY:-}" ]]; then
    echo "Set MAJOR_TOM_CODESIGN_IDENTITY in private/env/release-local.env." >&2
    exit 2
fi
if [[ -z "${MAJOR_TOM_PROVISIONING_PROFILE:-}" || ! -f "$MAJOR_TOM_PROVISIONING_PROFILE" ]]; then
    echo "Set MAJOR_TOM_PROVISIONING_PROFILE to the Developer ID CloudKit profile." >&2
    exit 2
fi

notary_profile="${MAJOR_TOM_NOTARY_KEYCHAIN_PROFILE:-major-tom-notary}"
if [[ -n "${MAJOR_TOM_NOTARY_KEY_PATH:-}" ]]; then
    : "${MAJOR_TOM_NOTARY_KEY_ID:?Set MAJOR_TOM_NOTARY_KEY_ID alongside MAJOR_TOM_NOTARY_KEY_PATH}"
    : "${MAJOR_TOM_NOTARY_ISSUER_ID:?Set MAJOR_TOM_NOTARY_ISSUER_ID alongside MAJOR_TOM_NOTARY_KEY_PATH}"
    if [[ ! -f "$MAJOR_TOM_NOTARY_KEY_PATH" ]]; then
        echo "Notary API key not found: $MAJOR_TOM_NOTARY_KEY_PATH" >&2
        exit 2
    fi
    if ! security find-generic-password -s "com.apple.gke.notary.tool" -a "$notary_profile" >/dev/null 2>&1; then
        xcrun notarytool store-credentials "$notary_profile" \
            --key "$MAJOR_TOM_NOTARY_KEY_PATH" \
            --key-id "$MAJOR_TOM_NOTARY_KEY_ID" \
            --issuer "$MAJOR_TOM_NOTARY_ISSUER_ID"
    fi
elif ! security find-generic-password -s "com.apple.gke.notary.tool" -a "$notary_profile" >/dev/null 2>&1; then
    echo "No notary credentials found. Set MAJOR_TOM_NOTARY_KEY_PATH, MAJOR_TOM_NOTARY_KEY_ID, and MAJOR_TOM_NOTARY_ISSUER_ID in private/env/release-local.env." >&2
    exit 2
fi

version="${release_tag#v}"
build_number="${MAJOR_TOM_BUILD_NUMBER:-$(git -C "$project_root" rev-list --count HEAD)}"
export MAJOR_TOM_SHORT_VERSION="$version"
export MAJOR_TOM_BUILD_NUMBER="$build_number"
export MAJOR_TOM_BUILD_INFO="Notarized build $release_tag ($(git -C "$project_root" rev-parse --short=7 HEAD))"
export MAJOR_TOM_ENTITLEMENTS_PATH="$project_root/Entitlements/MajorTom.release.entitlements"
export MAJOR_TOM_CODESIGN_IDENTITY
export MAJOR_TOM_PROVISIONING_PROFILE

"$project_root/Scripts/build-app.sh" release

app="$project_root/Build/Release/Major Tom.app"
release_dir="$project_root/Build/Release"
submission_zip="$release_dir/MajorTom-$release_tag-notarization.zip"
archive="$release_dir/MajorTom-$release_tag-macos.zip"

mkdir -p "$release_dir"
rm -f "$submission_zip" "$archive" "$archive.sha256"

codesign --force --sign "$MAJOR_TOM_CODESIGN_IDENTITY" --timestamp --options runtime \
    --entitlements "$MAJOR_TOM_ENTITLEMENTS_PATH" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

ditto -c -k --keepParent "$app" "$submission_zip"
xcrun notarytool submit "$submission_zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl -a -vv --type execute "$app"

ditto -c -k --keepParent "$app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
rm "$submission_zip"

echo "$archive"
