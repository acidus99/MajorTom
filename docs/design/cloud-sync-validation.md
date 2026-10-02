# Cloud sync signed-device validation

Status: **in progress, not release approval**. Cross-device outcomes are untested until
recorded below. See `cloud-sync-adversarial-review.md` for fixed findings and remaining
validation limitations.

## Artifact and isolation

- App: `Build/Development/Major Tom.app`.
- Transfer archive: `Build/Validation/MajorTom-cloud-sync-validation.zip`.
- Version: 2026.9.15 (205), `fb72ab2`, main **modified**. This is uncommitted work; version
  text alone does not identify its exact contents. Use the executable checksum below.
- Signing: Apple Development; signed entitlements verified for **Development**,
  `iCloud.dev.gemi.major-tom`. This is not the production CloudKit database.
- Local data: `~/Library/Application Support/Major Tom Development`.
- Production data (`~/Library/Application Support/Major Tom`) is not touched by this test.
- Do not run `make prod` / `make release` as part of this checklist. Those remain human-run.
- Both Macs must run the same copied app, with the same iCloud account. Mac #2 must be
  permitted by the development provisioning profile; report a launch/signing error rather
  than disabling system security or stripping the signature.

Final executable SHA-256:
`4ab802f17890c945e1d06c3573d6128f0f07548591a298c3b64627ebcd94b106`.
Archive SHA-256:
`11ac5e546744dee9be739d30563bb220006219e93a1fe3815ca30fa8b59079a5`.

## Mac #1 evidence already captured

The entitled app fetched the existing v2 bookmarks, certificate metadata, and Cloud Tabs.
The first launch exposed a same-account initial-sign-in restart loop; that was fixed,
regression-tested, and rerun. The initial unscoped fetch also downloaded unnecessary legacy
zone data; record fetching is now restricted to the current zone.

Created a new Favorites bookmark (did not retitle an existing bookmark):

- URL: `gemini://gemi.dev/?sync-reliability-20260915`
- Baseline: `Station - Sync Reliability`, synced before the rename.
- Renamed: **PRODUCTION - Station - Sync Reliability**.
- At 2026-09-15 15:04:52 UTC: Up to date, zero active-account pending rows, zero incoming
  journal batches, and local title equals the persisted server payload title.

This proves this Mac's observed acknowledgement. Mac #2 has not yet independently restored
it. The fixture intentionally remains in the Development dataset for that test.

The earlier review baseline was relaunched and checked again at **2026-09-15 15:14:39 UTC**:
the prefix remained intact, saved server metadata still matched it, Sync Now reached Up to
date, and both outbox and incoming journal were empty. Its signature passed strict verification.

Subsequent review added journal-worker and delayed-acknowledgement regressions, asynchronous
local persistence, and startup/shutdown barriers. The final artifact above passed ordinary
and 150-seed test runs (536 Core, one opt-in skip; 20 AppKit; no failures), packaging, and
strict signature/Development-entitlement verification. After unlocking Mac #1, the previous
process was quit and its exit verified, then the final binary was launched. At
**2026-09-15 15:45:25 UTC**, following Sync Now, the UI showed **Up to date**, the total outbox
and incoming journal were both empty, and the fixture's local title matched its saved server
payload. The exact prefixed title was also verified in the Bookmarks menu. The new process
logged one normal account activation, successful tab upload, subsequent fetches and confirmation,
with no restart loop or failed saves/deletes. **Mac #2 is now ready for the restore test below.**

## Mac #2: original-regression restore

Perform this when the reviewer says the artifact is ready:

1. Quit every Major Tom instance on Mac #2.
2. Copy the archive to Mac #2 (for example, using AirDrop), expand it into a dedicated test
   folder, and keep it separate from the normal app in Applications. Do not launch it yet.
3. Preserve the entire existing **Development** support directory before the empty-database
   test. This keeps the database, WAL/SHM companions, old JSON files, and local development
   history together. In Terminal on Mac #2:

   ```bash
   validation_store="$HOME/Library/Application Support/Major Tom Development"
   if [ -d "$validation_store" ]; then
       mv "$validation_store" "${validation_store}.before-sync-test-$(date +%Y%m%d-%H%M%S)"
   fi
   ```

   Do not move/delete the production `Major Tom` directory. Do not use the app's **Delete
   User Data** command: that would create synced deletions, not simulate an empty local cache.
   Keep the backup until the entire validation is complete. Restoring a pre-test database
   later must be done while the app is quit and with awareness that it may contain old intent.
4. Open the copied test app, with the same iCloud account as Mac #1. Allow the initial fetch;
   then use **Settings → General → iCloud → Sync Now**.
5. Open **Bookmarks → Show Bookmarks**, select Favorites, and look for the exact title
   **PRODUCTION - Station - Sync Reliability**. The full title may not fit in the Favorites
   bar, so inspect it in the manager.
6. Report the displayed title, CloudKit status, and any error or launch prompt. A screenshot
   of Favorites and the status is useful. Do not rename/delete anything yet.
7. The reviewer then checks Mac #1 again, runs Sync Now, and verifies the prefix has not
   reverted, its outbox remains empty, and both devices agree.

An empty database means domain rows are restored independently; it does not reset this
Mac's Apple-managed KVS preferences, stable device ID, or Keychain. Those are separate tests.

## Remaining matrix

### Second-Mac observation — 2026-09-15

The user reported that the launch failure occurred on the wrong Mac. On the intended
second Mac, the supplied screenshot shows **PRODUCTION - Station - Sync Reliability**
in Favorites and CloudKit Data **Up to date**. This is user-supplied UI evidence; Mac #2's
database counters and executable checksum were not independently inspected.

After that report, Mac #1 ran Sync Now again. At **2026-09-15 16:07:55 UTC**, it showed
**Up to date**, retained the exact prefixed title matching persisted server metadata, and
had zero pending rows and zero incoming journal batches. No reversion was observed.

The user clarified that the first successful launch had not used an empty cache. After
receiving the backup/reset instructions again for the correct Mac, the user reported that
Favorites started empty, populated after roughly a second, and included the prefixed test
bookmark. This is the reported fresh-restore run, distinct from the earlier screenshot.
Mac #1 then ran Sync Now again at **2026-09-15 16:12:20 UTC**: still Up to date, unchanged
prefixed title matching server metadata, zero pending rows and zero journal batches.
The user subsequently confirmed Mac #2 also showed Up to date on the fresh run. The original
fresh-restoration/non-reversion scenario therefore passed with user-observed Mac #2 evidence.
The earlier launch failure was on
the wrong Mac and does not establish a signing defect in the intended test build.

Record start/end UTC, exact build checksum, both final values, both displayed statuses, and
outbox/journal counts where available. Use additional disposable test records, not personal
bookmarks or credentials. Destructive/account/zone tests require a dedicated test account
or explicit user approval before performing the destructive step.

| Scenario | Result |
| --- | --- |
| Original prefix, empty B restore, A does not revert | Passed: user confirms fresh B restore and Up to date; A post-restore sync retains prefix, Up to date, empty outbox/journal |
| B moves the test bookmark from last to first; A receives it | Converged with delay: A's 16:16:47 UTC manual fetch still had old order rV. Its 16:17:32 UTC activation fetch received six bookmark records and changed the fixture to 8V, first of six. Menu and database agree; all 11 IDs/titles/URLs unchanged; queues empty. B screenshot shows first and Up to date. Cause of the ~45-second observation gap is not established without B's send timeline |
| B renames the first fixture to MAC2 - Station - Sync Reliability | Eventually converged; manual-refresh gate unresolved. B's supplied SQL shows both local and stored server title MAC2 - Station - Sync Reliability and no pending operation. A retained the old title through 16:31 UTC despite successful manual calls. At 16:37:39 UTC, foreground-triggered database discovery downloaded MTBookmark:1 and MTDeviceTabs:2. At 16:40:57 UTC A's UI and local/server-title columns agree on the MAC2 title, still first (8V), with zero outbox/journal rows. No rename reversion observed |
| Concurrent offline rename, both reconnect orders | Passed manually 2026-09-15: each reconnect order converged to the title from the Mac that reconnected second, consistent with pending-local intent winning over the fetched server version. |
| Delete versus edit, both reconnect orders | Not run |
| Move/reorder versus title/favicon edit | Not run |
| Folder/children separate arrival and deletion | Not run |
| Quit immediately after edit, relaunch, sync | Automated durability tests; signed two-device run pending |
| Connectivity loss during fetch/send/acceptance | Not run |
| Repeated Sync Now while editing | Not run |
| Sign out with pending edits, local use, same-account return | Not run |
| Switch accounts without cross-publication | Automated account/session tests; signed run pending |
| Explicit zone removal and recovery | Automated snapshot recovery tests; signed run pending |
| Fresh restore of certificates and Cloud Tabs | A received both; empty B pending |
| KVS and Keychain propagation, separately | Not run |

## Diagnostics and automated evidence

### Manual-refresh replacement build — 2026-09-15

Use `Build/Validation/MajorTom-cloud-sync-validation-refresh.zip` for the next two-device
matrix. The earlier archive remains untouched. ZIP SHA-256:
`01b68f33d38a55f42c4155d651ef9df2a31eec3512a0b5f998c73b7dbdaecf28`.
Executable SHA-256:
`1fbe2b40558afeeeb2f47674df75ce8bf7bcd6e48550ad0f788f8678c914cb1d`.
The extracted archive passed strict signature verification and its executable hash matches
the source Development bundle. It remains Development-provisioned, version 2026.9.15 (205),
not a notarized production release. No commit was made.

### Reconnect-recovery validation build — 2026-09-15

`Build/Validation/MajorTom-cloud-sync-validation-reconnect.zip` contains the signed
Development build with automatic offline-to-online recovery. ZIP SHA-256:
`20ab1877cdd712b27712589e1ea3282497c8606bee87c94102ae461542b573c1`.
Executable SHA-256:
`1d1d8a3e459ae2a795cf9b95a97ac218d3bffc81cf140b71f771d0b99f350980`.
The archive was extracted to a fresh temporary directory, then strict signature verification
and executable-hash comparison both passed. This validation archive is distinct from the
earlier refresh archive despite sharing the source-controlled version stamp 2026.9.15 (205).
No commit was made.

The SDK-only probe now lives in `Scripts/cloud-sync-fetch-probe.swift`, with a guarded
Development-only build/run wrapper. Both modes were rerun using the closed app's current
checkpoint: automatic mode skipped discovery; nonautomatic mode reached fetch-options
callbacks and made database requests on both calls. It does not write app data or checkpoints.

The replacement uses the controlled transport handoff described in `architecture.md`.
The final 150-seed suite passed: 540 Core tests (one opt-in live-network skip), 20 AppKit
tests, zero failures. Signed Mac #1 clean-checkpoint manual calls issued database requests
and restored automatic scheduling. The final packaged binary relaunched at 17:44 UTC,
retained the MAC2 fixture title, reached Up to date, and had empty outbox/journal.

One-click receive test procedure (completed below): install this replacement on B without deleting its database;
rename only the disposable fixture to `MAC2 - One Click Refresh`, click Sync Now once,
and confirm its local/server payload columns agree with no pending operation. Then A
performs one explicit Sync Now while its trace distinguishes user-triggered work from
foreground/push-triggered work. No repeated clicks are a workaround or a requirement.

Result at **2026-09-15 17:53:26 UTC: passed**. Before any UI interaction, A's SQLite
fixture still had `MAC2 - Station - Sync Reliability`, order 8V, and empty queues. A's
Settings window was already foreground per the user's setup. The live trace remained idle
until the one Sync Now click at 17:53:25.585 UTC. It logged `trigger=user`, constructed the
nonautomatic engine with restored state, issued a database fetch at 17:53:25.625, followed
by a zone fetch at 17:53:26.194. It delivered MTBookmark:1 and MTDeviceTabs:1 at
17:53:26.484, completed the requested cycle, and restored automatic mode at 17:53:26.570.
No activation-triggered fetch preceded that receipt. A's local and saved server title now
both equal `MAC2 - One Click Refresh`, order remains 8V, and outbox/journal counts are zero.
Settings shows Up to date. Only one click was used; the later automatic confirmation did
not deliver the rename. This validates the previously failing one-click receive schedule,
not the still-open offline-conflict/deletion/account/Keychain matrix.

### Offline pending rename versus acknowledged remote rename — passed, 2026-09-15

B's operator reports disconnecting the network and renaming the disposable fixture to
`MAC2 - Offline Pending`. B is instructed to remain offline while A makes a conflicting
edit. On A, the app's Favorites Rename popover saved `MAC1 - Online Conflict` at
approximately 18:00:59 UTC. Automatic upload prepared generation 3 and reported one
successful bookmark save at 18:01:00.625 UTC, with no failed saves. A single explicit
Sync Now at 18:01:14.175 then fetched the bookmark and restored automatic scheduling.
Read-only SQLite verification showed matching local/server title `MAC1 - Online Conflict`,
order 8V, no pending operation, and empty outbox/incoming journal. Settings subsequently
showed Up to date. The live trace is `/tmp/major-tom-offline-conflict-live.log`.

B's operator was then asked to reconnect and click Sync Now once, without another edit.
Expected result under the pending-intent conflict policy: B's unacknowledged
`MAC2 - Offline Pending` survives the fetched A version, is acknowledged by the server,
and subsequently arrives on A. This row is not passed until those results are observed.

Result: B's supplied screenshot shows `MAC2 - Offline Pending` and Up to date after the
requested reconnect/sync. Before interacting with A at 18:04:35 UTC, its database still
contained `MAC1 - Online Conflict`. One Sync Now on A at 18:05:36.771 issued database and
zone requests, received MTBookmark:1 at 18:05:37.615, and restored automatic mode at
18:05:37.677. A's local and saved server title both became `MAC2 - Offline Pending`, order
8V, with zero outbox/journal rows; Settings showed Up to date. This independently verifies
that B's surviving edit reached the server and another device, not merely B's local UI.
Receive trace: `/tmp/major-tom-offline-conflict-receive.log`. Automatic receipt had not
happened before the manual click; this does not establish a background delivery bound.
This schedule is narrower than both devices editing offline in both reconnect orders,
which remains a separate open matrix gate.

### Historical investigation before the replacement build

Rename investigation: Mac #1's persisted CloudKit framework logs report
`no zone IDs needing to be fetched, not fetching changes` during the no-op fetches.
Additional logging in `nextFetchChangesOptions` and a root fetch scope change from
`.zoneIDs([zoneID])` to `.all` did **not** establish a fix: the title remained old after
relaunch. The experiment was removed. No checkpoint reset or fixture overwrite was used.

A live debug stream established this schedule on Mac #1 (macOS 26.6.2):

1. At 16:37:38 UTC app foreground notification marks database discovery needed. The engine
   fetches database changes and then the user-data zone. The delegate's options callback
   is reached and selects the correct zone. The rename is applied at 16:37:39 UTC.
2. At 16:38:29 UTC a subsequent foreground-triggered fetch checks the database again;
   there are no additional changes.
3. At 16:39:00 UTC a user-triggered Sync Now enters the awaited `fetchChanges` call, emits
   will/did-fetch callbacks, and returns successfully without a database or record-zone
   request (`no need to fetch changes for scope`). It then sends no pending changes and
   displays Up to date.

Thus absence of an info-level message from persisted logs alone was not a valid way to
prove a callback was skipped; the live trace proves the no-op path in step 3. It does not
establish why the framework treats that manual call this way, nor prove that changing
scope fixed anything. The automated fake-server tests do not exercise this SDK behavior.
Do not equate successful awaited fetch return with evidence of a fresh server check.

At this earlier investigation stage, Mac #2 remained on the original frozen archive. Mac #1's experimental diagnostic executable differed
from it (SHA-256 `4696639e5f115340cf6f088107a1b06333b5cf88d6e4a163337b026648ad1afc`).
The earlier automated counts describe the pre-diagnostic baseline, not verification of a
completed receive fix. A verified manual-refresh fix requires another signed cross-device
test before producing a replacement archive. Removing an unsuccessful experiment is not
a fix for this open finding.

After removing the experiment, `make test` passed again (536 Core tests, one opt-in
live-network skip; 20 AppKit tests; zero failures). `Scripts/build-app.sh` passed and
strict signature verification passed using the host trust services (the sandbox-only
verification could not access trusted signing services). The restored Development binary
SHA-256 is `7af8f4fe213c41cd872f745c6fb0fc8044190e142898cce68aa340b332c767f7`.
The diagnostic process was quit and the restored app relaunched; the Favorites UI still
shows the MAC2 title. The frozen Mac #2 archive was not overwritten. No commit was made.

Run `bash Scripts/cloud-sync-diagnostics.sh /absolute/path/to/MajorTom.db` for read-only
account-hash prefix, zone/migration state, checkpoint presence, fetch/send dates, grouped
outbox counts, and incoming journal count. No output rows in the outbox section means zero
pending rows; an error reading the database is not zero work.

For a bounded background-delivery observation, run
`bash Scripts/watch-cloud-sync-background-delivery.sh /absolute/path/to/MajorTom.db fixture-url expected-title [timeout-seconds]`
on the receiving Mac while Major Tom stays open but in the background. It polls the live
database read-only and captures only CloudKit event logs; it neither launches nor focuses
Major Tom, invokes Sync Now, or prints bookmark payloads. A pass requires the expected
fixture to become both local and stored-server metadata with no pending operation, followed
by review of the capture for an automatic fetch and no user/activation trigger after the
observer starts. A timeout is a bounded failed observation, not a claim about eventual
CloudKit delivery.

### Background delivery — receiver pass, 2026-09-15

Mac #1 remained open but in the background while the read-only observer ran from
19:52:03 UTC, with no focus, activation, or Sync Now interaction. The disposable expected
title was absent from both the local bookmark and its stored server metadata through
19:52:26 UTC. At 19:52:25.938 UTC, the captured CloudKit trace began
`CKSyncEngine-FetchChanges-Automatic`; it made a database fetch, then a zone fetch. It
received MTBookmark:1 at 19:52:26.915 UTC, and the observer found matching local and
stored-server titles with no pending operation at 19:52:27 UTC. There is no `trigger=user`
or `trigger=activation` in the capture before receipt. The subsequent confirmation fetch
occurred after receipt and did not cause it. Capture directory:
`/var/folders/3w/gsqdk6j16cjfrdpjls6_q0k80000gn/T/major-tom-background-delivery.vttUmG`.

This establishes the receiver's automatic scheduler path for this delivery. The source
device's exact edit/acknowledgement time must be recorded separately before reporting an
end-to-end latency; it does not establish an Apple delivery-time guarantee.

### Offline edit, immediate quit/relaunch, then reconnect — passed, 2026-09-15

While Mac #2 was offline, its operator renamed the disposable bookmark to
`MAC2 - Offline Relaunch`, immediately quit Major Tom, and reopened it while still offline.
The title remained present and Settings reported `iCloud Sync Error: Offline, changes are
saved locally`, rather than Up to date. After Mac #2 reconnected and synced, Mac #1 remained
open in the background under a read-only observer. Its capture shows an automatic database
fetch at 19:56:17.150 UTC and automatic zone fetch at 19:56:17.733 UTC, receiving
MTBookmark:1 at 19:56:18.087 UTC; no user or activation trigger preceded that receipt.
Read-only SQLite then confirmed local/stored-server title `MAC2 - Offline Relaunch` and no
pending operation on Mac #1. The first observer invocation was configured with lower-case
`relaunch` from a human status report while the actual title used the instructed capital
`Relaunch`, so it did not self-report ARRIVED; this was a test-observer expected-string
mismatch, not a product timeout or loss. The observer now reports that configuration error
explicitly. Capture directory:
`/var/folders/3w/gsqdk6j16cjfrdpjls6_q0k80000gn/T/major-tom-background-delivery.fmQUT1`.

### Both Macs offline, conflicting rename, both reconnect orders — passed, 2026-09-15

The operator completed both scheduled delivery orders without retries beyond one Sync Now on
each Mac after it reconnected. When Mac #2 reconnected first, the final title was
`MAC1 - B First`; when Mac #1 reconnected first, the final title was `MAC2 - A First`.
This matches the documented policy: a still-pending local edit survives a fetched competing
server version, is rebased and sent, and the Mac that reconnects second supplies the final
pending intent. No title was clobbered while its own local edit remained pending.

`ICloudSyncStore.diagnosticSnapshot()` additionally supplies the runtime phase, engine
presence, last failure category, retry date, and journal count. Unified logs use subsystem
`dev.gemi.major-tom`, category `ICloudSync`, with hashed record identifiers and no payloads.

Local automated gate: `MAJOR_TOM_SYNC_SEEDS=150 make test`; the ordinary `make test` uses
24 seeds. The build gate is `Scripts/build-app.sh`, followed by signature and entitlement
inspection. Detailed final counts are recorded in the review report.

### Automatic reconnect status / atomic-batch regression — replacement build required

The first reconnect archive (executable SHA-256
`1d1d8a3e459ae2a795cf9b95a97ac218d3bffc81cf140b71f771d0b99f350980`) proved the data path:
Mac #2's offline rename `MAC2 - Automatic Reconnect` arrived at Mac #1 while Mac #1 remained
in the background. It did not prove the source status path. Mac #2 retained an Offline
status, then displayed a raw `CKRecordID` Atomic failure. The identifier maps to an
`MTDeviceTabs` record on Mac #1; it is a collateral batch item, not evidence that the
bookmark was lost. That behavior is a failed validation result, not an accepted delay.

The replacement archive is
`Build/Validation/MajorTom-cloud-sync-validation-reconnect-atomic.zip` (archive SHA-256
`30866bea4a5ad0c8e811664ea482d059176dde4efe6f7a0ed4e98ea7c6e10e4d`; executable SHA-256
`6d16e7cdd32695bde6f0b53bdeac93a9fb709ca955c824bad69c31ee46d03c27`). It is strictly
signature-verified after extraction and retains the Development CloudKit entitlements.
Local gate: `make test` passed with 543 Core tests (one opt-in skip) and 20 AppKit tests,
zero failures.

Required signed-device gate: install this exact archive on both Macs without deleting either
database. On Mac #2, make one new disposable bookmark rename while offline, reconnect without
clicking Sync Now, and leave the app open. Mac #1 stays open in the background under the
read-only delivery observer. Pass requires automatic arrival and eventual Up to date on both
Macs with empty outboxes; an unresolved reconciliation state may not show a record ID or raw
CloudKit error. Do not reset the CloudKit zone or retry a user click to make this gate pass.
