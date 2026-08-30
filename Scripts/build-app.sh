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
# Clang module caches embed the checkout's absolute path. The same working tree can
# be reached through different paths when it is shared over SMB, so sharing one
# SwiftPM scratch directory causes otherwise valid cached modules to fail with
# "compiled with module cache path ... but the path is currently ...". Keep a
# separate scratch directory for each absolute checkout path. SwiftPM's compiler
# artifacts remain in its hidden .build directory, while the finished application
# is packaged in the visible Build directory for convenient use from Finder.
scratch_key="$(printf '%s' "$project_root" | shasum -a 256 | cut -c1-12)"
scratch_path="$project_root/.build/swiftpm-$scratch_key"

# Indexing-while-building exists to feed an editor's index and does nothing for a
# packaging build. It also writes thousands of small files into .build and renames each
# into place, which fails outright when a checkout lives on a volume where another
# process — an editor's own index-build — is writing the same store concurrently. The
# build then dies with "failed writing record … File exists" despite the sources being
# fine, so it is switched off here rather than left to break the bundle.
swift_arguments=(build -c "$swift_configuration" --disable-index-store --scratch-path "$scratch_path")
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
cp "$project_root/Resources/Info.plist" "$contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$contents/Resources/AppIcon.icns"

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
    provisioning_profile="${MAJOR_TOM_PROVISIONING_PROFILE:-}"
    if [[ -n "$provisioning_profile" ]]; then
        if [[ ! -f "$provisioning_profile" ]]; then
            echo "Provisioning profile not found: $provisioning_profile" >&2
            exit 2
        fi
        cp "$provisioning_profile" "$contents/embedded.provisionprofile"
    else
        echo "Note: CloudKit requires a provisioning profile authorizing iCloud.dev.gemi.major-tom." >&2
        echo "Set MAJOR_TOM_PROVISIONING_PROFILE if the signing workflow does not embed one elsewhere." >&2
    fi
    codesign --force --sign "$signing_identity" \
        --entitlements "$entitlements_path" "$app"
fi

echo "$app"
echo "Version $short_version ($build_number) - $build_info"
