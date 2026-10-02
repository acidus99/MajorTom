#!/bin/bash
set -euo pipefail

# Read-only CloudKit SDK diagnosis using an already provisioned DEVELOPMENT bundle.
# Leaves its generated signed bundle in a private temporary directory for inspection.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
probe_database="${1:?Usage: bash Scripts/run-cloud-sync-fetch-probe.sh /path/to/closed/MajorTom.db [--automatic]}"
probe_mode="${2:-}"
if [[ -n "$probe_mode" && "$probe_mode" != "--automatic" ]]; then
    echo 'Only --automatic is supported as the optional mode.' >&2
    exit 2
fi
if pgrep -x MajorTom >/dev/null; then
    echo 'Quit Major Tom before running the isolated probe.' >&2
    exit 1
fi
if [[ ! -f "$probe_database" || -e "$probe_database-wal" || -e "$probe_database-shm" ]]; then
    echo 'Use a closed, fully checkpointed database with no WAL/SHM sidecars.' >&2
    exit 1
fi
local_config="$project_root/private/env/build-local.env"
[[ ! -f "$local_config" ]] || source "$local_config"
: "${MAJOR_TOM_CODESIGN_IDENTITY:?Configure the existing development signing identity first.}"
source_app="$project_root/Build/Development/Major Tom.app"
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/majortom-fetch-probe.XXXXXX")"
codesign -d --entitlements :- "$source_app" > "$probe_root/entitlements.plist" 2>/dev/null
probe_environment="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$probe_root/entitlements.plist")"
if [[ "$probe_environment" != Development ]]; then
    echo 'This probe requires a Development CloudKit entitlement, never Production.' >&2
    exit 1
fi
probe_contents="$probe_root/Probe.app/Contents"
mkdir -p "$probe_contents/MacOS"
cp "$source_app/Contents/Info.plist" "$probe_contents/Info.plist"
cp "$source_app/Contents/embedded.provisionprofile" "$probe_contents/embedded.provisionprofile"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos26.0" \
    "$project_root/Scripts/cloud-sync-fetch-probe.swift" -o "$probe_contents/MacOS/MajorTom"
codesign --force --sign "$MAJOR_TOM_CODESIGN_IDENTITY" \
    --entitlements "$probe_root/entitlements.plist" "$probe_root/Probe.app"
# SQLite's immutable mode avoids creating SHM files in the source folder. The closed-
# database checks above are essential: immutable mode does not read an active WAL.
sqlite3 -readonly "file:$probe_database?immutable=1" \
    "SELECT CAST(engine_state AS TEXT) FROM cloud_sync_state WHERE account_identity_hash = (SELECT CAST(value AS TEXT) FROM persistence_metadata WHERE key = 'cloud-sync-active-account-v2');" \
    | "$probe_contents/MacOS/MajorTom" ${probe_mode:+"$probe_mode"}
echo "Probe bundle retained at $probe_root/Probe.app; app database unchanged."
