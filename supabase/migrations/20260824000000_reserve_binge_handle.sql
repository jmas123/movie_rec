-- MARK: - Reserving the product's own handle after the rename
--
-- The app was renamed WatchRank → Binge. `profiles_handle_reserved` in
-- `20260821210000_social.sql` reserves `watchrank` and knows nothing about
-- `binge`, so **`@binge` is claimable by any user right now** — the one handle
-- a renamed product must hold, and the obvious one for someone to take.
--
-- **Why this is a new migration rather than an edit.** `20260821210000` is
-- applied to the hosted project. Editing it would leave the file describing a
-- schema that never ran, `db push` would not re-run it, and a later
-- `db reset` would build a local database that differs from production. That
-- is the same trap `20260823010000` was written to work around, one night
-- earlier. An applied migration records what ran.
--
-- **Why the client cannot do this alone.** `Handle.reserved` in
-- `UserProfile.swift` gains `binge` in the same change, and that is form
-- validation, not enforcement — a request that never opens the app bypasses it
-- entirely. Per `CLAUDE.md`: a rule the app enforces and Postgres does not is
-- not a rule.
--
-- **`watchrank` stays reserved.** Freeing the old name would let somebody claim
-- the handle the app used to answer to, which is an impersonation surface, not
-- a tidiness question. Reserved handles are cheap; a squatted one is not.

-- A CHECK constraint cannot be altered in place, so it is dropped and recreated
-- with the same name. The list below is `20260821210000`'s list plus `binge`,
-- and nothing else — deliberately not "tidied" in passing, so a reader can diff
-- the two and see exactly one addition.
alter table public.profiles
  drop constraint if exists profiles_handle_reserved;

alter table public.profiles
  add constraint profiles_handle_reserved check (
    handle not in (
      'admin','administrator','root','system','support','help','about','api',
      'watchrank','binge','official','staff','moderator','mod','settings','login',
      'signup','signin','logout','me','you','null','undefined','everyone','all'
    )
  );

-- **Existing rows are not re-validated by ADD CONSTRAINT … CHECK** unless the
-- table is scanned, which it is here — Postgres validates by default. So if
-- somebody has already claimed `@binge` between the rename and this migration,
-- **this will fail to apply**, loudly, rather than silently leaving them in
-- place. That is the correct outcome: it needs a human decision about an
-- existing account, not a migration that quietly skips it.
--
-- If it does fail, the recovery is to rename that account's handle first and
-- re-run — not to add `not valid` to this constraint, which would leave the
-- rule unenforced for exactly the row that violates it.

comment on constraint profiles_handle_reserved on public.profiles is
  'Handles that would collide with a route or allow impersonation of the app. '
  'Includes both the current product name (binge) and the former one '
  '(watchrank) — a renamed product must keep holding its old handle.';
