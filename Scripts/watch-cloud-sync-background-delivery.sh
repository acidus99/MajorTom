#!/bin/bash
set -euo pipefail

# Observe, but never influence, delivery of one disposable CloudKit fixture.
#
# This script intentionally does not launch, focus, signal, or query Major Tom through
# its UI. It polls only the open SQLite database in read-only mode and captures the
# app's CloudKit unified-log events. Use it while Major Tom remains running in the
# background, so an activation or Sync Now cannot masquerade as background delivery.
#
# It prints fixture-state booleans rather than bookmark payloads. The expected title
# itself appears in the command invocation and should be a disposable test value.
if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo 'Usage: bash Scripts/watch-cloud-sync-background-delivery.sh /absolute/path/to/MajorTom.db fixture-url expected-title [timeout-seconds]' >&2
    exit 2
fi

database_path=$1
fixture_url=$2
expected_title=$3
timeout_seconds=${4:-300}

if [[ ! -f "$database_path" ]]; then
    echo "Database does not exist: $database_path" >&2
    exit 2
fi
if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || (( timeout_seconds > 900 )); then
    echo 'timeout-seconds must be an integer from 1 through 900' >&2
    exit 2
fi

# Hex literals bind arbitrary text without interpolating shell input into SQL syntax.
to_hex() {
    LC_ALL=C printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}
url_hex=$(to_hex "$fixture_url")
title_hex=$(to_hex "$expected_title")

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
output_directory=$(mktemp -d "${TMPDIR:-/tmp}/major-tom-background-delivery.XXXXXX")
events_file="$output_directory/cloudkit-events.log"
observations_file="$output_directory/observations.tsv"

cleanup() {
    if [[ -n ${log_pid:-} ]]; then
        kill "$log_pid" 2>/dev/null || true
        wait "$log_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "started_utc=$started_at"
echo "timeout_seconds=$timeout_seconds"
echo "observations=$observations_file"
echo "cloudkit_events=$events_file"
printf 'observed_utc\tlocal_title_matches\tcasefolded_local_title_matches\tstored_server_title_matches\tpending_for_fixture\tresult\n' > "$observations_file"

# `log stream` is observational. A separate process prevents a database-lock retry
# from ever terminating the event capture. It is stopped by the trap above.
/usr/bin/log stream --style compact --level debug --timeout "${timeout_seconds}s" \
    --predicate 'process == "MajorTom" AND ((subsystem == "dev.gemi.major-tom" AND category == "ICloudSync") OR (subsystem == "com.apple.cloudkit" AND category == "OP"))' \
    > "$events_file" 2>&1 &
log_pid=$!

deadline=$((SECONDS + timeout_seconds))
while (( SECONDS < deadline )); do
    observed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # A transient read lock is an observation gap, never evidence that the fixture is
    # absent. `-readonly` preserves WAL visibility while Major Tom remains open.
    result=$(sqlite3 -readonly "$database_path" <<SQL 2>/dev/null || true
.timeout 750
SELECT
    CASE WHEN b.title = CAST(X'$title_hex' AS TEXT) THEN 1 ELSE 0 END,
    CASE WHEN lower(b.title) = lower(CAST(X'$title_hex' AS TEXT)) THEN 1 ELSE 0 END,
    CASE WHEN json_extract(CAST(s.server_payload AS TEXT), '$.title') = CAST(X'$title_hex' AS TEXT) THEN 1 ELSE 0 END,
    CASE WHEN p.record_name IS NULL THEN 0 ELSE 1 END
FROM bookmarks b
LEFT JOIN cloud_record_state s
    ON s.record_name = b.id AND s.account_identity_hash = b.account_identity_hash
LEFT JOIN cloud_pending_changes p
    ON p.record_name = b.id AND p.account_identity_hash = b.account_identity_hash
WHERE b.url = CAST(X'$url_hex' AS TEXT)
LIMIT 1;
SQL
)
    if [[ "$result" =~ ^[01]\|[01]\|[01]\|[01]$ ]]; then
        IFS='|' read -r local_matches casefolded_local_matches server_matches pending <<< "$result"
        if [[ "$local_matches" == 1 && "$server_matches" == 1 && "$pending" == 0 ]]; then
            printf '%s\t%s\t%s\t%s\t%s\tARRIVED\n' "$observed_at" "$local_matches" "$casefolded_local_matches" "$server_matches" "$pending" | tee -a "$observations_file"
            # The receive is durable before this point. Keep the logger alive briefly
            # so its line-buffered final CloudKit callbacks are present for review.
            sleep 2
            echo "Background delivery observed. Inspect $events_file for an automatic fetch; no UI interaction occurred in this watcher."
            exit 0
        fi
        if [[ "$local_matches" == 0 && "$casefolded_local_matches" == 1 ]]; then
            printf '%s\t%s\t%s\t%s\t%s\texpected-title-casing-mismatch\n' "$observed_at" "$local_matches" "$casefolded_local_matches" "$server_matches" "$pending" | tee -a "$observations_file"
            echo 'The fixture arrived with only a casing mismatch from expected-title; stopping without treating it as a pass.' >&2
            exit 1
        fi
        printf '%s\t%s\t%s\t%s\t%s\twaiting\n' "$observed_at" "$local_matches" "$casefolded_local_matches" "$server_matches" "$pending" >> "$observations_file"
    else
        printf '%s\t-\t-\t-\t-\tread-unavailable\n' "$observed_at" >> "$observations_file"
    fi
    sleep 1
done

echo "Timed out without observing background delivery. This is a failed bounded observation, not proof that CloudKit will never deliver."
exit 1
