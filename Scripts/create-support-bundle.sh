#!/bin/bash
set -euo pipefail

# Creates a privacy-conscious Major Tom diagnostic archive. It intentionally does not
# copy application databases, bookmark JSON, cached content, preferences, or Keychain
# items. Those can contain URLs, titles, certificate metadata, or private material.

usage() {
    cat <<'MESSAGE'
Usage: Scripts/create-support-bundle.sh [--last 2h] [--output DIRECTORY]

Collect recent Major Tom unified logs and a redacted local sync-state summary into a zip
archive. The default time window is two hours and the default output directory is Desktop.
MESSAGE
}

window="2h"
output_directory="$HOME/Desktop"

while [[ $# -gt 0 ]]; do
    case "$1" in
    --last)
        [[ $# -ge 2 ]] || { usage >&2; exit 2; }
        window="$2"
        shift 2
        ;;
    --output)
        [[ $# -ge 2 ]] || { usage >&2; exit 2; }
        output_directory="$2"
        shift 2
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
    esac
done

if [[ ! "$window" =~ ^[1-9][0-9]*[mhd]$ ]]; then
    echo "error: --last must be a positive duration such as 30m, 2h, or 1d." >&2
    exit 2
fi

mkdir -p "$output_directory"
bundle_name="MajorTom-support-$(date +%Y%m%d-%H%M%S)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/${bundle_name}.XXXXXX")"
bundle_directory="$temporary_directory/$bundle_name"
mkdir -p "$bundle_directory"
trap 'rm -rf "$temporary_directory"' EXIT

cat > "$bundle_directory/README.txt" <<MESSAGE
Major Tom support bundle
Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Unified-log window: $window

This archive contains Major Tom's own unified-log entries and a redacted summary of
local CloudKit state. It intentionally excludes databases, bookmarks, browsing history,
cached pages, preferences, certificates, and Keychain items.

The unified log can still contain URLs or other details you exposed while using the app.
Review it before sharing if that is a concern.
MESSAGE

log show --last "$window" --style compact --info --debug \
    --predicate 'subsystem == "dev.gemi.major-tom"' \
    > "$bundle_directory/MajorTom-unified.log" 2>&1 || true

{
    echo "Collected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sw_vers
    uname -m
    echo
    echo "Major Tom applications found:"
    find /Applications "$HOME/Applications" -maxdepth 1 -name 'Major Tom.app' -type d \
        -print 2>/dev/null || true
} > "$bundle_directory/system.txt"

database="$HOME/Library/Application Support/Major Tom/MajorTom.sqlite"
if [[ -f "$database" ]] && command -v sqlite3 >/dev/null; then
    sqlite3 -readonly "$database" <<'SQL' > "$bundle_directory/sync-state.txt" 2>&1 || true
.headers on
.mode column
SELECT 'database_integrity' AS check_name, integrity_check AS result
FROM pragma_integrity_check;

SELECT model_major, migrated_from_v1, migration_phase, zone_state,
       last_fetched_at, last_sent_at, updated_at
FROM cloud_sync_state;

SELECT record_type, operation, COUNT(*) AS pending_changes,
       MIN(enqueued_at) AS oldest_enqueued_at, MAX(enqueued_at) AS newest_enqueued_at
FROM cloud_pending_changes
GROUP BY record_type, operation
ORDER BY record_type, operation;

SELECT record_type, COUNT(*) AS locally_known_records,
       MAX(updated_at) AS last_record_state_update
FROM cloud_record_state
GROUP BY record_type
ORDER BY record_type;

SELECT COUNT(*) AS bookmark_folders FROM bookmark_folders;
SELECT COUNT(*) AS bookmarks FROM bookmarks;
SQL
else
    echo "No readable Major Tom database was found." > "$bundle_directory/sync-state.txt"
fi

archive="$output_directory/$bundle_name.zip"
ditto -c -k --sequesterRsrc --keepParent "$bundle_directory" "$archive"
echo "Created $archive"
