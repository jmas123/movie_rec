-- =============================================================================
-- Reserve `binged` — the product's third name.
--
-- WatchRank -> Binge -> Binged, all on 2026-08-23/24. The sweep that renamed
-- Binge to Binged rewrote capitalised `Binge` only, deliberately leaving every
-- lowercase `binge` alone — otherwise it would have reserved the new name while
-- silently *freeing* the old one, which is the opposite of the point.
--
-- **Why this is a new file rather than an edit to `20260824000000`.**
-- That migration adds `binge` and was written an hour ago. Editing it would be
-- defensible if it were certainly unapplied — the rule this project learned the
-- hard way is "an applied migration records what ran", not "never edit a
-- migration". But it cannot be verified as unapplied from here: `db push`
-- requires a password no session holds, and one push already happened tonight
-- without either of the sessions involved knowing in advance.
--
-- So: a forward migration, which is correct whether or not `20260824000000` has
-- run. The cost is one extra file. The cost of being wrong the other way is a
-- checked-in migration that disagrees with the database it was applied to.
--
-- **Every name this product has ever had stays reserved.** Freeing `watchrank`
-- or `binge` would let somebody claim a handle the app used to answer to, which
-- is an impersonation surface rather than a tidiness question. Anyone who saw an
-- earlier build reads those names as official. Reserved handles are cheap; a
-- squatted one is not.
-- =============================================================================

-- A CHECK constraint cannot be altered in place, so it is dropped and recreated
-- under the same name. The list below is `20260824000000`'s list plus `binged`,
-- and nothing else — deliberately not tidied in passing, so a reader can diff
-- the two files and see exactly one addition.
alter table public.profiles
  drop constraint if exists profiles_handle_reserved;

alter table public.profiles
  add constraint profiles_handle_reserved check (
    handle not in (
      'admin','administrator','root','system','support','help','about','api',
      'watchrank','binge','binged','official','staff','moderator','mod','settings',
      'login','signup','signin','logout','me','you','null','undefined','everyone','all'
    )
  );

-- **`ADD CONSTRAINT … CHECK` validates existing rows** — Postgres scans by
-- default. So if somebody has already claimed `@binged` between the rename and
-- this migration, **this fails loudly** rather than silently leaving them in
-- place. That is the correct outcome: an existing account needs a human
-- decision, not a migration that quietly skips it.
--
-- If it does fail, the recovery is to rename that account's handle and re-run —
-- **not** to add `not valid`, which would leave the rule unenforced for exactly
-- the row that violates it.
--
-- This file is idempotent in the sense that matters: re-running it recreates the
-- same constraint. It is *not* safe to run against a database whose constraint
-- has since gained further names, since it would drop them — check the current
-- definition before replaying it out of order.

comment on constraint profiles_handle_reserved on public.profiles is
  'Handles that would collide with a route or allow impersonation of the app. '
  'Includes the current product name (binged) and both former ones (binge, '
  'watchrank) — a renamed product must keep holding its old handles.';
