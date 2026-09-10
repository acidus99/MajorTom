#!/bin/bash
set -euo pipefail

# Runs the test suite so that a failure is always a nonzero exit.
#
# Two separate problems make a plain `swift test` unreliable as a verification gate:
#
# 1. XCTest ships with Xcode, not with the Command Line Tools. When xcode-select points
#    at the CLT, every test target fails to compile with "no such module 'XCTest'".
# 2. `swift test` exits 0 when a test target fails to *compile*. Combined with (1) the
#    suite reports success while executing zero tests, which is worse than a red build.
#
# Neither an Xcode path nor a developer directory is written down here: the toolchain is
# whatever the caller selected, and Xcode is located by bundle identifier when the
# selected toolchain cannot build tests at all.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

# `xcrun` honors DEVELOPER_DIR, so this also answers "did the caller already pick a
# usable toolchain?" without treating that case specially.
toolchain_has_xctest() {
    xcrun --find xctest >/dev/null 2>&1
}

# Recorded before anything below exports DEVELOPER_DIR, because `xcode-select -p` honors
# that variable too and would otherwise report the toolchain this script just chose.
selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"

if ! toolchain_has_xctest; then
    # Ask Launch Services' index where Xcode is rather than naming a location, so a
    # machine that keeps Xcode outside /Applications, or ships several versions, still
    # resolves. The first candidate that can actually find xctest wins.
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        candidate_developer_dir="$candidate/Contents/Developer"
        [[ -d "$candidate_developer_dir" ]] || continue
        if DEVELOPER_DIR="$candidate_developer_dir" xcrun --find xctest >/dev/null 2>&1; then
            export DEVELOPER_DIR="$candidate_developer_dir"
            echo "note: ${selected_developer_dir:-the selected toolchain} has no XCTest." >&2
            echo "note: building tests with $candidate instead." >&2
            break
        fi
    done < <(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null || true)
fi

if ! toolchain_has_xctest; then
    cat >&2 <<'MESSAGE'
error: the selected developer toolchain cannot build tests, because XCTest is part of
       Xcode rather than the Command Line Tools, and no installed Xcode was found.

       Install Xcode, then point the toolchain at it:

           sudo xcode-select -s /path/to/Xcode.app

       Or select one for a single run without changing the system setting:

           DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer make test
MESSAGE
    exit 1
fi

swift_flags=(--disable-index-store)

# A `.build` written over SMB embeds the mount's absolute paths, so it cannot be shared
# with the Mac that owns the files: whichever machine did not write it fails with
# "precompiled file … was compiled with module cache path …". Keep SwiftPM's scratch
# directory off the share when the checkout is on a network volume. The location is
# derived from $HOME rather than named, and a caller can override it.
if [[ "$(df -P . | awk 'NR == 2 { print $1 }')" == //* ]]; then
    scratch_path="${MAJOR_TOM_SCRATCH_PATH:-$HOME/Library/Caches/MajorTom/tests}"
    swift_flags+=(--scratch-path "$scratch_path")
    echo "note: checkout is on a network volume; building in $scratch_path." >&2
fi

# The compile is gated on its own because this is the step whose failure `swift test`
# reports as success. `swift build --build-tests` returns nonzero for exactly that case,
# and leaves the products `swift test` then reuses, so this is not a second full build.
swift build --build-tests "${swift_flags[@]}" "$@"
swift test "${swift_flags[@]}" "$@"
