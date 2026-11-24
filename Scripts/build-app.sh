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
        build_channel="development"
        cloud_environment="Development"
        icon_name="AppIconDevelopment"
        app_name="Major Tom Development"
        short_version="0.0.0"
        ;;
    release)
        swift_configuration="release"
        output_directory="Release"
        build_channel="production"
        cloud_environment="Production"
        icon_name="AppIcon"
        app_name="Major Tom"
        short_version="${MAJOR_TOM_SHORT_VERSION:-}"
        if [[ ! "$short_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
            echo "A production build requires a three-part MAJOR_TOM_SHORT_VERSION." >&2
            exit 2
        fi
        ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

cd "$project_root"
entitlements_path="${MAJOR_TOM_ENTITLEMENTS_PATH:-$project_root/Entitlements/MajorTom.$build_channel.entitlements}"
if [[ "$build_channel" == "production" ]]; then
    entitlements_path="${MAJOR_TOM_ENTITLEMENTS_PATH:-$project_root/Entitlements/MajorTom.release.entitlements}"
    if [[ "${MAJOR_TOM_CODESIGN_IDENTITY:--}" == "-" || -z "${MAJOR_TOM_PROVISIONING_PROFILE:-}" ]]; then
        echo "Production builds require a signing identity and provisioning profile. Use make release major|minor|patch." >&2
        exit 2
    fi
fi
if [[ "${MAJOR_TOM_CODESIGN_IDENTITY:--}" != "-" || -n "${MAJOR_TOM_PROVISIONING_PROFILE:-}" ]]; then
    requested_cloud="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$entitlements_path" 2>/dev/null || true)"
    if [[ "$requested_cloud" != "$cloud_environment" ]]; then
        echo "The $build_channel app requires the $cloud_environment CloudKit environment." >&2
        exit 2
    fi
fi
# Indexing-while-building exists to feed an editor's index and does nothing for a
# packaging build. It also writes thousands of small files into .build and renames each
# into place, which fails outright when a checkout lives on a volume where another
# process — an editor's own index-build — is writing the same store concurrently. The
# build then dies with "failed writing record … File exists" despite the sources being
# fine, so it is switched off here rather than left to break the bundle.
swift_arguments=(build -c "$swift_configuration" --disable-index-store)
scratch_path="$project_root/.build"
if [[ "$(df -P . | awk 'NR == 2 { print $1 }')" == //* ]]; then
    scratch_path="${MAJOR_TOM_SCRATCH_PATH:-$HOME/Library/Caches/MajorTom/build}"
    swift_arguments+=(--scratch-path "$scratch_path")
fi
if [[ "${MAJOR_TOM_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    swift_arguments+=(--disable-sandbox)
fi
swift "${swift_arguments[@]}"

app="$project_root/Build/$output_directory/Major Tom.app"
legacy_app="$project_root/.build/Major Tom.app"
contents="$app/Contents"
executable="$scratch_path/$swift_configuration/MajorTom"

rm -rf "$app" "$legacy_app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$executable" "$contents/MacOS/MajorTom"
# SwiftPM's generated resource accessor searches beside the executable and at the
# main bundle's resource root. Ship the CSS resource bundle in the latter location.
cp -R "$scratch_path/$swift_configuration/MajorTom_MajorTomCore.bundle" "$contents/Resources/"
cp "$project_root/Resources/Info.plist" "$contents/Info.plist"
cp "$project_root/Resources/$icon_name.icns" "$contents/Resources/$icon_name.icns"
cp "$project_root/Resources/funpack.dat" "$contents/Resources/funpack.dat"
cp "$project_root/Resources/lagrange-data-export.mp4" "$contents/Resources/lagrange-data-export.mp4"
cp "$project_root/Resources/alhena-data-export.mp4.mp4" "$contents/Resources/alhena-data-export.mp4"

# --- Version stamping -------------------------------------------------------
# Build identity describes this packaging run, including uncommitted iterations.
build_time="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
commit="$(git -C "$project_root" rev-parse HEAD 2>/dev/null || true)"
commit_sha="${commit:0:7}"
[[ -n "$commit_sha" ]] || commit_sha="unknown"

branch="$(git -C "$project_root" branch --show-current 2>/dev/null || true)"
[[ -n "$branch" ]] || branch="detached"

# The historical commit count is only an initial floor. Thereafter each package
# advances a durable counter, even when Git has not changed. Production also
# accepts the floor recorded in GitHub drafts and published releases.
minimum_build="$(git -C "$project_root" rev-list --count HEAD 2>/dev/null || echo 0)"
remote_minimum="${MAJOR_TOM_MINIMUM_BUILD_NUMBER:-0}"
if [[ ! "$remote_minimum" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "Invalid minimum build number." >&2
    exit 2
fi
(( remote_minimum <= minimum_build )) || minimum_build="$remote_minimum"
build_number="$(python3 "$project_root/Scripts/build_number.py" "$build_channel" --minimum "$minimum_build")"
build_info="Build $build_number - $build_time - $commit_sha - $branch"
if [[ -n "$(git -C "$project_root" status --porcelain 2>/dev/null)" ]]; then
    build_info="$build_info (modified)"
fi

plist="$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $short_version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $icon_name" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$plist"
/usr/libexec/PlistBuddy -c "Set :MTBuildChannel $build_channel" "$plist"
/usr/libexec/PlistBuddy -c "Add :MTBuildCommit string $commit" "$plist"
/usr/libexec/PlistBuddy -c "Set :MTBuildInfo $build_info" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :MTBuildInfo string $build_info" "$plist"

signing_identity="${MAJOR_TOM_CODESIGN_IDENTITY:--}"
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
    signed_cloud="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$signed_entitlements" 2>/dev/null || true)"
    rm -f "$signed_entitlements"
    if [[ "$signed_container" != "iCloud.dev.gemi.major-tom" \
        || "$signed_cloud" != "$cloud_environment" \
        || "$signed_aps" != "$requested_aps" \
        || "$signed_kvstore" != "7PDU8G67DD.dev.gemi.major-tom" ]]; then
        echo "Signed app is missing a required Major Tom iCloud entitlement." >&2
        exit 2
    fi
fi

echo "$app"
echo "Version $short_version ($build_number) - $build_info"
