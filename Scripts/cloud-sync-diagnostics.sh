#!/bin/bash
set -euo pipefail

# Read-only, privacy-safe database half of the CloudKit support snapshot.
# The runtime phase/error remains available in ICloudSyncStore.diagnosticSnapshot()
# and in the CloudSync unified log; never dump payload or domain tables here.
if [[ $# -ne 1 || ! -f "$1" ]]; then
    echo 'Usage: bash Scripts/cloud-sync-diagnostics.sh /absolute/path/to/MajorTom.db' >&2
    exit 2
fi

sqlite3 -readonly -header -column "$1" <<'SQL'
.timeout 5000
BEGIN;
SELECT substr(account_identity_hash, 1, 12) AS account_hash,
       zone_state, migration_phase, engine_state IS NOT NULL AS engine_state_present,
       last_fetched_at, last_sent_at
FROM cloud_sync_state
WHERE account_identity_hash = (SELECT CAST(value AS TEXT) FROM persistence_metadata WHERE key = 'cloud-sync-active-account-v2');
SELECT record_type, operation, COUNT(*) AS pending_count, MIN(enqueued_at) AS oldest_pending
FROM cloud_pending_changes
WHERE account_identity_hash = (SELECT CAST(value AS TEXT) FROM persistence_metadata WHERE key = 'cloud-sync-active-account-v2')
GROUP BY record_type, operation;
SELECT COUNT(*) AS unapplied_batches FROM cloud_incoming_batches
WHERE account_identity_hash = (SELECT CAST(value AS TEXT) FROM persistence_metadata WHERE key = 'cloud-sync-active-account-v2');
ROLLBACK;
SQL
