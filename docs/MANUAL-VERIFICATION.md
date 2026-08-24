# Manual verification queue

Things an autonomous session could not check for itself, kept in one place so
they are not scattered across commit messages and roadmap notes.

**Status key:** 🔴 blocks a phase · 🟡 should be checked before shipping ·
🟢 nice to confirm

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
