#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"

case "$configuration" in
    debug)
        swift_configuration="debug"
        ;;
    release)
        swift_configuration="release"
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

app="$project_root/.build/Major Tom.app"
contents="$app/Contents"
executable="$project_root/.build/$swift_configuration/MajorTom"

rm -rf "$app"
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
build_number="$(git -C "$project_root" rev-list --count HEAD 2>/dev/null || true)"
[[ -n "$build_number" ]] || build_number="0"

# CFBundleShortVersionString must be dot-separated integers, so strip leading zeros.
short_version="$(echo "$commit_date" | awk -F/ '{ printf "%d.%d.%d", $1, $2, $3 }')"

build_info="$commit_date - $commit_sha - $branch"
if ! git -C "$project_root" diff --quiet HEAD 2>/dev/null; then
    build_info="$build_info (modified)"
fi

plist="$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $short_version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
/usr/libexec/PlistBuddy -c "Set :MTBuildInfo $build_info" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :MTBuildInfo string $build_info" "$plist"

codesign --force --sign - "$app"

echo "$app"
echo "Version $short_version ($build_number) - $build_info"
