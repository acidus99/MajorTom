# Review of the Persistence, Cache, Omnibar, and CloudKit Handoff

Adversarial review of `handoff.md`, cross-checked against the actual code, Apple's current
CloudKit/Keychain documentation, and how shipping browsers solve the same problems.

## Verdict

The plan is roughly 80% right and its instincts are good: two databases, actors off `MainActor`,
batch observations but not user intent, CKSyncEngine over hand-rolled change tokens, physical
deletion over permanent tombstones, keep GRDB. Those calls are correct and I would not relitigate
them.

Four things are wrong:

1. **Syncing server-trust decisions the way this proposes is a real security regression**, and no
   mainstream browser does it. The plan hardens the conflict case and leaves the common case wide
   open. → **Resolved: trust no longer syncs (§2).**
2. **The legacy-zone compatibility scheme is the largest source of risk and complexity in the
   plan, and it is protecting a userbase that is one month old.** It should be deleted, not
   designed. → **Resolved: one-shot v1 → v2 migration, no bidirectionality (§3, §3a).**
3. **Preferences contradict the plan's own reasoning** and are using the wrong Apple API.
4. **Full query strings are published to CloudKit and indexed in FTS**, and the handoff decides
   this by omission rather than on purpose.

Two decisions have been taken since this review was written; both are recorded inline where they
apply, and the affected answers in §10 are updated.

Plus: delete-wins combined with the existing `ON DELETE CASCADE` is a data-loss bug, integer
ordering will not converge, and there are six concrete performance defects in
`PageCacheRepository` that the handoff's "current implementation" section does not mention —
which matters, because they are the actual cause of the stalls the redesign is chasing.

---

## 1. Query strings go to CloudKit and into FTS — decide this on purpose

The handoff settles this by omission:

> "A submitted Gemini status-10 response is an ordinary URL with a query and participates in
> history, tab state, and caching normally."

That sentence is doing more work than it looks like. `publishCloudTabs()`
(`MajorTomApp.swift:964-977`) filters on **scheme only**:

```swift
guard let url = browser.committedURL,
      ["gemini", "http", "https"].contains(url.scheme?.lowercased() ?? "")
```

So the **complete URL, query included**, becomes an `MTDeviceTabs` record ~750 ms after a tab
settles and is rendered in iCloud Tabs on the user's other Macs. Every Kennedy or TLGS search, every
status-10 answer, and any capsule that carries state in a query string. The same URL also lands in
`history_entries` (1 year), `page_cache` plus `page_cache_fts` (120 days), and `browser_tab_history`,
which survives quit and is restored into the tab's Back list.

`CloudSyncModels.swift:426-428` describes this record as "privacy-conscious" and enumerates what it
excludes. Query strings are not on the list.

None of that is necessarily wrong — Safari syncs open tabs with full URLs too. But it is the one
place where "what I typed" leaves the machine, and the handoff's data-ownership section presents
device tabs as "a privacy-conscious list of open tab titles and URLs" without saying that the query
component is included. Either state it deliberately in the spec, or strip the query from the
published tab record. It should not be an accident of a scheme check.

Two smaller items in the same area:

- **Clear Browsing Data never clears drafts.** `BrowserSettingsView.swift:344-349` clears history and
  session; `GeminiInputDraftRepository.removeAll()` exists and has no caller. Whatever the retention
  story is, "Clear Browsing Data" should honor it.
- **FTS indexes URLs including their query**, and the omnibar is about to search that index. Decide
  now whether previously typed queries should autocomplete back to the user. Safari does this
  deliberately; make it a decision rather than a side effect of `page_cache_fts` existing.

### On status 11 specifically — low priority, but the current state is incoherent

Status 11 is rare enough in practice to not be worth prioritizing, and the protocol spec asks only
that the input "not be echoed to the screen." Major Tom already satisfies that with `SecureField`.
So this is not urgent and it is not a spec-compliance issue.

It is, though, half-implemented. `isSensitive` exists on `BrowserModel.InputPrompt`
(`StreamingWebViewPrototype.swift:464`), gates `SecureField` and draft suppression, and is then
discarded at submit:

```swift
// StreamingWebViewPrototype.swift:1550-1561
inputPrompt = nil                     // isSensitive dies here
navigate(to: target, disposition: .new)
```

`MajorTomCore` has no notion of sensitivity at all — `GeminiResponseHeader.isInput`
(`GeminiResponseHeader.swift:32`) is true for both 10 and 11. So the app spends code caring about
the distinction for the duration of one sheet and then forgets it, which is the worst of both
positions. Two coherent options:

- **Don't care.** Drop `SecureField` and the draft suppression too, and document that Major Tom
  handles 1x uniformly. Cheapest, and defensible given real-world usage.
- **Care all the way through.** Carry the flag from `submitInput` through `navigate` → `commit` →
  `cache` → session → `publishCloudTabs`. This is **the same plumbing Private Browsing needs**
  (§9.3), so if private windows are ever built, the marginal cost of status 11 is close to zero —
  do it then, not now.

Two related fragilities worth noting whichever way you go:

- `preserveInputDraft(_:for:)` (`:1546-1548`) has **no** sensitivity check. It takes a
  `GeminiRequestTarget`, not the prompt, so the information is structurally unavailable to it. It is
  safe only because the sheet's `.onDisappear` never reports for a sensitive prompt — an invariant
  held by a comment, not by a type.
- `gemini_input_drafts` is keyed by **prompt URL**, so a status-10 prompt reached *from* a
  status-11 answer writes the prior query into `prompt_url` (`:1527`).

There is no test coverage here and there cannot be as structured: `isSensitive` lives in the
`MajorTom` app target, which has no test target. That is the more general problem — any
persistence *policy* that lives in the app layer is untestable. Push policy into Core.

---

## 2. Do not sync server trust the way this proposes

This is the one genuine security regression in the plan, and it is already shipped behavior
(`major-tom-specification.md:83`, `architecture.md:133`).

**No mainstream browser syncs TLS trust exceptions.** Safari syncs bookmarks, history, tabs and
passwords over iCloud, and does not sync per-site certificate exceptions. Firefox Sync has never
synced `cert_override.txt`. Chrome does not sync SSL decisions. The reason is that a certificate
exception is a *device-local, moment-local* risk acceptance — contextual to the network you were
on when you made it. Propagating it turns one bad decision (a hostile coffee-shop network, a
mistaken click) into fleet-wide silent trust.

In Gemini this is worse rather than better, because **TOFU is the entire security model**. If Mac B
inherits Mac A's decision, Mac B never performs first use and never observes the real certificate.
You have replaced "trust on first use" with "trust on first use by whichever of my Macs was on the
worst network." An attacker who wins once, anywhere, wins everywhere.

The handoff's mitigation covers only the **conflict** case (multiple active fingerprints for one
endpoint → surface, never auto-select). The **unconflicted** case — Mac A approves, Mac B silently
trusts a capsule it has never contacted — is the common case and gets no gate at all.

The projection is otherwise well built: only `source == .user` decisions leave the Mac
(`CloudSyncModels.swift:381`), and `certificatePEM`, `timesSeen`, `lastSeenAt`, `certificateSHA256`
stay local. The problem is the semantics, not the plumbing.

### Options, in decreasing safety

**(a) Don't sync trust at all — recommended.** TOFU per device. Cost: one extra approval per
capsule per Mac, for capsules you visit on more than one Mac. That is a small, comprehensible,
honest cost. It also deletes an entire record type, an entire conflict class, and the hardest
question in the plan (`Q5`).

**(b) Sync as advice, not decision.** A synced record pre-fills the TOFU dialog — "Your other Mac
trusted this key on 3 August" — but the local Mac still requires an explicit approval and records
its own first-use observation. This preserves the convenience benefit with none of the silent
propagation.

**(c) If you insist on auto-apply:** require the local Mac to have *observed* the same fingerprint
on a live connection before a synced decision becomes effective. A synced record for a
never-contacted host stays inert. A synced record that differs from a locally observed key is
always a conflict, and the local observation always wins.

Whatever you pick, record provenance (which device, when) and show it. And update the spec — this
is a product change, not a refactor.

**Decision taken** (2026-09-02): **option (a) — server trust does not sync.** TOFU is per device.
`MTServerTrust` leaves the CloudKit schema, `server_trust_sync` is dropped locally, and Q5
disappears. `trusted_server_identities` remains the single local authority for both the decision and
the observation, which also removes the decision/observation split the handoff was struggling to
represent. Update `major-tom-specification.md:83` and `architecture.md:133`, both of which currently
promise trust synchronization.

### Related: the trust record name is enumerable

`MTServerTrust`'s CloudKit record name is `server-trust-<sha256(stableID)>` where the stableID is
(`CloudSyncModels.swift:354-356`):

```swift
"\(endpoint.host.lowercased()):\(endpoint.port)|\(publicKeySHA256.lowercased())"
```

`recordName` is CloudKit **system metadata and is not covered by field-level encryption**. That
digest is unsalted over a preimage that is entirely public — Geminispace has a few thousand hosts,
all publicly crawled by Kennedy and TLGS, and every capsule's public-key fingerprint is observable
by connecting to it. Anyone holding the record names can precompute the table and recover exactly
which capsules the user manually trusted.

The other four hashed types digest random UUIDs and are fine — `sha256(UUID)` has 122 bits of
preimage entropy. They need no migration and their record names should be left alone.

The code was already signalling this. Trust is uploaded by a **special-cased loop**
(`ICloudSyncStore.swift:445-452`) rather than the generic `recordsNeedingUpload` path, because
`SyncedServerTrustDecision.id` is a composed `String` while every other synchronized type is
`Identifiable` by `UUID` (`ClientCertificate.swift:493` and equivalents).

#### Cleanup, now that trust does not sync

**A tombstone does not fix this.** In the current design a tombstone is a record with the *same
recordName* plus `deletedAt`. The record name is the leak, so tombstoning every trust record would
retire the feature and preserve the leak intact. These must be **physically deleted**.

1. **Stop writing them.** Remove `MTServerTrust` from `synchronizedRecordTypes`
   (`ICloudSyncStore.swift:60`) and delete the special-cased upload loop. The leak stops growing.
2. **Delete existing records by query, not by computed name.** Recomputing digests from local trust
   rows misses records for endpoints no longer trusted locally — removal wrote a tombstone, so the
   record persists under a name derived from a host this Mac has since forgotten. Use the existing
   `CKQuery(recordType:predicate: true)` machinery (`:510`) and delete every returned ID, in both
   zones, during the one-shot v1 pass.
3. **No completion marker is needed.** "The query returns zero `MTServerTrust` records" *is* the
   completion signal — self-verifying and idempotent, unlike the migration marker in §3a, because
   re-running it is harmless.
4. **Accept one residual.** An un-upgraded Mac reading v1 cannot distinguish the deletion from
   "never uploaded" and may re-upload its own trust set. It can only re-upload endpoints it trusts,
   the population is small and shrinking, and no current build reads v1 after cutover. Deleting is
   strictly better than not deleting; not deleting is a guaranteed leak.
5. **Drop `server_trust_sync`.** It is the projection plus permanent tombstones for a feature that
   no longer exists, and it is where the derived stable IDs live on disk.

#### Make the bug class unrepresentable

The rule was never "use UUIDs as record names" — it is **the preimage must be high-entropy**. The
current signature makes violating it the path of least resistance:

```swift
private func recordID(prefix: String, stableID: String, ...) -> CKRecord.ID   // takes any String
```

Change `stableID` to `UUID`. Feeding it a hostname then does not compile. That is a stronger
guarantee than a rule in `architecture.md`, and it is exactly why trust needed a special path.

#### What no fix removes

Zone names, record type names, per-type record counts, and CloudKit's own modification timestamps
are plaintext by construction. That still reveals how many bookmarks and client certificates the
user holds, how many Macs they have, and when each last changed. `trusted_server_identities` also
remains keyed by plaintext host/port in local SQLite, which is fine — local disk is not this threat
model. Document both as accepted limits in `architecture.md` so neither is rediscovered later as a
bug.

---

## 3. Delete the legacy-zone compatibility scheme

The handoff spends an entire section, challenge #7, two adversarial-table rows, an invalidation
condition, and a dual-write on every delete on backwards compatibility. It concludes:

> "There is no protocol trick that provides all three of these properties simultaneously... One
> constraint must be bounded."

Correct. It then bounds the wrong one, at one year.

**Who is being protected.** First commit 2026-08-01. First release 2026-08-08. Four GitHub
releases, the most recent 2026-09-01. Not in the App Store. Distribution is a hand-downloaded
`.app` from a GitHub Releases page, to users of a Gemini browser. The installed base of clients
too old to understand v2 is, realistically, a rounding error — and every one of them can update by
downloading a file.

**Why bidirectional is actively dangerous.** v2 uses physical deletion; v1 has no concept of it. A
v1 client holding an active record that v2 physically deleted will re-present it, and the
compatibility merge — which resolves by payload `modifiedAt` — has no way to know that absence in
v2 meant deletion. That is a resurrection machine, and it is exactly the failure mode the whole
redesign exists to eliminate. The handoff notices this ("Old client writes to the legacy zone
after v2 deletion → V2 object may be resurrected") and answers it with "compatibility rule must
distinguish stale legacy active data from allowed legacy edit," which is not a rule.

**What shipping sync systems do.** A sync protocol version is a hard gate, not a negotiation.
Firefox Sync has `storageVersion`: bump it and old clients hard-stop with "you need to update."
Chrome Sync uses a model/birthday check with the same effect. Nobody runs two protocols
bidirectionally against one dataset, because the merge rules are not expressible.

You already have the mechanism. `MTDataModelManifest` declares minimum reader and writer majors
and `architecture.md:105` says an incompatible manifest makes the app "stop syncing and report
that an upgrade is required." Use it.

### Recommendation

Ship one release that:
1. Reads the v1 zone once, migrates everything forward into v2.
2. Records a cutover marker.
3. Never writes v1 again.
4. Raises the v1 manifest's minimum reader so old clients stop cleanly with "Update Major Tom on
   your other Mac to keep syncing" instead of silently diverging.

Then delete the legacy code path entirely. Do not delete the v1 zone itself — an old installed app
may still be reading it — just stop participating.

The savings are large: no dual-write on delete, no cross-zone merge, no "which zone is
authoritative" question, no legacy tombstone lifecycle, and challenge #7 and invalidation
condition #6 both disappear.

**Decision taken** (2026-09-02): one-shot v1 → v2 migration, no bidirectional compatibility, no
mirror. See §3a for the mechanics and for what v2 needs in order to be the last zone.

---

## 3a. Designing v2 so there is never a v3

Decision taken: **no bidirectional compatibility. A one-shot v1 → v2 migration, then v1 is dead.**
This section is about making that the last zone migration.

The goal is achievable, but only if the versioning surface moves *inside* the zone. Everything
CloudKit makes permanent must be frozen correctly now; everything that will need to change must be
somewhere you fully control.

### What CloudKit makes permanent

These are one-way doors. Getting them wrong is what forces a v3.

| Decision | Reversible? | Get it right now |
|---|---|---|
| Zone name | No — a new zone *is* a migration | `MajorTomUserDataV2` is forever. Accept it. |
| Record names | No — requires recreating every record | **Random UUIDs.** Not hashes, not derived from content (§2). |
| Field encrypted vs plaintext | **No** — "you can't convert existing unencrypted fields" | Every field born encrypted. You are already correct here; keep it absolute. |
| Field type | No | One field, `payload`, type `Data`. Frozen. |
| Record type semantics | Effectively no | New meaning ⇒ new type, never a repurposed one. |

Note that a production CloudKit schema is append-only in practice: you can stop *using* a field,
but you cannot remove it. Every field you ever add is permanent. Which is the argument for adding
exactly one.

### The core move: freeze the CloudKit schema at one field per type

You already have this and may not have noticed it is the thing that makes "never touch it again"
reachable. Every record carries exactly one field, `encryptedValues["payload"]`
(`ICloudSyncStore.swift:548`). If that never changes, the CloudKit *schema* never changes — no
dashboard edits, no index changes, no production deploys, no schema drift between dev and prod,
ever again.

All evolution then happens inside a blob you control completely, with your own encoder, your own
version field, and your own tests. That is the right place for it. Keep the one-field rule as an
inviolable invariant and write it down.

The cost is real and worth stating: no server-side query or index on any domain value, and
whole-blob conflict resolution rather than field-level merge. Both are fine here. You already fetch
whole record sets, you do not sort server-side (`sortDescriptors` appears nowhere in the codebase),
and with CKSyncEngine you will be doing per-record domain merges anyway.

### The one feature that most determines longevity: preserve unknown fields

This is the classic sync data-loss bug and it is currently unguarded.

Today the payload is `try encoder.encode(value)` over a plain `Codable` struct. So:

> Mac A runs a future build that adds `bookmark.notes`. Mac B runs today's build, decodes the
> bookmark (dropping `notes`), the user renames it, Mac B re-encodes and uploads. **`notes` is
> destroyed** — not just on Mac B, on the server, for every device.

Any forward-compatibility promise is void without a fix. Firefox Sync preserves unknown fields for
exactly this reason.

The fix is envelope-level, not struct-level. Decode the payload to a JSON object first, lift out the
keys this build knows, keep the remainder verbatim, and merge it back on write:

```
Envelope {
  t: Int              // payload schema version for this record type
  ...known fields...
  ...unrecognized keys preserved verbatim and re-emitted on write...
}
```

`.sortedKeys` is already set (`ICloudSyncStore.swift:67`), so round-tripping stays byte-stable and
`recordNeedsUpload`'s comparison keeps working. Test this explicitly: encode a payload with an
injected unknown key, decode it with the current model, mutate a known field, re-encode, and assert
the unknown key survived. That one test is what makes v2 permanent.

### Version per record type, not one global manifest major

`MTDataModelManifest` with a global format major plus min reader/writer is a blunt instrument: any
incompatible change anywhere stops *all* syncing. That is a bad enough failure mode that you will
eventually be tempted into a new zone to avoid triggering it.

Put a schema version `t` in each payload envelope instead, and let the manifest carry a *per record
type* minimum reader. Then an unreadable record type is quarantined on its own while every other
type keeps syncing. A future breaking change to bookmarks does not stop your certificates from
syncing, and nobody is ever forced into a zone migration to dodge a global stop.

Keep the manifest — it is genuinely useful — but demote it from "gate on everything" to "declare
per-type minimums."

### The escape hatch that replaces a v3 zone

When a record type genuinely needs an incompatible model, **add a new record type in the same
zone.** `MTBookmark2` lives beside `MTBookmark`. New clients read both and prefer the new one; they
dual-write during a compatibility window; old clients keep reading `MTBookmark` and are unaffected.

That is a per-type migration inside a permanent zone, with a bounded dual-write and no
cross-protocol merge — all the benefit of a zone migration at a fraction of the risk. It is the
mechanism that lets you say "the zone is v2 forever" and mean it.

### Shrink the permanent surface before freezing it

Every record type is a permanent liability, so decide the roster *before* cutover, not after:

| Type | Keep? |
|---|---|
| `MTBookmark`, `MTBookmarkFolder` | Yes. Core value. |
| `MTClientCertificateDescriptor`, `MTClientCertificateAssociation` | Yes. |
| `MTDeviceTabs` | Yes — but cap the tab count. It is one record for all tabs on a device, and CloudKit caps record size. A pathological session should degrade, not fail to sync. |
| `MTPreferences` | **No.** Move to `NSUbiquitousKeyValueStore` (§4). |
| `MTServerTrust` | **No — removed.** It carried the enumerable record name, the hardest conflict semantics, and the security regression all at once (§2). |
| `MTDataModelManifest` | Yes, in the reduced role above. |

Five domain types plus a manifest is a small, defensible surface to keep for a decade.

### Freeze the payload representation of anything expensive to change

Two things belong in the day-one payload because changing them later is a breaking payload change:

- **Fractional ordering keys** (§6), not integer positions. Switching the ordering representation
  after cutover means re-encoding every bookmark and folder.
- **Certificate fingerprints as a join key** (§9.4), so a descriptor and a late-arriving Keychain
  identity can be matched without relying solely on a Major Tom UUID.

### Additive-only rules, written into `architecture.md`

1. Never remove a payload field. Deprecate it and keep emitting it until no supported reader wants it.
2. Never repurpose a field name, and never change a field's type.
3. New fields are optional with a defined default for absence.
4. Unknown fields are always preserved and re-emitted.
5. Record names are opaque random UUIDs. Nothing is ever derived from user content.
6. Exactly one CloudKit field, `payload`, encrypted, on every record type. Forever.
7. A breaking change to one type gets a new record type in the same zone. Never a new zone.

### The migration itself: don't build a time window, build a one-shot

"Very time limited" is best implemented as *exists in exactly one shipped release*, with no
date-based logic anywhere. Date windows require the code to survive until the date, and by then
nobody remembers why it is there.

**The correctness-critical detail: the migration marker must live in CloudKit, not in local
`persistence_metadata`.**

The v1 → v2 migration is a **once-per-iCloud-account** event, not once-per-device. If each Mac runs
its own v1 read at its own time, then a Mac that upgrades three months from now will read whatever
stale state v1 holds and merge it forward — resurrecting exactly the data the cutover was supposed
to retire. A local marker cannot prevent this because it is per-device by construction.

So:

1. On launch, read the v2 manifest. If it declares the migration complete, **never look at v1
   again.** Not once, not conditionally.
2. Only if v2 is genuinely uninitialized — no manifest, no model records — perform the one-shot v1
   read, merge forward, and write the manifest with the migration recorded.
3. After that, v1 is invisible to every current build.

Two supporting decisions:

- **Keep the v1 code path outside CKSyncEngine.** Configure the engine for `MajorTomUserDataV2`
  only, and run the v1 read as a self-contained one-shot query. It then has no entanglement with the
  engine, the outbox, or the state serialization, and you can delete the whole file in the next
  release without touching sync.
- **Do not delete the `MajorTomUserData` zone.** An un-upgraded Mac may still be using it, it costs
  nothing in the user's own iCloud storage, and deleting user data to tidy up is not worth the code
  or the risk. Ignore it forever. That is zero lines, which is the correct amount.

An un-upgraded Mac will silently stop syncing with the upgraded ones. That is the accepted cost, and
given a one-month-old GitHub-distributed app it is the right trade — but it should be a release-note
sentence, not a surprise.

---

## 4. Preferences: the plan contradicts itself, and CloudKit is the wrong API

The handoff rejects the giant-JSON-record pattern with good reasons:

> "Rejected because every small change rewrites the full payload, creates coarse conflicts,
> prevents record-level deletion, and recreates the slow import/sync behavior that initiated this
> project."

Then keeps exactly that for preferences: "Continue using one replaceable CloudKit record." Same
failure mode — Mac A changes the content theme, Mac B changes the homepage, both offline, one
loses silently and the user never finds out.

**Use `NSUbiquitousKeyValueStore` instead.** It is built for precisely this: ~1 MB, 1024 keys,
**per-key** conflict resolution, no custom zone, no record type, no schema deployment, no queryable
index to configure, no participation in CKSyncEngine or the outbox. The synced preference set here
(homepage, search provider, theme, width, Gemtext options, image loading, favicon visibility) is
tiny and fits comfortably.

This removes `MTPreferences` from the CloudKit schema, removes preferences from the outbox
invariant, and removes an entire class of "one setting change rewrote every setting" bug.

Caveats: it is not transactional with SQLite (preferences don't need to be), and you must keep
local-only preferences — appearance, proxy, Favorites-bar visibility — out of it. Observe
`didChangeExternallyNotification` and reconcile into your in-memory model.

---

## 5. Delete-wins is right for records and wrong for cascades

`bookmarks.folder_id` is declared `ON DELETE CASCADE` (`MajorTomDatabase.swift:122`). Combine that
with delete-wins and you get:

> Mac A deletes a folder. Mac B, offline, adds 20 bookmarks to it. Mac B comes online. The remote
> folder deletion wins, cascades, and destroys 20 bookmarks that nobody ever deleted.

The handoff lists the race ("Folder deletion races with bookmark move into that folder") and
resolves it with "define cloud merge order and delete-wins relationship," which chooses the losing
option.

**Neither Chrome nor Firefox does this.** Both reparent orphans — Firefox Sync to "Unfiled",
Chrome to "Other Bookmarks" — precisely because a cascade across a sync boundary destroys data the
user never saw.

**Fix:** delete-wins applies to the *record*, not to its children. When applying a **remote** folder
deletion, reparent surviving local children to a recovery folder (or the default folder) rather
than cascading. Keep the SQL cascade for **local, user-initiated** deletion, where the user saw
what they were deleting and confirmed it.

Delete-wins itself is correct, for the reason the handoff gives: it avoids adjudicating deletion
versus edit with untrusted device wall clocks. Keep it.

---

## 6. Integer `position` will churn and will not converge

`bookmarks.position` and `bookmark_folders.position` are plain `INTEGER`
(`MajorTomDatabase.swift:117-125`), and `BookmarkRepository` assigns positions from array offsets
(`BookmarkRepository.swift:117`, `:127`). Moving one bookmark rewrites every sibling → N changed
records → N CloudKit saves → N conflict opportunities.

The handoff identifies the problem — "Reordering a folder can touch many records at once", "Two
Macs reorder the same folder → duplicate positions or unstable order oscillation" — and then
resolves it with "deterministic normalization/tie-break," which is a restatement.

**Use fractional index keys.** Order values become strings you can always insert *between*
(base-62 style, with a device-id suffix as a deterministic tie-break). One move changes one record.
Merge converges without a global renumber. This is what Chrome Sync's `unique_position` and
Figma-style ordering do, and it is the standard answer.

Do this **before** cutting over to per-record CloudKit sync, because it changes the record payload
and you do not want to migrate the payload twice.

---

## 7. The outbox is right — and Apple has a first-class hook the handoff doesn't know about

This answers Q2 and Q3 together.

### Q2: make the outbox the *only* list

`CKSyncEngine.State` exposes **`hasPendingUntrackedChanges`**. Set it to `true` and the engine will
call `nextRecordZoneChangeBatch` even though `pendingRecordZoneChanges` is empty, letting you build
batches from your own database. Apple supports "your database is the source of truth" as a
first-class pattern.

So the correct shape is stronger than what the handoff proposes:

- **Never call `add(pendingRecordZoneChanges:)`.** Two lists that can diverge is worse than one.
- `cloud_pending_changes` is the sole record of intent, inserted in the **same SQLite transaction**
  as the domain mutation.
- Set `state.hasPendingUntrackedChanges = true` after that transaction commits (and at launch if
  the outbox is non-empty).
- Build batches by querying the outbox in `nextRecordZoneChangeBatch`.
- Delete outbox rows on `sentRecordZoneChanges` success, in one transaction with whatever result
  metadata you keep.

That collapses the crash window the handoff worries about into nothing: there is exactly one
durable list, written atomically with the domain row. Engine state then carries only change tokens,
and losing it is survivable by definition.

Batch limit is **250 records** (saves + deletes combined) per request; use
`CKSyncEngine.RecordZoneChangeBatch(pendingChanges:recordProvider:)` and it will stop at the limit
for you.

### Q3: don't store CKRecord system fields at all — drop `cloud_record_metadata`

You need the change tag only if you use `.ifServerRecordUnchanged`. CKSyncEngine's default hands
you the server record inside the `serverRecordChanged` failure, which is everything you need to
merge and retry.

More to the point: **every record is a single encrypted `payload` blob**
(`ICloudSyncStore.swift:548`). There is no field-level merge to perform. You are doing whole-blob
resolution either way, so the system fields buy you nothing you can currently use.

A per-record metadata table is a third thing to keep transactionally consistent for zero present
benefit. Cut it from v1 of this design. Add it later if you measure real conflict churn.

Net effect: the proposed three-table sync layer becomes two — `cloud_sync_state` and
`cloud_pending_changes`.

### Q1: yes, CKSyncEngine, and the manifest gate is not a blocker

Invalidation condition #1 worries CKSyncEngine "cannot preserve the required v2 manifest/zone
version gate." It doesn't invalidate anything — it moves the gate.

The engine hands you every changed record via `fetchedRecordZoneChanges`, including the manifest.
You cannot prevent the *fetch*. You don't need to. Move the gate from fetch-time to **apply**-time:
buffer and quarantine records you can't interpret, don't apply them to local state, and return
`nil` from `nextRecordZoneChangeBatch` so you stop *writing* when the manifest demands a newer
reader. The safety property you actually want — "never decode or overwrite unknown records" — is
fully preserved.

CKSyncEngine is macOS 14+; you target 26. Use it.

---

## 8. Concrete defects the handoff's "current implementation" section missed

This answers Q12. These matter because they are the actual cause of the stalls the redesign is
chasing — moving this code to an actor without fixing it just moves the stall off the main thread.

**8.1 Every cache *read* takes the write lock.** `PageCacheRepository.page(for:)` uses
`database.write` (`PageCacheRepository.swift:93`) so it can touch LRU in the same transaction;
`pages(for:)` does the same (`:119`). Combined with `MainActor` callers and a 5-second busy
timeout, this is your worst stall path. Batching LRU touches (the plan's item 6) fixes it properly
— reads become genuine `read`s and stop serializing against the single writer.

**8.2 `prune()` runs a full-table `SUM(body_size)` on every single store.** `store()` calls
`prune()` unconditionally (`:86`), which does
`SELECT COALESCE(SUM(body_size), 0) FROM page_cache` (`:187`). Every navigation scans the whole
cache table. Keep a running total in a bookkeeping row instead.

**8.3 FTS deletes are full table scans.** `url` is declared `UNINDEXED` in `page_cache_fts`
(`MajorTomDatabase.swift:201`), so `DELETE FROM page_cache_fts WHERE url = ?` (`:202`, `:213`)
scans the entire FTS table. `prune()`'s eviction loop calls that **once per evicted row** (`:193-198`).
Under cache pressure that is N full FTS scans inside one transaction, currently on `MainActor`.

Fix: give the FTS table an explicit `rowid` equal to an integer id on `page_cache` and delete by
rowid, **or** use an external-content FTS5 table (`content='page_cache'`). The external-content
form also eliminates the duplicated content the handoff correctly worries about in its cache-size
discussion but never proposes a fix for. This is the single highest-leverage change in the cache.

**8.4 `prune()` loads every candidate row with no `LIMIT`** (`:189-192`) in order to evict a few.

**8.5 `clear()` is `DELETE FROM page_cache`** (`:174`) — one enormous transaction that reclaims no
disk. The plan's "close and recreate the cache database" fixes this; it is the right call.

**8.6 `auto_vacuum` is a one-shot decision made at file creation.** You cannot enable
`PRAGMA auto_vacuum = INCREMENTAL` after the first table exists without a full `VACUUM`.
`MajorTomDatabase` never sets it (`MajorTomDatabase.swift:21-28`), so the durable database is
`NONE` permanently. **The new cache database gets exactly one chance** — set it in
`Configuration.prepareDatabase` before the first migration runs. Get this wrong and Q9 has no good
answer.

**8.7 Tests use `DatabaseQueue`; production uses `DatabasePool`** (`MajorTomDatabase.swift:41` vs
`:28`). The test database serializes everything. Production has one writer and concurrent readers.
Every race challenge #4 worries about is structurally invisible to the current test suite. Add a
file-backed `DatabasePool` fixture before introducing actors.

**8.8 `synchronous` is never configured.** For a document this detailed, that is a conspicuous gap
— it is a large write-cost lever. Decide it deliberately per database: durable = `FULL` (or
`NORMAL` with WAL, the usual choice), disposable cache = `NORMAL`. Also set `journal_size_limit` on
the cache.

**8.9 Six tables are opaque JSON blobs keyed by id** — `bookmark_sync_folders`,
`bookmark_sync_bookmarks`, `server_trust_sync`, `client_certificate_sync_descriptors`,
`client_certificate_sync_associations`, and `trusted_server_identities.payload`
(`MajorTomDatabase.swift:138-147`, `:208-234`). That is a key-value store wearing SQL: no index on
fingerprint, no query by trust source, no partial update, and payload schema migration happens in
Swift rather than in a GRDB migration. The redesign is the moment to normalize the ones you
actually query — especially trust, where detecting a conflict means "find all active fingerprints
for this endpoint," which today requires decoding every row.

**8.10 27 `try?` calls in `BrowserPersistence.swift`.** Challenge #4 names the problem; this is its
size.

**8.11 One good thing worth not breaking:** the CloudKit encoder sets
`outputFormatting = [.sortedKeys]` (`ICloudSyncStore.swift:67`), so `recordNeedsUpload`'s
byte-comparison (`:701`) is deterministic. Keep that if the encoder is ever touched.

---

## 9. Divergences from browser best practice worth a deliberate decision

### 9.1 History is local-only — that is a real divergence from the stated model

Safari syncs history via iCloud. Firefox Sync syncs history. Chrome Sync syncs history. All of
them. The handoff asserts "Global browsing history... remain local" with no rationale, in a project
whose stated principle is "Safari is the behavioral model where the Gemini protocol does not
require something different."

Privacy is a perfectly good justification and Gemini's culture supports it — but write it down.

Note the tension: you **do** sync open tab URLs across Macs (`MTDeviceTabs`). So "URLs I visit
never leave this Mac" is already false for current tabs. Pick a coherent story and state it in the
spec.

### 9.2 Syncing bookmark favicons is avoidable churn

A favicon is *derived observation*, not user intent — any Mac can re-derive it by visiting the
capsule. Syncing it means every favicon refresh rewrites the bookmark's whole payload blob and
produces a CloudKit save, and it creates the "favicon refresh races with bookmark deletion" hazard
the handoff lists.

The stated benefit is that "a newly installed Mac can render Favorites before building a local
favicon cache" (`major-tom-specification.md:32-35`). That is a first-launch nicety paid for with
permanent write amplification and a whole race class.

Consider: include the favicon in the bookmark's **create** payload only; treat later observations
as local. First launch still renders correctly; steady-state churn goes to zero.

### 9.3 There is no Private Browsing

Confirmed absent — no flag, no column, no concept anywhere in `Sources` or the schema. If Safari is
the model, private windows are table stakes.

The relevant point for *this* plan is that a private window is a per-tab "ephemeral" flag that
suppresses history, cache, FTS, session, and `MTDeviceTabs` writes — i.e. a policy flag threaded
through every write path. Steps 2–6 rewrite every one of those paths. If private browsing is ever
going to exist, designing the flag now is nearly free and retrofitting it later is a second pass
over the same code. It also subsumes §1's status-11 question at no extra cost.

That is an argument for deciding it now, not necessarily for building it now.

### 9.4 Client-certificate / Keychain hazards not mentioned anywhere

The Keychain layer is better than the handoff implies — `kSecUseDataProtectionKeychain: true` on
the preferred paths, `kSecAttrSynchronizable` set only at creation, no `SecItemUpdate` anywhere, so
the classic "tried to flip synchronizable" bug is structurally absent. But:

- **`kSecAttrSynchronizable` cannot be changed on an existing item.** There is no
  `SecItemUpdate` path for it; you must delete and re-add. That means "let the user turn on iCloud
  sync for an existing identity" requires exporting the private key — which fails if it was created
  non-extractable. Today the UI correctly presents storage as read-only status text
  (`ClientCertificateViews.swift:195-197`). If a toggle is ever added, this is the constraint.
- **Secure Enclave keys can never sync.** If any identity path ever uses
  `kSecAttrTokenIDSecureEnclave`, it is permanently local. Worth an explicit note.
- **Legacy fallback paths set `kSecUseDataProtectionKeychain: false`** or omit it entirely
  (`ClientCertificateKeychain.swift:137`, `:192`, `:582-589`, and others). They are guarded as
  unsigned-test-only, but reads and deletes probe all three stores, so an item created once on a
  legacy path stays reachable forever. That is a lingering split-brain source; consider a one-time
  migration that promotes legacy items into the data-protection keychain and then stops probing.
- **`errSecDuplicateItem` is treated as success** in `storeImportedPrivateKey`
  (`ClientCertificateKeychain.swift:657`, `:662`, `:669`), so an import silently binds to a
  pre-existing item with the same application tag rather than failing. That is a wrong-key hazard.
- **The join key is the Major Tom UUID only.** Descriptor and private key arrive through
  *independent channels on independent schedules* (CloudKit vs iCloud Keychain) — challenge #8. The
  descriptor already carries `certificateSHA256` / `publicKeySHA256`
  (`ClientCertificate.swift:443-444`) but they are used only for import-time duplicate detection,
  never for a keychain lookup. Adding fingerprint-based matching as a fallback would make the
  "identity arrived before/after its descriptor" case resolvable rather than merely representable.
- **A CloudKit descriptor tombstone destroys Keychain material on every device.**
  `ClientCertificateStore.swift:391-399` computes `removedIDs` from merged remote state and calls
  `try? keychain.delete(id:)`, and the delete path uses `kSecAttrSynchronizableAny`
  (`ClientCertificateKeychain.swift:466`, `:499`, `:523`) — so it removes the synchronizable item
  and propagates that deletion everywhere. Under **delete-wins** with physical CloudKit deletion,
  verify very carefully that a transient fetch anomaly or a token-expiry resync can never be read
  as "this certificate was deleted." A private key is the one thing here that is genuinely
  unrecoverable. Consider making certificate deletion the one place that requires an explicit local
  confirmation rather than silent remote application.

### 9.5 CloudKit encrypted fields cannot be retrofitted

Apple: *"You can't convert existing unencrypted fields in the CloudKit schema"*, and encrypted
fields cannot be indexed. You are in good shape today — every payload write uses
`encryptedValues["payload"]` and there is not a single plain `record[...]` field write in the
codebase. Preserve that: any new field must be **born** encrypted, and never add a plaintext field
"just for sorting or filtering." The v2 schema is already deployed to a container, so this is
permanent per field name.

### 9.6 Consider a third database: local-private

The durable/disposable split is right, but there is a third category. History, session, and drafts
are **local-only, high-churn, privacy-sensitive, and user-clearable** — none of which describes
bookmarks, certificates, or trust.

Real browsers separate these (Safari: `Bookmarks.plist` vs `History.db` vs cache; Chrome: separate
`Bookmarks` and `History` stores). Benefits here:

- Clear Browsing Data drops a file instead of running large `DELETE`s across the precious database.
- The highest-churn writer (a full session snapshot every 2–5 seconds) stops contending with
  security-critical writes on the same single writer.
- A corrupt history database never endangers your client certificates.
- You can run `synchronous = NORMAL` on it without weakening durability where it matters.

Cost: one more connection, and Clear Browsing Data spans two files. I would take that trade.

### 9.7 Session snapshots are heavier than the plan assumes

The plan rejects incremental IDs as "bookkeeping ... without a demonstrated need." Do the
arithmetic: 5 windows × 15 tabs × 50 back/forward entries ≈ 3,750 rows deleted and reinserted every
few seconds, in the durable database, contending with bookmark and trust writes.

You can keep the snapshot model — it is genuinely simpler and the atomicity argument is right —
with four cheap fixes:

1. Hash the snapshot and skip the write when unchanged. Most 5-second ticks change nothing.
2. Cap persisted back/forward depth per tab. Safari does.
3. Reconsider persisting a scroll offset for *every* back/forward entry rather than just the
   current one.
4. Move session into the local-private database (§9.6) so its churn never touches security data.

---

## 10. Short answers to the twelve questions

| Q | Answer |
|---|---|
| 1 | Yes, CKSyncEngine. macOS 14+; you target 26. The manifest gate moves from fetch-time to apply-time and is fully preserved. |
| 2 | Yes — but stronger. Make the outbox the **only** list via `hasPendingUntrackedChanges`; never call `add(pendingRecordZoneChanges:)`. One durable list, written in the domain transaction. |
| 3 | Neither. Drop `cloud_record_metadata` entirely for now. With a single encrypted `payload` blob there is no field-level merge, and `serverRecordChanged` supplies the server record. |
| 4 | Delete-wins yes, for **records**. Not for cascades — reparent orphaned bookmarks instead of cascading a remote folder deletion. Treat certificate deletion as a special case (§9.4). |
| 5 | Moot — decided. Trust does not sync (§2), so there is no cloud representation to design. `trusted_server_identities` stays the single local authority for decision *and* observation. |
| 6 | The outbox already answers this. A row in `cloud_pending_changes` means dirty — never delete. No row means clean — absent remotely + clean = delete locally. The handoff got this one right. |
| 7 | Two releases, never one. Release A: stop writing tombstones, upload the current active set, record a cutover marker, keep reading old tombstones. Release B: drop the shadow tables. Never a single destructive migration. |
| 8 | Zero — decided. One-shot v1→v2 migration, marker held **in CloudKit** so it is once-per-account rather than once-per-device, then v1 is never read again (§3, §3a). |
| 9 | Incremental vacuum — **set at file creation, you get one chance** — plus `journal_size_limit`, `wal_checkpoint(TRUNCATE)` at maintenance, and recreate-the-file as the backstop. Budget = main + WAL; evict at ~85% headroom. Switching to external-content FTS (§8.3) removes the duplicated content from the equation entirely. |
| 10 | Don't move it. It is a **cache**, the app is one month old, and the worst case is that pages re-fetch. The proposed dual-read lazy migration is real complexity spent preserving data with no value. Create the new cache empty; delete the old tables in deferred maintenance. |
| 11 | 1–2 s history and 2–5 s session are fine. Add a **hard ceiling** (e.g. 30 s max between session checkpoints regardless of debounce) so scroll cannot starve it — the plan identifies this risk and doesn't specify the fix. For termination use `NSApplication.reply(toApplicationShouldTerminate:)` with `.terminateLater`; that is the AppKit mechanism being reached for. |
| 12 | Yes — see §8. Notably every cache *read* takes the write lock, `prune()` full-scans on every store, and FTS deletes are full scans. |

---

## 11. Revised implementation order

The plan's order is sound. Three changes:

**Insert at position 0:** decide the trust-sync question (§2) and the legacy-compatibility question
(§3). Both are product decisions that determine how much of the rest of the plan even exists. If
trust doesn't sync, an entire record type and the hardest conflict class disappear. If legacy
compatibility ends, so do challenge #7, invalidation condition #6, and the dual-write path. Neither
is worth designing around until it is settled.

**Decide alongside them:** whether a per-navigation "don't persist this" flag exists at all (§1,
§9.3). It is not urgent on its own merits, but it is a *policy flag threaded through every write
path* — which is exactly what steps 2–6 are rewriting. Deciding it now costs little; retrofitting
it through the new actors afterwards costs a second pass over the same code.

**Add to step 7 (sync tables):** fractional ordering keys (§6) and the record-name change for
`MTServerTrust` (§2) both alter the record payload/identity. Do them in the same cutover, not
after.

Otherwise the sequencing — tests first, actors, cache split, clear/recreate, buffering, remaining
`MainActor` removal, sync tables, CKSyncEngine, migration, omnibar, docs — is right, and the
insistence that every stage be independently testable and restartable is the most important line in
the document.

---

## 12. What I did not find fault with

Worth saying explicitly, because the plan gets a lot right and a review that only lists problems is
misleading:

- Two databases over one-plus-vacuum. Correct, and the reasoning is right.
- Keeping GRDB rather than combining a persistence rewrite with a sync migration. Correct.
- Batching observations, not user intent. This is the right axis to cut on.
- Physical deletion plus authoritative resync over permanent tombstones. Correct, and the
  clean-vs-dirty rule (Q6) is right as written.
- SQLite cache over per-response files. Correct for the stated reasons.
- Keeping live browser state in memory. Correct.
- Refusing to let maintenance run on the startup path. This is the constraint most projects get
  wrong; holding it as first-class is the best decision in the document.
- The adversarial failure table. Genuinely good — most of what it lists is real, and the few gaps
  are noted above.
