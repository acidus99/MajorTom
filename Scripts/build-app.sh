#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
local_config="$project_root/private/env/build-local.env"
requested_signing_identity="${MAJOR_TOM_CODESIGN_IDENTITY:-}"
requested_provisioning_profile="${MAJOR_TOM_PROVISIONING_PROFILE:-}"
if [[ -f "$local_config" ]]; then
    # Machine-specific signing identity and provisioning-profile path. This file is
    # ignored by Git because neither value belongs in a shared build configuration.
    source "$local_config"
fi
# A caller can deliberately override the development defaults in private/env/build-local.env,
# for example when the local release script switches to a Developer ID identity.
[[ -z "$requested_signing_identity" ]] || MAJOR_TOM_CODESIGN_IDENTITY="$requested_signing_identity"
[[ -z "$requested_provisioning_profile" ]] || MAJOR_TOM_PROVISIONING_PROFILE="$requested_provisioning_profile"

configuration="${1:-debug}"

case "$configuration" in
    debug)
        swift_configuration="debug"
        output_directory="Development"
        ;;
    release)
        swift_configuration="release"
        output_directory="Release"
        ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

cd "$project_root"
# Indexing-while-building exists to feed an editor's index and does nothing for a
# packaging build. It also writes thousands of small files into .build and renames each
# into place, which fails outright when a checkout lives on a volume where another
# process — an editor's own index-build — is writing the same store concurrently. The
# build then dies with "failed writing record … File exists" despite the sources being
# fine, so it is switched off here rather than left to break the bundle.
swift_arguments=(build -c "$swift_configuration" --disable-index-store)
if [[ "${MAJOR_TOM_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    swift_arguments+=(--disable-sandbox)
fi
swift "${swift_arguments[@]}"

app="$project_root/Build/$output_directory/Major Tom.app"
legacy_app="$project_root/.build/Major Tom.app"
contents="$app/Contents"
executable="$project_root/.build/$swift_configuration/MajorTom"

rm -rf "$app" "$legacy_app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$executable" "$contents/MacOS/MajorTom"
cp "$project_root/Resources/Info.plist" "$contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$contents/Resources/AppIcon.icns"
cp "$project_root/Resources/funpack.dat" "$contents/Resources/funpack.dat"
cp "$project_root/Resources/lagrange-data-export.mp4" "$contents/Resources/lagrange-data-export.mp4"
cp "$project_root/Resources/alhena-data-export.mp4.mp4" "$contents/Resources/alhena-data-export.mp4"

# --- Version stamping -------------------------------------------------------
# Mirrors Kennedy's scheme (Server/Kennedy.Server.csproj): identify a build by the
# date of the commit it came from, plus the short hash and branch. Nothing to bump
# by hand, and every build is traceable to an exact commit.
commit_date="$(git -C "$project_root" log -1 --format=%cd --date=format:'%Y/%m/%d' 2>/dev/null || true)"
[[ -n "$commit_date" ]] || commit_date="$(date -u +'%Y/%m/%d')"

commit_sha="$(git -C "$project_root" rev-parse --short=7 HEAD 2>/dev/null || true)"
[[ -n "$commit_sha" ]] || commit_sha="unknown"

branch="$(git -C "$project_root" branch --show-current 2>/dev/null || true)"
[[ -n "$branch" ]] || branch="detached"

# Commit count is monotonically increasing, which is exactly what CFBundleVersion
# requires between builds of the same short version.
build_number="${MAJOR_TOM_BUILD_NUMBER:-}"
if [[ -z "$build_number" ]]; then
    build_number="$(git -C "$project_root" rev-list --count HEAD 2>/dev/null || true)"
fi
[[ -n "$build_number" ]] || build_number="0"

# CFBundleShortVersionString must be dot-separated integers, so strip leading zeros.
short_version="${MAJOR_TOM_SHORT_VERSION:-}"
if [[ -z "$short_version" ]]; then
    short_version="$(echo "$commit_date" | awk -F/ '{ printf "%d.%d.%d", $1, $2, $3 }')"
fi

build_info="${MAJOR_TOM_BUILD_INFO:-}"
if [[ -z "$build_info" ]]; then
    build_info="$commit_date - $commit_sha - $branch"
    if ! git -C "$project_root" diff --quiet HEAD 2>/dev/null; then
        build_info="$build_info (modified)"
    fi
fi

plist="$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $short_version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
/usr/libexec/PlistBuddy -c "Set :MTBuildInfo $build_info" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :MTBuildInfo string $build_info" "$plist"

signing_identity="${MAJOR_TOM_CODESIGN_IDENTITY:--}"
entitlements_path="${MAJOR_TOM_ENTITLEMENTS_PATH:-$project_root/Entitlements/MajorTom.development.entitlements}"
provisioning_profile="${MAJOR_TOM_PROVISIONING_PROFILE:-}"
signing_is_configured=false
if [[ "$signing_identity" != "-" || -n "$provisioning_profile" ]]; then
    signing_is_configured=true
fi
if [[ "$signing_identity" != "-" ]] \
    && ! security find-identity -v -p codesigning | grep -Fq -- "$signing_identity"; then
    echo "Configured code-signing identity is not valid in this keychain: $signing_identity" >&2
    exit 2
fi
if [[ "$signing_is_configured" == true && "$signing_identity" == "-" ]]; then
    echo "A provisioning profile requires an Apple-issued signing identity." >&2
    exit 2
fi
if [[ "$signing_is_configured" == true && ! -f "$provisioning_profile" ]]; then
    echo "Provisioning profile not found: ${provisioning_profile:-<not configured>}" >&2
    exit 2
fi
if [[ "$signing_is_configured" == true ]]; then
    profile_plist="$(mktemp)"
    if ! security cms -D -i "$provisioning_profile" > "$profile_plist" 2>/dev/null \
        && ! openssl cms -verify -inform DER -in "$provisioning_profile" \
            -noverify -nosigs -out "$profile_plist" 2>/dev/null; then
        rm -f "$profile_plist"
        echo "Could not decode provisioning profile: $provisioning_profile" >&2
        exit 2
    fi
    requested_aps="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.aps-environment' "$entitlements_path" 2>/dev/null || true)"
    profile_aps="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.aps-environment' "$profile_plist" 2>/dev/null || true)"
    profile_container="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-identifiers:0' "$profile_plist" 2>/dev/null || true)"
    profile_kvstore="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.ubiquity-kvstore-identifier' "$profile_plist" 2>/dev/null || true)"
    rm -f "$profile_plist"
    if [[ "$profile_aps" != "$requested_aps" ]]; then
        echo "Provisioning profile does not authorize the requested $requested_aps APNs environment." >&2
        exit 2
    fi
    if [[ "$profile_container" != "iCloud.dev.gemi.major-tom" ]]; then
        echo "Provisioning profile does not authorize iCloud.dev.gemi.major-tom." >&2
        exit 2
    fi
    if [[ "$profile_kvstore" != "7PDU8G67DD.dev.gemi.major-tom" \
        && "$profile_kvstore" != "7PDU8G67DD.*" ]]; then
        echo "Provisioning profile does not authorize Major Tom's iCloud Key-Value Store." >&2
        exit 2
    fi
fi
if [[ "$signing_identity" == "-" ]]; then
    # Restricted iCloud entitlements require an Apple-issued signing identity.
    # Putting them on an ad-hoc signature makes macOS kill the executable before
    # launch (LaunchServices reports RBSRequestErrorDomain Code=5 / POSIX 163).
    codesign --force --sign - "$app"
    echo "Note: iCloud sync is unavailable in this ad-hoc signed build." >&2
else
    if [[ ! -f "$entitlements_path" ]]; then
        echo "Entitlements file not found: $entitlements_path" >&2
        exit 2
    fi
    if [[ -n "$provisioning_profile" ]]; then
        cp "$provisioning_profile" "$contents/embedded.provisionprofile"
    else
        echo "Note: CloudKit requires a provisioning profile authorizing iCloud.dev.gemi.major-tom." >&2
        echo "Set MAJOR_TOM_PROVISIONING_PROFILE if the signing workflow does not embed one elsewhere." >&2
    fi
    codesign --force --sign "$signing_identity" \
        --entitlements "$entitlements_path" "$app"
    signed_entitlements="$(mktemp)"
    codesign -d --entitlements :- "$app" > "$signed_entitlements" 2>/dev/null
    signed_container="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' "$signed_entitlements" 2>/dev/null || true)"
    signed_aps="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.aps-environment' "$signed_entitlements" 2>/dev/null || true)"
    signed_kvstore="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.ubiquity-kvstore-identifier' "$signed_entitlements" 2>/dev/null || true)"
    rm -f "$signed_entitlements"
    if [[ "$signed_container" != "iCloud.dev.gemi.major-tom" \
        || "$signed_aps" != "$requested_aps" \
        || "$signed_kvstore" != "7PDU8G67DD.dev.gemi.major-tom" ]]; then
        echo "Signed app is missing a required Major Tom iCloud entitlement." >&2
        exit 2
    fi
fi

echo "$app"
echo "Version $short_version ($build_number) - $build_info"
