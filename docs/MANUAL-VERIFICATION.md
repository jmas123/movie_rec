# Manual verification queue

Things an autonomous session could not check for itself, kept in one place so
they are not scattered across commit messages and roadmap notes.

**Status key:** 🔴 blocks a phase · 🟡 should be checked before shipping ·
🟢 nice to confirm

> **Shipping specifically?** [`TESTFLIGHT-CHECKLIST.md`](./TESTFLIGHT-CHECKLIST.md) collects the
> subset of this queue that stands between the working tree and a TestFlight build, ordered by
> what blocks what. §§6, 7 and 9 below are folded into it.

Last updated 2026-08-21.

---


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

### 7. ~~Supabase migrations~~ and the edge function are not deployed

**Migrations: resolved 2026-08-25.** `supabase migration list` against the linked
project (`qyboceoakxznkrbeygro`) reports **all ten local migrations applied
remotely**, `20260825000000_comment_editing.sql` included after a push that
evening. There is no schema drift.

**This section was wrong for a long time and that is the lesson worth keeping.**
It listed `20260822000000_moderation.sql` as "written, never run" — it had been
applied since 2026-08-22. `GAP-AUDIT.md` §1 separately claimed only
`20260821210000_social.sql` was live and that `@binge`/`@binged` were therefore
claimable by anyone; both reservation migrations were in fact already applied.
Two documents asserting remote state that neither had checked, repeated forward
for days, and read by at least one session as a live security exposure.

**How to apply:** remote state is a one-command question —
`supabase migration list`, which prints LOCAL against REMOTE. It needs the
database password, so it cannot be answered from inside the repo or by an agent
without it. Never restate what is deployed from a document; run the command, and
if you cannot, say that the state is unverified rather than repeating the last
thing someone wrote.

Still not deployed:

- **`20260826010000_content_filter.sql`** — the UGC term filter (App Store 1.2's
  fourth requirement; see `docs/APP-STORE-CONNECT-RECORD.md` §4). Written and
  verified against a local `db reset` on 2026-08-26: 18 pgTAP assertions in
  `supabase/tests/content_filter_test.sql`, with `rls_test` (42) and
  `comment_editing_test` (10) still green beside it. **Local Postgres is 15.x
  and the project is 17.x, so that is strong evidence and not proof.**
- `20260826000000_title_watchers.sql` — added the same day by another session;
  listed here because it is newer than the push that made §7's "all ten applied"
  true, not because anything is known to be wrong with it.
- `supabase/functions/tmdb-proxy/` — the TMDB credential proxy. Phase 35: deploy
  it, `supabase secrets set TMDB_READ_TOKEN=…`, then remove the token from the
  release build and **rotate it**. Until the function is live every build falls
  through to the direct path, so nothing has changed on anyone's device.

To apply: `supabase db push` (or `supabase start` then `db reset` locally), and
`supabase functions deploy tmdb-proxy` with `TMDB_READ_TOKEN` set as a function
secret. The proxy is inert until the app is pointed at it — that switch is a
one-line change in `TMDBEndpoint` and is deliberately **not** made yet, because
it cannot be tested from here.

### 8. Sign-up does not yet gate on accepting terms

Phase 28 step 2 asks for EULA acceptance at signup. The links are in Settings
(Apple's standard EULA and a privacy-policy URL) but the sign-up form does not
require a tick. Add the checkbox before submitting to review, and put a real
privacy policy at the URL — `https://trybinged.com/privacy` is where
`SupportLinks` now points, and nothing is served there yet.

### 9. App Store privacy labels

Declare: email address, handle/username, user content (rankings, reviews,
comments), all **linked to identity**. Not declared and not collected:
location, contacts, browsing history, advertising identifiers.

---

## Resolved

*(items move here once confirmed)*
