# Part IV — Account sync (v2.1)

**Status:** built, unverified against a database · **Decided & built:** 2026-08-23 · **Supersedes:** `PART-III-SOCIAL.md` §8 and open question 3

> **Where it stands.** Phases 29–32 are code-complete; **539 unit tests green**
> and **33/33 pgTAP assertions pass** against a local stack.
>
> **The hosted project is current, and the privilege fix is verified there.**
> All seven migrations are applied. Checked against the live schema on
> 2026-08-24, `authenticated` holds `INSERT` and `SELECT` on
> `ranked_items.is_published` and **no `UPDATE`**; `anon` holds nothing on it;
> `set_library_published`, `set_bucket_published` and `blocked_accounts` all
> exist.
>
> That check is worth repeating after any change to grants on this table,
> because the failure it guards is silent: `20260823000000` shipped a
> column-level `REVOKE` that ran successfully and did nothing (§4), and a
> migration list looks identical either way. **Verify the privilege state, not
> the migration record.** Phase 33 (disclosure): the sign-up sentence and the
> `CLAUDE.md` "Do not" rewrite have landed, and the privacy-policy *text* is
> drafted — what is outstanding is **publishing** it, since
> `SupportLinks.privacyPolicy` points at a URL that does not resolve. Phase 34
> is untouched.

## 1. The decision

> "I want each user's entries to be in their account at all times, so if they sign in from any device, their entries are there."

Part III shipped a *published projection*: the device is the truth, the server
holds a copy for other people to look at. Part IV makes the account durable
storage for the user's own library, so a lost phone is not a lost ranking and a
second device is not a second library.

**This is the thing `PART-III-SOCIAL.md` deliberately deferred.** §8 states
"v2.0 assumes one device per account", and open question 3 defers the fix. Part
IV closes that question. It does not close it the way open question 3
speculated — replaying comparison *decisions* rather than positions remains
unbuilt, and remains the better long-term answer (§8 below).

## 2. What does not change

Part III's five invariants (`PART-III-SOCIAL.md` §2) hold without amendment.
Two of them constrain this design tightly enough to be worth restating:

1. **The ranking engine stays pure and local.** The server never computes a
   score. Part IV imports *positions* and recomputes scores on device — see §5.
2. **The app is fully usable signed out.** Sync is something an account adds,
   never something the app requires. A user who never signs in must not be able
   to tell that this document exists.

One thing does change, and it is a documented invariant, so it is called out
rather than quietly reversed:

> ~~"What still never leaves the device: … anything at all while the user is
> signed out."~~ — still true. Signed out, nothing syncs.
>
> ~~"Publishing is opt-in and never silent."~~ — **split in two.** *Syncing* to
> your own account is now unconditional once signed in. *Publishing* — making a
> ranking visible to other people — remains opt-in and never silent. The
> consent question survives; it is asked about a different thing.

## 3. The distinction this whole document rests on

Today `ranked_items` does two jobs with one row:

| Job | Audience | Should it be opt-in? |
|---|---|---|
| Your cloud copy | you, on your other devices | **no** — it is your own data |
| Your public ranking | followers, on your profile | **yes** |

Conflating them means "sync my library" and "show my library to strangers" are
the same switch. Turn it off and you lose your backup; turn it on and you have
published. Neither is what a user wants, and the current code takes the worse
of the two: `SyncEngine.drain()` is gated on consent, so a user who declines
gets no cloud copy at all.

**Part IV separates the two at the security boundary**, because per `CLAUDE.md`
a rule the client enforces and Postgres does not is not a rule.

## 4. Schema

One migration. One column, one policy.

```sql
alter table public.ranked_items
  add column is_published boolean not null default false;

drop policy ranked_items_select on public.ranked_items;

create policy ranked_items_select on public.ranked_items for select to authenticated
  using (
    user_id = auth.uid()
    or (is_published and app.can_view_library(user_id))
  );
```

`app.can_view_library` already short-circuits on `owner = auth.uid()`, so the
self-read half works today with no policy change — but stating it explicitly in
the policy keeps the two audiences legible to anyone reading the schema, and
stops a future edit to `can_view_library` from silently taking your own library
away from you.

**Default `false` is the migration's whole safety story.** Every row that
already exists becomes private on upgrade. Nobody's library becomes visible
because a migration ran.

### Publishing stays per-bucket, not per-item

`is_published` is a per-row column set **uniformly across a `(type, sentiment)`
bucket**. This is not tidiness; a per-item flag leaks.

Every row carries `bucket_size` so a viewer can apply rule 6 to someone else's
library (`PART-III-SOCIAL.md` §5). Publish 3 of 7 Liked films and a viewer sees
three rows claiming `bucket_size: 7`. That tells them four titles exist that
they are not allowed to see, and it shows a score computed over a bucket they
cannot verify. Rule 6 exists to stop the app implying precision it has not
earned; a partially-published bucket implies precision the *viewer* cannot check.

All-or-nothing per bucket also matches §8's existing rule that the bucket is the
unit of sync, so the outbox needs no new concepts.

## 5. Disclosure: the half that must stay loud

Making sync unconditional **removes a decision the user used to make.** That is
the intent. It also means the app now has to *say* what it does, at the moment
it becomes true, because there is no longer a switch the user can look at to
find out.

Three statements the app currently makes become false, and shipping any of them
unchanged would be a lie rather than an oversight:

1. **The consent sheet.** It currently reads *"Nothing has been uploaded yet.
   Your ranking stays on this device until you say so."* That is false the
   moment `drain()` is unconditional. The sentence does not get edited — it gets
   deleted, and the sheet gets repointed at the publishing question.
2. **`CLAUDE.md`'s "Do not" section.** It lists what never leaves the device:
   untracked items, nil-`externalId` items, and anything at all while signed
   out. The first and third stay true. What changes is the neighbouring claim
   that publishing is the only thing that leaves — syncing now does too.
   *This file is a project constitution; the edit needs the user's sign-off, not
   a peer's.*
3. **The privacy policy.** It has to state that a signed-in account stores the
   user's library, not merely what they chose to publish.
4. **`PrivacyInfo.xcprivacy`'s header comment.** The manifest's *declarations*
   need no change — `NSPrivacyCollectedDataTypeOtherUserContent` already covers
   a whole library, not just a published subset. But its header comment cites
   `PART-III-SOCIAL.md` §8 for "signed out, nothing leaves the device", and §8
   is the section Part IV supersedes. A stale cross-reference inside a
   compliance artifact is worse than one in a design doc.

Two constraints on where the sentence goes, from the session that built the
terms gate: it must **not** be folded into the "I agree to the Terms of Use and
Privacy Policy" toggle's label, and `canSubmit`'s `guard acceptedTerms` must
stay — that gate is Guideline 3.1.2/1.2 and is load-bearing on its own. The
disclosure belongs beside the toggle, not inside it.

**Requirement: account creation discloses sync.** Signing up *is* the moment the
user grants it, so it is the moment they must be told — one plain sentence at
the point of decision, not a clause in a policy nobody opens. "Your rankings are
saved to your account so they follow you between devices. Nothing is visible to
anyone else until you publish it."

The real consent survives untouched, and it is stronger than a checkbox:
**a user who wants nothing on a server does not make an account, and the app
stays fully usable that way** (invariant 3). Part IV does not weaken that; it
just stops pretending the in-between state was meaningful.

## 6. The client

### 6.1 What is missing today

**The push half is done.** As of 2026-08-23 `SyncEngine.drain()` has four
triggers in `BingedApp` — session change, foreground, library mutation, and
network return via `ConnectivityMonitor` — and publishing has run end to end on
the simulator. (An earlier draft of this document said it had zero call sites.
That was true when measured and was overtaken the same afternoon.)

**The pull half does not exist.** `RankingFeedService.rankedItems(userID:)` is a
paged read for rendering *someone else's* profile; nothing reads your own rows
back into SwiftData. This is the entire gap between what ships today and what
this document asks for — everything in §6.2–§6.5 is new code.

The one live blocker is in §3: `drain()` is currently gated on
`consentDecision == true`, so a user who declines gets no cloud copy at all.

### 6.2 Restore is two pieces, and only one of them touches a network

**`LibraryRestoreService`** — thin. `GET ranked_items?user_id=eq.<me>`, decode,
return rows. No merge logic, no SwiftData. Has a `Mock` sibling like every other
service.

**`LibraryMerge`** — a pure function, no network and no `ModelContext`:

```swift
func plan(local: [MediaItem], remote: [RemoteRankedItem]) -> MergePlan
```

This is where the logic and the tests live, for the reason `RankingEngine` is
pure: the interesting failures are all in the merge, and none of them need a
server to reproduce.

### 6.3 The merge rule

Union, keyed on `externalId` — already namespaced `tmdb:movie:27205`, so unique
across types (Phase 12 finding 2).

| Case | Outcome |
|---|---|
| Both sides | Server's sentiment and position win |
| Local only | Keep, and mark the bucket dirty so it pushes |
| Remote only | Insert |

Nothing is ever discarded. "Server wins ties" resolves *disagreements*; it never
deletes a title only one side knows about.

### 6.4 Scores are recomputed, never imported

The merge imports `rank_in_bucket` — an *order*. It then recomputes every
affected bucket through the shared recompute, exactly as an insertion does.

Two reasons, and both are load-bearing:

1. **Merging changes N.** A bucket whose size changed without a recompute leaves
   survivors holding scores computed for the old N. That is the vacated-bucket
   bug with a network in the middle.
2. **Invariant 1.** If we wrote the server's `score` into the local store, the
   server would have computed a score. It must not. The number it holds is a
   denormalised copy for other people to read, and it is advisory here.

### 6.5 Order of operations on sign-in

**Restore, then drain.** Getting this backwards is destructive: draining first
pushes a device that has not yet seen the account, and last-write-wins does the
rest.

```
sign in → fetch remote rows → merge → recompute affected buckets
        → mark merged buckets dirty → drain outbox
```

A failure anywhere in the first four steps must leave the outbox untouched and
the local library unchanged. Half a merge is worse than none.

## 7. What syncs

Per the decision: **ranked and want-to-watch titles with a resolved
`externalId`.** That is what the schema already models — the
`ranked_items_ranked_or_queued` constraint exists precisely so a queued entry is
a legal row.

**Titles with a nil `externalId` stay on the device**, because the server has no
key for them. This is a real gap, not a rounding error: sign in elsewhere and
those titles are missing. The UI must say so plainly — `SyncEngine.unpublishableCount`
already computes exactly this number and currently has nowhere to display it.
"3 titles stay on this device" is honest; silently omitting them is not.

## 8. Limitations, stated honestly

**Two devices ranking concurrently still produce an order neither user chose.**
Merge means nothing is *lost* — that is a real improvement over §8's wholesale
bucket loss — but a merged bucket is a union re-sorted by two partial orders
that never met. The user may open the app and find their top five rearranged by
a merge rather than by a comparison they made. There is no way around this while
the server stores derived positions.

**The principled fix remains unbuilt.** Storing comparison *decisions* rather
than their results would let any device replay the ranking, and would make the
ranking portable and auditable as a side effect. `PART-III-SOCIAL.md` open
question 3 describes it. Part IV does not do it, and Part IV does not make it
harder to do later — the outbox and the merge both sit above the engine, which
stays pure either way.

**`PART-III-SOCIAL.md` §8 needs rewriting** once this ships. "v2.0 assumes one
device per account" stops being true, and a stale invariant is worse than none.

## 9. Consequences for work in flight

A concurrent session is building `PublishConsent` as a gate on
`SyncEngine.drain()`. Under this design the gate **moves rather than
disappears**:

| Survives | Inverts |
|---|---|
| `PublishConsent` as a stored per-user answer | The `consentDecision == true` guard on `drain()` |
| The `!isRankingInProgress` guard on `drain()` | `isPublishingAllowed` / `needsConsentDecision` semantics |
| Wiring `drain()` to real call sites | Any sheet copy asking to "sync your library" |

The consent sheet's question changes from *"may we sync this?"* to *"publish
your ranking so followers can see it?"* — different words, different placement,
different default. Refusing must never read as "your data stays on this device",
because after Part IV it does not.

## 10. Phases

| # | Phase | Deliverable |
|---|---|---|
| 29 | Schema | ✅ `is_published`, `profiles.publishes_library`, the select policy, the inherit trigger, and both RPCs — plus `20260823010000`, which fixes a privilege revoke that silently did nothing. **`rls_test.sql`: 33/33 pass locally** |
| 30 | Merge | ✅ `LibraryMerge` pure + 13 tests; `MediaItem.lastRankedAt` (no schema version — see below) |
| 31 | Restore | ✅ `LibraryRestoreService` + mock, `LibraryRestorer` + 9 tests, restore-then-drain wired into `sessionChanged()` |
| 32 | Publish control | ✅ per-bucket `is_published`, repointed consent sheet, `set_library_published` — built with the session that owns the consent flow |
| 33 | Disclosure | ✅ sign-up sentence; `CLAUDE.md` "Do not" rewritten (signed off by the user); `PrivacyInfo.xcprivacy` corrected — see below; privacy-policy text drafted at [`PRIVACY-POLICY.md`](./PRIVACY-POLICY.md). **Outstanding: publishing it.** `SupportLinks.privacyPolicy` points at a URL that does not exist, and review follows that link |
| 34 | Doc + QA | ✅ `PART-III-SOCIAL.md` §8 and open question 3 superseded; `MANUAL-QA.md` gained Journey 7i (two devices) and 7c's stale "blocked until the migration lands" note removed |

**The privacy manifest was wrong, and not only in its cross-reference.** It
declared `NSPrivacyAccessedAPITypes` empty and said in prose that the app uses
no `UserDefaults` — but `PublishConsent` stores the publish answer there, and
`UserDefaults` is a required-reason API. Now declared with reason **CA92.1**
(values accessible only to the app itself), which is accurate: the answer never
leaves the device and is not shared with an app group. This is a submission
blocker that a reviewer, not a test, would have found.

**`lastRankedAt` needed no schema version, and adding one crashed the app.** A
`VersionedSchema` describes models *as they were*; V1 and V2 both listing the
live `MediaItem.self` compute the same checksum, and
`NSLightweightMigrationStage` throws when `from == to` — inside
`BingedApp.init()`, so the app aborts before drawing a frame, where
`StoreRecoveryView` cannot catch it. A real version needs a *frozen copy* of
each changed model. Nothing has shipped, development deletes the app between
shape changes, and the property is optional — so there is no store to migrate
from and one version is correct. The trap is written up in
`Models/BingedSchema.swift`.

**The unit suite cannot see a launch crash.** It builds containers directly and
never calls `BingedApp.init()`; it stayed green through the abort. Anything
touching the schema or app startup needs the full plan or a real launch.

**Open: whether the identity columns need to stay UPDATE-able.**
`20260823010000` re-grants UPDATE on every column except `is_published`,
including `user_id`, `media_type` and `external_id`. Excluding them would be
defensible hardening — changing a row's identity is a delete-and-insert, not an
update — but PostgREST's `resolution=merge-duplicates` may put the conflict
target in its generated `DO UPDATE SET`, and if it does, excluding them 42501s
every publish after a bucket's first. A hand-written upsert *with* the key
columns in the SET list has been shown to succeed under the current grant; that
proves the grant is sufficient **if** PostgREST includes them, and says nothing
about whether it does. Settling it needs PostgREST running with
`log_statement='all'` and someone reading the emitted SQL. Until then: reasoned,
not observed, and the grant stays wide.

**`supabase test db` reports `PASS` alongside "planned 33 but ran 27".** The
miscount is a harness artifact, not six skipped assertions: `psql -t -A` emits
all 33 TAP lines. psql's aligned output wraps long descriptions and pg_prove
counts the wrapped lines as separate. Shortening the descriptions did not fix
it, so the cause is the runner's flags rather than the prose. It is recorded
here because "PASS with a miscount" is the state most likely to teach someone to
stop reading the plan line — which is the one number that would reveal a real
skip.

**Verification status.** 33/33 pgTAP assertions pass against a local stack
(Postgres 15.8), and the privilege state is confirmed on the hosted project
(17.6). What has *not* been done: the pgTAP suite has never run against the
deployed schema, and the CLI's bundled `pg_dump` (15.8) cannot even read a 17.6
server, so `db dump` and `db pull` fail until the CLI is upgraded. Three of the four mechanisms in §4 — the two-audience policy,
the trigger's three-case fallback, and the `user_id = auth.uid()` boundary
inside a SECURITY DEFINER function — have never been executed. They are
deployed. Existence is not correctness.

Phase 30 is the one worth over-testing. It is pure, it is where every
interesting failure lives, and it is the only phase whose bugs are silent.
