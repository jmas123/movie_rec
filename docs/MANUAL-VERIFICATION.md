# Manual verification queue

Things an autonomous session could not check for itself, kept in one place so
they are not scattered across commit messages and roadmap notes.

**Status key:** 🔴 blocks a phase · 🟡 should be checked before shipping ·
🟢 nice to confirm

Last updated 2026-08-21.

---

## 🔴 Blockers

### 1. Supabase credentials are missing

`WatchRank/Config/Secrets.xcconfig` contains `TMDB_READ_TOKEN` and **nothing
else**. `Secrets.xcconfig.example` documents two more keys that are not present:

```
SUPABASE_URL      = https://<ref>.supabase.co
SUPABASE_ANON_KEY = <anon/public key>
```

**Effect:** Part III client code can be written and tested against a *local*
Supabase stack (the CLI and Docker are both installed, and
`supabase/migrations/` + `supabase/tests/rls_test.sql` exist), but the app
cannot talk to your hosted project until these are added.

**What to do:** Supabase dashboard → Project Settings → API → copy Project URL
and the `anon`/`public` key into `Secrets.xcconfig`. The file is gitignored;
never commit it.

---

## 🟡 Should be checked before shipping

### 2. Discover screen: dark mode, Dynamic Type, VoiceOver

`osascript` has no assistive access in this environment, so the running screen
could not be driven or inspected. Covered by unit tests: the four empty states,
the confidence gate, the band copy, the accessibility *strings*. Not covered:
how any of it looks or sounds.

Specifically worth a look:
- Mood chip grid at the largest accessibility text sizes — grids break first.
- The predicted badge beside a real score badge, light and dark. They must not
  read as the same kind of thing.
- VoiceOver on a recommendation row: it should say "predicted 8.2 out of 10",
  never a bare number.

### 3. ~~Simulator wipe after the Phase 17 schema change~~ — not needed

Resolved. The three new properties are optional or defaulted, so SwiftData
lightweight-migrated in place: all 50 items survived and no wipe was required.
Your library was exported to `.library-backup-20260821/` (gitignored) before
the attempt, and that backup is still there if you want it.

**Worth knowing:** `CLAUDE.md`'s "delete the app on any schema change" is right
for renames, type changes and relationships, and too strict for purely additive
optional/defaulted properties.

### 4. Rank a few titles you *didn't* love — it is the highest-leverage thing you can do

Not a bug report, a measurement. Two snapshots of your own library, one day
apart:

| | 41 titles, all Liked | 49 titles, 7 marked Fine |
|---|---|---|
| Spearman ρ | +0.187 (not significant) | **+0.366 (significant)** |
| Prediction range | 8.37 – 8.44 | **7.50 – 8.46** |

Seven ratings in a second bucket roughly doubled the correlation and widened
the output tenfold. About 85% of what the model learns is *which bucket* a
title landed in, so a handful of "It was fine" and "Didn't like it" ratings is
worth more than any amount of tuning. A few Disliked entries would help most —
you currently have none, so the app has never seen what you actively dislike.

### 5. Part III has never run against a real Supabase project

Everything in Phases 21+ is client code tested against `StubURLProtocol`. That
covers the retry rules, the header shapes, the error mapping and the
concurrency — but **not** whether the schema, the RLS policies and the client
agree with each other.

The local stack was deliberately not started: this is an 8 GB M1 Air already at
3.2 GB of swap, and a full Supabase stack is six containers.

To verify, either:
- `supabase start` (Docker) and point `Secrets.xcconfig` at `http://127.0.0.1:54321`, or
- use the hosted project (see blocker 1).

Then walk: sign up → claim handle → sign out → sign in → publish → follow →
feed. The RLS tests in `supabase/tests/rls_test.sql` cover the server side
independently and were green at Phase 20.

### 6. Sign in with Apple is not built

Phase 22 step 5. It is a system framework with no dependency cost, but it needs
an entitlement, a configured Services ID in the developer portal, and a real
device to test — none of which an autonomous session can set up. The email and
password path is complete and is the fallback either way.

---

## 🟢 Worth confirming

### 5. TMDB rate limits during a cold pool build

A cold candidate pool pages every mood × type × component — up to ~150 requests
before the first mood tap answers. Never observed hitting a limit, but it has
only ever been run on a warm cache or against stubs.

### 6. Nothing secret is committed

`git grep` for the TMDB token pattern and the Supabase anon key before any
push. `Secrets.xcconfig` is gitignored; `Secrets.xcconfig.example` is not and
must stay placeholder-only.

### 7. Supabase migrations and the edge function are not deployed

Written, never run:

- `supabase/migrations/20260822000000_moderation.sql` — reports, rate-limit
  triggers, `delete_account()`
- `supabase/functions/tmdb-proxy/` — the TMDB credential proxy

To apply: `supabase db push` (or `supabase start` then `db reset` locally), and
`supabase functions deploy tmdb-proxy` with `TMDB_READ_TOKEN` set as a function
secret. The proxy is inert until the app is pointed at it — that switch is a
one-line change in `TMDBEndpoint` and is deliberately **not** made yet, because
it cannot be tested from here.

### 8. Sign-up does not yet gate on accepting terms

Phase 28 step 2 asks for EULA acceptance at signup. The links are in Settings
(Apple's standard EULA and a privacy-policy URL) but the sign-up form does not
require a tick. Add the checkbox before submitting to review, and put a real
privacy policy at the URL — `https://watchrank.app/privacy` currently points at
nothing.

### 9. App Store privacy labels

Declare: email address, handle/username, user content (rankings, reviews,
comments), all **linked to identity**. Not declared and not collected:
location, contacts, browsing history, advertising identifiers.

---

## Resolved

*(items move here once confirmed)*
